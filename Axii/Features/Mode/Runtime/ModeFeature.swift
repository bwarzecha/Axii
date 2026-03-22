//
//  ModeFeature.swift
//  Axii
//
//  The active shipping runtime for all modes (dictation, conversation, meeting, custom).
//  Config-driven via ModeConfig; replaces the legacy per-feature classes
//  (DictationFeature, ConversationFeature, MeetingFeature) which are transitional.
//
//  Recording logic: ModeFeatureRecording.swift
//  Meeting logic:   ModeFeatureMeeting.swift
//

#if os(macOS)
import SwiftUI

@MainActor
final class ModeFeature: Feature, ModeDismissControlling {
    var config: ModeConfig
    let state: ModeRuntimeState
    var isActive: Bool = false

    // Services (internal for cross-file extensions)
    let transcriptionService: any TranscriptionProviding
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
    var meetingHandler: MeetingPipelineHandler?
    let pipelineRunner: PipelineRunner
    private let llmService: LLMService?

    // Single-shot post-capture processor — lazy because it captures self as dismissController.
    private(set) lazy var singleShotProcessor = SingleShotModeTurnProcessor(
        transcriber: transcriptionService,
        pipeline: pipelineRunner,
        output: outputHandler,
        dismissController: self
    )

    // Multi-turn post-capture processor — lazy because it captures self as dismissController.
    private(set) lazy var multiTurnProcessor: MultiTurnModeTurnProcessor? = {
        guard let llm = llmService else { return nil }
        return MultiTurnModeTurnProcessor(
            transcriber: transcriptionService,
            responder: llm,
            sessionStore: ConversationSessionStore(historyService: historyService),
            dismissController: self
        )
    }()

    /// Whether this mode uses multi-turn conversation execution.
    let hasMultiTurnLLM: Bool

    var deviceUIDKey: String { "mode_\(config.id)_selectedMic" }
    var selectedDeviceUID: String? {
        get { UserDefaults.standard.string(forKey: deviceUIDKey) }
        set { UserDefaults.standard.set(newValue, forKey: deviceUIDKey) }
    }

    init(
        config: ModeConfig,
        transcriptionService: any TranscriptionProviding,
        micPermission: MicrophonePermissionService,
        screenPermission: ScreenRecordingPermissionService? = nil,
        pasteService: any PasteProviding,
        clipboardService: ClipboardService,
        settings: SettingsService,
        historyService: HistoryService,
        mediaControlService: MediaControlService,
        llmService: LLMService? = nil,
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
        self.llmService = llmService
        self.outputHandler = OutputHandler(
            pasteService: pasteService,
            clipboardService: clipboardService,
            historyService: historyService,
            settings: settings
        )
        self.pipelineRunner = PipelineRunner(
            llmService: llmService,
            diarizationService: diarizationService
        )
        self.hasMultiTurnLLM = config.processing.contains { step in
            if case .llmTransform(let cfg) = step { return cfg.multiTurn }
            return false
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
        if let hotkey = config.hotkey { return hotkey.symbolString }
        // Fallback to SettingsService for modes without hotkey in config (migration)
        guard let context else { return "" }
        let s = context.settings
        switch config.id {
        case DefaultModes.dictationId: return s.hotkeyConfig.symbolString
        case DefaultModes.conversationId: return s.conversationHotkeyConfig.symbolString
        case DefaultModes.meetingId: return s.meetingHotkeyConfig.symbolString
        default: return ""
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
        cancelScheduledDismiss()
        recordingHelper?.cancel()
        recordingHelper = nil
        meetingHandler?.cancel()
        state.clearConversationSession()
        state.reset()
        isActive = false
        mediaControlService.resetState()
    }

    // MARK: - Registration

    func registerHotkey() {
        guard let context else { return }
        guard let hotkeyConfig = resolveHotkeyConfig() else { return }
        context.registerHotkey(hotkeyIDForConfig(), config: hotkeyConfig) { [weak self] in
            self?.handleHotkey()
        }
    }

    private func hotkeyIDForConfig() -> HotkeyID {
        switch config.id {
        case DefaultModes.dictationId: return .togglePanel
        case DefaultModes.conversationId: return .conversation
        case DefaultModes.meetingId: return .meeting
        default: return .mode(config.id)
        }
    }

    private func resolveHotkeyConfig() -> HotkeyConfig? {
        if let hotkey = config.hotkey { return hotkey }
        // Fallback to SettingsService for pre-migration mode JSONs
        guard let context else { return nil }
        let s = context.settings
        switch config.id {
        case DefaultModes.dictationId: return s.hotkeyConfig
        case DefaultModes.conversationId: return s.conversationHotkeyConfig
        case DefaultModes.meetingId: return s.meetingHotkeyConfig
        default: return nil
        }
    }

    private func wireSettingsCallback() {
        // Legacy: re-register hotkey when SettingsService changes (for pre-migration configs)
        let callback: () -> Void = { [weak self] in self?.registerHotkey() }
        switch config.id {
        case DefaultModes.dictationId: settings.onHotkeyChanged = callback
        case DefaultModes.conversationId: settings.onConversationHotkeyChanged = callback
        case DefaultModes.meetingId: settings.onMeetingHotkeyChanged = callback
        default: break
        }
    }

    /// Update config from editor. Re-registers hotkey if changed.
    func updateConfig(_ newConfig: ModeConfig) {
        let hotkeyChanged = config.hotkey != newConfig.hotkey
        config = newConfig
        if hotkeyChanged { registerHotkey() }
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
        } else if hasMultiTurnLLM {
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
            else { cancelScheduledDismiss(); startSimpleRecording() }
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
        cancelScheduledDismiss()
        recordingHelper?.cancel(); recordingHelper = nil
        meetingHandler?.cancel()
        state.clearConversationSession()
        state.reset(); isActive = false
        mediaControlService.resetState()
        context?.onDeactivate?()
    }

    // MARK: - ModeDismissControlling

    func cancelScheduledDismiss() {
        deactivationWorkItem?.cancel(); deactivationWorkItem = nil
    }

    func scheduleDismiss(after delay: TimeInterval) {
        cancelScheduledDismiss()
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
