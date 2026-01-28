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
                audioFormatPicker
            } header: {
                Text("Audio Quality")
            } footer: {
                Text(settings.meetingAudioFormat.description)
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

    private var audioFormatPicker: some View {
        Picker("Format", selection: Binding(
            get: { settings.meetingAudioFormat },
            set: { settings.setMeetingAudioFormat($0) }
        )) {
            ForEach(MeetingAudioFormat.allCases, id: \.self) { format in
                Text(format.displayName).tag(format)
            }
        }
        .pickerStyle(.menu)
    }
}

#Preview {
    MeetingSettingsView(settings: SettingsService())
}
#endif
