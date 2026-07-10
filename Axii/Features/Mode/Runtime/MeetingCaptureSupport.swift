//
//  MeetingCaptureSupport.swift
//  Axii
//
//  Small collaborators owned by MeetingCaptureSession: serialized execution
//  of app/mic switches, and the 1-second recording duration ticker.
//

#if os(macOS)
import AppKit
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

/// Duration ticker for an active recording. Owns the Timer so the session
/// cannot leak one across start/stop cycles.
///
/// Counts elapsed time in RESUMABLE SEGMENTS, not raw wall clock: the wall
/// clock keeps running through system sleep while the audio does not, so an
/// unpaused ticker would overstate an hour-long meeting by every minute the
/// lid was closed. pause()/resume() bracket sleep; duration tracks what was
/// actually captured.
@MainActor
final class MeetingDurationTicker {
    private var timer: Timer?
    private(set) var duration: TimeInterval = 0
    // A tick Task enqueued just before invalidation would otherwise land
    // after reset() and write the OLD recording's elapsed time.
    private var run = 0
    /// Time banked by completed segments (before the last pause).
    private var accumulated: TimeInterval = 0
    /// Start of the currently running segment; nil while paused/stopped.
    private var segmentStart: Date?
    private let interval: TimeInterval

    var onTick: ((TimeInterval) -> Void)?

    init(interval: TimeInterval = 1.0) {
        self.interval = interval
    }

    /// Stops any previous timer and zeroes the duration — called at session
    /// start so a detach during a still-starting session reads 0, not the
    /// previous recording's value.
    func reset() {
        stop()
        duration = 0
        accumulated = 0
    }

    func start() {
        timer?.invalidate()
        run += 1
        let currentRun = run
        segmentStart = Date()
        timer = Timer.scheduledTimer(
            withTimeInterval: interval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.run == currentRun else { return }
                self.duration = self.accumulated
                    + (self.segmentStart.map { Date().timeIntervalSince($0) } ?? 0)
                self.onTick?(self.duration)
            }
        }
    }

    /// The system is going down: bank the running segment and stop counting.
    /// Idempotent — a second willSleep cannot double-bank.
    func pause() {
        if let start = segmentStart {
            accumulated += Date().timeIntervalSince(start)
            duration = accumulated
        }
        segmentStart = nil
        run += 1
        timer?.invalidate()
        timer = nil
    }

    /// Continue counting after a wake. A wake without a matching pause
    /// (spurious notification while running) is a no-op.
    func resume() {
        guard segmentStart == nil, timer == nil else { return }
        start()
    }

    func stop() {
        segmentStart = nil
        run += 1
        timer?.invalidate()
        timer = nil
    }

    deinit {
        timer?.invalidate()
    }
}

/// Keeps a meeting recording honest across system power transitions:
/// prevents IDLE sleep while recording (a meeting is foreground work even
/// when nobody touches the keyboard), and surfaces willSleep/didWake so the
/// session can flush its recovery autosave and pause the duration ticker.
/// Lid-close sleep still happens — that is the user's call to make.
@MainActor
final class MeetingPowerMonitor {
    private var activityToken: NSObjectProtocol?
    private var observers: [NSObjectProtocol] = []
    private let center: NotificationCenter

    var onWillSleep: (() -> Void)?
    var onDidWake: (() -> Void)?

    /// Production observes NSWorkspace's center (where sleep/wake arrive);
    /// tests inject a private one and post the same notification names.
    init(center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.center = center
    }

    func beginRecording(reason: String) {
        endRecording()
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled],
            reason: reason
        )
        // queue: nil = the block runs SYNCHRONOUSLY on the posting thread.
        // NSWorkspace posts sleep/wake on the main thread, and synchronous
        // execution is the point: the autosave flush must COMPLETE before
        // the willSleep handler returns — a Task hop could still be queued
        // when the process suspends, and if the battery dies asleep the
        // flush never happens at all. (It would also bank the whole sleep
        // interval into the duration ticker at wake.)
        observers = [
            center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil, queue: nil
            ) { [weak self] _ in
                Self.runOnMain { self?.onWillSleep?() }
            },
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil, queue: nil
            ) { [weak self] _ in
                Self.runOnMain { self?.onDidWake?() }
            },
        ]
    }

    /// Synchronous when already on the main thread (the NSWorkspace case);
    /// falls back to a hop only for unexpected off-main delivery.
    private static func runOnMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            Task { @MainActor in body() }
        }
    }

    func endRecording() {
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
        }
        activityToken = nil
        observers.forEach { center.removeObserver($0) }
        observers = []
    }

    deinit {
        // Belt and braces: normal teardown goes through endRecording() at
        // capture detach. NotificationCenter removal is thread-safe.
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
        }
        observers.forEach { center.removeObserver($0) }
    }
}
#endif
