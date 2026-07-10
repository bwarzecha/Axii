//
//  ModeRuntimeState.swift
//  Axii
//
//  Unified observable state for all mode types.
//  ModeFeature writes to this; panel views observe it.
//

#if os(macOS)
import SwiftUI

@MainActor @Observable
final class ModeRuntimeState {
    // Phase
    var phase: ModePhase = .idle

    // Audio visualization
    var audioLevel: Float = 0
    var spectrum: [Float] = []
    var isWaitingForSignal: Bool = false

    // Transcription
    var liveTranscript: String = ""
    var finalText: String = ""

    // Conversation
    var messages: [DisplayMessage] = []
    var currentSessionId: UUID? = nil

    // Transcript segments
    var segments: [TranscriptSegment] = []
    var duration: TimeInterval = 0

    // Processing
    var processingProgress: Double = 0
    var processingStatus: String = ""

    // Error
    var error: String? = nil

    // Devices
    var availableMicrophones: [AudioDevice] = []
    var selectedMicrophone: AudioDevice? = nil
    /// The device actually capturing right now — can silently diverge from
    /// selectedMicrophone when an unplug forces a fallback. The panel shows
    /// this so the user is never lied to about which mic is recording.
    var activeCaptureDevice: AudioDevice? = nil
    var availableApps: [AudioApp] = []
    var selectedApp: AudioApp? = nil

    // Panel
    var panelMode: PanelDisplayMode = .default

    // Output
    var needsManualCopy: Bool = false
    var manualCopyText: String = ""
    var focusSnapshot: FocusSnapshot? = nil

    /// Clear conversation session state. Called by the runtime shell
    /// on cancel/deactivate — not by the turn processor or session store.
    /// This is the ONLY method that clears messages and currentSessionId.
    /// reset() intentionally does NOT touch these fields so that
    /// error-retry in multi-turn modes preserves the conversation.
    func clearConversationSession() {
        messages.removeAll()
        currentSessionId = nil
        liveTranscript = ""
        finalText = ""
    }

    /// Reset non-conversation runtime state to idle defaults.
    /// Does NOT clear messages or currentSessionId — use
    /// clearConversationSession() for that, called explicitly by
    /// cancel/cancelAndDeactivate when the session should end.
    func reset() {
        phase = .idle
        audioLevel = 0
        spectrum = []
        isWaitingForSignal = false
        liveTranscript = ""
        finalText = ""
        segments = []
        duration = 0
        processingProgress = 0
        processingStatus = ""
        error = nil
        needsManualCopy = false
        manualCopyText = ""
        focusSnapshot = nil
        activeCaptureDevice = nil
    }
}
// Note: Reuses DisplayMessage from ConversationState.swift (internal scope)
#endif
