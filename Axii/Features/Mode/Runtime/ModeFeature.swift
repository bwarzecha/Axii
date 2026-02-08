//
//  ModeFeature.swift
//  Axii
//
//  Generic Feature driven by ModeConfig. Replaces DictationFeature,
//  ConversationFeature, and MeetingFeature with a single config-driven
//  implementation.
//
//  Recording logic: ModeFeatureRecording.swift
//  Meeting logic:   ModeFeatureMeeting.swift
//

#if os(macOS)
import SwiftUI

@MainActor
final class ModeFeature: Feature {
    let config: ModeConfig
    let state: ModeRuntimeState
    var isActive: Bool = false

    // Services (internal for cross-file extensions)
    let transcriptionService: TranscriptionService
    let micPermission: MicrophonePermissionService
    let clipboardService: ClipboardService
    let settings: SettingsService
    let mediaControlService: MediaControlService
    let outputHandler: OutputHandler
    let historyService: HistoryService
    var context: FeatureContext?
    var recordingHelper: RecordingSessionHelper?
    var deactivationWorkItem: DispatchWorkItem?
    private let deviceMonitor = DeviceMonitor()

    // Pipeline handlers (created based on config)
    var conversationHandler: ConversationHandler?
    var meetingHandler: MeetingPipelineHandler?

    var deviceUIDKey: String { "mode_\(config.id)_selectedMic" }
    var selectedDeviceUID: String? {
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

        // Create handlers based on config shape (not explicit session type)
        let hasMultiTurnLLM = config.processing.contains { step in
            if case .llmTransform(let cfg) = step { return cfg.multiTurn }
            return false
        }
        if hasMultiTurnLLM,
           let llm = llmService, let playback = playbackService {
            self.conversationHandler = ConversationHandler(
                state: state, llmService: llm,
                playbackService: playback, historyService: historyService
            )
        }
        if config.audioCapture.isDual,
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
        if config.lifecycle.enableCrashRecovery {
            meetingHandler?.checkCrashRecovery()
        }
    }

    func handleEscape() {
        if state.phase.isRecording && config.lifecycle.escapeBehavior == .blockWhileRecording {
            return
        }
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

    func resolveSelectedMicrophone() -> AudioDevice? {
        guard let uid = selectedDeviceUID else { return nil }
        return state.availableMicrophones.first { $0.uid == uid }
    }

    // MARK: - Hotkey Routing

    private func handleHotkey() {
        if meetingHandler != nil {
            handleLongRunningHotkey()
        } else if conversationHandler != nil {
            handleMultiTurnHotkey()
        } else {
            handleSingleShotHotkey()
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
        case .idle:
            if isActive { startMeeting() } else { showMeetingPanel() }
        case .preparing: startMeeting()
        case .recording:
            state.panelMode = state.panelMode == .compact ? .expanded : .compact
        case .error: cancelAndDeactivate()
        case .processing, .done, .transcribing: break
        }
    }

    // MARK: - Start/Stop Buttons (for panel UI)

    private func handleStartButton() {
        if meetingHandler != nil { startMeeting() }
    }

    private func handleStopButton() {
        if meetingHandler != nil { stopMeeting(saveToHistory: true) }
    }

    // MARK: - Helpers

    func cancelAndDeactivate() {
        cancelDeactivationTimer()
        recordingHelper?.cancel(); recordingHelper = nil
        meetingHandler?.cancel()
        conversationHandler?.clearSession()
        state.reset(); isActive = false
        mediaControlService.resetState()
        context?.onDeactivate?()
    }

    func cancelDeactivationTimer() {
        deactivationWorkItem?.cancel(); deactivationWorkItem = nil
    }

    func scheduleDeactivation(delay: TimeInterval) {
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

}
#endif
