//
//  MeetingCaptureSupport.swift
//  Axii
//
//  Small collaborators owned by MeetingCaptureSession: serialized execution
//  of app/mic switches, and the 1-second recording duration ticker.
//

#if os(macOS)
import Foundation

/// Serializes app/mic switch operations so they can never interleave with
/// each other — and lets stop/cancel wait for the chain to settle before
/// tearing audio down (interrupting a switch's stop-and-restart dance would
/// orphan the restarted audio session).
@MainActor
final class MeetingSwitchSerializer {
    // Always holds the newest switch and is never cleared: awaiting an
    // already-completed task is free, and clearing it from inside the chain
    // would race newer entries out of the slot.
    private var pending: Task<Void, Never>?

    var hasPending: Bool { pending != nil }

    /// Snapshot of the newest switch at this instant. Callers that defer
    /// work must await THIS task, not settle() later — by then a newer
    /// session's switches may have chained onto the slot, delaying the
    /// deferred work arbitrarily.
    var currentPending: Task<Void, Never>? { pending }

    @discardableResult
    func run(_ operation: @escaping () async -> Void) -> Task<Void, Never> {
        let previous = pending
        let task = Task {
            await previous?.value
            await operation()
        }
        pending = task
        return task
    }

    /// Waits until every enqueued switch has finished.
    func settle() async {
        await pending?.value
    }
}

/// Wall-clock duration ticker for an active recording. Owns the Timer so the
/// session cannot leak one across start/stop cycles.
@MainActor
final class MeetingDurationTicker {
    private var timer: Timer?
    private(set) var duration: TimeInterval = 0
    // A tick Task enqueued just before invalidation would otherwise land
    // after reset() and write the OLD recording's elapsed time.
    private var run = 0

    var onTick: ((TimeInterval) -> Void)?

    /// Stops any previous timer and zeroes the duration — called at session
    /// start so a detach during a still-starting session reads 0, not the
    /// previous recording's value.
    func reset() {
        stop()
        duration = 0
    }

    func start() {
        run += 1
        let currentRun = run
        let startTime = Date()
        timer = Timer.scheduledTimer(
            withTimeInterval: 1.0,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.run == currentRun else { return }
                self.duration = Date().timeIntervalSince(startTime)
                self.onTick?(self.duration)
            }
        }
    }

    func stop() {
        run += 1
        timer?.invalidate()
        timer = nil
    }

    deinit {
        timer?.invalidate()
    }
}
#endif
