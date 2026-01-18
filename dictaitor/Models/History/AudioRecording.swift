import Foundation

/// Metadata for an audio recording stored with an interaction
struct AudioRecording: Identifiable, Codable, Equatable {
    let id: UUID
    let filename: String        // Relative path within interaction folder (e.g., "audio/abc123.wav")
    let duration: TimeInterval
    let sampleRate: Double
    let timestamp: Date

    init(
        id: UUID = UUID(),
        filename: String,
        duration: TimeInterval,
        sampleRate: Double,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.filename = filename
        self.duration = duration
        self.sampleRate = sampleRate
        self.timestamp = timestamp
    }
}
