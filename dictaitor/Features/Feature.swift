//
//  Feature.swift
//  dictaitor
//
//  Protocol defining a self-contained feature that owns its hotkeys, state, and UI.
//

#if os(macOS)
import SwiftUI

/// Context provided to features for registration and signaling.
@MainActor
final class FeatureContext {
    let hotkeyService: HotkeyService

    /// Call when feature becomes active (shows UI, takes over)
    var onActivate: ((any Feature) -> Void)?

    /// Call when feature is done (hides UI, releases control)
    var onDeactivate: (() -> Void)?

    init(hotkeyService: HotkeyService) {
        self.hotkeyService = hotkeyService
    }
}

/// Protocol for self-contained features.
/// Each feature owns its hotkeys, state machine, and UI.
@MainActor
protocol Feature: AnyObject {
    /// Whether this feature is currently active (has control)
    var isActive: Bool { get }

    /// The SwiftUI view to display in the panel when active
    var panelContent: AnyView { get }

    /// Register hotkeys and set up the feature
    func register(with context: FeatureContext)

    /// Handle escape key - typically cancels and deactivates
    func handleEscape()

    /// Force cancel - called when another feature needs to take over
    func cancel()
}
#endif
