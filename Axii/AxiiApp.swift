//
//  AxiiApp.swift
//  Axii
//
//  Menu bar app with floating panel triggered by global hotkey.
//

import SwiftUI

#if os(macOS)
import AppKit

@main
struct AxiiApp: App {
    @State private var controller: AppController
    @StateObject private var updaterService = UpdaterService()

    init() {
        _controller = State(initialValue: AppController())
    }

    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // Menu bar for status and quit
        MenuBarExtra {
            MenuBarView(
                dictationState: controller.dictationFeature.state,
                hotkeyDisplay: controller.settings.hotkeyConfig.displayString,
                onShowOnboarding: { openWindow(id: "onboarding") },
                updaterService: updaterService
            )
        } label: {
            Image("MenuBarIcon")
                .renderingMode(.template)
        }
        .menuBarExtraStyle(.menu)

        // Onboarding window - show if models not downloaded
        Window("Setup", id: "onboarding") {
            OnboardingView(
                micPermission: controller.micPermission,
                accessibilityPermission: controller.accessibilityPermission,
                downloadService: controller.modelDownloadService,
                onComplete: {
                    controller.initializeServicesAfterDownload()
                    NSApp.keyWindow?.close()
                }
            )
            .onAppear {
                // Bring window to front and activate app
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(controller.needsOnboarding ? .presented : .suppressed)

        // Settings window
        Window("Settings", id: "settings") {
            SidebarSettingsView(
                settings: controller.settings,
                inputMonitoringPermission: controller.inputMonitoringPermission,
                mediaControlService: controller.mediaControlService,
                updaterService: updaterService
            )
            .onAppear {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        .windowResizability(.contentSize)

        // History window
        Window("History", id: "history") {
            HistoryView(historyService: controller.historyService)
                .onAppear {
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .defaultSize(width: 700, height: 500)

        // Credits/Acknowledgments window
        Window("Acknowledgments", id: "credits") {
            CreditsView()
                .onAppear {
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .windowResizability(.contentSize)
    }

}

/// Menu bar dropdown content.
struct MenuBarView: View {
    var dictationState: DictationState
    var hotkeyDisplay: String
    var onShowOnboarding: () -> Void
    @ObservedObject var updaterService: UpdaterService

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 8) {
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Hotkey: \(hotkeyDisplay)")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Divider()

            Button("History...") {
                showWindow(title: "History", id: "history")
            }

            Button("Settings...") {
                showWindow(title: "Settings", id: "settings")
            }

            Button("Setup Permissions...") {
                showWindow(title: "Setup", id: "onboarding")
                onShowOnboarding()
            }

            Button("Acknowledgments...") {
                showWindow(title: "Acknowledgments", id: "credits")
            }

            Divider()

            Button("Check for Updates...") {
                updaterService.checkForUpdates()
            }
            .disabled(!updaterService.canCheckForUpdates)

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: [.command])
        }
        .padding(.vertical, 8)
        .frame(width: 180)
    }

    /// Shows a window, bringing it to front if already open.
    private func showWindow(title: String, id: String) {
        if let window = NSApp.windows.first(where: { $0.title == title }) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            openWindow(id: id)
        }
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
        case .doneNeedsCopy:
            return "Copy pending"
        case .error:
            return "Error"
        }
    }
}
#endif
