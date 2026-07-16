//
//  MeetingConcurrencyFuzzTests.swift
//  AxiiIntegrationTests
//
//  Schedule-fuzzing harness for MeetingCaptureSession. The meeting runtime
//  is @MainActor, so its concurrency bugs are interleavings at await
//  suspension points — and because every async dependency in the chaos
//  fakes suspends on a GateHub, the driver controls exactly which suspended
//  call proceeds next. Each seed replays a deterministic random schedule of
//  operations (start/stop/cancel/switch/chunks/errors/start-failures) and
//  gate releases, then checks INVARIANTS at quiescence instead of specific
//  outputs:
//
//  - no live capture survives the final cancel (no orphaned hot mic)
//  - every started capture is stopped exactly once
//  - recovery artifacts are conserved: a saved capture keeps its autosave
//    and temp audio (cleared later at the persistence commit point); a
//    discarded capture clears both exactly once
//  - no autosave timer outlives its session
//  - samples are never read from cleaned-up files
//
//  A failing seed is a reproducible bug report: rerun with that seed.
//

import XCTest
@testable import Axii

@MainActor
final class MeetingConcurrencyFuzzTests: XCTestCase {

    private struct StopRecord {
        let saveToHistory: Bool
        let captured: MeetingCapturedAudio?
    }

    // MARK: - Fuzz Driver

    private func runFuzzIteration(seed: UInt64) async -> [String] {
        var rng = SplitMix64(seed: seed)
        let violations = ViolationLog()
        let gates = GateHub()
        let registry = ChaosRegistry(gates: gates, violations: violations)

        var failRoll = SplitMix64(seed: seed ^ 0xDEAD_BEEF)
        let session = MeetingCaptureSession(
            transcriptionService: NullTranscriber(),
            audioManagerFactory: {
                registry.makeAudio(failStart: failRoll.next(upperBound: 10) == 0)
            },
            transcriptManagerFactory: { registry.makeTranscript() },
            // Deterministic: no run-loop timers or power assertions inside
            // seeded schedules (see MeetingInteractionFuzzSupport).
            durationTicker: FuzzDurationTicker(),
            powerMonitor: FuzzPowerMonitor()
        )

        var operations: [Task<Void, Never>] = []
        var stopRecords: [StopRecord] = []
        var trace: [String] = []

        let steps = 8 + Int(rng.next(upperBound: 12))
        for _ in 0..<steps {
            switch rng.next(upperBound: 10) {
            case 0...2:
                trace.append("start")
                operations.append(Task {
                    try? await session.start(
                        configuration: MeetingCaptureStartConfiguration(
                            selectedApp: nil,
                            selectedMicrophone: nil,
                            streamingEnabled: true
                        )
                    )
                })
            case 3...4:
                let save = rng.next(upperBound: 2) == 0
                trace.append(save ? "stop(save)" : "stop(discard)")
                operations.append(Task {
                    let captured = await session.stop(saveToHistory: save)
                    stopRecords.append(StopRecord(saveToHistory: save, captured: captured))
                })
            case 5:
                trace.append("cancel")
                session.cancel()
            case 6:
                trace.append("selectApp")
                session.selectApp(nil)
            case 7:
                trace.append("switchMic")
                operations.append(Task {
                    await session.switchMicrophone(to: nil, selectedApp: nil)
                })
            case 8:
                trace.append("chunk")
                registry.liveAudio?.emitChunk()
            default:
                trace.append("error")
                registry.liveAudio?.onError?("chaos error")
            }

            // Random amount of forward progress between operations.
            for _ in 0..<Int(rng.next(upperBound: 3)) {
                _ = gates.releaseRandom(&rng)
            }
            for _ in 0..<Int(rng.next(upperBound: 4)) {
                await Task.yield()
            }
        }

        // Drain: keep opening gates while the issued operations finish.
        let drain = Task { @MainActor in
            while !Task.isCancelled {
                gates.releaseAll()
                await Task.yield()
            }
        }
        for operation in operations {
            await operation.value
        }
        session.cancel()
        // Convergence drain: a released continuation's job may still be
        // queued when pendingCount reads 0, so release/yield until the
        // invariant-relevant state stops moving (see FuzzQuiescence.swift)
        // instead of trusting a fixed round count.
        let converged = await settleUntilStable(
            round: { _ in
                gates.releaseAll()
                for _ in 0..<5 { await Task.yield() }
            },
            fingerprint: {
                "gates:\(gates.pendingCount)|" + registry.stateFingerprint
            }
        )
        drain.cancel()
        if !converged {
            violations.add(
                "drain did not converge — state still changing after "
                + "\(fuzzDrainMaxRounds) rounds"
            )
        }

        checkInvariants(
            session: session,
            registry: registry,
            stopRecords: stopRecords,
            violations: violations
        )

        if violations.violations.isEmpty {
            return []
        }
        return violations.violations.map { "\($0) [trace: \(trace.joined(separator: ","))]" }
    }

    // MARK: - Quiescence Invariants

    private func checkInvariants(
        session: MeetingCaptureSession,
        registry: ChaosRegistry,
        stopRecords: [StopRecord],
        violations: ViolationLog
    ) {
        if session.isRecording {
            violations.add("session still recording after final cancel")
        }

        for audio in registry.audios {
            if audio.live {
                violations.add("audio[\(audio.id)] live at quiescence — orphaned capture")
            }
            if audio.started && !audio.startFailed && audio.stopCalls == 0 {
                violations.add("audio[\(audio.id)] started but never stopped")
            }
            if audio.startFailed && !audio.cleaned {
                violations.add("audio[\(audio.id)] failed start left temp files behind")
            }
        }

        for transcript in registry.transcripts {
            if transcript.autosaveRunning {
                violations.add("transcript[\(transcript.id)] autosave timer running at quiescence")
            }
        }

        // Artifact conservation for every completed stop.
        for record in stopRecords {
            guard let captured = record.captured else { continue }
            guard record.saveToHistory else {
                violations.add("stop(discard) returned captured audio")
                continue
            }
            guard let artifacts = captured.recoveryArtifacts else {
                violations.add("saved capture has no recovery artifacts")
                continue
            }
            guard let transcript = registry.transcript(for: artifacts.sessionID) else {
                violations.add("artifacts sessionID matches no transcript")
                continue
            }
            if transcript.clearCount != 0 {
                violations.add(
                    "transcript[\(transcript.id)] autosave cleared before persistence commit"
                )
            }
            if transcript.flushCount == 0 {
                violations.add("transcript[\(transcript.id)] saved without a final autosave flush")
            }
            if let audio = registry.audio(forMicURL: artifacts.micFileURL), audio.cleaned {
                violations.add(
                    "audio[\(audio.id)] temp files cleaned before persistence commit"
                )
            }
        }
    }

    // MARK: - Tests

    /// Watchdog wrapper: a schedule that deadlocks must fail the seed, not
    /// hang the suite.
    private func runWatchedIteration(seed: UInt64) async -> [String] {
        await withTaskGroup(of: [String]?.self) { group in
            group.addTask { @MainActor in
                await self.runFuzzIteration(seed: seed)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return nil
            }
            for await result in group {
                group.cancelAll()
                return result ?? ["iteration hung >10s — probable deadlock"]
            }
            return ["watchdog: no result"]
        }
    }

    func testFuzzCaptureLifecycleAcrossSeededSchedules() async {
        // Default 500 seeds (~1s). Deep runs set AXII_FUZZ_SEEDS
        // (TEST_RUNNER_AXII_FUZZ_SEEDS via xcodebuild) — see
        // Scripts/reliability-suite.sh. AXII_FUZZ_SEED_START offsets the
        // range so CI can shard a deep run across parallel jobs (and a
        // failing seed can be replayed exactly, like the interaction
        // fuzzer).
        let seedCount = Int(
            ProcessInfo.processInfo.environment["AXII_FUZZ_SEEDS"] ?? ""
        ) ?? 500
        let seedStart = Int(
            ProcessInfo.processInfo.environment["AXII_FUZZ_SEED_START"] ?? ""
        ) ?? 0
        var failures: [String] = []
        for seed in seedStart..<(seedStart + seedCount) {
            let iterationViolations = await runWatchedIteration(seed: UInt64(seed))
            if !iterationViolations.isEmpty {
                failures.append("seed \(seed): \(iterationViolations.joined(separator: " | "))")
            }
            if failures.count >= 5 {
                break
            }
        }
        XCTAssertTrue(
            failures.isEmpty,
            "Concurrency invariant violations:\n" + failures.joined(separator: "\n")
        )
    }
}
