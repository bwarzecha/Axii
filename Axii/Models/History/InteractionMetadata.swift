import Foundation

/// Type-specific details stored in metadata.json
enum MetadataDetails: Codable, Equatable {
    case transcription(TranscriptionMetadata)
    case conversation(ConversationMetadata)

    private enum CodingKeys: String, CodingKey {
        case type
        case data
    }

    private enum TypeValue: String, Codable {
        case transcription
        case conversation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(TypeValue.self, forKey: .type)

        switch type {
        case .transcription:
            let data = try container.decode(TranscriptionMetadata.self, forKey: .data)
            self = .transcription(data)
        case .conversation:
            let data = try container.decode(ConversationMetadata.self, forKey: .data)
            self = .conversation(data)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .transcription(let data):
            try container.encode(TypeValue.transcription, forKey: .type)
            try container.encode(data, forKey: .data)
        case .conversation(let data):
            try container.encode(TypeValue.conversation, forKey: .type)
            try container.encode(data, forKey: .data)
        }
    }
}

/// Base metadata for any interaction (~500 bytes, read at startup for listing)
struct InteractionMetadata: Identifiable, Codable, Equatable {
    let id: UUID
    let type: InteractionType
    let createdAt: Date
    var updatedAt: Date
    let preview: String          // First ~100 chars for display
    let details: MetadataDetails

    /// Folder name for this interaction (e.g., "2025-01-18T10-30-00_transcription_abc123")
    var folderName: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withDashSeparatorInDate]
        let dateString = formatter.string(from: createdAt)
            .replacingOccurrences(of: ":", with: "-")
        let shortId = id.uuidString.prefix(8).lowercased()
        return "\(dateString)_\(type.rawValue)_\(shortId)"
    }

    init(
        id: UUID,
        type: InteractionType,
        createdAt: Date,
        updatedAt: Date,
        preview: String,
        details: MetadataDetails
    ) {
        self.id = id
        self.type = type
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.preview = String(preview.prefix(100))
        self.details = details
    }
}
