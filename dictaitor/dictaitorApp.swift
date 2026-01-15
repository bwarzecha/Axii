//
//  DictAItorApp.swift
//  dictaitor
//
//  Menu bar app with floating panel triggered by global hotkey.
//

import SwiftUI

#if os(macOS)
import AppKit
import Combine
import HotKey

// MARK: - Constants

enum HotkeyConfig {
    static let key: Key = .space
    static let modifiers: NSEvent.ModifierFlags = [.control, .shift]
    static let displayString = "Control+Shift+Space"
}

// MARK: - App State

@MainActor
final class AppState: ObservableObject {
    @Published var isListening = false
    @Published var isPanelVisible = false

    private var hotKey: HotKey?
    private var panelController: FloatingPanelController?

    init() {
        setupHotKey()
        setupPanel()
    }

    private func setupHotKey() {
        hotKey = HotKey(key: HotkeyConfig.key, modifiers: HotkeyConfig.modifiers)

        hotKey?.keyDownHandler = { [weak self] in
            Task { @MainActor in
                self?.togglePanel()
            }
        }
    }

    private func setupPanel() {
        let panelView = RecordingPanelView(
            isListening: isListening,
            hotkeyHint: HotkeyConfig.displayString
        )
        panelController = FloatingPanelController(content: panelView)

        panelController?.setDismissHandler { [weak self] in
            self?.isPanelVisible = false
        }
    }

    func togglePanel() {
        isPanelVisible.toggle()
        updatePanel()
    }

    func showPanel() {
        isPanelVisible = true
        updatePanel()
    }

    func hidePanel() {
        isPanelVisible = false
        updatePanel()
    }

    private func updatePanel() {
        if isPanelVisible {
            // Update content before showing
            let panelView = RecordingPanelView(
                isListening: isListening,
                hotkeyHint: HotkeyConfig.displayString
            )
            panelController?.updateContent(panelView)
            panelController?.show()
        } else {
            panelController?.hide()
        }
    }

    func toggleListening() {
        isListening.toggle()
        // Update panel content to reflect new state
        if isPanelVisible {
            let panelView = RecordingPanelView(
                isListening: isListening,
                hotkeyHint: HotkeyConfig.displayString
            )
            panelController?.updateContent(panelView)
        }
    }
}

#endif

// MARK: - App Entry Point

@main
struct DictAItorApp: App {
    #if os(macOS)
    @StateObject private var appState = AppState()
    #endif

    var body: some Scene {
        #if os(macOS)
        // Minimal menu bar - just for quit and status
        MenuBarExtra("DictAItor", systemImage: appState.isPanelVisible ? "waveform" : "mic") {
            VStack(spacing: 8) {
                Text(appState.isPanelVisible ? "Panel visible" : "Panel hidden")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Hotkey: \(HotkeyConfig.displayString)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Divider()

                Button("Toggle Panel") {
                    appState.togglePanel()
                }
                .keyboardShortcut("p", modifiers: [.command])

                Divider()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: [.command])
            }
            .padding(.vertical, 8)
            .frame(width: 180)
        }
        .menuBarExtraStyle(.menu)

        #else
        // iOS fallback
        WindowGroup {
            ContentView()
        }
        #endif
    }
}
