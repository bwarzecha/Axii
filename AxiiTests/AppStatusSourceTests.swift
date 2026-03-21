//
//  AppStatusSourceTests.swift
//  AxiiTests
//
//  Tests for the observable app-level status source contract.
//  These verify that AppStatusSource.appStatus changes correctly as
//  the active runtime state changes — covering both activation/deactivation
//  transitions and phase transitions within an active mode.
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

    // MARK: - No active mode

    func testNoActiveMode_ReturnsReady() {
        XCTAssertEqual(source.appStatus, .ready)
    }

    // MARK: - Active mode phase mapping

    func testActiveMode_IdlePhase_ReturnsReady() {
        let state = ModeRuntimeState()
        state.phase = .idle
        source.activeState = state
        XCTAssertEqual(source.appStatus, .ready)
    }

    func testActiveMode_DonePhase_ReturnsReady() {
        let state = ModeRuntimeState()
        state.phase = .done
        source.activeState = state
        XCTAssertEqual(source.appStatus, .ready)
    }

    func testActiveMode_RecordingPhase_ReturnsRecording() {
        let state = ModeRuntimeState()
        state.phase = .recording
        source.activeState = state
        XCTAssertEqual(source.appStatus, .recording)
    }

    func testActiveMode_PreparingPhase_ReturnsProcessing() {
        let state = ModeRuntimeState()
        state.phase = .preparing
        source.activeState = state
        XCTAssertEqual(source.appStatus, .processing)
    }

    func testActiveMode_TranscribingPhase_ReturnsProcessing() {
        let state = ModeRuntimeState()
        state.phase = .transcribing
        source.activeState = state
        XCTAssertEqual(source.appStatus, .processing)
    }

    func testActiveMode_ProcessingPhase_ReturnsProcessing() {
        let state = ModeRuntimeState()
        state.phase = .processing
        source.activeState = state
        XCTAssertEqual(source.appStatus, .processing)
    }

    func testActiveMode_ErrorPhase_ReturnsError() {
        let state = ModeRuntimeState()
        state.phase = .error("test failure")
        source.activeState = state
        XCTAssertEqual(source.appStatus, .error)
    }

    // MARK: - Transitions: activation changes status

    func testActivatingMode_ChangesStatusFromReady() {
        XCTAssertEqual(source.appStatus, .ready, "Precondition: no active mode")

        let state = ModeRuntimeState()
        state.phase = .recording
        source.activeState = state

        XCTAssertEqual(source.appStatus, .recording,
                        "Activating a mode in recording phase should change status")
    }

    func testDeactivatingMode_ReturnsToReady() {
        let state = ModeRuntimeState()
        state.phase = .recording
        source.activeState = state
        XCTAssertEqual(source.appStatus, .recording, "Precondition: active recording")

        source.activeState = nil
        XCTAssertEqual(source.appStatus, .ready,
                        "Deactivating should return to ready")
    }

    // MARK: - Transitions: phase changes within active mode update status

    func testPhaseTransition_IdleToRecording() {
        let state = ModeRuntimeState()
        state.phase = .idle
        source.activeState = state
        XCTAssertEqual(source.appStatus, .ready)

        state.phase = .recording
        XCTAssertEqual(source.appStatus, .recording,
                        "Phase change should be reflected in appStatus")
    }

    func testPhaseTransition_RecordingToTranscribing() {
        let state = ModeRuntimeState()
        state.phase = .recording
        source.activeState = state
        XCTAssertEqual(source.appStatus, .recording)

        state.phase = .transcribing
        XCTAssertEqual(source.appStatus, .processing)
    }

    func testPhaseTransition_ProcessingToDone() {
        let state = ModeRuntimeState()
        state.phase = .processing
        source.activeState = state
        XCTAssertEqual(source.appStatus, .processing)

        state.phase = .done
        XCTAssertEqual(source.appStatus, .ready)
    }

    func testPhaseTransition_RecordingToError() {
        let state = ModeRuntimeState()
        state.phase = .recording
        source.activeState = state
        XCTAssertEqual(source.appStatus, .recording)

        state.phase = .error("mic disconnected")
        XCTAssertEqual(source.appStatus, .error)
    }

    func testFullLifecycle_ActivateTransitionDeactivate() {
        // Start with no mode
        XCTAssertEqual(source.appStatus, .ready)

        // Activate a mode
        let state = ModeRuntimeState()
        state.phase = .idle
        source.activeState = state
        XCTAssertEqual(source.appStatus, .ready)

        // Start recording
        state.phase = .recording
        XCTAssertEqual(source.appStatus, .recording)

        // Stop -> transcribing
        state.phase = .transcribing
        XCTAssertEqual(source.appStatus, .processing)

        // Processing
        state.phase = .processing
        XCTAssertEqual(source.appStatus, .processing)

        // Done
        state.phase = .done
        XCTAssertEqual(source.appStatus, .ready)

        // Deactivate
        source.activeState = nil
        XCTAssertEqual(source.appStatus, .ready)
    }
}
