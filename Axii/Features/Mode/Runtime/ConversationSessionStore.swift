//
//  ConversationSessionStore.swift
//  Axii
//
//  Narrow persistence collaborator for multi-turn mode execution.
//  Owns persisted conversation session lifecycle: creating sessions,
//  appending user messages, loading message context, and persisting
//  assistant replies.
//
//  Does NOT own: ModeRuntimeState mutation, display message projection,
//  LLM request policy, or cancel/deactivate cleanup.
//

#if os(macOS)
import Foundation
import os.log

private let logger = Logger(subsystem: "com.axii", category: "ConversationSessionStore")

@MainActor
final class ConversationSessionStore: ConversationSessionStoring {

    private let historyService: HistoryService

    init(historyService: HistoryService) {
        self.historyService = historyService
    }

    // MARK: - ConversationSessionStoring

    func beginTurn(
        userText: String,
        currentSessionId: UUID?
    ) async throws -> PreparedConversationTurn {
        guard historyService.isEnabled else {
            // History disabled: no session, no persisted messages.
            // LLM calls will use send(message:) — stateless from LLM perspective.
            return PreparedConversationTurn(sessionId: nil, persistedMessages: nil)
        }

        if let existingId = currentSessionId {
            return try await appendUserAndLoadMessages(
                userText: userText,
                sessionId: existingId
            )
        }

        return try await createNewSession(userText: userText)
    }

    func appendAssistantReply(
        sessionId: UUID,
        text: String
    ) async {
        guard historyService.isEnabled else { return }

        do {
            let interaction = try await historyService.loadInteraction(id: sessionId)
            guard case .conversation(var conversation) = interaction else { return }
            conversation.addMessage(Message(role: .assistant, content: text))
            try await historyService.save(.conversation(conversation))
        } catch {
            logger.error("Failed to persist assistant reply: \(error.localizedDescription)")
        }
    }

    // MARK: - Private Helpers

    private func createNewSession(
        userText: String
    ) async throws -> PreparedConversationTurn {
        let conversation = Conversation(
            messages: [Message(role: .user, content: userText)]
        )
        try await historyService.save(.conversation(conversation))
        // First turn: no prior messages to send to LLM
        return PreparedConversationTurn(
            sessionId: conversation.id,
            persistedMessages: nil
        )
    }

    private func appendUserAndLoadMessages(
        userText: String,
        sessionId: UUID
    ) async throws -> PreparedConversationTurn {
        let interaction = try await historyService.loadInteraction(id: sessionId)

        guard case .conversation(var conversation) = interaction else {
            // Existing interaction is not a conversation; fall back to new session
            logger.warning("Session \(sessionId) is not a conversation, creating new session")
            return try await createNewSession(userText: userText)
        }

        conversation.addMessage(Message(role: .user, content: userText))
        try await historyService.save(.conversation(conversation))

        return PreparedConversationTurn(
            sessionId: sessionId,
            persistedMessages: conversation.messages
        )
    }
}

#endif
