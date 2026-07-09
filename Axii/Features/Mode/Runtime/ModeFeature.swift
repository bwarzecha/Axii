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
    var meetingHandler: (any MeetingPipelineHandling)?
    /// Identity token for meeting stop flows: two overlapping stops can both
    /// occupy .processing, so a phase-value check alone cannot tell "my
    /// processing" from a newer session's. Incremented per stopMeeting.
    var meetingStopGeneration = 0
    /// Identity token for single-shot/multi-turn turns. Bumped by teardown
    /// and by each new turn: a processor resuming from an await must not
    /// write state, paste, or schedule dismissal for a superseded turn.
    var turnGeneration = 0
    /// The in-flight post-capture turn, cancelled on teardown.
    var turnTask: Task<Void, Never>?
    /// The in-flight meeting save-stop: a second Stop tap must join it, not
    /// race it (a second handler.stop would flip the UI to idle mid-save and
    /// generation-suppress the first stop's error reporting).
    var meetingStopTask: Task<Void, Never>?
    /// Audio captured before a mid-recording mic switch: switching devices
    /// must never destroy what was already said. Combined at stop.
    var carriedRecordingSegments: [(samples: [Float], sampleRate: Double)] = []
    /// The delayed restart after a mic switch — cancellable so a teardown
    /// in the 0.1s gap cannot be resurrected by it.
    var micSwitchRestartWorkItem: DispatchWorkItem?
    let pipelineRunner: PipelineRunner
    let meetingPersistence: any MeetingPersisting

    // Single-shot post-capture processor — lazy because it captures self as dismissController.
    private(set) lazy var singleShotProcessor = SingleShotModeTurnProcessor(
        transcriber: transcriptionService,
        pipeline: pipelineRunner,
        output: outputHandler,
        dismissController: self
    )

    // Multi-turn collaborators — injected at init for testability.
    // Production uses LLMService/ConversationSessionStore; tests inject fakes.
    private let conversationResponder: (any ConversationResponding)?
    private let conversationSessionStore: (any ConversationSessionStoring)?

    // Multi-turn post-capture processor — lazy because it captures self as dismissController.
    // Built from the injected collaborators; nil when no responder is available.
    private lazy var configuredMultiTurnProcessor: MultiTurnModeTurnProcessor? = {
        guard let responder = conversationResponder else { return nil }
        guard let store = conversationSessionStore else { return nil }
        return MultiTurnModeTurnProcessor(
            transcriber: transcriptionService,
            responder: responder,
            sessionStore: store,
            dismissController: self
        )
    }()

    /// Multi-turn execution is config-driven, not provider-driven. Dictation
    /// must remain single-shot even when the app has an LLM service available.
    var multiTurnProcessor: MultiTurnModeTurnProcessor? {
        guard config.usesMultiTurnProcessing else { return nil }
        return configuredMultiTurnProcessor
    }

    var hotkeyRoute: ModeHotkeyRoute {
        ModeHotkeyRoute.select(
            hasMeetingHandler: meetingHandler != nil,
            config: config
        )
    }

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
        diarizationService: DiarizationService? = nil,
        conversationResponder: (any ConversationResponding)? = nil,
        conversationSessionStore: (any ConversationSessionStoring)? = nil,
        meetingHandler: (any MeetingPipelineHandling)? = nil,
        meetingPersistence: (any MeetingPersisting)? = nil
    ) {
        self.config = config
        self.state = ModeRuntimeState()
        self.transcriptionService = transcriptionService
        self.micPermission = micPermission
        self.clipboardService = clipboardService
        self.settings = settings
        self.mediaControlService = mediaControlService
        self.historyService = historyService
        self.meetingPersistence = meetingPersistence
            ?? MeetingPersistenceService(historyService: historyService)
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
        self.meetingHandler = meetingHandler

        // Multi-turn collaborators: use injected fakes or default production instances
        self.conversationResponder = conversationResponder ?? llmService
        self.conversationSessionStore = conversationSessionStore
            ?? (llmService != nil ? ConversationSessionStore(historyService: historyService) : nil)

        if self.meetingHandler == nil,
           config.audioCapture.isDual,
           let screen = screenPermission {
            self.meetingHandler = MeetingPipelineHandler(
                state: state, transcriptionService: transcriptionService,
                screenPermission: screen,
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
            recoverCrashedMeetingIfNeeded()
        }
    }

    func handleEscape() {
        if state.phase.isRecording && config.lifecycle.escapeBehavior == .blockWhileRecording {
            return
        }
        cancelAndDeactivate()
    }

    func cancel() {
        teardownRuntime()
    }

    /// Shared teardown for cancel and cancelAndDeactivate.
    private func teardownRuntime() {
        turnGeneration += 1
        turnTask?.cancel(); turnTask = nil
        cancelScheduledDismiss()
        micSwitchRestartWorkItem?.cancel(); micSwitchRestartWorkItem = nil
        carriedRecordingSegments = []
        recordingHelper?.cancel(); recordingHelper = nil
        if let handler = meetingHandler, handler.hasLiveCapture,
           case .error = state.phase {
            // An errored meeting still holds a live capture: every exit
            // salvages it to history (UX-2); the detached stop survives the
            // reset below. Discard stays available via history delete.
            stopMeeting(saveToHistory: true)
        } else {
            meetingHandler?.cancel()
        }
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
        reconcileMicrophoneSelection(
            resolved: resolveSelectedMicrophone(),
            previous: state.selectedMicrophone
        )
    }

    /// A meeting captures with the device it was started with; if the
    /// resolved selection changed under it (unplug → nil, replug → the
    /// preferred mic again), the capture session must be told or its
    /// stored selection drifts from what the user sees. Dictation needs
    /// no reconciliation: it resolves the device fresh on each start.
    @discardableResult
    func reconcileMicrophoneSelection(
        resolved: AudioDevice?,
        previous: AudioDevice?
    ) -> Task<Void, Never>? {
        state.selectedMicrophone = resolved
        guard let handler = meetingHandler,
              state.phase == .recording,
              resolved?.uid != previous?.uid else { return nil }
        let source: AudioSource.MicrophoneSource =
            resolved.map { .specific($0) } ?? .systemDefault
        return Task {
            await handler.switchMicrophone(to: resolved, micSource: source)
        }
    }

    func resolveSelectedMicrophone() -> AudioDevice? {
        guard let uid = selectedDeviceUID else { return nil }
        return state.availableMicrophones.first { $0.uid == uid }
    }

    // MARK: - Data-Bearing Takeover Protection

    var isDataBearing: Bool {
        if meetingHandler?.hasLiveCapture == true { return true }
        switch state.phase {
        case .recording, .transcribing, .processing: return true
        default: return false
        }
    }

    /// Stop-and-deliver whatever is in flight, releasing the UI without
    /// destroying data: meetings save to history, dictation/conversation
    /// turns finish in the background (their stale-write guards keep them
    /// from touching the successor's UI).
    func stopAndPreserve() {
        if let handler = meetingHandler, handler.hasLiveCapture {
            stopMeeting(saveToHistory: true)
        } else if state.phase.isRecording, recordingHelper != nil {
            if multiTurnProcessor != nil { stopAndProcessMultiTurn() }
            else { stopSimpleRecording() }
        } else if state.phase == .transcribing || state.phase == .processing {
            // A turn or save is already in flight — let it finish detached.
        } else {
            cancel()
            return
        }
        isActive = false
    }

    private enum BusyModeChoice {
        case saveAndSwitch, discardAndSwitch, stay
    }

    private func askBusyModeChoice() -> BusyModeChoice {
        let alert = NSAlert()
        alert.messageText = "Another mode is busy"
        alert.informativeText = "A recording or save is in progress in another mode. What should happen to it?"
        alert.addButton(withTitle: "Save & Switch")
        alert.addButton(withTitle: "Discard & Switch")
        alert.addButton(withTitle: "Stay")
        alert.alertStyle = .warning
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .saveAndSwitch
        case .alertSecondButtonReturn: return .discardAndSwitch
        default: return .stay
        }
    }

    // MARK: - Hotkey Routing

    private func handleHotkey() {
        // Another mode holds unsaved data: the user decides its fate BEFORE
        // this mode touches the microphone — a muscle-memory keystroke must
        // never silently destroy an hour-long recording.
        if let busy = context?.busyFeature?(), busy !== self {
            switch askBusyModeChoice() {
            case .saveAndSwitch: busy.stopAndPreserve()
            case .discardAndSwitch: busy.cancel()
            case .stay: return
            }
        }
        switch hotkeyRoute {
        case .meeting:
            handleLongRunningHotkey()
        case .multiTurn:
            handleMultiTurnHotkey()
        case .singleShot:
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
        case .transcribing: cancelAndDeactivate()
        case .error:
            // The panel labels the hotkey "Retry" in this phase — retry,
            // don't dismiss.
            cancelScheduledDismiss()
            state.reset()
            startSimpleRecording()
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
        teardownRuntime()
        context?.onDeactivate?(self)
    }

    // MARK: - ModeDismissControlling

    func cancelScheduledDismiss() {
        deactivationWorkItem?.cancel(); deactivationWorkItem = nil
    }

    func scheduleDismiss(after delay: TimeInterval) {
        cancelScheduledDismiss()
        let item = DispatchWorkItem { [weak self] in
            self?.deactivationWorkItem = nil
            self?.cancelAndDeactivate()
        }
        deactivationWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func copyAndDismiss(_ text: String) {
        clipboardService.copy(text); cancelAndDeactivate()
    }

}
#endif
