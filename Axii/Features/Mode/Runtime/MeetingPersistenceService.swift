//
//  MeetingPersistenceService.swift
//  Axii
//
//  Owns the persisted meeting and audio write contract.
//  Consumes a MeetingPersistencePayload and writes the final Meeting
//  to HistoryService, including compressed audio attachments.
//
//  Important: HistoryService.saveAudioCompressed requires an existing
//  metadata cache entry. The two-write pattern (initial save → audio
//  writes → final save) is intentional and required.
//

#if os(macOS)
import Foundation
import os.log

private let logger = Logger(subsystem: "com.axii", category: "MeetingPersistenceService")

/// Protocol for adapter-level test injection of meeting persistence.
@MainActor
protocol MeetingPersisting {
    /// Returns the persisted meeting, or `nil` when history is disabled and
    /// nothing was written. Callers must not release recovery artifacts on nil.
    func persist(
        payload: MeetingPersistencePayload,
        audioFormat: AudioStorageFormat
    ) async throws -> Meeting?
}

/// Dedicated service for persisting finalized meetings and their audio.
///
/// Responsibilities:
/// - Create the base Meeting
/// - Initial history save (establishes folder/cache identity)
/// - Compressed audio writes for mic/system tracks
/// - Final re-save with attached AudioRecording metadata
/// - Return the final persisted Meeting
///
/// Does not own: settings, autosave, temp-file cleanup, or finalization.
@MainActor
final class MeetingPersistenceService: MeetingPersisting {

    private let historyService: HistoryService

    init(historyService: HistoryService) {
        self.historyService = historyService
    }

    /// Persist a finalized meeting with optional audio tracks.
    ///
    /// The two-write flow is required by HistoryService:
    /// 1. Save base Meeting to establish folder and cache entry
    /// 2. Write compressed audio against that meeting ID
    /// 3. Re-save Meeting with attached AudioRecording values
    ///
    /// - Parameters:
    ///   - payload: The finalized meeting data from the pipeline handler.
    ///   - audioFormat: The audio compression format to use.
    /// - Returns: The final persisted Meeting (with recordings attached), or
    ///   nil when history is disabled and nothing was written to disk.
    /// - Throws: On any persistence failure. Callers decide error semantics.
    func persist(
        payload: MeetingPersistencePayload,
        audioFormat: AudioStorageFormat
    ) async throws -> Meeting? {
        // 1. Create base meeting. Crash recoveries carry the recording's
        // original start time — a meeting recovered days later must appear
        // in history under its real date, not the relaunch time.
        let meeting = Meeting(
            segments: payload.segments,
            duration: payload.duration,
            appName: payload.appName,
            createdAt: payload.startedAt ?? Date(),
            discardedAt: payload.discardedAt
        )

        // 2. Initial save — establishes history folder and metadata cache entry.
        // A disabled history writes nothing; report that instead of continuing
        // to "save" audio into a record that does not exist.
        guard try await historyService.save(.meeting(meeting)) == .saved else {
            return nil
        }

        // 3. Save compressed audio tracks if present
        var micRecording: AudioRecording?
        var systemRecording: AudioRecording?

        if !payload.micSamples.isEmpty, payload.micSampleRate > 0 {
            micRecording = try await historyService.saveAudioCompressed(
                samples: payload.micSamples,
                sampleRate: payload.micSampleRate,
                format: audioFormat,
                for: meeting.id
            )
        }

        if !payload.systemSamples.isEmpty, payload.systemSampleRate > 0 {
            systemRecording = try await historyService.saveAudioCompressed(
                samples: payload.systemSamples,
                sampleRate: payload.systemSampleRate,
                format: audioFormat,
                for: meeting.id
            )
        }

        // 4. Re-save with recordings attached, preserving id and createdAt
        if micRecording != nil || systemRecording != nil {
            let updated = Meeting(
                id: meeting.id,
                segments: payload.segments,
                duration: payload.duration,
                micRecording: micRecording,
                systemRecording: systemRecording,
                appName: payload.appName,
                createdAt: meeting.createdAt,
                discardedAt: payload.discardedAt
            )
            try await historyService.save(.meeting(updated))
            return updated
        }

        return meeting
    }
}
#endif
