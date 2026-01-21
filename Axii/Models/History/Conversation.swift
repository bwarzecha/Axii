import Foundation

/// Full conversation data (stored in interaction.json)
struct Conversation: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String?
    var messages: [Message]
    var audioRecordings: [AudioRecording]
    let createdAt: Date
    var updatedAt: Date

    var interactionType: InteractionType { .conversation }

    init(
        id: UUID = UUID(),
        title: String? = nil,
        messages: [Message] = [],
        audioRecordings: [AudioRecording] = [],
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.audioRecordings = audioRecordings
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    /// Number of user messages (turns)
    var turnCount: Int {
        messages.filter { $0.role == .user }.count
    }

    /// Add a message and update timestamp
    mutating func addMessage(_ message: Message) {
        messages.append(message)
        updatedAt = Date()
    }

    /// Add an audio recording
    mutating func addAudioRecording(_ recording: AudioRecording) {
        audioRecordings.append(recording)
        updatedAt = Date()
    }

    /// Get the first user message as preview text
    var previewText: String {
        messages.first(where: { $0.role == .user })?.content ?? ""
    }

    /// Generate metadata for this conversation
    func toMetadata() -> InteractionMetadata {
        let details = MetadataDetails.conversation(
            ConversationMetadata(
                turnCount: turnCount,
                messageCount: messages.count,
                hasAudio: !audioRecordings.isEmpty
            )
        )
        return InteractionMetadata(
            id: id,
            type: .conversation,
            createdAt: createdAt,
            updatedAt: updatedAt,
            preview: previewText,
            details: details
        )
    }
}
