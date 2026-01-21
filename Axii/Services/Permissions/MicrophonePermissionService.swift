//
//  MicrophonePermissionService.swift
//  Axii
//
//  Centralized microphone permission management.
//

import AVFoundation

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

@MainActor
@Observable
final class MicrophonePermissionService {
    enum State: Equatable {
        case authorized
        case denied
        case restricted
        case notDetermined

        var isAuthorized: Bool { self == .authorized }
        var needsPrompt: Bool { self == .notDetermined }
        var isBlocked: Bool { self == .denied || self == .restricted }
    }

    private(set) var state: State
    private var pollTimer: Timer?
    private let pollInterval: TimeInterval = 1.0

    init() {
        state = Self.resolveState()
        startPollingIfNeeded()
    }

    func refresh() {
        let newState = Self.resolveState()
        guard newState != state else { return }
        state = newState
        if newState.isAuthorized {
            stopPolling()
        }
    }

    func stopPollingOnDeinit() {
        stopPolling()
    }

    private func startPollingIfNeeded() {
        guard pollTimer == nil, !state.isAuthorized else { return }
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

    func requestAccess() async -> Bool {
        guard state.needsPrompt else { return state.isAuthorized }
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        refresh()
        return granted
    }

    func openSystemSettings() {
        #if os(macOS)
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else {
            return
        }
        NSWorkspace.shared.open(url)
        startPollingIfNeeded()
        #elseif os(iOS)
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            return
        }
        UIApplication.shared.open(url)
        startPollingIfNeeded()
        #endif
    }

    private static func resolveState() -> State {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .restricted
        }
    }
}
