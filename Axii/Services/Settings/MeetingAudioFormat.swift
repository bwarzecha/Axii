//
//  MeetingAudioFormat.swift
//  Axii
//
//  Audio format options for meeting recordings.
//  User-configurable in Settings to balance quality vs file size.
//

#if os(macOS)
import Foundation

/// Audio format for meeting recordings - user-configurable in Settings.
enum MeetingAudioFormat: String, Codable, CaseIterable {
    case alac   // Apple Lossless - perfect quality, ~150 MB/hour
    case aac    // AAC 128kbps - transparent quality, ~57 MB/hour

    var displayName: String {
        switch self {
        case .alac: return "ALAC (Lossless)"
        case .aac: return "AAC (Smaller files)"
        }
    }

    var description: String {
        switch self {
        case .alac: return "Perfect quality, ~150 MB/hour"
        case .aac: return "Transparent quality, ~57 MB/hour"
        }
    }

    /// File extension for saved audio files
    var fileExtension: String { "m4a" }  // Both use M4A container

    /// AAC bitrate in bits per second (only used for AAC)
    var aacBitrate: Int { 128_000 }  // 128 kbps
}
#endif
