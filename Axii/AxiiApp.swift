//
//  AxiiApp.swift
//  Axii
//
//  Menu bar app with floating panel triggered by global hotkey.
//

import SwiftUI

#if os(macOS)
import AppKit

/// Termination gate: quitting (Cmd-Q, logout, Sparkle relaunch) must never
/// silently kill a live recording — dictation audio is memory-only and a
/// meeting's save may be mid-flight.
final class AxiiAppDelegate: NSObject, NSApplicationDelegate {
    static weak var featureManager: FeatureManager?

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard let busy = Self.featureManager?.dataBearingFeature else {
            return .terminateNow
        }

        if let mode = busy as? ModeFeature, mode.state.phase.isRecording {
            let alert = NSAlert()
            alert.messageText = "Recording in progress"
            alert.informativeText = "Quitting now will stop the recording. Save it first?"
            alert.addButton(withTitle: "Save, then Quit")
            alert.addButton(withTitle: "Quit and Discard")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                busy.stopAndPreserve()
            case .alertSecondButtonReturn:
                // Quit and discard. A full finalize is too slow for the quit
                // deadline, so we do NOT run one — but we also do not destroy
                // the artifacts. Leaving them on disk lets next-launch crash
                // recovery restore the meeting, so a mistaken "discard on
                // quit" is still recoverable. (A discard of a NON-recording
                // meeting — one already stopped — has no live artifacts and
                // its trashed copy already survives in Recently Deleted.)
                if mode.meetingHandler != nil { return .terminateNow }
                // A simple-mode recording is MEMORY-only — terminating now
                // is the one discard the trash can't catch. Cancel routes
                // it to "Recently Deleted"; the drain loop below then holds
                // termination until the audio write lands (the archiver's
                // pending write keeps the mode data-bearing).
                mode.cancel()
            default:
                return .terminateCancel
            }
        }

        // Saves/turns are in flight (or one was just started above): let
        // them ALL finish, then quit — a detached meeting save and a
        // just-stopped dictation can coexist, so re-scan every iteration
        // instead of watching one snapshot. Bounded: a wedged save cannot
        // block logout, and its recovery artifacts survive termination.
        let stoppedFeature = busy
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline {
                guard let stillBusy = Self.featureManager?.dataBearingFeature else {
                    break // everything drained
                }
                // A NEW recording started during the wait (a different
                // feature went live): the user changed their mind about
                // quitting — killing that recording silently is exactly
                // what this gate exists to prevent.
                if stillBusy !== stoppedFeature,
                   let mode = stillBusy as? ModeFeature,
                   mode.state.phase.isRecording {
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct AxiiApp: App {
    @NSApplicationDelegateAdaptor(AxiiAppDelegate.self) private var appDelegate
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
                appStatus: controller.featureManager.statusSource.appStatus,
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
                onConfigChanged: { updated in
                    if !controller.featureManager.updateModeConfig(updated) {
                        // The mode is mid-recording/save; its capture type
                        // cannot be swapped under a live session.
                        let alert = NSAlert()
                        alert.messageText = "Capture change will apply later"
                        alert.informativeText = "This mode is recording or saving. The audio capture change takes effect after it finishes and the mode is edited again, or when Axii restarts."
                        alert.alertStyle = .informational
                        alert.runModal()
                    }
                },
                onModeCreated: { controller.registerNewMode($0) },
                onModeDeleted: { controller.featureManager.unregisterMode(id: $0) },
                canDeleteMode: { controller.featureManager.canDeleteMode($0) },
                updaterService: updaterService
            )
            .onAppear {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        .windowResizability(.contentSize)

        // History window
        Window("History", id: "history") {
            HistoryView(
                historyService: controller.historyService,
                retranscriber: controller.meetingRetranscriber
            )
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
