//
//  ConversationState.swift
//  Axii
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

/// A display message for the conversation UI (simpler than history Message)
struct DisplayMessage: Identifiable, Equatable {
    let id: UUID
    let role: MessageRole
    let content: String

    init(id: UUID = UUID(), role: MessageRole, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }

    /// Create from history Message
    init(from message: Message) {
        self.id = message.id
        self.role = message.role
        self.content = message.content
    }
}

/// Observable state for conversation feature.
@MainActor @Observable
final class ConversationState {
    var phase: ConversationPhase = .idle
    var audioLevel: Float = 0
    var spectrum: [Float] = []
    var transcript: String = ""     // Current turn: user's speech
    var response: String = ""       // Current turn: agent's response
    var messages: [DisplayMessage] = []  // Full conversation history for UI

    /// True when waiting for Bluetooth device to produce signal.
    var isWaitingForSignal: Bool = false

    var isListening: Bool {
        if case .listening = phase { return true }
        return false
    }

    /// Add a user message to the display
    func addUserMessage(_ content: String) {
        messages.append(DisplayMessage(role: .user, content: content))
    }

    /// Add an assistant message to the display
    func addAssistantMessage(_ content: String) {
        messages.append(DisplayMessage(role: .assistant, content: content))
    }

    /// Load messages from a conversation (for continuing a multi-turn session)
    func loadMessages(from historyMessages: [Message]) {
        messages = historyMessages.map { DisplayMessage(from: $0) }
    }

    /// Clear all messages (for starting fresh)
    func clearMessages() {
        messages.removeAll()
    }
}
