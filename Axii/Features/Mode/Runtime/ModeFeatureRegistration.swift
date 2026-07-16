//
//  ModeFeatureRegistration.swift
//  Axii
//
//  Hotkey registration/unregistration, config updates, and microphone
//  selection reconciliation for ModeFeature.
//  Extracted to keep each file under 300 lines.
//

#if os(macOS)
import Foundation

extension ModeFeature {

    // MARK: - Hotkey Registration

    var hotkeyHint: String {
        if let hotkey = config.hotkey { return hotkey.symbolString }
        // Fallback to SettingsService for modes without hotkey in config (migration)
        guard let context else { return "" }
        let s = context.settings
        switch config.id {
        case DefaultModes.dictationId: return s.hotkeyConfig.symbolString
        case DefaultModes.conversationId: return s.conversationHotkeyConfig.symbolString
        case DefaultModes.meetingId: return s.meetingHotkeyConfig.symbolString
        default: return ""
        }
    }

    func registerHotkey() {
        guard let context else { return }
        guard let hotkeyConfig = resolveHotkeyConfig() else { return }
        context.registerHotkey(hotkeyIDForConfig(), config: hotkeyConfig) { [weak self] in
            self?.handleHotkey()
        }
    }

    /// Exact inverse of register(with:): release the feature's external
    /// footprint — its global hotkey and its context. A deleted mode whose
    /// hotkey survives is a zombie: the keystroke still drives a feature no
    /// UI can reach. Runtime teardown (cancel vs stop-and-preserve) is the
    /// CALLER's policy — an unconditional cancel here would destroy a
    /// just-preserved capture whose async save has not detached it yet.
    /// Settings/device-monitor callbacks hold weak self and die with the
    /// feature; deliberately not cleared so a replacement feature's freshly
    /// wired callbacks are never nil-ed by the old one's teardown.
    func unregister() {
        context?.unregisterHotkey(hotkeyIDForConfig())
        context = nil
    }

    /// Forget the persisted per-mode device preference. Deletion-only
    /// cleanup — NOT part of unregister(), which is also used when a feature
    /// is rebuilt in place and must keep the user's choice.
    func clearPersistedDeviceSelection() {
        UserDefaults.standard.removeObject(forKey: deviceUIDKey)
    }

    private func hotkeyIDForConfig() -> HotkeyID {
        switch config.id {
        case DefaultModes.dictationId: return .togglePanel
        case DefaultModes.conversationId: return .conversation
        case DefaultModes.meetingId: return .meeting
        default: return .mode(config.id)
        }
    }

    private func resolveHotkeyConfig() -> HotkeyConfig? {
        if let hotkey = config.hotkey { return hotkey }
        // Fallback to SettingsService for pre-migration mode JSONs
        guard let context else { return nil }
        let s = context.settings
        switch config.id {
        case DefaultModes.dictationId: return s.hotkeyConfig
        case DefaultModes.conversationId: return s.conversationHotkeyConfig
        case DefaultModes.meetingId: return s.meetingHotkeyConfig
        default: return nil
        }
    }

    func wireSettingsCallback() {
        // Legacy: re-register hotkey when SettingsService changes (for pre-migration configs)
        let callback: () -> Void = { [weak self] in self?.registerHotkey() }
        switch config.id {
        case DefaultModes.dictationId: settings.onHotkeyChanged = callback
        case DefaultModes.conversationId: settings.onConversationHotkeyChanged = callback
        case DefaultModes.meetingId: settings.onMeetingHotkeyChanged = callback
        default: break
        }
    }

    /// Update config from editor. DEFERRED while the mode holds data:
    /// applying an edit mid-capture can flip the stop keystroke to a
    /// different execution family and strand the live recording — the turn
    /// contract must not change under an in-flight capture. Deferred edits
    /// land at the next idle boundary (panel close, next start, save
    /// completion). Capture-type changes are FeatureManager's job: they
    /// need a different runtime shape, so the feature is rebuilt.
    func updateConfig(_ newConfig: ModeConfig) {
        guard !isDataBearing else {
            pendingConfig = newConfig
            return
        }
        applyConfig(newConfig)
    }

    /// Land a deferred edit once nothing in flight can be affected by it.
    func applyPendingConfigIfIdle() {
        guard !isDataBearing, let pending = pendingConfig else { return }
        pendingConfig = nil
        applyConfig(pending)
    }

    private func applyConfig(_ newConfig: ModeConfig) {
        let hotkeyChanged = config.hotkey != newConfig.hotkey
        config = newConfig
        if hotkeyChanged { registerHotkey() }
    }

    // MARK: - Microphone Selection

    func refreshDeviceList() {
        state.availableMicrophones = DeviceMonitor.availableMicrophones()
        reconcileMicrophoneSelection(
            resolved: resolveSelectedMicrophone(),
            previous: state.selectedMicrophone
        )
    }

    /// A meeting captures with the device it was started with; if the
    /// resolved selection changed under it (unplug → nil, replug → the
    /// preferred mic again), the capture session must be told or its
    /// stored selection drifts from what the user sees. Dictation needs
    /// no reconciliation: it resolves the device fresh on each start.
    @discardableResult
    func reconcileMicrophoneSelection(
        resolved: AudioDevice?,
        previous: AudioDevice?
    ) -> Task<Void, Never>? {
        state.selectedMicrophone = resolved
        guard let handler = meetingHandler,
              state.phase == .recording,
              resolved?.uid != previous?.uid else { return nil }
        let source: AudioSource.MicrophoneSource =
            resolved.map { .specific($0) } ?? .systemDefault
        return Task {
            await handler.switchMicrophone(to: resolved, micSource: source)
        }
    }

    func resolveSelectedMicrophone() -> AudioDevice? {
        guard let uid = selectedDeviceUID else { return nil }
        return state.availableMicrophones.first { $0.uid == uid }
    }

    /// Remove per-mode mic selections whose mode no longer exists. The keys
    /// are per-mode-ID and otherwise accumulate forever — deleted custom
    /// modes in production, and fuzz-created UUID modes in the test suite,
    /// where they once grew the defaults domain past cfprefsd's 4MB limit
    /// (every write then fault-logs and every read pays a full-dictionary
    /// merge; a 2026-07 fuzz run burned 95% CPU in CFPreferences).
    /// Call with the full set of live mode IDs (launch) or `[]` (test reset).
    static func pruneOrphanedMicSelections(activeModeIDs: Set<UUID>) {
        let defaults = AppLaunchOverrides.runtimeDefaults
        let activeKeys = Set(activeModeIDs.map { "mode_\($0)_selectedMic" })
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("mode_") && key.hasSuffix("_selectedMic")
            && !activeKeys.contains(key) {
            defaults.removeObject(forKey: key)
        }
    }
}
#endif
