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
    /// When the user discarded this meeting. A discarded meeting is a real
    /// history row (audio and transcript intact) but is hidden from the main
    /// list and shown in "Recently Deleted" — so a mistaken Escape/discard
    /// is recoverable. Swept for good after the recovery window. nil = kept.
    var discardedAt: Date?

    var interactionType: InteractionType { .meeting }
    var isDiscarded: Bool { discardedAt != nil }

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
        createdAt: Date = Date(),
        discardedAt: Date? = nil
    ) {
        self.id = id
        self.segments = segments
        self.duration = duration
        self.micRecording = micRecording
        self.systemRecording = systemRecording
        self.appName = appName
        self.createdAt = createdAt
        self.discardedAt = discardedAt
    }

    /// A copy with the discard flag set/cleared, preserving everything else.
    func withDiscarded(_ date: Date?) -> Meeting {
        Meeting(
            id: id, segments: segments, duration: duration,
            micRecording: micRecording, systemRecording: systemRecording,
            appName: appName, createdAt: createdAt, discardedAt: date
        )
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
                hasSystemAudio: systemRecording != nil,
                discardedAt: discardedAt
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
