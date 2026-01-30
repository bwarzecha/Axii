//
//  AWSConfigHelper.swift
//  Axii
//
//  Helper for reading AWS configuration.
//

import Foundation

/// Helper for reading AWS credentials and configuration.
struct AWSConfigHelper {
    /// Common AWS regions.
    static let regions = [
        "us-east-1",
        "us-east-2",
        "us-west-1",
        "us-west-2",
        "ca-central-1",
        "eu-west-1",
        "eu-west-2",
        "eu-west-3",
        "eu-central-1",
        "eu-north-1",
        "ap-southeast-1",
        "ap-southeast-2",
        "ap-northeast-1",
        "ap-northeast-2",
        "ap-south-1",
        "sa-east-1"
    ]

    /// Read available AWS profiles from ~/.aws/credentials file.
    static func readAvailableProfiles() -> [String] {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let credentialsPath = homeDir.appendingPathComponent(".aws/credentials")

        guard let contents = try? String(contentsOf: credentialsPath, encoding: .utf8) else {
            return []
        }

        var profiles: [String] = []

        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Match [profile_name]
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                let profileName = String(trimmed.dropFirst().dropLast())
                profiles.append(profileName)
            }
        }

        return profiles.isEmpty ? ["default"] : profiles
    }
}
