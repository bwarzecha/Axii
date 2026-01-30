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
    @State private var profileName: String
    @State private var region: String

    init(settings: LLMSettingsService) {
        self.settings = settings
        _profileName = State(initialValue: settings.awsBedrockConfig.profileName ?? "")
        _region = State(initialValue: settings.awsBedrockConfig.region)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AWS Bedrock")
                .font(.headline)

            // Profile name
            HStack {
                Text("Profile:")
                    .frame(width: 80, alignment: .trailing)
                TextField("default", text: $profileName)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: profileName) { _, newValue in
                        settings.setAWSProfile(newValue.isEmpty ? nil : newValue)
                    }
            }

            Text("AWS profile name from ~/.aws/credentials. Leave empty for default.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Region
            HStack {
                Text("Region:")
                    .frame(width: 80, alignment: .trailing)
                TextField("us-east-1", text: $region)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: region) { _, newValue in
                        if !newValue.isEmpty {
                            settings.setAWSRegion(newValue)
                        }
                    }
            }

            Text("AWS region for Bedrock service (e.g., us-east-1, us-west-2).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
#endif
