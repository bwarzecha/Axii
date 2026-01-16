//
//  HotkeyConfig.swift
//  dictaitor
//
//  Codable hotkey configuration using Carbon key codes.
//

#if os(macOS)
import Carbon.HIToolbox
import AppKit
import HotKey

/// Codable hotkey configuration for persistence.
/// Uses Carbon key codes which are stable and serializable.
struct HotkeyConfig: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32

    /// Default dictation hotkey: Control+Shift+Space
    static let `default` = HotkeyConfig(
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(controlKey) | UInt32(shiftKey)
    )

    /// Default conversation hotkey: Control+Option+Space
    static let conversationDefault = HotkeyConfig(
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(controlKey) | UInt32(optionKey)
    )

    /// Convert to HotKey library Key type for registration.
    /// Falls back to space key if the key code is invalid.
    var key: Key {
        Key(carbonKeyCode: keyCode) ?? .space
    }

    /// Convert Carbon modifiers to NSEvent.ModifierFlags.
    var nsModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }

    /// Human-readable display string (e.g., "Control+Shift+Space").
    var displayString: String {
        var parts: [String] = []

        // Modifiers in standard macOS order
        if modifiers & UInt32(controlKey) != 0 { parts.append("Control") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("Option") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("Shift") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("Command") }

        if let keyName = keyCodeToString(keyCode) {
            parts.append(keyName)
        }

        return parts.joined(separator: "+")
    }

    /// Create from NSEvent (used by hotkey recorder).
    init(from event: NSEvent) {
        self.keyCode = UInt32(event.keyCode)
        self.modifiers = Self.nsModifiersToCarbonModifiers(event.modifierFlags)
    }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Check if config has at least one modifier key.
    var hasModifiers: Bool {
        modifiers != 0
    }
}

// MARK: - Conversion Helpers

private extension HotkeyConfig {
    static func nsModifiersToCarbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        return carbon
    }

    func keyCodeToString(_ code: UInt32) -> String? {
        switch Int(code) {
        // Special keys
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Delete: return "Delete"
        case kVK_ForwardDelete: return "Forward Delete"
        case kVK_Escape: return "Escape"

        // Arrow keys
        case kVK_LeftArrow: return "Left"
        case kVK_RightArrow: return "Right"
        case kVK_UpArrow: return "Up"
        case kVK_DownArrow: return "Down"

        // Function keys
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"

        // Letters (ANSI layout)
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"

        // Numbers
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"

        default:
            return "Key(\(code))"
        }
    }
}
#endif
