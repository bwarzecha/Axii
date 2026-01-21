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

        // On macOS, AVCaptureDevice.requestAccess(for: .audio) doesn't reliably
        // trigger the permission dialog. We need to actually create a capture
        // session to force TCC to prompt and register the app in System Settings.
        let granted = await triggerMicrophonePermission()
        refresh()
        return granted
    }

    /// Trigger the microphone permission dialog by creating a capture session.
    /// This is required on macOS because requestAccess alone doesn't always work.
    private nonisolated func triggerMicrophonePermission() async -> Bool {
        #if os(macOS)
        // On macOS, we need to actually create a capture session to reliably
        // trigger the TCC dialog and register the app in System Settings.
        // The requestAccess API alone doesn't always work for non-sandboxed apps.

        guard let device = AVCaptureDevice.default(for: .audio) else {
            return false
        }

        // Creating AVCaptureDeviceInput will trigger the permission dialog
        // if permission is .notDetermined
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            // This typically means permission was denied
            return false
        }

        // Create and briefly run a capture session to ensure TCC registration
        let session = AVCaptureSession()
        session.beginConfiguration()

        if session.canAddInput(input) {
            session.addInput(input)
        }
        session.commitConfiguration()

        // Start on background to avoid blocking main thread
        session.startRunning()

        // Stop immediately - we just needed to trigger TCC registration
        session.stopRunning()

        return true
        #else
        return await AVCaptureDevice.requestAccess(for: .audio)
        #endif
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
