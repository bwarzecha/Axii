//
//  Meeting.swift
//  Axii
//
//  Meeting transcription data for history storage.
//

import Foundation

/// Full meeting data (stored in interaction.json)
struct Meeting: Identifiable, Codable, Equatable {
    let id: UUID
    let segments: [MeetingSegment]
    let duration: TimeInterval
    let micRecording: AudioRecording?
    let systemRecording: AudioRecording?
    let appName: String?
    let createdAt: Date

    var interactionType: InteractionType { .meeting }

    /// Full transcript text (all segments concatenated)
    var fullText: String {
        segments.map { "\($0.displayName): \($0.text)" }.joined(separator: "\n\n")
    }

    /// Word count across all segments
    var wordCount: Int {
        segments.reduce(0) { $0 + $1.text.split(separator: " ").count }
    }

    init(
        id: UUID = UUID(),
        segments: [MeetingSegment],
        duration: TimeInterval,
        micRecording: AudioRecording? = nil,
        systemRecording: AudioRecording? = nil,
        appName: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.segments = segments
        self.duration = duration
        self.micRecording = micRecording
        self.systemRecording = systemRecording
        self.appName = appName
        self.createdAt = createdAt
    }

    /// Generate metadata for this meeting
    func toMetadata() -> InteractionMetadata {
        let preview = segments.first.map { "\($0.displayName): \($0.text)" } ?? "Empty meeting"
        let details = MetadataDetails.meeting(
            MeetingMetadata(
                segmentCount: segments.count,
                duration: duration,
                wordCount: wordCount,
                appName: appName,
                hasMicAudio: micRecording != nil,
                hasSystemAudio: systemRecording != nil
            )
        )
        return InteractionMetadata(
            id: id,
            type: .meeting,
            createdAt: createdAt,
            updatedAt: createdAt,
            preview: preview,
            details: details
        )
    }
}
