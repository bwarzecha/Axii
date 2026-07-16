//
//  MeetingInteractionFuzzSupport.swift
//  AxiiIntegrationTests
//
//  Meeting-mode interaction fuzzing: the REAL adapter stack — ModeFeature →
//  MeetingPipelineHandler → MeetingCaptureSession — over the gate-controlled
//  chaos capture fakes, driven through the UI entry points (hotkey, panel
//  buttons, Escape, mic switches, capture errors, config edits) with
//  persistence success/failure/history-off all seeded.
//

import Foundation
@testable import Axii

// MARK: - Permission Fakes

@MainActor
final class FuzzMicPermission: MeetingMicrophonePermissionChecking {
    var state: MicrophonePermissionService.State = .authorized
    func openSystemSettings() {}
}

@MainActor
final class FuzzScreenPermission: MeetingScreenRecordingPermissionChecking {
    var isGranted = true
    func request() {}
}

// MARK: - Seeded Persistence

/// Gate-suspended persistence whose outcome (success / throw / silent
/// no-write) is decided per call by the schedule's RNG.
@MainActor
final class FuzzPersistence: MeetingPersisting {
    enum Outcome { case succeed, fail, writeNothing }

    private let gates: GateHub
    var nextOutcome: () -> Outcome = { .succeed }
    private(set) var persistCalls = 0
    private(set) var successes = 0

    init(gates: GateHub) {
        self.gates = gates
    }

    func persist(
        payload: MeetingPersistencePayload,
        audioFormat: AudioStorageFormat
    ) async throws -> Meeting? {
        persistCalls += 1
        await gates.pass("persist")
        switch nextOutcome() {
        case .succeed:
            successes += 1
            return Meeting(
                segments: payload.segments,
                duration: payload.duration,
                appName: payload.appName
            )
        case .fail:
            throw ChaosError.startFailed
        case .writeNothing:
            return nil
        }
    }
}

// MARK: - Meeting Fuzz Driver

@MainActor
final class MeetingModeFuzzDriver {
    let feature: ModeFeature
    let gates: GateHub
    let violations: ViolationLog
    let registry: ChaosRegistry
    let persistence: FuzzPersistence
    private let handler: MeetingPipelineHandler

    private(set) var pendingDelayed: [DispatchWorkItem] = []
    private(set) var actionLog: [String] = []
    private var rng: SplitMix64

    private let devices = [
        AudioDevice(id: 1, uid: "mic-a", name: "Mic A", transportType: .usb),
        AudioDevice(id: 2, uid: "built-in", name: "Built-in", transportType: .builtIn),
    ]

    init(
        seed: UInt64,
        settings: SettingsService,
        historyService: HistoryService
    ) {
        var rng = SplitMix64(seed: seed)
        self.gates = GateHub()
        self.violations = ViolationLog()
        self.registry = ChaosRegistry(gates: gates, violations: violations)
        self.persistence = FuzzPersistence(gates: gates)

        // A quarter of the runs exercise the history-off/export machinery.
        historyService.isEnabled = rng.next(upperBound: 4) != 0
        self.rng = rng

        let transcriber = NullTranscriber()
        let feature = ModeFeature(
            config: Self.fuzzConfig(),
            transcriptionService: transcriber,
            micPermission: MicrophonePermissionService(),
            pasteService: MeetingFuzzPasteProvider(),
            clipboardService: ClipboardService(),
            settings: settings,
            historyService: historyService,
            mediaControlService: MediaControlService(),
            meetingPersistence: persistence
        )
        self.feature = feature

        let registry = self.registry
        var failRNG = SplitMix64(seed: seed ^ 0xDEAD_BEEF)
        let captureSession = MeetingCaptureSession(
            transcriptionService: transcriber,
            audioManagerFactory: {
                registry.makeAudio(failStart: failRNG.next(upperBound: 6) == 0)
            },
            transcriptManagerFactory: { registry.makeTranscript() }
        )
        let handler = MeetingPipelineHandler(
            state: feature.state,
            transcriptionService: transcriber,
            screenPermission: ScreenRecordingPermissionService(),
            micPermission: MicrophonePermissionService(),
            settings: settings,
            startCoordinator: MeetingStartCoordinator(
                transcriptionService: transcriber,
                screenPermission: FuzzScreenPermission(),
                micPermission: FuzzMicPermission()
            ),
            captureSession: captureSession,
            // Deterministic: the real provider reaches ScreenCaptureKit
            // (TCC-gated, real XPC latency) — it floods unentitled CI
            // runners with permission errors and perturbs schedules so
            // failing seeds do not replay.
            appListProvider: { [] }
        )
        self.handler = handler
        feature.meetingHandler = handler

        feature.isModalSessionActive = { false }
        feature.busyChoiceProvider = { .stay }
        feature.historyOffConfirmProvider = { true }
        feature.scheduleDelayed = { [unowned self] _, item in
            self.pendingDelayed.append(item)
        }
        persistence.nextOutcome = { [unowned self] in
            switch self.rng.next(upperBound: 6) {
            case 0: .fail
            case 1: .writeNothing
            default: .succeed
            }
        }
    }

    private static func fuzzConfig() -> ModeConfig {
        let base = DefaultModes.meeting()
        return ModeConfig(
            id: UUID(),
            name: "FuzzMeeting",
            icon: "person.2",
            isBuiltIn: false,
            hotkey: nil,
            audioCapture: base.audioCapture,
            transcription: base.transcription,
            processing: [],
            outputs: [.display(DisplayConfig())],
            lifecycle: LifecycleConfig(
                startMode: .manual,
                panelPersistence: .stayOpen,
                escapeBehavior: .blockWhileRecording,
                permissions: [.microphone, .screenRecording],
                enableCrashRecovery: false // recovery is fuzzed elsewhere
            ),
            panel: base.panel
        )
    }

    // MARK: Schedule

    private enum Action {
        case hotkey, startButton, stopButton, closeButton, escape
        case releaseGate, emitChunk, captureError, micSwitch
        case configEdit, stopAndPreserve, cancel, fireDelayed
    }

    private func pick() -> Action {
        switch rng.next(upperBound: 100) {
        case 0..<30: .releaseGate
        case 30..<42: .hotkey
        case 42..<52: .startButton
        case 52..<62: .stopButton
        case 62..<70: .emitChunk
        case 70..<76: .captureError
        case 76..<82: .micSwitch
        case 82..<86: .escape
        case 86..<90: .closeButton
        case 90..<94: .configEdit
        case 94..<97: .stopAndPreserve
        case 97..<99: .cancel
        default: .fireDelayed
        }
    }

    func runSchedule(steps: Int) async {
        // Every meeting run begins with the panel, like a real user.
        feature.showMeetingPanel()
        for _ in 0..<steps {
            perform(pick())
            for _ in 0..<3 { await Task.yield() }
            trace("POST[\(actionLog.count - 1)] \(actionLog.last ?? "")")
        }
        await drain()
    }

    /// Sidecar state timeline for single-seed debugging (xcodebuild logs
    /// swallow test-host stdout). AXII_FUZZ_TRACE_FILE=<path> to enable.
    private func trace(_ label: String) {
        guard let tracePath = ProcessInfo.processInfo
            .environment["AXII_FUZZ_TRACE_FILE"] else { return }
        let live = registry.audios.filter(\.live).map(\.id)
        let line = "\(label) phase=\(feature.state.phase) live=\(live) "
            + "hasLive=\(handler.hasLiveCapture) "
            + "active=\(feature.isActive) "
            + "stopTask=\(feature.meetingStopTask != nil)\n"
        if let handle = FileHandle(forWritingAtPath: tracePath) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        } else {
            FileManager.default.createFile(
                atPath: tracePath, contents: Data(line.utf8)
            )
        }
    }

    private func perform(_ action: Action) {
        actionLog.append("\(action)@\(feature.state.phase)")
        switch action {
        case .hotkey:
            feature.handleHotkey()
        case .startButton:
            feature.startMeeting()
        case .stopButton:
            feature.stopMeeting(saveToHistory: true)
        case .closeButton:
            feature.handleCloseButton()
        case .escape:
            feature.handleEscape()
        case .releaseGate:
            gates.releaseRandom(&rng)
        case .emitChunk:
            registry.liveAudio?.emitChunk()
        case .captureError:
            registry.audios.randomElement(using: &rng)?.onError?("chaos error")
        case .micSwitch:
            feature.switchMicrophone(to: devices.randomElement(using: &rng))
        case .configEdit:
            var edited = feature.config
            edited.name = "FuzzMeeting-\(rng.next(upperBound: 1_000))"
            feature.updateConfig(edited)
        case .stopAndPreserve:
            feature.stopAndPreserve()
        case .cancel:
            feature.cancel()
        case .fireDelayed:
            pendingDelayed.removeAll { $0.isCancelled }
            guard !pendingDelayed.isEmpty else { return }
            let index = Int(rng.next(upperBound: UInt64(pendingDelayed.count)))
            pendingDelayed.remove(at: index).perform()
        }
    }

    private func drain() async {
        for step in 0..<300 {
            gates.releaseAll()
            pendingDelayed.removeAll { $0.isCancelled }
            if let item = pendingDelayed.popLast() {
                item.perform()
            }
            for _ in 0..<10 { await Task.yield() }
            trace("DRAIN[\(step)]")
            if gates.pendingCount == 0, pendingDelayed.isEmpty {
                if let stop = feature.meetingStopTask { await stop.value }
                for _ in 0..<10 { await Task.yield() }
                pendingDelayed.removeAll { $0.isCancelled }
                if gates.pendingCount == 0, pendingDelayed.isEmpty,
                   feature.meetingStopTask == nil {
                    return
                }
            }
        }
        violations.add(
            "drain did not reach quiescence — gates \(gates.pendingCount), "
            + "delayed \(pendingDelayed.count), stopTask "
            + "\(feature.meetingStopTask == nil ? "nil" : "live"), "
            + "phase \(feature.state.phase)"
        )
    }

    // MARK: Invariants

    func checkInvariants() {
        // 1. A live capture must be owned and truthfully phased. .error
        //    legitimately keeps the capture live (exits salvage it).
        for audio in registry.audios where audio.live {
            let phaseAllowsLive: Bool = switch feature.state.phase {
            case .recording, .error: true
            default: false
            }
            if !handler.hasLiveCapture || !phaseAllowsLive {
                violations.add(
                    "audio[\(audio.id)] live without ownership "
                    + "(hasLiveCapture \(handler.hasLiveCapture), "
                    + "phase \(feature.state.phase), "
                    + "isActive \(feature.isActive), "
                    + "stopTaskInFlight \(feature.meetingStopTask != nil))"
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
        if feature.state.phase == .recording, !handler.hasLiveCapture {
            violations.add(".recording with no live capture behind it")
        }

        // 3. The export window only exists where a user can see it.
        if feature.pendingMeetingExport != nil, !feature.isActive {
            violations.add("export offer parked in a closed panel")
        }
    }
}

private final class MeetingFuzzPasteProvider: PasteProviding {
    func paste(
        text: String,
        focusSnapshot: FocusSnapshot?,
        finishBehavior: FinishBehavior,
        failureBehavior: InsertionFailureBehavior
    ) async -> PasteService.Outcome { .skipped }
}
