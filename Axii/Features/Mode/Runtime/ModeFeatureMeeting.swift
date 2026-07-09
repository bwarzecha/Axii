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
                        // saved yet, so it must remain recoverable.
                        if state.phase == .processing {
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
            // Only this stop's own .processing phase may be resolved to idle;
            // if a newer session owns the UI (.recording/.preparing/.error),
            // leave it alone.
            if state.phase == .processing {
                state.phase = .idle
            }
        }
        return task
    }
}
#endif
