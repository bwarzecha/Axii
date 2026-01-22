//
//  AdvancedHotkeyService.swift
//  Axii
//
//  CGEventTap-based hotkey service with Fn key support.
//  Requires Accessibility permission for event consumption.
//
//  Threading: The CGEventTap callback runs on a background thread.
//  Properties accessed from the callback are marked nonisolated(unsafe).
//  This is safe because registration only happens on main thread during setup,
//  and the race window with mode switching is negligible in practice.
//

#if os(macOS)
import AppKit
import CoreGraphics
import Carbon.HIToolbox

/// CGEventTap-based hotkey service that supports the Fn key modifier.
/// This is an alternative to HotkeyService for users who need Fn key support.
@MainActor
final class AdvancedHotkeyService {

    // MARK: - Types

    private struct RegisteredHotkey {
        let keyCode: UInt32
        let modifiers: CGEventFlags
        let usesFn: Bool
        let handler: () -> Void
    }

    // MARK: - Properties
    // Note: These are accessed from the event tap callback (background thread)

    nonisolated(unsafe) private var registeredHotkeys: [HotkeyID: RegisteredHotkey] = [:]
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    nonisolated(unsafe) private var isPaused = false

    /// Shared instance pointer for C callback access
    nonisolated(unsafe) private static weak var sharedInstance: AdvancedHotkeyService?

    private let permission: InputMonitoringPermissionService

    // MARK: - Initialization

    init(permission: InputMonitoringPermissionService) {
        self.permission = permission
    }

    // MARK: - Public API

    /// Starts the event tap. Returns false if permission not granted or tap creation fails.
    func start() -> Bool {
        guard permission.isGranted else {
            return false
        }

        guard eventTap == nil else {
            return true
        }

        AdvancedHotkeyService.sharedInstance = self

        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

        // Use .defaultTap to be able to consume (block) matched hotkey events
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, _ -> Unmanaged<CGEvent>? in
                let matched = AdvancedHotkeyService.handleEvent(type: type, event: event)
                // Return nil to consume the event (block it), or return the event to let it through
                if matched {
                    return nil
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        )

        guard let eventTap else {
            print("AdvancedHotkeyService: Failed to create event tap - restart the app after granting Input Monitoring permission")
            AdvancedHotkeyService.sharedInstance = nil
            return false
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)

        guard let runLoopSource else {
            self.eventTap = nil
            return false
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        return true
    }

    /// Stops the event tap.
    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }

        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }

        eventTap = nil
        runLoopSource = nil

        if AdvancedHotkeyService.sharedInstance === self {
            AdvancedHotkeyService.sharedInstance = nil
        }
    }

    /// Whether the event tap is currently active.
    var isActive: Bool {
        eventTap != nil
    }

    /// Temporarily pauses all hotkey handlers.
    func pause() {
        isPaused = true
    }

    /// Resumes hotkey handlers after pausing.
    func resume() {
        isPaused = false
    }

    /// Registers a global hotkey with the given configuration.
    func register(
        _ id: HotkeyID,
        config: HotkeyConfig,
        handler: @escaping () -> Void
    ) {
        unregister(id)

        let modifiers = Self.nsModifiersToCGEventFlags(config.nsModifiers)

        registeredHotkeys[id] = RegisteredHotkey(
            keyCode: config.keyCode,
            modifiers: modifiers,
            usesFn: config.usesFnKey,
            handler: handler
        )
    }

    /// Unregisters a hotkey by its identifier.
    func unregister(_ id: HotkeyID) {
        registeredHotkeys[id] = nil
    }

    /// Checks if a hotkey is currently registered.
    func isRegistered(_ id: HotkeyID) -> Bool {
        registeredHotkeys[id] != nil
    }

    /// Unregisters all hotkeys.
    func unregisterAll() {
        registeredHotkeys.removeAll()
    }

    /// Returns all currently registered hotkey IDs.
    var registeredHotkeyIDs: [HotkeyID] {
        Array(registeredHotkeys.keys)
    }

    // MARK: - Event Handling

    /// Returns true if a hotkey was matched (event should be consumed)
    private static func handleEvent(type: CGEventType, event: CGEvent) -> Bool {
        guard let instance = sharedInstance else {
            return false
        }

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // System disabled the tap, re-enable it
            if let tap = instance.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return false
        }

        guard type == .keyDown else { return false }
        guard !instance.isPaused else { return false }

        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        // Check each registered hotkey
        for (id, hotkey) in instance.registeredHotkeys {
            if instance.matchesHotkey(hotkey, keyCode: keyCode, flags: flags) {
                print("AdvancedHotkeyService: Matched hotkey \(id)")
                // Dispatch to main thread to ensure UI safety
                Task { @MainActor in
                    hotkey.handler()
                }
                return true  // Consume the event
            }
        }
        return false  // Let the event through
    }

    private func matchesHotkey(_ hotkey: RegisteredHotkey, keyCode: UInt32, flags: CGEventFlags) -> Bool {
        // Check key code
        guard hotkey.keyCode == keyCode else { return false }

        // Check Fn key requirement
        let fnPressed = flags.contains(.maskSecondaryFn)
        if hotkey.usesFn && !fnPressed {
            return false
        }

        // Check standard modifiers (mask out Fn and other non-standard flags)
        let standardMask: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate]
        let eventStandardMods = flags.intersection(standardMask)
        let hotkeyStandardMods = hotkey.modifiers.intersection(standardMask)

        return eventStandardMods == hotkeyStandardMods
    }

    // MARK: - Helpers

    private static func nsModifiersToCGEventFlags(_ flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var cgFlags: CGEventFlags = []
        if flags.contains(.command) { cgFlags.insert(.maskCommand) }
        if flags.contains(.shift) { cgFlags.insert(.maskShift) }
        if flags.contains(.control) { cgFlags.insert(.maskControl) }
        if flags.contains(.option) { cgFlags.insert(.maskAlternate) }
        return cgFlags
    }
}
#endif
