//
//  MeetingAnimationStyle.swift
//  Axii
//
//  Animation style options for the meeting recording indicator.
//

#if os(macOS)
import Foundation

/// Animation style for the meeting compact view recording indicator.
enum MeetingAnimationStyle: String, Codable, CaseIterable {
    case pulsingDot
    case waveform
    case none

    var displayName: String {
        switch self {
        case .pulsingDot: return "Pulsing Dot"
        case .waveform: return "Waveform"
        case .none: return "None (Static)"
        }
    }

    var description: String {
        switch self {
        case .pulsingDot: return "A pulsing red dot that indicates recording"
        case .waveform: return "Audio level bars that respond to sound"
        case .none: return "A static indicator with no animation"
        }
    }
}
#endif
