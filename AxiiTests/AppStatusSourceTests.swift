//
//  AppStatusSourceTests.swift
//  AxiiTests
//
//  Low-level unit tests for AppStatusSource's stored property mutation.
//  These verify that update(phase:) and deactivate() correctly set appStatus.
//  They do NOT test the observation bridge from ModeRuntimeState — that is
//  covered by PhaseStatusBridgeTests.
//

import XCTest
@testable import Axii

@MainActor
final class AppStatusSourceTests: XCTestCase {

    private var source: AppStatusSource!

    override func setUp() {
        source = AppStatusSource()
    }

    override func tearDown() {
        source = nil
    }

    // MARK: - Initial state

    func testInitialStatus_IsReady() {
        XCTAssertEqual(source.appStatus, .ready)
    }

    // MARK: - update(phase:) sets correct status

    func testUpdate_IdlePhase_ReturnsReady() {
        source.update(phase: .idle)
        XCTAssertEqual(source.appStatus, .ready)
    }

    func testUpdate_DonePhase_ReturnsReady() {
        source.update(phase: .done)
        XCTAssertEqual(source.appStatus, .ready)
    }

    func testUpdate_RecordingPhase_ReturnsRecording() {
        source.update(phase: .recording)
        XCTAssertEqual(source.appStatus, .recording)
    }

    func testUpdate_PreparingPhase_ReturnsProcessing() {
        source.update(phase: .preparing)
        XCTAssertEqual(source.appStatus, .processing)
    }

    func testUpdate_TranscribingPhase_ReturnsProcessing() {
        source.update(phase: .transcribing)
        XCTAssertEqual(source.appStatus, .processing)
    }

    func testUpdate_ProcessingPhase_ReturnsProcessing() {
        source.update(phase: .processing)
        XCTAssertEqual(source.appStatus, .processing)
    }

    func testUpdate_ErrorPhase_ReturnsError() {
        source.update(phase: .error("test failure"))
        XCTAssertEqual(source.appStatus, .error)
    }

    // MARK: - deactivate() resets to ready

    func testDeactivate_ReturnsToReady() {
        source.update(phase: .recording)
        source.deactivate()
        XCTAssertEqual(source.appStatus, .ready)
    }
}
