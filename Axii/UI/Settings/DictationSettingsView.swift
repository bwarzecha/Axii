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
        }
        .formStyle(.grouped)
    }
}
#endif
