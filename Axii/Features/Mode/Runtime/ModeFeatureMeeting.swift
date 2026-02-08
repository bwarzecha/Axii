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

    func stopMeeting(saveToHistory: Bool) {
        guard let handler = meetingHandler else { return }
        Task {
            let result = await handler.stop(saveToHistory: saveToHistory)
            if let result, saveToHistory {
                await saveMeetingToHistory(result)
            }
            state.phase = .idle
        }
    }

    func saveMeetingToHistory(_ result: MeetingStopResult) async {
        guard historyService.isEnabled else { return }
        do {
            let meeting = Meeting(
                segments: result.segments,
                duration: result.duration,
                appName: result.appName
            )
            try await historyService.save(.meeting(meeting))

            if !result.micSamples.isEmpty, result.micSampleRate > 0 {
                _ = try await historyService.saveAudioCompressed(
                    samples: result.micSamples, sampleRate: result.micSampleRate,
                    format: settings.audioStorageFormat, for: meeting.id
                )
            }
            if !result.systemSamples.isEmpty, result.systemSampleRate > 0 {
                _ = try await historyService.saveAudioCompressed(
                    samples: result.systemSamples, sampleRate: result.systemSampleRate,
                    format: settings.audioStorageFormat, for: meeting.id
                )
            }
        } catch {
            logger.error("Failed to save meeting: \(error.localizedDescription)")
        }
    }
}
#endif
