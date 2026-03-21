//
//  MeetingSaveRegressionTests.swift
//  AxiiIntegrationTests
//
//  Integration tests for meeting save behavior via ModeFeature.saveMeetingToHistory.
//  Tests exercise the real production method and verify persisted outcomes.
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

    // MARK: - Active Save Path: Audio Attached After Reload

    /// Exercises the real ModeFeature.saveMeetingToHistory and verifies
    /// that both audio recordings are attached to the persisted Meeting.
    func testSaveMeetingToHistory_AttachesBothRecordings() async throws {
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

        await modeFeature.saveMeetingToHistory(result)

        // Verify meeting is listed
        let meetings = historyService.listMetadata(type: .meeting)
        XCTAssertEqual(meetings.count, 1, "One meeting should be saved")

        // Load and verify recordings are attached
        let meetingId = meetings.first!.id
        let loaded = try await historyService.loadInteraction(id: meetingId)
        guard case .meeting(let loadedMeeting) = loaded else {
            XCTFail("Expected meeting interaction")
            return
        }

        XCTAssertEqual(loadedMeeting.segments.count, 2)
        XCTAssertEqual(loadedMeeting.duration, 60.0)
        XCTAssertEqual(loadedMeeting.appName, "Zoom")
        XCTAssertNotNil(loadedMeeting.micRecording, "Mic recording should be attached")
        XCTAssertNotNil(loadedMeeting.systemRecording, "System recording should be attached")

        // Verify audio files exist on disk
        let metadata = meetings.first!
        let folderURL = tempDir.appendingPathComponent(metadata.folderName)
        let audioDir = folderURL.appendingPathComponent("audio")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioDir.path))

        let audioFiles = try FileManager.default.contentsOfDirectory(
            at: audioDir, includingPropertiesForKeys: nil
        )
        XCTAssertEqual(audioFiles.count, 2, "Mic + system audio files")
    }

    /// Verifies the active save path uses the configured compressed format (AAC -> .m4a).
    func testSaveMeetingToHistory_UsesConfiguredCompressedFormat() async throws {
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

        let meetings = historyService.listMetadata(type: .meeting)
        XCTAssertEqual(meetings.count, 1)

        // Load and verify recordings use .m4a extension
        let loaded = try await historyService.loadInteraction(id: meetings.first!.id)
        guard case .meeting(let m) = loaded else {
            XCTFail("Expected meeting interaction")
            return
        }

        XCTAssertNotNil(m.micRecording, "Mic recording should be attached")
        XCTAssertNotNil(m.systemRecording, "System recording should be attached")
        XCTAssertTrue(m.micRecording?.filename.hasSuffix(".m4a") == true,
                       "Mic recording should use .m4a for AAC")
        XCTAssertTrue(m.systemRecording?.filename.hasSuffix(".m4a") == true,
                       "System recording should use .m4a for AAC")

        // Verify files exist on disk
        let metadata = meetings.first!
        let folderURL = tempDir.appendingPathComponent(metadata.folderName)
        let audioDir = folderURL.appendingPathComponent("audio")
        let audioFiles = try FileManager.default.contentsOfDirectory(
            at: audioDir, includingPropertiesForKeys: nil
        )
        XCTAssertEqual(audioFiles.count, 2)
        for file in audioFiles {
            XCTAssertEqual(file.pathExtension, "m4a")
        }
    }

    /// Verifies that a newly saved meeting persists valid recording references
    /// that can be resolved to audio file URLs.
    func testSaveMeetingToHistory_RecordingReferencesAreResolvable() async throws {
        let sampleRate: Double = 44100
        let result = MeetingStopResult(
            micSamples: syntheticSamples(count: Int(sampleRate), sampleRate: sampleRate),
            micSampleRate: sampleRate,
            systemSamples: syntheticSamples(count: Int(sampleRate), sampleRate: sampleRate),
            systemSampleRate: sampleRate,
            segments: [
                MeetingSegment(text: "Hello", speakerId: "You",
                               isFromMicrophone: true, startTime: 0, endTime: 5),
            ],
            duration: 45.0,
            appName: "Zoom"
        )

        await modeFeature.saveMeetingToHistory(result)

        let meetings = historyService.listMetadata(type: .meeting)
        let loaded = try await historyService.loadInteraction(id: meetings.first!.id)
        guard case .meeting(let m) = loaded else {
            XCTFail("Expected meeting interaction")
            return
        }

        // Recording references should resolve to existing files via HistoryService
        let micURL = historyService.getAudioURL(m.micRecording!, for: m.id)
        let sysURL = historyService.getAudioURL(m.systemRecording!, for: m.id)
        XCTAssertNotNil(micURL)
        XCTAssertNotNil(sysURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: micURL!.path),
                       "Mic audio file should exist at resolved URL")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sysURL!.path),
                       "System audio file should exist at resolved URL")
    }
}
