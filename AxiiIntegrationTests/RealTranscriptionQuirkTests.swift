//
//  RealTranscriptionQuirkTests.swift
//  AxiiIntegrationTests
//
//  Quirk tests against the REAL FluidAudio/Parakeet models — everything the
//  stub-based suites structurally cannot catch: CoreML inference behavior,
//  the long-audio chunk processor, decoder-state semantics under actor
//  reentrancy, resampling, and hangs (every call is deadline-bounded, so a
//  library stall fails instead of wedging the suite).
//
//  Opt-in and self-skipping: requires AXII_REAL_ASR=1 in the environment AND
//  the app's downloaded models on disk. Run with:
//
//    TEST_RUNNER_AXII_REAL_ASR=1 xcodebuild test \
//      -project Axii.xcodeproj -scheme Axii -destination 'platform=macOS' \
//      -only-testing:AxiiIntegrationTests/RealTranscriptionQuirkTests
//
//  Speech fixtures are synthesized on the fly with /usr/bin/say, so tests
//  can assert actual transcript content without committing audio files.
//

import AVFoundation
import XCTest
@testable import Axii

@MainActor
final class RealTranscriptionQuirkTests: XCTestCase {

    private static let modelsDirectory = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    ).first!.appendingPathComponent("Axii/Models")

    private static var modelsPresent: Bool {
        FileManager.default.fileExists(
            atPath: modelsDirectory
                .appendingPathComponent("parakeet-tdt-0.6b-v3-coreml").path
        )
    }

    private static var optedIn: Bool {
        ProcessInfo.processInfo.environment["AXII_REAL_ASR"] == "1"
    }

    /// One shared, prepared service for the whole class — model load is
    /// seconds, so pay it once.
    private static let sharedService = Task { () throws -> TranscriptionService in
        let service = TranscriptionService()
        try await service.prepare(modelsDirectory: modelsDirectory)
        return service
    }

    private var service: TranscriptionService!

    override func setUp() async throws {
        try XCTSkipUnless(
            Self.optedIn,
            "Real-ASR tests are opt-in: set AXII_REAL_ASR=1 (TEST_RUNNER_AXII_REAL_ASR=1 via xcodebuild)"
        )
        try XCTSkipUnless(Self.modelsPresent, "Parakeet models not downloaded")
        service = try await Self.sharedService.value
    }

    // MARK: - Fixture Synthesis

    /// Renders speech via /usr/bin/say as float32 @ 16 kHz and loads it.
    private func speech(_ text: String) throws -> [Float] {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("axii-asr-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", url.path, "--data-format=LEF32@16000", text]
        try say.run()
        say.waitUntilExit()
        guard say.terminationStatus == 0 else {
            throw NSError(domain: "say", code: Int(say.terminationStatus))
        }
        return try loadSamples(from: url)
    }

    private func loadSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: frameCount
        ) else {
            throw NSError(domain: "fixture", code: 1)
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData else {
            throw NSError(domain: "fixture", code: 2)
        }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
    }

    /// Tiles a clip with silence gaps until it reaches the target duration —
    /// long-audio inputs without long `say` invocations.
    private func tiled(_ clip: [Float], toSeconds seconds: Double) -> [Float] {
        let gap = [Float](repeating: 0, count: 8_000)  // 0.5s
        var result: [Float] = []
        while result.count < Int(seconds * 16_000) {
            result.append(contentsOf: clip)
            result.append(contentsOf: gap)
        }
        return result
    }

    /// Deadline wrapper: a hang in the library is a FINDING, not a wedged
    /// suite.
    private func transcribeBounded(
        _ samples: [Float],
        sampleRate: Double = 16_000,
        deadline: TimeInterval = 90
    ) async throws -> String {
        let service = self.service!
        return try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                try await service.transcribe(samples: samples, sampleRate: sampleRate)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                return nil
            }
            guard let first = try await group.next(), let text = first else {
                group.cancelAll()
                throw NSError(
                    domain: "quirk", code: 408,
                    userInfo: [NSLocalizedDescriptionKey: "transcription exceeded \(deadline)s — library hang"]
                )
            }
            group.cancelAll()
            return text
        }
    }

    // MARK: - Basic Correctness

    func testTranscribesKnownSpeech() async throws {
        let samples = try speech("The quick brown fox jumps over the lazy dog")
        let text = try await transcribeBounded(samples)
        XCTAssertTrue(
            text.lowercased().contains("brown fox"),
            "Expected known phrase in transcript, got: \(text)"
        )
    }

    func testSilenceProducesEmptyOrTrivialTranscript() async throws {
        let silence = [Float](repeating: 0, count: 3 * 16_000)
        let text = try await transcribeBounded(silence)
        XCTAssertLessThan(
            text.count, 20,
            "Silence should not hallucinate a transcript, got: \(text)"
        )
    }

    func testTooShortAudioThrowsInsteadOfHanging() async throws {
        let blip = [Float](repeating: 0.1, count: 3_000)  // ~0.19s
        do {
            _ = try await transcribeBounded(blip)
            XCTFail("Expected tooShort error")
        } catch let error as TranscriptionError {
            XCTAssertEqual(error.errorDescription, TranscriptionError.tooShort.errorDescription)
        }
    }

    // MARK: - Long Audio (FluidAudio ChunkProcessor Path)

    func testLongAudioRoutesThroughChunkProcessorAndCompletes() async throws {
        // >15s at 16kHz crosses ASRConstants.maxModelSamples and exercises
        // FluidAudio's internal chunked path (worker pool, window merging) —
        // the code path a long dictation takes.
        let clip = try speech("Reliability testing catches library quirks early")
        let long = tiled(clip, toSeconds: 40)
        let text = try await transcribeBounded(long, deadline: 180)
        XCTAssertTrue(
            text.lowercased().contains("reliability"),
            "Expected phrase to survive chunked transcription, got: \(text)"
        )
    }

    // MARK: - Concurrency (Real Actor Reentrancy)

    func testConcurrentTranscriptionsDoNotCorruptEachOther() async throws {
        // Interleaved calls at real CoreML await points — the scenario the
        // per-call decoder state exists for (shared state was a
        // use-after-free per the FluidAudio non-reentrancy warning).
        let fox = try speech("The quick brown fox jumps over the lazy dog")
        let sky = try speech("The sky above the harbor was bright blue")
        let silence = [Float](repeating: 0, count: 2 * 16_000)

        async let a = transcribeBounded(fox)
        async let b = transcribeBounded(sky)
        async let c = transcribeBounded(silence)
        async let d = transcribeBounded(fox)
        let (textA, textB, _, textD) = try await (a, b, c, d)

        XCTAssertTrue(textA.lowercased().contains("brown fox"), "got: \(textA)")
        XCTAssertTrue(textB.lowercased().contains("harbor") || textB.lowercased().contains("blue"),
                      "got: \(textB)")
        XCTAssertTrue(textD.lowercased().contains("brown fox"), "got: \(textD)")
    }

    func testRepeatedTranscriptionsStayStable() async throws {
        // Fresh decoder state per call: run N sequential utterances of the
        // same audio and require byte-identical output every time — drift
        // across calls would indicate leaked decoder context.
        //
        // Library quirk (documented by this suite's first run): Parakeet v3
        // applies inverse text normalization, so "one two three" comes back
        // as "123" — assert determinism and recognition, never spelling.
        let samples = try speech("Testing one two three")
        let reference = try await transcribeBounded(samples)
        XCTAssertTrue(
            reference.lowercased().contains("testing"),
            "Expected recognition, got: \(reference)"
        )
        for iteration in 0..<7 {
            let text = try await transcribeBounded(samples)
            XCTAssertEqual(
                text, reference,
                "Iteration \(iteration) drifted from first output"
            )
        }
    }

    // MARK: - Resampling

    func testNonNativeSampleRateIsResampledCorrectly() async throws {
        // Render at 44.1kHz — the mic-native path — and let the service
        // resample to the model's 16kHz.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("axii-asr-441-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", url.path, "--data-format=LEF32@44100",
                         "Resampling should not change the words"]
        try say.run()
        say.waitUntilExit()
        let samples = try loadSamples(from: url)

        let text = try await transcribeBounded(samples, sampleRate: 44_100)
        XCTAssertTrue(
            text.lowercased().contains("words"),
            "Expected phrase after resampling, got: \(text)"
        )
    }

    // MARK: - End-To-End Meeting Finalization

    func testRealMeetingFinalizationProducesLabeledSegments() async throws {
        let clip = try speech("This is the meeting recording reliability check")
        let micTrack = tiled(clip, toSeconds: 35)
        let systemTrack = [Float](repeating: 0, count: 10 * 16_000)

        let finalization = MeetingFinalizationService(transcriptionService: service)
        var finalProgress = 0.0
        let payload = await finalization.finalize(
            input: MeetingFinalizationInput(
                micSamples: micTrack,
                micSampleRate: 16_000,
                systemSamples: systemTrack,
                systemSampleRate: 16_000,
                duration: 35,
                appName: "QuirkTest"
            ),
            onProgress: { progress, _ in finalProgress = progress }
        )

        XCTAssertEqual(finalProgress, 1.0, "Progress must reach done")
        XCTAssertFalse(payload.segments.isEmpty, "Speech track must yield segments")
        XCTAssertTrue(payload.segments.allSatisfy { $0.speakerId == "You" },
                      "Mic-only speech must be labeled as the local speaker")
        let fullText = payload.segments.map(\.text).joined(separator: " ").lowercased()
        XCTAssertTrue(fullText.contains("reliability"),
                      "Expected phrase in finalized transcript, got: \(fullText)")
    }
}
