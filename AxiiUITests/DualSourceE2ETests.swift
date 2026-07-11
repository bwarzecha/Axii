//
//  DualSourceE2ETests.swift
//  AxiiUITests
//
//  Scenario 4: a meeting captures the MICROPHONE and APPLICATION audio
//  simultaneously and attributes each to the right side.
//
//  Isolation design: the two fixtures take DIFFERENT paths into the app.
//    - mic fixture A -> BlackHole 2ch (the meeting's mic) — loopback in
//    - app fixture B -> the default output — its ONLY path into the
//      meeting is ScreenCaptureKit (All-Apps mode hears the runner play
//      it, regardless of output device); it must NOT play into BlackHole
//      or it would loop into the mic track
//  Assertions: mic track carries A and none of B (device isolation);
//  system track carries B (the app-audio path works). A also appearing
//  in the system track is expected — the runner plays both.
//  (A specific-app picker filter was tried and dropped: windowless
//  processes like the test runner don't appear in SCShareableContent.)
//
//  Cost: fixture B is briefly AUDIBLE through the default output.
//

import XCTest

final class DualSourceE2ETests: XCTestCase {

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

    func testMeetingAttributesMicAndAppAudioToTheRightSides() throws {
        let micFixture = Fixture.hopeItWorks           // side A
        let systemFixture = Fixture.testingOneTwoThree // side B

        app = session.makeApp()
        app.launch()
        XCTAssertTrue(app.statusItems.firstMatch.waitForExistence(timeout: 15))
        sleep(3)

        let entriesBefore = session.historyEntryCount()

        // Open the meeting panel idle; default All-Apps system capture.
        HotkeyDriver.press(
            E2EContract.meetingKeyCode, flags: E2EContract.meetingFlags
        )
        XCTAssertTrue(
            E2ESession.pressPanelStart(app),
            "meeting never reached the recording phase"
        )
        sleep(1)

        // Sequential playback keeps the transcripts unambiguous.
        try AudioDriver.play(
            micFixture.url, toDeviceUID: E2EContract.blackHoleUID
        )
        sleep(1)
        try AudioDriver.playToDefaultOutput(systemFixture.url) // audible
        sleep(1)

        let action = app.descendants(matching: .any)
            .matching(identifier: E2EContract.panelActionID).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        action.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).click()

        guard let entry = session.waitForNewHistoryEntry(
            beyond: entriesBefore, timeout: 90
        ) else { return XCTFail("dual-source meeting never reached history") }

        let (micText, systemText) = transcripts(of: entry)
        for anchor in micFixture.anchors {
            XCTAssertTrue(
                micText.contains(anchor),
                "mic track lost its anchor '\(anchor)': \"\(micText)\""
            )
        }
        for anchor in systemFixture.anchors
        where !micFixture.anchors.contains(anchor) {
            XCTAssertFalse(
                micText.contains(anchor),
                "app audio bled into the MIC track: '\(anchor)'"
            )
            XCTAssertTrue(
                systemText.contains(anchor),
                "system track lost its anchor '\(anchor)': \"\(systemText)\""
            )
        }
    }

    private func transcripts(of entry: URL) -> (mic: String, system: String) {
        guard let data = try? Data(
            contentsOf: entry.appendingPathComponent("interaction.json")
        ),
            let json = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any],
            let meeting = json["data"] as? [String: Any],
            let segments = meeting["segments"] as? [[String: Any]]
        else { return ("", "") }
        func joined(fromMic: Bool) -> String {
            segments
                .filter { ($0["isFromMicrophone"] as? Bool) == fromMic }
                .map { ($0["text"] as? String) ?? "" }
                .joined(separator: " ").lowercased()
        }
        return (joined(fromMic: true), joined(fromMic: false))
    }
}
