//
//  MeetingMetadata.swift
//  Axii
//
//  Lightweight metadata for meeting history entries.
//

import Foundation

/// Type-specific metadata for meetings (stored in metadata.json)
struct MeetingMetadata: Codable, Equatable {
    let segmentCount: Int
    let duration: TimeInterval
    let wordCount: Int
    let appName: String?
    let hasMicAudio: Bool
    let hasSystemAudio: Bool

    /// Formatted duration string (e.g., "1:23:45" or "5:30")
    var formattedDuration: String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}
