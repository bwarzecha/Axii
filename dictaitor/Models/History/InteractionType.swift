import Foundation

/// Type of interaction stored in history
enum InteractionType: String, Codable, CaseIterable {
    case transcription
    case conversation
    // case command  // Future
}
