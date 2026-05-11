//
//  MeetingPipelineHandler.swift
//  Axii
//
//  Encapsulates meeting-specific pipeline logic: dual audio capture,
//  streaming transcription, permission checks, crash recovery, and processing.
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

    private let transcriptionService: any TranscriptionProviding
    private let diarizationService: DiarizationService?
    private let screenPermission: ScreenRecordingPermissionService
    private let micPermission: MicrophonePermissionService
    private let settings: SettingsService
    private let state: ModeRuntimeState

    // MARK: - Managers

    private var audioManager: MeetingAudioManager?
    private var transcriptManager: MeetingTranscriptManager?

    // MARK: - Timers & Tasks

    private var durationTimer: Timer?
    private var chunkTranscriptionTasks: [Task<Void, Never>] = []
    private var recordingStartTime: Date?
    private var permissionPollTimer: Timer?

    // MARK: - Initialization

    init(
        state: ModeRuntimeState,
        transcriptionService: any TranscriptionProviding,
        diarizationService: DiarizationService?,
        screenPermission: ScreenRecordingPermissionService,
        micPermission: MicrophonePermissionService,
        settings: SettingsService
    ) {
        self.state = state
        self.transcriptionService = transcriptionService
        self.diarizationService = diarizationService
        self.screenPermission = screenPermission
        self.micPermission = micPermission
        self.settings = settings
    }

    // MARK: - Start

    func start() async {
        // 1. Check microphone permission
        if micPermission.state.isBlocked {
            state.phase = .error("Microphone permission required")
            micPermission.openSystemSettings()
            return
        }

        // 2. Check screen recording permission
        guard screenPermission.isGranted else {
            state.phase = .preparing
            screenPermission.request()
            startPermissionPolling()
            return
        }

        await prepareAndRecord()
    }

    // MARK: - Stop

    func stop(saveToHistory: Bool) async -> MeetingStopResult? {
        // Invalidate timers
        durationTimer?.invalidate()
        durationTimer = nil

        transcriptManager?.stopAutoSave()

        // Cancel pending chunk tasks
        let pendingTasks = chunkTranscriptionTasks
        for task in pendingTasks { task.cancel() }
        chunkTranscriptionTasks = []

        guard let audio = audioManager else { return nil }
        let (micFile, micRate, systemFile, systemRate) = audio.stop()
        let duration = state.duration

        if saveToHistory {
            state.phase = .processing

            // Wait for cancelled chunk tasks to finish
            for task in pendingTasks { await task.value }

            // Read original-quality audio from temp files
            let micSamples = audio.readSamplesFromFile(micFile)
            let systemSamples = audio.readSamplesFromFile(systemFile)

            // Final transcription (resamples to 16kHz internally)
            await transcriptManager?.transcribeFullAudio(
                micSamples: micSamples,
                micSampleRate: micRate,
                systemSamples: systemSamples,
                systemSampleRate: systemRate
            )

            transcriptManager?.clearAutoSave()
            audio.cleanupTempFiles()

            return MeetingStopResult(
                micSamples: micSamples,
                micSampleRate: micRate,
                systemSamples: systemSamples,
                systemSampleRate: systemRate,
                segments: transcriptManager?.segments ?? [],
                duration: duration,
                appName: state.selectedApp?.name
            )
        } else {
            audio.cleanupTempFiles()
            return nil
        }
    }

    // MARK: - Cancel

    func cancel() {
        durationTimer?.invalidate()
        durationTimer = nil
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil

        transcriptManager?.stopAutoSave()

        for task in chunkTranscriptionTasks { task.cancel() }
        chunkTranscriptionTasks = []

        _ = audioManager?.stop()
        audioManager?.cleanupTempFiles()
    }

    // MARK: - App Selection

    func selectApp(_ app: AudioApp?) {
        state.selectedApp = app
        transcriptManager?.setSelectedApp(app)

        if state.phase.isRecording {
            Task {
                let micSource = resolveMicSource()
                try? await audioManager?.switchApp(
                    to: app,
                    micSource: micSource
                )
            }
        }
    }

    // MARK: - Microphone Switching

    func switchMicrophone(
        to device: AudioDevice?,
        micSource: AudioSource.MicrophoneSource
    ) async {
        state.selectedMicrophone = device

        if state.phase.isRecording {
            try? await audioManager?.switchApp(
                to: state.selectedApp,
                micSource: micSource
            )
        }
    }

    // MARK: - App List

    func refreshAppList() async {
        let apps = await MeetingAudioManager.audioProducingApps()
        state.availableApps = sortAppsForMeetings(apps)
    }

    // MARK: - Crash Recovery

    func checkCrashRecovery() {
        let transcript = MeetingTranscriptManager(
            transcriptionService: transcriptionService
        )
        if let recovery = transcript.checkForCrashRecovery() {
            state.segments = recovery.segments
            state.duration = recovery.duration
            transcript.clearAutoSave()
        }
    }

    // MARK: - Private: Prepare & Record

    private func prepareAndRecord() async {
        state.phase = .preparing

        do {
            // Prepare transcription model if needed
            let isReady = await transcriptionService.isReady
            if !isReady {
                try await transcriptionService.prepare()
            }

            try await beginRecording()
        } catch {
            state.phase = .error("Failed: \(error.localizedDescription)")
        }
    }

    private func beginRecording() async throws {
        chunkTranscriptionTasks = []

        // Create managers
        let audio = MeetingAudioManager()
        let transcript = MeetingTranscriptManager(
            transcriptionService: transcriptionService
        )
        audioManager = audio
        transcriptManager = transcript

        // Wire audio callbacks
        audio.onAudioLevel = { [weak self] level in
            self?.state.audioLevel = level
        }

        if settings.isMeetingStreamingEnabled {
            audio.onTranscriptionChunk = { [weak self] chunk in
                guard let self, let manager = self.transcriptManager else {
                    return
                }
                let task = manager.transcribeChunk(chunk)
                self.chunkTranscriptionTasks.append(task)
                if self.chunkTranscriptionTasks.count > 20 {
                    self.chunkTranscriptionTasks.removeAll {
                        $0.isCancelled
                    }
                }
            }
        }

        audio.onError = { [weak self] message in
            self?.state.phase = .error(message)
        }

        // Wire transcript callbacks
        transcript.onSegmentsUpdated = { [weak self] segments in
            self?.state.segments = segments
        }
        transcript.onProgressUpdated = { [weak self] progress, status in
            self?.state.processingProgress = progress
            self?.state.processingStatus = status
        }

        transcript.setSelectedApp(state.selectedApp)
        transcript.reset()

        // Determine sources
        let micSource = resolveMicSource()
        let appSelection = resolveAppSelection()

        try await audio.start(
            micSource: micSource,
            appSelection: appSelection
        )

        state.phase = .recording

        // Start auto-save
        transcript.startAutoSave()

        // Start duration timer
        let startTime = Date()
        recordingStartTime = startTime
        durationTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.state.duration = Date().timeIntervalSince(startTime)
            }
        }
    }

    // MARK: - Private: Permission Polling

    private func startPermissionPolling() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0,
            repeats: true
        ) { [weak self] timer in
            Task { @MainActor in
                guard let self else {
                    timer.invalidate()
                    return
                }
                guard self.state.phase == .preparing else {
                    timer.invalidate()
                    self.permissionPollTimer = nil
                    return
                }
                if self.screenPermission.isGranted {
                    timer.invalidate()
                    self.permissionPollTimer = nil
                    await self.prepareAndRecord()
                }
            }
        }
    }

    // MARK: - Private: Source Resolution

    private func resolveMicSource() -> AudioSource.MicrophoneSource {
        if let device = state.selectedMicrophone {
            return .specific(device)
        }
        return .systemDefault
    }

    private func resolveAppSelection() -> AppSelection {
        if let app = state.selectedApp {
            return .only([app])
        }
        return .all
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
