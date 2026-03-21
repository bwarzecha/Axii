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
        // Menu bar — status derived from the active mode runtime, not legacy features
        MenuBarExtra {
            MenuBarView(
                appStatus: controller.featureManager.appStatus,
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
                llmSettings: controller.llmSettings,
                bedrockClient: controller.llmService.bedrockClient,
                modeService: controller.modeService,
                onConfigChanged: { controller.featureManager.updateModeConfig($0) },
                onModeCreated: { controller.registerNewMode($0) },
                onModeDeleted: { controller.featureManager.unregisterMode(id: $0) },
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
/// Status is derived from the active mode runtime via AppStatus.
struct MenuBarView: View {
    var appStatus: AppStatus
    var hotkeyDisplay: String
    var onShowOnboarding: () -> Void
    @ObservedObject var updaterService: UpdaterService

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 8) {
            Text(appStatus.menuBarText)
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
}
#endif
