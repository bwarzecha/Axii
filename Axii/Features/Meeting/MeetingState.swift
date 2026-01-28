//
//  MeetingState.swift
//  Axii
//
//  Observable state for meeting transcription feature.
//

#if os(macOS)
import SwiftUI

// MARK: - MeetingSegment

/// A transcribed segment from a meeting with speaker attribution.
struct MeetingSegment: Identifiable, Codable, Equatable {
    let id: UUID
    let text: String
    let speakerId: String
    let isFromMicrophone: Bool
    let startTime: TimeInterval
    let endTime: TimeInterval

    init(
        id: UUID = UUID(),
        text: String,
        speakerId: String,
        isFromMicrophone: Bool,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) {
        self.id = id
        self.text = text
        self.speakerId = speakerId
        self.isFromMicrophone = isFromMicrophone
        self.startTime = startTime
        self.endTime = endTime
    }

    var displayName: String {
        if speakerId == "You" || speakerId == "you" {
            return "You"
        }
        if speakerId == "Remote" {
            return "Remote"
        }
        let components = speakerId.split(separator: "_")
        if components.count == 2, components.first == "speaker", let number = components.last {
            return "Speaker \(number)"
        }
        if Int(speakerId) != nil {
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
    case ready
    case loadingModels
    case permissionRequired
    case recording
    case processing
    case error(message: String)
}

// MARK: - MeetingState

/// Observable state for meeting transcription feature.
@MainActor @Observable
final class MeetingState {
    var phase: MeetingPhase = .idle
    var panelMode: MeetingPanelMode = .expanded
    var audioLevel: Float = 0
    var duration: TimeInterval = 0
    var segments: [MeetingSegment] = []
    var availableMicrophones: [AudioDevice] = []
    var selectedMicrophone: AudioDevice?
    var availableApps: [AudioApp] = []
    var selectedApp: AudioApp?

    // Processing progress (0.0 to 1.0)
    var processingProgress: Double = 0
    var processingStatus: String = ""

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    var isProcessing: Bool {
        if case .processing = phase { return true }
        return false
    }

    func reset() {
        segments = []
        duration = 0
        audioLevel = 0
        processingProgress = 0
        processingStatus = ""
    }
}
#endif
