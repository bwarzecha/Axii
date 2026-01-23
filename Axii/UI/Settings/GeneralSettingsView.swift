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
        }
        .formStyle(.grouped)
    }
}
#endif
