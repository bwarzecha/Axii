//
//  SidebarSettingsView.swift
//  Axii
//
//  Main settings container with sidebar navigation.
//  Supports General, dynamic mode list, and About sections.
//

#if os(macOS)
import SwiftUI

struct SidebarSettingsView: View {
    @Bindable var settings: SettingsService
    var inputMonitoringPermission: InputMonitoringPermissionService
    var mediaControlService: MediaControlService
    var llmSettings: LLMSettingsService
    var bedrockClient: BedrockClient
    var modeService: ModeService
    var onConfigChanged: (ModeConfig) -> Void
    var onModeCreated: (ModeConfig) -> Void
    var onModeDeleted: (UUID) -> Void
    /// Asks the runtime whether deleting this mode would destroy anything
    /// (active panel, live recording, in-flight save). Deletion is refused
    /// while it would.
    var canDeleteMode: (UUID) -> Bool = { _ in true }
    @ObservedObject var updaterService: UpdaterService

    @State private var selectedItem: SettingsSidebarItem = .general
    @State private var modes: [ModeConfig] = []
    @State private var showTemplateChooser = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 150, ideal: 180, max: 220)
        } detail: {
            detailView
                .navigationTitle(selectedItemTitle)
        }
        .frame(width: 580, height: 500)
        .onAppear { modes = modeService.loadAllModes() }
        .sheet(isPresented: $showTemplateChooser) {
            ModeTemplateChooser { newConfig in
                handleCreate(newConfig)
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selectedItem) {
            // General
            Label("General", systemImage: "gear")
                .tag(SettingsSidebarItem.general)

            // Built-in Modes
            Section("Modes") {
                ForEach(builtInModes) { mode in
                    Label(mode.name, systemImage: mode.icon)
                        .tag(SettingsSidebarItem.mode(mode.id))
                }
            }

            // Custom Modes
            if !customModes.isEmpty {
                Section("Custom") {
                    ForEach(customModes) { mode in
                        Label(mode.name, systemImage: mode.icon)
                            .tag(SettingsSidebarItem.mode(mode.id))
                    }
                }
            }

            // New Mode button
            Section {
                Button {
                    showTemplateChooser = true
                } label: {
                    Label("New Mode", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }

            // About
            Label("About", systemImage: "info.circle")
                .tag(SettingsSidebarItem.about)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailView: some View {
        switch selectedItem {
        case .general:
            GeneralSettingsView(
                settings: settings,
                inputMonitoringPermission: inputMonitoringPermission
            )
        case .mode(let id):
            if let mode = modes.first(where: { $0.id == id }) {
                ModeEditorView(
                    config: mode,
                    modeService: modeService,
                    settings: settings,
                    mediaControlService: mediaControlService,
                    onConfigChanged: { updated in
                        onConfigChanged(updated)
                        reloadModes()
                    },
                    onDelete: {
                        handleDelete(id: id)
                    },
                    onReset: {
                        handleReset(id: id)
                    },
                    onDuplicate: {
                        handleDuplicate(mode)
                    },
                    canDelete: { canDeleteMode(id) }
                )
                .id(id) // Force view recreation when switching modes
            } else {
                Text("Mode not found")
                    .foregroundStyle(.secondary)
            }
        case .about:
            AboutSettingsView(updaterService: updaterService)
        }
    }

    // MARK: - Helpers

    private var builtInModes: [ModeConfig] {
        modes.filter { $0.isBuiltIn }
    }

    private var customModes: [ModeConfig] {
        modes.filter { !$0.isBuiltIn }
    }

    private var selectedItemTitle: String {
        switch selectedItem {
        case .general: return "General"
        case .mode(let id): return modes.first { $0.id == id }?.name ?? "Mode"
        case .about: return "About"
        }
    }

    private func reloadModes() {
        modes = modeService.loadAllModes()
    }

    private func handleDelete(id: UUID) {
        // The button disables while busy, but that state can go stale (a
        // hotkey can start a recording while Settings sits open) — re-check
        // at the moment of truth, BEFORE the mode's file is deleted, so file
        // and runtime never disagree about whether the mode exists.
        guard canDeleteMode(id) else {
            let alert = NSAlert()
            alert.messageText = "Mode is in use"
            alert.informativeText = "Stop the recording or wait for the save to finish before deleting this mode."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        do {
            try modeService.delete(id: id)
        } catch {
            // File already gone or inaccessible — still unregister the
            // runtime below so no hotkey-driveable zombie survives.
        }
        onModeDeleted(id)
        reloadModes()
        selectedItem = .general
    }

    private func handleReset(id: UUID) {
        try? modeService.resetToDefault(id: id)
        reloadModes()
    }

    private func handleDuplicate(_ mode: ModeConfig) {
        let copy = ModeConfig(
            id: UUID(),
            name: "\(mode.name) Copy",
            icon: mode.icon,
            isBuiltIn: false,
            hotkey: nil,
            audioCapture: mode.audioCapture,
            transcription: mode.transcription,
            processing: mode.processing,
            outputs: mode.outputs,
            lifecycle: mode.lifecycle,
            panel: mode.panel
        )
        handleCreate(copy)
    }

    private func handleCreate(_ config: ModeConfig) {
        do {
            try modeService.save(config)
            onModeCreated(config)
            reloadModes()
            selectedItem = .mode(config.id)
        } catch {
            // Save failed — don't register the feature or navigate to it
        }
    }
}

// MARK: - Sidebar Item

enum SettingsSidebarItem: Hashable, Identifiable {
    case general
    case mode(UUID)
    case about

    var id: String {
        switch self {
        case .general: return "general"
        case .mode(let uuid): return "mode_\(uuid.uuidString)"
        case .about: return "about"
        }
    }
}
#endif
