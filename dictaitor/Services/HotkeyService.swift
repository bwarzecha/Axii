//
//  HotkeyService.swift
//  dictaitor
//
//  Centralized global hotkey management.
//

import AppKit
import HotKey

/// Identifiers for registered hotkeys.
enum HotkeyID: String, CaseIterable {
    case togglePanel
    case escape
    // Future hotkeys:
    // case startRecording
    // case stopRecording
    // case cancel
}

/// Centralized service for managing global hotkeys.
/// All hotkey registration/unregistration goes through this service.
@MainActor
final class HotkeyService {
    private var hotkeys: [HotkeyID: HotKey] = [:]

    /// Registers a global hotkey with the given configuration.
    /// - Parameters:
    ///   - id: Unique identifier for the hotkey
    ///   - key: The key to register
    ///   - modifiers: Modifier keys (shift, control, option, command)
    ///   - handler: Closure called when hotkey is pressed
    func register(
        _ id: HotkeyID,
        key: Key,
        modifiers: NSEvent.ModifierFlags,
        handler: @escaping () -> Void
    ) {
        // Unregister existing if any
        hotkeys[id] = nil

        let hotkey = HotKey(key: key, modifiers: modifiers)
        hotkey.keyDownHandler = handler
        hotkeys[id] = hotkey
    }

    /// Unregisters a hotkey by its identifier.
    func unregister(_ id: HotkeyID) {
        hotkeys[id] = nil
    }

    /// Checks if a hotkey is currently registered.
    func isRegistered(_ id: HotkeyID) -> Bool {
        hotkeys[id] != nil
    }

    /// Unregisters all hotkeys.
    func unregisterAll() {
        hotkeys.removeAll()
    }

    /// Returns all currently registered hotkey IDs.
    var registeredHotkeys: [HotkeyID] {
        Array(hotkeys.keys)
    }
}
