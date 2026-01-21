import Foundation

/// Lightweight metadata for conversation (stored in metadata.json)
struct ConversationMetadata: Codable, Equatable {
    let turnCount: Int       // Number of user messages
    let messageCount: Int    // Total messages (user + assistant)
    let hasAudio: Bool

    init(turnCount: Int, messageCount: Int, hasAudio: Bool = false) {
        self.turnCount = turnCount
        self.messageCount = messageCount
        self.hasAudio = hasAudio
    }
}
