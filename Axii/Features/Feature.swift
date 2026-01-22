//
//  Feature.swift
//  Axii
//
//  Protocol defining a self-contained feature that owns its hotkeys, state, and UI.
//

#if os(macOS)
import SwiftUI
import HotKey

/// Context provided to features for registration and signaling.
@MainActor
final class FeatureContext {
    let hotkeyService: HotkeyService
    let advancedHotkeyService: AdvancedHotkeyService?
    let settings: SettingsService

    /// Call when feature becomes active (shows UI, takes over)
    var onActivate: ((any Feature) -> Void)?

    /// Call when feature is done (hides UI, releases control)
    var onDeactivate: (() -> Void)?

    init(
        hotkeyService: HotkeyService,
        advancedHotkeyService: AdvancedHotkeyService? = nil,
        settings: SettingsService
    ) {
        self.hotkeyService = hotkeyService
        self.advancedHotkeyService = advancedHotkeyService
        self.settings = settings
    }

    /// Registers a hotkey using the appropriate service based on current mode.
    func registerHotkey(
        _ id: HotkeyID,
        config: HotkeyConfig,
        handler: @escaping () -> Void
    ) {
        switch settings.hotkeyMode {
        case .standard:
            hotkeyService.register(id, key: config.key, modifiers: config.nsModifiers, handler: handler)
        case .advanced:
            advancedHotkeyService?.register(id, config: config, handler: handler)
        }
    }

    /// Registers a hotkey with simple parameters (for hardcoded hotkeys).
    func registerHotkey(
        _ id: HotkeyID,
        key: Key,
        modifiers: NSEvent.ModifierFlags,
        handler: @escaping () -> Void
    ) {
        // Create a config without Fn (hardcoded hotkeys don't use Fn)
        let config = HotkeyConfig(key: key, modifiers: modifiers)
        registerHotkey(id, config: config, handler: handler)
    }

    /// Unregisters a hotkey from the appropriate service.
    func unregisterHotkey(_ id: HotkeyID) {
        hotkeyService.unregister(id)
        advancedHotkeyService?.unregister(id)
    }
}

/// Protocol for self-contained features.
/// Each feature owns its hotkeys, state machine, and UI.
@MainActor
protocol Feature: AnyObject {
    /// Whether this feature is currently active (has control)
    var isActive: Bool { get }

    /// The SwiftUI view to display in the panel when active
    var panelContent: AnyView { get }

    /// Register hotkeys and set up the feature
    func register(with context: FeatureContext)

    /// Handle escape key - typically cancels and deactivates
    func handleEscape()

    /// Force cancel - called when another feature needs to take over
    func cancel()
}
#endif
