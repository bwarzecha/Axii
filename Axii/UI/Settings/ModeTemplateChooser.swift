//
//  ModeTemplateChooser.swift
//  Axii
//
//  Template selection sheet for creating new custom modes.
//  Each template provides a pre-configured ModeConfig as a starting point.
//

#if os(macOS)
import SwiftUI

struct ModeTemplateChooser: View {
    let onCreate: (ModeConfig) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Mode")
                .font(.title2.bold())

            Text("Choose a template to start from:")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                ForEach(ModeTemplates.all, id: \.name) { template in
                    templateRow(template)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 380)
    }

    private func templateRow(_ template: ModeTemplate) -> some View {
        Button {
            onCreate(template.create())
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: template.icon)
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(template.name)
                        .font(.body.bold())
                    Text(template.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.04))
        )
    }
}

// MARK: - Template Definition

struct ModeTemplate {
    let name: String
    let icon: String
    let description: String
    let create: () -> ModeConfig
}

enum ModeTemplates {
    static let all: [ModeTemplate] = [
        quickCapture,
        clipboardDictation,
        fileJournal,
        meetingRecorder,
        blank,
    ]

    static let quickCapture = ModeTemplate(
        name: "Quick Capture",
        icon: "mic.fill",
        description: "Record and paste text at cursor"
    ) {
        ModeConfig(
            id: UUID(),
            name: "Quick Capture",
            icon: "mic.fill",
            isBuiltIn: false,
            hotkey: nil,
            audioCapture: .simple(SimpleCaptureConfig(devicePreference: .lastUsed)),
            transcription: .batch(BatchTranscriptionConfig()),
            processing: [],
            outputs: [
                .pasteAtCursor(PasteConfig()),
                .history(HistoryConfig(saveAudio: false)),
            ],
            lifecycle: LifecycleConfig(
                startMode: .automatic,
                panelPersistence: .autoDismiss(delay: 2.0),
                escapeBehavior: .alwaysCancel,
                pauseMedia: true,
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

    static let clipboardDictation = ModeTemplate(
        name: "Clipboard Dictation",
        icon: "doc.on.clipboard",
        description: "Record and copy text to clipboard"
    ) {
        ModeConfig(
            id: UUID(),
            name: "Clipboard Dictation",
            icon: "doc.on.clipboard",
            isBuiltIn: false,
            hotkey: nil,
            audioCapture: .simple(SimpleCaptureConfig(devicePreference: .lastUsed)),
            transcription: .batch(BatchTranscriptionConfig()),
            processing: [],
            outputs: [
                .clipboard(ClipboardConfig()),
                .history(HistoryConfig(saveAudio: false)),
            ],
            lifecycle: LifecycleConfig(
                startMode: .automatic,
                panelPersistence: .autoDismiss(delay: 2.0),
                escapeBehavior: .alwaysCancel,
                permissions: [.microphone]
            ),
            panel: PanelConfig(
                layout: .standard,
                preferences: PanelPreferences(
                    recordingIndicatorStyle: .radialBar,
                    transcriptDisplay: .none,
                    showCopyButton: false
                )
            )
        )
    }

    static let fileJournal = ModeTemplate(
        name: "File Journal",
        icon: "doc.text",
        description: "Record and append to a text file"
    ) {
        ModeConfig(
            id: UUID(),
            name: "File Journal",
            icon: "doc.text",
            isBuiltIn: false,
            hotkey: nil,
            audioCapture: .simple(SimpleCaptureConfig(devicePreference: .lastUsed)),
            transcription: .batch(BatchTranscriptionConfig()),
            processing: [],
            outputs: [
                .file(FileOutputConfig(
                    pathTemplate: "~/Documents/journal-{date}.txt",
                    writeMode: .append
                )),
                .history(HistoryConfig(saveAudio: false)),
            ],
            lifecycle: LifecycleConfig(
                startMode: .automatic,
                panelPersistence: .autoDismiss(delay: 2.0),
                escapeBehavior: .alwaysCancel,
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

    static let meetingRecorder = ModeTemplate(
        name: "Meeting Recorder",
        icon: "person.2.fill",
        description: "Record mic + system audio with speaker labels"
    ) {
        ModeConfig(
            id: UUID(),
            name: "Meeting Recorder",
            icon: "person.2.fill",
            isBuiltIn: false,
            hotkey: nil,
            audioCapture: .dual(DualCaptureConfig(
                devicePreference: .lastUsed,
                appSelection: .userSelected
            )),
            transcription: .streaming(StreamingConfig(chunkDurationSeconds: 15.0)),
            processing: [.diarize(DiarizeConfig())],
            outputs: [
                .display(DisplayConfig()),
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

    static let blank = ModeTemplate(
        name: "Blank Mode",
        icon: "square.dashed",
        description: "Start from scratch with minimal defaults"
    ) {
        ModeConfig(
            id: UUID(),
            name: "New Mode",
            icon: "waveform",
            isBuiltIn: false,
            hotkey: nil,
            audioCapture: .simple(SimpleCaptureConfig()),
            transcription: .batch(BatchTranscriptionConfig()),
            processing: [],
            outputs: [.display(DisplayConfig())],
            lifecycle: LifecycleConfig(permissions: [.microphone]),
            panel: PanelConfig(
                layout: .standard,
                preferences: PanelPreferences()
            )
        )
    }
}
#endif
