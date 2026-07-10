//
//  ModeFeatureHotkeys.swift
//  Axii
//
//  Hotkey routing and panel button handling for ModeFeature.
//  Extracted to keep each file under 300 lines.
//

#if os(macOS)
import AppKit

extension ModeFeature {

    // MARK: - Cross-Mode Takeover Protection

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

    func handleHotkey() {
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
}
#endif
