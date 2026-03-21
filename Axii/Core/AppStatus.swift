//
//  AppStatus.swift
//  Axii
//
//  Lightweight app-level status derived from the active mode runtime.
//  Used by the menu bar to show current state without depending on
//  legacy feature types.
//

#if os(macOS)

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

#endif
