//
//  MicrophonePermissionService.swift
//  dictaitor
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

    init() {
        state = Self.resolveState()
    }

    func refresh() {
        state = Self.resolveState()
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
        #elseif os(iOS)
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            return
        }
        UIApplication.shared.open(url)
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
