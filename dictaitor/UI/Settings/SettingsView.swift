//
//  SettingsView.swift
//  dictaitor
//
//  Main settings window container.
//

#if os(macOS)
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: SettingsService

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Settings")
                .font(.title2)
                .fontWeight(.semibold)

            Divider()

            HotkeySettingView(
                hotkeyConfig: settings.hotkeyConfig,
                onUpdate: { settings.updateHotkey($0) },
                onReset: { settings.resetHotkeyToDefault() },
                onStartRecording: { settings.startHotkeyRecording() },
                onStopRecording: { settings.stopHotkeyRecording() }
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
        .frame(width: 400, height: 280)
    }
}
#endif
