//
//  MeetingSettingsView.swift
//  Axii
//
//  Settings view for meeting transcription configuration.
//

#if os(macOS)
import SwiftUI

struct MeetingSettingsView: View {
    @Bindable var settings: SettingsService

    var body: some View {
        Form {
            Section {
                HotkeySettingView(
                    hotkeyConfig: settings.meetingHotkeyConfig,
                    onUpdate: { settings.updateMeetingHotkey($0) },
                    onReset: { settings.resetMeetingHotkeyToDefault() },
                    onStartRecording: { settings.startHotkeyRecording() },
                    onStopRecording: { settings.stopHotkeyRecording() },
                    allowFnKey: settings.hotkeyMode == .advanced
                )
            } header: {
                Text("Hotkey")
            }

            Section {
                animationStylePicker
            } header: {
                Text("Recording Indicator")
            } footer: {
                Text("Choose how the recording indicator appears in the compact meeting panel.")
            }

            Section {
                Toggle("Live Transcription", isOn: Binding(
                    get: { settings.isMeetingStreamingEnabled },
                    set: { settings.setMeetingStreamingEnabled($0) }
                ))
            } header: {
                Text("Transcription")
            } footer: {
                Text("When enabled, text appears in real-time during recording. Disable if you experience stability issues — the full transcript will still be generated when you stop recording.")
            }

            Section {
                Toggle("Save to History", isOn: Binding(
                    get: { settings.isMeetingHistoryEnabled },
                    set: { settings.setMeetingHistoryEnabled($0) }
                ))
            } header: {
                Text("History")
            } footer: {
                Text("When enabled, meeting transcripts and audio recordings are saved to History for later review.")
            }
        }
        .formStyle(.grouped)
    }

    private var animationStylePicker: some View {
        Picker("Animation Style", selection: Binding(
            get: { settings.meetingAnimationStyle },
            set: { settings.setMeetingAnimationStyle($0) }
        )) {
            ForEach(MeetingAnimationStyle.allCases, id: \.self) { style in
                Text(style.displayName).tag(style)
            }
        }
        .pickerStyle(.menu)
    }

}

#Preview {
    MeetingSettingsView(settings: SettingsService())
}
#endif
