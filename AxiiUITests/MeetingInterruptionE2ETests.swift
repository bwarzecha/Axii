//
//  MeetingInterruptionE2ETests.swift
//  AxiiUITests
//
//  Scenario 2 (live half): Escape during a real meeting discards it into
//  Recently Deleted — recoverable, panel gone, no stuck phase.
//  Scenario 6: switching microphones mid-capture conserves the audio
//  recorded before the switch.
//

import XCTest

final class MeetingInterruptionE2ETests: XCTestCase {

    private var session: E2ESession!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        try E2ESession.skipIfScreenLocked()
        try XCTSkipUnless(
            AudioDriver.deviceExists(uid: E2EContract.blackHoleUID),
            "BlackHole 2ch not installed"
        )
        if !HotkeyDriver.isTrusted {
            HotkeyDriver.requestTrustPrompt()
            throw XCTSkip("UI-test runner lacks Accessibility (see README)")
        }
        session = try E2ESession()
        E2ESession.terminateOtherAxiiInstances()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        session?.cleanup()
    }

    // MARK: - Scenario 2: Escape blocked while recording; close discards

    /// A recording meeting is protected from one-keystroke destruction:
    /// Escape is blocked (escapeBehavior == .blockWhileRecording) AND the
    /// close button is not rendered. The real discard path is the
    /// cross-mode takeover dialog — "Discard & Switch" lands the meeting
    /// in Recently Deleted, recoverable.
    func testEscapeIsInertWhileRecordingAndTakeoverDiscardsToTrash() throws {
        app = session.makeApp()
        app.launch()
        XCTAssertTrue(app.statusItems.firstMatch.waitForExistence(timeout: 15))
        sleep(3)

        let entriesBefore = session.historyEntryCount()
        startMeeting()
        sleep(1)
        try AudioDriver.play(
            Fixture.testingOneTwoThree.url,
            toDeviceUID: E2EContract.blackHoleUID
        )

        // Protection 1: Escape must be INERT — still recording after it.
        HotkeyDriver.press(CGKeyCode(53), flags: [])
        sleep(2)
        XCTAssertTrue(
            E2ESession.waitForPanelPhase(app, "recording", timeout: 3),
            "Escape interrupted a recording meeting — the block regressed"
        )

        // Protection 2: no close button is offered while recording.
        let close = app.descendants(matching: .any)
            .matching(identifier: E2EContract.panelCloseID).firstMatch
        XCTAssertFalse(
            close.exists,
            "close button rendered during recording — protection regressed"
        )

        // The real discard path: another mode's hotkey brings up the busy
        // dialog; "Discard & Switch" tears the meeting down into trash.
        HotkeyDriver.press(
            E2EContract.dictationKeyCode, flags: E2EContract.dictationFlags
        )
        let discardButton = app.buttons["Discard & Switch"].firstMatch
        XCTAssertTrue(
            discardButton.waitForExistence(timeout: 8),
            "busy takeover dialog never appeared"
        )
        discardButton.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).click()

        // The discard persists HEADLESS into Recently Deleted.
        guard let entry = session.waitForNewHistoryEntry(
            beyond: entriesBefore, timeout: 60
        ) else {
            return XCTFail("discarded meeting never persisted to history")
        }
        let details = (session.metadata(of: entry)?["details"]
            as? [String: Any])?["data"] as? [String: Any]
        XCTAssertNotNil(
            details?["discardedAt"],
            "taken-over meeting is missing the discardedAt flag"
        )

        // The takeover started dictation; Escape cancels it (alwaysCancel)
        // and the panel must fully resolve — no stuck phase anywhere.
        HotkeyDriver.press(CGKeyCode(53), flags: [])
        let phase = app.descendants(matching: .any)
            .matching(identifier: E2EContract.panelPhaseID).firstMatch
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, phase.exists {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertFalse(phase.exists, "panel still visible after teardown")
    }

    // MARK: - Scenario 6: mic selection through the real picker
    //
    // The product HIDES the picker while recording (canConfigureFooter is
    // false for .recording) — mid-capture switching is a device-event path
    // covered by the in-process interaction fuzzer. The UI-level truth to
    // prove: selecting a mic through the picker actually drives the
    // capture to that device.

    func testMicSelectionThroughPickerDrivesCapture() throws {
        app = session.makeApp(micUID: nil) // unseeded: choose via UI
        app.launch()
        XCTAssertTrue(app.statusItems.firstMatch.waitForExistence(timeout: 15))
        sleep(3)

        let entriesBefore = session.historyEntryCount()

        // Open the meeting panel (idle) and pick BlackHole via the picker.
        HotkeyDriver.press(
            E2EContract.meetingKeyCode, flags: E2EContract.meetingFlags
        )
        let picker = app.descendants(matching: .any)
            .matching(identifier: E2EContract.panelMicPickerID).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 8), "mic picker missing")
        picker.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).click()
        // Keyboard type-ahead: menu-item frames are unreliable (see README).
        app.typeText("BlackHole 2ch")
        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(
            E2ESession.pressPanelStart(app),
            "meeting never reached the recording phase"
        )
        sleep(1)
        try AudioDriver.play(
            Fixture.hopeItWorks.url, toDeviceUID: E2EContract.blackHoleUID
        )
        sleep(1)

        clickPanelAction() // Stop
        guard let entry = session.waitForNewHistoryEntry(
            beyond: entriesBefore, timeout: 60
        ) else { return XCTFail("meeting never reached history") }

        guard let data = try? Data(
            contentsOf: entry.appendingPathComponent("interaction.json")
        ),
            let json = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any],
            let meeting = json["data"] as? [String: Any],
            let segments = meeting["segments"] as? [[String: Any]]
        else { return XCTFail("unreadable meeting entry") }

        let text = segments
            .filter { ($0["isFromMicrophone"] as? Bool) == true }
            .map { ($0["text"] as? String) ?? "" }
            .joined(separator: " ").lowercased()
        for anchor in Fixture.hopeItWorks.anchors {
            XCTAssertTrue(
                text.contains(anchor),
                "pre-switch audio lost anchor '\(anchor)': \"\(text)\""
            )
        }
    }

    // MARK: - Helpers

    private func startMeeting() {
        HotkeyDriver.press(
            E2EContract.meetingKeyCode, flags: E2EContract.meetingFlags
        )
        XCTAssertTrue(
            E2ESession.pressPanelStart(app),
            "meeting never reached the recording phase"
        )
    }

    private func clickPanelAction() {
        let action = app.descendants(matching: .any)
            .matching(identifier: E2EContract.panelActionID).firstMatch
        XCTAssertTrue(
            action.waitForExistence(timeout: 8), "panel action button missing"
        )
        action.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).click()
    }
}
