//
//  ScreenRecordingPermissionService.swift
//  Axii
//
//  Permission handling for Screen Recording (required for app audio capture via ScreenCaptureKit).
//

#if os(macOS)
import AppKit

/// Service for managing Screen Recording permission.
/// Required for capturing app audio via ScreenCaptureKit.
@MainActor
final class ScreenRecordingPermissionService {

    /// Current permission state.
    enum State {
        case granted
        case denied
        case notDetermined
    }

    /// Check current permission state.
    var state: State {
        if CGPreflightScreenCaptureAccess() {
            return .granted
        }
        // CGPreflightScreenCaptureAccess returns false for both denied and not determined
        // We can't distinguish without triggering the prompt
        return .notDetermined
    }

    /// Whether screen recording is currently allowed.
    var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Request screen recording permission.
    /// This will trigger the system prompt if not yet determined.
    func request() {
        CGRequestScreenCaptureAccess()
    }

    /// Open System Settings to the Screen Recording privacy pane.
    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
#endif
