//
//  LLMProvider.swift
//  dictaitor
//
//  LLM provider types and configuration.
//

import Foundation

/// Available LLM providers.
enum LLMProvider: String, Codable, CaseIterable {
    case awsBedrock = "aws_bedrock"
    case openAI = "openai"
    case anthropic = "anthropic"

    var displayName: String {
        switch self {
        case .awsBedrock: return "AWS Bedrock"
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        }
    }

    /// Whether this provider requires an API key entry.
    var requiresAPIKey: Bool {
        switch self {
        case .awsBedrock: return false  // Uses AWS credential chain
        case .openAI, .anthropic: return true
        }
    }

    #if os(macOS)
    /// AWS Bedrock is only available on macOS.
    static var available: [LLMProvider] {
        allCases
    }
    #else
    static var available: [LLMProvider] {
        [.openAI, .anthropic]
    }
    #endif
}

/// Configuration for AWS Bedrock provider.
struct AWSBedrockConfig: Codable, Equatable {
    /// AWS profile name. Nil uses default credential chain.
    var profileName: String?

    /// AWS region for Bedrock API.
    var region: String

    static let `default` = AWSBedrockConfig(
        profileName: nil,
        region: "us-east-1"
    )
}
