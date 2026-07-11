//
//  MeetingLifecycleAuditTests.swift
//  AxiiIntegrationTests
//
//  Contract tests from the async/state-machine audit (batch 2):
//  - teardown's error-salvage must not lose the streamed transcript to the
//    state reset that follows it
//  - an export offer must never be parked in a closed panel
//  - the export window is data-bearing: takeovers preserve, never destroy
//  - a stale start (modal held open, panel closed meanwhile) must not fire
//

import AppKit
import XCTest
@testable import Axii

@MainActor
final class MeetingLifecycleAuditTests: XCTestCase {

    private var settings: SettingsService!
    private var historyService: HistoryService!
    private var tempDir: URL!

    override func setUp() async throws {
        settings = SettingsService(
            defaults: UserDefaults(suiteName: "MeetingAudit-\(UUID().uuidString)")!
        )
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AxiiMeetingAudit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        historyService = HistoryService(historyDirectory: tempDir)
    }

    override func tearDown() async throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        settings = nil
        historyService = nil
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

    /// Meeting handler fake mirroring the real handler's semantics: stop()
    /// detaches the live capture and publishes .processing for save-stops,
    /// exactly like MeetingPipelineHandler.stop.
    @MainActor
    private final class StubMeetingHandler: MeetingPipelineHandling {
        var stopResult: MeetingStopResult?
        var hasLiveCapture = false
        weak var state: ModeRuntimeState?
        private(set) var startCallCount = 0
        private(set) var stopCallCount = 0

        init(stopResult: MeetingStopResult?) {
            self.stopResult = stopResult
        }

        func start() async { startCallCount += 1 }

        func stop(saveToHistory: Bool) async -> MeetingStopResult? {
            stopCallCount += 1
            if saveToHistory, hasLiveCapture {
                state?.phase = .processing
            }
            hasLiveCapture = false
            return stopResult
        }

        func cancel() { hasLiveCapture = false }
        func selectApp(_ app: AudioApp?) {}
        func switchMicrophone(
            to device: AudioDevice?,
            micSource: AudioSource.MicrophoneSource
        ) async {}
        func refreshAppList() async {}
        @discardableResult
        func checkCrashRecovery() -> MeetingCrashRecovery? { nil }
    }

    @MainActor
    private final class SpyPersistence: MeetingPersisting {
        private(set) var lastPayload: MeetingPersistencePayload?
        private(set) var callCount = 0

        func persist(
            payload: MeetingPersistencePayload,
            audioFormat: AudioStorageFormat
        ) async throws -> Meeting? {
            callCount += 1
            lastPayload = payload
            return Meeting(
                segments: payload.segments,
                duration: payload.duration,
                appName: payload.appName
            )
        }
    }

    private func makeSegment(_ text: String) -> MeetingSegment {
        MeetingSegment(
            text: text, speakerId: "You",
            isFromMicrophone: true, startTime: 0, endTime: 1
        )
    }

    private func makePayload(
        segments: [MeetingSegment] = []
    ) -> MeetingPersistencePayload {
        MeetingPersistencePayload(
            micSamples: [0.1], micSampleRate: 16_000,
            systemSamples: [], systemSampleRate: 0,
            segments: segments, duration: 5, appName: nil
        )
    }

    private func makeFeature(
        handler: StubMeetingHandler,
        persistence: (any MeetingPersisting)? = nil
    ) -> ModeFeature {
        let feature = ModeFeature(
            config: DefaultModes.meeting(),
            transcriptionService: StubTranscriber(),
            micPermission: MicrophonePermissionService(),
            pasteService: StubPasteProvider(),
            clipboardService: ClipboardService(),
            settings: settings,
            historyService: historyService,
            mediaControlService: MediaControlService(),
            meetingHandler: handler,
            meetingPersistence: persistence
        )
        handler.state = feature.state
        return feature
    }

    // MARK: - Streamed Transcript Survives Teardown Salvage

    /// Escape from an errored live meeting salvages via a DETACHED save, and
    /// teardown's state.reset() runs before that save does. If finalization
    /// yields nothing, the streamed transcript snapshot is the only copy —
    /// it must be taken synchronously, before the reset.
    func testTeardownSalvagePreservesStreamedSegments() async throws {
        let handler = StubMeetingHandler(stopResult: makePayload(segments: []))
        handler.hasLiveCapture = true
        let spy = SpyPersistence()
        let feature = makeFeature(handler: handler, persistence: spy)
        feature.isActive = true
        feature.state.phase = .error("audio died")
        feature.state.segments = [makeSegment("streamed transcript")]

        feature.cancel() // teardown: salvage stop + state.reset()
        let save = try XCTUnwrap(feature.meetingStopTask)
        await save.value

        XCTAssertEqual(spy.callCount, 1)
        XCTAssertEqual(
            spy.lastPayload?.segments.map(\.text), ["streamed transcript"],
            "The reset must not erase the only transcript before the save reads it"
        )
    }

    // MARK: - Export Never Parks In A Closed Panel

    func testExportIntoClosedPanelReactivatesIt() async throws {
        let handler = StubMeetingHandler(
            stopResult: makePayload(segments: [makeSegment("hello")])
        )
        let feature = makeFeature(handler: handler, persistence: SpyPersistence())
        feature.meetingHistoryEnabledAtStart = false
        feature.isActive = false // panel closed while the salvage ran
        feature.state.phase = .processing

        let stop = try XCTUnwrap(feature.stopMeeting(saveToHistory: true))
        await stop.value

        XCTAssertTrue(feature.isActive,
                      "An unsaved transcript must be PRESENTED, not parked invisibly")
        XCTAssertEqual(feature.state.phase, .done)
        XCTAssertNotNil(feature.pendingMeetingExport)
    }

    // MARK: - Export Window Is Data-Bearing

    func testPendingExportMakesFeatureDataBearing() {
        let handler = StubMeetingHandler(stopResult: nil)
        let feature = makeFeature(handler: handler)
        XCTAssertFalse(feature.isDataBearing)

        feature.pendingMeetingExport = makePayload(segments: [makeSegment("x")])

        XCTAssertTrue(feature.isDataBearing,
                      "A transcript existing only in the panel must be takeover-protected")
    }

    func testStopAndPreserveCopiesExportAndKeepsArtifacts() throws {
        let micFile = tempDir.appendingPathComponent("export-mic.raw")
        let autosaveFile = tempDir.appendingPathComponent("export-autosave.json")
        try Data([1, 2, 3]).write(to: micFile)
        try Data("{}".utf8).write(to: autosaveFile)

        var payload = makePayload(segments: [makeSegment("keep me")])
        payload.recoveryArtifacts = MeetingRecoveryArtifacts(
            sessionID: UUID(),
            autosaveFileURL: autosaveFile,
            micFileURL: micFile,
            systemFileURL: nil
        )
        let handler = StubMeetingHandler(stopResult: nil)
        let feature = makeFeature(handler: handler)
        feature.pendingMeetingExport = payload
        feature.state.phase = .done
        feature.isActive = true

        feature.stopAndPreserve()

        XCTAssertNil(feature.pendingMeetingExport)
        XCTAssertFalse(feature.isActive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: micFile.path),
                      "Preserve keeps the artifacts; only an explicit discard destroys them")
        XCTAssertTrue(FileManager.default.fileExists(atPath: autosaveFile.path))
        // Deliberately NOT asserting pasteboard contents: NSPasteboard.general
        // is machine-global and other suites (the interaction fuzzers) write
        // it concurrently. The artifact + pending-export checks above are the
        // data-safety core of this contract.
    }

    // MARK: - Discard Keeps A Recoverable Copy

    /// Tearing down a LIVE meeting (Escape/close/takeover) discards it — but
    /// a mistaken discard must be recoverable, so the audio and transcript
    /// are persisted flagged, not destroyed.
    func testTeardownOfLiveMeetingPersistsAsDiscarded() async throws {
        let handler = StubMeetingHandler(
            stopResult: makePayload(segments: [makeSegment("keep me")])
        )
        handler.hasLiveCapture = true
        let spy = SpyPersistence()
        let feature = makeFeature(handler: handler, persistence: spy)
        feature.meetingHistoryEnabledAtStart = true
        feature.isActive = true
        feature.state.phase = .recording

        feature.cancel() // teardown of a live, non-errored meeting
        let save = try XCTUnwrap(feature.meetingStopTask)
        await save.value

        XCTAssertEqual(spy.callCount, 1,
                       "A discarded live meeting is persisted, not destroyed")
        XCTAssertNotNil(spy.lastPayload?.discardedAt,
                        "It lands in Recently Deleted, not the main list")
        XCTAssertEqual(spy.lastPayload?.segments.map(\.text), ["keep me"])
    }

    /// An ERRORED meeting torn down is a save (salvage), not a discard.
    func testTeardownOfErroredMeetingSavesNotDiscards() async throws {
        let handler = StubMeetingHandler(
            stopResult: makePayload(segments: [makeSegment("salvaged")])
        )
        handler.hasLiveCapture = true
        let spy = SpyPersistence()
        let feature = makeFeature(handler: handler, persistence: spy)
        feature.meetingHistoryEnabledAtStart = true
        feature.isActive = true
        feature.state.phase = .error("audio died")

        feature.cancel()
        let save = try XCTUnwrap(feature.meetingStopTask)
        await save.value

        XCTAssertEqual(spy.callCount, 1)
        XCTAssertNil(spy.lastPayload?.discardedAt,
                     "An error salvage saves to the main list, not the trash")
    }

    // MARK: - Stale Starts Cannot Fire

    /// startMeeting re-validates after its confirm dialog: with the panel
    /// closed (takeover during the modal), the start must not fire.
    func testStartMeetingRefusedWhenPanelNotActive() {
        let handler = StubMeetingHandler(stopResult: nil)
        let feature = makeFeature(handler: handler)
        feature.isActive = false
        feature.state.phase = .idle

        feature.startMeeting()

        XCTAssertEqual(handler.startCallCount, 0,
                       "A start whose panel closed must not put a capture behind it")
    }

    func testStartMeetingRefusedWhenCaptureAlreadyLive() {
        let handler = StubMeetingHandler(stopResult: nil)
        handler.hasLiveCapture = true
        let feature = makeFeature(handler: handler)
        feature.isActive = true
        feature.state.phase = .recording // a second start went live meanwhile

        feature.startMeeting()

        XCTAssertEqual(handler.startCallCount, 0,
                       "A stale start must not cancel-on-reentry a live capture")
    }

    /// The error-salvage retry re-validates after the salvage save completes:
    /// if Escape or a takeover closed the panel during the (potentially long)
    /// save, the retry must abort instead of starting a headless capture.
    func testSalvageRetryAbortsWhenPanelClosesDuringSave() async throws {
        let handler = StubMeetingHandler(stopResult: makePayload())
        handler.hasLiveCapture = true
        let feature = makeFeature(handler: handler, persistence: SpyPersistence())
        feature.isActive = false // panel already gone
        feature.state.phase = .error("audio died")

        feature.startMeeting() // salvage branch
        let save = try XCTUnwrap(feature.meetingStopTask)
        await save.value
        // Let the chained retry task run to its guard.
        for _ in 0..<50 { await Task.yield() }

        XCTAssertEqual(handler.stopCallCount, 1, "The salvage save itself runs")
        XCTAssertEqual(handler.startCallCount, 0,
                       "The retry must not restart behind a closed panel")
    }

    func testSalvageRetryProceedsWhenPanelStaysOpen() async throws {
        let handler = StubMeetingHandler(stopResult: makePayload())
        handler.hasLiveCapture = true
        let feature = makeFeature(handler: handler, persistence: SpyPersistence())
        feature.isActive = true
        feature.state.phase = .error("audio died")

        feature.startMeeting()
        let save = try XCTUnwrap(feature.meetingStopTask)
        await save.value
        var spins = 0
        while handler.startCallCount == 0, spins < 10_000 {
            await Task.yield()
            spins += 1
        }

        XCTAssertEqual(handler.startCallCount, 1,
                       "With the panel still open, the retry restarts normally")
    }
}
