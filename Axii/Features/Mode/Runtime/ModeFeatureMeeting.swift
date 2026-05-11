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
            if let result, saveToHistory, historyService.isEnabled {
                do {
                    _ = try await meetingPersistence.persist(
                        payload: result,
                        audioFormat: settings.audioStorageFormat
                    )
                } catch {
                    logger.error("Failed to save meeting: \(error.localizedDescription)")
                }
            }
            state.phase = .idle
        }
        return task
    }
}
#endif
