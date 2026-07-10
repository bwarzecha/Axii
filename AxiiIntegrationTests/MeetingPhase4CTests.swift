//
//  MeetingPhase4CTests.swift
//  AxiiIntegrationTests
//
//  Service-level and handler-level coverage for the Phase 4C meeting
//  start/capture split.
//

import AppKit
import CoreAudio
import XCTest
@testable import Axii

@MainActor
final class MeetingPhase4CTests: XCTestCase {

    private enum TestError: Error {
        case prepareFailed
        case startFailed
    }

    // MARK: - Fakes

    private actor SpyTranscriber: TranscriptionProviding {
        var isReadyValue: Bool
        var prepareError: Error?
        private(set) var prepareCount = 0
        private let text: String
        private var suspendPrepare = false
        private var prepareStarted = false
        private var prepareStartWaiters: [CheckedContinuation<Void, Never>] = []
        private var finishPrepareContinuation: CheckedContinuation<Void, Never>?

        var isReady: Bool { isReadyValue }

        init(isReady: Bool = true, text: String = "ok") {
            self.isReadyValue = isReady
            self.text = text
        }

        func prepare() async throws {
            prepareCount += 1
            prepareStarted = true
            let waiters = prepareStartWaiters
            prepareStartWaiters = []
            for waiter in waiters {
                waiter.resume()
            }
            if suspendPrepare {
                await withCheckedContinuation { continuation in
                    finishPrepareContinuation = continuation
                }
            }
            if let prepareError {
                throw prepareError
            }
            isReadyValue = true
        }

        func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
            text
        }

        func snapshotPrepareCount() -> Int {
            prepareCount
        }

        func setPrepareErrorForTest(_ error: Error) {
            prepareError = error
        }

        func suspendPrepareForTest() {
            suspendPrepare = true
        }

        func waitForPrepareStart() async {
            if prepareStarted {
                return
            }
            await withCheckedContinuation { continuation in
                prepareStartWaiters.append(continuation)
            }
        }

        func finishSuspendedPrepare() {
            suspendPrepare = false
            finishPrepareContinuation?.resume()
            finishPrepareContinuation = nil
        }
    }

    private final class FakeMicPermission: MeetingMicrophonePermissionChecking {
        var state: MicrophonePermissionService.State
        private(set) var openSettingsCount = 0

        init(state: MicrophonePermissionService.State) {
            self.state = state
        }

        func openSystemSettings() {
            openSettingsCount += 1
        }
    }

    private final class FakeScreenPermission: MeetingScreenRecordingPermissionChecking {
        var isGranted: Bool
        private(set) var requestCount = 0

        init(isGranted: Bool) {
            self.isGranted = isGranted
        }

        func request() {
            requestCount += 1
        }
    }

    private final class FakeAudioManager: MeetingAudioManaging {
        var onAudioLevel: ((Float) -> Void)?
        var onTranscriptionChunk: ((TranscriptionChunk) -> Void)?
        var onError: ((String) -> Void)?

        var startError: Error?
        var audioFileReferences: MeetingAudioFileReferences? {
            MeetingAudioFileReferences(
                micFileURL: stopResult.micFile,
                micSampleRate: stopResult.micRate,
                systemFileURL: stopResult.systemFile,
                systemSampleRate: stopResult.systemRate
            )
        }
        var stopResult: (
            micFile: URL?,
            micRate: Double,
            systemFile: URL?,
            systemRate: Double
        ) = (nil, 0, nil, 0)
        var samplesByURL: [URL: [Float]] = [:]

        private(set) var startCallCount = 0
        private(set) var stopCallCount = 0
        private(set) var cleanupCallCount = 0
        private(set) var readURLs: [URL?] = []
        private(set) var startedMicSource: AudioSource.MicrophoneSource?
        private(set) var startedAppSelection: AppSelection?
        private(set) var switchCalls: [(
            app: AudioApp?,
            micSource: AudioSource.MicrophoneSource
        )] = []

        // When set, start() suspends until releaseSuspendedStart() is called,
        // so tests can interleave cancel/stop while a start is in flight.
        var suspendStart = false
        private var startContinuation: CheckedContinuation<Void, Never>?

        func start(
            micSource: AudioSource.MicrophoneSource,
            appSelection: AppSelection
        ) async throws {
            startCallCount += 1
            startedMicSource = micSource
            startedAppSelection = appSelection
            if suspendStart {
                await withCheckedContinuation { continuation in
                    startContinuation = continuation
                }
            }
            if let startError {
                throw startError
            }
        }

        func releaseSuspendedStart() {
            startContinuation?.resume()
            startContinuation = nil
        }

        func stop() -> (
            micFile: URL?,
            micRate: Double,
            systemFile: URL?,
            systemRate: Double
        ) {
            stopCallCount += 1
            return stopResult
        }

        func switchApp(
            to app: AudioApp?,
            micSource: AudioSource.MicrophoneSource
        ) async throws {
            switchCalls.append((app, micSource))
        }

        func readSamplesFromFile(_ url: URL?) -> [Float] {
            readURLs.append(url)
            guard let url else { return [] }
            return samplesByURL[url] ?? []
        }

        func cleanupTempFiles() {
            cleanupCallCount += 1
        }

        func emitAudioLevel(_ level: Float) {
            onAudioLevel?(level)
        }

        func emitChunk(_ chunk: TranscriptionChunk) {
            onTranscriptionChunk?(chunk)
        }

        func emitError(_ message: String) {
            onError?(message)
        }
    }

    private final class FakeTranscriptManager: MeetingTranscriptManaging {
        var onSegmentsUpdated: (([MeetingSegment]) -> Void)?
        var audioFileReferenceProvider: (() -> MeetingAudioFileReferences?)?
        var recovery: MeetingCrashRecovery?
        var useLongRunningChunkTasks = false

        let sessionID = UUID()
        let autosaveFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("phase4c-autosave-\(UUID().uuidString).json")
        private(set) var resetCount = 0
        private(set) var startAutoSaveCount = 0
        private(set) var stopAutoSaveCount = 0
        private(set) var flushAutoSaveCount = 0
        private(set) var clearAutoSaveCount = 0
        private(set) var crashRecoveryCheckCount = 0
        private(set) var transcribeChunkCount = 0
        private(set) var selectedApps: [AudioApp?] = []
        private(set) var chunkTasks: [Task<Void, Never>] = []

        func reset() {
            resetCount += 1
        }

        func setSelectedApp(_ app: AudioApp?) {
            selectedApps.append(app)
        }

        func startAutoSave() {
            startAutoSaveCount += 1
        }

        func stopAutoSave() {
            stopAutoSaveCount += 1
        }

        func flushAutoSave() {
            flushAutoSaveCount += 1
        }

        func clearAutoSave() {
            clearAutoSaveCount += 1
        }

        func checkForCrashRecovery() -> MeetingCrashRecovery? {
            crashRecoveryCheckCount += 1
            return recovery
        }

        // When set, chunk tasks ignore cancellation and complete only on
        // releaseHeldChunkTasks() — lets tests keep stop() suspended at its
        // await while interleaving other operations.
        var holdChunkTasksUntilReleased = false
        private var chunkHoldContinuations: [CheckedContinuation<Void, Never>] = []

        @discardableResult
        func transcribeChunk(_ chunk: TranscriptionChunk) -> Task<Void, Never> {
            transcribeChunkCount += 1
            let longRunning = useLongRunningChunkTasks
            let held = holdChunkTasksUntilReleased
            let task = Task {
                if held {
                    await withCheckedContinuation { continuation in
                        self.chunkHoldContinuations.append(continuation)
                    }
                } else if longRunning {
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 1_000_000)
                    }
                }
            }
            chunkTasks.append(task)
            return task
        }

        func releaseHeldChunkTasks() {
            for continuation in chunkHoldContinuations {
                continuation.resume()
            }
            chunkHoldContinuations = []
        }

        func emitSegments(_ segments: [MeetingSegment]) {
            onSegmentsUpdated?(segments)
        }
    }

    // MARK: - Start Coordinator

    func testStartCoordinator_MicrophoneBlockedOpensSettingsAndBlocks() async throws {
        let transcriber = SpyTranscriber(isReady: false)
        let mic = FakeMicPermission(state: .denied)
        let screen = FakeScreenPermission(isGranted: true)
        let coordinator = MeetingStartCoordinator(
            transcriptionService: transcriber,
            screenPermission: screen,
            micPermission: mic
        )

        let outcome = try await coordinator.requestStart()

        XCTAssertEqual(outcome, .blocked("Microphone permission required"))
        XCTAssertEqual(mic.openSettingsCount, 1)
        XCTAssertEqual(screen.requestCount, 0)
        let prepareCount = await transcriber.snapshotPrepareCount()
        XCTAssertEqual(prepareCount, 0)
    }

    func testStartCoordinator_ScreenPermissionMissingRequestsAndWaits() async throws {
        let transcriber = SpyTranscriber(isReady: false)
        let mic = FakeMicPermission(state: .authorized)
        let screen = FakeScreenPermission(isGranted: false)
        let coordinator = MeetingStartCoordinator(
            transcriptionService: transcriber,
            screenPermission: screen,
            micPermission: mic
        )

        let outcome = try await coordinator.requestStart()

        XCTAssertEqual(outcome, .waitingForScreenRecording)
        XCTAssertEqual(screen.requestCount, 1)
        let prepareCount = await transcriber.snapshotPrepareCount()
        XCTAssertEqual(prepareCount, 0)
    }

    func testStartCoordinator_PreparesTranscriptionWhenPermissionsAreReady() async throws {
        let transcriber = SpyTranscriber(isReady: false)
        let coordinator = MeetingStartCoordinator(
            transcriptionService: transcriber,
            screenPermission: FakeScreenPermission(isGranted: true),
            micPermission: FakeMicPermission(state: .authorized)
        )

        let outcome = try await coordinator.requestStart()

        XCTAssertEqual(outcome, .readyToRecord)
        let prepareCount = await transcriber.snapshotPrepareCount()
        XCTAssertEqual(prepareCount, 1)
    }

    func testStartCoordinator_DoesNotPrepareWhenTranscriptionAlreadyReady() async throws {
        let transcriber = SpyTranscriber(isReady: true)
        let coordinator = MeetingStartCoordinator(
            transcriptionService: transcriber,
            screenPermission: FakeScreenPermission(isGranted: true),
            micPermission: FakeMicPermission(state: .authorized)
        )

        let outcome = try await coordinator.requestStart()

        XCTAssertEqual(outcome, .readyToRecord)
        let prepareCount = await transcriber.snapshotPrepareCount()
        XCTAssertEqual(prepareCount, 0)
    }

    func testStartCoordinator_PropagatesPrepareFailure() async {
        let transcriber = SpyTranscriber(isReady: false)
        await transcriber.setPrepareErrorForTest(TestError.prepareFailed)
        let coordinator = MeetingStartCoordinator(
            transcriptionService: transcriber,
            screenPermission: FakeScreenPermission(isGranted: true),
            micPermission: FakeMicPermission(state: .authorized)
        )

        do {
            _ = try await coordinator.requestStart()
            XCTFail("Expected prepare failure")
        } catch {
            XCTAssertTrue(error is TestError)
        }
    }

    // MARK: - Capture Session

    func testCaptureStart_UsesSelectedSourcesAndWiresCallbacks() async throws {
        let app = makeApp(name: "Zoom", pid: 10)
        let mic = makeMicrophone(uid: "mic-1")
        let audio = FakeAudioManager()
        let transcript = FakeTranscriptManager()
        let session = makeCaptureSession(audio: audio, transcript: transcript)

        var audioLevels: [Float] = []
        var segmentUpdates: [[MeetingSegment]] = []
        var errors: [String] = []
        session.onAudioLevel = { audioLevels.append($0) }
        session.onSegmentsUpdated = { segmentUpdates.append($0) }
        session.onError = { errors.append($0) }

        try await session.start(configuration: MeetingCaptureStartConfiguration(
            selectedApp: app,
            selectedMicrophone: mic,
            streamingEnabled: true
        ))

        XCTAssertEqual(audio.startCallCount, 1)
        XCTAssertEqual(micUID(audio.startedMicSource), "mic-1")
        XCTAssertEqual(selectionSnapshot(audio.startedAppSelection), .only(["Zoom"]))
        XCTAssertEqual(transcript.selectedApps.compactMap { $0?.name }, ["Zoom"])
        XCTAssertEqual(transcript.resetCount, 1)
        XCTAssertEqual(transcript.startAutoSaveCount, 1)

        let segment = makeSegment(text: "live")
        audio.emitAudioLevel(0.35)
        transcript.emitSegments([segment])
        audio.emitError("capture failed")

        XCTAssertEqual(audioLevels, [0.35])
        XCTAssertEqual(segmentUpdates, [[segment]])
        XCTAssertEqual(errors, ["capture failed"])

        session.cancel()
    }

    func testCaptureStart_DefaultsToSystemMicAndAllApps() async throws {
        let audio = FakeAudioManager()
        let transcript = FakeTranscriptManager()
        let session = makeCaptureSession(audio: audio, transcript: transcript)

        try await session.start(configuration: MeetingCaptureStartConfiguration(
            selectedApp: nil,
            selectedMicrophone: nil,
            streamingEnabled: true
        ))

        XCTAssertTrue(isSystemDefaultMic(audio.startedMicSource))
        XCTAssertEqual(selectionSnapshot(audio.startedAppSelection), .all)

        session.cancel()
    }

    func testCaptureStart_StreamingDisabledDoesNotRouteChunks() async throws {
        let audio = FakeAudioManager()
        let transcript = FakeTranscriptManager()
        let session = makeCaptureSession(audio: audio, transcript: transcript)

        try await session.start(configuration: MeetingCaptureStartConfiguration(
            selectedApp: nil,
            selectedMicrophone: nil,
            streamingEnabled: false
        ))

        audio.emitChunk(makeChunk())

        XCTAssertEqual(transcript.transcribeChunkCount, 0)

        session.cancel()
    }

    func testCaptureStopSave_CancelsChunksReadsSamplesAndKeepsRecoveryArtifacts() async throws {
        let app = makeApp(name: "Zoom", pid: 10)
        let micURL = URL(fileURLWithPath: "/tmp/phase4c-mic.raw")
        let systemURL = URL(fileURLWithPath: "/tmp/phase4c-system.raw")
        let audio = FakeAudioManager()
        audio.stopResult = (micURL, 44_100, systemURL, 48_000)
        audio.samplesByURL[micURL] = [0.1, 0.2]
        audio.samplesByURL[systemURL] = [0.3, 0.4, 0.5]

        let transcript = FakeTranscriptManager()
        transcript.useLongRunningChunkTasks = true
        let session = makeCaptureSession(audio: audio, transcript: transcript)

        try await session.start(configuration: MeetingCaptureStartConfiguration(
            selectedApp: app,
            selectedMicrophone: nil,
            streamingEnabled: true
        ))
        audio.emitChunk(makeChunk())

        let stopResult = await session.stop(saveToHistory: true)
        let captured = try XCTUnwrap(stopResult)

        XCTAssertEqual(transcript.transcribeChunkCount, 1)
        XCTAssertEqual(transcript.stopAutoSaveCount, 1)
        XCTAssertEqual(transcript.flushAutoSaveCount, 1)
        XCTAssertEqual(audio.stopCallCount, 1)
        XCTAssertEqual(audio.readURLs, [micURL, systemURL])
        XCTAssertEqual(captured.micSamples, [0.1, 0.2])
        XCTAssertEqual(captured.micSampleRate, 44_100)
        XCTAssertEqual(captured.systemSamples, [0.3, 0.4, 0.5])
        XCTAssertEqual(captured.systemSampleRate, 48_000)
        XCTAssertEqual(captured.appName, "Zoom")

        // Recovery artifacts must survive until the persistence commit
        // point: finalization and persistence still lie ahead of this
        // return, and a crash there must stay recoverable.
        XCTAssertEqual(transcript.clearAutoSaveCount, 0)
        XCTAssertEqual(audio.cleanupCallCount, 0)
        let artifacts = try XCTUnwrap(captured.recoveryArtifacts)
        XCTAssertEqual(artifacts.sessionID, transcript.sessionID)
        XCTAssertEqual(artifacts.micFileURL, micURL)
        XCTAssertEqual(artifacts.systemFileURL, systemURL)
    }

    func testCaptureStopWithoutSaveDiscardsRecoveryArtifactsImmediately() async throws {
        let audio = FakeAudioManager()
        let transcript = FakeTranscriptManager()
        let session = makeCaptureSession(audio: audio, transcript: transcript)

        try await session.start(configuration: MeetingCaptureStartConfiguration(
            selectedApp: nil,
            selectedMicrophone: nil,
            streamingEnabled: true
        ))

        let captured = await session.stop(saveToHistory: false)

        XCTAssertNil(captured)
        XCTAssertEqual(transcript.stopAutoSaveCount, 1)
        // A deliberate discard clears recovery data now — otherwise the
        // discarded meeting resurfaces as phantom "crash recovery".
        XCTAssertEqual(transcript.clearAutoSaveCount, 1)
        XCTAssertEqual(audio.stopCallCount, 1)
        XCTAssertEqual(audio.cleanupCallCount, 1)
        XCTAssertTrue(audio.readURLs.isEmpty)
    }

    func testCaptureSwitching_UpdatesTranscriptAndForwardsCaptureSwitches() async throws {
        let zoom = makeApp(name: "Zoom", pid: 10)
        let teams = makeApp(name: "Teams", pid: 11)
        let mic = makeMicrophone(uid: "mic-2")
        let audio = FakeAudioManager()
        let transcript = FakeTranscriptManager()
        let session = makeCaptureSession(audio: audio, transcript: transcript)

        try await session.start(configuration: MeetingCaptureStartConfiguration(
            selectedApp: zoom,
            selectedMicrophone: nil,
            streamingEnabled: true
        ))

        session.selectApp(teams)
        try? await Task.sleep(nanoseconds: 20_000_000)
        await session.switchMicrophone(to: mic, selectedApp: teams)

        XCTAssertEqual(transcript.selectedApps.compactMap { $0?.name }, ["Zoom", "Teams"])
        XCTAssertEqual(audio.switchCalls.count, 2)
        XCTAssertEqual(audio.switchCalls.first?.app?.name, "Teams")
        XCTAssertTrue(isSystemDefaultMic(audio.switchCalls.first?.micSource))
        XCTAssertEqual(audio.switchCalls.last?.app?.name, "Teams")
        XCTAssertEqual(micUID(audio.switchCalls.last?.micSource), "mic-2")

        session.cancel()
    }

    func testCaptureCrashRecoveryDoesNotDestroyAutosaveOnRead() async {
        let segment = makeSegment(text: "recovered")
        let audio = FakeAudioManager()
        let transcript = FakeTranscriptManager()
        transcript.recovery = MeetingCrashRecovery(
            segments: [segment],
            duration: 42,
            appName: nil,
            sessionID: transcript.sessionID,
            autosaveFileURL: transcript.autosaveFileURL,
            audioFiles: nil
        )
        let session = makeCaptureSession(audio: audio, transcript: transcript)

        let recovery = session.checkCrashRecovery()

        XCTAssertEqual(recovery?.segments, [segment])
        XCTAssertEqual(recovery?.duration, 42)
        XCTAssertEqual(transcript.crashRecoveryCheckCount, 1)
        // Reading recovery data must not delete it: a second crash before
        // the recovered meeting is saved would otherwise erase it for good.
        XCTAssertEqual(transcript.clearAutoSaveCount, 0)
    }

    func testCaptureStartFailureCleansTempFilesAndDoesNotLeaveSessionActive() async throws {
        let audio = FakeAudioManager()
        audio.startError = TestError.startFailed
        let transcript = FakeTranscriptManager()
        let session = makeCaptureSession(audio: audio, transcript: transcript)

        do {
            try await session.start(configuration: MeetingCaptureStartConfiguration(
                selectedApp: nil,
                selectedMicrophone: nil,
                streamingEnabled: true
            ))
            XCTFail("Expected capture start failure")
        } catch {
            XCTAssertTrue(error is TestError)
        }

        XCTAssertEqual(audio.cleanupCallCount, 1)
        XCTAssertFalse(session.isRecording)
        let captured = await session.stop(saveToHistory: true)
        XCTAssertNil(captured)
    }

    func testCancelDuringStartNeverPublishesAndStopsTheStartedAudio() async throws {
        let audio = FakeAudioManager()
        audio.suspendStart = true
        let transcript = FakeTranscriptManager()
        let session = makeCaptureSession(audio: audio, transcript: transcript)

        let startTask = Task {
            try await session.start(configuration: MeetingCaptureStartConfiguration(
                selectedApp: nil,
                selectedMicrophone: nil,
                streamingEnabled: true
            ))
        }
        var spins = 0
        while audio.startCallCount == 0 {
            await Task.yield()
            spins += 1
            if spins > 10_000 {
                XCTFail("audio.start was never reached")
                return
            }
        }

        // User cancels while the panel shows "Preparing...".
        session.cancel()
        audio.releaseSuspendedStart()

        do {
            try await startTask.value
            XCTFail("Expected CancellationError from superseded start")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // The capture that finished starting after the cancel must be torn
        // down, not published: no phantom recording, no orphaned hot mic,
        // no timers on a discarded session.
        XCTAssertFalse(session.isRecording)
        XCTAssertEqual(audio.stopCallCount, 1)
        XCTAssertEqual(audio.cleanupCallCount, 1)
        XCTAssertEqual(transcript.startAutoSaveCount, 0)
    }

    // MARK: - Sleep/Wake (CF-16)

    /// The wall clock keeps running through system sleep; the audio does
    /// not. Persisted duration must come from the captured samples, so a
    /// meeting slept through the lid-close reports what was recorded, not
    /// how long the laptop was shut.
    func testStopDerivesDurationFromCapturedSamples() async throws {
        let micURL = URL(fileURLWithPath: "/tmp/phase4c-duration-\(UUID().uuidString).raw")
        let audio = FakeAudioManager()
        audio.stopResult = (micURL, 16_000, nil, 0)
        audio.samplesByURL[micURL] = tone(seconds: 3)
        let transcript = FakeTranscriptManager()
        let session = makeCaptureSession(audio: audio, transcript: transcript)

        try await session.start(configuration: MeetingCaptureStartConfiguration(
            selectedApp: nil, selectedMicrophone: nil, streamingEnabled: true
        ))
        let captured = await session.stop(saveToHistory: true)

        XCTAssertEqual(captured?.duration ?? 0, 3.0, accuracy: 0.01,
                       "Duration = samples/rate, immune to wall-clock skew")
    }

    /// Sleep can arrive while the autosave is up to 60s stale, and the
    /// machine may never wake (battery dies shut) — the recovery file must
    /// be flushed BEFORE the system goes down.
    func testWillSleepFlushesAutoSaveWhileRecording() async throws {
        let audio = FakeAudioManager()
        let transcript = FakeTranscriptManager()
        let session = makeCaptureSession(audio: audio, transcript: transcript)
        try await session.start(configuration: MeetingCaptureStartConfiguration(
            selectedApp: nil, selectedMicrophone: nil, streamingEnabled: true
        ))
        let flushesBefore = transcript.flushAutoSaveCount

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.willSleepNotification, object: nil
        )
        var spins = 0
        while transcript.flushAutoSaveCount == flushesBefore, spins < 10_000 {
            await Task.yield()
            spins += 1
        }

        XCTAssertGreaterThan(transcript.flushAutoSaveCount, flushesBefore,
                             "Sleep must flush the recovery autosave first")
        _ = await session.stop(saveToHistory: false)
    }

    func testStopStartOverlapDoesNotClobberTheNewSession() async throws {
        let firstMicURL = URL(fileURLWithPath: "/tmp/phase4c-overlap-mic.raw")
        let firstAudio = FakeAudioManager()
        firstAudio.stopResult = (firstMicURL, 16_000, nil, 0)
        firstAudio.samplesByURL[firstMicURL] = [0.5]
        let secondAudio = FakeAudioManager()
        let firstTranscript = FakeTranscriptManager()
        firstTranscript.holdChunkTasksUntilReleased = true
        let secondTranscript = FakeTranscriptManager()

        var audios = [firstAudio, secondAudio]
        var transcripts = [firstTranscript, secondTranscript]
        let session = MeetingCaptureSession(
            transcriptionService: SpyTranscriber(),
            audioManagerFactory: { audios.removeFirst() },
            transcriptManagerFactory: { transcripts.removeFirst() }
        )

        try await session.start(configuration: MeetingCaptureStartConfiguration(
            selectedApp: nil,
            selectedMicrophone: nil,
            streamingEnabled: true
        ))
        firstAudio.emitChunk(makeChunk())

        // Stop suspends awaiting the held chunk task — the exact window in
        // which a user (Escape during processing, then Start) can begin a
        // new meeting.
        let stopTask = Task {
            await session.stop(saveToHistory: true)
        }
        var spins = 0
        while firstAudio.stopCallCount == 0 {
            await Task.yield()
            spins += 1
            if spins > 10_000 {
                XCTFail("audio.stop was never reached")
                return
            }
        }

        try await session.start(configuration: MeetingCaptureStartConfiguration(
            selectedApp: nil,
            selectedMicrophone: nil,
            streamingEnabled: true
        ))
        XCTAssertTrue(session.isRecording)

        firstTranscript.releaseHeldChunkTasks()
        let captured = await stopTask.value

        // The finishing stop returns its own session's audio...
        XCTAssertEqual(captured?.micSamples, [0.5])
        // ...and the new session is untouched: still recording, its audio
        // never stopped, its recovery data never cleared.
        XCTAssertTrue(session.isRecording)
        XCTAssertEqual(secondAudio.stopCallCount, 0)
        XCTAssertEqual(secondAudio.cleanupCallCount, 0)
        XCTAssertEqual(secondTranscript.stopAutoSaveCount, 0)
        XCTAssertEqual(secondTranscript.clearAutoSaveCount, 0)
        XCTAssertEqual(secondTranscript.startAutoSaveCount, 1)

        session.cancel()
    }

    // MARK: - Handler Integration

    func testPipelineHandlerStartStopCoordinatesExtractedServicesAndFinalization() async throws {
        let transcriber = SpyTranscriber(isReady: true, text: "final text")
        let app = makeApp(name: "Zoom", pid: 10)
        let micURL = URL(fileURLWithPath: "/tmp/phase4c-handler-mic.raw")
        let audio = FakeAudioManager()
        audio.stopResult = (micURL, 16_000, nil, 0)
        audio.samplesByURL[micURL] = tone(seconds: 1)

        let transcript = FakeTranscriptManager()
        let captureSession = makeCaptureSession(
            transcriber: transcriber,
            audio: audio,
            transcript: transcript
        )
        let startCoordinator = MeetingStartCoordinator(
            transcriptionService: transcriber,
            screenPermission: FakeScreenPermission(isGranted: true),
            micPermission: FakeMicPermission(state: .authorized)
        )
        let state = ModeRuntimeState()
        state.selectedApp = app
        let settings = SettingsService(
            defaults: try XCTUnwrap(UserDefaults(suiteName: "Phase4C-\(UUID().uuidString)"))
        )
        let handler = MeetingPipelineHandler(
            state: state,
            transcriptionService: transcriber,
            screenPermission: ScreenRecordingPermissionService(),
            micPermission: MicrophonePermissionService(),
            settings: settings,
            startCoordinator: startCoordinator,
            captureSession: captureSession
        )

        await handler.start()

        XCTAssertEqual(state.phase, .recording)
        XCTAssertEqual(audio.startCallCount, 1)

        let stopResult = await handler.stop(saveToHistory: true)
        let payload = try XCTUnwrap(stopResult)

        XCTAssertEqual(state.phase, .processing)
        XCTAssertEqual(payload.appName, "Zoom")
        XCTAssertEqual(payload.micSamples, tone(seconds: 1))
        XCTAssertEqual(payload.micSampleRate, 16_000)
        XCTAssertEqual(payload.segments.map(\.text), ["final text"])
        XCTAssertEqual(state.segments, payload.segments)
    }

    func testPipelineHandlerStartShowsPreparingWhileTranscriptionPrepares() async throws {
        let transcriber = SpyTranscriber(isReady: false)
        await transcriber.suspendPrepareForTest()
        let audio = FakeAudioManager()
        let captureSession = makeCaptureSession(
            transcriber: transcriber,
            audio: audio,
            transcript: FakeTranscriptManager()
        )
        let state = ModeRuntimeState()
        let settings = SettingsService(
            defaults: try XCTUnwrap(UserDefaults(suiteName: "Phase4C-\(UUID().uuidString)"))
        )
        let handler = MeetingPipelineHandler(
            state: state,
            transcriptionService: transcriber,
            screenPermission: ScreenRecordingPermissionService(),
            micPermission: MicrophonePermissionService(),
            settings: settings,
            startCoordinator: MeetingStartCoordinator(
                transcriptionService: transcriber,
                screenPermission: FakeScreenPermission(isGranted: true),
                micPermission: FakeMicPermission(state: .authorized)
            ),
            captureSession: captureSession
        )

        let startTask = Task {
            await handler.start()
        }
        await transcriber.waitForPrepareStart()

        XCTAssertEqual(state.phase, .preparing)
        XCTAssertEqual(audio.startCallCount, 0)

        await transcriber.finishSuspendedPrepare()
        await startTask.value

        XCTAssertEqual(state.phase, .recording)
        XCTAssertEqual(audio.startCallCount, 1)
        handler.cancel()
    }

    func testPipelineHandlerStopWithoutCaptureDoesNotEnterProcessing() async throws {
        let transcriber = SpyTranscriber(isReady: true)
        let captureSession = makeCaptureSession(
            transcriber: transcriber,
            audio: FakeAudioManager(),
            transcript: FakeTranscriptManager()
        )
        let state = ModeRuntimeState()
        let settings = SettingsService(
            defaults: try XCTUnwrap(UserDefaults(suiteName: "Phase4C-\(UUID().uuidString)"))
        )
        let handler = MeetingPipelineHandler(
            state: state,
            transcriptionService: transcriber,
            screenPermission: ScreenRecordingPermissionService(),
            micPermission: MicrophonePermissionService(),
            settings: settings,
            captureSession: captureSession
        )

        let payload = await handler.stop(saveToHistory: true)

        XCTAssertNil(payload)
        XCTAssertEqual(state.phase, .idle)
    }

    // MARK: - Helpers

    private enum SelectionSnapshot: Equatable {
        case all
        case only([String])
        case excluding([String])
    }

    private func makeCaptureSession(
        transcriber: any TranscriptionProviding = SpyTranscriber(),
        audio: FakeAudioManager,
        transcript: FakeTranscriptManager
    ) -> MeetingCaptureSession {
        MeetingCaptureSession(
            transcriptionService: transcriber,
            audioManagerFactory: { audio },
            transcriptManagerFactory: { transcript }
        )
    }

    private func makeApp(name: String, pid: pid_t) -> AudioApp {
        AudioApp(
            pid: pid,
            bundleIdentifier: "com.example.\(name.lowercased())",
            name: name
        )
    }

    private func makeMicrophone(uid: String) -> AudioDevice {
        AudioDevice(
            id: AudioDeviceID(1),
            uid: uid,
            name: "Mic \(uid)",
            transportType: .builtIn
        )
    }

    private func makeSegment(text: String) -> MeetingSegment {
        MeetingSegment(
            text: text,
            speakerId: "You",
            isFromMicrophone: true,
            startTime: 0,
            endTime: 1
        )
    }

    private func makeChunk() -> TranscriptionChunk {
        TranscriptionChunk(
            samples: [0.1, 0.2],
            source: .microphone,
            timestamp: Date()
        )
    }

    private func tone(seconds: Double, sampleRate: Double = 16_000) -> [Float] {
        let count = Int(seconds * sampleRate)
        return (0..<count).map { i in
            Float(sin(Double(i) * 2.0 * .pi * 440.0 / sampleRate) * 0.5)
        }
    }

    private func micUID(_ source: AudioSource.MicrophoneSource?) -> String? {
        guard let source else { return nil }
        switch source {
        case .systemDefault:
            return nil
        case .specific(let device):
            return device.uid
        }
    }

    private func isSystemDefaultMic(_ source: AudioSource.MicrophoneSource?) -> Bool {
        guard let source else { return false }
        if case .systemDefault = source {
            return true
        }
        return false
    }

    private func selectionSnapshot(_ selection: AppSelection?) -> SelectionSnapshot? {
        guard let selection else { return nil }
        switch selection {
        case .all:
            return .all
        case .only(let apps):
            return .only(apps.map(\.name))
        case .excluding(let apps):
            return .excluding(apps.map(\.name))
        }
    }
}
