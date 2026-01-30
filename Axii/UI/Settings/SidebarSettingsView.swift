//
//  SidebarSettingsView.swift
//  Axii
//
//  Main settings container with sidebar navigation.
//

#if os(macOS)
import SwiftUI

struct SidebarSettingsView: View {
    @Bindable var settings: SettingsService
    var inputMonitoringPermission: InputMonitoringPermissionService
    var mediaControlService: MediaControlService
    var llmSettings: LLMSettingsService
    @ObservedObject var updaterService: UpdaterService

    @State private var selectedSection: SettingsSection = .general

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedSection) {
                ForEach(SettingsSection.allCases) { section in
                    Label(section.title, systemImage: section.icon)
                        .tag(section)
                }
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 180, max: 220)
        } detail: {
            detailView
                .navigationTitle(selectedSection.title)
        }
        .frame(width: 550, height: 400)
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedSection {
        case .general:
            GeneralSettingsView(
                settings: settings,
                inputMonitoringPermission: inputMonitoringPermission
            )
        case .dictation:
            DictationSettingsView(settings: settings, mediaControlService: mediaControlService)
        case .conversation:
            ConversationSettingsView(settings: settings, llmSettings: llmSettings)
        case .meeting:
            MeetingSettingsView(settings: settings)
        case .about:
            AboutSettingsView(updaterService: updaterService)
        }
    }
}

// MARK: - Settings Section

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case dictation
    case conversation
    case meeting
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .dictation: return "Dictation"
        case .conversation: return "Conversation"
        case .meeting: return "Meeting"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gear"
        case .dictation: return "mic"
        case .conversation: return "bubble.left.and.bubble.right"
        case .meeting: return "person.2.wave.2"
        case .about: return "info.circle"
        }
    }
}

// MARK: - Placeholder for Conversation Settings

struct ConversationSettingsView: View {
    @Bindable var settings: SettingsService
    var llmSettings: LLMSettingsService

    var body: some View {
        Form {
            Section {
                HotkeySettingView(
                    hotkeyConfig: settings.conversationHotkeyConfig,
                    onUpdate: { settings.updateConversationHotkey($0) },
                    onReset: { settings.resetConversationHotkeyToDefault() },
                    onStartRecording: { settings.startHotkeyRecording() },
                    onStopRecording: { settings.stopHotkeyRecording() },
                    allowFnKey: settings.hotkeyMode == .advanced
                )
            } header: {
                Text("Hotkey")
            }

            Section {
                LLMSettingsView(settings: llmSettings)
            } header: {
                Text("LLM Provider")
            }
        }
        .formStyle(.grouped)
    }
}
#endif
