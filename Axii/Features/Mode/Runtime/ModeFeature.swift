//
//  ModeFeature.swift
//  Axii
//
//  Generic Feature driven by ModeConfig. Replaces DictationFeature,
//  ConversationFeature, and MeetingFeature with a single config-driven
//  implementation.
//

#if os(macOS)
import SwiftUI

@MainActor
final class ModeFeature: Feature {
    let config: ModeConfig
    let state: ModeRuntimeState
    private(set) var isActive: Bool = false

    private let transcriptionService: TranscriptionService
    private let micPermission: MicrophonePermissionService
    private let clipboardService: ClipboardService
    private let settings: SettingsService
    private let mediaControlService: MediaControlService
    private let outputHandler: OutputHandler
    private let historyService: HistoryService
    private var context: FeatureContext?
    private var recordingHelper: RecordingSessionHelper?
    private var deactivationWorkItem: DispatchWorkItem?
    private let deviceMonitor = DeviceMonitor()

    // Pipeline handlers (created based on config)
    private var conversationHandler: ConversationHandler?
    private var meetingHandler: MeetingPipelineHandler?

    private var deviceUIDKey: String { "mode_\(config.id)_selectedMic" }
    private var selectedDeviceUID: String? {
        get { UserDefaults.standard.string(forKey: deviceUIDKey) }
        set { UserDefaults.standard.set(newValue, forKey: deviceUIDKey) }
    }

    init(
        config: ModeConfig,
        transcriptionService: TranscriptionService,
        micPermission: MicrophonePermissionService,
        screenPermission: ScreenRecordingPermissionService? = nil,
        pasteService: PasteService,
        clipboardService: ClipboardService,
        settings: SettingsService,
        historyService: HistoryService,
        mediaControlService: MediaControlService,
        llmService: LLMService? = nil,
        playbackService: AudioPlaybackService? = nil,
        diarizationService: DiarizationService? = nil
    ) {
        self.config = config
        self.state = ModeRuntimeState()
        self.transcriptionService = transcriptionService
        self.micPermission = micPermission
        self.clipboardService = clipboardService
        self.settings = settings
        self.mediaControlService = mediaControlService
        self.historyService = historyService
        self.outputHandler = OutputHandler(
            pasteService: pasteService,
            clipboardService: clipboardService,
            historyService: historyService,
            settings: settings
        )

        // Create handlers based on config
        if config.lifecycle.sessionType == .multiTurn,
           let llm = llmService, let playback = playbackService {
            self.conversationHandler = ConversationHandler(
                state: state, llmService: llm,
                playbackService: playback, historyService: historyService
            )
        }
        if config.lifecycle.sessionType == .longRunning,
           let screen = screenPermission {
            self.meetingHandler = MeetingPipelineHandler(
                state: state, transcriptionService: transcriptionService,
                diarizationService: diarizationService, screenPermission: screen,
                micPermission: micPermission, settings: settings
            )
        }
    }

    // MARK: - Feature Protocol

    var panelContent: AnyView {
        switch config.panel.layout {
        case .standard:
            AnyView(StandardPanelView(
                state: state, config: config, hotkeyHint: hotkeyHint,
                onStart: { [weak self] in self?.handleStartButton() },
                onStop: { [weak self] in self?.handleStopButton() },
                onClose: { [weak self] in self?.cancelAndDeactivate() },
                onMicrophoneSwitch: { [weak self] in self?.switchMicrophone(to: $0) },
                onAppSelect: { [weak self] in self?.meetingHandler?.selectApp($0) },
                onRefreshApps: { [weak self] in Task { await self?.meetingHandler?.refreshAppList() } },
                onModeChange: { [weak self] in self?.state.panelMode = $0 },
                onCopy: { [weak self] in self?.copyAndDismiss($0) }
            ))
        case .conversation:
            AnyView(ModeConversationView(
                state: state, config: config, hotkeyHint: hotkeyHint,
                onMicrophoneSwitch: { [weak self] in self?.switchMicrophone(to: $0) },
                onCopy: { [weak self] in self?.copyAndDismiss($0) }
            ))
        }
    }

    var hotkeyHint: String {
        guard let context else { return "" }
        let s = context.settings
        switch config.id {
        case DefaultModes.dictationId: return s.hotkeyConfig.symbolString
        case DefaultModes.conversationId: return s.conversationHotkeyConfig.symbolString
        case DefaultModes.meetingId: return s.meetingHotkeyConfig.symbolString
        default: return s.hotkeyConfig.symbolString
        }
    }

    func register(with context: FeatureContext) {
        self.context = context
        registerHotkey()
        wireSettingsCallback()
        refreshDeviceList()
        deviceMonitor.onDeviceListChanged = { [weak self] in
            Task { @MainActor in self?.refreshDeviceList() }
        }
        // Crash recovery for meeting mode
        if config.lifecycle.enableCrashRecovery {
            meetingHandler?.checkCrashRecovery()
        }
    }

    func handleEscape() {
        if state.phase.isRecording && !config.lifecycle.escapeAllowedDuringRecording { return }
        cancelAndDeactivate()
    }

    func cancel() {
        cancelDeactivationTimer()
        recordingHelper?.cancel()
        recordingHelper = nil
        meetingHandler?.cancel()
        conversationHandler?.clearSession()
        state.reset()
        isActive = false
        mediaControlService.resetState()
    }

    // MARK: - Registration

    private func registerHotkey() {
        guard let context else { return }
        context.registerHotkey(hotkeyIDForConfig(), config: currentHotkeyConfig()) { [weak self] in
            self?.handleHotkey()
        }
    }

    private func hotkeyIDForConfig() -> HotkeyID {
        switch config.id {
        case DefaultModes.dictationId: return .togglePanel
        case DefaultModes.conversationId: return .conversation
        case DefaultModes.meetingId: return .meeting
        default: return .togglePanel
        }
    }

    private func currentHotkeyConfig() -> HotkeyConfig {
        guard let context else { return .default }
        let s = context.settings
        switch config.id {
        case DefaultModes.dictationId: return s.hotkeyConfig
        case DefaultModes.conversationId: return s.conversationHotkeyConfig
        case DefaultModes.meetingId: return s.meetingHotkeyConfig
        default: return s.hotkeyConfig
        }
    }

    private func wireSettingsCallback() {
        let callback: () -> Void = { [weak self] in self?.registerHotkey() }
        switch config.id {
        case DefaultModes.dictationId: settings.onHotkeyChanged = callback
        case DefaultModes.conversationId: settings.onConversationHotkeyChanged = callback
        case DefaultModes.meetingId: settings.onMeetingHotkeyChanged = callback
        default: settings.onHotkeyChanged = callback
        }
    }

    private func refreshDeviceList() {
        state.availableMicrophones = DeviceMonitor.availableMicrophones()
        state.selectedMicrophone = resolveSelectedMicrophone()
    }

    private func resolveSelectedMicrophone() -> AudioDevice? {
        guard let uid = selectedDeviceUID else { return nil }
        return state.availableMicrophones.first { $0.uid == uid }
    }

    // MARK: - Hotkey Routing

    private func handleHotkey() {
        switch config.lifecycle.sessionType {
        case .singleShot: handleSingleShotHotkey()
        case .multiTurn: handleMultiTurnHotkey()
        case .longRunning: handleLongRunningHotkey()
        }
    }

    private func handleSingleShotHotkey() {
        switch state.phase {
        case .idle: startSimpleRecording()
        case .recording: stopSimpleRecording()
        case .done:
            if state.needsManualCopy { copyAndDismiss(state.manualCopyText) }
            else { cancelDeactivationTimer(); startSimpleRecording() }
        case .transcribing, .error: cancelAndDeactivate()
        case .preparing, .processing: break
        }
    }

    private func handleMultiTurnHotkey() {
        switch state.phase {
        case .idle, .done: startSimpleRecording()
        case .recording: stopAndProcessMultiTurn()
        case .processing: break
        case .error: state.reset(); startSimpleRecording()
        case .preparing, .transcribing: break
        }
    }

    private func handleLongRunningHotkey() {
        switch state.phase {
        case .idle: showMeetingPanel()
        case .preparing: startMeeting()
        case .recording:
            state.panelMode = state.panelMode == .compact ? .expanded : .compact
        case .error: cancelAndDeactivate()
        case .processing, .done, .transcribing: break
        }
    }

    // MARK: - Start/Stop Buttons (for panel UI)

    private func handleStartButton() {
        if config.lifecycle.sessionType == .longRunning {
            startMeeting()
        }
    }

    private func handleStopButton() {
        if config.lifecycle.sessionType == .longRunning {
            stopMeeting(saveToHistory: true)
        }
    }

    // MARK: - Simple Recording (singleShot + multiTurn)

    private func startSimpleRecording() {
        if config.lifecycle.captureFocus { state.focusSnapshot = FocusSnapshot.capture() }
        if config.lifecycle.pauseMedia { Task { await mediaControlService.pauseIfPlaying() } }

        let helper = RecordingSessionHelper()
        recordingHelper = helper
        helper.onVisualizationUpdate = { [weak self] update in
            guard self?.state.phase.isRecording == true else { return }
            self?.state.audioLevel = update.audioLevel
            self?.state.spectrum = update.spectrum
        }
        helper.onSignalStateChanged = { [weak self] in self?.state.isWaitingForSignal = $0 }
        helper.onError = { [weak self] in self?.handleSessionError($0) }

        let source: AudioSource = resolveSelectedMicrophone().map { .microphone($0) } ?? .systemDefault
        Task {
            do {
                try await helper.start(source: source)
                state.phase = .recording; isActive = true; context?.onActivate?(self)
            } catch let error as AudioSessionError { handleSessionError(error) }
            catch { state.phase = .error("Microphone error"); scheduleDeactivation(delay: 2.0) }
        }
        Task {
            if !(await transcriptionService.isReady) { try? await transcriptionService.prepare() }
        }
    }

    private func stopSimpleRecording() {
        guard state.phase.isRecording, let helper = recordingHelper else { return }
        let (samples, sampleRate) = helper.stop()
        recordingHelper = nil
        state.audioLevel = 0; state.isWaitingForSignal = false; state.phase = .transcribing

        Task {
            defer { resumeMediaIfNeeded() }
            do {
                let text = try await transcriptionService.transcribe(samples: samples, sampleRate: sampleRate)
                if text.isEmpty {
                    state.finalText = "No speech detected"; state.phase = .done
                    scheduleDeactivation(delay: 2.0)
                } else {
                    state.finalText = text
                    await outputHandler.executeOutput(
                        config: config.output, text: text, state: state,
                        modeConfig: config, samples: samples, sampleRate: sampleRate
                    )
                    if !state.needsManualCopy, let delay = config.lifecycle.autoDeactivateDelay {
                        scheduleDeactivation(delay: delay)
                    }
                }
                state.focusSnapshot = nil
            } catch {
                let msg = (error as? TranscriptionError)?.errorDescription ?? "Transcription failed"
                state.phase = .error(msg); scheduleDeactivation(delay: 2.0)
            }
        }
    }

    // MARK: - Multi Turn (Conversation)

    private func stopAndProcessMultiTurn() {
        guard state.phase.isRecording, let helper = recordingHelper else { return }
        let (samples, sampleRate) = helper.stop()
        recordingHelper = nil
        state.audioLevel = 0; state.isWaitingForSignal = false; state.phase = .processing

        Task {
            do {
                let text = try await transcriptionService.transcribe(samples: samples, sampleRate: sampleRate)
                guard !text.isEmpty else {
                    state.phase = .done
                    scheduleDeactivation(delay: 2.0)
                    return
                }
                state.liveTranscript = text

                // Find LLM processing step
                let llmConfig = config.processing.compactMap { step -> LLMTransformConfig? in
                    if case .llmTransform(let cfg) = step { return cfg }
                    return nil
                }.first

                if let llmConfig, let handler = conversationHandler {
                    let response = try await handler.processTranscription(text, config: llmConfig)
                    state.finalText = response
                } else {
                    // No LLM configured - just show transcript
                    state.messages.append(DisplayMessage(role: .user, content: text))
                    state.finalText = text
                }
                state.phase = .done
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? "Processing failed"
                state.phase = .error(msg)
            }
        }
    }

    // MARK: - Long Running (Meeting)

    private func showMeetingPanel() {
        isActive = true
        state.phase = .idle
        context?.onActivate?(self)
        // Refresh app list for meeting panel
        Task { await meetingHandler?.refreshAppList() }
    }

    private func startMeeting() {
        guard let handler = meetingHandler else {
            state.phase = .error("Meeting handler not configured")
            return
        }
        Task { await handler.start() }
    }

    private func stopMeeting(saveToHistory: Bool) {
        guard let handler = meetingHandler else { return }
        Task {
            let result = await handler.stop(saveToHistory: saveToHistory)
            if let result, saveToHistory {
                // Save meeting to history
                await saveMeetingToHistory(result)
            }
            state.phase = .idle
        }
    }

    private func saveMeetingToHistory(_ result: MeetingStopResult) async {
        guard historyService.isEnabled else { return }
        do {
            let meeting = Meeting(
                segments: result.segments,
                duration: result.duration,
                appName: result.appName
            )
            try await historyService.save(.meeting(meeting))

            // Save mic audio
            if !result.micSamples.isEmpty, result.micSampleRate > 0 {
                _ = try await historyService.saveAudioCompressed(
                    samples: result.micSamples, sampleRate: result.micSampleRate,
                    format: settings.audioStorageFormat, for: meeting.id
                )
            }
            // Save system audio
            if !result.systemSamples.isEmpty, result.systemSampleRate > 0 {
                _ = try await historyService.saveAudioCompressed(
                    samples: result.systemSamples, sampleRate: result.systemSampleRate,
                    format: settings.audioStorageFormat, for: meeting.id
                )
            }
        } catch {
            print("ModeFeature: Failed to save meeting: \(error)")
        }
    }

    // MARK: - Helpers

    private func resumeMediaIfNeeded() {
        guard config.lifecycle.pauseMedia else { return }
        Task { await mediaControlService.resumeIfWasPlaying() }
    }

    private func handleSessionError(_ error: AudioSessionError) {
        switch error {
        case .permissionDenied:
            if micPermission.state.isBlocked { micPermission.openSystemSettings() }
            state.phase = .error("Microphone permission required")
        case .deviceUnavailable: state.phase = .error("Microphone unavailable")
        case .configurationFailed(let r): state.phase = .error(r)
        case .captureFailure(let r): state.phase = .error(r)
        }
        scheduleDeactivation(delay: 2.0)
    }

    private func cancelAndDeactivate() {
        cancelDeactivationTimer()
        recordingHelper?.cancel(); recordingHelper = nil
        meetingHandler?.cancel()
        conversationHandler?.clearSession()
        state.reset(); isActive = false
        mediaControlService.resetState()
        context?.onDeactivate?()
    }

    private func cancelDeactivationTimer() {
        deactivationWorkItem?.cancel(); deactivationWorkItem = nil
    }

    private func scheduleDeactivation(delay: TimeInterval) {
        cancelDeactivationTimer()
        let item = DispatchWorkItem { [weak self] in
            self?.deactivationWorkItem = nil; self?.cancelAndDeactivate()
        }
        deactivationWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func copyAndDismiss(_ text: String) {
        clipboardService.copy(text); cancelAndDeactivate()
    }

    func switchMicrophone(to device: AudioDevice?) {
        let wasRecording = state.phase.isRecording
        if wasRecording && config.lifecycle.sessionType == .longRunning {
            // Meeting: switch mic without stopping
            let source: AudioSource.MicrophoneSource = device.map { .specific($0) } ?? .systemDefault
            Task { await meetingHandler?.switchMicrophone(to: device, micSource: source) }
        } else if wasRecording {
            recordingHelper?.cancel(); recordingHelper = nil
            state.audioLevel = 0; state.isWaitingForSignal = false
        }
        selectedDeviceUID = device?.uid; state.selectedMicrophone = device
        if wasRecording && config.lifecycle.sessionType != .longRunning {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.startSimpleRecording()
            }
        }
    }
}
#endif
