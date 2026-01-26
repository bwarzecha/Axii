import Foundation

/// Lightweight metadata for transcription (stored in metadata.json)
struct TranscriptionMetadata: Codable, Equatable {
    let wordCount: Int
    let pastedTo: String?    // App bundle ID where text was pasted
    let hasAudio: Bool
    let hasContext: Bool     // Whether focus context was captured
    let appName: String?     // App name for display
    let windowTitle: String? // Window title for display

    init(
        wordCount: Int,
        pastedTo: String? = nil,
        hasAudio: Bool = false,
        hasContext: Bool = false,
        appName: String? = nil,
        windowTitle: String? = nil
    ) {
        self.wordCount = wordCount
        self.pastedTo = pastedTo
        self.hasAudio = hasAudio
        self.hasContext = hasContext
        self.appName = appName
        self.windowTitle = windowTitle
    }

    // Custom decoder for backward compatibility with old history entries
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        wordCount = try container.decode(Int.self, forKey: .wordCount)
        pastedTo = try container.decodeIfPresent(String.self, forKey: .pastedTo)
        hasAudio = try container.decodeIfPresent(Bool.self, forKey: .hasAudio) ?? false
        hasContext = try container.decodeIfPresent(Bool.self, forKey: .hasContext) ?? false
        appName = try container.decodeIfPresent(String.self, forKey: .appName)
        windowTitle = try container.decodeIfPresent(String.self, forKey: .windowTitle)
    }

    private enum CodingKeys: String, CodingKey {
        case wordCount, pastedTo, hasAudio, hasContext, appName, windowTitle
    }
}
