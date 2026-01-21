//
//  DictationState.swift
//  Axii
//
//  Observable state for the dictation feature.
//

import SwiftUI

/// Dictation workflow phases.
enum DictationPhase: Equatable {
    case idle
    case loadingModel
    case recording
    case transcribing
    case done(text: String)
    case error(message: String)
}

/// Observable state for dictation feature.
@MainActor @Observable
final class DictationState {
    var phase: DictationPhase = .idle
    var audioLevel: Float = 0
    var spectrum: [Float] = []

    /// True when waiting for Bluetooth device to produce signal.
    /// Used to show "Waiting for signal..." feedback during Bluetooth warm-up.
    var isWaitingForSignal: Bool = false

    #if os(macOS)
    /// Available microphones (updated when devices connect/disconnect).
    var availableMicrophones: [AudioDevice] = []

    /// Currently selected microphone (nil = system default).
    var selectedMicrophone: AudioDevice?
    #endif

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }
}
