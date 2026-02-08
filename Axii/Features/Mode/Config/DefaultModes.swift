//
//  DefaultModes.swift
//  Axii
//
//  Default ModeConfig instances for the three built-in modes.
//  Fixed UUIDs ensure settings compatibility across launches.
//

#if os(macOS)
import Foundation

enum DefaultModes {
    // Fixed UUIDs for settings compatibility
    static let dictationId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let conversationId = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let meetingId = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    static func dictation() -> ModeConfig {
        ModeConfig(
            id: dictationId,
            name: "Dictation",
            icon: "mic.fill",
            isBuiltIn: true,
            hotkey: .default,
            audioCapture: .simple(SimpleCaptureConfig(devicePreference: .lastUsed)),
            transcription: .batch(BatchTranscriptionConfig()),
            processing: [],
            outputs: [
                .pasteAtCursor(PasteConfig()),
                .history(HistoryConfig(saveAudio: true)),
            ],
            lifecycle: LifecycleConfig(
                startMode: .automatic,
                panelPersistence: .autoDismiss(delay: 2.0),
                escapeBehavior: .alwaysCancel,
                pauseMedia: true,
                captureFocus: true,
                permissions: [.microphone]
            ),
            panel: PanelConfig(
                layout: .standard,
                preferences: PanelPreferences(
                    recordingIndicatorStyle: .radialBar,
                    transcriptDisplay: .none,
                    showCopyButton: true
                )
            )
        )
    }

    static func conversation() -> ModeConfig {
        ModeConfig(
            id: conversationId,
            name: "Conversation",
            icon: "bubble.left.and.bubble.right.fill",
            isBuiltIn: true,
            hotkey: .conversationDefault,
            audioCapture: .simple(SimpleCaptureConfig(devicePreference: .systemDefault)),
            transcription: .batch(BatchTranscriptionConfig()),
            processing: [.llmTransform(LLMTransformConfig(systemPrompt: "", multiTurn: true))],
            outputs: [
                .display,
                .history(HistoryConfig(saveAudio: false)),
            ],
            lifecycle: LifecycleConfig(
                startMode: .automatic,
                panelPersistence: .stayOpen,
                escapeBehavior: .alwaysCancel,
                permissions: [.microphone]
            ),
            panel: PanelConfig(
                layout: .conversation,
                preferences: PanelPreferences(
                    recordingIndicatorStyle: .radialBar,
                    transcriptDisplay: .none,
                    showCopyButton: false
                )
            )
        )
    }

    static func meeting() -> ModeConfig {
        ModeConfig(
            id: meetingId,
            name: "Meeting",
            icon: "person.2.fill",
            isBuiltIn: true,
            hotkey: .meetingDefault,
            audioCapture: .dual(DualCaptureConfig(
                devicePreference: .lastUsed,
                appSelection: .userSelected
            )),
            transcription: .streaming(StreamingConfig(chunkDurationSeconds: 15.0)),
            processing: [.diarize(DiarizeConfig())],
            outputs: [
                .display,
                .history(HistoryConfig(saveAudio: true, audioFormat: .aac)),
            ],
            lifecycle: LifecycleConfig(
                startMode: .manual,
                panelPersistence: .stayOpen,
                escapeBehavior: .blockWhileRecording,
                permissions: [.microphone, .screenRecording],
                enableCrashRecovery: true
            ),
            panel: PanelConfig(
                layout: .standard,
                preferences: PanelPreferences(
                    recordingIndicatorStyle: .pulsingDot,
                    transcriptDisplay: .full,
                    showDurationTimer: true,
                    showCopyButton: false,
                    compactModeEnabled: true
                )
            )
        )
    }
}
#endif
