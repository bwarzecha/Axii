//
//  MeetingStopResponsivenessTests.swift
//  AxiiIntegrationTests
//
//  Opt-in (AXII_STOP_REPRO=1): drives the REAL meeting stop chain — raw
//  spool read, MeetingFinalizationService with the real Parakeet models,
//  MeetingPersistenceService + HistoryService — with hour-scale 48kHz
//  tracks, and asserts BOTH bounded completion and a responsive main
//  thread. This is the full-chain tier of the encode-wedge regression
//  coverage (HistoryAudioEncodeRegressionTests is the fast tier): a single
//  whole-track AVAudioFile.write wedged the AAC codec past 512MB of input
//  (~46.6 min @48kHz) and froze the app for the 2026-07-15 hour-long
//  meeting. Requires downloaded models — a local/manual tier, like
//  RealTranscriptionQuirkTests.
//
//  Run (60 min, AAC — the format that wedged):
//    TEST_RUNNER_AXII_STOP_REPRO=1 xcodebuild test \
//      -project Axii.xcodeproj -scheme Axii -destination 'platform=macOS' \
//      -only-testing:AxiiIntegrationTests/MeetingStopResponsivenessTests
//
//  Knobs: AXII_STOP_REPRO_MINUTES (default 60),
//         AXII_STOP_REPRO_FORMAT (alac|aac, default aac),
//         AXII_STOP_REPRO_CLIP (path to a real recording to tile; default
//         synthesizes speech with /usr/bin/say at 48kHz).
//

import AVFoundation
import XCTest
@testable import Axii

@MainActor
final class MeetingStopResponsivenessTests: XCTestCase {

    private static let modelsDirectory = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    ).first!.appendingPathComponent("Axii/Models")

    private static var env: [String: String] { ProcessInfo.processInfo.environment }

    func testHourLongMeetingStopChainStaysResponsive() async throws {
        try XCTSkipUnless(
            Self.env["AXII_STOP_REPRO"] == "1",
            "Opt-in: TEST_RUNNER_AXII_STOP_REPRO=1"
        )
        try XCTSkipUnless(
            FileManager.default.fileExists(
                atPath: Self.modelsDirectory
                    .appendingPathComponent("parakeet-tdt-0.6b-v3-coreml").path
            ),
            "Parakeet models not downloaded"
        )

        let minutes = Int(Self.env["AXII_STOP_REPRO_MINUTES"] ?? "") ?? 60
        let format = AudioStorageFormat(
            rawValue: Self.env["AXII_STOP_REPRO_FORMAT"] ?? "aac"
        ) ?? .aac
        let rate = 48_000.0

        let clip = try sourceClip(rate: rate)
        let track = tile(clip, minutes: minutes, rate: rate)
        let duration = Double(track.count) / rate
        report(String(format: "track: %.1f min @ %.0fHz, %d samples (%.0f MB), format=%@",
                      duration / 60, rate, track.count,
                      Double(track.count * 4) / 1_048_576, format.rawValue))

        // Stage 0: spool round-trip — stop() reads both raw spool files
        // (off the main actor since the 2026-07-15 fix).
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AxiiStopRepro-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let micSpool = tempDir.appendingPathComponent("mic.raw")
        let systemSpool = tempDir.appendingPathComponent("system.raw")
        try track.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: micSpool)
        try track.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: systemSpool)

        let transcription = TranscriptionService()
        try await transcription.prepare(modelsDirectory: Self.modelsDirectory)

        let history = HistoryService(historyDirectory: tempDir.appendingPathComponent("history"))
        history.isEnabled = true
        let persistence = MeetingPersistenceService(historyService: history)
        let finalization = MeetingFinalizationService(transcriptionService: transcription)

        let probe = MainActorStallProbe()
        probe.start()
        let wallStart = Date()

        let readStart = Date()
        let audioManager = MeetingAudioManager()
        let micSamples = await audioManager.readSamplesFromFileOffMain(micSpool)
        let systemSamples = await audioManager.readSamplesFromFileOffMain(systemSpool)
        report(String(format: "spool read x2: %.2fs", Date().timeIntervalSince(readStart)))
        XCTAssertEqual(micSamples.count, track.count, "spool round-trip lost samples")

        let finalizeStart = Date()
        var lastStatus = ""
        var payload = await finalization.finalize(
            input: MeetingFinalizationInput(
                micSamples: micSamples, micSampleRate: rate,
                systemSamples: systemSamples, systemSampleRate: rate,
                duration: duration, appName: "StopRepro"
            ),
            onProgress: { _, status in
                if status != lastStatus {
                    lastStatus = status
                    self.report("finalize status: \(status)")
                }
            }
        )
        report(String(format: "finalize: %.1fs, %d segments",
                      Date().timeIntervalSince(finalizeStart), payload.segments.count))
        XCTAssertFalse(payload.segments.isEmpty, "finalize produced no transcript")

        payload.recoveryArtifacts = nil
        let persistStart = Date()
        let persisted = try await persistence.persist(payload: payload, audioFormat: format)
        report(String(format: "persist (%@): %.1fs", format.rawValue,
                      Date().timeIntervalSince(persistStart)))
        XCTAssertNotNil(persisted, "meeting failed to persist")

        probe.stop()
        let wall = Date().timeIntervalSince(wallStart)
        let stall = probe.maxStallSeconds
        report(String(format: "TOTAL stop chain: %.1fs, longest main-thread stall: %.2fs", wall, stall))

        XCTAssertLessThan(wall, 600, "stop chain took >10 min — encode wedge regressed")
        // The macOS beachball appears around ~2s of blocked main thread.
        XCTAssertLessThan(stall, 2.0, "main thread stalled — stop-path work leaked onto the main actor")
    }

    // MARK: - Fixtures

    /// Decodes AXII_STOP_REPRO_CLIP if provided (any AVAudioFile-readable
    /// format, resampled to `rate` if needed), else synthesizes speech.
    private func sourceClip(rate: Double) throws -> [Float] {
        if let path = Self.env["AXII_STOP_REPRO_CLIP"], !path.isEmpty {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
            )!
            try file.read(into: buffer)
            let samples = Array(UnsafeBufferPointer(
                start: buffer.floatChannelData![0], count: Int(buffer.frameLength)
            ))
            let sourceRate = file.processingFormat.sampleRate
            return sourceRate == rate
                ? samples
                : AudioResampler.resample(samples, from: sourceRate, to: rate)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("axii-stoprepro-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = [
            "-o", url.path, "--data-format=LEF32@48000",
            "The stop chain must survive hour long meetings without freezing the app.",
        ]
        try say.run()
        say.waitUntilExit()
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        )!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(
            start: buffer.floatChannelData![0], count: Int(buffer.frameLength)
        ))
    }

    private func tile(_ clip: [Float], minutes: Int, rate: Double) -> [Float] {
        let target = Int(Double(minutes) * 60 * rate)
        let gap = [Float](repeating: 0, count: Int(rate / 2))
        var result: [Float] = []
        result.reserveCapacity(target + clip.count + gap.count)
        while result.count < target {
            result.append(contentsOf: clip)
            result.append(contentsOf: gap)
        }
        return result
    }

    private func report(_ message: String) {
        // NSLog reaches the xcodebuild log unbuffered — progress stays
        // visible even if the run later wedges.
        NSLog("STOPREPRO %@", message)
    }
}

// MARK: - Main-actor stall probe

/// Measures the longest gap between main-actor turns — a synchronous block
/// on the main thread (the beachball) shows up as one large gap.
@MainActor
private final class MainActorStallProbe {
    private var task: Task<Void, Never>?
    private(set) var maxStallSeconds: Double = 0

    func start() {
        task = Task { @MainActor [weak self] in
            var last = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                let now = Date()
                let gap = now.timeIntervalSince(last) - 0.05
                if let self, gap > self.maxStallSeconds {
                    self.maxStallSeconds = gap
                }
                last = now
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
