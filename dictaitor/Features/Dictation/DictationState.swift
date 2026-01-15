//
//  DictationState.swift
//  dictaitor
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

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }
}
