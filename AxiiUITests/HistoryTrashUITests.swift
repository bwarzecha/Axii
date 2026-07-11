//
//  HistoryTrashUITests.swift
//  AxiiUITests
//
//  Scenario 2 (UI half): a discarded meeting is invisible in the main
//  History list, visible under Recently Deleted, and Restore brings it
//  back — driven entirely through the real History window. Needs neither
//  BlackHole nor hotkey permissions (seeded data, XCUITest clicks only).
//

import XCTest

final class HistoryTrashUITests: XCTestCase {

    private var session: E2ESession!
    private var app: XCUIApplication!
    private let seededText = "Restore me please this is a seeded segment"

    override func setUpWithError() throws {
        continueAfterFailure = false
        session = try E2ESession()
        try session.seedDiscardedMeeting(text: seededText)
        E2ESession.terminateOtherAxiiInstances()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        session?.cleanup()
    }

    func testDiscardedMeetingIsRestorableThroughHistoryWindow() throws {
        app = session.makeApp()
        app.launch()

        XCTAssertTrue(
            E2ESession.openHistoryWindow(app),
            "History window never opened via the status menu"
        )

        // Hidden from the main list...
        let rowText = app.staticTexts
            .containing(
                NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@",
                            "Restore me", "Restore me")
            ).firstMatch
        XCTAssertFalse(
            rowText.exists,
            "discarded meeting leaked into the main history list"
        )

        // ...but reachable via the Recently Deleted toggle.
        let trashToggle = app.descendants(matching: .any)
            .matching(identifier: E2EContract.historyTrashToggleID).firstMatch
        XCTAssertTrue(
            trashToggle.waitForExistence(timeout: 5),
            "Recently Deleted toggle missing despite a discarded entry"
        )
        trashToggle.click()

        XCTAssertTrue(
            rowText.waitForExistence(timeout: 5),
            "discarded meeting not shown in Recently Deleted"
        )
        rowText.click()

        // Restore from the detail pane.
        let restore = app.descendants(matching: .any)
            .matching(identifier: E2EContract.historyRestoreID).firstMatch
        XCTAssertTrue(
            restore.waitForExistence(timeout: 5),
            "Restore button missing in detail view"
        )
        restore.click()

        // Disk is the truth: the discard flag must be gone.
        let deadline = Date().addingTimeInterval(10)
        var restored = false
        while Date() < deadline, !restored {
            if let entry = session.newestEntry(),
               let data = try? Data(
                   contentsOf: entry.appendingPathComponent("interaction.json")
               ),
               let json = try? JSONSerialization.jsonObject(with: data)
                   as? [String: Any],
               let meeting = json["data"] as? [String: Any] {
                restored = meeting["discardedAt"] == nil
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertTrue(restored, "interaction.json still carries discardedAt")
    }
}
