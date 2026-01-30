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
    let isInferenceProfile: Bool
    let scope: String?  // global, us, eu, apac, regional
    let baseModelId: String?  // For inference profiles

    /// Whether model supports text input/output (suitable for chat).
    var isTextModel: Bool {
        inputModalities.contains("TEXT") && outputModalities.contains("TEXT")
    }

    /// Display priority (lower is better): global > us > regional.
    var displayPriority: Int {
        guard isInferenceProfile else { return 100 }
        switch scope {
        case "global": return 0
        case "us": return 1
        case "eu": return 2
        case "apac": return 3
        default: return 10
        }
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

    /// List available models including inference profiles.
    /// Prioritizes cross-region inference profiles (global, US) over foundation models.
    func listModels(config: AWSBedrockConfig) async throws -> [BedrockModel] {
        let client = try await getOrCreateManagementClient(config: config)

        // Fetch inference profiles (preferred for cross-region routing)
        var inferenceProfiles: [BedrockModel] = []
        var nextToken: String?

        repeat {
            let profileInput = ListInferenceProfilesInput(
                maxResults: 100,
                nextToken: nextToken
            )
            let profileResponse = try await client.listInferenceProfiles(input: profileInput)

            if let profiles = profileResponse.inferenceProfileSummaries {
                for profile in profiles {
                    guard let profileId = profile.inferenceProfileId,
                          let profileName = profile.inferenceProfileName,
                          let status = profile.status,
                          status == .active else {
                        continue
                    }

                    // Only include Claude models
                    guard profileId.contains("claude") || profileId.contains("anthropic") else {
                        continue
                    }

                    let scope = inferProfileScope(from: profileId)
                    let baseModel = extractBaseModelId(from: profile.models ?? [])

                    inferenceProfiles.append(BedrockModel(
                        id: profileId,
                        name: profileName,
                        provider: "Anthropic",
                        inputModalities: ["TEXT", "IMAGE"],
                        outputModalities: ["TEXT"],
                        isInferenceProfile: true,
                        scope: scope,
                        baseModelId: baseModel
                    ))
                }
            }

            nextToken = profileResponse.nextToken
        } while nextToken != nil

        // Sort by priority: global > us > other
        let sortedProfiles = inferenceProfiles.sorted { model1, model2 in
            if model1.displayPriority != model2.displayPriority {
                return model1.displayPriority < model2.displayPriority
            }
            return model1.name < model2.name
        }

        return sortedProfiles
    }

    /// Determine inference profile scope from ID prefix.
    private func inferProfileScope(from profileId: String) -> String {
        if profileId.hasPrefix("global.") { return "global" }
        if profileId.hasPrefix("us.") { return "us" }
        if profileId.hasPrefix("eu.") { return "eu" }
        if profileId.hasPrefix("apac.") { return "apac" }
        return "regional"
    }

    /// Extract base model ID from inference profile models.
    private func extractBaseModelId(from models: [AWSBedrock.InferenceProfileModel]) -> String? {
        guard let firstModel = models.first,
              let arn = firstModel.modelArn else {
            return nil
        }

        // ARN format: arn:aws:bedrock:region::foundation-model/model-id
        if let range = arn.range(of: "foundation-model/") {
            return String(arn[range.upperBound...])
        }

        return nil
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

        // Configure runtime client
        var runtimeConfig = try await BedrockRuntimeClient.BedrockRuntimeClientConfiguration(
            region: config.region
        )

        // Set custom credential resolver if profile is specified
        if let profileName = config.profileName, !profileName.isEmpty {
            let identityResolver = try ProfileAWSCredentialIdentityResolver(
                profileName: profileName,
                configFilePath: nil,  // uses default ~/.aws/config
                credentialsFilePath: nil  // uses default ~/.aws/credentials
            )
            runtimeConfig.awsCredentialIdentityResolver = identityResolver
        }

        let newRuntimeClient = BedrockRuntimeClient(config: runtimeConfig)

        // Configure management client
        var managementConfig = try await AWSBedrock.BedrockClient.BedrockClientConfiguration(
            region: config.region
        )

        if let profileName = config.profileName, !profileName.isEmpty {
            let identityResolver = try ProfileAWSCredentialIdentityResolver(
                profileName: profileName,
                configFilePath: nil,
                credentialsFilePath: nil
            )
            managementConfig.awsCredentialIdentityResolver = identityResolver
        }

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
