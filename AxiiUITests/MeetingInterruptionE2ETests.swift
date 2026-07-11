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

    // MARK: - Scenario 2: Escape discards into Recently Deleted

    func testEscapeMidMeetingLandsInRecentlyDeleted() throws {
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

        // Escape: the registered panel-scoped hotkey — a bare key, no
        // modifiers needed.
        HotkeyDriver.press(CGKeyCode(53), flags: [])

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
            "escaped meeting is missing the discardedAt flag"
        )

        // No stuck phase: the panel is gone (its elements with it).
        let phase = app.descendants(matching: .any)
            .matching(identifier: E2EContract.panelPhaseID).firstMatch
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, phase.exists {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertFalse(phase.exists, "panel still visible after Escape")
    }

    // MARK: - Scenario 6: mic switch mid-capture conserves audio

    func testMicSwitchMidCaptureKeepsPreSwitchAudio() throws {
        try XCTSkipUnless(
            AudioDriver.deviceExists(uid: E2EContract.builtInMicUID),
            "no built-in microphone to switch to"
        )
        app = session.makeApp()
        app.launch()
        XCTAssertTrue(app.statusItems.firstMatch.waitForExistence(timeout: 15))
        sleep(3)

        let entriesBefore = session.historyEntryCount()
        startMeeting()
        sleep(1)
        try AudioDriver.play(
            Fixture.hopeItWorks.url, toDeviceUID: E2EContract.blackHoleUID
        )

        // Switch to the built-in mic through the real picker.
        let picker = app.descendants(matching: .any)
            .matching(identifier: E2EContract.panelMicPickerID).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "mic picker missing")
        picker.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).click()
        // Keyboard type-ahead: menu-item frames are unreliable (see README).
        app.typeText("MacBook Pro Microphone")
        app.typeKey(.return, modifierFlags: [])

        sleep(2) // capture continues on the new device (ambient)

        // Stop and verify the pre-switch fixture survived the switch.
        clickPanelAction()
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
        clickPanelAction()
        XCTAssertTrue(
            E2ESession.waitForPanelPhase(app, "recording", timeout: 25),
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
