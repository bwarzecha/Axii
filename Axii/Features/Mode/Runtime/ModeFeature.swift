//
//  ModeFeature.swift
//  Axii
//
//  The active shipping runtime for all modes (dictation, conversation, meeting, custom).
//  Config-driven via ModeConfig; the legacy per-feature classes it replaced
//  have been removed.
//
//  Recording logic: ModeFeatureRecording.swift
//  Meeting logic:   ModeFeatureMeeting.swift
//

#if os(macOS)
import SwiftUI

@MainActor
final class ModeFeature: Feature, ModeDismissControlling {
    var config: ModeConfig
    /// A config edit that arrived while the mode held data. The contract a
    /// capture STARTED under (hotkey route, escape behavior, outputs)
    /// governs it to completion; the edit lands at the next idle boundary.
    var pendingConfig: ModeConfig?
    let state: ModeRuntimeState
    var isActive: Bool = false

    // Services (internal for cross-file extensions)
    let transcriptionService: any TranscriptionProviding
    let micPermission: MicrophonePermissionService
    let clipboardService: any ClipboardProviding
    let settings: SettingsService
    let mediaControlService: MediaControlService
    let outputHandler: OutputHandler
    let historyService: HistoryService
    var context: FeatureContext?
    var recordingHelper: (any RecordingSessionProviding)?
    var deactivationWorkItem: DispatchWorkItem?
    private let deviceMonitor = DeviceMonitor()

    // MARK: Fuzz/test seams — production defaults, overridden by the
    // interaction fuzzer so schedules control what wall-clock, hardware,
    // and modal dialogs would otherwise decide.

    /// Capture factory; the fuzzer substitutes gate-controlled fakes.
    var makeRecordingHelper: () -> any RecordingSessionProviding = {
        RecordingSessionHelper()
    }
    /// Crash-spool factory for simple captures. Defaults to nil (no spool)
    /// so tests and fuzzers never write recovery files; PRODUCTION wires
    /// SimpleCaptureSpool at construction (AppController).
    var makeCaptureSpool: () -> (any CaptureSpooling)? = { nil }
    /// The current capture session's crash spool. Created per capture at
    /// start, survives mic switches and the post-stop turn, and is
    /// discarded only at a terminal state (delivered / durably trashed /
    /// below the salvage threshold). An orphan on disk = crash → recovered
    /// at next launch into "Recently Deleted".
    var activeCaptureSpool: (any CaptureSpooling)?
    /// Busy-mode dialog decision; nil = real NSAlert.
    var busyChoiceProvider: (() -> ModeBusyChoice)?
    /// History-off confirm decision; nil = real NSAlert.
    var historyOffConfirmProvider: (() -> Bool)?
    /// Delayed-work scheduler (dismiss timers, mic-switch restarts); the
    /// fuzzer collects the items and fires them under schedule control.
    var scheduleDelayed: (TimeInterval, DispatchWorkItem) -> Void = { delay, item in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

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
    /// The audio behind the in-flight simple turn. Held from stop until the
    /// turn DELIVERS (.done) so a cancel during .transcribing/.processing —
    /// or a turn that dies in .error — can salvage the capture to
    /// "Recently Deleted" instead of losing it with the cancelled task.
    var inFlightTurnCapture: (samples: [Float], sampleRate: Double)?
    /// Persists discarded simple captures into "Recently Deleted" —
    /// see ModeFeatureDiscardSalvage.swift for what gets salvaged when.
    private(set) lazy var discardArchiver = DiscardedCaptureArchiver(
        history: historyService, transcriber: transcriptionService
    )
    /// The in-flight meeting save-stop: a second Stop tap must join it, not
    /// race it (a second handler.stop would flip the UI to idle mid-save and
    /// generation-suppress the first stop's error reporting).
    var meetingStopTask: Task<Void, Never>?
    /// Which capture era `meetingStopTask` stops. A stop may only coalesce
    /// with a stop of the SAME era: a task still persisting a PREVIOUS
    /// meeting must never swallow the stop of a capture it does not own —
    /// the new recording would sail on unowned behind a closed panel.
    /// (Found by the interaction fuzzer, seed 34311.)
    var meetingCaptureEra = 0
    var meetingStopTaskEra = -1
    /// History-enabled as it was when this meeting STARTED. The user may flip
    /// the setting mid-meeting; the contract they recorded under is the one
    /// that governs the save, and a mid-meeting flip must never silently
    /// discard an hour of audio at the commit point.
    var meetingHistoryEnabledAtStart: Bool = true
    /// A finished meeting that was never written to history (history off).
    /// Held so the panel can offer an export before the data disappears.
    var pendingMeetingExport: MeetingPersistencePayload?
    /// Audio captured before a mid-recording mic switch: switching devices
    /// must never destroy what was already said. Combined at stop.
    var carriedRecordingSegments: [(samples: [Float], sampleRate: Double)] = []
    /// The delayed restart after a mic switch — cancellable so a teardown
    /// in the 0.1s gap cannot be resurrected by it.
    var micSwitchRestartWorkItem: DispatchWorkItem?
    /// Overridable seam for tests; production asks AppKit whether a modal
    /// alert session is running.
    var isModalSessionActive: () -> Bool = { NSApp.modalWindow != nil }
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
        get { AppLaunchOverrides.runtimeDefaults.string(forKey: deviceUIDKey) }
        set { AppLaunchOverrides.runtimeDefaults.set(newValue, forKey: deviceUIDKey) }
    }

    init(
        config: ModeConfig,
        transcriptionService: any TranscriptionProviding,
        micPermission: MicrophonePermissionService,
        screenPermission: ScreenRecordingPermissionService? = nil,
        pasteService: any PasteProviding,
        clipboardService: any ClipboardProviding,
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
        if isSavingMeeting { return }
        cancelAndDeactivate()
    }

    /// A meeting save is writing to disk. Closing the panel now would tear
    /// down the runtime under an in-flight persist, so every user-initiated
    /// exit is refused until it resolves (the panel shows its progress).
    /// Scoped to save-stops: a discard-stop sets no meetingStopTask.
    var isSavingMeeting: Bool {
        meetingStopTask != nil
    }

    func cancel() {
        teardownRuntime()
    }

    /// Shared teardown for cancel and cancelAndDeactivate.
    private func teardownRuntime() {
        // Before anything is destroyed: a simple capture this teardown
        // would lose (live recording, in-flight turn, errored turn) goes
        // to "Recently Deleted" instead — the dictation counterpart of
        // the meeting discard below.
        salvageDiscardedSimpleCapture()
        turnGeneration += 1
        turnTask?.cancel(); turnTask = nil
        cancelScheduledDismiss()
        micSwitchRestartWorkItem?.cancel(); micSwitchRestartWorkItem = nil
        carriedRecordingSegments = []
        recordingHelper?.cancel(); recordingHelper = nil
        if let handler = meetingHandler, handler.hasLiveCapture {
            if case .error = state.phase {
                // An errored meeting still holds a live capture: salvage it
                // straight to history (UX-2) — an error is not a discard.
                stopMeeting(disposition: .save)
            } else {
                // A live meeting torn down by Escape/close/takeover is a
                // DISCARD, but a mistaken one must be recoverable: keep the
                // audio and transcript in "Recently Deleted" rather than
                // destroying them. Deliberate permanent deletion is a
                // separate action from the trash.
                stopMeeting(disposition: .discard)
            }
        } else {
            meetingHandler?.cancel()
        }
        // The user's chance to export an unsaved meeting ends with the panel.
        releasePendingMeetingExport()
        state.clearConversationSession()
        state.reset()
        isActive = false
        mediaControlService.resetState()
    }

    // MARK: - Helpers

    func cancelAndDeactivate() {
        teardownRuntime()
        context?.onDeactivate?(self)
        // The panel is gone and nothing is in flight — a config edit made
        // mid-capture can land now. Deliberately NOT in cancel(): callers of
        // plain cancel() (takeover, deletion) manage lifecycle themselves.
        applyPendingConfigIfIdle()
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
        scheduleDelayed(delay, item)
    }
}
#endif
