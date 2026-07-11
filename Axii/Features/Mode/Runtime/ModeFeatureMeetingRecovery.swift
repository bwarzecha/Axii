//
//  ModeFeatureMeetingRecovery.swift
//  Axii
//
//  Launch-time crash recovery for meetings.
//  Split from ModeFeatureMeeting.swift to keep each file under 300 lines.
//

#if os(macOS)
import Foundation
import os.log

private let logger = Logger(subsystem: "com.axii", category: "ModeFeatureMeetingRecovery")

extension ModeFeature {

    /// Crash recovery consumes a SHARED autosave file — it must run at most
    /// once per process. Without this gate, every crash-recovery mode
    /// registered at launch would persist the same crashed meeting again,
    /// and a mode created or rebuilt at runtime would run "recovery"
    /// against whatever session is live right then.
    static var crashRecoveryDidRun = false

    /// Recover a crashed meeting's transcript at launch: mirror it into the
    /// panel AND persist it to history so the next recording cannot destroy
    /// it (the autosave file is shared; a new session's first write would
    /// overwrite the crashed session's data — see the reliability model doc).
    /// The recovery file is released only after the persist succeeds.
    @discardableResult
    func recoverCrashedMeetingIfNeeded() -> Task<Void, Never>? {
        guard let handler = meetingHandler else { return nil }
        guard !Self.crashRecoveryDidRun else { return nil }
        Self.crashRecoveryDidRun = true
        defer {
            // Sweep spool audio whose sessions expired; runs once, before
            // any capture can start, so it never touches a live recording.
            MeetingAudioManager.cleanExpiredSpoolFiles()
        }
        guard let recovery = handler.checkCrashRecovery() else { return nil }
        let hasContent = !recovery.segments.isEmpty || recovery.audioFiles != nil
        guard historyService.isEnabled, hasContent else { return nil }

        return Task { @MainActor in
            // Restore the audio too when the spool files survived the crash.
            let micSamples = MeetingAudioManager.readRawSamples(
                from: recovery.audioFiles?.micFileURL
            )
            let systemSamples = MeetingAudioManager.readRawSamples(
                from: recovery.audioFiles?.systemFileURL
            )

            // Streaming-off sessions have audio but no live segments —
            // build the transcript from the recovered audio.
            var segments = recovery.segments
            if segments.isEmpty, !micSamples.isEmpty || !systemSamples.isEmpty {
                let finalized = await MeetingFinalizationService(
                    transcriptionService: transcriptionService
                ).finalize(
                    input: MeetingFinalizationInput(
                        micSamples: micSamples,
                        micSampleRate: recovery.audioFiles?.micSampleRate ?? 0,
                        systemSamples: systemSamples,
                        systemSampleRate: recovery.audioFiles?.systemSampleRate ?? 0,
                        duration: recovery.duration,
                        appName: recovery.appName
                    )
                )
                segments = finalized.segments
            }

            do {
                let persisted = try await meetingPersistence.persist(
                    payload: MeetingPersistencePayload(
                        micSamples: micSamples,
                        micSampleRate: recovery.audioFiles?.micSampleRate ?? 0,
                        systemSamples: systemSamples,
                        systemSampleRate: recovery.audioFiles?.systemSampleRate ?? 0,
                        segments: segments,
                        duration: recovery.duration,
                        appName: recovery.appName,
                        startedAt: recovery.startedAt
                    ),
                    audioFormat: settings.audioStorageFormat
                )
                // History was switched off between the isEnabled check above
                // and this write: nothing landed on disk, so the recovery
                // files stay put and will be offered again next launch.
                guard persisted != nil else {
                    logger.info("History disabled mid-recovery; keeping recovery files")
                    return
                }
                clearRecoveryArtifacts(for: recovery)
                logger.info("Recovered crashed meeting to history (\(segments.count) segments)")
            } catch {
                // Keep the files: recovery will be offered again next launch.
                logger.error("Failed to persist recovered meeting: \(error.localizedDescription)")
            }
        }
    }

    /// Release a recovered session's on-disk artifacts. Called only after the
    /// meeting is durably in history — this is the commit point.
    private func clearRecoveryArtifacts(for recovery: MeetingCrashRecovery) {
        if let owner = recovery.sessionID {
            MeetingTranscriptManager.clearAutoSave(
                matching: owner,
                at: recovery.autosaveFileURL
            )
        } else {
            // Pre-sessionID legacy file: recovered and persisted, and
            // there can only have been one writer — safe to remove.
            try? FileManager.default.removeItem(at: recovery.autosaveFileURL)
        }
        if let audioFiles = recovery.audioFiles {
            if let mic = audioFiles.micFileURL {
                try? FileManager.default.removeItem(at: mic)
            }
            if let system = audioFiles.systemFileURL {
                try? FileManager.default.removeItem(at: system)
            }
        }
    }
}
#endif
