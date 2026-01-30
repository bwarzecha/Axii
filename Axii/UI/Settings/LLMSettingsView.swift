//
//  LLMSettingsView.swift
//  Axii
//
//  LLM provider configuration settings.
//

#if os(macOS)
import SwiftUI

struct LLMSettingsView: View {
    let settings: LLMSettingsService
    let bedrockClient: BedrockClient

    @State private var availableProfiles: [String] = []
    @State private var availableModels: [BedrockModel] = []
    @State private var isLoadingModels = false
    @State private var modelError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AWS Bedrock")
                .font(.headline)

            // Profile picker
            HStack {
                Text("Profile:")
                    .frame(width: 80, alignment: .trailing)

                if availableProfiles.isEmpty {
                    Text("No profiles found")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    Picker("", selection: Binding(
                        get: { settings.awsBedrockConfig.profileName ?? "default" },
                        set: { settings.setAWSProfile($0 == "default" ? nil : $0) }
                    )) {
                        ForEach(availableProfiles, id: \.self) { profile in
                            Text(profile).tag(profile)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }
            }

            Text("AWS profile from ~/.aws/credentials")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Region picker
            HStack {
                Text("Region:")
                    .frame(width: 80, alignment: .trailing)

                Picker("", selection: Binding(
                    get: { settings.awsBedrockConfig.region },
                    set: { settings.setAWSRegion($0) }
                )) {
                    ForEach(AWSConfigHelper.regions, id: \.self) { region in
                        Text(region).tag(region)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .onChange(of: settings.awsBedrockConfig.region) { _, _ in
                    // Clear model selection when region changes
                    settings.setAWSModelId(nil)
                    availableModels = []
                }
            }

            Text("AWS region for Bedrock service")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            // Model selection
            HStack {
                Text("Model:")
                    .frame(width: 80, alignment: .trailing)

                if isLoadingModels {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if let error = modelError {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Error loading models")
                            .foregroundStyle(.red)
                            .font(.caption)
                        Text(error)
                            .foregroundStyle(.secondary)
                            .font(.caption2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if availableModels.isEmpty {
                    Button("Load Models") {
                        Task {
                            await loadModels()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Picker("", selection: Binding(
                        get: { settings.awsBedrockConfig.modelId ?? "" },
                        set: { settings.setAWSModelId($0.isEmpty ? nil : $0) }
                    )) {
                        Text("Select model").tag("")
                        ForEach(availableModels) { model in
                            HStack {
                                Text(model.name)
                                if let scope = model.scope {
                                    Text("(\(scope))")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .tag(model.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)

                    Button("Refresh") {
                        Task {
                            await loadModels()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            if !availableModels.isEmpty {
                Text("Cross-region inference profiles preferred for better availability")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let modelId = settings.awsBedrockConfig.modelId,
               let model = availableModels.first(where: { $0.id == modelId }) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Selected:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(model.name)
                            .font(.caption)
                        if model.isInferenceProfile, let scope = model.scope {
                            Text("[\(scope.uppercased())]")
                                .font(.caption2)
                                .foregroundStyle(.blue)
                        }
                    }
                }
            }
        }
        .task {
            // Load profiles on appear
            availableProfiles = AWSConfigHelper.readAvailableProfiles()

            // Auto-load models if config is set
            if !settings.awsBedrockConfig.region.isEmpty,
               availableModels.isEmpty {
                await loadModels()
            }
        }
    }

    private func loadModels() async {
        isLoadingModels = true
        modelError = nil

        do {
            let models = try await bedrockClient.listModels(config: settings.awsBedrockConfig)
            availableModels = models
            isLoadingModels = false

            // Auto-select first model if none selected
            if settings.awsBedrockConfig.modelId == nil, let first = models.first {
                settings.setAWSModelId(first.id)
            }
        } catch {
            modelError = error.localizedDescription
            isLoadingModels = false
        }
    }
}
#endif
