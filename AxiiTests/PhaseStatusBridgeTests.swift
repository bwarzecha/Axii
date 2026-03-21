//
//  PhaseStatusBridgeTests.swift
//  AxiiTests
//
//  Tests for the observation bridge from ModeRuntimeState.phase to
//  AppStatusSource.appStatus. This is the critical glue that keeps the
//  menu bar in sync with the active mode runtime.
//
//  Tests cover: immediate sync on observe(), async propagation of phase
//  changes, deactivation, and — most importantly — stale callback
//  invalidation after stop() and after switching to a different state.
//
//  Phase changes propagate asynchronously (withObservationTracking onChange
//  dispatches via Task). Tests use a bounded polling helper to wait for
//  the expected status.
//

import XCTest
@testable import Axii

@MainActor
final class PhaseStatusBridgeTests: XCTestCase {

    private var statusSource: AppStatusSource!
    private var bridge: PhaseStatusBridge!

    override func setUp() {
        statusSource = AppStatusSource()
        bridge = PhaseStatusBridge(statusSource: statusSource)
    }

    override func tearDown() {
        bridge = nil
        statusSource = nil
    }

    // MARK: - Helpers

    /// Polls until the status source reaches the expected value, or fails.
    private func waitForStatus(
        _ expected: AppStatus,
        timeout: TimeInterval = 2.0,
        message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while statusSource.appStatus != expected {
            guard Date() < deadline else {
                XCTFail(
                    "Timed out waiting for status \(expected), got \(statusSource.appStatus). \(message)",
                    file: file, line: line
                )
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - A. Initial / inactive state

    func testInitialState_StatusIsReady() {
        XCTAssertEqual(statusSource.appStatus, .ready)
    }

    func testStopWithoutObserving_StatusRemainsReady() {
        bridge.stop()
        XCTAssertEqual(statusSource.appStatus, .ready)
    }

    // MARK: - B. Immediate activation sync

    func testObserve_IdlePhase_ImmediatelySyncsReady() {
        let state = ModeRuntimeState()
        state.phase = .idle
        bridge.observe(state)
        XCTAssertEqual(statusSource.appStatus, .ready)
    }

    func testObserve_RecordingPhase_ImmediatelySyncsRecording() {
        let state = ModeRuntimeState()
        state.phase = .recording
        bridge.observe(state)
        XCTAssertEqual(statusSource.appStatus, .recording)
    }

    func testObserve_TranscribingPhase_ImmediatelySyncsProcessing() {
        let state = ModeRuntimeState()
        state.phase = .transcribing
        bridge.observe(state)
        XCTAssertEqual(statusSource.appStatus, .processing)
    }

    func testObserve_ProcessingPhase_ImmediatelySyncsProcessing() {
        let state = ModeRuntimeState()
        state.phase = .processing
        bridge.observe(state)
        XCTAssertEqual(statusSource.appStatus, .processing)
    }

    func testObserve_ErrorPhase_ImmediatelySyncsError() {
        let state = ModeRuntimeState()
        state.phase = .error("boom")
        bridge.observe(state)
        XCTAssertEqual(statusSource.appStatus, .error)
    }

    // MARK: - C. Live phase propagation

    func testPhaseChange_IdleToRecording_PropagatesAsync() async throws {
        let state = ModeRuntimeState()
        state.phase = .idle
        bridge.observe(state)
        XCTAssertEqual(statusSource.appStatus, .ready)

        state.phase = .recording
        try await waitForStatus(.recording)
    }

    func testPhaseChange_RecordingToTranscribing_PropagatesAsync() async throws {
        let state = ModeRuntimeState()
        state.phase = .recording
        bridge.observe(state)
        XCTAssertEqual(statusSource.appStatus, .recording)

        state.phase = .transcribing
        try await waitForStatus(.processing)
    }

    func testPhaseChange_ProcessingToDone_PropagatesAsync() async throws {
        let state = ModeRuntimeState()
        state.phase = .processing
        bridge.observe(state)
        XCTAssertEqual(statusSource.appStatus, .processing)

        state.phase = .done
        try await waitForStatus(.ready)
    }

    func testPhaseChange_RecordingToError_PropagatesAsync() async throws {
        let state = ModeRuntimeState()
        state.phase = .recording
        bridge.observe(state)
        XCTAssertEqual(statusSource.appStatus, .recording)

        state.phase = .error("mic disconnected")
        try await waitForStatus(.error)
    }

    func testMultiplePhaseChanges_PropagateSequentially() async throws {
        let state = ModeRuntimeState()
        bridge.observe(state)

        state.phase = .recording
        try await waitForStatus(.recording)

        state.phase = .transcribing
        try await waitForStatus(.processing)

        state.phase = .done
        try await waitForStatus(.ready)
    }

    // MARK: - D. Deactivation behavior

    func testStop_ResetsStatusToReady() async throws {
        let state = ModeRuntimeState()
        state.phase = .recording
        bridge.observe(state)
        XCTAssertEqual(statusSource.appStatus, .recording)

        bridge.stop()
        XCTAssertEqual(statusSource.appStatus, .ready)
    }

    // MARK: - E. Stale callback invalidation

    /// After stop(), mutations on the previously observed state must NOT
    /// propagate to the status source.
    func testStop_ThenMutateOldState_StatusRemainsReady() async throws {
        let stateA = ModeRuntimeState()
        stateA.phase = .recording
        bridge.observe(stateA)
        XCTAssertEqual(statusSource.appStatus, .recording)

        bridge.stop()
        XCTAssertEqual(statusSource.appStatus, .ready)

        // Mutate the old state — status must stay ready
        stateA.phase = .error("should be ignored")

        // Wait long enough for any stale callback to fire if it was going to
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(statusSource.appStatus, .ready,
                        "Stale mutation on old state must not affect status after stop()")
    }

    /// After switching observation from state A to state B, mutations on
    /// state A must NOT propagate. Mutations on state B must propagate.
    func testSwitchObservation_OldStateMutationsIgnored() async throws {
        let stateA = ModeRuntimeState()
        stateA.phase = .recording
        bridge.observe(stateA)
        XCTAssertEqual(statusSource.appStatus, .recording)

        // Switch to state B
        let stateB = ModeRuntimeState()
        stateB.phase = .idle
        bridge.observe(stateB)
        XCTAssertEqual(statusSource.appStatus, .ready,
                        "Switching should immediately sync to state B's phase")

        // Mutate old state A — must be ignored
        stateA.phase = .error("should be ignored")

        // Wait for any stale callback to settle
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(statusSource.appStatus, .ready,
                        "Old state A mutations must not affect status after switching to B")

        // Mutate state B — should propagate
        stateB.phase = .recording
        try await waitForStatus(.recording, message: "State B mutations should propagate")
    }

    /// After switching observation, verify that the new state's full lifecycle
    /// propagates correctly while old state mutations remain ignored.
    func testSwitchObservation_NewStateLifecyclePropagates() async throws {
        let stateA = ModeRuntimeState()
        stateA.phase = .recording
        bridge.observe(stateA)

        let stateB = ModeRuntimeState()
        stateB.phase = .idle
        bridge.observe(stateB)

        // State B lifecycle
        stateB.phase = .recording
        try await waitForStatus(.recording)

        stateB.phase = .transcribing
        try await waitForStatus(.processing)

        // Mutate A in the middle — still ignored
        stateA.phase = .error("stale")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(statusSource.appStatus, .processing,
                        "Stale state A mutation must not interfere with active state B observation")

        stateB.phase = .done
        try await waitForStatus(.ready)
    }

    /// Generation counter increments on each observe/stop call.
    func testGenerationIncrementsOnObserveAndStop() {
        let initial = bridge.generation

        let state = ModeRuntimeState()
        bridge.observe(state)
        XCTAssertEqual(bridge.generation, initial + 1)

        bridge.stop()
        XCTAssertEqual(bridge.generation, initial + 2)

        bridge.observe(state)
        XCTAssertEqual(bridge.generation, initial + 3)
    }
}
