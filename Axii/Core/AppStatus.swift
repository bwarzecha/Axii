//
//  AppStatus.swift
//  Axii
//
//  Lightweight app-level status derived from the active mode runtime.
//  Used by the menu bar to show current state without depending on
//  legacy feature types.
//

#if os(macOS)
import SwiftUI

/// App-level status for the menu bar, derived from the active mode runtime.
enum AppStatus: Equatable {
    case ready
    case recording
    case processing
    case error
}

extension AppStatus {

    /// Maps a ModePhase to a simplified app-level status.
    static func from(_ phase: ModePhase) -> AppStatus {
        switch phase {
        case .idle, .done:
            return .ready
        case .recording:
            return .recording
        case .preparing, .transcribing, .processing:
            return .processing
        case .error:
            return .error
        }
    }

    /// Display text for the menu bar.
    var menuBarText: String {
        switch self {
        case .ready: return "Ready"
        case .recording: return "Recording..."
        case .processing: return "Processing..."
        case .error: return "Error"
        }
    }
}

/// Observable status source for the menu bar.
///
/// Holds a reference to the active mode's `ModeRuntimeState`. The `appStatus`
/// computed property reads `activeState.phase`, which is `@Observable`. This
/// means SwiftUI views that read `appStatus` establish a real observation
/// dependency on the underlying `ModeRuntimeState.phase` — no polling, no
/// duplicate store, no manual synchronization needed.
///
/// `FeatureManager` updates `activeState` when modes activate/deactivate.
@MainActor @Observable
final class AppStatusSource {
    /// The runtime state of the currently active mode, or nil if no mode is active.
    /// Set by FeatureManager on activate/deactivate.
    var activeState: ModeRuntimeState?

    /// Current app status. Reading this in a SwiftUI view body creates an
    /// observation dependency on both `activeState` (for activation changes)
    /// and `activeState.phase` (for phase transitions within the active mode).
    var appStatus: AppStatus {
        guard let state = activeState else { return .ready }
        return AppStatus.from(state.phase)
    }
}

#endif
