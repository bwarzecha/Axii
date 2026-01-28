import Foundation

/// Unified wrapper for any interaction type (for storage and retrieval)
enum Interaction: Codable, Equatable {
    case transcription(Transcription)
    case conversation(Conversation)
    case meeting(Meeting)

    private enum CodingKeys: String, CodingKey {
        case type
        case data
    }

    var id: UUID {
        switch self {
        case .transcription(let t): return t.id
        case .conversation(let c): return c.id
        case .meeting(let m): return m.id
        }
    }

    var createdAt: Date {
        switch self {
        case .transcription(let t): return t.createdAt
        case .conversation(let c): return c.createdAt
        case .meeting(let m): return m.createdAt
        }
    }

    var type: InteractionType {
        switch self {
        case .transcription: return .transcription
        case .conversation: return .conversation
        case .meeting: return .meeting
        }
    }

    /// Generate metadata for this interaction
    func toMetadata() -> InteractionMetadata {
        switch self {
        case .transcription(let t):
            return t.toMetadata()
        case .conversation(let c):
            return c.toMetadata()
        case .meeting(let m):
            return m.toMetadata()
        }
    }

    // MARK: - Codable

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(InteractionType.self, forKey: .type)

        switch type {
        case .transcription:
            let data = try container.decode(Transcription.self, forKey: .data)
            self = .transcription(data)
        case .conversation:
            let data = try container.decode(Conversation.self, forKey: .data)
            self = .conversation(data)
        case .meeting:
            let data = try container.decode(Meeting.self, forKey: .data)
            self = .meeting(data)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .transcription(let data):
            try container.encode(InteractionType.transcription, forKey: .type)
            try container.encode(data, forKey: .data)
        case .conversation(let data):
            try container.encode(InteractionType.conversation, forKey: .type)
            try container.encode(data, forKey: .data)
        case .meeting(let data):
            try container.encode(InteractionType.meeting, forKey: .type)
            try container.encode(data, forKey: .data)
        }
    }
}
