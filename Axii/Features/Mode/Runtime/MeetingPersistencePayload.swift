//
//  MeetingPersistencePayload.swift
//  Axii
//
//  Explicit boundary type for meeting persistence. Contains exactly
//  the data needed to persist a finalized meeting and its audio.
//  Lives outside MeetingPipelineHandler so persistence consumers
//  do not depend on handler internals.
//

#if os(macOS)
import Foundation

/// Data needed to persist a finalized meeting to history.
/// Produced by MeetingPipelineHandler.stop(saveToHistory:) and
/// consumed by MeetingPersistenceService.persist(...).
struct MeetingPersistencePayload {
    let micSamples: [Float]
    let micSampleRate: Double
    let systemSamples: [Float]
    let systemSampleRate: Double
    let segments: [MeetingSegment]
    let duration: TimeInterval
    let appName: String?
}
#endif
