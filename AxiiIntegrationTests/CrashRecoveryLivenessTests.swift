//
//  CrashRecoveryLivenessTests.swift
//  AxiiIntegrationTests
//
//  Contract tests from the async/state-machine audit (batch 3):
//  the shared autosave file must never be handed out as "crash recovery"
//  while its owning session is still writing it, and recovery itself runs
//  at most once per process — a mode created or rebuilt mid-meeting must
//  not persist a phantom duplicate and delete the live session's spool.
//

import XCTest
@testable import Axii

@MainActor
final class CrashRecoveryLivenessTests: XCTestCase {

    private var tempDir: URL!
    private var autosaveURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AxiiRecoveryLiveness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        autosaveURL = tempDir.appendingPathComponent("autosave.json")
        ModeFeature.crashRecoveryDidRun = false
    }

    override func tearDown() async throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        autosaveURL = nil
    }

    private actor StubTranscriber: TranscriptionProviding {
        var isReady: Bool { true }
        func prepare() async throws {}
        func transcribe(samples: [Float], sampleRate: Double) async throws -> String { "" }
    }

    private func makeManager() -> MeetingTranscriptManager {
        MeetingTranscriptManager(
            transcriptionService: StubTranscriber(),
            autosaveFileURL: autosaveURL
        )
    }

    // MARK: - Live Sessions Are Not Crashes

    func testLiveSessionAutosaveIsNotOfferedAsRecovery() {
        // A live meeting: autosave running, file on disk with its sessionID.
        let live = makeManager()
        live.reset()
        live.audioFileReferenceProvider = {
            MeetingAudioFileReferences(
                micFileURL: self.tempDir.appendingPathComponent("mic.raw"),
                micSampleRate: 16_000,
                systemFileURL: nil,
                systemSampleRate: 0
            )
        }
        live.startAutoSave()
        live.flushAutoSave()
        XCTAssertTrue(FileManager.default.fileExists(atPath: autosaveURL.path))

        // A second manager (a mode registered mid-meeting) checks recovery.
        let intruder = makeManager()
        XCTAssertNil(intruder.checkForCrashRecovery(),
                     "A LIVE session's safety net is not a crash to recover")

        // Once the session ends (or the process dies), the file is fair game.
        live.stopAutoSave()
        let afterStop = makeManager()
        XCTAssertNotNil(afterStop.checkForCrashRecovery(),
                        "A finished writer's file is recoverable again")
    }

    // MARK: - Recovery Runs Once Per Process

    private final class StubPasteProvider: PasteProviding {
        func paste(
            text: String,
            focusSnapshot: FocusSnapshot?,
            finishBehavior: FinishBehavior,
            failureBehavior: InsertionFailureBehavior
        ) async -> PasteService.Outcome { .skipped }
    }

    @MainActor
    private final class RecoveryStubHandler: MeetingPipelineHandling {
        var recovery: MeetingCrashRecovery?
        private(set) var checkCount = 0

        func start() async {}
        func stop(saveToHistory: Bool) async -> MeetingStopResult? { nil }
        func cancel() {}
        func selectApp(_ app: AudioApp?) {}
        func switchMicrophone(
            to device: AudioDevice?,
            micSource: AudioSource.MicrophoneSource
        ) async {}
        func refreshAppList() async {}
        var hasLiveCapture: Bool { false }
        @discardableResult
        func checkCrashRecovery() -> MeetingCrashRecovery? {
            checkCount += 1
            return recovery
        }
    }

    private func makeFeature(handler: RecoveryStubHandler) -> ModeFeature {
        let settings = SettingsService(
            defaults: UserDefaults(suiteName: "RecoveryLiveness-\(UUID().uuidString)")!
        )
        return ModeFeature(
            config: DefaultModes.meeting(),
            transcriptionService: StubTranscriber(),
            micPermission: MicrophonePermissionService(),
            pasteService: StubPasteProvider(),
            clipboardService: ClipboardService(),
            settings: settings,
            historyService: HistoryService(historyDirectory: tempDir),
            mediaControlService: MediaControlService()
        )
    }

    func testCrashRecoveryRunsOncePerProcess() {
        let handlerA = RecoveryStubHandler()
        let featureA = makeFeature(handler: handlerA)
        featureA.meetingHandler = handlerA
        let handlerB = RecoveryStubHandler()
        let featureB = makeFeature(handler: handlerB)
        featureB.meetingHandler = handlerB

        _ = featureA.recoverCrashedMeetingIfNeeded()
        XCTAssertEqual(handlerA.checkCount, 1,
                       "The first registration performs the launch check")

        _ = featureB.recoverCrashedMeetingIfNeeded()
        XCTAssertEqual(handlerB.checkCount, 0,
                       "A second crash-recovery mode must not re-run recovery — "
                       + "at launch that duplicates the meeting, at runtime it "
                       + "cannibalizes the live session")
    }
}
