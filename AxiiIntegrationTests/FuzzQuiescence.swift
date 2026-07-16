//
//  FuzzQuiescence.swift
//  AxiiIntegrationTests
//
//  Convergence-based quiescence for the fuzz drains. Releasing a gate
//  removes the waiter from the hub at RESUME time, so a resumed-but-not-
//  yet-executed continuation is invisible to GateHub.pendingCount — on a
//  slow machine its job can still be queued on the main actor when a
//  fixed-iteration yield loop ends, and the invariants then read a
//  mid-flight state (CI-only false positives; see the harness section of
//  docs/meeting-reliability-model.md). Fixed loop counts assume scheduler
//  fairness Swift does not guarantee. Instead, a drain converges: it runs
//  rounds until the invariant-relevant state fingerprint stops changing.
//  A genuinely stuck state stays stuck forever, so convergence checks the
//  product's actual eventual-teardown contract rather than fairness.
//

import Foundation

/// Rounds the fingerprint must hold unchanged before quiescence is declared.
let fuzzDrainStableRounds = 25
/// Hard cap on total rounds — thousands, so only a livelock exhausts it.
let fuzzDrainMaxRounds = 4_000

/// Runs `round` until `fingerprint` is unchanged for `stableRounds`
/// consecutive rounds. Returns false if `maxRounds` ran out while state was
/// still moving (livelock) — callers should record that as a violation.
@MainActor
func settleUntilStable(
    stableRounds: Int = fuzzDrainStableRounds,
    maxRounds: Int = fuzzDrainMaxRounds,
    round: @MainActor (Int) async -> Void,
    fingerprint: @MainActor () -> String
) async -> Bool {
    var consecutiveStable = 0
    var last = fingerprint()
    for index in 0..<maxRounds {
        await round(index)
        let now = fingerprint()
        if now == last {
            consecutiveStable += 1
            if consecutiveStable >= stableRounds { return true }
        } else {
            consecutiveStable = 0
            last = now
        }
    }
    return false
}

extension GateHub {
    /// Await `body` while a background task keeps every gate flowing. The
    /// awaited work may be mid-hop toward a gate at the moment pendingCount
    /// reads 0 — it parks only AFTER the await starts, and with no releaser
    /// running nobody ever opens that gate: the await deadlocks.
    func releasingWhile(_ body: () async -> Void) async {
        let releaser = Task { @MainActor [self] in
            while !Task.isCancelled {
                releaseAll()
                await Task.yield()
            }
        }
        await body()
        releaser.cancel()
    }
}

extension ChaosRegistry {
    /// Invariant-relevant state of every chaos fake, for convergence drains.
    var stateFingerprint: String {
        var parts: [String] = []
        for audio in audios {
            parts.append(
                "a\(audio.id):\(audio.started),\(audio.live),"
                + "\(audio.stopCalls),\(audio.cleaned),\(audio.startFailed)"
            )
        }
        for transcript in transcripts {
            parts.append(
                "t\(transcript.id):\(transcript.autosaveRunning),"
                + "\(transcript.flushCount),\(transcript.clearCount)"
            )
        }
        return parts.joined(separator: "|")
    }
}
