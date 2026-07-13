//
//  ModeFeatureDiscardSalvage.swift
//  Axii
//
//  Discard-to-trash for simple (singleShot/multiTurn) captures: the
//  dictation counterpart of the meeting discard path. A user-initiated
//  teardown — Escape, panel close, takeover discard, mode deletion,
//  quit-and-discard — that reaches a mode holding captured audio must
//  not destroy it: ModeFeature decides WHAT to salvage here; the
//  DiscardedCaptureArchiver owns HOW it lands in "Recently Deleted".
//

#if os(macOS)
import Foundation

extension ModeFeature {

    /// Minimum audio worth salvaging — same bar as the error-salvage path:
    /// keeps sub-second accidental opens out of the trash.
    static let discardSalvageMinimumSeconds = 1.0

    /// Take whatever capture a teardown is about to destroy and hand it to
    /// the archiver. Covers three holdings: a live recording helper, audio
    /// carried across a mic switch, and the capture behind an in-flight
    /// (or errored) post-stop turn.
    ///
    /// Meetings never reach this: they hold no recordingHelper or turn
    /// capture, and their live capture discards through stopMeeting(.discard),
    /// which owns the meeting trash path.
    func salvageDiscardedSimpleCapture() {
        let capture = takeDiscardedCapture()
        guard historyService.isEnabled,
              let (samples, sampleRate) = capture,
              sampleRate > 0,
              Double(samples.count) / sampleRate
                  >= Self.discardSalvageMinimumSeconds
        else { return }
        discardArchiver.archive(
            samples: samples, sampleRate: sampleRate,
            config: historyOutputConfig()
        )
    }

    /// Consume every audio holding of the current simple session. Always
    /// drains state (even when the salvage guards then drop the result) so
    /// the teardown that follows finds nothing left to destroy twice.
    private func takeDiscardedCapture() -> (samples: [Float], sampleRate: Double)? {
        defer { inFlightTurnCapture = nil }
        if state.phase.isRecording, let helper = recordingHelper {
            let taken = takeCombinedRecording(finishing: helper)
            recordingHelper = nil
            return taken
        }
        if state.phase.isRecording, let carried = takeCarriedRecording() {
            // Mic-switch restart gap: no live helper, audio only carried.
            return carried
        }
        // A turn superseded mid-.transcribing/.processing, or one that
        // ended in .error and was never delivered.
        return inFlightTurnCapture
    }

    /// The mode's history output shapes HOW a salvage persists (audio
    /// on/off, format). Its ABSENCE does not opt out of the safety net:
    /// conversation modes persist through the session store instead, yet a
    /// discarded capture still deserves the trash. The global history
    /// toggle (checked by the caller) is the only opt-out.
    private func historyOutputConfig() -> HistoryConfig? {
        for output in config.outputs {
            if case .history(let cfg) = output { return cfg }
        }
        return nil
    }
}
#endif
