import Foundation

/// Lightweight metadata for transcription (stored in metadata.json)
struct TranscriptionMetadata: Codable, Equatable {
    let wordCount: Int
    let pastedTo: String?    // App bundle ID where text was pasted
    let hasAudio: Bool

    init(wordCount: Int, pastedTo: String? = nil, hasAudio: Bool = false) {
        self.wordCount = wordCount
        self.pastedTo = pastedTo
        self.hasAudio = hasAudio
    }
}
