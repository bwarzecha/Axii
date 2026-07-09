//
//  MeetingSaveRegressionTests.swift
//  AxiiIntegrationTests
//
//  Thin adapter-level regression tests for meeting stop/save behavior.
//  The full persistence matrix lives in MeetingPersistenceServiceTests.
//  These tests cover adapter-specific behavior only:
//  - persistence failure still returns runtime to idle
//  - history-disabled meeting stop does not persist
//

import XCTest
@testable import Axii

@MainActor
final class MeetingSaveRegressionTests: XCTestCase {

    private var historyService: HistoryService!
    private var settings: SettingsService!
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AxiiMeetingSaveRegression-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        historyService = HistoryService(historyDirectory: tempDir)
        settings = SettingsService(
            defaults: UserDefaults(suiteName: "MeetingSaveRegression-\(UUID().uuidString)")!
        )
    }

    override func tearDown() async throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        historyService = nil
        settings = nil
        tempDir = nil
    }

    // MARK: - Fakes

    private actor StubTranscriber: TranscriptionProviding {
        var isReady: Bool { true }
        func prepare() async throws {}
        func transcribe(samples: [Float], sampleRate: Double) async throws -> String { "" }
    }

    private final class StubPasteProvider: PasteProviding {
        func paste(
            text: String,
            focusSnapshot: FocusSnapshot?,
            finishBehavior: FinishBehavior,
            failureBehavior: InsertionFailureBehavior
        ) async -> PasteService.Outcome { .skipped }
    }

    /// A persistence fake that always throws, for failure regression.
    @MainActor
    private final class FailingPersistence: MeetingPersisting {
        private(set) var callCount = 0

        func persist(
            payload: MeetingPersistencePayload,
            audioFormat: AudioStorageFormat
        ) async throws -> Meeting {
            callCount += 1
            throw NSError(
                domain: "test", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Simulated persistence failure"]
            )
        }
    }

    /// A persistence fake that records whether it was called.
    @MainActor
    private final class SpyPersistence: MeetingPersisting {
        private(set) var callCount = 0

        func persist(
            payload: MeetingPersistencePayload,
            audioFormat: AudioStorageFormat
        ) async throws -> Meeting {
            callCount += 1
            return Meeting(
                segments: payload.segments,
                duration: payload.duration,
                appName: payload.appName
            )
        }
    }

    /// A meeting handler fake that lets tests exercise ModeFeature.stopMeeting.
    @MainActor
    private final class StubMeetingHandler: MeetingPipelineHandling {
        private let stopResult: MeetingStopResult?
        private(set) var stopCallCount = 0
        private(set) var stopSaveToHistory: Bool?

        init(stopResult: MeetingStopResult?) {
            self.stopResult = stopResult
        }

        func start() async {}

        func stop(saveToHistory: Bool) async -> MeetingStopResult? {
            stopCallCount += 1
            stopSaveToHistory = saveToHistory
            return stopResult
        }

        func cancel() {}
        func selectApp(_ app: AudioApp?) {}
        func switchMicrophone(
            to device: AudioDevice?,
            micSource: AudioSource.MicrophoneSource
        ) async {}
        func refreshAppList() async {}
        func checkCrashRecovery() {}
    }

    private func makePayload() -> MeetingPersistencePayload {
        MeetingPersistencePayload(
            micSamples: [0.1, 0.2],
            micSampleRate: 44100,
            systemSamples: [],
            systemSampleRate: 0,
            segments: [],
            duration: 10,
            appName: nil
        )
    }

    private func makeFeature(
        meetingHandler: any MeetingPipelineHandling,
        meetingPersistence: (any MeetingPersisting)? = nil
    ) -> ModeFeature {
        ModeFeature(
            config: DefaultModes.meeting(),
            transcriptionService: StubTranscriber(),
            micPermission: MicrophonePermissionService(),
            pasteService: StubPasteProvider(),
            clipboardService: ClipboardService(),
            settings: settings,
            historyService: historyService,
            mediaControlService: MediaControlService(),
            meetingHandler: meetingHandler,
            meetingPersistence: meetingPersistence
        )
    }

    // MARK: - History Disabled

    func testHistoryDisabled_MeetingStopDoesNotPersist() async throws {
        historyService.isEnabled = false
        let handler = StubMeetingHandler(stopResult: makePayload())
        let spy = SpyPersistence()
        let feature = makeFeature(
            meetingHandler: handler,
            meetingPersistence: spy
        )
        feature.state.phase = .processing

        let stopTask = try XCTUnwrap(feature.stopMeeting(saveToHistory: true))
        await stopTask.value

        XCTAssertEqual(handler.stopCallCount, 1)
        XCTAssertEqual(handler.stopSaveToHistory, true)
        XCTAssertEqual(spy.callCount, 0, "Persistence should not be called when history is disabled")
        XCTAssertEqual(feature.state.phase, .idle)

        let meetings = historyService.listMetadata(type: .meeting)
        XCTAssertTrue(meetings.isEmpty, "No meetings should be persisted when history is disabled")
    }

    // MARK: - Persistence Failure Is Surfaced

    func testPersistenceFailure_SurfacesErrorInsteadOfPretendingSuccess() async throws {
        let handler = StubMeetingHandler(stopResult: makePayload())
        let persistence = FailingPersistence()
        let feature = makeFeature(
            meetingHandler: handler,
            meetingPersistence: persistence
        )

        feature.state.phase = .processing

        let stopTask = try XCTUnwrap(feature.stopMeeting(saveToHistory: true))
        await stopTask.value

        XCTAssertEqual(handler.stopCallCount, 1)
        XCTAssertEqual(handler.stopSaveToHistory, true)
        XCTAssertEqual(persistence.callCount, 1)
        XCTAssertEqual(feature.state.phase, .error("Failed to save meeting"),
                       "A failed save must be visible to the user, not silently dropped")
    }
}
