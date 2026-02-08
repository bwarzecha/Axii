//
//  HotkeyService.swift
//  Axii
//
//  Centralized global hotkey management.
//

#if os(macOS)
import AppKit
import HotKey

/// Identifiers for registered hotkeys.
struct HotkeyID: Hashable {
    let rawValue: String

    static let togglePanel = HotkeyID(rawValue: "togglePanel")
    static let conversation = HotkeyID(rawValue: "conversation")
    static let meeting = HotkeyID(rawValue: "meeting")
    static let escape = HotkeyID(rawValue: "escape")

    /// Dynamic ID for custom modes
    static func mode(_ id: UUID) -> HotkeyID {
        HotkeyID(rawValue: "mode_\(id.uuidString)")
    }
}

/// Centralized service for managing global hotkeys.
/// All hotkey registration/unregistration goes through this service.
@MainActor
final class HotkeyService {
    private var hotkeys: [HotkeyID: HotKey] = [:]
    private var isPaused = false

    /// Temporarily pauses all hotkey handlers.
    /// Use when capturing new hotkey input to prevent conflicts.
    func pause() {
        isPaused = true
    }

    /// Resumes hotkey handlers after pausing.
    func resume() {
        isPaused = false
    }

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
        hotkey.keyDownHandler = { [weak self] in
            guard self?.isPaused != true else { return }
            handler()
        }
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
#endif
