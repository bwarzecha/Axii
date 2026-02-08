//
//  ModeEditorBehavior.swift
//  Axii
//
//  Behavior section: lifecycle, panel preferences, permissions.
//

#if os(macOS)
import SwiftUI

struct ModeEditorBehavior: View {
    @Binding var config: ModeConfig
    let mediaControlService: MediaControlService
    let onSave: () -> Void

    @State private var showAdvanced = false
    @State private var mediaControlAvailable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Recording start
            VStack(alignment: .leading, spacing: 6) {
                Text("Recording start")
                    .font(.subheadline.bold())
                Picker("", selection: Binding(
                    get: { config.lifecycle.startMode },
                    set: { config.lifecycle.startMode = $0; onSave() }
                )) {
                    Text("Automatic (starts immediately)").tag(StartMode.automatic)
                    Text("Manual (show Start button)").tag(StartMode.manual)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            // Panel preferences
            VStack(alignment: .leading, spacing: 8) {
                Picker("Recording indicator:", selection: Binding(
                    get: { config.panel.preferences.recordingIndicatorStyle },
                    set: { config.panel.preferences.recordingIndicatorStyle = $0; onSave() }
                )) {
                    Text("Radial Bar").tag(RecordingIndicatorStyle.radialBar)
                    Text("Pulsing Dot").tag(RecordingIndicatorStyle.pulsingDot)
                    Text("Waveform").tag(RecordingIndicatorStyle.waveform)
                    Text("None").tag(RecordingIndicatorStyle.none)
                }
                .pickerStyle(.menu)
                .frame(width: 280)

                Picker("Live transcript:", selection: Binding(
                    get: { config.panel.preferences.transcriptDisplay },
                    set: { config.panel.preferences.transcriptDisplay = $0; onSave() }
                )) {
                    Text("None").tag(TranscriptDisplay.none)
                    Text("Minimal (single line)").tag(TranscriptDisplay.minimal)
                    Text("Full (scrollable)").tag(TranscriptDisplay.full)
                }
                .pickerStyle(.menu)
                .frame(width: 280)
            }

            // Toggles
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Show duration timer", isOn: Binding(
                    get: { config.panel.preferences.showDurationTimer },
                    set: { config.panel.preferences.showDurationTimer = $0; onSave() }
                ))
                Toggle("Show copy button when results available", isOn: Binding(
                    get: { config.panel.preferences.showCopyButton },
                    set: { config.panel.preferences.showCopyButton = $0; onSave() }
                ))
                Toggle("Allow compact mode toggle", isOn: Binding(
                    get: { config.panel.preferences.compactModeEnabled },
                    set: { config.panel.preferences.compactModeEnabled = $0; onSave() }
                ))
            }

            // After completion
            VStack(alignment: .leading, spacing: 6) {
                Text("After completion")
                    .font(.subheadline.bold())

                let isAutoDismiss = isAutoDismissBinding
                Picker("", selection: isAutoDismiss) {
                    Text("Auto-dismiss").tag(true)
                    Text("Stay open until closed").tag(false)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                if case .autoDismiss(let delay) = config.lifecycle.panelPersistence {
                    HStack {
                        Text("After")
                        TextField("", value: Binding(
                            get: { delay },
                            set: { config.lifecycle.panelPersistence = .autoDismiss(delay: $0); onSave() }
                        ), format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 50)
                        Text("seconds")
                    }
                    .padding(.leading, 20)
                    .font(.caption)
                }
            }

            // Escape behavior
            VStack(alignment: .leading, spacing: 6) {
                Text("Escape key")
                    .font(.subheadline.bold())
                Picker("", selection: Binding(
                    get: { config.lifecycle.escapeBehavior },
                    set: { config.lifecycle.escapeBehavior = $0; onSave() }
                )) {
                    Text("Cancel and discard").tag(EscapeBehavior.alwaysCancel)
                    Text("Block during recording").tag(EscapeBehavior.blockWhileRecording)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            // Pause media
            if mediaControlAvailable {
                Toggle("Pause media during recording", isOn: Binding(
                    get: { config.lifecycle.pauseMedia },
                    set: { config.lifecycle.pauseMedia = $0; onSave() }
                ))
            }

            // Advanced
            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Enable crash recovery", isOn: Binding(
                        get: { config.lifecycle.enableCrashRecovery },
                        set: { config.lifecycle.enableCrashRecovery = $0; onSave() }
                    ))

                    HStack {
                        Text("Permissions:")
                        Text(config.lifecycle.permissions.map { $0.rawValue.capitalized }.joined(separator: ", "))
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
                .padding(.top, 4)
            }
            .font(.subheadline)
        }
        .onAppear {
            mediaControlAvailable = mediaControlService.checkAvailability()
        }
    }

    // MARK: - Helpers

    private var isAutoDismissBinding: Binding<Bool> {
        Binding(
            get: {
                if case .autoDismiss = config.lifecycle.panelPersistence { return true }
                return false
            },
            set: {
                config.lifecycle.panelPersistence = $0 ? .autoDismiss(delay: 2.0) : .stayOpen
                onSave()
            }
        )
    }
}
#endif
