//
//  MeetingSleepWakeTests.swift
//  AxiiIntegrationTests
//
//  Unit coverage for the sleep/wake collaborators:
//  - MeetingDurationTicker excludes paused (slept) time from the duration
//  - MeetingPowerMonitor observes sleep/wake only while recording
//

import AppKit
import XCTest
@testable import Axii

@MainActor
final class MeetingSleepWakeTests: XCTestCase {

    // MARK: - Duration Ticker

    /// The core sleep-skew claim: while paused, wall time passes but the
    /// duration does not move — deterministic, no timer exists to tick.
    func testTickerExcludesPausedTime() async throws {
        let ticker = MeetingDurationTicker(interval: 0.02)
        ticker.reset()
        ticker.start()

        // Let at least one tick land so there is banked time to protect.
        var spins = 0
        while ticker.duration == 0, spins < 10_000 {
            try await Task.sleep(for: .milliseconds(5))
            spins += 1
        }
        ticker.pause()
        let atPause = ticker.duration
        XCTAssertGreaterThan(atPause, 0)

        // Wall clock races ahead; the paused ticker must not.
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(ticker.duration, atPause,
                       "Paused (slept) time must never be counted")

        ticker.resume()
        spins = 0
        while ticker.duration <= atPause, spins < 10_000 {
            try await Task.sleep(for: .milliseconds(5))
            spins += 1
        }
        ticker.stop()
        XCTAssertGreaterThan(ticker.duration, atPause,
                             "Counting resumes at wake")
    }

    func testTickerResumeWithoutPauseIsNoOp() async throws {
        let ticker = MeetingDurationTicker(interval: 0.02)
        ticker.reset()
        ticker.start()
        // A spurious didWake while running must not reset the segment or
        // double-start timers.
        ticker.resume()
        var spins = 0
        while ticker.duration == 0, spins < 10_000 {
            try await Task.sleep(for: .milliseconds(5))
            spins += 1
        }
        ticker.stop()
        XCTAssertGreaterThan(ticker.duration, 0)
    }

    func testTickerResetZeroesBankedTime() async throws {
        let ticker = MeetingDurationTicker(interval: 0.02)
        ticker.start()
        var spins = 0
        while ticker.duration == 0, spins < 10_000 {
            try await Task.sleep(for: .milliseconds(5))
            spins += 1
        }
        ticker.pause()
        XCTAssertGreaterThan(ticker.duration, 0)

        ticker.reset()
        XCTAssertEqual(ticker.duration, 0,
                       "A new session must not inherit the previous one's banked time")
    }

    // MARK: - Power Monitor

    func testPowerMonitorFiresCallbacksOnlyWhileRecording() async throws {
        let center = NotificationCenter()
        let monitor = MeetingPowerMonitor(center: center)
        var sleeps = 0
        var wakes = 0
        monitor.onWillSleep = { sleeps += 1 }
        monitor.onDidWake = { wakes += 1 }

        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(sleeps, 0, "Not observing before beginRecording")

        monitor.beginRecording(reason: "test")
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        var spins = 0
        while (sleeps < 1 || wakes < 1), spins < 10_000 {
            await Task.yield()
            spins += 1
        }
        XCTAssertEqual(sleeps, 1)
        XCTAssertEqual(wakes, 1)

        monitor.endRecording()
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(sleeps, 1, "Observers released at endRecording")
    }

    func testPowerMonitorBeginTwiceDoesNotDoubleObserve() async throws {
        let center = NotificationCenter()
        let monitor = MeetingPowerMonitor(center: center)
        var sleeps = 0
        monitor.onWillSleep = { sleeps += 1 }

        monitor.beginRecording(reason: "test")
        monitor.beginRecording(reason: "test")
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        var spins = 0
        while sleeps < 1, spins < 10_000 {
            await Task.yield()
            spins += 1
        }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(sleeps, 1, "Re-begin replaces observers, never stacks them")
        monitor.endRecording()
    }
}
