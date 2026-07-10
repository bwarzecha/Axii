//
//  MeetingRetranscriptionServiceTests.swift
//  AxiiIntegrationTests
//
//  Contract tests for re-transcribing a stored meeting from its audio:
//  - rebuilds the transcript from real stored (compressed) audio
//  - preserves the meeting's identity and recordings
//  - never replaces an existing transcript with nothing
//

import XCTest
@testable import Axii

@MainActor
final class MeetingRetranscriptionServiceTests: XCTestCase {

    private var historyService: HistoryService!
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AxiiRetranscribe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        historyService = HistoryService(historyDirectory: tempDir)
    }

    override func tearDown() async throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        historyService = nil
        tempDir = nil
    }

    private actor StubTranscriber: TranscriptionProviding {
        let text: String
        init(text: String) { self.text = text }
        var isReady: Bool { true }
        func prepare() async throws {}
        func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
            text
        }
    }

    /// Loud sine so finalization's silence gate never skips the chunk.
    /// 44.1 kHz: the AAC encoder rejects its fixed bitrate at 16 kHz input.
    private func tone(seconds: Double, sampleRate: Double = 44_100) -> [Float] {
        (0..<Int(seconds * sampleRate)).map { i in
            Float(sin(Double(i) * 2.0 * .pi * 440.0 / sampleRate) * 0.5)
        }
    }

    /// A meeting persisted for real: compressed audio on disk, record in
    /// history — exactly what an auto-saved meeting looks like.
    private func persistMeeting(
        segments: [MeetingSegment]
    ) async throws -> Meeting {
        let service = MeetingPersistenceService(historyService: historyService)
        let persisted = try await service.persist(
            payload: MeetingPersistencePayload(
                micSamples: tone(seconds: 2),
                micSampleRate: 44_100,
                systemSamples: [],
                systemSampleRate: 0,
                segments: segments,
                duration: 2,
                appName: "Zoom"
            ),
            audioFormat: .aac
        )
        return try XCTUnwrap(persisted)
    }

    private func makeService(text: String) -> MeetingRetranscriptionService {
        MeetingRetranscriptionService(
            transcriptionService: StubTranscriber(text: text),
            historyService: historyService
        )
    }

    func testRebuildsTranscriptFromStoredAudioAndPersists() async throws {
        let meeting = try await persistMeeting(segments: [])
        XCTAssertNotNil(meeting.micRecording)

        var progressCalls = 0
        let updated = try await makeService(text: "hello world")
            .retranscribe(meeting) { _, _ in progressCalls += 1 }

        XCTAssertEqual(updated.id, meeting.id, "Identity must be preserved")
        XCTAssertEqual(
            updated.createdAt.timeIntervalSince1970,
            meeting.createdAt.timeIntervalSince1970,
            accuracy: 1.0
        )
        XCTAssertEqual(updated.segments.map(\.text), ["hello world"])
        XCTAssertEqual(updated.segments.first?.speakerId, "You")
        XCTAssertEqual(updated.micRecording?.id, meeting.micRecording?.id,
                       "Recordings are kept, never re-encoded")
        XCTAssertGreaterThan(progressCalls, 0)

        // Durable: the reloaded record carries the new transcript.
        let reloaded = try await historyService.loadInteraction(id: meeting.id)
        guard case .meeting(let fromDisk) = reloaded else {
            return XCTFail("Expected meeting")
        }
        XCTAssertEqual(fromDisk.segments.map(\.text), ["hello world"])
        XCTAssertEqual(historyService.listMetadata(type: .meeting).count, 1,
                       "In-place update, not a duplicate entry")
    }

    /// A re-run that hears nothing must not destroy the only transcript the
    /// meeting has.
    func testEmptyResultKeepsExistingTranscript() async throws {
        let existing = MeetingSegment(
            text: "precious", speakerId: "You",
            isFromMicrophone: true, startTime: 0, endTime: 1
        )
        let meeting = try await persistMeeting(segments: [existing])

        do {
            _ = try await makeService(text: "").retranscribe(meeting)
            XCTFail("Expected producedEmptyTranscript")
        } catch let error as MeetingRetranscriptionError {
            guard case .producedEmptyTranscript = error else {
                return XCTFail("Wrong error: \(error)")
            }
        }

        let reloaded = try await historyService.loadInteraction(id: meeting.id)
        guard case .meeting(let fromDisk) = reloaded else {
            return XCTFail("Expected meeting")
        }
        XCTAssertEqual(fromDisk.segments.map(\.text), ["precious"],
                       "The stored transcript survives a no-speech re-run")
    }

    func testMeetingWithoutAudioThrows() async throws {
        let meeting = Meeting(segments: [], duration: 10)

        do {
            _ = try await makeService(text: "hello").retranscribe(meeting)
            XCTFail("Expected noAudio")
        } catch let error as MeetingRetranscriptionError {
            guard case .noAudio = error else {
                return XCTFail("Wrong error: \(error)")
            }
        }
    }

    private actor GatedTranscriber: TranscriptionProviding {
        private(set) var started = false
        private var continuation: CheckedContinuation<Void, Never>?
        var isReady: Bool { true }
        func prepare() async throws {}
        func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
            started = true
            await withCheckedContinuation { continuation = $0 }
            return "hello"
        }
        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    /// Deleting the meeting while a long retranscription runs must not
    /// resurrect it as a zombie record pointing at removed audio files.
    func testMeetingDeletedMidRunIsNotResurrected() async throws {
        let meeting = try await persistMeeting(segments: [])
        let gated = GatedTranscriber()
        let service = MeetingRetranscriptionService(
            transcriptionService: gated,
            historyService: historyService
        )

        let run = Task { try await service.retranscribe(meeting) }
        var spins = 0
        while await !gated.started, spins < 10_000 {
            await Task.yield()
            spins += 1
        }

        // The user deletes the meeting while transcription is mid-flight.
        try await historyService.delete(id: meeting.id)
        await gated.release()

        do {
            _ = try await run.value
            XCTFail("Expected meetingDeleted")
        } catch let error as MeetingRetranscriptionError {
            guard case .meetingDeleted = error else {
                return XCTFail("Wrong error: \(error)")
            }
        }
        XCTAssertTrue(historyService.listMetadata(type: .meeting).isEmpty,
                      "The deleted meeting stays deleted")
    }

    func testHistoryDisabledSurfacesInsteadOfPretendingSuccess() async throws {
        let meeting = try await persistMeeting(segments: [])
        historyService.isEnabled = false

        do {
            _ = try await makeService(text: "hello").retranscribe(meeting)
            XCTFail("Expected historyDisabled")
        } catch let error as MeetingRetranscriptionError {
            guard case .historyDisabled = error else {
                return XCTFail("Wrong error: \(error)")
            }
        }
    }
}
