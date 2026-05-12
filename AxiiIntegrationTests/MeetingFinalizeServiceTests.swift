//
//  MeetingFinalizeServiceTests.swift
//  AxiiIntegrationTests
//
//  Service-level tests for MeetingFinalizationService.
//  Owns the finalization behavior matrix: source labels, resampling,
//  30s chunking, silent-chunk skipping, per-chunk error tolerance,
//  sort/merge, and progress reporting.
//

import XCTest
@testable import Axii

@MainActor
final class MeetingFinalizeServiceTests: XCTestCase {

    // MARK: - Fakes

    /// Records every transcription call. Returns a deterministic label so tests
    /// can assert sample count, sample rate, and call ordering.
    private actor RecordingTranscriber: TranscriptionProviding {
        struct Call: Sendable {
            let sampleCount: Int
            let sampleRate: Double
        }

        private(set) var calls: [Call] = []
        private let producer: @Sendable (Int) -> String

        var isReady: Bool { true }
        func prepare() async throws {}

        init(text: String = "ok") {
            self.producer = { _ in text }
        }

        init(producer: @escaping @Sendable (Int) -> String) {
            self.producer = producer
        }

        func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
            calls.append(Call(sampleCount: samples.count, sampleRate: sampleRate))
            return producer(calls.count)
        }

        func snapshotCalls() -> [Call] { calls }
    }

    /// Always throws — used to verify per-chunk error tolerance.
    private actor FailingTranscriber: TranscriptionProviding {
        var isReady: Bool { true }
        func prepare() async throws {}
        func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
            throw NSError(domain: "test", code: 1)
        }
    }

    /// Throws on a specific call index — used to verify non-failing chunks
    /// still produce segments.
    private actor SometimesFailingTranscriber: TranscriptionProviding {
        private(set) var callIndex = 0
        private let failOn: Int

        init(failOn: Int) { self.failOn = failOn }

        var isReady: Bool { true }
        func prepare() async throws {}
        func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
            callIndex += 1
            if callIndex == failOn {
                throw NSError(domain: "test", code: 1)
            }
            return "chunk-\(callIndex)"
        }
    }

    // MARK: - Helpers

    /// Sine wave samples at the requested sample rate. Non-silent.
    private func tone(seconds: Double, sampleRate: Double = 16000) -> [Float] {
        let count = Int(seconds * sampleRate)
        return (0..<count).map { i in
            Float(sin(Double(i) * 2.0 * .pi * 440.0 / sampleRate) * 0.5)
        }
    }

    /// Silent samples (zeros).
    private func silence(seconds: Double, sampleRate: Double = 16000) -> [Float] {
        Array(repeating: Float(0), count: Int(seconds * sampleRate))
    }

    private func makeInput(
        micSamples: [Float] = [],
        micSampleRate: Double = 16000,
        systemSamples: [Float] = [],
        systemSampleRate: Double = 16000,
        duration: TimeInterval = 60,
        appName: String? = "Zoom"
    ) -> MeetingFinalizationInput {
        MeetingFinalizationInput(
            micSamples: micSamples,
            micSampleRate: micSampleRate,
            systemSamples: systemSamples,
            systemSampleRate: systemSampleRate,
            duration: duration,
            appName: appName
        )
    }

    // MARK: - Source Labels

    func testMicOnly_ProducesYouSegmentsFromMicrophone() async {
        let transcriber = RecordingTranscriber(text: "hi")
        let service = MeetingFinalizationService(transcriptionService: transcriber)

        let payload = await service.finalize(input: makeInput(
            micSamples: tone(seconds: 10),
            systemSamples: []
        ))

        XCTAssertFalse(payload.segments.isEmpty)
        for segment in payload.segments {
            XCTAssertEqual(segment.speakerId, "You")
            XCTAssertTrue(segment.isFromMicrophone)
        }
    }

    func testSystemOnly_ProducesRemoteSegmentsNotFromMicrophone() async {
        let transcriber = RecordingTranscriber(text: "hello")
        let service = MeetingFinalizationService(transcriptionService: transcriber)

        let payload = await service.finalize(input: makeInput(
            micSamples: [],
            systemSamples: tone(seconds: 10)
        ))

        XCTAssertFalse(payload.segments.isEmpty)
        for segment in payload.segments {
            XCTAssertEqual(segment.speakerId, "Remote")
            XCTAssertFalse(segment.isFromMicrophone)
        }
    }

    func testBothTracks_PreservesSourceLabels() async {
        let transcriber = RecordingTranscriber(text: "x")
        let service = MeetingFinalizationService(transcriptionService: transcriber)

        let payload = await service.finalize(input: makeInput(
            micSamples: tone(seconds: 10),
            systemSamples: tone(seconds: 10)
        ))

        let youSegments = payload.segments.filter { $0.speakerId == "You" }
        let remoteSegments = payload.segments.filter { $0.speakerId == "Remote" }
        XCTAssertFalse(youSegments.isEmpty, "Should have at least one You segment")
        XCTAssertFalse(remoteSegments.isEmpty, "Should have at least one Remote segment")
        for segment in youSegments { XCTAssertTrue(segment.isFromMicrophone) }
        for segment in remoteSegments { XCTAssertFalse(segment.isFromMicrophone) }
    }

    // MARK: - Empty Input

    func testEmptyAudio_ReturnsPayloadWithNoSegmentsButPreservesEnvelope() async {
        let transcriber = RecordingTranscriber()
        let service = MeetingFinalizationService(transcriptionService: transcriber)

        let payload = await service.finalize(input: makeInput(
            micSamples: [], micSampleRate: 44100,
            systemSamples: [], systemSampleRate: 48000,
            duration: 42, appName: "FaceTime"
        ))

        XCTAssertTrue(payload.segments.isEmpty)
        XCTAssertEqual(payload.duration, 42)
        XCTAssertEqual(payload.appName, "FaceTime")
        XCTAssertEqual(payload.micSampleRate, 44100)
        XCTAssertEqual(payload.systemSampleRate, 48000)
        XCTAssertTrue(payload.micSamples.isEmpty)
        XCTAssertTrue(payload.systemSamples.isEmpty)
    }

    // MARK: - Resampling

    func testNon16kInput_IsResampledTo16kForTranscription() async {
        let transcriber = RecordingTranscriber(text: "x")
        let service = MeetingFinalizationService(transcriptionService: transcriber)

        // 1 second at 44100 Hz, non-silent
        _ = await service.finalize(input: makeInput(
            micSamples: tone(seconds: 1, sampleRate: 44100),
            micSampleRate: 44100
        ))

        let calls = await transcriber.snapshotCalls()
        XCTAssertFalse(calls.isEmpty, "Expected at least one transcription call")
        for call in calls {
            XCTAssertEqual(call.sampleRate, 16000, "Transcription must receive 16kHz audio")
        }
    }

    func test16kInput_IsPassedThroughAt16k() async {
        let transcriber = RecordingTranscriber(text: "x")
        let service = MeetingFinalizationService(transcriptionService: transcriber)

        // 5 seconds at 16kHz so we get one chunk (< 30s).
        let samples = tone(seconds: 5, sampleRate: 16000)
        _ = await service.finalize(input: makeInput(
            micSamples: samples, micSampleRate: 16000
        ))

        let calls = await transcriber.snapshotCalls()
        XCTAssertEqual(calls.count, 1, "Expected exactly one chunk for 5s at 16kHz")
        XCTAssertEqual(calls.first?.sampleRate, 16000)
        XCTAssertEqual(calls.first?.sampleCount, samples.count)
    }

    // MARK: - 30-Second Chunking

    func test30SecondChunking_IsPreserved() async {
        let transcriber = RecordingTranscriber(text: "x")
        let service = MeetingFinalizationService(transcriptionService: transcriber)

        // 65 seconds at 16kHz should chunk into [30s, 30s, 5s] = 3 chunks
        let samples = tone(seconds: 65, sampleRate: 16000)
        _ = await service.finalize(input: makeInput(
            micSamples: samples, micSampleRate: 16000
        ))

        let calls = await transcriber.snapshotCalls()
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls[0].sampleCount, 30 * 16000)
        XCTAssertEqual(calls[1].sampleCount, 30 * 16000)
        XCTAssertEqual(calls[2].sampleCount, 5 * 16000)
    }

    // MARK: - Silent Chunk Skipping

    func testSilentChunks_AreSkipped() async {
        let transcriber = RecordingTranscriber(text: "x")
        let service = MeetingFinalizationService(transcriptionService: transcriber)

        // All-zero samples — every chunk has max amplitude 0, < 0.001 threshold
        let samples = silence(seconds: 65, sampleRate: 16000)
        let payload = await service.finalize(input: makeInput(
            micSamples: samples, micSampleRate: 16000
        ))

        let calls = await transcriber.snapshotCalls()
        XCTAssertEqual(calls.count, 0, "Silent chunks must not be transcribed")
        XCTAssertTrue(payload.segments.isEmpty, "No segments expected from pure silence")
    }

    // MARK: - Per-Chunk Error Tolerance

    func testPerChunkTranscriptionFailure_DoesNotFailFinalization() async {
        let transcriber = FailingTranscriber()
        let service = MeetingFinalizationService(transcriptionService: transcriber)

        let payload = await service.finalize(input: makeInput(
            micSamples: tone(seconds: 10),
            systemSamples: tone(seconds: 10)
        ))

        // Service must complete and return a payload, even though all
        // transcription attempts threw.
        XCTAssertTrue(payload.segments.isEmpty,
                       "Failed chunks should produce no segments, not crash")
        XCTAssertEqual(payload.duration, 60)
    }

    func testOneFailingChunk_StillProducesSegmentsForOthers() async {
        let transcriber = SometimesFailingTranscriber(failOn: 1)
        let service = MeetingFinalizationService(transcriptionService: transcriber)

        // 65s = 3 chunks mic + 0 system. First throws, next two succeed.
        let payload = await service.finalize(input: makeInput(
            micSamples: tone(seconds: 65, sampleRate: 16000),
            micSampleRate: 16000
        ))

        XCTAssertFalse(payload.segments.isEmpty,
                       "Surviving chunks should produce segments")
    }

    // MARK: - Sort + Merge

    func testConsecutiveSameSpeakerSegments_AreMerged() async {
        let transcriber = RecordingTranscriber(text: "x")
        let service = MeetingFinalizationService(transcriptionService: transcriber)

        // 65s mic → 3 chunks → 3 You segments. After merge they collapse to 1.
        let payload = await service.finalize(input: makeInput(
            micSamples: tone(seconds: 65, sampleRate: 16000),
            micSampleRate: 16000
        ))

        let youSegments = payload.segments.filter { $0.speakerId == "You" }
        XCTAssertEqual(youSegments.count, 1,
                       "Consecutive You chunks must merge into one segment")
    }

    func testSegments_AreSortedByStartTime() async {
        let transcriber = RecordingTranscriber(text: "x")
        let service = MeetingFinalizationService(transcriptionService: transcriber)

        // Both tracks 65s → mic [0-30, 30-60, 60-65], system [0-30, 30-60, 60-65].
        // After mic→system processing and sort, consecutive segments by start time
        // alternating could merge. Either way result must be sorted.
        let payload = await service.finalize(input: makeInput(
            micSamples: tone(seconds: 65, sampleRate: 16000),
            micSampleRate: 16000,
            systemSamples: tone(seconds: 65, sampleRate: 16000),
            systemSampleRate: 16000
        ))

        let starts = payload.segments.map { $0.startTime }
        XCTAssertEqual(starts, starts.sorted(),
                       "Segments must be sorted by startTime after finalization")
    }

    // MARK: - Progress

    func testProgressReachesDoneAtCompletion() async {
        let transcriber = RecordingTranscriber(text: "x")
        let service = MeetingFinalizationService(transcriptionService: transcriber)

        var lastProgress: Double = -1
        var lastStatus: String = ""
        service.onProgressUpdated = { progress, status in
            lastProgress = progress
            lastStatus = status
        }

        _ = await service.finalize(input: makeInput(
            micSamples: tone(seconds: 5, sampleRate: 16000),
            micSampleRate: 16000
        ))

        XCTAssertEqual(lastProgress, 1.0, "Final progress must be 1.0")
        XCTAssertEqual(lastStatus, "Done", "Final status must be 'Done'")
    }
}
