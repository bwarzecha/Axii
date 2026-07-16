//
//  ModeFuzzSupport.swift
//  AxiiIntegrationTests
//
//  Support for the mode-layer INTERACTION fuzzer: a gate-controlled fake
//  capture helper, a gated transcriber that accounts every sample it
//  receives, and a seeded driver that fires REAL UI entry points (hotkey,
//  Escape, panel buttons, mic switches, device events, session errors,
//  config edits, timer fires) in schedule-controlled interleavings.
//
//  Conservation principle: audio a user recorded must reach the transcriber
//  or pass through an explicit cancel — it must never silently vanish.
//

import Foundation
@testable import Axii

// MARK: - Chaos Recording Helper

/// RecordingSessionProviding fake under full schedule control. Mirrors the
/// production helper's contract: start suspends (permission prompt, device
/// spin-up), a stop/cancel during that suspension supersedes the start, and
/// samples accumulate only while live.
@MainActor
final class ChaosRecordingHelper: RecordingSessionProviding {
    let id: Int
    let startError: AudioSessionError?

    private let gates: GateHub
    private let violations: ViolationLog

    private(set) var started = false
    private(set) var live = false
    private(set) var superseded = false
    /// Samples currently buffered (not yet taken by stop()).
    private(set) var bufferedCount = 0
    /// Every sample this helper ever recorded.
    private(set) var recordedTotal = 0
    /// Samples destroyed via cancel() — legal only on explicit user cancels.
    private(set) var discardedTotal = 0

    var currentDevice: AudioDevice?
    var onVisualizationUpdate: ((VisualizationUpdate) -> Void)?
    var onSignalStateChanged: ((Bool) -> Void)?
    var onError: ((AudioSessionError) -> Void)?
    var onDeviceChanged: ((AudioDevice) -> Void)?
    var captureSpool: (any CaptureSpooling)?

    init(
        id: Int,
        gates: GateHub,
        violations: ViolationLog,
        startError: AudioSessionError?
    ) {
        self.id = id
        self.gates = gates
        self.violations = violations
        self.startError = startError
    }

    func start(source: AudioSource) async throws {
        if started {
            violations.add("helper[\(id)] started twice")
        }
        started = true
        await gates.pass("helper[\(id)].start")
        // Mirrors the production epoch guard: a stop/cancel during the
        // suspension means this start must not go live.
        if superseded {
            throw CancellationError()
        }
        if let startError {
            throw startError
        }
        live = true
    }

    func stop() -> (samples: [Float], sampleRate: Double) {
        superseded = true
        live = false
        let taken = bufferedCount
        bufferedCount = 0
        return ([Float](repeating: 0.5, count: taken), 16_000)
    }

    func cancel() {
        superseded = true
        live = false
        discardedTotal += bufferedCount
        bufferedCount = 0
    }

    /// Driver injects two seconds of audio — comfortably above the 1s
    /// salvage threshold, so an errored capture is always salvageable and
    /// strict conservation holds.
    func emitAudio() {
        guard live else { return }
        bufferedCount += 32_000
        recordedTotal += 32_000
    }

    func fireError(_ error: AudioSessionError) {
        onError?(error)
    }

    func fireDeviceChanged(_ device: AudioDevice) {
        currentDevice = device
        onDeviceChanged?(device)
    }
}

// MARK: - Fuzz Spool

/// Custody-tracked crash-spool fake: records whether the runtime resolved
/// it (discarded after its payload landed) or leaked it.
@MainActor
final class FuzzSpool: CaptureSpooling {
    private(set) var discarded = false
    func append(samples: [Float], sampleRate: Double) {}
    func noteDevice(_ device: AudioDevice?) {}
    func discard() { discarded = true }
}

// MARK: - Accounting Transcriber

/// Suspends on the gate hub and counts every sample it receives — the
/// "delivered" side of the conservation invariant.
actor AccountingTranscriber: TranscriptionProviding {
    private let gates: GateHub
    private(set) var receivedSamples = 0

    init(gates: GateHub) {
        self.gates = gates
    }

    var isReady: Bool { true }
    func prepare() async throws {}

    func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
        receivedSamples += samples.count
        await gates.pass("transcribe")
        return "fuzzed transcript"
    }
}

// MARK: - Driver

/// Seeded schedule driver over a single-shot ModeFeature's UI surface.
@MainActor
final class ModeFuzzDriver {
    enum Profile {
        /// No user-initiated cancels: every recorded sample must reach the
        /// transcriber. The strictest data-loss detector.
        case noCancel
        /// Everything including Escape/close/cancel: structural invariants
        /// only (no unowned capture, no stuck phase, no leaked audio).
        case fullChaos
    }

    let feature: ModeFeature
    let gates: GateHub
    let violations: ViolationLog
    let transcriber: AccountingTranscriber
    let profile: Profile

    private(set) var helpers: [ChaosRecordingHelper] = []
    private(set) var spools: [FuzzSpool] = []
    private(set) var pendingDelayed: [DispatchWorkItem] = []
    private(set) var actionLog: [String] = []
    private var rng: SplitMix64
    private var explicitCancels = 0

    private let devices = [
        AudioDevice(id: 1, uid: "mic-a", name: "Mic A", transportType: .usb),
        AudioDevice(id: 2, uid: "mic-b", name: "Mic B", transportType: .bluetooth),
        AudioDevice(id: 3, uid: "built-in", name: "Built-in", transportType: .builtIn),
    ]

    init(
        seed: UInt64,
        profile: Profile,
        settings: SettingsService,
        historyService: HistoryService
    ) {
        self.rng = SplitMix64(seed: seed)
        self.profile = profile
        self.gates = GateHub()
        self.violations = ViolationLog()
        self.transcriber = AccountingTranscriber(gates: gates)

        let feature = ModeFeature(
            config: Self.fuzzConfig(),
            transcriptionService: transcriber,
            micPermission: MicrophonePermissionService(),
            pasteService: FuzzPasteProvider(),
            clipboardService: FuzzClipboard(),
            settings: settings,
            historyService: historyService,
            mediaControlService: MediaControlService()
        )
        self.feature = feature

        feature.isModalSessionActive = { false }
        feature.busyChoiceProvider = { .stay }
        feature.historyOffConfirmProvider = { true }
        feature.makeRecordingHelper = { [unowned self] in
            var seedRNG = self.rng
            let failRoll = seedRNG.next(upperBound: 10)
            self.rng = seedRNG
            let error: AudioSessionError? = switch failRoll {
            case 0: .deviceUnavailable
            case 1: .captureFailure(underlying: "chaos")
            default: nil
            }
            let helper = ChaosRecordingHelper(
                id: self.helpers.count,
                gates: self.gates,
                violations: self.violations,
                startError: error
            )
            self.helpers.append(helper)
            return helper
        }
        feature.scheduleDelayed = { [unowned self] _, item in
            self.pendingDelayed.append(item)
        }
        feature.makeCaptureSpool = { [unowned self] in
            let spool = FuzzSpool()
            self.spools.append(spool)
            return spool
        }
    }

    private static func fuzzConfig() -> ModeConfig {
        let base = DefaultModes.dictation()
        return ModeConfig(
            id: UUID(),
            name: "Fuzz",
            icon: "mic",
            isBuiltIn: false,
            hotkey: nil,
            audioCapture: base.audioCapture,
            transcription: base.transcription,
            processing: [],
            outputs: [.display(DisplayConfig())],
            lifecycle: LifecycleConfig(
                startMode: .automatic,
                panelPersistence: .autoDismiss(delay: 2.0),
                escapeBehavior: .alwaysCancel,
                pauseMedia: false,       // never touch system media in fuzz
                captureFocus: false,     // never touch AX APIs in fuzz
                permissions: [.microphone]
            ),
            panel: base.panel
        )
    }

    // MARK: Schedule

    private enum Action: CaseIterable {
        case hotkey, releaseGate, emitAudio, fireDelayed, micSwitch
        case deviceChanged, sessionError, configEdit, stopAndPreserve
        case escape, closeButton, cancel
    }

    private func isAllowed(_ action: Action) -> Bool {
        switch action {
        case .escape, .closeButton, .cancel:
            return profile == .fullChaos
        default:
            return true
        }
    }

    func runSchedule(steps: Int) async {
        for _ in 0..<steps {
            let action = pick()
            guard isAllowed(action) else { continue }
            perform(action)
            // Let whatever the action spawned reach its first suspension.
            for _ in 0..<3 { await Task.yield() }
        }
        await drain()
    }

    private func pick() -> Action {
        // Weighted: gate releases and hotkeys dominate, chaos events salt.
        let roll = rng.next(upperBound: 100)
        switch roll {
        case 0..<28: return .releaseGate
        case 28..<48: return .hotkey
        case 48..<62: return .emitAudio
        case 62..<70: return .fireDelayed
        case 70..<76: return .micSwitch
        case 76..<81: return .deviceChanged
        case 81..<86: return .sessionError
        case 86..<90: return .configEdit
        case 90..<93: return .stopAndPreserve
        case 93..<96: return .escape
        case 96..<98: return .closeButton
        default: return .cancel
        }
    }

    private func perform(_ action: Action) {
        actionLog.append("\(action)@\(feature.state.phase)")
        switch action {
        case .hotkey:
            // A hotkey during .transcribing is the DESIGNED cancel gesture;
            // in the no-cancel profile skip it so strict conservation holds.
            if profile == .noCancel, feature.state.phase == .transcribing {
                return
            }
            feature.handleHotkey()
        case .releaseGate:
            gates.releaseRandom(&rng)
        case .emitAudio:
            helpers.last { $0.live }?.emitAudio()
        case .fireDelayed:
            fireRandomDelayed()
        case .micSwitch:
            let device = randomDevice()
            feature.switchMicrophone(to: device)
        case .deviceChanged:
            // Stale device events can arrive from stopped helpers too.
            helpers.randomElement(using: &rng)?
                .fireDeviceChanged(randomDevice() ?? devices[0])
        case .sessionError:
            let error: AudioSessionError = rng.next(upperBound: 2) == 0
                ? .deviceUnavailable
                : .captureFailure(underlying: "chaos")
            helpers.randomElement(using: &rng)?.fireError(error)
        case .configEdit:
            var edited = feature.config
            edited.name = "Fuzz-\(rng.next(upperBound: 1_000))"
            feature.updateConfig(edited)
        case .stopAndPreserve:
            feature.stopAndPreserve()
        case .escape:
            explicitCancels += 1
            feature.handleEscape()
        case .closeButton:
            explicitCancels += 1
            feature.handleCloseButton()
        case .cancel:
            explicitCancels += 1
            feature.cancel()
        }
    }

    private func randomDevice() -> AudioDevice? {
        let roll = rng.next(upperBound: UInt64(devices.count + 1))
        return roll == 0 ? nil : devices[Int(roll) - 1]
    }

    private func fireRandomDelayed() {
        pendingDelayed.removeAll { $0.isCancelled }
        guard !pendingDelayed.isEmpty else { return }
        let index = Int(rng.next(upperBound: UInt64(pendingDelayed.count)))
        let item = pendingDelayed.remove(at: index)
        item.perform()
    }

    /// Run everything to quiescence: no suspended gates, no pending timers,
    /// no in-flight turn. Convergence-based (see FuzzQuiescence.swift): a
    /// released continuation's job may still be queued when pendingCount
    /// reads 0 — e.g. a restarted helper's start resumed from its gate but
    /// the job that sets live=true hasn't run — so the drain ends only once
    /// the invariant-relevant fingerprint stops changing, with helper
    /// liveness part of that fingerprint, not just feature-level state.
    private func drain() async {
        let converged = await settleUntilStable(
            round: { _ in
                gates.releaseAll()
                pendingDelayed.removeAll { $0.isCancelled }
                if let item = pendingDelayed.popLast() {
                    item.perform()
                }
                for _ in 0..<10 { await Task.yield() }
                if gates.pendingCount == 0, pendingDelayed.isEmpty {
                    // The turn may be mid-hop to its transcribe gate right
                    // now — that gate parks AFTER this await starts, so a
                    // bare await deadlocks. Keep the hub flowing while we
                    // wait, exactly like drainDiscardSalvage().
                    if let turn = feature.turnTask {
                        await gates.releasingWhile { await turn.value }
                    }
                    await drainDiscardSalvage()
                }
            },
            fingerprint: { drainFingerprint() }
        )
        pendingDelayed.removeAll { $0.isCancelled }
        // turnTask may legitimately be a stale COMPLETED task here — the
        // product only nils it on the cancel path. The round above already
        // awaited it, so non-nil does not mean in-flight.
        if converged, gates.pendingCount == 0, pendingDelayed.isEmpty,
           feature.discardArchiver.currentTask == nil {
            return
        }
        violations.add(
            "drain did not reach quiescence "
            + "(converged \(converged)) — gates \(gates.pendingCount), "
            + "delayed \(pendingDelayed.count), turnTask "
            + "\(feature.turnTask == nil ? "nil" : "live"), "
            + "phase \(feature.state.phase)"
        )
    }

    /// Everything checkInvariants() reads, plus in-flight work markers.
    private func drainFingerprint() -> String {
        var parts = [
            "gates:\(gates.pendingCount)",
            "delayed:\(pendingDelayed.count)",
            "phase:\(feature.state.phase)",
            "turn:\(feature.turnTask != nil)",
            "archiver:\(feature.discardArchiver.currentTask != nil)",
            "carried:\(feature.carriedRecordingSegments.count)",
        ]
        for helper in helpers {
            parts.append(
                "h\(helper.id):\(helper.started),\(helper.live),"
                + "\(helper.bufferedCount),\(helper.discardedTotal)"
            )
        }
        for (index, spool) in spools.enumerated() {
            parts.append("s\(index):\(spool.discarded)")
        }
        return parts.joined(separator: "|")
    }

    /// Await any discard-salvage persist. Its transcript enrichment suspends
    /// on the "transcribe" gate like every other transcription, so a
    /// releaser keeps the hub flowing while we wait — awaiting directly
    /// would deadlock on a gate nobody else releases.
    private func drainDiscardSalvage() async {
        guard feature.discardArchiver.currentTask != nil else { return }
        await gates.releasingWhile { await feature.discardArchiver.drain() }
    }

    // MARK: Invariants

    func checkInvariants() async {
        // 1. No unowned capture: a live helper must BE the feature's current
        //    helper with the phase telling the truth about it.
        for helper in helpers where helper.live {
            let owned = (feature.recordingHelper as? ChaosRecordingHelper) === helper
            if !(owned && feature.state.phase == .recording && feature.isActive) {
                violations.add(
                    "helper[\(helper.id)] live without ownership "
                    + "(phase \(feature.state.phase), isActive \(feature.isActive))"
                )
            }
        }

        // 2. No stuck phases at quiescence.
        switch feature.state.phase {
        case .idle, .done, .error, .recording:
            break
        case .preparing, .transcribing, .processing:
            violations.add("stuck phase at quiescence: \(feature.state.phase)")
        }
        if feature.state.phase == .recording,
           (feature.recordingHelper as? ChaosRecordingHelper)?.live != true {
            violations.add(".recording with no live capture behind it")
        }

        // 3. Carried audio must not leak outside a recording.
        if !feature.carriedRecordingSegments.isEmpty,
           feature.state.phase != .recording {
            violations.add("carried audio leaked in phase \(feature.state.phase)")
        }

        // 4. Spool custody: outside a live recording or an errored turn
        //    still awaiting salvage, every crash spool must be resolved
        //    (discarded once its payload landed) — anything else is a
        //    disk leak accumulating across sessions.
        let liveSpools = spools.filter { !$0.discarded }
        switch feature.state.phase {
        case .recording, .error:
            // Exactly the CURRENT capture's spool may be live here.
            if liveSpools.count > 1 {
                violations.add(
                    "\(liveSpools.count) crash spools live at once in phase "
                    + "\(feature.state.phase) — predecessors leaked"
                )
            }
        default:
            if !liveSpools.isEmpty {
                violations.add(
                    "\(liveSpools.count) crash spool(s) leaked in phase "
                    + "\(feature.state.phase)"
                )
            }
        }

        // 5. Conservation — the invariant the Escape-loses-dictation bug
        //    hid behind when cancels were "legal destruction". Every fuzz
        //    audio quantum (2s) is above the discard-salvage threshold, so
        //    with history on NO entry point may destroy samples anymore:
        //    they reach the transcriber (turn or salvage), sit in a live
        //    buffer, or are carried. Cancels are allowed to OVER-deliver
        //    (a capture cancelled mid-turn is re-transcribed by the
        //    salvage), never to lose.
        let recorded = helpers.reduce(0) { $0 + $1.recordedTotal }
        let discarded = helpers.reduce(0) { $0 + $1.discardedTotal }
        let buffered = helpers.reduce(0) { $0 + $1.bufferedCount }
        let carried = feature.carriedRecordingSegments
            .reduce(0) { $0 + $1.samples.count }
        let delivered = await transcriber.receivedSamples
        let accounted = delivered + buffered + carried
        if discarded != 0 {
            violations.add(
                "a helper destroyed audio above the salvage threshold: "
                + "discarded \(discarded) of recorded \(recorded)"
            )
        }
        if profile == .noCancel {
            if accounted != recorded {
                violations.add(
                    "audio vanished without a cancel: recorded \(recorded), "
                    + "delivered \(delivered), buffered \(buffered), "
                    + "carried \(carried)"
                )
            }
        } else if accounted < recorded {
            violations.add(
                "audio vanished through a cancel path: recorded \(recorded), "
                + "delivered \(delivered), buffered \(buffered), "
                + "carried \(carried) — a discard must salvage to the "
                + "trash, never destroy"
            )
        }
    }
}

// MARK: - Small Fakes

private final class FuzzPasteProvider: PasteProviding {
    func paste(
        text: String,
        focusSnapshot: FocusSnapshot?,
        finishBehavior: FinishBehavior,
        failureBehavior: InsertionFailureBehavior
    ) async -> PasteService.Outcome { .skipped }
}

extension Array {
    /// Seeded random element — Swift's own randomElement takes a
    /// RandomNumberGenerator, but SplitMix64 is a plain struct.
    func randomElement(using rng: inout SplitMix64) -> Element? {
        guard !isEmpty else { return nil }
        return self[Int(rng.next(upperBound: UInt64(count)))]
    }
}
