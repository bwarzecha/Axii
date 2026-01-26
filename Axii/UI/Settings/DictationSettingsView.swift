//
//  DictationSettingsView.swift
//  Axii
//
//  Dictation-specific settings: hotkey, finish behavior.
//

#if os(macOS)
import SwiftUI

struct DictationSettingsView: View {
    @Bindable var settings: SettingsService
    var mediaControlService: MediaControlService

    @State private var mediaControlAvailable: Bool = false

    var body: some View {
        Form {
            Section {
                HotkeySettingView(
                    hotkeyConfig: settings.hotkeyConfig,
                    onUpdate: { settings.updateHotkey($0) },
                    onReset: { settings.resetHotkeyToDefault() },
                    onStartRecording: { settings.startHotkeyRecording() },
                    onStopRecording: { settings.stopHotkeyRecording() },
                    allowFnKey: settings.hotkeyMode == .advanced
                )
            } header: {
                Text("Hotkey")
            }

            Section {
                Picker("After transcription", selection: Binding(
                    get: { settings.finishBehavior },
                    set: { settings.setFinishBehavior($0) }
                )) {
                    ForEach(FinishBehavior.allCases, id: \.self) { behavior in
                        Text(behavior.displayName).tag(behavior)
                    }
                }

                Text(settings.finishBehavior.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Text Output")
            }

            Section {
                Picker("When insertion fails", selection: Binding(
                    get: { settings.insertionFailureBehavior },
                    set: { settings.setInsertionFailureBehavior($0) }
                )) {
                    ForEach(InsertionFailureBehavior.allCases, id: \.self) { behavior in
                        Text(behavior.displayName).tag(behavior)
                    }
                }

                Text(settings.insertionFailureBehavior.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Insertion may fail if you switch apps during recording, the cursor is in a password field, or Accessibility permission is not granted.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } header: {
                Text("Insertion Failure")
            }

            Section {
                if mediaControlAvailable {
                    Toggle("Pause media during recording", isOn: Binding(
                        get: { settings.pauseMediaDuringDictation },
                        set: { settings.setPauseMediaDuringDictation($0) }
                    ))

                    Text("Pauses music and podcasts when recording starts. Resumes automatically if something was playing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("media-control not installed")
                            .foregroundStyle(.secondary)

                        Text("To enable pausing media during dictation, install media-control:")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text("brew tap ungive/media-control && brew install media-control")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(6)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(4)

                        Button("Check again") {
                            mediaControlAvailable = mediaControlService.checkAvailability(forceRecheck: true)
                        }
                        .buttonStyle(.link)
                    }
                }
            } header: {
                Text("Media Control")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            mediaControlAvailable = mediaControlService.checkAvailability()
        }
    }
}
#endif
