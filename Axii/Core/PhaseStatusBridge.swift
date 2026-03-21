//
//  PhaseStatusBridge.swift
//  Axii
//
//  Bridges ModeRuntimeState.phase -> AppStatusSource using
//  withObservationTracking. Owned by FeatureManager; one bridge
//  instance exists per app lifecycle.
//
//  The bridge uses a generation counter to invalidate stale
//  observation callbacks when the observed state is switched
//  or observation is stopped.
//

#if os(macOS)
import Foundation

/// Observes a ModeRuntimeState.phase and pushes changes to an AppStatusSource.
///
/// Call `observe(_:)` to begin tracking a state's phase.
/// Call `stop()` to disconnect and reset to ready.
/// Call `observe(_:)` again to switch to a different state.
///
/// Stale callbacks from a previously observed state are safely discarded
/// via a generation counter that increments on every `observe` or `stop`.
@MainActor
final class PhaseStatusBridge {
    let statusSource: AppStatusSource

    /// Incremented on each observe/stop to invalidate stale callbacks.
    private(set) var generation: Int = 0

    init(statusSource: AppStatusSource) {
        self.statusSource = statusSource
    }

    /// Begin observing a ModeRuntimeState's phase. Immediately syncs the
    /// current phase and starts self-re-arming observation.
    /// Calling this again switches observation to the new state.
    func observe(_ state: ModeRuntimeState) {
        generation += 1
        statusSource.update(phase: state.phase)
        armObservation(of: state, generation: generation)
    }

    /// Stop observing and reset status to ready.
    func stop() {
        generation += 1
        statusSource.deactivate()
    }

    /// Self-re-arming observation via withObservationTracking.
    /// The generation parameter ensures stale callbacks are discarded.
    private func armObservation(of state: ModeRuntimeState, generation: Int) {
        withObservationTracking {
            _ = state.phase
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.statusSource.update(phase: state.phase)
                self.armObservation(of: state, generation: generation)
            }
        }
    }
}

#endif
