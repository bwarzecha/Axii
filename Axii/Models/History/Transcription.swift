import Foundation

/// Full transcription data (stored in interaction.json)
struct Transcription: Identifiable, Codable, Equatable {
    let id: UUID
    let text: String
    let audioRecording: AudioRecording?
    let pastedTo: String?       // App bundle ID where text was pasted
    let focusContext: FocusContext?  // Rich context for LLM corrections
    let createdAt: Date

    var interactionType: InteractionType { .transcription }

    init(
        id: UUID = UUID(),
        text: String,
        audioRecording: AudioRecording? = nil,
        pastedTo: String? = nil,
        focusContext: FocusContext? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.audioRecording = audioRecording
        self.pastedTo = pastedTo
        self.focusContext = focusContext
        self.createdAt = createdAt
    }

    /// Generate metadata for this transcription
    func toMetadata() -> InteractionMetadata {
        let wordCount = text.split(separator: " ").count
        let details = MetadataDetails.transcription(
            TranscriptionMetadata(
                wordCount: wordCount,
                pastedTo: pastedTo,
                hasAudio: audioRecording != nil,
                hasContext: focusContext != nil,
                appName: focusContext?.appName,
                windowTitle: focusContext?.windowTitle
            )
        )
        return InteractionMetadata(
            id: id,
            type: .transcription,
            createdAt: createdAt,
            updatedAt: createdAt,
            preview: text,
            details: details
        )
    }
}
