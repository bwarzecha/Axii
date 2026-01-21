//
//  BedrockClient.swift
//  Axii
//
//  AWS Bedrock client using the Converse API.
//

#if os(macOS)
import AWSBedrock
import AWSBedrockRuntime
import AWSSDKIdentity
import Foundation
import SmithyIdentity

/// Available Bedrock model info.
struct BedrockModel: Identifiable, Hashable {
    let id: String
    let name: String
    let provider: String
    let inputModalities: [String]
    let outputModalities: [String]

    /// Whether model supports text input/output (suitable for chat).
    var isTextModel: Bool {
        inputModalities.contains("TEXT") && outputModalities.contains("TEXT")
    }
}

/// Client for AWS Bedrock LLM calls.
/// Note: Using class instead of actor to avoid potential async deadlocks with AWS SDK.
final class BedrockClient: @unchecked Sendable {
    private var runtimeClient: BedrockRuntimeClient?
    private var managementClient: AWSBedrock.BedrockClient?
    private var currentConfig: AWSBedrockConfig?
    private let lock = NSLock()

    /// Default model ID for Claude on Bedrock.
    static let defaultModelId = "us.anthropic.claude-3-7-sonnet-20250219-v1:0"

    /// Test authentication by listing models. Returns true if successful.
    func testConnection(config: AWSBedrockConfig) async throws -> Bool {
        let client = try await getOrCreateManagementClient(config: config)
        let input = ListFoundationModelsInput(
            byInferenceType: .onDemand,
            byOutputModality: .text
        )
        _ = try await client.listFoundationModels(input: input)
        return true
    }

    /// List available foundation models that support text.
    func listModels(config: AWSBedrockConfig) async throws -> [BedrockModel] {
        let client = try await getOrCreateManagementClient(config: config)

        let input = ListFoundationModelsInput(
            byInferenceType: .onDemand,
            byOutputModality: .text
        )

        let response = try await client.listFoundationModels(input: input)

        guard let summaries = response.modelSummaries else {
            return []
        }

        return summaries.compactMap { summary -> BedrockModel? in
            guard let modelId = summary.modelId,
                  let name = summary.modelName,
                  let provider = summary.providerName else {
                return nil
            }

            return BedrockModel(
                id: modelId,
                name: name,
                provider: provider,
                inputModalities: summary.inputModalities?.map { $0.rawValue } ?? [],
                outputModalities: summary.outputModalities?.map { $0.rawValue } ?? []
            )
        }
        .filter { $0.isTextModel }
        .sorted { $0.provider < $1.provider || ($0.provider == $1.provider && $0.name < $1.name) }
    }

    /// Send a message and get a response using Converse API.
    func send(
        message: String,
        config: AWSBedrockConfig,
        modelId: String = defaultModelId,
        systemPrompt: String? = nil
    ) async throws -> String {
        let client = try await getOrCreateRuntimeClient(config: config)

        // Build user message
        let userMessage = BedrockRuntimeClientTypes.Message(
            content: [.text(message)],
            role: .user
        )

        // Build system prompt if provided
        var systemPrompts: [BedrockRuntimeClientTypes.SystemContentBlock]?
        if let systemPrompt {
            systemPrompts = [.text(systemPrompt)]
        }

        // Create and send request
        let input = ConverseInput(
            messages: [userMessage],
            modelId: modelId,
            system: systemPrompts
        )
        let response = try await client.converse(input: input)

        return try extractResponseText(from: response)
    }

    /// Send a conversation (multiple messages) and get a response using Converse API.
    func sendConversation(
        messages: [Message],
        config: AWSBedrockConfig,
        modelId: String = defaultModelId,
        systemPrompt: String? = nil
    ) async throws -> String {
        let client = try await getOrCreateRuntimeClient(config: config)

        // Convert Message array to Bedrock format
        let bedrockMessages = messages.compactMap { message -> BedrockRuntimeClientTypes.Message? in
            // Skip system and tool messages for now
            guard message.role == .user || message.role == .assistant else { return nil }

            let role: BedrockRuntimeClientTypes.ConversationRole = message.role == .user ? .user : .assistant
            return BedrockRuntimeClientTypes.Message(
                content: [.text(message.content)],
                role: role
            )
        }

        guard !bedrockMessages.isEmpty else {
            throw BedrockError.emptyConversation
        }

        // Build system prompt if provided
        var systemPrompts: [BedrockRuntimeClientTypes.SystemContentBlock]?
        if let systemPrompt {
            systemPrompts = [.text(systemPrompt)]
        }

        let input = ConverseInput(
            messages: bedrockMessages,
            modelId: modelId,
            system: systemPrompts
        )
        let response = try await client.converse(input: input)

        return try extractResponseText(from: response)
    }

    /// Extract text content from Converse API response.
    private func extractResponseText(from response: ConverseOutput) throws -> String {
        guard let output = response.output,
              case .message(let responseMessage) = output,
              let content = responseMessage.content else {
            throw BedrockError.emptyResponse
        }

        // Collect text blocks
        let responseText = content.compactMap { block -> String? in
            if case .text(let text) = block { return text }
            return nil
        }.joined()

        if responseText.isEmpty {
            throw BedrockError.emptyResponse
        }

        return responseText
    }

    // MARK: - Private

    private func getOrCreateRuntimeClient(config: AWSBedrockConfig) async throws -> BedrockRuntimeClient {
        lock.lock()
        if let runtimeClient, currentConfig == config {
            lock.unlock()
            return runtimeClient
        }
        lock.unlock()
        try await createClients(config: config)
        lock.lock()
        let client = runtimeClient!
        lock.unlock()
        return client
    }

    private func getOrCreateManagementClient(config: AWSBedrockConfig) async throws -> AWSBedrock.BedrockClient {
        lock.lock()
        if let managementClient, currentConfig == config {
            lock.unlock()
            return managementClient
        }
        lock.unlock()
        try await createClients(config: config)
        lock.lock()
        let client = managementClient!
        lock.unlock()
        return client
    }

    private func createClients(config: AWSBedrockConfig) async throws {
        // Disable IMDS to prevent timeout (not running on EC2)
        setenv("AWS_EC2_METADATA_DISABLED", "true", 1)

        // Use default credential chain - reads from ~/.aws/credentials
        let runtimeConfig = try await BedrockRuntimeClient.BedrockRuntimeClientConfiguration(
            region: config.region
        )
        let newRuntimeClient = BedrockRuntimeClient(config: runtimeConfig)

        let managementConfig = try await AWSBedrock.BedrockClient.BedrockClientConfiguration(
            region: config.region
        )
        let newManagementClient = AWSBedrock.BedrockClient(config: managementConfig)

        lock.lock()
        self.runtimeClient = newRuntimeClient
        self.managementClient = newManagementClient
        self.currentConfig = config
        lock.unlock()
    }
}

enum BedrockError: LocalizedError {
    case emptyResponse
    case emptyConversation
    case invalidCredentials
    case modelNotAvailable(String)

    var errorDescription: String? {
        switch self {
        case .emptyResponse:
            return "Bedrock returned empty response"
        case .emptyConversation:
            return "No messages to send"
        case .invalidCredentials:
            return "AWS credentials invalid or expired"
        case .modelNotAvailable(let modelId):
            return "Model \(modelId) not available in this region"
        }
    }
}
#endif
