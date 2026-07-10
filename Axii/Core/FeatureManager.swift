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

    /// Observable status source for the menu bar, kept in sync with the active
    /// mode's phase via the bridge's withObservationTracking loop.
    let statusSource = AppStatusSource()
    let statusBridge: PhaseStatusBridge

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
        self.statusBridge = PhaseStatusBridge(statusSource: statusSource)
    }

    /// Sets the panel controller for showing/hiding UI
    func setPanelController(_ controller: FloatingPanelController) {
        self.panelController = controller
    }

    /// Registers a feature. The feature will register its own hotkeys.
    /// Idempotent per mode id: a mode created before feature activation is
    /// registered immediately AND again by the later registerFeatures sweep —
    /// two live instances would split the hotkey and the editor between
    /// different configs. The quiescent duplicate is replaced; a busy one is
    /// kept and the newcomer dropped (never displace live data).
    func register(_ feature: any Feature) {
        if let mode = feature as? ModeFeature,
           let existingIndex = features.firstIndex(where: {
               ($0 as? ModeFeature)?.config.id == mode.config.id
           }) {
            let existing = features[existingIndex]
            guard isQuiescent(existing) else { return }
            existing.unregister()
            existing.cancel()
            features.remove(at: existingIndex)
        }

        let context = FeatureContext(
            hotkeyService: hotkeyService,
            advancedHotkeyService: advancedHotkeyService,
            settings: settings
        )

        context.onActivate = { [weak self] feature in
            self?.activateFeature(feature)
        }

        context.onDeactivate = { [weak self] requester in
            guard let self, requester === self.activeFeature else { return }
            self.deactivateCurrentFeature()
        }

        context.busyFeature = { [weak self] in
            guard let self, let active = self.activeFeature,
                  active.isDataBearing else { return nil }
            return active
        }

        feature.register(with: context)
        features.append(feature)
    }

    /// Any registered feature currently holding unsaved user data —
    /// consulted by app termination to avoid killing a live recording.
    var dataBearingFeature: (any Feature)? {
        features.first { $0.isDataBearing }
    }

    // MARK: - Feature Lifecycle

    private func activateFeature(_ feature: any Feature) {
        // Displace the current feature if different. Safety net: any
        // activation path that skipped the busy-mode dialog preserves data
        // (stop-and-save) rather than destroying it; for idle features this
        // is equivalent to cancel.
        if let current = activeFeature, current !== feature {
            if current.isDataBearing {
                current.stopAndPreserve()
            } else {
                current.cancel()
            }
        }

        activeFeature = feature

        // Start phase observation for the active mode's runtime state
        if let modeFeature = feature as? ModeFeature {
            statusBridge.observe(modeFeature.state)
        }

        // Update panel with feature's content
        panelController?.updateContent(feature.panelContent)
        panelController?.show()

        // Register escape hotkey for active feature
        registerEscapeHotkey()
    }

    private func registerEscapeHotkey() {
        hotkeyService.register(.escape, key: .escape, modifiers: []) { [weak self] in
            self?.handleEscape()
        }
    }

    /// Re-register every feature's hotkey (plus Escape if a feature is
    /// active). A hotkey-mode switch wipes BOTH services with unregisterAll;
    /// the legacy per-built-in settings callbacks re-registered only the
    /// three built-in modes, leaving every custom mode's hotkey dead until
    /// relaunch — including the finish hotkey of a recording in progress.
    func reRegisterAllHotkeys() {
        for feature in features {
            (feature as? ModeFeature)?.registerHotkey()
        }
        if activeFeature != nil {
            registerEscapeHotkey()
        }
    }

    private func deactivateCurrentFeature() {
        statusBridge.stop()
        activeFeature = nil
        panelController?.hide()
        hotkeyService.unregister(.escape)
    }

    private func handleEscape() {
        // While a modal alert is up, Escape belongs to the DIALOG. The
        // global hotkey consumes the keypress before the alert sees it —
        // acting on it here would cancel the very recording the dialog is
        // offering to save.
        guard NSApp.modalWindow == nil else { return }
        activeFeature?.handleEscape()
    }

    /// Returns whether any feature is currently active
    var hasActiveFeature: Bool {
        activeFeature != nil
    }

    // MARK: - Mode Config Updates

    /// Builds a fresh ModeFeature for capture-type config changes.
    /// Wired by AppController, which owns the service graph.
    var modeFeatureFactory: ((ModeConfig) -> ModeFeature?)?

    /// Updates a ModeFeature's config (called by editor).
    ///
    /// In-place edits apply immediately when idle and defer while busy (the
    /// feature enforces this). A capture-type change (mic-only ↔ mic+system)
    /// needs a different runtime shape — meeting handler, screen permission —
    /// so the feature is REBUILT, and only when quiescent. Returns false when
    /// a capture-type change had to wait: behavior converges once the mode is
    /// idle and next re-saved, or at launch (mode JSON is already current).
    /// Until then the mode safely keeps its old capture behavior — routing
    /// follows the handler that actually exists, never the config alone.
    @discardableResult
    func updateModeConfig(_ config: ModeConfig) -> Bool {
        guard let feature = features.compactMap({ $0 as? ModeFeature })
            .first(where: { $0.config.id == config.id }) else { return true }

        let needsRebuild = (feature.meetingHandler != nil) != config.audioCapture.isDual
        if needsRebuild, isQuiescent(feature), let fresh = modeFeatureFactory?(config) {
            feature.unregister()
            features.removeAll { ($0 as? ModeFeature) === feature }
            register(fresh)
            return true
        }

        // Report an unapplied capture-type change only on the save that
        // INTRODUCES it — the editor auto-saves every field, and the user
        // must not be re-warned on each subsequent keystroke.
        let requestedIsDual = (feature.pendingConfig ?? feature.config).audioCapture.isDual
        let introducesCaptureChange = needsRebuild
            && requestedIsDual != config.audioCapture.isDual
        feature.updateConfig(config)
        return !introducesCaptureChange
    }

    /// Removes a ModeFeature by config ID (for deleted custom modes).
    /// Refused while the mode is busy: deleting a mode must never destroy a
    /// live recording or an in-flight save, no matter which caller skipped
    /// the UI guard. Returns false when refused.
    @discardableResult
    func unregisterMode(id: UUID) -> Bool {
        guard let index = features.firstIndex(where: {
            ($0 as? ModeFeature)?.config.id == id
        }) else { return true }
        guard canDeleteMode(id) else { return false }
        let feature = features[index]
        // Hotkey first: once the feature leaves the registry, no keystroke
        // may revive it. Then runtime hygiene (pending dismiss timers) —
        // safe here because the busy guard proved there is nothing to lose.
        feature.unregister()
        feature.cancel()
        (feature as? ModeFeature)?.clearPersistedDeviceSelection()
        features.remove(at: index)
        return true
    }

    /// True when deleting the mode would destroy nothing: panel not showing,
    /// no recording, no save in flight. The editor disables Delete otherwise;
    /// unregisterMode enforces it regardless.
    func canDeleteMode(_ id: UUID) -> Bool {
        guard let feature = features.first(where: {
            ($0 as? ModeFeature)?.config.id == id
        }) else { return true }
        return isQuiescent(feature)
    }

    /// Nothing running, nothing showing, nothing unsaved — the only state in
    /// which a feature may be torn down or rebuilt without losing anything.
    private func isQuiescent(_ feature: any Feature) -> Bool {
        !(feature.isActive || feature.isDataBearing || feature === activeFeature)
    }
}
#endif
