//
//  ModeFeatureHotkeys.swift
//  Axii
//
//  Hotkey routing and panel button handling for ModeFeature.
//  Extracted to keep each file under 300 lines.
//

#if os(macOS)
import AppKit

/// The user's verdict on another mode's unsaved data before a takeover.
enum ModeBusyChoice {
    case saveAndSwitch, discardAndSwitch, stay
}

extension ModeFeature {

    // MARK: - Cross-Mode Takeover Protection

    private func askBusyModeChoice() -> ModeBusyChoice {
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

    func handleHotkey() {
        // While ANY modal alert is up, global hotkeys are inert. Carbon
        // events deliver during modal sessions, and acting on them corrupts
        // the question the dialog is asking: nested busy dialogs whose stale
        // outer verdict destroys a turn the inner one preserved, or a new
        // capture started behind a dialog that then "discards" it.
        guard !isModalSessionActive() else { return }
        // Another mode holds unsaved data: the user decides its fate BEFORE
        // this mode touches the microphone — a muscle-memory keystroke must
        // never silently destroy an hour-long recording.
        if let busy = context?.busyFeature?(), busy !== self {
            switch busyChoiceProvider?() ?? askBusyModeChoice() {
            case .saveAndSwitch:
                // Re-validate after the modal: the dialog may have sat open
                // while the busy feature's save finished on its own. The
                // verdict applies only to data that still exists.
                if busy.isDataBearing { busy.stopAndPreserve() }
            case .discardAndSwitch:
                if busy.isDataBearing { busy.cancel() }
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
        case .done:
            // An unsaved meeting is on screen awaiting export — the hotkey
            // must not discard it. Copy is the only exit that keeps the data.
            if pendingMeetingExport != nil { copyAndDismiss(state.manualCopyText) }
            else { state.reset() }
        case .processing, .transcribing: break
        }
    }

    // MARK: - Panel Buttons

    func handleStartButton() {
        if meetingHandler != nil { startMeeting() }
    }

    func handleStopButton() {
        if meetingHandler != nil { stopMeeting(saveToHistory: true) }
    }

    /// The panel hides its close button during a save, but a stale click can
    /// still land as the phase flips — refuse it rather than tear down mid-write.
    func handleCloseButton() {
        if isSavingMeeting { return }
        cancelAndDeactivate()
    }

    func copyAndDismiss(_ text: String) {
        clipboardService.copy(text); cancelAndDeactivate()
    }

    /// Copy the running meeting transcript mid-recording. Unlike
    /// `copyAndDismiss`, this leaves the capture and panel untouched — the
    /// meeting keeps recording while the user pastes the transcript so far.
    func copyLiveTranscript() {
        guard !state.segments.isEmpty else { return }
        clipboardService.copy(Self.transcriptText(from: state.segments))
    }

    // MARK: - Data-Bearing Takeover Protection

    var isDataBearing: Bool {
        if meetingHandler?.hasLiveCapture == true { return true }
        // An unsaved (history-off) meeting awaiting export exists ONLY in
        // this panel and its on-disk artifacts — displacement must not
        // silently destroy it.
        if pendingMeetingExport != nil { return true }
        // A discarded capture whose trash write is still in flight: the
        // quit gate must not let the process die under it.
        if discardArchiver.pendingWrites > 0 { return true }
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
        } else if let export = pendingMeetingExport {
            // History-off meeting awaiting export: copy the transcript out
            // (the only delivery possible without history) and leave the
            // recovery artifacts ON DISK — recoverable if history returns,
            // expired otherwise. Only cancel() destroys them deliberately.
            clipboardService.copy(Self.transcriptText(from: export.segments))
            pendingMeetingExport = nil
        } else if state.phase.isRecording,
                  recordingHelper != nil || !carriedRecordingSegments.isEmpty {
            // The carried check matters: inside the 0.1s mic-switch restart
            // gap there is no helper, but the audio so far is carried and
            // must be delivered, not cancelled.
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
}
#endif
