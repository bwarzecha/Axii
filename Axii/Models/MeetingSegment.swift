//
//  MeetingSegment.swift
//  Axii
//
//  A transcribed segment from a meeting with speaker attribution — the
//  core meeting data type, shared by capture, finalization, persistence,
//  pipeline steps, and history UI.
//  (Extracted from the deleted legacy MeetingState.swift.)
//

import Foundation

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
