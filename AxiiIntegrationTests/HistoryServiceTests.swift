//
//  HistoryServiceTests.swift
//  AxiiIntegrationTests
//
//  Integration tests for HistoryService using a real temp directory.
//

import XCTest
@testable import Axii

@MainActor
final class HistoryServiceTests: XCTestCase {

    private var historyService: HistoryService!
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AxiiHistoryTests-\(UUID().uuidString)")
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

    // MARK: - Tests

    func testSaveTranscriptionCreatesFiles() async throws {
        let transcription = Transcription(text: "Hello world from dictation")
        try await historyService.save(.transcription(transcription))

        let metadata = historyService.cache[transcription.id]
        XCTAssertNotNil(metadata, "Metadata should be in cache after save")

        let folderURL = tempDir.appendingPathComponent(metadata!.folderName)
        let metadataFile = folderURL.appendingPathComponent("metadata.json")
        let interactionFile = folderURL.appendingPathComponent("interaction.json")

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: metadataFile.path),
            "metadata.json should exist after save"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: interactionFile.path),
            "interaction.json should exist after save"
        )
    }

    func testLoadTranscriptionRoundTrips() async throws {
        let original = Transcription(
            text: "Round trip transcription test",
            pastedTo: "com.apple.TextEdit"
        )
        try await historyService.save(.transcription(original))

        let loaded = try await historyService.loadInteraction(id: original.id)
        guard case .transcription(let loadedTranscription) = loaded else {
            XCTFail("Expected transcription interaction")
            return
        }

        XCTAssertEqual(loadedTranscription.id, original.id)
        XCTAssertEqual(loadedTranscription.text, original.text)
        XCTAssertEqual(loadedTranscription.pastedTo, original.pastedTo)
    }

    func testSaveConversationRoundTrips() async throws {
        let conversation = Conversation(
            title: "Test Conversation",
            messages: [
                Message(role: .user, content: "What is Swift?"),
                Message(role: .assistant, content: "Swift is a programming language."),
            ]
        )
        try await historyService.save(.conversation(conversation))

        let loaded = try await historyService.loadInteraction(id: conversation.id)
        guard case .conversation(let loadedConversation) = loaded else {
            XCTFail("Expected conversation interaction")
            return
        }

        XCTAssertEqual(loadedConversation.id, conversation.id)
        XCTAssertEqual(loadedConversation.title, conversation.title)
        XCTAssertEqual(loadedConversation.messages.count, 2)
        XCTAssertEqual(loadedConversation.messages[0].content, "What is Swift?")
    }

    func testSaveMeetingRoundTrips() async throws {
        let segments = [
            MeetingSegment(
                text: "Welcome everyone",
                speakerId: "You",
                isFromMicrophone: true,
                startTime: 0,
                endTime: 5.0
            ),
            MeetingSegment(
                text: "Thanks for having me",
                speakerId: "Remote",
                isFromMicrophone: false,
                startTime: 5.0,
                endTime: 10.0
            ),
        ]
        let meeting = Meeting(
            segments: segments,
            duration: 60.0,
            appName: "Zoom"
        )
        try await historyService.save(.meeting(meeting))

        let loaded = try await historyService.loadInteraction(id: meeting.id)
        guard case .meeting(let loadedMeeting) = loaded else {
            XCTFail("Expected meeting interaction")
            return
        }

        XCTAssertEqual(loadedMeeting.id, meeting.id)
        XCTAssertEqual(loadedMeeting.segments.count, 2)
        XCTAssertEqual(loadedMeeting.duration, 60.0)
        XCTAssertEqual(loadedMeeting.appName, "Zoom")
    }

    func testSaveAudioCreatesFile() async throws {
        let transcription = Transcription(text: "Audio test")
        try await historyService.save(.transcription(transcription))

        let samples = [Float](repeating: 0.5, count: 16000)
        let recording = try await historyService.saveAudio(
            samples: samples,
            sampleRate: 16000,
            for: transcription.id
        )

        XCTAssertEqual(recording.duration, 1.0, accuracy: 0.01)
        XCTAssertEqual(recording.sampleRate, 16000)

        let audioURL = historyService.getAudioURL(recording, for: transcription.id)
        XCTAssertNotNil(audioURL)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: audioURL!.path),
            "Audio WAV file should exist on disk"
        )
    }

    func testDeleteRemovesFolderAndCache() async throws {
        let transcription = Transcription(text: "Delete me")
        try await historyService.save(.transcription(transcription))

        XCTAssertNotNil(historyService.cache[transcription.id])

        let metadata = historyService.cache[transcription.id]!
        let folderURL = tempDir.appendingPathComponent(metadata.folderName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folderURL.path))

        try await historyService.delete(id: transcription.id)

        XCTAssertNil(historyService.cache[transcription.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folderURL.path))
    }

    func testListMetadataSortsNewestFirst() async throws {
        let date1 = Date(timeIntervalSince1970: 1_000_000)
        let date2 = Date(timeIntervalSince1970: 2_000_000)
        let date3 = Date(timeIntervalSince1970: 3_000_000)

        let t1 = Transcription(text: "Oldest", createdAt: date1)
        let t2 = Transcription(text: "Middle", createdAt: date2)
        let t3 = Transcription(text: "Newest", createdAt: date3)

        try await historyService.save(.transcription(t1))
        try await historyService.save(.transcription(t2))
        try await historyService.save(.transcription(t3))

        let list = historyService.listMetadata()

        XCTAssertEqual(list.count, 3)
        XCTAssertEqual(list[0].id, t3.id, "Newest should be first")
        XCTAssertEqual(list[1].id, t2.id, "Middle should be second")
        XCTAssertEqual(list[2].id, t1.id, "Oldest should be last")
    }
}
