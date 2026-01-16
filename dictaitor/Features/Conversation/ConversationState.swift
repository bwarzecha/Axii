//
//  ConversationState.swift
//  dictaitor
//
//  Observable state for the conversation/agent feature.
//

import SwiftUI

/// Conversation workflow phases.
enum ConversationPhase: Equatable {
    case idle
    case listening      // Recording user speech
    case processing     // Transcribing + LLM thinking
    case responding     // TTS playing agent response
    case done
    case error(message: String)
}

/// Observable state for conversation feature.
@MainActor @Observable
final class ConversationState {
    var phase: ConversationPhase = .idle
    var audioLevel: Float = 0
    var spectrum: [Float] = []
    var transcript: String = ""     // User's speech (accumulated)
    var response: String = ""       // Agent's response

    var isListening: Bool {
        if case .listening = phase { return true }
        return false
    }
}
