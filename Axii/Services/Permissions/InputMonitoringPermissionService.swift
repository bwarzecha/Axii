//
//  InputMonitoringPermissionService.swift
//  Axii
//
//  Centralized input monitoring permission management.
//  Required for CGEventTap-based hotkey detection (Advanced mode).
//

#if os(macOS)
import AppKit
import CoreGraphics

@MainActor
@Observable
final class InputMonitoringPermissionService {
    private(set) var isGranted: Bool
    private var pollTimer: Timer?
    private let pollInterval: TimeInterval = 1.0

    /// Called when permission transitions from denied to granted.
    var onPermissionGranted: (() -> Void)?

    init() {
        isGranted = CGPreflightListenEventAccess()
        startPollingIfNeeded()
    }

    func refresh() {
        let newValue = CGPreflightListenEventAccess()
        guard newValue != isGranted else { return }
        let wasGranted = isGranted
        isGranted = newValue
        if newValue {
            stopPolling()
            // Notify when permission is newly granted
            if !wasGranted {
                onPermissionGranted?()
            }
        }
    }

    func requestAccess() {
        let result = CGRequestListenEventAccess()
        print("InputMonitoringPermission: CGRequestListenEventAccess returned \(result)")
        openSystemSettings()
        startPollingIfNeeded()
    }

    func openSystemSettings() {
        // Try macOS Ventura+ URL first, fall back to older URL
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent",
            "x-apple.systempreferences:com.apple.preference.security?Privacy"
        ]

        for urlString in urls {
            if let url = URL(string: urlString) {
                let success = NSWorkspace.shared.open(url)
                if success {
                    print("InputMonitoringPermission: Opened \(urlString)")
                    return
                }
            }
        }
        print("InputMonitoringPermission: Failed to open System Settings")
    }

    func stopPollingOnDeinit() {
        stopPolling()
    }

    private func startPollingIfNeeded() {
        guard pollTimer == nil, !isGranted else { return }
        let interval = pollInterval
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
#endif
