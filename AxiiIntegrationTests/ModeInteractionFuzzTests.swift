//
//  ModeInteractionFuzzTests.swift
//  AxiiIntegrationTests
//
//  The UI-entry-point schedule fuzzer: seeded random interleavings of REAL
//  user interactions (hotkey, Escape, panel buttons, mic switches, device
//  events, session errors, config edits, timer fires) against the mode
//  runtime, with every async dependency suspended on harness gates.
//
//  Two profiles:
//  - noCancel: the user never cancels — every recorded sample must reach
//    the transcriber. The strictest silent-data-loss detector.
//  - fullChaos: everything including cancels — structural invariants (no
//    unowned capture, no stuck phase, no leaked or unaccounted audio).
//
//  A failing seed is a reproducible bug report:
//    AXII_FUZZ_ITERATIONS=10000 for deep runs (see Scripts/reliability-suite.sh)
//

import XCTest
@testable import Axii

@MainActor
final class ModeInteractionFuzzTests: XCTestCase {

    private var settings: SettingsService!
    private var historyService: HistoryService!
    private var tempDir: URL!

    override func setUp() async throws {
        settings = SettingsService(
            defaults: UserDefaults(suiteName: "ModeFuzz-\(UUID().uuidString)")!
        )
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AxiiModeFuzz-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        historyService = HistoryService(historyDirectory: tempDir)
    }

    override func tearDown() async throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        settings = nil
        historyService = nil
        tempDir = nil
    }

    private var iterations: Int {
        ProcessInfo.processInfo.environment["AXII_FUZZ_ITERATIONS"]
            .flatMap(Int.init) ?? 300
    }

    func testNoCancelProfile_RecordedAudioAlwaysReachesTranscriber() async throws {
        try await runFuzz(profile: .noCancel, seedBase: 10_000)
    }

    func testFullChaosProfile_StructuralInvariantsHold() async throws {
        try await runFuzz(profile: .fullChaos, seedBase: 20_000)
    }

    /// The meeting surface: real adapter + real handler + real capture
    /// session over gate-controlled chaos fakes, with persistence outcomes
    /// (success / failure / history-off no-write) seeded per call.
    func testMeetingSurface_StructuralInvariantsHold() async throws {
        for i in 0..<iterations {
            let seed: UInt64 = 30_000 &+ UInt64(i)
            let driver = MeetingModeFuzzDriver(
                seed: seed,
                settings: settings,
                historyService: historyService
            )
            await driver.runSchedule(steps: 40)
            driver.checkInvariants()

            let violations = driver.violations.violations
            if !violations.isEmpty {
                XCTFail(
                    "seed \(seed) [meeting]: "
                    + violations.joined(separator: " | ")
                    + "\nactions: "
                    + driver.actionLog.joined(separator: " → ")
                )
                return
            }
        }
    }

    private func runFuzz(
        profile: ModeFuzzDriver.Profile,
        seedBase: UInt64
    ) async throws {
        for i in 0..<iterations {
            let seed = seedBase &+ UInt64(i)
            let driver = ModeFuzzDriver(
                seed: seed,
                profile: profile,
                settings: settings,
                historyService: historyService
            )
            await driver.runSchedule(steps: 40)
            await driver.checkInvariants()

            let violations = driver.violations.violations
            if !violations.isEmpty {
                XCTFail(
                    "seed \(seed) [\(profile)]: "
                    + violations.joined(separator: " | ")
                    + "\nactions: "
                    + driver.actionLog.joined(separator: " → ")
                )
                return
            }
        }
    }
}
