//
//  DiscardRecoveryE2ETests.swift
//  AxiiUITests
//
//  Scenario: the user's bug report — "accidentally hit ESC in dictate
//  mode and the recording is lost". Real hotkey starts a real capture
//  from BlackHole; a system-wide Escape (the accidental press, swallowed
//  globally while the panel is up) discards it. The recording must land
//  in Recently Deleted with its audio and (real Parakeet) transcript,
//  and Restore through the real History window must bring it back.
//

import XCTest

final class DiscardRecoveryE2ETests: XCTestCase {

    private var session: E2ESession!
    private var app: XCUIApplication!

    private static let escapeKeyCode: CGKeyCode = 53 // kVK_Escape

    override func setUpWithError() throws {
        continueAfterFailure = false
        try E2ESession.skipIfScreenLocked()
        try XCTSkipUnless(
            AudioDriver.deviceExists(uid: E2EContract.blackHoleUID),
            """
            BlackHole 2ch not installed. Run:
            brew install --cask blackhole-2ch && sudo killall coreaudiod
            """
        )
        if !HotkeyDriver.isTrusted {
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

    func testEscapeMidDictationLandsInRecentlyDeletedAndRestores() throws {
        app = session.makeApp()
        app.launch()
        XCTAssertTrue(
            app.statusItems.firstMatch.waitForExistence(timeout: 15),
            "menu bar item never appeared"
        )
        sleep(3)

        let entriesBefore = session.historyEntryCount()
        let fixture = Fixture.testingOneTwoThree

        // Record the fixture...
        HotkeyDriver.press(
            E2EContract.dictationKeyCode, flags: E2EContract.dictationFlags
        )
        XCTAssertTrue(
            E2ESession.waitForPanelPhase(app, "recording", timeout: 10),
            "dictation never reached recording"
        )
        sleep(1) // capture arming preroll
        try AudioDriver.play(fixture.url, toDeviceUID: E2EContract.blackHoleUID)
        sleep(1) // tail padding

        // ...then the accidental Escape: system-wide, exactly as it lands
        // when dismissing some other app's popup while dictating.
        HotkeyDriver.press(Self.escapeKeyCode, flags: [])

        // Data plane: the discard must CREATE an entry, not destroy audio.
        guard let entry = session.waitForNewHistoryEntry(
            beyond: entriesBefore, timeout: 30
        ) else {
            return XCTFail(
                "Escape destroyed the recording — no entry within 30s"
            )
        }

        // The entry is flagged discarded, and the transcript enrichment
        // (real Parakeet, best-effort after the audio write) fills in.
        var payload = [String: Any]()
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            payload = interaction(of: entry) ?? [:]
            if let text = payload["text"] as? String, !text.isEmpty {
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertNotNil(
            payload["discardedAt"],
            "salvaged capture must carry discardedAt (Recently Deleted)"
        )
        let text = (payload["text"] as? String ?? "").lowercased()
        for anchor in fixture.anchors {
            XCTAssertTrue(
                text.contains(anchor),
                "salvaged transcript lost anchor '\(anchor)': \"\(text)\""
            )
        }

        // Artifact plane: the audio itself is the recovery guarantee.
        let stats = try session.storedAudioStats(of: entry)
        XCTAssertGreaterThan(
            stats.rms, 0.005, "salvaged audio is silence — capture lost"
        )
        XCTAssertGreaterThanOrEqual(
            stats.duration, fixture.duration - 0.5,
            "salvaged audio shorter than the fixture — samples dropped"
        )

        // UI plane: restore it through the real History window.
        XCTAssertTrue(
            E2ESession.openHistoryWindow(app),
            "History window never opened via the status menu"
        )
        let trashToggle = app.descendants(matching: .any)
            .matching(identifier: E2EContract.historyTrashToggleID).firstMatch
        XCTAssertTrue(
            trashToggle.waitForExistence(timeout: 5),
            "Recently Deleted toggle missing despite the discarded dictation"
        )
        trashToggle.click()

        let anchorWord = fixture.anchors[0]
        let row = app.staticTexts.containing(
            NSPredicate(
                format: "value CONTAINS[c] %@ OR label CONTAINS[c] %@",
                anchorWord, anchorWord
            )
        ).firstMatch
        XCTAssertTrue(
            row.waitForExistence(timeout: 5),
            "discarded dictation not listed under Recently Deleted"
        )
        row.click()

        let restore = app.descendants(matching: .any)
            .matching(identifier: E2EContract.historyRestoreID).firstMatch
        XCTAssertTrue(
            restore.waitForExistence(timeout: 5),
            "Restore button missing for a discarded dictation"
        )
        restore.click()

        // Disk is the truth: the discard flag must clear.
        let restoreDeadline = Date().addingTimeInterval(10)
        var restored = false
        while Date() < restoreDeadline, !restored {
            restored = interaction(of: entry)?["discardedAt"] == nil
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertTrue(restored, "interaction.json still carries discardedAt")
    }

    /// The `data` payload of the entry's interaction.json, or nil.
    private func interaction(of entry: URL) -> [String: Any]? {
        guard
            let data = try? Data(
                contentsOf: entry.appendingPathComponent("interaction.json")
            ),
            let json = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else { return nil }
        return json["data"] as? [String: Any]
    }
}
