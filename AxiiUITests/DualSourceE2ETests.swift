//
//  DualSourceE2ETests.swift
//  AxiiUITests
//
//  Scenario 4: a meeting captures the MICROPHONE and APPLICATION audio
//  simultaneously, and attributes each to the right side.
//
//  Isolation design (probed empirically): ScreenCaptureKit in All-Apps
//  mode captures ANY process's audio regardless of its output device — so
//  the runner's own playback always lands in the system track. The mic
//  track is isolated by giving it its OWN loopback device:
//    - mic fixture A -> BlackHole 16ch (the meeting's selected mic)
//    - system fixture B -> BlackHole 2ch (no one records its input side;
//      it reaches the meeting ONLY through ScreenCaptureKit)
//  Assertions: mic segments carry A's anchors and none of B's; system
//  segments carry B's anchors. (A also appearing in the system track is
//  expected — the runner plays both — and asserted-irrelevant.)
//
//  Prerequisite beyond the suite's usual two:
//    brew install --cask blackhole-16ch && sudo killall coreaudiod
//

import XCTest

final class DualSourceE2ETests: XCTestCase {

    private static let mic16UID = "BlackHole16ch_UID"

    private var session: E2ESession!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(
            AudioDriver.deviceExists(uid: Self.mic16UID),
            """
            Dual-source needs a SECOND loopback device:
            brew install --cask blackhole-16ch && sudo killall coreaudiod
            """
        )
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
        let micFixture = Fixture.hopeItWorks          // side A
        let systemFixture = Fixture.testingOneTwoThree // side B

        app = session.makeApp(micUID: Self.mic16UID)
        app.launch()
        XCTAssertTrue(app.statusItems.firstMatch.waitForExistence(timeout: 15))
        sleep(3)

        let entriesBefore = session.historyEntryCount()
        HotkeyDriver.press(
            E2EContract.meetingKeyCode, flags: E2EContract.meetingFlags
        )
        XCTAssertTrue(
            E2ESession.pressPanelStart(app),
            "meeting never reached the recording phase"
        )
        sleep(1)

        // Sequential playback keeps the transcripts unambiguous.
        try AudioDriver.play(micFixture.url, toDeviceUID: Self.mic16UID)
        sleep(1)
        try AudioDriver.play(
            systemFixture.url, toDeviceUID: E2EContract.blackHoleUID
        )
        sleep(1)

        // Stop and let finalization persist.
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
        for anchor in systemFixture.anchors where !micFixture.anchors.contains(anchor) {
            XCTAssertFalse(
                micText.contains(anchor),
                "system audio bled into the MIC track: '\(anchor)'"
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
