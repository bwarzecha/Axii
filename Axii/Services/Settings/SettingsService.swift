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

    /// Current meeting hotkey configuration.
    private(set) var meetingHotkeyConfig: HotkeyConfig

    /// Meeting animation style for compact view.
    private(set) var meetingAnimationStyle: MeetingAnimationStyle

    /// Audio storage format for saved recordings (ALAC lossless or AAC compressed).
    private(set) var audioStorageFormat: AudioStorageFormat

    /// Current hotkey mode (standard or advanced).
    private(set) var hotkeyMode: HotkeyMode

    /// Finish behavior for dictation (what to do with transcribed text).
    private(set) var finishBehavior: FinishBehavior

    /// What to do when insertion fails.
    private(set) var insertionFailureBehavior: InsertionFailureBehavior

    /// Whether to pause media playback during dictation (default: false)
    private(set) var pauseMediaDuringDictation: Bool

    /// Whether meeting history saving is enabled (default: true)
    private(set) var isMeetingHistoryEnabled: Bool

    /// Whether real-time streaming transcription is enabled during meetings (default: true).
    /// When disabled, transcription only runs after recording stops (more stable but no live text).
    private(set) var isMeetingStreamingEnabled: Bool

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

    /// Called when meeting hotkey configuration changes (for re-registration).
    var onMeetingHotkeyChanged: (() -> Void)?

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
    private let meetingHotkeyKey = "settings.meetingHotkeyConfig"
    private let meetingAnimationStyleKey = "settings.meetingAnimationStyle"
    private let audioStorageFormatKey = "settings.audioStorageFormat"
    private let historyEnabledKey = "settings.isHistoryEnabled"
    private let hotkeyModeKey = "settings.hotkeyMode"
    private let finishBehaviorKey = "settings.finishBehavior"
    private let insertionFailureBehaviorKey = "settings.insertionFailureBehavior"
    private let pauseMediaKey = "settings.pauseMediaDuringDictation"
    private let meetingHistoryEnabledKey = "settings.isMeetingHistoryEnabled"
    private let meetingStreamingEnabledKey = "settings.isMeetingStreamingEnabled"

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
        self.meetingHotkeyConfig = Self.loadHotkeyConfig(
            from: defaults,
            key: "settings.meetingHotkeyConfig",
            defaultValue: .meetingDefault
        )
        self.meetingAnimationStyle = Self.loadMeetingAnimationStyle(from: defaults)
        self.audioStorageFormat = Self.loadAudioStorageFormat(from: defaults)
        self.hotkeyMode = Self.loadHotkeyMode(from: defaults)
        self.finishBehavior = Self.loadFinishBehavior(from: defaults)
        self.insertionFailureBehavior = Self.loadInsertionFailureBehavior(from: defaults)
        // Pause media is disabled by default
        self.pauseMediaDuringDictation = defaults.object(forKey: "settings.pauseMediaDuringDictation") as? Bool ?? false
        // History is enabled by default
        self.isHistoryEnabled = defaults.object(forKey: "settings.isHistoryEnabled") as? Bool ?? true
        // Meeting history is enabled by default
        self.isMeetingHistoryEnabled = defaults.object(forKey: "settings.isMeetingHistoryEnabled") as? Bool ?? true
        // Streaming transcription is enabled by default
        self.isMeetingStreamingEnabled = defaults.object(forKey: "settings.isMeetingStreamingEnabled") as? Bool ?? true
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

    /// Updates the meeting hotkey configuration and persists it.
    func updateMeetingHotkey(_ config: HotkeyConfig) {
        guard config != meetingHotkeyConfig else { return }
        meetingHotkeyConfig = config
        saveMeetingHotkeyConfig()
        onMeetingHotkeyChanged?()
    }

    /// Resets meeting hotkey to default value.
    func resetMeetingHotkeyToDefault() {
        updateMeetingHotkey(.meetingDefault)
    }

    /// Updates the meeting animation style and persists it.
    func setMeetingAnimationStyle(_ style: MeetingAnimationStyle) {
        guard style != meetingAnimationStyle else { return }
        meetingAnimationStyle = style
        defaults.set(style.rawValue, forKey: meetingAnimationStyleKey)
    }

    /// Updates the audio storage format and persists it.
    func setAudioStorageFormat(_ format: AudioStorageFormat) {
        guard format != audioStorageFormat else { return }
        audioStorageFormat = format
        defaults.set(format.rawValue, forKey: audioStorageFormatKey)
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
        meetingHotkeyConfig = .meetingDefault
        saveHotkeyConfig()
        saveConversationHotkeyConfig()
        saveMeetingHotkeyConfig()
        onHotkeyChanged?()
        onConversationHotkeyChanged?()
        onMeetingHotkeyChanged?()
    }

    /// Updates the finish behavior and persists it.
    func setFinishBehavior(_ behavior: FinishBehavior) {
        guard behavior != finishBehavior else { return }
        finishBehavior = behavior
        defaults.set(behavior.rawValue, forKey: finishBehaviorKey)
    }

    /// Updates the insertion failure behavior and persists it.
    func setInsertionFailureBehavior(_ behavior: InsertionFailureBehavior) {
        guard behavior != insertionFailureBehavior else { return }
        insertionFailureBehavior = behavior
        defaults.set(behavior.rawValue, forKey: insertionFailureBehaviorKey)
    }

    /// Updates the pause media during dictation setting and persists it.
    func setPauseMediaDuringDictation(_ enabled: Bool) {
        guard enabled != pauseMediaDuringDictation else { return }
        pauseMediaDuringDictation = enabled
        defaults.set(enabled, forKey: pauseMediaKey)
    }

    /// Updates the meeting history enabled setting and persists it.
    func setMeetingHistoryEnabled(_ enabled: Bool) {
        guard enabled != isMeetingHistoryEnabled else { return }
        isMeetingHistoryEnabled = enabled
        defaults.set(enabled, forKey: meetingHistoryEnabledKey)
    }

    /// Updates the streaming transcription setting and persists it.
    func setMeetingStreamingEnabled(_ enabled: Bool) {
        guard enabled != isMeetingStreamingEnabled else { return }
        isMeetingStreamingEnabled = enabled
        defaults.set(enabled, forKey: meetingStreamingEnabledKey)
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

    func saveMeetingHotkeyConfig() {
        guard let data = try? JSONEncoder().encode(meetingHotkeyConfig) else {
            return
        }
        defaults.set(data, forKey: meetingHotkeyKey)
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

    static func loadFinishBehavior(from defaults: UserDefaults) -> FinishBehavior {
        guard let rawValue = defaults.string(forKey: "settings.finishBehavior"),
              let behavior = FinishBehavior(rawValue: rawValue) else {
            return .insertAndCopy
        }
        return behavior
    }

    static func loadInsertionFailureBehavior(from defaults: UserDefaults) -> InsertionFailureBehavior {
        guard let rawValue = defaults.string(forKey: "settings.insertionFailureBehavior"),
              let behavior = InsertionFailureBehavior(rawValue: rawValue) else {
            return .showCopyButton
        }
        return behavior
    }

    static func loadMeetingAnimationStyle(from defaults: UserDefaults) -> MeetingAnimationStyle {
        guard let rawValue = defaults.string(forKey: "settings.meetingAnimationStyle"),
              let style = MeetingAnimationStyle(rawValue: rawValue) else {
            return .pulsingDot
        }
        return style
    }

    static func loadAudioStorageFormat(from defaults: UserDefaults) -> AudioStorageFormat {
        guard let rawValue = defaults.string(forKey: "settings.audioStorageFormat"),
              let format = AudioStorageFormat(rawValue: rawValue) else {
            return .alac  // Default to lossless
        }
        return format
    }
}
#endif
