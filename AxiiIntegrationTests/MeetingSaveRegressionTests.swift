//
//  MeetingSaveRegressionTests.swift
//  AxiiIntegrationTests
//
//  Regression tests capturing the known meeting-save bug where audio files
//  are saved to disk but the AudioRecording values are discarded, leaving
//  the Meeting metadata without recording references.
//
//  These tests exercise the real ModeFeature.saveMeetingToHistory method.
//

import XCTest
@testable import Axii

@MainActor
final class MeetingSaveRegressionTests: XCTestCase {

    private var historyService: HistoryService!
    private var settings: SettingsService!
    private var modeFeature: ModeFeature!
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AxiiMeetingSaveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        historyService = HistoryService(historyDirectory: tempDir)

        let defaults = UserDefaults(suiteName: "MeetingSaveTest-\(UUID().uuidString)")!
        settings = SettingsService(defaults: defaults)

        // Create a minimal ModeFeature to call saveMeetingToHistory.
        // Use a simple dictation config — the method only needs historyService and settings.
        let config = DefaultModes.dictation()
        let fakeTranscriber = StubTranscriber()
        let fakePaste = StubPasteProvider()

        modeFeature = ModeFeature(
            config: config,
            transcriptionService: fakeTranscriber,
            micPermission: MicrophonePermissionService(),
            pasteService: fakePaste,
            clipboardService: ClipboardService(),
            settings: settings,
            historyService: historyService,
            mediaControlService: MediaControlService()
        )
    }

    override func tearDown() async throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        modeFeature = nil
        historyService = nil
        settings = nil
        tempDir = nil
    }

    // MARK: - Helpers

    private actor StubTranscriber: TranscriptionProviding {
        var isReady: Bool { true }
        func prepare() async throws {}
        func transcribe(samples: [Float], sampleRate: Double) async throws -> String { "" }
    }

    private final class StubPasteProvider: PasteProviding {
        func paste(text: String, focusSnapshot: FocusSnapshot?, finishBehavior: FinishBehavior, failureBehavior: InsertionFailureBehavior) async -> PasteService.Outcome { .skipped }
    }

    /// Synthetic sine-wave samples for AAC encoding (constant buffers can fail).
    private func syntheticSamples(count: Int, sampleRate: Double = 44100) -> [Float] {
        (0..<count).map { i in
            Float(sin(Double(i) * 2.0 * .pi * 440.0 / sampleRate) * 0.5)
        }
    }

    // MARK: - Regression: Known Bug via Real Production Path

    /// Exercises the real ModeFeature.saveMeetingToHistory and demonstrates
    /// that audio files are saved to disk but not attached to the Meeting.
    func testSaveMeetingToHistory_KnownBug_AudioNotAttached() async throws {
        let sampleRate: Double = 44100
        let result = MeetingStopResult(
            micSamples: syntheticSamples(count: Int(sampleRate), sampleRate: sampleRate),
            micSampleRate: sampleRate,
            systemSamples: syntheticSamples(count: Int(sampleRate), sampleRate: sampleRate),
            systemSampleRate: sampleRate,
            segments: [
                MeetingSegment(text: "Hello from mic", speakerId: "You",
                               isFromMicrophone: true, startTime: 0, endTime: 5),
                MeetingSegment(text: "Hello from remote", speakerId: "Remote",
                               isFromMicrophone: false, startTime: 5, endTime: 10),
            ],
            duration: 60.0,
            appName: "Zoom"
        )

        // Call the real production method
        await modeFeature.saveMeetingToHistory(result)

        // Find the saved meeting in the cache
        let meetings = historyService.listMetadata(type: .meeting)
        XCTAssertEqual(meetings.count, 1, "One meeting should be saved")

        let meetingId = meetings.first!.id
        let loaded = try await historyService.loadInteraction(id: meetingId)
        guard case .meeting(let loadedMeeting) = loaded else {
            XCTFail("Expected meeting interaction")
            return
        }

        // Verify segments and duration were saved correctly
        XCTAssertEqual(loadedMeeting.segments.count, 2)
        XCTAssertEqual(loadedMeeting.duration, 60.0)
        XCTAssertEqual(loadedMeeting.appName, "Zoom")

        // BUG: Audio files exist on disk but are NOT attached to the Meeting.
        // The saveMeetingToHistory method discards the AudioRecording return values.
        XCTAssertNil(
            loadedMeeting.micRecording,
            "Known bug: mic audio saved to disk but not attached to Meeting"
        )
        XCTAssertNil(
            loadedMeeting.systemRecording,
            "Known bug: system audio saved to disk but not attached to Meeting"
        )

        // Verify the audio files DO exist on disk (orphaned)
        let metadata = historyService.cache[meetingId]!
        let folderURL = tempDir.appendingPathComponent(metadata.folderName)
        let audioDir = folderURL.appendingPathComponent("audio")
        if FileManager.default.fileExists(atPath: audioDir.path) {
            let audioFiles = try FileManager.default.contentsOfDirectory(
                at: audioDir, includingPropertiesForKeys: nil
            )
            XCTAssertEqual(
                audioFiles.count, 2,
                "Two audio files should be orphaned on disk"
            )
        }
    }

    /// Uses compressed audio (AAC) like the real meeting flow does.
    func testSaveMeetingToHistory_UsesCompressedAudio() async throws {
        // Set AAC format (matches real meeting behavior)
        settings.setAudioStorageFormat(.aac)

        let sampleRate: Double = 44100
        let result = MeetingStopResult(
            micSamples: syntheticSamples(count: Int(sampleRate), sampleRate: sampleRate),
            micSampleRate: sampleRate,
            systemSamples: syntheticSamples(count: Int(sampleRate), sampleRate: sampleRate),
            systemSampleRate: sampleRate,
            segments: [
                MeetingSegment(text: "Test", speakerId: "You",
                               isFromMicrophone: true, startTime: 0, endTime: 5),
            ],
            duration: 30.0,
            appName: "FaceTime"
        )

        await modeFeature.saveMeetingToHistory(result)

        // Verify the compressed audio files were created
        let meetings = historyService.listMetadata(type: .meeting)
        XCTAssertEqual(meetings.count, 1)

        let metadata = meetings.first!
        let folderURL = tempDir.appendingPathComponent(metadata.folderName)
        let audioDir = folderURL.appendingPathComponent("audio")

        XCTAssertTrue(FileManager.default.fileExists(atPath: audioDir.path),
                       "Audio directory should exist")

        let audioFiles = try FileManager.default.contentsOfDirectory(
            at: audioDir, includingPropertiesForKeys: nil
        )
        XCTAssertEqual(audioFiles.count, 2, "Mic + system audio files")

        // All files should be .m4a (compressed)
        for file in audioFiles {
            XCTAssertEqual(file.pathExtension, "m4a",
                           "Compressed audio should use .m4a extension")
        }
    }

    // MARK: - Correct Behavior Reference

    /// Shows what the fix should produce: Meeting with recordings attached.
    func testMeetingSaveWithAudioAttached_CorrectBehavior() async throws {
        let segments = [
            MeetingSegment(text: "Hello", speakerId: "You",
                           isFromMicrophone: true, startTime: 0, endTime: 5),
        ]

        // Manually perform the correct save flow
        let meeting = Meeting(segments: segments, duration: 60.0, appName: "Zoom")
        try await historyService.save(.meeting(meeting))

        let sampleRate: Double = 44100
        let micRecording = try await historyService.saveAudioCompressed(
            samples: syntheticSamples(count: Int(sampleRate), sampleRate: sampleRate),
            sampleRate: sampleRate, format: .aac, for: meeting.id
        )
        let sysRecording = try await historyService.saveAudioCompressed(
            samples: syntheticSamples(count: Int(sampleRate), sampleRate: sampleRate),
            sampleRate: sampleRate, format: .aac, for: meeting.id
        )

        // Re-save with recordings attached (the correct pattern)
        let updated = Meeting(
            id: meeting.id, segments: segments, duration: 60.0,
            micRecording: micRecording, systemRecording: sysRecording,
            appName: "Zoom", createdAt: meeting.createdAt
        )
        try await historyService.save(.meeting(updated))

        let loaded = try await historyService.loadInteraction(id: meeting.id)
        guard case .meeting(let m) = loaded else {
            XCTFail("Expected meeting")
            return
        }
        XCTAssertNotNil(m.micRecording, "Mic recording should be attached")
        XCTAssertNotNil(m.systemRecording, "System recording should be attached")
        XCTAssertTrue(m.micRecording?.filename.hasSuffix(".m4a") == true)
    }
}
