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
    /// Current hotkey configuration.
    private(set) var hotkeyConfig: HotkeyConfig

    /// Called when hotkey configuration changes (for re-registration).
    var onHotkeyChanged: (() -> Void)?

    /// Called when hotkey recording starts (to pause global hotkeys).
    var onHotkeyRecordingStarted: (() -> Void)?

    /// Called when hotkey recording stops (to resume global hotkeys).
    var onHotkeyRecordingStopped: (() -> Void)?

    private let defaults: UserDefaults
    private let hotkeyKey = "settings.hotkeyConfig"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.hotkeyConfig = Self.loadHotkeyConfig(from: defaults, key: "settings.hotkeyConfig")
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

    static func loadHotkeyConfig(from defaults: UserDefaults, key: String) -> HotkeyConfig {
        guard let data = defaults.data(forKey: key),
              let config = try? JSONDecoder().decode(HotkeyConfig.self, from: data) else {
            return .default
        }
        return config
    }
}
#endif
