//
//  MeetingE2ETests.swift
//  AxiiUITests
//
//  Scenario 3: meeting happy path — hotkey opens the panel, Start is a
//  real button click, capture runs from BlackHole, Stop persists a meeting
//  whose mic-attributed segments carry the fixture's words.
//
//  Scenario 5: kill -9 mid-meeting — a fresh launch recovers the meeting
//  into history from the scratch recovery artifacts.
//

import XCTest

final class MeetingE2ETests: XCTestCase {

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

    // MARK: - Scenario 3: happy path with mic attribution

    func testMeetingCapturesMicFixtureIntoAttributedSegments() throws {
        app = session.makeApp()
        app.launch()
        XCTAssertTrue(app.statusItems.firstMatch.waitForExistence(timeout: 15))
        sleep(3)

        let entriesBefore = session.historyEntryCount()
        openMeetingPanelAndStart()

        sleep(1)
        try AudioDriver.play(
            Fixture.hopeItWorks.url, toDeviceUID: E2EContract.blackHoleUID
        )
        sleep(1)

        // Stop via the footer action button (now "Stop").
        clickPanelAction()

        guard let entry = session.waitForNewHistoryEntry(
            beyond: entriesBefore, timeout: 60
        ) else { return XCTFail("meeting never reached history") }

        let segments = micSegments(of: entry)
        XCTAssertFalse(segments.isEmpty, "no microphone-attributed segments")
        let text = segments.map { ($0["text"] as? String) ?? "" }
            .joined(separator: " ").lowercased()
        for anchor in Fixture.hopeItWorks.anchors {
            XCTAssertTrue(
                text.contains(anchor),
                "mic segments lost anchor '\(anchor)': \"\(text)\""
            )
        }
    }

    // MARK: - Scenario 5: kill -9 recovery

    func testKillNineMidMeetingRecoversOnNextLaunch() throws {
        app = session.makeApp()
        app.launch()
        XCTAssertTrue(app.statusItems.firstMatch.waitForExistence(timeout: 15))
        sleep(3)

        openMeetingPanelAndStart()
        sleep(1)
        try AudioDriver.play(
            Fixture.testingOneTwoThree.url,
            toDeviceUID: E2EContract.blackHoleUID
        )
        // Give the autosave its immediate first flush a moment to land.
        sleep(2)

        // The crash: no cleanup, no finalize, no persistence.
        killAppHard()

        XCTAssertTrue(
            recoveryArtifactsExist(),
            "no recovery artifacts on disk after kill -9 — nothing to recover"
        )

        // Next launch recovers into history.
        let entriesBefore = session.historyEntryCount()
        app = session.makeApp()
        app.launch()
        XCTAssertTrue(app.statusItems.firstMatch.waitForExistence(timeout: 15))

        guard let entry = session.waitForNewHistoryEntry(
            beyond: entriesBefore, timeout: 90
        ) else {
            return XCTFail("crashed meeting never recovered into history")
        }
        let type = session.metadata(of: entry)?["type"] as? String
        XCTAssertEqual(type, "meeting", "recovered entry is not a meeting")
        let stats = try session.storedAudioStats(of: entry)
        XCTAssertGreaterThan(
            stats.rms, 0.005, "recovered meeting audio is silence"
        )
    }

    // MARK: - Helpers

    /// Meeting hotkey shows the panel idle; Start is a real button press
    /// with a phase-verified retry. Blocks until recording — audio played
    /// into BlackHole while the capture is preparing is dropped unheard.
    private func openMeetingPanelAndStart() {
        HotkeyDriver.press(
            E2EContract.meetingKeyCode, flags: E2EContract.meetingFlags
        )
        XCTAssertTrue(
            E2ESession.pressPanelStart(app),
            "meeting never reached the recording phase"
        )
    }

    /// The footer action button on a non-activating panel: isHittable lies
    /// for these panels, so wait on existence and click by coordinate.
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

    private func micSegments(of entry: URL) -> [[String: Any]] {
        guard let data = try? Data(
            contentsOf: entry.appendingPathComponent("interaction.json")
        ),
            let json = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any],
            let meeting = json["data"] as? [String: Any],
            let segments = meeting["segments"] as? [[String: Any]]
        else { return [] }
        return segments.filter { ($0["isFromMicrophone"] as? Bool) == true }
    }

    private func killAppHard() {
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: E2EContract.bundleID
        )
        for instance in running {
            kill(instance.processIdentifier, SIGKILL)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
    }

    private func recoveryArtifactsExist() -> Bool {
        let autosave = session.recoveryDir
            .appendingPathComponent("meeting_autosave.json")
        return FileManager.default.fileExists(atPath: autosave.path)
    }
}
