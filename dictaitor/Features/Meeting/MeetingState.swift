//
//  MeetingState.swift
//  dictaitor
//
//  Observable state and data models for the meeting transcription feature.
//

#if os(macOS)
import SwiftUI

// MARK: - MeetingSegment

/// A transcribed segment from a meeting with speaker attribution.
struct MeetingSegment: Identifiable, Codable, Equatable {
    let id: UUID
    let text: String
    /// Speaker ID: "you" for microphone, "speaker_1", "speaker_2" etc for system audio
    let speakerId: String
    /// Whether this segment came from microphone (host) or system audio (remote participants)
    let isFromMicrophone: Bool
    let startTime: TimeInterval
    let endTime: TimeInterval
    /// Whether this segment has been confirmed (transcription complete) vs preliminary
    let isConfirmed: Bool

    init(
        id: UUID = UUID(),
        text: String,
        speakerId: String,
        isFromMicrophone: Bool,
        startTime: TimeInterval,
        endTime: TimeInterval,
        isConfirmed: Bool = true
    ) {
        self.id = id
        self.text = text
        self.speakerId = speakerId
        self.isFromMicrophone = isFromMicrophone
        self.startTime = startTime
        self.endTime = endTime
        self.isConfirmed = isConfirmed
    }

    /// Display name for the speaker
    var displayName: String {
        if speakerId == "you" {
            return "You"
        }
        // Handle "speaker_1" format -> "Speaker 1"
        let components = speakerId.split(separator: "_")
        if components.count == 2, components.first == "speaker", let number = components.last {
            return "Speaker \(number)"
        }
        // Handle raw numeric IDs from diarization (e.g., "1" -> "Speaker 1")
        if let _ = Int(speakerId) {
            return "Speaker \(speakerId)"
        }
        return speakerId.capitalized
    }

    var duration: TimeInterval {
        endTime - startTime
    }
}

// MARK: - MeetingPhase

/// Meeting workflow phases.
enum MeetingPhase: Equatable {
    case idle
    case ready              // Panel shown, user can configure before starting
    case loadingModels
    case permissionRequired
    case recording
    case processing         // Finishing up, transcribing remaining audio
    case error(message: String)
}

// MARK: - MeetingState

/// Observable state for meeting transcription feature.
@MainActor @Observable
final class MeetingState {
    var phase: MeetingPhase = .idle
    var audioLevel: Float = 0
    var spectrum: [Float] = []

    /// Transcribed segments from the meeting
    var segments: [MeetingSegment] = []

    /// Total recording duration
    var duration: TimeInterval = 0

    /// Available microphones
    var availableMicrophones: [AudioDevice] = []

    /// Currently selected microphone (nil = system default)
    var selectedMicrophone: AudioDevice?

    /// Available apps for audio capture
    var availableApps: [AudioApp] = []

    /// Selected app for audio capture (nil = all apps)
    var selectedApp: AudioApp?

    /// Whether currently recording
    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    /// Reset state for a new meeting
    func reset() {
        segments = []
        duration = 0
        audioLevel = 0
        spectrum = []
    }
}
#endif
