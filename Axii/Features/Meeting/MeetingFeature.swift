//
//  MeetingFeature.swift
//  Axii
//
//  Meeting transcription feature with You vs Remote speaker labels.
//  Uses combined audio capture (mic + system audio) for meeting transcription.
//

#if os(macOS)
import AppKit
import SwiftUI

/// Meeting transcription feature with You vs Remote speaker labels.
@MainActor
final class MeetingFeature: Feature {
    let state = MeetingState()
    private var context: FeatureContext?
    private(set) var isActive = false

    // Services
    private let transcriptionService: TranscriptionService
    private let screenPermission: ScreenRecordingPermissionService
    private let micPermission: MicrophonePermissionService
    private let settings: SettingsService
    private let historyService: HistoryService

    // Managers
    private var audioManager: MeetingAudioManager?
    private var transcriptManager: MeetingTranscriptManager?

    // Timers
    private var durationTimer: Timer?

    // Pending chunk transcription tasks (must be cancelled before final transcription)
    private var chunkTranscriptionTasks: [Task<Void, Never>] = []

    // Device selection persistence
    private let deviceUIDKey = "meetingSelectedMicUID"
    private var selectedDeviceUID: String? {
        get { UserDefaults.standard.string(forKey: deviceUIDKey) }
        set { UserDefaults.standard.set(newValue, forKey: deviceUIDKey) }
    }

    // Panel mode persistence
    private let panelModeKey = "meetingPanelMode"
    private var savedPanelMode: MeetingPanelMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: panelModeKey),
                  let mode = MeetingPanelMode(rawValue: raw) else {
                return .expanded
            }
            return mode
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: panelModeKey)
        }
    }

    private let deviceListMonitor = DeviceMonitor()

    // MARK: - Initialization

    init(
        transcriptionService: TranscriptionService,
        screenPermission: ScreenRecordingPermissionService,
        micPermission: MicrophonePermissionService,
        settings: SettingsService,
        historyService: HistoryService
    ) {
        self.transcriptionService = transcriptionService
        self.screenPermission = screenPermission
        self.micPermission = micPermission
        self.settings = settings
        self.historyService = historyService
    }

    // MARK: - Feature Protocol

    var panelContent: AnyView {
        AnyView(MeetingPanelView(
            state: state,
            animationStyle: settings.meetingAnimationStyle,
            onStart: { [weak self] in self?.startMeeting() },
            onStop: { [weak self] in self?.stopMeeting() },
            onClose: { [weak self] in self?.closePanel() },
            onMicrophoneSwitch: { [weak self] device in
                self?.switchMicrophone(to: device)
            },
            onAppSelect: { [weak self] app in
                self?.selectApp(app)
            },
            onRefreshApps: { [weak self] in
                self?.refreshAppList()
            },
            onModeChange: { [weak self] mode in
                self?.setPanelMode(mode)
            }
        ))
    }

    private var selectedMicrophone: AudioDevice? {
        guard let uid = selectedDeviceUID else { return nil }
        return state.availableMicrophones.first { $0.uid == uid }
    }

    func register(with context: FeatureContext) {
        self.context = context

        // Register hotkey with current settings
        registerHotkey()

        // Re-register when settings change
        settings.onMeetingHotkeyChanged = { [weak self] in
            self?.registerHotkey()
        }

        // Initialize device list
        refreshDeviceList()
        deviceListMonitor.onDeviceListChanged = { [weak self] in
            Task { @MainActor in
                self?.refreshDeviceList()
            }
        }

        // Check for crash recovery
        checkCrashRecovery()
    }

    private func registerHotkey() {
        guard let context else { return }
        let config = settings.meetingHotkeyConfig
        context.registerHotkey(.meeting, config: config) { [weak self] in
            self?.handleHotkey()
        }
    }

    func cancel() {
        for task in chunkTranscriptionTasks { task.cancel() }
        chunkTranscriptionTasks = []
        stopRecording(saveToHistory: false)
        audioManager?.cleanupTempFiles()
        state.phase = .idle
        state.reset()
        isActive = false
    }

    func handleEscape() {
        if state.isRecording {
            // During recording, ESC does nothing - user must click Stop button
            // This prevents accidental data loss
            return
        } else {
            // Otherwise, dismiss panel
            cancel()
            context?.onDeactivate?()
        }
    }

    /// Close the panel (called from close button in UI)
    func closePanel() {
        if !state.isRecording && !state.isProcessing {
            cancel()
            context?.onDeactivate?()
        }
    }

    // MARK: - Hotkey Handling

    private func handleHotkey() {
        switch state.phase {
        case .idle:
            showPanel()
        case .ready, .permissionRequired:
            // Already showing panel, toggle to start
            startMeeting()
        case .loadingModels:
            break
        case .recording:
            // Toggle panel mode during recording
            togglePanelMode()
        case .processing:
            break
        case .error:
            cancel()
            context?.onDeactivate?()
        }
    }

    private func showPanel() {
        state.phase = .ready
        state.panelMode = savedPanelMode
        isActive = true
        context?.onActivate?(self)
        refreshAppList()
    }

    private func togglePanelMode() {
        let newMode: MeetingPanelMode = state.panelMode == .compact ? .expanded : .compact
        setPanelMode(newMode)
    }

    private func setPanelMode(_ mode: MeetingPanelMode) {
        state.panelMode = mode
        savedPanelMode = mode
    }

    // MARK: - Meeting Lifecycle

    func startMeeting() {
        // Check mic permission
        if micPermission.state.isBlocked {
            state.phase = .error(message: "Microphone permission required")
            micPermission.openSystemSettings()
            return
        }

        // Check screen recording permission
        guard screenPermission.isGranted else {
            state.phase = .permissionRequired
            screenPermission.request()
            pollForScreenPermission()
            return
        }

        state.phase = .loadingModels
        isActive = true
        context?.onActivate?(self)

        Task {
            do {
                try await prepareAndStart()
            } catch {
                state.phase = .error(message: "Failed: \(error.localizedDescription)")
            }
        }
    }

    func stopMeeting() {
        if state.isRecording {
            stopRecording(saveToHistory: true)
        }
    }

    private func prepareAndStart() async throws {
        // Prepare transcription
        let isReady = await transcriptionService.isReady
        if !isReady {
            try await transcriptionService.prepare()
        }

        await startRecording()
    }

    private func startRecording() async {
        state.reset()
        chunkTranscriptionTasks = []

        // Create managers
        let audio = MeetingAudioManager()
        let transcript = MeetingTranscriptManager(transcriptionService: transcriptionService)

        audioManager = audio
        transcriptManager = transcript

        // Configure audio callbacks
        audio.onAudioLevel = { [weak self] level in
            self?.state.audioLevel = level
        }
        if settings.isMeetingStreamingEnabled {
            audio.onTranscriptionChunk = { [weak self] chunk in
                guard let self, let manager = self.transcriptManager else { return }
                let task = manager.transcribeChunk(chunk)
                self.chunkTranscriptionTasks.append(task)
                // Prune completed tasks to prevent unbounded growth
                if self.chunkTranscriptionTasks.count > 20 {
                    self.chunkTranscriptionTasks.removeAll { $0.isCancelled }
                }
            }
        }
        audio.onError = { [weak self] message in
            self?.state.phase = .error(message: message)
        }

        // Configure transcript callbacks
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
        let micSource: AudioSource.MicrophoneSource
        if let device = selectedMicrophone {
            micSource = .specific(device)
        } else {
            micSource = .systemDefault
        }

        let appSelection: AppSelection
        if let app = state.selectedApp {
            appSelection = .only([app])
        } else {
            appSelection = .all
        }

        do {
            try await audio.start(micSource: micSource, appSelection: appSelection)

            state.phase = .recording

            // Start auto-save
            transcript.startAutoSave()

            // Start duration timer
            let startTime = Date()
            durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.state.duration = Date().timeIntervalSince(startTime)
                }
            }
        } catch {
            state.phase = .error(message: "Failed to start: \(error.localizedDescription)")
        }
    }

    private func stopRecording(saveToHistory: Bool) {
        durationTimer?.invalidate()
        durationTimer = nil

        transcriptManager?.stopAutoSave()

        // Cancel all pending chunk transcription tasks
        let pendingTasks = chunkTranscriptionTasks
        for task in pendingTasks { task.cancel() }
        chunkTranscriptionTasks = []

        guard let audio = audioManager else { return }
        let (micFile, micRate, systemFile, systemRate) = audio.stop()
        let duration = state.duration

        if saveToHistory {
            state.phase = .processing

            Task {
                // Wait for cancelled chunk tasks to finish
                // (prevents use-after-free from orphaned CoreML inference)
                for task in pendingTasks { await task.value }

                // Read original-quality audio files
                let micSamples = audio.readSamplesFromFile(micFile)
                let sysSamples = audio.readSamplesFromFile(systemFile)

                // Final transcription (resamples to 16kHz internally)
                await transcriptManager?.transcribeFullAudio(
                    micSamples: micSamples,
                    micSampleRate: micRate,
                    systemSamples: sysSamples,
                    systemSampleRate: systemRate
                )

                // Clear auto-save
                transcriptManager?.clearAutoSave()

                // Save to history (original quality for playback)
                if settings.isMeetingHistoryEnabled {
                    await saveToHistoryStorage(
                        micSamples: micSamples,
                        micSampleRate: micRate,
                        systemSamples: sysSamples,
                        systemSampleRate: systemRate,
                        duration: duration
                    )
                }

                // Clean up temp files
                audio.cleanupTempFiles()

                // Show results
                state.phase = .ready
                state.audioLevel = 0
            }
        } else {
            audio.cleanupTempFiles()
            state.phase = .idle
            state.audioLevel = 0
            isActive = false
            context?.onDeactivate?()
        }
    }

    private func saveToHistoryStorage(
        micSamples: [Float],
        micSampleRate: Double,
        systemSamples: [Float],
        systemSampleRate: Double,
        duration: TimeInterval
    ) async {
        let meetingId = UUID()
        let segments = transcriptManager?.segments ?? []
        let audioFormat = settings.audioStorageFormat

        // Create initial meeting without audio recordings
        var meeting = Meeting(
            id: meetingId,
            segments: segments,
            duration: duration,
            micRecording: nil,
            systemRecording: nil,
            appName: state.selectedApp?.name,
            createdAt: Date()
        )

        do {
            // Save the meeting first to create the folder
            try await historyService.save(.meeting(meeting))

            // Save audio files with original sample rates and user-selected format
            var micRecording: AudioRecording?
            var systemRecording: AudioRecording?

            if !micSamples.isEmpty && micSampleRate > 0 {
                micRecording = try await historyService.saveAudioCompressed(
                    samples: micSamples,
                    sampleRate: micSampleRate,
                    format: audioFormat,
                    for: meetingId
                )
            }

            if !systemSamples.isEmpty && systemSampleRate > 0 {
                systemRecording = try await historyService.saveAudioCompressed(
                    samples: systemSamples,
                    sampleRate: systemSampleRate,
                    format: audioFormat,
                    for: meetingId
                )
            }

            // Update meeting with audio recording references
            meeting = Meeting(
                id: meetingId,
                segments: segments,
                duration: duration,
                micRecording: micRecording,
                systemRecording: systemRecording,
                appName: state.selectedApp?.name,
                createdAt: meeting.createdAt
            )

            // Save updated meeting with audio references
            try await historyService.save(.meeting(meeting))
            print("MeetingFeature: Saved meeting to history with \(segments.count) segments (\(audioFormat.displayName) @ \(Int(systemSampleRate))Hz)")
        } catch {
            print("MeetingFeature: Failed to save to history: \(error)")
        }
    }

    // MARK: - Source Selection

    private func selectApp(_ app: AudioApp?) {
        let wasRecording = state.isRecording
        state.selectedApp = app
        transcriptManager?.setSelectedApp(app)

        if wasRecording {
            // Restart with new app (brief gap OK)
            Task {
                let micSource: AudioSource.MicrophoneSource
                if let device = selectedMicrophone {
                    micSource = .specific(device)
                } else {
                    micSource = .systemDefault
                }
                try? await audioManager?.switchApp(to: app, micSource: micSource)
            }
        }
    }

    private func switchMicrophone(to device: AudioDevice?) {
        selectedDeviceUID = device?.uid
        state.selectedMicrophone = device

        if state.isRecording {
            // Restart with new mic
            Task {
                await restartRecordingWithNewSources()
            }
        }
    }

    private func restartRecordingWithNewSources() async {
        let micSource: AudioSource.MicrophoneSource
        if let device = selectedMicrophone {
            micSource = .specific(device)
        } else {
            micSource = .systemDefault
        }
        try? await audioManager?.switchApp(to: state.selectedApp, micSource: micSource)
    }

    // MARK: - Device & App Lists

    private func refreshDeviceList() {
        state.availableMicrophones = MeetingAudioManager.availableMicrophones()
        state.selectedMicrophone = selectedMicrophone
    }

    func refreshAppList() {
        Task {
            let apps = await MeetingAudioManager.audioProducingApps()
            let sortedApps = sortAppsForMeetings(apps)
            state.availableApps = sortedApps
        }
    }

    private func sortAppsForMeetings(_ apps: [AudioApp]) -> [AudioApp] {
        let meetingBundleIDs = [
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

        return apps.sorted { app1, app2 in
            let isMeeting1 = meetingBundleIDs.contains(app1.bundleIdentifier ?? "")
            let isMeeting2 = meetingBundleIDs.contains(app2.bundleIdentifier ?? "")
            if isMeeting1 && !isMeeting2 { return true }
            if !isMeeting1 && isMeeting2 { return false }
            return app1.name < app2.name
        }
    }

    // MARK: - Permission Polling

    private func pollForScreenPermission() {
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self = self else {
                    timer.invalidate()
                    return
                }

                guard case .permissionRequired = self.state.phase else {
                    timer.invalidate()
                    return
                }

                if self.screenPermission.isGranted {
                    timer.invalidate()
                    self.refreshAppList()
                    self.startMeeting()
                }
            }
        }
    }

    // MARK: - Crash Recovery

    private func checkCrashRecovery() {
        let transcript = MeetingTranscriptManager(transcriptionService: transcriptionService)
        if let recovery = transcript.checkForCrashRecovery() {
            // Found recovery data - show it
            state.segments = recovery.segments
            state.duration = recovery.duration
            state.phase = .ready
            transcript.clearAutoSave()
            print("MeetingFeature: Recovered \(recovery.segments.count) segments from crash")
        }
    }
}
#endif
