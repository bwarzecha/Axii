//
//  AppStatusTests.swift
//  AxiiTests
//
//  Unit tests for the AppStatus mapping from ModePhase to menu bar text.
//  These test a small, stable contract that is independent of the object graph.
//

import XCTest
@testable import Axii

final class AppStatusTests: XCTestCase {

    // MARK: - ModePhase -> AppStatus mapping

    func testIdlePhase_MapsToReady() {
        XCTAssertEqual(AppStatus.from(.idle), .ready)
    }

    func testDonePhase_MapsToReady() {
        XCTAssertEqual(AppStatus.from(.done), .ready)
    }

    func testRecordingPhase_MapsToRecording() {
        XCTAssertEqual(AppStatus.from(.recording), .recording)
    }

    func testPreparingPhase_MapsToProcessing() {
        XCTAssertEqual(AppStatus.from(.preparing), .processing)
    }

    func testTranscribingPhase_MapsToProcessing() {
        XCTAssertEqual(AppStatus.from(.transcribing), .processing)
    }

    func testProcessingPhase_MapsToProcessing() {
        XCTAssertEqual(AppStatus.from(.processing), .processing)
    }

    func testErrorPhase_MapsToError() {
        XCTAssertEqual(AppStatus.from(.error("something")), .error)
    }

    // MARK: - AppStatus -> menu bar text

    func testReadyMenuBarText() {
        XCTAssertEqual(AppStatus.ready.menuBarText, "Ready")
    }

    func testRecordingMenuBarText() {
        XCTAssertEqual(AppStatus.recording.menuBarText, "Recording...")
    }

    func testProcessingMenuBarText() {
        XCTAssertEqual(AppStatus.processing.menuBarText, "Processing...")
    }

    func testErrorMenuBarText() {
        XCTAssertEqual(AppStatus.error.menuBarText, "Error")
    }
}
