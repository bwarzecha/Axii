//
//  DictAItorApp.swift
//  dictaitor
//
//  Menu bar app with floating panel triggered by global hotkey.
//

import SwiftUI

#if os(macOS)
import AppKit

@main
struct DictAItorApp: App {
    @State private var controller = AppController()

    var body: some Scene {
        // Menu bar for status and quit
        MenuBarExtra("DictAItor", systemImage: menuBarIcon) {
            MenuBarView(dictationState: controller.dictationFeature.state)
        }
        .menuBarExtraStyle(.menu)
    }

    private var menuBarIcon: String {
        controller.dictationFeature.isActive ? "waveform" : "mic"
    }
}

/// Menu bar dropdown content.
struct MenuBarView: View {
    var dictationState: DictationState

    var body: some View {
        VStack(spacing: 8) {
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Hotkey: Control+Shift+Space")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: [.command])
        }
        .padding(.vertical, 8)
        .frame(width: 180)
    }

    private var statusText: String {
        switch dictationState.phase {
        case .idle:
            return "Ready"
        case .loadingModel:
            return "Loading model..."
        case .recording:
            return "Recording..."
        case .transcribing:
            return "Transcribing..."
        case .done:
            return "Done"
        case .error:
            return "Error"
        }
    }
}

#else
// iOS fallback
@main
struct DictAItorApp: App {
    var body: some Scene {
        WindowGroup {
            Text("DictAItor is macOS only")
        }
    }
}
#endif
