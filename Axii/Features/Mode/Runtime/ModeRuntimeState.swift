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
    var availableApps: [AudioApp] = []
    var selectedApp: AudioApp? = nil

    // Panel
    var panelMode: PanelDisplayMode = .default

    // Output
    var needsManualCopy: Bool = false
    var manualCopyText: String = ""
    var focusSnapshot: FocusSnapshot? = nil

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
    }
}
// Note: Reuses DisplayMessage from ConversationState.swift (internal scope)
#endif
