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
    var segments: [MeetingSegment]
    let duration: TimeInterval
    let appName: String?
    /// Recovery data kept alive until this payload is durably persisted.
    /// The persistence caller clears it after a successful save (or when
    /// persistence is disabled); it stays on disk after a persist failure.
    var recoveryArtifacts: MeetingRecoveryArtifacts?
    /// The recording's original start time when known (crash recovery) —
    /// nil means "now" (a live stop). A meeting recovered days after the
    /// crash must not masquerade as new in history.
    var startedAt: Date? = nil
}
#endif
