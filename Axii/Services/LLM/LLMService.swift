//
//  LLMService.swift
//  Axii
//
//  Unified LLM service that routes to configured provider.
//

#if os(macOS)
import Foundation

/// Service for LLM interactions. Routes to configured provider.
@MainActor
final class LLMService {
    private let settings: LLMSettingsService
    private let bedrockClient = BedrockClient()

    /// System prompt for the voice agent.
    var systemPrompt: String = """
        You are a helpful voice assistant. Keep responses concise and conversational, \
        suitable for text-to-speech. Avoid markdown formatting, bullet points, or long lists. \
        Respond naturally as if speaking.
        """

    init(settings: LLMSettingsService) {
        self.settings = settings
    }

    /// Test connection to the configured LLM provider.
    func testConnection() async throws -> Bool {
        switch settings.selectedProvider {
        case .awsBedrock:
            return try await bedrockClient.testConnection(config: settings.awsBedrockConfig)
        case .openAI, .anthropic:
            throw LLMServiceError.providerNotImplemented(settings.selectedProvider)
        }
    }

    /// Send a message and get a response from the configured LLM.
    func send(message: String) async throws -> String {
        switch settings.selectedProvider {
        case .awsBedrock:
            return try await bedrockClient.send(
                message: message,
                config: settings.awsBedrockConfig,
                systemPrompt: systemPrompt
            )
        case .openAI:
            throw LLMServiceError.providerNotImplemented(.openAI)
        case .anthropic:
            throw LLMServiceError.providerNotImplemented(.anthropic)
        }
    }

    /// Send a conversation (multiple messages) and get a response from the configured LLM.
    func send(messages: [Message]) async throws -> String {
        switch settings.selectedProvider {
        case .awsBedrock:
            return try await bedrockClient.sendConversation(
                messages: messages,
                config: settings.awsBedrockConfig,
                systemPrompt: systemPrompt
            )
        case .openAI:
            throw LLMServiceError.providerNotImplemented(.openAI)
        case .anthropic:
            throw LLMServiceError.providerNotImplemented(.anthropic)
        }
    }
}

enum LLMServiceError: LocalizedError {
    case providerNotImplemented(LLMProvider)
    case notConfigured(LLMProvider)

    var errorDescription: String? {
        switch self {
        case .providerNotImplemented(let provider):
            return "\(provider.displayName) not yet implemented"
        case .notConfigured(let provider):
            return "\(provider.displayName) requires configuration"
        }
    }
}
#endif
