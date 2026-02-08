//
//  ConversationHandler.swift
//  Axii
//
//  Encapsulates conversation-specific logic: LLM interaction,
//  multi-turn message management, and history persistence.
//  Used by ModeFeature for conversation-type modes.
//

#if os(macOS)
import Foundation
import os.log

private let logger = Logger(subsystem: "com.axii", category: "ConversationHandler")

@MainActor
final class ConversationHandler {

    // MARK: - Dependencies

    private let llmService: LLMService
    private let playbackService: AudioPlaybackService
    private let historyService: HistoryService
    private let state: ModeRuntimeState

    // MARK: - Init

    init(
        state: ModeRuntimeState,
        llmService: LLMService,
        playbackService: AudioPlaybackService,
        historyService: HistoryService
    ) {
        self.state = state
        self.llmService = llmService
        self.playbackService = playbackService
        self.historyService = historyService
    }

    // MARK: - Public API

    /// Process transcribed text through LLM and update conversation state.
    /// Returns the LLM response text.
    func processTranscription(
        _ text: String,
        config: LLMTransformConfig
    ) async throws -> String {
        // 1. Add user message to display state
        state.messages.append(
            DisplayMessage(role: .user, content: text)
        )

        // 2. Determine whether we are continuing an existing session
        let isExistingSession = state.currentSessionId != nil

        // 3. Save user message to history (create or update conversation)
        let conversationId = try await saveUserMessage(text)
        state.currentSessionId = conversationId

        // 4. Get LLM response using the appropriate call style
        let response: String

        if config.multiTurn,
           isExistingSession,
           let conversationId,
           let historyMessages = await loadConversationMessages(
               conversationId: conversationId
           ),
           historyMessages.count > 1 {
            // Multi-turn with prior context: send full message history
            response = try await llmService.send(messages: historyMessages)
        } else {
            // First turn or single-turn: send just the user text
            response = try await llmService.send(message: text)
        }

        // 5. Add assistant message to display state
        state.messages.append(
            DisplayMessage(role: .assistant, content: response)
        )

        // 6. Persist assistant message to history
        if let conversationId {
            await updateWithAssistantMessage(
                conversationId: conversationId,
                content: response
            )
        }

        return response
    }

    /// Stop any active playback.
    func interruptPlayback() {
        playbackService.stop()
    }

    /// Clear conversation session (messages, session ID, live text).
    func clearSession() {
        state.messages.removeAll()
        state.currentSessionId = nil
        state.liveTranscript = ""
        state.finalText = ""
    }

    // MARK: - History Helpers

    /// Save the user message to an existing or new conversation.
    /// Returns the conversation UUID on success, nil if history is disabled or save fails.
    private func saveUserMessage(_ text: String) async throws -> UUID? {
        guard historyService.isEnabled else {
            return state.currentSessionId
        }

        if let existingId = state.currentSessionId {
            return try await appendUserMessage(
                text,
                toConversation: existingId
            )
        }

        return try await createNewConversation(with: text)
    }

    /// Append a user message to an existing conversation on disk.
    private func appendUserMessage(
        _ text: String,
        toConversation id: UUID
    ) async throws -> UUID {
        let interaction = try await historyService.loadInteraction(id: id)

        guard case .conversation(var conversation) = interaction else {
            // Existing interaction is not a conversation; create a new one
            if let newId = try await createNewConversation(with: text) {
                return newId
            }
            return id
        }

        conversation.addMessage(Message(role: .user, content: text))
        try await historyService.save(.conversation(conversation))
        return id
    }

    /// Create a brand-new conversation containing the first user message.
    private func createNewConversation(
        with text: String
    ) async throws -> UUID? {
        let conversation = Conversation(
            messages: [Message(role: .user, content: text)]
        )
        try await historyService.save(.conversation(conversation))
        return conversation.id
    }

    /// Append the assistant response to the persisted conversation.
    private func updateWithAssistantMessage(
        conversationId: UUID,
        content: String
    ) async {
        guard historyService.isEnabled else { return }

        do {
            let interaction = try await historyService.loadInteraction(
                id: conversationId
            )
            guard case .conversation(var conversation) = interaction else {
                return
            }
            conversation.addMessage(
                Message(role: .assistant, content: content)
            )
            try await historyService.save(.conversation(conversation))
        } catch {
            logger.error("Failed to update assistant message: \(error.localizedDescription)")
        }
    }

    /// Load all messages from a persisted conversation.
    private func loadConversationMessages(
        conversationId: UUID
    ) async -> [Message]? {
        do {
            let interaction = try await historyService.loadInteraction(
                id: conversationId
            )
            guard case .conversation(let conversation) = interaction else {
                return nil
            }
            return conversation.messages
        } catch {
            logger.error("Failed to load messages: \(error.localizedDescription)")
            return nil
        }
    }
}
#endif
