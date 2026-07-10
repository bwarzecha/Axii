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
        // Crash recovery is once-per-process in production; each test is
        // its own "launch".
        ModeFeature.crashRecoveryDidRun = false
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
        ) async throws -> Meeting? {
            callCount += 1
            throw NSError(
                domain: "test", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Simulated persistence failure"]
            )
        }
    }

    /// A persistence fake that records whether it was called.
    /// `writesNothing` mimics history being switched off between meeting start
    /// and the persist call: no throw, but nothing reaches disk.
    @MainActor
    private final class SpyPersistence: MeetingPersisting {
        private(set) var callCount = 0
        private(set) var lastPayload: MeetingPersistencePayload?
        var writesNothing = false

        func persist(
            payload: MeetingPersistencePayload,
            audioFormat: AudioStorageFormat
        ) async throws -> Meeting? {
            callCount += 1
            lastPayload = payload
            if writesNothing { return nil }
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
        var recovery: MeetingCrashRecovery?
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
        private(set) var micSwitches: [(device: AudioDevice?, micSource: AudioSource.MicrophoneSource)] = []
        func switchMicrophone(
            to device: AudioDevice?,
            micSource: AudioSource.MicrophoneSource
        ) async {
            micSwitches.append((device, micSource))
        }
        func refreshAppList() async {}
        @discardableResult
        func checkCrashRecovery() -> MeetingCrashRecovery? { recovery }
        var hasLiveCapture: Bool { false }
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

    /// A payload whose recovery artifacts point at real files in tempDir,
    /// so tests can observe the commit point on disk.
    private func makePayloadWithArtifacts() throws -> (
        payload: MeetingPersistencePayload,
        micFile: URL,
        autosaveFile: URL
    ) {
        let micFile = tempDir.appendingPathComponent("artifact-mic.raw")
        let autosaveFile = tempDir.appendingPathComponent("artifact-autosave.json")
        try Data([1, 2, 3]).write(to: micFile)
        // A sessionID-less legacy-format autosave decodes and is treated as
        // owned by the committing session.
        try Data(#"{"segments":[],"duration":1,"startTime":0,"selectedAppName":null}"#.utf8)
            .write(to: autosaveFile)

        var payload = makePayload()
        payload.recoveryArtifacts = MeetingRecoveryArtifacts(
            sessionID: UUID(),
            autosaveFileURL: autosaveFile,
            micFileURL: micFile,
            systemFileURL: nil
        )
        return (payload, micFile, autosaveFile)
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

    /// A meeting recorded with history off is never handed to persistence, and
    /// its transcript is parked in .done so the user can copy it out.
    func testHistoryDisabledAtStart_OffersExportInsteadOfPersisting() async throws {
        var payload = makePayload()
        payload.segments = [
            MeetingSegment(
                text: "hello", speakerId: "You",
                isFromMicrophone: true, startTime: 0, endTime: 1
            )
        ]
        let handler = StubMeetingHandler(stopResult: payload)
        let spy = SpyPersistence()
        let feature = makeFeature(
            meetingHandler: handler,
            meetingPersistence: spy
        )
        feature.meetingHistoryEnabledAtStart = false
        feature.state.phase = .processing

        let stopTask = try XCTUnwrap(feature.stopMeeting(saveToHistory: true))
        await stopTask.value

        XCTAssertEqual(handler.stopCallCount, 1)
        XCTAssertEqual(spy.callCount, 0, "Persistence should not be called when history was off at start")
        XCTAssertEqual(feature.state.phase, .done)
        XCTAssertTrue(feature.state.needsManualCopy,
                      "An unsaved meeting must offer its transcript before it disappears")
        XCTAssertEqual(feature.state.manualCopyText, "You: hello")
        XCTAssertNotNil(feature.pendingMeetingExport)

        let meetings = historyService.listMetadata(type: .meeting)
        XCTAssertTrue(meetings.isEmpty, "No meetings should be persisted when history is disabled")
    }

    /// The setting the user recorded under governs the save, not whatever the
    /// toggle says when they hit Stop. Flipping it mid-meeting must not turn
    /// an hour of audio into a silent no-op.
    func testHistoryEnabledAtStart_PersistsEvenIfDisabledMidMeeting() async throws {
        let handler = StubMeetingHandler(stopResult: makePayload())
        let spy = SpyPersistence()
        let feature = makeFeature(meetingHandler: handler, meetingPersistence: spy)
        feature.meetingHistoryEnabledAtStart = true
        historyService.isEnabled = false
        feature.state.phase = .processing

        let stopTask = try XCTUnwrap(feature.stopMeeting(saveToHistory: true))
        await stopTask.value

        XCTAssertEqual(spy.callCount, 1,
                       "A meeting started with history on is still handed to persistence")
        XCTAssertEqual(feature.state.phase, .idle)
    }

    /// Defense in depth: if the write reaches HistoryService and lands nowhere
    /// (disabled underneath us), the artifacts must survive and the user must
    /// be given the transcript rather than a false success.
    func testPersistWritesNothing_KeepsArtifactsAndOffersExport() async throws {
        let (payload, micFile, autosaveFile) = try makePayloadWithArtifacts()
        let handler = StubMeetingHandler(stopResult: payload)
        let spy = SpyPersistence()
        spy.writesNothing = true
        let feature = makeFeature(meetingHandler: handler, meetingPersistence: spy)
        feature.meetingHistoryEnabledAtStart = true
        feature.state.phase = .processing

        let stopTask = try XCTUnwrap(feature.stopMeeting(saveToHistory: true))
        await stopTask.value

        XCTAssertEqual(spy.callCount, 1)
        XCTAssertEqual(feature.state.phase, .done)
        XCTAssertNotNil(feature.pendingMeetingExport)
        XCTAssertTrue(FileManager.default.fileExists(atPath: micFile.path),
                      "Nothing was written, so nothing may be released")
        XCTAssertTrue(FileManager.default.fileExists(atPath: autosaveFile.path))
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

    // MARK: - Recovery Artifact Commit Point

    func testPersistSuccess_ClearsRecoveryArtifacts() async throws {
        let (payload, micFile, autosaveFile) = try makePayloadWithArtifacts()
        let handler = StubMeetingHandler(stopResult: payload)
        let feature = makeFeature(
            meetingHandler: handler,
            meetingPersistence: SpyPersistence()
        )
        feature.state.phase = .processing

        let stopTask = try XCTUnwrap(feature.stopMeeting(saveToHistory: true))
        await stopTask.value

        XCTAssertFalse(FileManager.default.fileExists(atPath: micFile.path),
                       "Temp audio is cleared once the meeting is durably saved")
        XCTAssertFalse(FileManager.default.fileExists(atPath: autosaveFile.path),
                       "Autosave is cleared once the meeting is durably saved")
    }

    func testPersistFailure_KeepsRecoveryArtifacts() async throws {
        let (payload, micFile, autosaveFile) = try makePayloadWithArtifacts()
        let handler = StubMeetingHandler(stopResult: payload)
        let feature = makeFeature(
            meetingHandler: handler,
            meetingPersistence: FailingPersistence()
        )
        feature.state.phase = .processing

        let stopTask = try XCTUnwrap(feature.stopMeeting(saveToHistory: true))
        await stopTask.value

        XCTAssertTrue(FileManager.default.fileExists(atPath: micFile.path),
                      "A meeting that failed to save must stay recoverable")
        XCTAssertTrue(FileManager.default.fileExists(atPath: autosaveFile.path),
                      "A meeting that failed to save must stay recoverable")
    }

    // MARK: - Crash Recovery Auto-Persist

    private func makeRecovery(
        autosaveFile: URL,
        sessionID: UUID
    ) throws -> MeetingCrashRecovery {
        try Data(
            #"{"segments":[],"duration":5,"startTime":0,"selectedAppName":null,"sessionID":"\#(sessionID.uuidString)"}"#
                .utf8
        ).write(to: autosaveFile)
        let segment = MeetingSegment(
            text: "recovered",
            speakerId: "You",
            isFromMicrophone: true,
            startTime: 0,
            endTime: 1
        )
        return MeetingCrashRecovery(
            segments: [segment],
            duration: 5,
            appName: "Zoom",
            sessionID: sessionID,
            autosaveFileURL: autosaveFile,
            audioFiles: nil
        )
    }

    func testCrashRecovery_PersistsRecoveredMeetingAndReleasesFile() async throws {
        let autosaveFile = tempDir.appendingPathComponent("recovery-autosave.json")
        let handler = StubMeetingHandler(stopResult: nil)
        handler.recovery = try makeRecovery(autosaveFile: autosaveFile, sessionID: UUID())
        let spy = SpyPersistence()
        let feature = makeFeature(meetingHandler: handler, meetingPersistence: spy)

        let task = try XCTUnwrap(feature.recoverCrashedMeetingIfNeeded())
        await task.value

        XCTAssertEqual(spy.callCount, 1, "A recovered transcript must land in history")
        XCTAssertFalse(FileManager.default.fileExists(atPath: autosaveFile.path),
                       "The recovery file is released once the transcript is durable")
    }

    func testCrashRecovery_PersistFailureKeepsFileForNextLaunch() async throws {
        let autosaveFile = tempDir.appendingPathComponent("recovery-autosave.json")
        let handler = StubMeetingHandler(stopResult: nil)
        handler.recovery = try makeRecovery(autosaveFile: autosaveFile, sessionID: UUID())
        let feature = makeFeature(
            meetingHandler: handler,
            meetingPersistence: FailingPersistence()
        )

        let task = try XCTUnwrap(feature.recoverCrashedMeetingIfNeeded())
        await task.value

        XCTAssertTrue(FileManager.default.fileExists(atPath: autosaveFile.path),
                      "Recovery must be re-offered next launch when persisting it failed")
    }

    func testCrashRecovery_HistoryDisabledLeavesFileAlone() async throws {
        historyService.isEnabled = false
        let autosaveFile = tempDir.appendingPathComponent("recovery-autosave.json")
        let handler = StubMeetingHandler(stopResult: nil)
        handler.recovery = try makeRecovery(autosaveFile: autosaveFile, sessionID: UUID())
        let spy = SpyPersistence()
        let feature = makeFeature(meetingHandler: handler, meetingPersistence: spy)

        XCTAssertNil(feature.recoverCrashedMeetingIfNeeded())
        XCTAssertEqual(spy.callCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: autosaveFile.path))
    }

    // MARK: - Stale Stop Cannot Stomp A Newer Stop

    /// Persistence fake that suspends every call until released, in order.
    @MainActor
    private final class GatedPersistence: MeetingPersisting {
        private(set) var continuations: [CheckedContinuation<Void, Never>] = []

        func persist(
            payload: MeetingPersistencePayload,
            audioFormat: AudioStorageFormat
        ) async throws -> Meeting? {
            await withCheckedContinuation { continuations.append($0) }
            return Meeting(
                segments: payload.segments,
                duration: payload.duration,
                appName: payload.appName
            )
        }

        func release(_ index: Int) {
            continuations[index].resume()
        }
    }

    func testConcurrentSaveStopsCoalesceIntoOne() async throws {
        let gated = GatedPersistence()
        let handler = StubMeetingHandler(stopResult: makePayload())
        let feature = makeFeature(meetingHandler: handler, meetingPersistence: gated)

        feature.state.phase = .processing
        let stopA = try XCTUnwrap(feature.stopMeeting(saveToHistory: true))
        var spins = 0
        while gated.continuations.count < 1, spins < 10_000 {
            await Task.yield()
            spins += 1
        }

        // A double-tap while the save is in flight must JOIN it — a second
        // handler.stop against the already-detached capture would flip the
        // UI to idle mid-save and suppress the first stop's error reporting.
        let stopB = try XCTUnwrap(feature.stopMeeting(saveToHistory: true))
        XCTAssertEqual(feature.state.phase, .processing,
                       "The joined stop must not disturb the in-flight save")

        gated.release(0)
        await stopA.value
        await stopB.value
        XCTAssertEqual(handler.stopCallCount, 1,
                       "Coalesced stops issue exactly one handler.stop")
        XCTAssertEqual(gated.continuations.count, 1,
                       "Coalesced stops persist exactly once")
        XCTAssertEqual(feature.state.phase, .idle)

        // A LATER save-stop (after the first completed) is a fresh flow.
        feature.state.phase = .processing
        let stopC = try XCTUnwrap(feature.stopMeeting(saveToHistory: true))
        spins = 0
        while gated.continuations.count < 2, spins < 10_000 {
            await Task.yield()
            spins += 1
        }
        gated.release(1)
        await stopC.value
        XCTAssertEqual(handler.stopCallCount, 2)
    }

    func testCrashRecovery_RestoresAudioFromSpoolFiles() async throws {
        let autosaveFile = tempDir.appendingPathComponent("recovery-autosave.json")
        let micFile = tempDir.appendingPathComponent("spool-mic.raw")
        let samples: [Float] = [0.25, -0.5, 0.75]
        try samples.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: micFile)

        let handler = StubMeetingHandler(stopResult: nil)
        var recovery = try makeRecovery(autosaveFile: autosaveFile, sessionID: UUID())
        recovery = MeetingCrashRecovery(
            segments: recovery.segments,
            duration: recovery.duration,
            appName: recovery.appName,
            sessionID: recovery.sessionID,
            autosaveFileURL: recovery.autosaveFileURL,
            audioFiles: MeetingAudioFileReferences(
                micFileURL: micFile,
                micSampleRate: 48_000,
                systemFileURL: nil,
                systemSampleRate: 0
            )
        )
        handler.recovery = recovery
        let spy = SpyPersistence()
        let feature = makeFeature(meetingHandler: handler, meetingPersistence: spy)

        let task = try XCTUnwrap(feature.recoverCrashedMeetingIfNeeded())
        await task.value

        XCTAssertEqual(spy.lastPayload?.micSamples, samples,
                       "Recovered meeting must include the spooled audio")
        XCTAssertEqual(spy.lastPayload?.micSampleRate, 48_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: micFile.path),
                       "Spool audio is released once the recovered meeting is durable")
    }

    // MARK: - Mic Reconciliation During A Meeting

    private func makeDevice(uid: String) -> AudioDevice {
        AudioDevice(id: 0, uid: uid, name: uid, transportType: .usb)
    }

    func testMicUnplugDuringMeetingSwitchesCaptureToDefault() async throws {
        let handler = StubMeetingHandler(stopResult: nil)
        let feature = makeFeature(meetingHandler: handler)
        feature.state.phase = .recording

        let task = feature.reconcileMicrophoneSelection(
            resolved: nil,
            previous: makeDevice(uid: "usb-mic")
        )
        await task?.value

        XCTAssertEqual(handler.micSwitches.count, 1)
        XCTAssertNil(handler.micSwitches.first?.device)
        if case .systemDefault = handler.micSwitches.first?.micSource {
        } else {
            XCTFail("Unplug must fall back to the system default source")
        }
    }

    func testMicReplugDuringMeetingSwitchesBackToPreferredDevice() async throws {
        let handler = StubMeetingHandler(stopResult: nil)
        let feature = makeFeature(meetingHandler: handler)
        feature.state.phase = .recording
        let preferred = makeDevice(uid: "usb-mic")

        let task = feature.reconcileMicrophoneSelection(
            resolved: preferred,
            previous: nil
        )
        await task?.value

        XCTAssertEqual(handler.micSwitches.count, 1)
        XCTAssertEqual(handler.micSwitches.first?.device?.uid, "usb-mic")
    }

    func testDeviceChangeOutsideRecordingDoesNotTouchCapture() async throws {
        let handler = StubMeetingHandler(stopResult: nil)
        let feature = makeFeature(meetingHandler: handler)
        feature.state.phase = .idle

        let task = feature.reconcileMicrophoneSelection(
            resolved: makeDevice(uid: "usb-mic"),
            previous: nil
        )

        XCTAssertNil(task, "No reconciliation outside an active recording")
        XCTAssertTrue(handler.micSwitches.isEmpty)
    }

    func testUnchangedDeviceDoesNotRestartCapture() async throws {
        let handler = StubMeetingHandler(stopResult: nil)
        let feature = makeFeature(meetingHandler: handler)
        feature.state.phase = .recording
        let device = makeDevice(uid: "usb-mic")

        let task = feature.reconcileMicrophoneSelection(
            resolved: device,
            previous: device
        )

        XCTAssertNil(task, "Same device must not trigger a capture restart")
        XCTAssertTrue(handler.micSwitches.isEmpty)
    }

    // MARK: - Unsaved Meeting Export Window

    /// While an unsaved meeting sits in .done awaiting export, its artifacts
    /// stay on disk: a crash during the export window must still be
    /// recoverable. They are released only when the panel closes.
    func testHistoryDisabled_KeepsArtifactsUntilPanelCloses() async throws {
        let (payload, micFile, autosaveFile) = try makePayloadWithArtifacts()
        let handler = StubMeetingHandler(stopResult: payload)
        let feature = makeFeature(
            meetingHandler: handler,
            meetingPersistence: SpyPersistence()
        )
        feature.meetingHistoryEnabledAtStart = false
        feature.state.phase = .processing

        let stopTask = try XCTUnwrap(feature.stopMeeting(saveToHistory: true))
        await stopTask.value

        XCTAssertTrue(FileManager.default.fileExists(atPath: micFile.path),
                      "The export window must stay crash-recoverable")
        XCTAssertTrue(FileManager.default.fileExists(atPath: autosaveFile.path))

        feature.cancel()

        XCTAssertFalse(FileManager.default.fileExists(atPath: micFile.path),
                       "Closing the panel ends the export window and releases the data")
        XCTAssertFalse(FileManager.default.fileExists(atPath: autosaveFile.path))
        XCTAssertNil(feature.pendingMeetingExport)
    }

    // MARK: - Save-In-Flight Close Guard

    /// Escape during a meeting save would tear down the runtime under an
    /// in-flight persist. Refuse it until the save resolves.
    func testEscapeDuringSaveIsRefused() async throws {
        let gated = GatedPersistence()
        let handler = StubMeetingHandler(stopResult: makePayload())
        let feature = makeFeature(meetingHandler: handler, meetingPersistence: gated)
        feature.isActive = true
        feature.state.phase = .processing

        let stop = try XCTUnwrap(feature.stopMeeting(saveToHistory: true))
        var spins = 0
        while gated.continuations.isEmpty, spins < 10_000 {
            await Task.yield()
            spins += 1
        }

        XCTAssertTrue(feature.isSavingMeeting)
        feature.handleEscape()
        XCTAssertEqual(feature.state.phase, .processing,
                       "Escape must not tear down a runtime that is mid-save")
        XCTAssertTrue(feature.isActive)

        gated.release(0)
        await stop.value

        XCTAssertFalse(feature.isSavingMeeting)
        feature.handleEscape()
        XCTAssertFalse(feature.isActive, "Once the save lands, Escape closes the panel")
    }

    /// A discard-stop sets no in-flight save, so it must not block the exit.
    func testEscapeAfterDiscardStopIsAllowed() async throws {
        let handler = StubMeetingHandler(stopResult: nil)
        let feature = makeFeature(meetingHandler: handler)
        feature.isActive = true

        let stop = try XCTUnwrap(feature.stopMeeting(saveToHistory: false))
        await stop.value

        XCTAssertFalse(feature.isSavingMeeting)
        feature.handleEscape()
        XCTAssertFalse(feature.isActive)
    }
}
