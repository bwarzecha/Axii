//
//  LLMSettingsService.swift
//  dictaitor
//
//  Settings service for LLM provider configuration.
//

#if os(macOS)
import Foundation

/// Manages LLM provider settings with secure API key storage.
@MainActor
@Observable
final class LLMSettingsService {
    /// Currently selected LLM provider.
    private(set) var selectedProvider: LLMProvider

    /// AWS Bedrock configuration.
    private(set) var awsBedrockConfig: AWSBedrockConfig

    private let defaults: UserDefaults
    private let keychain: KeychainService

    private let providerKey = "llm.selectedProvider"
    private let awsConfigKey = "llm.awsBedrockConfig"

    init(defaults: UserDefaults = .standard, keychain: KeychainService = KeychainService()) {
        self.defaults = defaults
        self.keychain = keychain

        // Load provider selection
        if let rawValue = defaults.string(forKey: providerKey),
           let provider = LLMProvider(rawValue: rawValue) {
            self.selectedProvider = provider
        } else {
            self.selectedProvider = .awsBedrock  // Default to Bedrock (only implemented provider)
        }

        // Load AWS config
        if let data = defaults.data(forKey: awsConfigKey),
           let config = try? JSONDecoder().decode(AWSBedrockConfig.self, from: data) {
            self.awsBedrockConfig = config
        } else {
            self.awsBedrockConfig = .default
        }
    }

    // MARK: - Provider Selection

    func selectProvider(_ provider: LLMProvider) {
        guard provider != selectedProvider else { return }
        selectedProvider = provider
        defaults.set(provider.rawValue, forKey: providerKey)
    }

    // MARK: - AWS Bedrock Configuration

    func updateAWSBedrockConfig(_ config: AWSBedrockConfig) {
        guard config != awsBedrockConfig else { return }
        awsBedrockConfig = config
        if let data = try? JSONEncoder().encode(config) {
            defaults.set(data, forKey: awsConfigKey)
        }
    }

    func setAWSProfile(_ profileName: String?) {
        var config = awsBedrockConfig
        config.profileName = profileName
        updateAWSBedrockConfig(config)
    }

    func setAWSRegion(_ region: String) {
        var config = awsBedrockConfig
        config.region = region
        updateAWSBedrockConfig(config)
    }

    // MARK: - API Keys

    /// Get API key for a provider.
    func apiKey(for provider: LLMProvider) -> String? {
        keychain.get(key: provider.rawValue)
    }

    /// Set API key for a provider.
    func setAPIKey(_ key: String?, for provider: LLMProvider) {
        guard provider.requiresAPIKey else { return }

        if let key, !key.isEmpty {
            try? keychain.set(key, forKey: provider.rawValue)
        } else {
            try? keychain.delete(key: provider.rawValue)
        }
    }

    /// Check if API key is configured for a provider.
    func hasAPIKey(for provider: LLMProvider) -> Bool {
        guard provider.requiresAPIKey else { return true }
        return keychain.exists(key: provider.rawValue)
    }

    // MARK: - Validation

    /// Check if current provider is ready to use.
    var isCurrentProviderConfigured: Bool {
        switch selectedProvider {
        case .awsBedrock:
            return true  // AWS uses credential chain
        case .openAI, .anthropic:
            return hasAPIKey(for: selectedProvider)
        }
    }

    /// Human-readable status for current provider.
    var configurationStatus: String {
        if isCurrentProviderConfigured {
            return "\(selectedProvider.displayName) ready"
        } else {
            return "\(selectedProvider.displayName) needs API key"
        }
    }
}
#endif
