//
//  ModeFeatureMeeting.swift
//  Axii
//
//  Long-running meeting logic for ModeFeature.
//  Extracted to keep each file under 300 lines.
//

#if os(macOS)
import Foundation
import os.log

private let logger = Logger(subsystem: "com.axii", category: "ModeFeatureMeeting")

extension ModeFeature {

    // MARK: - Long Running (Meeting)

    /// Recover a crashed meeting's transcript at launch: mirror it into the
    /// panel AND persist it to history so the next recording cannot destroy
    /// it (the autosave file is shared; a new session's first write would
    /// overwrite the crashed session's data — see the reliability model doc).
    /// The recovery file is released only after the persist succeeds.
    @discardableResult
    func recoverCrashedMeetingIfNeeded() -> Task<Void, Never>? {
        guard let handler = meetingHandler else { return nil }
        defer {
            // Sweep spool audio whose sessions expired; runs before any
            // capture can start, so it never touches a live recording.
            MeetingAudioManager.cleanExpiredSpoolFiles()
        }
        guard let recovery = handler.checkCrashRecovery() else { return nil }
        guard historyService.isEnabled, !recovery.segments.isEmpty else { return nil }

        return Task { @MainActor in
            // Restore the audio too when the spool files survived the crash.
            let micSamples = MeetingAudioManager.readRawSamples(
                from: recovery.audioFiles?.micFileURL
            )
            let systemSamples = MeetingAudioManager.readRawSamples(
                from: recovery.audioFiles?.systemFileURL
            )
            do {
                _ = try await meetingPersistence.persist(
                    payload: MeetingPersistencePayload(
                        micSamples: micSamples,
                        micSampleRate: recovery.audioFiles?.micSampleRate ?? 0,
                        systemSamples: systemSamples,
                        systemSampleRate: recovery.audioFiles?.systemSampleRate ?? 0,
                        segments: recovery.segments,
                        duration: recovery.duration,
                        appName: recovery.appName
                    ),
                    audioFormat: settings.audioStorageFormat
                )
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
                logger.info("Recovered crashed meeting to history (\(recovery.segments.count) segments)")
            } catch {
                // Keep the files: recovery will be offered again next launch.
                logger.error("Failed to persist recovered meeting: \(error.localizedDescription)")
            }
        }
    }

    func showMeetingPanel() {
        isActive = true
        state.phase = .idle
        context?.onActivate?(self)
        Task { await meetingHandler?.refreshAppList() }
    }

    func startMeeting() {
        guard let handler = meetingHandler else {
            state.phase = .error("Meeting handler not configured")
            return
        }
        Task { await handler.start() }
    }

    @discardableResult
    func stopMeeting(saveToHistory: Bool) -> Task<Void, Never>? {
        guard let handler = meetingHandler else { return nil }
        meetingStopGeneration += 1
        let gen = meetingStopGeneration
        let task = Task { @MainActor in
            let result = await handler.stop(saveToHistory: saveToHistory)
            if let result, saveToHistory {
                if historyService.isEnabled {
                    do {
                        _ = try await meetingPersistence.persist(
                            payload: result,
                            audioFormat: settings.audioStorageFormat
                        )
                    } catch {
                        logger.error("Failed to save meeting: \(error.localizedDescription)")
                        // Surface the failure, and deliberately do NOT clear
                        // the recovery artifacts: the meeting is not durably
                        // saved yet, so it must remain recoverable. Both
                        // guards matter: a newer stop's .processing must not
                        // be stomped by a stale error either.
                        if state.phase == .processing, gen == meetingStopGeneration {
                            state.phase = .error("Failed to save meeting")
                        }
                        return
                    }
                }
                // Commit point: the meeting is durably saved (or persistence
                // is disabled and there is nothing to save into). Recovery
                // data has served its purpose.
                result.recoveryArtifacts?.clear()
            }
            // Resolve .processing to idle only when BOTH hold: the phase is
            // still processing AND no newer stop was issued — a newer stop
            // occupies .processing itself, and a phase check alone would
            // stomp it mid-finalize.
            if state.phase == .processing, gen == meetingStopGeneration {
                state.phase = .idle
            }
        }
        return task
    }
}
#endif
