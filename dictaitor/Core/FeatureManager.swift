//
//  FeatureManager.swift
//  dictaitor
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
    private var features: [any Feature] = []
    private var activeFeature: (any Feature)?
    private var panelController: FloatingPanelController?

    /// Callback when panel content changes
    var onPanelContentChanged: ((AnyView?) -> Void)?

    init(hotkeyService: HotkeyService) {
        self.hotkeyService = hotkeyService
    }

    /// Sets the panel controller for showing/hiding UI
    func setPanelController(_ controller: FloatingPanelController) {
        self.panelController = controller
    }

    /// Registers a feature. The feature will register its own hotkeys.
    func register(_ feature: any Feature) {
        let context = FeatureContext(hotkeyService: hotkeyService)

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
}
#endif
