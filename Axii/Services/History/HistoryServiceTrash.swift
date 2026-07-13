//
//  HistoryServiceTrash.swift
//  Axii
//
//  "Recently Deleted" for meetings and dictations: a discarded capture is
//  a real history row (audio + transcript intact) flagged `discardedAt`,
//  hidden from the main list until the user restores it or the retention
//  window sweeps it. So a mistaken Escape/close/discard is always
//  recoverable.
//

#if os(macOS)
import Foundation

extension HistoryService {

    // MARK: - Trash Queries

    /// Entries currently in "Recently Deleted", newest discard first.
    func discardedMetadata() -> [InteractionMetadata] {
        cache.values
            .filter { $0.isDiscarded }
            .sorted { ($0.discardedAt ?? .distantPast) > ($1.discardedAt ?? .distantPast) }
    }

    /// Non-discarded entries only — the main history list.
    func activeMetadata(type: InteractionType) -> [InteractionMetadata] {
        cache.values
            .filter { $0.type == type && !$0.isDiscarded }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func activeMetadata() -> [InteractionMetadata] {
        cache.values
            .filter { !$0.isDiscarded }
            .sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Restore

    /// Bring a discarded entry back into the main history list. Rewrites
    /// the same folder (folderName is derived from createdAt+id, so it is
    /// stable across the flag change) with `discardedAt` cleared.
    @discardableResult
    func restoreDiscarded(id: UUID) async throws -> Bool {
        guard let metadata = cache[id], metadata.isDiscarded else { return false }
        switch try await loadInteraction(id: id) {
        case .meeting(let meeting):
            try await save(.meeting(meeting.withDiscarded(nil)))
            return true
        case .transcription(let transcription):
            try await save(.transcription(transcription.withDiscarded(nil)))
            return true
        case .conversation:
            return false
        }
    }

    // MARK: - Sweep

    /// Permanently delete entries discarded longer ago than the retention
    /// window. Runs at launch, before any capture — same lifetime as crash
    /// recovery so the whole reliability surface expires consistently.
    func sweepExpiredDiscards(
        now: Date = Date(),
        lifetime: TimeInterval = MeetingRecoveryPolicy.artifactLifetime
    ) async {
        let expired = cache.values.filter {
            guard let discardedAt = $0.discardedAt else { return false }
            return now.timeIntervalSince(discardedAt) > lifetime
        }
        for metadata in expired {
            try? await delete(id: metadata.id)
        }
    }
}
#endif
