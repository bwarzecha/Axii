//
//  GeneralSettingsView.swift
//  Axii
//
//  General app settings: hotkey mode, history toggle.
//

#if os(macOS)
import SwiftUI

struct GeneralSettingsView: View {
    @Bindable var settings: SettingsService
    var inputMonitoringPermission: InputMonitoringPermissionService

    var body: some View {
        Form {
            Section {
                HotkeyModeSettingView(
                    currentMode: settings.hotkeyMode,
                    isPermissionGranted: inputMonitoringPermission.isGranted,
                    onModeChange: { settings.setHotkeyMode($0) },
                    onRequestPermission: { inputMonitoringPermission.requestAccess() }
                )
            } header: {
                Text("Hotkey Mode")
            }

            Section {
                Toggle("Save interaction history", isOn: $settings.isHistoryEnabled)

                Text("When enabled, dictations and conversations are saved for later review.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("History")
            }

            Section {
                Picker("Format", selection: Binding(
                    get: { settings.audioStorageFormat },
                    set: { settings.setAudioStorageFormat($0) }
                )) {
                    ForEach(AudioStorageFormat.allCases, id: \.self) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("Audio Quality")
            } footer: {
                Text(settings.audioStorageFormat.description)
            }
        }
        .formStyle(.grouped)
    }
}
#endif
