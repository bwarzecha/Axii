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
    func checkCrashRecovery()
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

    // MARK: - Initialization

    init(
        state: ModeRuntimeState,
        transcriptionService: any TranscriptionProviding,
        diarizationService: DiarizationService?,
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
        self.finalizationService.onProgressUpdated = { [weak state] progress, status in
            state?.processingProgress = progress
            state?.processingStatus = status
        }
        wireCaptureSessionCallbacks()
    }

    // MARK: - Start

    func start() async {
        do {
            switch try await startCoordinator.requestStart(
                onPreparing: { [weak state] in
                    state?.phase = .preparing
                }
            ) {
            case .readyToRecord:
                try await beginRecording()
            case .waitingForScreenRecording:
                state.phase = .preparing
                startCoordinator.startScreenPermissionPolling(
                    while: { [weak state] in state?.phase == .preparing },
                    onGranted: { [weak self] in
                        await self?.prepareAndRecordAfterScreenPermissionGrant()
                    }
                )
            case .blocked(let message):
                state.phase = .error(message)
            }
        } catch {
            state.phase = .error("Failed: \(error.localizedDescription)")
        }
    }

    private func prepareAndRecordAfterScreenPermissionGrant() async {
        do {
            state.phase = .preparing
            try await startCoordinator.prepareAfterScreenPermissionGrant()
            try await beginRecording()
        } catch {
            state.phase = .error("Failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Stop

    func stop(saveToHistory: Bool) async -> MeetingStopResult? {
        if saveToHistory && captureSession.isRecording {
            state.phase = .processing
        }

        guard let capturedAudio = await captureSession.stop(
            saveToHistory: saveToHistory
        ) else {
            return nil
        }

        let payload = await finalizationService.finalize(
            input: MeetingFinalizationInput(
                micSamples: capturedAudio.micSamples,
                micSampleRate: capturedAudio.micSampleRate,
                systemSamples: capturedAudio.systemSamples,
                systemSampleRate: capturedAudio.systemSampleRate,
                duration: capturedAudio.duration,
                appName: capturedAudio.appName
            )
        )

        // Reflect the finalized transcript in live state so the UI can
        // show the final transcript before persistence completes.
        state.segments = payload.segments

        return payload
    }

    // MARK: - Cancel

    func cancel() {
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

    // MARK: - Crash Recovery

    func checkCrashRecovery() {
        if let recovery = captureSession.checkCrashRecovery() {
            state.segments = recovery.segments
            state.duration = recovery.duration
        }
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
        captureSession.onError = { [weak state] message in
            state?.phase = .error(message)
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
