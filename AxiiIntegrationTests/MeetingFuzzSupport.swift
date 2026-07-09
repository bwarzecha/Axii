//
//  MeetingFuzzSupport.swift
//  AxiiIntegrationTests
//
//  Support types for the meeting concurrency fuzzer: a gate hub that turns
//  every async dependency call into a harness-controlled suspension point,
//  a seeded RNG for reproducible schedules, and chaos fakes that record
//  their own lifecycle and flag illegal transitions.
//

import Foundation
@testable import Axii

// MARK: - Deterministic RNG

/// SplitMix64 — tiny, seedable, reproducible across runs.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next(upperBound: UInt64) -> UInt64 {
        upperBound == 0 ? 0 : next() % upperBound
    }
}

// MARK: - Violation Log

/// Collects invariant violations observed by the fakes and the driver.
@MainActor
final class ViolationLog {
    private(set) var violations: [String] = []

    func add(_ message: String) {
        violations.append(message)
    }
}

// MARK: - Gate Hub

/// Every async dependency call parks here. The driver decides, per schedule,
/// which suspended call proceeds next — deterministic interleaving control
/// without sleeps.
@MainActor
final class GateHub {
    private var waiters: [(label: String, continuation: CheckedContinuation<Void, Never>)] = []

    var pendingCount: Int { waiters.count }

    func pass(_ label: String) async {
        await withCheckedContinuation { continuation in
            waiters.append((label, continuation))
        }
    }

    @discardableResult
    func releaseRandom(_ rng: inout SplitMix64) -> Bool {
        guard !waiters.isEmpty else { return false }
        let index = Int(rng.next(upperBound: UInt64(waiters.count)))
        waiters.remove(at: index).continuation.resume()
        return true
    }

    func releaseAll() {
        while !waiters.isEmpty {
            waiters.removeFirst().continuation.resume()
        }
    }
}

// MARK: - Chaos Errors

enum ChaosError: Error {
    case startFailed
}

// MARK: - Chaos Audio Manager

/// MeetingAudioManaging fake that suspends on the gate hub and records its
/// lifecycle. Illegal transitions are flagged immediately.
@MainActor
final class ChaosAudioManager: MeetingAudioManaging {
    let id: Int
    let shouldFailStart: Bool
    let micURL: URL
    let systemURL: URL

    private let gates: GateHub
    private let violations: ViolationLog

    private(set) var started = false
    private(set) var live = false
    private(set) var startFailed = false
    private(set) var stopCalls = 0
    private(set) var cleaned = false

    var onAudioLevel: ((Float) -> Void)?
    var onTranscriptionChunk: ((TranscriptionChunk) -> Void)?
    var onError: ((String) -> Void)?

    init(id: Int, gates: GateHub, violations: ViolationLog, shouldFailStart: Bool) {
        self.id = id
        self.gates = gates
        self.violations = violations
        self.shouldFailStart = shouldFailStart
        self.micURL = URL(fileURLWithPath: "/chaos/mic-\(id).raw")
        self.systemURL = URL(fileURLWithPath: "/chaos/system-\(id).raw")
    }

    func start(
        micSource: AudioSource.MicrophoneSource,
        appSelection: AppSelection
    ) async throws {
        if started {
            violations.add("audio[\(id)] started twice")
        }
        started = true
        await gates.pass("audio[\(id)].start")
        if shouldFailStart {
            startFailed = true
            throw ChaosError.startFailed
        }
        live = true
    }

    func stop() -> (micFile: URL?, micRate: Double, systemFile: URL?, systemRate: Double) {
        stopCalls += 1
        if !started {
            violations.add("audio[\(id)] stopped before start")
        }
        if stopCalls > 1 {
            violations.add("audio[\(id)] stopped \(stopCalls) times")
        }
        guard live else { return (nil, 0, nil, 0) }
        live = false
        return (micURL, 16_000, systemURL, 16_000)
    }

    func switchApp(
        to app: AudioApp?,
        micSource: AudioSource.MicrophoneSource
    ) async throws {
        guard live else { return }
        // Mirrors the real manager's stop-and-restart dance: not live while
        // the switch is in flight.
        live = false
        await gates.pass("audio[\(id)].switch")
        live = true
    }

    func readSamplesFromFile(_ url: URL?) -> [Float] {
        if cleaned {
            violations.add("audio[\(id)] read after cleanup — data loss")
        }
        guard url != nil else { return [] }
        return [0.25]
    }

    func cleanupTempFiles() {
        if live {
            violations.add("audio[\(id)] cleanup while capture is live")
        }
        cleaned = true
    }

    func emitChunk() {
        onTranscriptionChunk?(TranscriptionChunk(
            samples: [0.5],
            source: .microphone,
            timestamp: Date()
        ))
    }
}

// MARK: - Chaos Transcript Manager

@MainActor
final class ChaosTranscriptManager: MeetingTranscriptManaging {
    let id: Int
    let sessionID = UUID()
    let autosaveFileURL: URL

    private let gates: GateHub
    private let violations: ViolationLog

    private(set) var autosaveRunning = false
    private(set) var flushCount = 0
    private(set) var clearCount = 0
    private(set) var everStartedAutosave = false

    var onSegmentsUpdated: (([MeetingSegment]) -> Void)?

    init(id: Int, gates: GateHub, violations: ViolationLog) {
        self.id = id
        self.gates = gates
        self.violations = violations
        self.autosaveFileURL = URL(fileURLWithPath: "/chaos/autosave-\(id).json")
    }

    func reset() {}

    func setSelectedApp(_ app: AudioApp?) {}

    func startAutoSave() {
        if autosaveRunning {
            violations.add("transcript[\(id)] autosave started twice")
        }
        autosaveRunning = true
        everStartedAutosave = true
    }

    func stopAutoSave() {
        autosaveRunning = false
    }

    func flushAutoSave() {
        flushCount += 1
    }

    func clearAutoSave() {
        clearCount += 1
        if clearCount > 1 {
            violations.add("transcript[\(id)] autosave cleared \(clearCount) times")
        }
    }

    func checkForCrashRecovery() -> MeetingCrashRecovery? {
        nil
    }

    @discardableResult
    func transcribeChunk(_ chunk: TranscriptionChunk) -> Task<Void, Never> {
        // Ignores cancellation and completes only when the gate opens —
        // maximizes the window stop() spends suspended awaiting chunk tasks.
        Task {
            await gates.pass("transcript[\(id)].chunk")
        }
    }
}

// MARK: - Registry

/// Creates and tracks every chaos fake an iteration produced, so the driver
/// can check conservation invariants across the whole run.
@MainActor
final class ChaosRegistry {
    private let gates: GateHub
    private let violations: ViolationLog

    private(set) var audios: [ChaosAudioManager] = []
    private(set) var transcripts: [ChaosTranscriptManager] = []

    init(gates: GateHub, violations: ViolationLog) {
        self.gates = gates
        self.violations = violations
    }

    func makeAudio(failStart: Bool) -> ChaosAudioManager {
        let audio = ChaosAudioManager(
            id: audios.count,
            gates: gates,
            violations: violations,
            shouldFailStart: failStart
        )
        audios.append(audio)
        return audio
    }

    func makeTranscript() -> ChaosTranscriptManager {
        let transcript = ChaosTranscriptManager(
            id: transcripts.count,
            gates: gates,
            violations: violations
        )
        transcripts.append(transcript)
        return transcript
    }

    var liveAudio: ChaosAudioManager? {
        audios.last { $0.live }
    }

    func transcript(for sessionID: UUID) -> ChaosTranscriptManager? {
        transcripts.first { $0.sessionID == sessionID }
    }

    func audio(forMicURL url: URL?) -> ChaosAudioManager? {
        guard let url else { return nil }
        return audios.first { $0.micURL == url }
    }
}

// MARK: - Null Transcriber

actor NullTranscriber: TranscriptionProviding {
    var isReady: Bool { true }
    func prepare() async throws {}
    func transcribe(samples: [Float], sampleRate: Double) async throws -> String { "" }
}
