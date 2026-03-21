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
/// Exposes a single `appStatus` property that is `@Observable`. FeatureManager
/// calls `update(phase:)` whenever the active mode's phase changes, and
/// `deactivate()` when no mode is active. SwiftUI views that read `appStatus`
/// get a real observation dependency — no polling, no duplicate store needed.
@MainActor @Observable
final class AppStatusSource {
    /// The current app status. Updated by FeatureManager.
    private(set) var appStatus: AppStatus = .ready

    /// Update status from the active mode's current phase.
    func update(phase: ModePhase) {
        appStatus = AppStatus.from(phase)
    }

    /// Reset to ready when no mode is active.
    func deactivate() {
        appStatus = .ready
    }
}

#endif
