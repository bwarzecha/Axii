//
//  MeetingSaveRegressionTests.swift
//  AxiiIntegrationTests
//
//  Regression tests capturing the known meeting-save bug where audio files
//  are saved to disk but the AudioRecording values are discarded, leaving
//  the Meeting metadata without recording references.
//

import XCTest
@testable import Axii

@MainActor
final class MeetingSaveRegressionTests: XCTestCase {

    private var historyService: HistoryService!
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AxiiMeetingSaveTests-\(UUID().uuidString)")
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

    // MARK: - Regression: Known Bug

    /// Regression test: meeting audio is saved to disk but not attached to Meeting metadata.
    /// This captures the known bug in ModeFeatureMeeting.saveMeetingToHistory.
    ///
    /// The buggy flow:
    /// 1. Creates a Meeting without micRecording/systemRecording
    /// 2. Saves it to history
    /// 3. Calls saveAudio which returns AudioRecording values
    /// 4. Discards the returned AudioRecording values (never updates the Meeting)
    func testMeetingSaveAudioNotAttachedToMeeting_KnownBug() async throws {
        let segments = [
            MeetingSegment(
                text: "Hello from mic",
                speakerId: "You",
                isFromMicrophone: true,
                startTime: 0,
                endTime: 5.0
            ),
            MeetingSegment(
                text: "Hello from remote",
                speakerId: "Remote",
                isFromMicrophone: false,
                startTime: 5.0,
                endTime: 10.0
            ),
        ]

        // Simulate the buggy save flow from ModeFeatureMeeting.saveMeetingToHistory:
        // Meeting is created WITHOUT micRecording/systemRecording
        let meeting = Meeting(
            segments: segments,
            duration: 60.0,
            appName: "Zoom"
        )
        try await historyService.save(.meeting(meeting))

        // Audio is saved to disk (succeeds), but result is discarded with `_ =`
        let micRecording = try await historyService.saveAudio(
            samples: [Float](repeating: 0.1, count: 16000),
            sampleRate: 16000,
            for: meeting.id
        )
        XCTAssertNotNil(micRecording, "Audio file should be created on disk")

        let systemRecording = try await historyService.saveAudio(
            samples: [Float](repeating: 0.2, count: 16000),
            sampleRate: 16000,
            for: meeting.id
        )
        XCTAssertNotNil(systemRecording, "System audio file should be created on disk")

        // Verify audio files exist on disk
        let micURL = historyService.getAudioURL(micRecording, for: meeting.id)
        XCTAssertNotNil(micURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: micURL!.path))

        let systemURL = historyService.getAudioURL(systemRecording, for: meeting.id)
        XCTAssertNotNil(systemURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: systemURL!.path))

        // Load back and verify the bug: meeting has no recording metadata
        let loaded = try await historyService.loadInteraction(id: meeting.id)
        guard case .meeting(let loadedMeeting) = loaded else {
            XCTFail("Expected meeting interaction")
            return
        }

        // These assertions capture the BUG: recordings are nil because they
        // were never attached to the Meeting before saving
        XCTAssertNil(
            loadedMeeting.micRecording,
            "Known bug: mic audio saved but not attached to Meeting"
        )
        XCTAssertNil(
            loadedMeeting.systemRecording,
            "Known bug: system audio saved but not attached to Meeting"
        )
    }

    // MARK: - Fixed Version

    /// Shows what correct behavior looks like: audio recordings are attached
    /// to the Meeting metadata before the final save.
    func testMeetingSaveWithAudioAttached_CorrectBehavior() async throws {
        let segments = [
            MeetingSegment(
                text: "Hello from mic",
                speakerId: "You",
                isFromMicrophone: true,
                startTime: 0,
                endTime: 5.0
            ),
            MeetingSegment(
                text: "Hello from remote",
                speakerId: "Remote",
                isFromMicrophone: false,
                startTime: 5.0,
                endTime: 10.0
            ),
        ]

        // Step 1: Save initial meeting (needed so saveAudio can find the cache entry)
        let initialMeeting = Meeting(
            segments: segments,
            duration: 60.0,
            appName: "Zoom"
        )
        try await historyService.save(.meeting(initialMeeting))

        // Step 2: Save audio files
        let micRecording = try await historyService.saveAudio(
            samples: [Float](repeating: 0.1, count: 16000),
            sampleRate: 16000,
            for: initialMeeting.id
        )

        let systemRecording = try await historyService.saveAudio(
            samples: [Float](repeating: 0.2, count: 16000),
            sampleRate: 16000,
            for: initialMeeting.id
        )

        // Step 3: CORRECT: Create updated Meeting WITH recording references and re-save
        let updatedMeeting = Meeting(
            id: initialMeeting.id,
            segments: segments,
            duration: 60.0,
            micRecording: micRecording,
            systemRecording: systemRecording,
            appName: "Zoom",
            createdAt: initialMeeting.createdAt
        )
        try await historyService.save(.meeting(updatedMeeting))

        // Step 4: Load back and verify recordings are attached
        let loaded = try await historyService.loadInteraction(id: initialMeeting.id)
        guard case .meeting(let loadedMeeting) = loaded else {
            XCTFail("Expected meeting interaction")
            return
        }

        XCTAssertNotNil(
            loadedMeeting.micRecording,
            "Mic recording should be attached after correct save"
        )
        XCTAssertNotNil(
            loadedMeeting.systemRecording,
            "System recording should be attached after correct save"
        )
        if let micDuration = loadedMeeting.micRecording?.duration {
            XCTAssertEqual(micDuration, 1.0, accuracy: 0.01)
        }
        if let sysDuration = loadedMeeting.systemRecording?.duration {
            XCTAssertEqual(sysDuration, 1.0, accuracy: 0.01)
        }
    }
}
