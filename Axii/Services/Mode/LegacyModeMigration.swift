//
//  LegacyModeMigration.swift
//  Axii
//
//  One-time seeding of freshly created built-in modes from the
//  pre-mode-runtime (v1.8.2 and earlier) UserDefaults. Runs only when a
//  built-in mode's JSON does not exist yet — for an upgrader that is the
//  first launch after updating; fresh installs have no legacy keys, so
//  every mapping is a no-op. Without this, a 1.8.2 user's custom hotkeys,
//  microphone selections, and behavior toggles silently reset to defaults
//  (and the app "stops responding" to the hotkey they trained on).
//

#if os(macOS)
import Foundation

enum LegacyModeMigration {

    /// UserDefaults keys the pre-mode-runtime app wrote.
    enum LegacyKey {
        static let dictationHotkey = "settings.hotkeyConfig"
        static let conversationHotkey = "settings.conversationHotkeyConfig"
        static let meetingHotkey = "settings.meetingHotkeyConfig"
        static let dictationMic = "selectedMicrophoneUID"
        static let meetingMic = "meetingSelectedMicUID"
        static let pauseMedia = "settings.pauseMediaDuringDictation"
        static let insertionFailure = "settings.insertionFailureBehavior"
        static let meetingAnimation = "settings.meetingAnimationStyle"
        static let meetingPanelMode = "meetingPanelMode"
        static let panelModeCompact = "compact"
    }

    /// Returns the built-in mode seeded with any legacy preferences that
    /// map onto it, and migrates the mode's mic selection key as a side
    /// effect. `defaults` is where the legacy app wrote (production:
    /// the runtime store).
    static func seeded(
        _ mode: ModeConfig,
        defaults: UserDefaults = AppLaunchOverrides.runtimeDefaults
    ) -> ModeConfig {
        var seeded = mode
        switch mode.id {
        case DefaultModes.dictationId:
            if let hotkey = decodeHotkey(LegacyKey.dictationHotkey, defaults) {
                seeded.hotkey = hotkey
            }
            if defaults.object(forKey: LegacyKey.pauseMedia) != nil {
                seeded.lifecycle.pauseMedia =
                    defaults.bool(forKey: LegacyKey.pauseMedia)
            }
            if let raw = defaults.string(forKey: LegacyKey.insertionFailure),
               let behavior = InsertionFailureBehavior(rawValue: raw) {
                seeded.outputs = seeded.outputs.map { output in
                    guard case .pasteAtCursor(var config) = output else {
                        return output
                    }
                    config.failureBehavior = behavior
                    return .pasteAtCursor(config)
                }
            }
            migrateMic(from: LegacyKey.dictationMic, to: mode.id, defaults)
        case DefaultModes.conversationId:
            if let hotkey = decodeHotkey(
                LegacyKey.conversationHotkey, defaults
            ) {
                seeded.hotkey = hotkey
            }
        case DefaultModes.meetingId:
            if let hotkey = decodeHotkey(LegacyKey.meetingHotkey, defaults) {
                seeded.hotkey = hotkey
            }
            if let raw = defaults.string(forKey: LegacyKey.meetingAnimation),
               let style = RecordingIndicatorStyle(rawValue: raw) {
                seeded.panel.preferences.recordingIndicatorStyle = style
            }
            if let raw = defaults.string(forKey: LegacyKey.meetingPanelMode) {
                seeded.panel.preferences.compactModeEnabled =
                    raw == LegacyKey.panelModeCompact
            }
            migrateMic(from: LegacyKey.meetingMic, to: mode.id, defaults)
        default:
            break
        }
        return seeded
    }

    // MARK: - Private

    private static func decodeHotkey(
        _ key: String, _ defaults: UserDefaults
    ) -> HotkeyConfig? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(HotkeyConfig.self, from: data)
    }

    /// The per-mode mic key wins when already set; otherwise copy the
    /// legacy device UID so the user keeps their microphone.
    private static func migrateMic(
        from legacyKey: String, to modeID: UUID, _ defaults: UserDefaults
    ) {
        let modeKey = "mode_\(modeID)_selectedMic"
        guard defaults.string(forKey: modeKey) == nil,
              let uid = defaults.string(forKey: legacyKey) else { return }
        defaults.set(uid, forKey: modeKey)
    }
}
#endif
