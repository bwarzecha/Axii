//
//  DictationE2ETests.swift
//  AxiiUITests
//
//  Scenario 1: the dictation happy path against the REAL app — synthetic
//  global hotkey, real capture from BlackHole, real Parakeet, history
//  assertion on all three planes (data, UI state, artifacts).
//

import XCTest

final class DictationE2ETests: XCTestCase {

    private var session: E2ESession!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(
            AudioDriver.deviceExists(uid: E2EContract.blackHoleUID),
            """
            BlackHole 2ch not installed. Run:
            brew install --cask blackhole-2ch && sudo killall coreaudiod
            """
        )
        if !HotkeyDriver.isTrusted {
            // Surfaces the runner's identity in System Settings (unchecked).
            HotkeyDriver.requestTrustPrompt()
            throw XCTSkip(
                """
                The UI-test runner is not Accessibility-trusted. A new entry
                was just added to System Settings > Privacy & Security >
                Accessibility — toggle it ON and re-run.
                """
            )
        }
        session = try E2ESession()
        E2ESession.terminateOtherAxiiInstances()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        session?.cleanup()
    }

    func testDictationHappyPathLandsFixtureInHistory() throws {
        app = session.makeApp()
        app.launch()

        // Readiness beacon: the menu bar item exists once the app is up;
        // hotkeys register shortly after feature activation.
        XCTAssertTrue(
            app.statusItems.firstMatch.waitForExistence(timeout: 15),
            "menu bar item never appeared"
        )
        sleep(3)

        let entriesBefore = session.historyEntryCount()
        let fixture = Fixture.testingOneTwoThree
        let captureStart = Date()

        // Start recording (Control+Shift+Space in a scratch environment).
        HotkeyDriver.press(
            E2EContract.dictationKeyCode, flags: E2EContract.dictationFlags
        )

        // UI plane: recording UI is up. Which element renders depends on
        // layout (compact shows stop+level; auto status rows show the mic
        // picker instead of the phase while recording) — accept any.
        XCTAssertTrue(
            waitForAnyElement(
                identifiers: [
                    E2EContract.panelAudioLevelID,
                    E2EContract.panelPhaseID,
                    E2EContract.panelStopID,
                    E2EContract.panelActionID,
                ],
                timeout: 8
            ),
            "no panel element appeared — hotkey lost or panel dead"
        )

        sleep(1) // capture arming preroll
        try AudioDriver.play(fixture.url, toDeviceUID: E2EContract.blackHoleUID)
        sleep(1) // tail padding

        // Stop.
        HotkeyDriver.press(
            E2EContract.dictationKeyCode, flags: E2EContract.dictationFlags
        )
        let captureWindow = Date().timeIntervalSince(captureStart)

        // Data plane: a history entry appears with the fixture's anchors.
        guard let entry = session.waitForNewHistoryEntry(
            beyond: entriesBefore, timeout: 45
        ) else {
            return XCTFail("no history entry appeared within 45s of stop")
        }
        let preview = (session.metadata(of: entry)?["preview"] as? String) ?? ""
        for anchor in fixture.anchors {
            XCTAssertTrue(
                preview.lowercased().contains(anchor),
                "transcript lost anchor '\(anchor)': \"\(preview)\""
            )
        }

        // Artifact plane: stored audio has signal and a sane duration.
        // Duration ~2x the capture window is the channel-layout corruption
        // signature (the stereo bug this suite exists to catch).
        let stats = try session.storedAudioStats(of: entry)
        XCTAssertGreaterThan(
            stats.rms, 0.005, "stored audio is silence — capture path broken"
        )
        XCTAssertGreaterThanOrEqual(
            stats.duration, fixture.duration - 0.5,
            "stored audio shorter than the fixture — samples were dropped"
        )
        XCTAssertLessThan(
            stats.duration, captureWindow * 1.5 + 2,
            "stored audio far exceeds the capture window — duplicated samples"
        )
    }

    /// True once any of the identified elements exists — polls across ids
    /// because different panel layouts render different subsets.
    private func waitForAnyElement(
        identifiers: [String], timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for identifier in identifiers {
                let element = app.descendants(matching: .any)
                    .matching(identifier: identifier).firstMatch
                if element.exists { return true }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return false
    }
}
