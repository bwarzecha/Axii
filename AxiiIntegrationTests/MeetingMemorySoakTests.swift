//
//  MeetingMemorySoakTests.swift
//  AxiiIntegrationTests
//
//  Opt-in soak (AXII_SOAK=1): measures the STOP-TIME memory spike of a
//  long meeting through the REAL finalize + persist path — resample,
//  30s-chunk transcription with the real Parakeet models, and dual-track
//  AAC encoding. A meeting that records for an hour and then dies at Stop
//  from memory pressure is the exact failure this suite exists to prevent,
//  and until this test the spike had never been measured.
//
//  Run:
//    TEST_RUNNER_AXII_SOAK=1 [TEST_RUNNER_AXII_SOAK_MINUTES=60] \
//      xcodebuild test -project Axii.xcodeproj -scheme Axii \
//      -destination 'platform=macOS' \
//      -only-testing:AxiiIntegrationTests/MeetingMemorySoakTests
//

import AVFoundation
import XCTest
@testable import Axii

@MainActor
final class MeetingMemorySoakTests: XCTestCase {

    private static let modelsDirectory = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    ).first!.appendingPathComponent("Axii/Models")

    /// Peak footprint allowed ABOVE the pre-stop baseline. Measured reality
    /// (2026-07-11, 60min x2 tracks): 0.28 GB spike, 0.75 GB peak — the
    /// budget is generous headroom over that, and a regression tripwire.
    private static let spikeBudgetBytes: Int64 = 2 * 1_024 * 1_024 * 1_024

    func testHourLongMeetingStopMemorySpike() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["AXII_SOAK"] == "1",
            "Soak is opt-in: TEST_RUNNER_AXII_SOAK=1"
        )
        try XCTSkipUnless(
            FileManager.default.fileExists(
                atPath: Self.modelsDirectory
                    .appendingPathComponent("parakeet-tdt-0.6b-v3-coreml").path
            ),
            "Parakeet models not downloaded"
        )
        let minutes = Int(
            ProcessInfo.processInfo.environment["AXII_SOAK_MINUTES"] ?? ""
        ) ?? 60

        // Build the two tracks the way a real stop holds them: full-length
        // float arrays. Tiled real speech so the ASR does real work.
        let rate = 16_000.0
        let clip = try speechClip()
        let mic = tile(clip, minutes: minutes, rate: rate)
        let system = tile(clip, minutes: minutes, rate: rate)
        let duration = Double(mic.count) / rate

        let transcription = TranscriptionService()
        try await transcription.prepare(modelsDirectory: Self.modelsDirectory)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AxiiSoak-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let history = HistoryService(historyDirectory: tempDir)
        history.isEnabled = true
        let persistence = MeetingPersistenceService(historyService: history)

        // Measure from here: this is the "user pressed Stop" boundary.
        let sampler = FootprintSampler()
        sampler.start()
        let baseline = FootprintSampler.currentFootprint()

        let finalization = MeetingFinalizationService(
            transcriptionService: transcription
        )
        var payload = await finalization.finalize(
            input: MeetingFinalizationInput(
                micSamples: mic, micSampleRate: rate,
                systemSamples: system, systemSampleRate: rate,
                duration: duration, appName: "SoakTest"
            )
        )
        XCTAssertFalse(payload.segments.isEmpty, "soak produced no transcript")

        payload.recoveryArtifacts = nil
        let persisted = try await persistence.persist(
            payload: payload, audioFormat: .aac
        )
        XCTAssertNotNil(persisted, "soak meeting failed to persist")

        sampler.stop()
        let peak = sampler.peak
        let spike = peak - baseline
        let gigabyte = Double(1_024 * 1_024 * 1_024)
        let report = String(
            format: "SOAK[%dmin x2 tracks] baseline=%.2fGB peak=%.2fGB spike=%.2fGB segments=%d",
            minutes, Double(baseline) / gigabyte, Double(peak) / gigabyte,
            Double(spike) / gigabyte, payload.segments.count
        )
        try report.write(
            to: tempDir.deletingLastPathComponent()
                .appendingPathComponent("axii_soak_report.txt"),
            atomically: true, encoding: .utf8
        )
        XCTAssertLessThan(
            spike, Self.spikeBudgetBytes,
            "stop-time spike exceeded budget: \(report)"
        )
    }

    // MARK: - Fixtures

    private func speechClip() throws -> [Float] {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("axii-soak-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = [
            "-o", url.path, "--data-format=LEF32@16000",
            "The reliability suite verifies that long meetings survive "
                + "their own stop button without exhausting memory.",
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

    private func tile(
        _ clip: [Float], minutes: Int, rate: Double
    ) -> [Float] {
        let target = Int(Double(minutes) * 60 * rate)
        let gap = [Float](repeating: 0, count: Int(rate)) // 1s pause
        var result: [Float] = []
        result.reserveCapacity(target + clip.count + gap.count)
        while result.count < target {
            result.append(contentsOf: clip)
            result.append(contentsOf: gap)
        }
        return result
    }
}

// MARK: - Footprint sampling

/// Samples the process's physical footprint on a background thread —
/// peak capture across the whole stop path, not just checkpoints.
private final class FootprintSampler: @unchecked Sendable {
    private(set) var peak: Int64 = 0
    private var running = false
    private let lock = NSLock()

    func start() {
        lock.lock()
        running = true
        lock.unlock()
        Thread.detachNewThread { [weak self] in
            while true {
                guard let self else { return }
                self.lock.lock()
                let alive = self.running
                self.lock.unlock()
                guard alive else { return }
                let now = Self.currentFootprint()
                self.lock.lock()
                if now > self.peak { self.peak = now }
                self.lock.unlock()
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
    }

    static func currentFootprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size
                / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self, capacity: Int(count)
            ) {
                task_info(
                    mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count
                )
            }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }
}
