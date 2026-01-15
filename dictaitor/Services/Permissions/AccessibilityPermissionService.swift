//
//  AccessibilityPermissionService.swift
//  dictaitor
//
//  Centralized accessibility permission management.
//  Polls for trust status since macOS doesn't provide a notification API.
//

#if os(macOS)
import ApplicationServices
import AppKit

@MainActor
@Observable
final class AccessibilityPermissionService {
    private(set) var isTrusted: Bool
    private var pollTimer: Timer?
    private let pollInterval: TimeInterval = 1.0

    init() {
        isTrusted = Self.checkTrust(prompt: false)
        startPollingIfNeeded()
    }

    func refresh() {
        let newValue = Self.checkTrust(prompt: false)
        guard newValue != isTrusted else { return }
        isTrusted = newValue
        if newValue {
            stopPolling()
        }
    }

    func requestAccess() {
        _ = Self.checkTrust(prompt: true)
        openSystemSettings()
        startPollingIfNeeded()
    }

    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func stopPollingOnDeinit() {
        stopPolling()
    }

    private func startPollingIfNeeded() {
        guard pollTimer == nil, !isTrusted else { return }
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

    private nonisolated static func checkTrust(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
#endif
