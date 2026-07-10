//
//  ModeFeatureMeeting.swift
//  Axii
//
//  Long-running meeting logic for ModeFeature.
//  Crash recovery lives in ModeFeatureMeetingRecovery.swift.
//  Extracted to keep each file under 300 lines.
//

#if os(macOS)
import AppKit
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
        // Guarded internally: a deferred edit never applies while the
        // error-salvage path below still holds a live capture.
        applyPendingConfigIfIdle()
        guard let handler = meetingHandler else {
            state.phase = .error("Meeting handler not configured")
            return
        }
        if handler.hasLiveCapture, case .error = state.phase {
            // Retry after an error: the wounded session is salvaged to
            // history first — cancel-on-reentry would destroy it.
            let salvage = stopMeeting(saveToHistory: true)
            Task { @MainActor in
                await salvage?.value
                // The salvage can run for minutes. If a takeover or Escape
                // closed this panel meanwhile, the retry no longer owns
                // anything — restarting would put a hot capture behind a
                // closed panel with no way to reach it.
                guard self.isActive, self.state.phase == .idle,
                      !handler.hasLiveCapture else { return }
                await handler.start()
            }
            return
        }
        guard confirmStartWithoutHistory() else { return }
        // The confirm dialog can sit open indefinitely while hotkeys keep
        // firing (Carbon events deliver during modal sessions). Re-validate
        // before committing: a stale "Record Anyway" must neither
        // cancel-on-reentry a capture that went live during the modal nor
        // start one behind a panel a takeover has closed.
        guard isActive, !handler.hasLiveCapture,
              state.phase == .idle || state.phase == .preparing else { return }
        // Freeze the persistence contract for this meeting. Flipping the
        // history setting mid-recording must not change where an hour of
        // audio ends up — least of all silently.
        meetingHistoryEnabledAtStart = historyService.isEnabled
        pendingMeetingExport = nil
        Task { await handler.start() }
    }

    /// History off means this meeting will exist only in the panel. Say so
    /// before an hour is recorded against that assumption, not after.
    private func confirmStartWithoutHistory() -> Bool {
        guard !historyService.isEnabled else { return true }
        let alert = NSAlert()
        alert.messageText = "History is turned off"
        alert.informativeText = """
            This meeting will not be saved to history. You can copy the \
            transcript when it finishes, but it will be lost when the panel closes.
            """
        alert.addButton(withTitle: "Record Anyway")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }

    @discardableResult
    func stopMeeting(saveToHistory: Bool) -> Task<Void, Never>? {
        guard let handler = meetingHandler else { return nil }
        if saveToHistory, let inFlight = meetingStopTask {
            // Coalesce: a double-tap joins the running save instead of
            // issuing a second stop against an already-detached capture.
            return inFlight
        }
        meetingStopGeneration += 1
        let gen = meetingStopGeneration
        // Snapshot the streamed transcript SYNCHRONOUSLY: when this stop is
        // teardown's error-salvage, state.reset() runs before the task below
        // does, and the handler's own fallback would read empty segments —
        // losing the only transcript in existence if finalization also fails.
        let streamedSegments = state.segments
        let task = Task { @MainActor in
            defer { self.meetingStopTask = nil }
            var result = await handler.stop(saveToHistory: saveToHistory)
            if saveToHistory, var payload = result,
               payload.segments.isEmpty, !streamedSegments.isEmpty {
                payload.segments = streamedSegments
                result = payload
            }
            if let result, saveToHistory {
                guard await persistMeeting(result, generation: gen) else { return }
            }
            // Resolve .processing to idle only when BOTH hold: the phase is
            // still processing AND no newer stop was issued — a newer stop
            // occupies .processing itself, and a phase check alone would
            // stomp it mid-finalize.
            if state.phase == .processing, gen == meetingStopGeneration {
                state.phase = .idle
            }
            // The save is durable and the capture detached — an edit made
            // mid-meeting can land now (internally guarded against a newer
            // session that is already recording again).
            self.applyPendingConfigIfIdle()
        }
        if saveToHistory { meetingStopTask = task }
        return task
    }

    /// Persist a finished meeting. Returns false when the caller must leave
    /// the phase alone (an error or an export state was published instead).
    private func persistMeeting(
        _ result: MeetingPersistencePayload,
        generation gen: Int
    ) async -> Bool {
        // Honor the contract this meeting was recorded under, not whatever
        // the toggle says now.
        guard meetingHistoryEnabledAtStart else {
            offerExport(of: result, generation: gen)
            return false
        }
        do {
            let persisted = try await meetingPersistence.persist(
                payload: result,
                audioFormat: settings.audioStorageFormat
            )
            guard persisted != nil else {
                // History was switched off between start and this write.
                // Nothing reached disk — keep the artifacts and hand the
                // user the transcript rather than pretending it was saved.
                offerExport(of: result, generation: gen)
                return false
            }
        } catch {
            logger.error("Failed to save meeting: \(error.localizedDescription)")
            // Surface the failure, and deliberately do NOT clear the recovery
            // artifacts: the meeting is not durably saved yet, so it must
            // remain recoverable. Both guards matter: a newer stop's
            // .processing must not be stomped by a stale error either.
            if state.phase == .processing, gen == meetingStopGeneration {
                state.phase = .error("Failed to save meeting")
            }
            return false
        }
        // Commit point: the meeting is durably saved. Recovery data has
        // served its purpose.
        result.recoveryArtifacts?.clear()
        return true
    }

    /// Park an unsaved meeting in `.done` with its transcript intact so the
    /// user can copy it out. Recovery artifacts stay on disk until the panel
    /// closes — the transcript is not durably stored anywhere else.
    private func offerExport(
        of result: MeetingPersistencePayload,
        generation gen: Int
    ) {
        guard gen == meetingStopGeneration else { return }
        if !isActive {
            // The panel closed while the salvage ran. An offer parked in a
            // closed panel is worse than none: the next hotkey press would
            // silently clipboard-and-destroy it. Re-present the panel when
            // nothing else is mid-capture; otherwise leave the artifacts on
            // disk (recoverable if history returns, expired otherwise)
            // rather than hijack a live recording's UI.
            guard context?.busyFeature?() == nil else { return }
            isActive = true
            context?.onActivate?(self)
        }
        pendingMeetingExport = result
        state.segments = result.segments
        state.duration = result.duration
        state.needsManualCopy = !result.segments.isEmpty
        state.manualCopyText = Self.transcriptText(from: result.segments)
        state.phase = .done
    }

    /// The transcript a user would expect on the clipboard: speaker-attributed
    /// lines in spoken order.
    static func transcriptText(from segments: [MeetingSegment]) -> String {
        segments
            .sorted { $0.startTime < $1.startTime }
            .map { segment in
                let speaker = segment.speakerId.isEmpty ? "" : "\(segment.speakerId): "
                return "\(speaker)\(segment.text)"
            }
            .joined(separator: "\n")
    }

    /// Discard an unsaved meeting's artifacts once the user has had their
    /// chance to export it. Called from teardown, never from the save path.
    func releasePendingMeetingExport() {
        guard let pending = pendingMeetingExport else { return }
        pendingMeetingExport = nil
        pending.recoveryArtifacts?.clear()
    }
}
#endif
