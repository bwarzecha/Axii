//
//  SettingsService.swift
//  dictaitor
//
//  Manages app settings with UserDefaults persistence.
//

#if os(macOS)
import Foundation

/// Observable settings service with UserDefaults persistence.
/// Changes notify listeners via callbacks for live updates.
@MainActor
@Observable
final class SettingsService {
    /// Current dictation hotkey configuration.
    private(set) var hotkeyConfig: HotkeyConfig

    /// Current conversation hotkey configuration.
    private(set) var conversationHotkeyConfig: HotkeyConfig

    /// Called when dictation hotkey configuration changes (for re-registration).
    var onHotkeyChanged: (() -> Void)?

    /// Called when conversation hotkey configuration changes (for re-registration).
    var onConversationHotkeyChanged: (() -> Void)?

    /// Called when hotkey recording starts (to pause global hotkeys).
    var onHotkeyRecordingStarted: (() -> Void)?

    /// Called when hotkey recording stops (to resume global hotkeys).
    var onHotkeyRecordingStopped: (() -> Void)?

    private let defaults: UserDefaults
    private let hotkeyKey = "settings.hotkeyConfig"
    private let conversationHotkeyKey = "settings.conversationHotkeyConfig"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.hotkeyConfig = Self.loadHotkeyConfig(
            from: defaults,
            key: "settings.hotkeyConfig",
            defaultValue: .default
        )
        self.conversationHotkeyConfig = Self.loadHotkeyConfig(
            from: defaults,
            key: "settings.conversationHotkeyConfig",
            defaultValue: .conversationDefault
        )
    }

    /// Updates the hotkey configuration and persists it.
    func updateHotkey(_ config: HotkeyConfig) {
        guard config != hotkeyConfig else { return }
        hotkeyConfig = config
        saveHotkeyConfig()
        onHotkeyChanged?()
    }

    /// Resets hotkey to default value.
    func resetHotkeyToDefault() {
        updateHotkey(.default)
    }

    /// Updates the conversation hotkey configuration and persists it.
    func updateConversationHotkey(_ config: HotkeyConfig) {
        guard config != conversationHotkeyConfig else { return }
        conversationHotkeyConfig = config
        saveConversationHotkeyConfig()
        onConversationHotkeyChanged?()
    }

    /// Resets conversation hotkey to default value.
    func resetConversationHotkeyToDefault() {
        updateConversationHotkey(.conversationDefault)
    }

    /// Call when starting to record a new hotkey.
    func startHotkeyRecording() {
        onHotkeyRecordingStarted?()
    }

    /// Call when done recording a new hotkey.
    func stopHotkeyRecording() {
        onHotkeyRecordingStopped?()
    }
}

// MARK: - Persistence

private extension SettingsService {
    func saveHotkeyConfig() {
        guard let data = try? JSONEncoder().encode(hotkeyConfig) else {
            return
        }
        defaults.set(data, forKey: hotkeyKey)
    }

    func saveConversationHotkeyConfig() {
        guard let data = try? JSONEncoder().encode(conversationHotkeyConfig) else {
            return
        }
        defaults.set(data, forKey: conversationHotkeyKey)
    }

    static func loadHotkeyConfig(
        from defaults: UserDefaults,
        key: String,
        defaultValue: HotkeyConfig
    ) -> HotkeyConfig {
        guard let data = defaults.data(forKey: key),
              let config = try? JSONDecoder().decode(HotkeyConfig.self, from: data) else {
            return defaultValue
        }
        return config
    }
}
#endif
