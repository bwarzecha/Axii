import Foundation

/// Full transcription data (stored in interaction.json)
struct Transcription: Identifiable, Codable, Equatable {
    let id: UUID
    let text: String
    let audioRecording: AudioRecording?
    let pastedTo: String?       // App bundle ID where text was pasted
    let focusContext: FocusContext?  // Rich context for LLM corrections
    let createdAt: Date
    /// When this dictation was discarded to "Recently Deleted", if ever.
    /// A canceled capture is salvaged here rather than destroyed, so a
    /// mistaken Escape is recoverable. Optional: entries from versions
    /// before the trash decode as nil (never discarded).
    var discardedAt: Date?

    var interactionType: InteractionType { .transcription }

    /// List/search preview for a discarded capture whose transcript hasn't
    /// been produced yet. Makes no claim about audio: some salvage configs
    /// (saveAudio off) keep only the transcript.
    static let discardedPreviewPlaceholder = "Canceled recording"

    init(
        id: UUID = UUID(),
        text: String,
        audioRecording: AudioRecording? = nil,
        pastedTo: String? = nil,
        focusContext: FocusContext? = nil,
        createdAt: Date = Date(),
        discardedAt: Date? = nil
    ) {
        self.id = id
        self.text = text
        self.audioRecording = audioRecording
        self.pastedTo = pastedTo
        self.focusContext = focusContext
        self.createdAt = createdAt
        self.discardedAt = discardedAt
    }

    func withDiscarded(_ date: Date?) -> Transcription {
        Transcription(
            id: id, text: text, audioRecording: audioRecording,
            pastedTo: pastedTo, focusContext: focusContext,
            createdAt: createdAt, discardedAt: date
        )
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
                windowTitle: focusContext?.windowTitle,
                discardedAt: discardedAt
            )
        )
        return InteractionMetadata(
            id: id,
            type: .transcription,
            createdAt: createdAt,
            updatedAt: createdAt,
            preview: text.isEmpty && discardedAt != nil
                ? Self.discardedPreviewPlaceholder : text,
            details: details
        )
    }
}
