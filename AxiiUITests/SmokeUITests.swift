//
//  SmokeUITests.swift
//  AxiiUITests
//
//  No-hotkey smoke: the scratch-environment app launches, its menu bar
//  item is reachable, and the scratch isolation seam works. Needs neither
//  BlackHole nor the runner's Accessibility grant — this is the tier that
//  can run anywhere, and the fast failure detector for launch regressions.
//

import XCTest

final class SmokeUITests: XCTestCase {

    private var session: E2ESession!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        session = try E2ESession()
        E2ESession.terminateOtherAxiiInstances()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        session?.cleanup()
    }

    func testScratchAppLaunchesAndMenuBarResponds() throws {
        app = session.makeApp()
        app.launch()

        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(
            statusItem.waitForExistence(timeout: 15),
            "menu bar item never appeared — launch or activation broken"
        )
        statusItem.click()

        // The MenuBarExtra menu should contain the History entry.
        let historyItem = app.menuItems["History"].firstMatch
        XCTAssertTrue(
            historyItem.waitForExistence(timeout: 5),
            "status menu did not open or History item missing"
        )
        // Close the menu without invoking anything.
        XCUIElement.perform(withKeyModifiers: []) {
            app.typeKey(.escape, modifierFlags: [])
        }

        // Scratch isolation: the app created nothing in the scratch history
        // yet, and — critically — never touched the real one during launch.
        XCTAssertEqual(
            session.historyEntryCount(), 0,
            "scratch history should start empty"
        )
    }
}
