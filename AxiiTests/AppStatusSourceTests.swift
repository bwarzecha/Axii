//
//  AppStatusSourceTests.swift
//  AxiiTests
//
//  Tests for the observable app-level status source contract.
//  These verify that AppStatusSource.appStatus changes correctly as
//  the active runtime state changes — covering both activation/deactivation
//  transitions and phase transitions within an active mode.
//
//  The tests exercise AppStatusSource via its public update/deactivate API,
//  which is the same API FeatureManager uses. This tests the stable contract
//  without depending on FeatureManager internals.
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

    // MARK: - Phase mapping through update()

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

    // MARK: - Activation transition

    func testActivating_ChangesStatusFromReady() {
        XCTAssertEqual(source.appStatus, .ready, "Precondition: initial ready")

        source.update(phase: .recording)
        XCTAssertEqual(source.appStatus, .recording,
                        "Updating with recording phase should change status")
    }

    // MARK: - Deactivation transition

    func testDeactivate_ReturnsToReady() {
        source.update(phase: .recording)
        XCTAssertEqual(source.appStatus, .recording, "Precondition: active recording")

        source.deactivate()
        XCTAssertEqual(source.appStatus, .ready,
                        "Deactivating should return to ready")
    }

    // MARK: - Phase transitions within an active mode

    func testPhaseTransition_IdleToRecording() {
        source.update(phase: .idle)
        XCTAssertEqual(source.appStatus, .ready)

        source.update(phase: .recording)
        XCTAssertEqual(source.appStatus, .recording)
    }

    func testPhaseTransition_RecordingToTranscribing() {
        source.update(phase: .recording)
        XCTAssertEqual(source.appStatus, .recording)

        source.update(phase: .transcribing)
        XCTAssertEqual(source.appStatus, .processing)
    }

    func testPhaseTransition_ProcessingToDone() {
        source.update(phase: .processing)
        XCTAssertEqual(source.appStatus, .processing)

        source.update(phase: .done)
        XCTAssertEqual(source.appStatus, .ready)
    }

    func testPhaseTransition_RecordingToError() {
        source.update(phase: .recording)
        XCTAssertEqual(source.appStatus, .recording)

        source.update(phase: .error("mic disconnected"))
        XCTAssertEqual(source.appStatus, .error)
    }

    // MARK: - Full lifecycle

    func testFullLifecycle_ActivateTransitionDeactivate() {
        // Start with no mode
        XCTAssertEqual(source.appStatus, .ready)

        // Activate with idle
        source.update(phase: .idle)
        XCTAssertEqual(source.appStatus, .ready)

        // Recording
        source.update(phase: .recording)
        XCTAssertEqual(source.appStatus, .recording)

        // Transcribing
        source.update(phase: .transcribing)
        XCTAssertEqual(source.appStatus, .processing)

        // Processing
        source.update(phase: .processing)
        XCTAssertEqual(source.appStatus, .processing)

        // Done
        source.update(phase: .done)
        XCTAssertEqual(source.appStatus, .ready)

        // Deactivate
        source.deactivate()
        XCTAssertEqual(source.appStatus, .ready)
    }

}
