//
//  SettingsView.swift
//  dictaitor
//
//  Main settings window container.
//

#if os(macOS)
import SwiftUI

struct SettingsView: View {
    let settings: SettingsService

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

            Spacer()
        }
        .padding(24)
        .frame(width: 400, height: 200)
    }
}
#endif
