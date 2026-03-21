//
//  FeatureManager.swift
//  Axii
//
//  Manages feature lifecycle. Features register themselves; manager ensures
//  only one feature is active at a time and coordinates panel display.
//

#if os(macOS)
import SwiftUI
import HotKey

/// Manages registered features and coordinates their lifecycle.
/// - Features register their own hotkeys
/// - Only one feature can be active at a time
/// - Handles escape key for active feature
@MainActor
final class FeatureManager {
    private let hotkeyService: HotkeyService
    private let advancedHotkeyService: AdvancedHotkeyService?
    private let settings: SettingsService
    private var features: [any Feature] = []
    private var activeFeature: (any Feature)?
    private var panelController: FloatingPanelController?

    /// Observable status source for the menu bar. Updated on activate/deactivate.
    let statusSource = AppStatusSource()

    /// Callback when panel content changes
    var onPanelContentChanged: ((AnyView?) -> Void)?

    init(
        hotkeyService: HotkeyService,
        advancedHotkeyService: AdvancedHotkeyService? = nil,
        settings: SettingsService
    ) {
        self.hotkeyService = hotkeyService
        self.advancedHotkeyService = advancedHotkeyService
        self.settings = settings
    }

    /// Sets the panel controller for showing/hiding UI
    func setPanelController(_ controller: FloatingPanelController) {
        self.panelController = controller
    }

    /// Registers a feature. The feature will register its own hotkeys.
    func register(_ feature: any Feature) {
        let context = FeatureContext(
            hotkeyService: hotkeyService,
            advancedHotkeyService: advancedHotkeyService,
            settings: settings
        )

        context.onActivate = { [weak self] feature in
            self?.activateFeature(feature)
        }

        context.onDeactivate = { [weak self] in
            self?.deactivateCurrentFeature()
        }

        feature.register(with: context)
        features.append(feature)
    }

    // MARK: - Feature Lifecycle

    private func activateFeature(_ feature: any Feature) {
        // Cancel current feature if different
        if let current = activeFeature, current !== feature {
            current.cancel()
        }

        activeFeature = feature
        statusSource.activeState = (feature as? ModeFeature)?.state

        // Update panel with feature's content
        panelController?.updateContent(feature.panelContent)
        panelController?.show()

        // Register escape hotkey for active feature
        hotkeyService.register(.escape, key: .escape, modifiers: []) { [weak self] in
            self?.handleEscape()
        }
    }

    private func deactivateCurrentFeature() {
        activeFeature = nil
        statusSource.activeState = nil
        panelController?.hide()
        hotkeyService.unregister(.escape)
    }

    private func handleEscape() {
        activeFeature?.handleEscape()
    }

    /// Returns whether any feature is currently active
    var hasActiveFeature: Bool {
        activeFeature != nil
    }

    // MARK: - Mode Config Updates

    /// Updates a ModeFeature's config (called by editor). Re-registers hotkey if changed.
    func updateModeConfig(_ config: ModeConfig) {
        guard let modeFeature = features.compactMap({ $0 as? ModeFeature }).first(where: { $0.config.id == config.id }) else { return }
        modeFeature.updateConfig(config)
    }

    /// Removes a ModeFeature by config ID (for deleted custom modes).
    func unregisterMode(id: UUID) {
        guard let index = features.firstIndex(where: {
            ($0 as? ModeFeature)?.config.id == id
        }) else { return }
        let feature = features[index]
        feature.cancel()
        features.remove(at: index)
    }

    /// Checks if a mode is currently active (for editor disable state).
    func isModeActive(_ id: UUID) -> Bool {
        features.compactMap { $0 as? ModeFeature }.first { $0.config.id == id }?.isActive ?? false
    }
}
#endif
