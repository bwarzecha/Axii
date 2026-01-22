//
//  SettingsService.swift
//  Axii
//
//  Manages app settings with UserDefaults persistence.
//

#if os(macOS)
import Foundation

/// Hotkey detection mode.
/// Standard uses Carbon API (no Fn support), Advanced uses CGEventTap (Fn supported).
enum HotkeyMode: String, Codable {
    case standard
    case advanced
}

/// Observable settings service with UserDefaults persistence.
/// Changes notify listeners via callbacks for live updates.
@MainActor
@Observable
final class SettingsService {
    /// Current dictation hotkey configuration.
    private(set) var hotkeyConfig: HotkeyConfig

    /// Current conversation hotkey configuration.
    private(set) var conversationHotkeyConfig: HotkeyConfig

    /// Current hotkey mode (standard or advanced).
    private(set) var hotkeyMode: HotkeyMode

    /// Whether history saving is enabled (default: true)
    var isHistoryEnabled: Bool {
        didSet {
            defaults.set(isHistoryEnabled, forKey: historyEnabledKey)
            onHistorySettingChanged?(isHistoryEnabled)
        }
    }

    /// Called when dictation hotkey configuration changes (for re-registration).
    var onHotkeyChanged: (() -> Void)?

    /// Called when conversation hotkey configuration changes (for re-registration).
    var onConversationHotkeyChanged: (() -> Void)?

    /// Called when hotkey recording starts (to pause global hotkeys).
    var onHotkeyRecordingStarted: (() -> Void)?

    /// Called when hotkey recording stops (to resume global hotkeys).
    var onHotkeyRecordingStopped: (() -> Void)?

    /// Called when history setting changes
    var onHistorySettingChanged: ((Bool) -> Void)?

    /// Called when hotkey mode changes (to switch between services).
    var onHotkeyModeChanged: (() -> Void)?

    private let defaults: UserDefaults
    private let hotkeyKey = "settings.hotkeyConfig"
    private let conversationHotkeyKey = "settings.conversationHotkeyConfig"
    private let historyEnabledKey = "settings.isHistoryEnabled"
    private let hotkeyModeKey = "settings.hotkeyMode"

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
        self.hotkeyMode = Self.loadHotkeyMode(from: defaults)
        // History is enabled by default
        self.isHistoryEnabled = defaults.object(forKey: "settings.isHistoryEnabled") as? Bool ?? true
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

    /// Sets the hotkey mode and resets all hotkeys to defaults.
    /// Switching modes requires re-registering hotkeys with different service.
    func setHotkeyMode(_ mode: HotkeyMode) {
        guard mode != hotkeyMode else { return }
        hotkeyMode = mode
        saveHotkeyMode()
        // First: switch services (stop old, start new)
        onHotkeyModeChanged?()
        // Then: reset hotkeys which triggers re-registration with new service
        resetAllHotkeysToDefaults()
    }

    /// Resets all hotkeys to their default values.
    func resetAllHotkeysToDefaults() {
        hotkeyConfig = .default
        conversationHotkeyConfig = .conversationDefault
        saveHotkeyConfig()
        saveConversationHotkeyConfig()
        onHotkeyChanged?()
        onConversationHotkeyChanged?()
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

    func saveHotkeyMode() {
        defaults.set(hotkeyMode.rawValue, forKey: hotkeyModeKey)
    }

    static func loadHotkeyMode(from defaults: UserDefaults) -> HotkeyMode {
        guard let rawValue = defaults.string(forKey: "settings.hotkeyMode"),
              let mode = HotkeyMode(rawValue: rawValue) else {
            return .standard
        }
        return mode
    }
}
#endif
