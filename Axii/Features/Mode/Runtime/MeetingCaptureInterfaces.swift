//
//  MeetingCaptureInterfaces.swift
//  Axii
//
//  Collaborator surfaces and boundary types for MeetingCaptureSession:
//  audio/transcript manager protocols and capture start/result values.
//

#if os(macOS)
import Foundation

@MainActor
protocol MeetingAudioManaging: AnyObject {
    var onAudioLevel: ((Float) -> Void)? { get set }
    var onTranscriptionChunk: ((TranscriptionChunk) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }

    func start(
        micSource: AudioSource.MicrophoneSource,
        appSelection: AppSelection
    ) async throws
    func stop() -> (
        micFile: URL?,
        micRate: Double,
        systemFile: URL?,
        systemRate: Double
    )
    func switchApp(
        to app: AudioApp?,
        micSource: AudioSource.MicrophoneSource
    ) async throws
    func readSamplesFromFile(_ url: URL?) -> [Float]
    func cleanupTempFiles()
}

extension MeetingAudioManager: MeetingAudioManaging {}

@MainActor
protocol MeetingTranscriptManaging: AnyObject {
    var onSegmentsUpdated: (([MeetingSegment]) -> Void)? { get set }
    var sessionID: UUID { get }
    var autosaveFileURL: URL { get }

    func reset()
    func setSelectedApp(_ app: AudioApp?)
    func startAutoSave()
    func stopAutoSave()
    func flushAutoSave()
    func clearAutoSave()
    func checkForCrashRecovery() -> (
        segments: [MeetingSegment],
        duration: TimeInterval
    )?
    @discardableResult
    func transcribeChunk(_ chunk: TranscriptionChunk) -> Task<Void, Never>
}

extension MeetingTranscriptManager: MeetingTranscriptManaging {}

struct MeetingCaptureStartConfiguration {
    let selectedApp: AudioApp?
    let selectedMicrophone: AudioDevice?
    let streamingEnabled: Bool
}

struct MeetingCapturedAudio {
    let micSamples: [Float]
    let micSampleRate: Double
    let systemSamples: [Float]
    let systemSampleRate: Double
    let duration: TimeInterval
    let appName: String?
    var recoveryArtifacts: MeetingRecoveryArtifacts?
}

/// Recovery artifacts for a stopped-but-not-yet-persisted meeting: the
/// autosave transcript plus the original-quality temp audio files. They are
/// cleared only after the meeting is durably persisted (or deliberately
/// discarded), so a crash during finalization or persistence stays
/// recoverable — clearing them any earlier is data loss.
struct MeetingRecoveryArtifacts: Sendable {
    let sessionID: UUID
    let autosaveFileURL: URL
    let micFileURL: URL?
    let systemFileURL: URL?

    /// Delete the temp audio, and the autosave file if it still belongs to
    /// this session (a newer session may own the file by now).
    @MainActor
    func clear() {
        if let micFileURL {
            try? FileManager.default.removeItem(at: micFileURL)
        }
        if let systemFileURL {
            try? FileManager.default.removeItem(at: systemFileURL)
        }
        MeetingTranscriptManager.clearAutoSave(
            matching: sessionID,
            at: autosaveFileURL
        )
    }
}
#endif
