//
//  SettingsView.swift
//  Axii
//
//  Main settings window container.
//

#if os(macOS)
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: SettingsService
    var inputMonitoringPermission: InputMonitoringPermissionService

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Settings")
                .font(.title2)
                .fontWeight(.semibold)

            Divider()

            HotkeyModeSettingView(
                currentMode: settings.hotkeyMode,
                isPermissionGranted: inputMonitoringPermission.isGranted,
                onModeChange: { settings.setHotkeyMode($0) },
                onRequestPermission: { inputMonitoringPermission.requestAccess() }
            )

            Divider()

            HotkeySettingView(
                hotkeyConfig: settings.hotkeyConfig,
                onUpdate: { settings.updateHotkey($0) },
                onReset: { settings.resetHotkeyToDefault() },
                onStartRecording: { settings.startHotkeyRecording() },
                onStopRecording: { settings.stopHotkeyRecording() },
                allowFnKey: settings.hotkeyMode == .advanced
            )

            Divider()

            // History settings
            VStack(alignment: .leading, spacing: 8) {
                Text("History")
                    .font(.headline)

                Toggle("Save interaction history", isOn: $settings.isHistoryEnabled)
                    .toggleStyle(.switch)

                Text("When enabled, dictations and conversations are saved for later review.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(24)
        .frame(width: 400, height: 400)
    }
}
#endif
