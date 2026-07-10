//
//  MeetingPipelineHandler.swift
//  Axii
//
//  Coordinates meeting-specific runtime flow: start gates, capture session,
//  finalization, and state updates.
//

#if os(macOS)
import Foundation

// MARK: - Meeting App Constants

enum MeetingAppConstants {
    /// Bundle identifiers for apps commonly used in meetings.
    /// Used to sort app picker results with meeting apps first.
    static let prioritizedBundleIDs: Set<String> = [
        "us.zoom.xos",
        "com.google.Chrome",
        "com.apple.Safari",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.cisco.webexmeetingsapp",
        "com.apple.FaceTime",
        "com.slack.Slack",
        "com.discord.Discord",
        "com.brave.Browser",
        "org.mozilla.firefox",
    ]
}

// MARK: - MeetingStopResult

/// Backward-compatible alias. The canonical boundary type is now
/// MeetingPersistencePayload, defined in its own file.
typealias MeetingStopResult = MeetingPersistencePayload

// MARK: - MeetingPipelineHandling

/// Adapter-facing surface for meeting runtime coordination.
@MainActor
protocol MeetingPipelineHandling: AnyObject {
    func start() async
    func stop(saveToHistory: Bool) async -> MeetingStopResult?
    func cancel()
    func selectApp(_ app: AudioApp?)
    func switchMicrophone(
        to device: AudioDevice?,
        micSource: AudioSource.MicrophoneSource
    ) async
    func refreshAppList() async
    @discardableResult
    func checkCrashRecovery() -> MeetingCrashRecovery?
    /// True while audio is actively being captured — exits that would
    /// destroy a live capture consult this to salvage instead.
    var hasLiveCapture: Bool { get }
}

// MARK: - MeetingPipelineHandler

@MainActor
final class MeetingPipelineHandler: MeetingPipelineHandling {

    // MARK: - Dependencies

    private let settings: SettingsService
    private let state: ModeRuntimeState
    private let finalizationService: MeetingFinalizationService
    private let startCoordinator: MeetingStartCoordinator
    private let captureSession: MeetingCaptureSession

    // Bumped by start/stop/cancel. A stop that resumes from finalization and
    // finds the generation changed must not write to state — a newer session
    // owns the UI now.
    private var generation = 0

    // MARK: - Initialization

    init(
        state: ModeRuntimeState,
        transcriptionService: any TranscriptionProviding,
        screenPermission: ScreenRecordingPermissionService,
        micPermission: MicrophonePermissionService,
        settings: SettingsService,
        finalizationService: MeetingFinalizationService? = nil,
        startCoordinator: MeetingStartCoordinator? = nil,
        captureSession: MeetingCaptureSession? = nil
    ) {
        self.state = state
        self.settings = settings
        self.finalizationService = finalizationService
            ?? MeetingFinalizationService(transcriptionService: transcriptionService)
        self.startCoordinator = startCoordinator ?? MeetingStartCoordinator(
            transcriptionService: transcriptionService,
            screenPermission: screenPermission,
            micPermission: micPermission
        )
        self.captureSession = captureSession ?? MeetingCaptureSession(
            transcriptionService: transcriptionService
        )
        wireCaptureSessionCallbacks()
    }

    // MARK: - Start

    func start() async {
        generation += 1
        let gen = generation
        do {
            state.phase = .preparing
            let outcome = try await startCoordinator.requestStart()
            // The await above can take seconds (ASR model load). If the user
            // cancelled or restarted meanwhile, this start no longer owns the
            // session and must not launch a capture behind a closed panel.
            guard generation == gen else { return }
            switch outcome {
            case .readyToRecord:
                try await beginRecording()
            case .waitingForScreenRecording:
                // Once the user grants permission, run the whole start gate
                // again — the permission preflight is live, so it now passes
                // straight through to recording. One start flow, not two.
                startCoordinator.startScreenPermissionPolling(
                    while: { [weak state] in state?.phase == .preparing },
                    onGranted: { [weak self] in
                        await self?.start()
                    }
                )
            case .blocked(let message):
                state.phase = .error(message)
            }
        } catch is CancellationError {
            // A newer cancel/stop/start superseded this start mid-flight;
            // whoever did owns the UI phase now.
        } catch {
            if generation == gen {
                state.phase = .error("Failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Stop

    func stop(saveToHistory: Bool) async -> MeetingStopResult? {
        generation += 1
        let gen = generation

        if saveToHistory && captureSession.isRecording {
            state.phase = .processing
        } else if !saveToHistory {
            // Discard is immediate from the user's perspective; do not hold
            // the UI hostage to audio teardown.
            state.phase = .idle
        } else if state.phase == .preparing {
            // A save-stop that lands while a start is still preparing (a
            // stale Stop click racing an error retry): the generation bump
            // above supersedes that start — it will publish nothing — so
            // the phase must not stay parked at .preparing forever.
            state.phase = .idle
        }

        // Snapshot the streamed transcript before finalization can replace
        // it: if final transcription fails wholesale, the live segments are
        // the best copy in existence and must not be overwritten by nothing.
        let liveSegments = state.segments

        guard let capturedAudio = await captureSession.stop(
            saveToHistory: saveToHistory
        ) else {
            return nil
        }

        var payload = await finalizationService.finalize(
            input: MeetingFinalizationInput(
                micSamples: capturedAudio.micSamples,
                micSampleRate: capturedAudio.micSampleRate,
                systemSamples: capturedAudio.systemSamples,
                systemSampleRate: capturedAudio.systemSampleRate,
                duration: capturedAudio.duration,
                appName: capturedAudio.appName
            ),
            onProgress: { [weak self] progress, status in
                guard let self, self.generation == gen else { return }
                self.state.processingProgress = progress
                self.state.processingStatus = status
            }
        )

        if payload.segments.isEmpty, !liveSegments.isEmpty {
            payload.segments = liveSegments
        }

        payload.recoveryArtifacts = capturedAudio.recoveryArtifacts

        // Reflect the finalized transcript in live state so the UI can show
        // the final transcript before persistence completes — unless a newer
        // session owns the UI now.
        if generation == gen {
            state.segments = payload.segments
        }

        return payload
    }

    // MARK: - Cancel

    func cancel() {
        generation += 1
        startCoordinator.cancelPermissionPolling()
        captureSession.cancel()
    }

    // MARK: - App Selection

    func selectApp(_ app: AudioApp?) {
        state.selectedApp = app
        captureSession.selectApp(app)
    }

    // MARK: - Microphone Switching

    func switchMicrophone(
        to device: AudioDevice?,
        micSource: AudioSource.MicrophoneSource
    ) async {
        state.selectedMicrophone = device
        await captureSession.switchMicrophone(
            to: device,
            selectedApp: state.selectedApp,
            micSource: micSource
        )
    }

    // MARK: - App List

    func refreshAppList() async {
        let apps = await MeetingAudioManager.audioProducingApps()
        state.availableApps = sortAppsForMeetings(apps)
    }

    var hasLiveCapture: Bool {
        captureSession.isRecording
    }

    // MARK: - Crash Recovery

    @discardableResult
    func checkCrashRecovery() -> MeetingCrashRecovery? {
        guard let recovery = captureSession.checkCrashRecovery() else { return nil }
        state.segments = recovery.segments
        state.duration = recovery.duration
        return recovery
    }

    // MARK: - Private: Capture Session

    private func beginRecording() async throws {
        try await captureSession.start(
            configuration: MeetingCaptureStartConfiguration(
                selectedApp: state.selectedApp,
                selectedMicrophone: state.selectedMicrophone,
                streamingEnabled: settings.isMeetingStreamingEnabled
            )
        )
        state.phase = .recording
    }

    private func wireCaptureSessionCallbacks() {
        captureSession.onAudioLevel = { [weak state] level in
            state?.audioLevel = level
        }
        captureSession.onSegmentsUpdated = { [weak state] segments in
            state?.segments = segments
        }
        captureSession.onError = { [weak self] message in
            guard let self else { return }
            // Protect the recording FIRST: errors often precede an exit,
            // and the recovery file may be up to 60s stale.
            if self.captureSession.isRecording {
                self.captureSession.flushAutoSaveNow()
            }
            self.state.phase = .error(message)
        }
        captureSession.onDurationUpdated = { [weak state] duration in
            state?.duration = duration
        }
    }

    // MARK: - Private: App Sorting

    private func sortAppsForMeetings(_ apps: [AudioApp]) -> [AudioApp] {
        return apps.sorted { app1, app2 in
            let isMeeting1 = MeetingAppConstants.prioritizedBundleIDs.contains(
                app1.bundleIdentifier ?? ""
            )
            let isMeeting2 = MeetingAppConstants.prioritizedBundleIDs.contains(
                app2.bundleIdentifier ?? ""
            )
            if isMeeting1 && !isMeeting2 { return true }
            if !isMeeting1 && isMeeting2 { return false }
            return app1.name < app2.name
        }
    }
}
#endif
