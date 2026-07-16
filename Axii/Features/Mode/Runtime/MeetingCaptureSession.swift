//
//  MeetingCaptureSession.swift
//  Axii
//
//  Owns the active meeting capture session: audio manager, live transcript
//  manager, chunk tasks, autosave timer control, and capture cleanup.
//
//  Concurrency model: at most one capture is live at a time ("no concurrent
//  capture sessions" is an invariant, enforced by phase gating in the UI and
//  by cancel-on-reentry in start()). Every await in this file is guarded:
//  start() publishes nothing until the capture is fully live and the epoch
//  still matches; stop() detaches the entire capture into locals before its
//  first await, so a session that starts afterwards can never be clobbered
//  by the finishing one.
//

#if os(macOS)
import Foundation

@MainActor
final class MeetingCaptureSession {
    typealias AudioManagerFactory = @MainActor () -> any MeetingAudioManaging
    typealias TranscriptManagerFactory = @MainActor () -> any MeetingTranscriptManaging

    private let audioManagerFactory: AudioManagerFactory
    private let transcriptManagerFactory: TranscriptManagerFactory

    private var audioManager: (any MeetingAudioManaging)?
    private var transcriptManager: (any MeetingTranscriptManaging)?
    // Grows by one tiny completed-task handle per streamed chunk (~480/hour)
    // and is emptied on stop/cancel; deliberately not pruned mid-recording.
    private var chunkTranscriptionTasks: [Task<Void, Never>] = []
    private var selectedApp: AudioApp?
    private var selectedMicrophone: AudioDevice?
    // One-shot per capture: re-flush the autosave when the first chunk's
    // sample rates land (see wireCallbacks).
    private var didFlushOnFirstAudio = false
    private let switches = MeetingSwitchSerializer()
    private let durationTicker = MeetingDurationTicker()
    private let powerMonitor = MeetingPowerMonitor()

    // Bumped by start/stop/cancel. An operation that resumes from an await
    // and finds the epoch changed must not publish or mutate session state.
    private var epoch = 0

    var onAudioLevel: ((Float) -> Void)?
    var onSegmentsUpdated: (([MeetingSegment]) -> Void)?
    var onError: ((String) -> Void)?
    var onDurationUpdated: ((TimeInterval) -> Void)?

    var isRecording: Bool {
        audioManager != nil
    }

    init(
        transcriptionService: any TranscriptionProviding,
        audioManagerFactory: @escaping AudioManagerFactory = {
            MeetingAudioManager()
        },
        transcriptManagerFactory: TranscriptManagerFactory? = nil
    ) {
        self.audioManagerFactory = audioManagerFactory
        self.transcriptManagerFactory = transcriptManagerFactory ?? {
            MeetingTranscriptManager(transcriptionService: transcriptionService)
        }
        durationTicker.onTick = { [weak self] duration in
            self?.onDurationUpdated?(duration)
        }
        // Sleep mid-meeting: protect the recording FIRST (the autosave may
        // be up to 60s stale, and the machine may never wake), then stop
        // counting time the audio pipeline will not capture.
        powerMonitor.onWillSleep = { [weak self] in
            guard let self, self.isRecording else { return }
            self.flushAutoSaveNow()
            self.durationTicker.pause()
        }
        powerMonitor.onDidWake = { [weak self] in
            guard let self, self.isRecording else { return }
            self.durationTicker.resume()
        }
    }

    deinit {
        for task in chunkTranscriptionTasks {
            task.cancel()
        }
    }

    // MARK: - Start

    func start(configuration: MeetingCaptureStartConfiguration) async throws {
        if audioManager != nil || transcriptManager != nil {
            cancel()
        }
        epoch += 1
        let startEpoch = epoch
        didFlushOnFirstAudio = false
        durationTicker.reset()

        selectedApp = configuration.selectedApp
        selectedMicrophone = configuration.selectedMicrophone

        let audio = audioManagerFactory()
        let transcript = transcriptManagerFactory()
        wireCallbacks(
            audio: audio,
            transcript: transcript,
            streamingEnabled: configuration.streamingEnabled
        )
        transcript.setSelectedApp(configuration.selectedApp)
        transcript.reset()

        do {
            try await audio.start(
                micSource: resolveMicSource(),
                appSelection: resolveAppSelection()
            )
        } catch {
            clearCallbacks(audio: audio, transcript: transcript)
            audio.cleanupTempFiles()
            throw error
        }

        // stop()/cancel()/start() arrived while audio was starting: this
        // capture must never be published. Teardown must happen HERE — audio
        // is fully started at this point, so its stop() works, whereas the
        // earlier cancel() saw a partial start and its stop() was a no-op.
        guard epoch == startEpoch else {
            clearCallbacks(audio: audio, transcript: transcript)
            _ = audio.stop()
            audio.cleanupTempFiles()
            throw CancellationError()
        }

        audioManager = audio
        transcriptManager = transcript
        transcript.startAutoSave()
        durationTicker.start()
        powerMonitor.beginRecording(reason: "Axii is recording a meeting")
    }

    // MARK: - Stop

    func stop(saveToHistory: Bool) async -> MeetingCapturedAudio? {
        let capture = detachCurrentCapture()
        await switches.settle()

        guard let audio = capture.audio else {
            return nil
        }

        let stoppedAudio = audio.stop()

        guard saveToHistory else {
            capture.transcript?.clearAutoSave()
            audio.cleanupTempFiles()
            return nil
        }

        // The autosave cadence is 60s; flush the freshest transcript to the
        // recovery file before the long finalize/persist window opens.
        capture.transcript?.flushAutoSave()

        for task in capture.pendingTasks {
            await task.value
        }

        // Off-main: an hour-long capture's spool is ~700MB per track; the
        // capture is already detached, so awaiting here cannot be clobbered
        // by a newer session (detach-before-await invariant).
        let micSamples = await audio.readSamplesFromFileOffMain(stoppedAudio.micFile)
        let systemSamples = await audio.readSamplesFromFileOffMain(stoppedAudio.systemFile)

        // The AUDIO is the truth for persisted duration: the wall clock kept
        // running through any system sleep, the samples did not. The ticker
        // value is only the fallback for captures whose spool never
        // materialized.
        let micDuration = stoppedAudio.micRate > 0
            ? Double(micSamples.count) / stoppedAudio.micRate : 0
        let systemDuration = stoppedAudio.systemRate > 0
            ? Double(systemSamples.count) / stoppedAudio.systemRate : 0
        let audioDuration = max(micDuration, systemDuration)

        // Recovery artifacts (autosave + temp audio) are NOT cleaned here:
        // finalization and persistence still lie ahead, and a crash there
        // must stay recoverable. The persistence caller commits them.
        return MeetingCapturedAudio(
            micSamples: micSamples,
            micSampleRate: stoppedAudio.micRate,
            systemSamples: systemSamples,
            systemSampleRate: stoppedAudio.systemRate,
            duration: audioDuration > 0 ? audioDuration : capture.duration,
            appName: capture.appName,
            recoveryArtifacts: capture.transcript.map {
                MeetingRecoveryArtifacts(
                    sessionID: $0.sessionID,
                    autosaveFileURL: $0.autosaveFileURL,
                    micFileURL: stoppedAudio.micFile,
                    systemFileURL: stoppedAudio.systemFile
                )
            }
        )
    }

    // MARK: - Cancel

    func cancel() {
        let capture = detachCurrentCapture()
        // Snapshot NOW: a switch mid-flight would resurrect audio after a
        // synchronous stop, so discard is deferred behind it — but only
        // behind switches that already exist, never behind a newer
        // session's chain.
        guard let pending = switches.currentPending else {
            discard(capture)
            return
        }
        Task { @MainActor in
            await pending.value
            self.discard(capture)
        }
    }

    private func discard(_ capture: DetachedCapture) {
        _ = capture.audio?.stop()
        capture.transcript?.clearAutoSave()
        capture.audio?.cleanupTempFiles()
    }

    // MARK: - App Selection

    func selectApp(_ app: AudioApp?) {
        selectedApp = app
        transcriptManager?.setSelectedApp(app)

        guard let audioManager else { return }
        let micSource = resolveMicSource()
        switches.run {
            try? await audioManager.switchApp(to: app, micSource: micSource)
        }
    }

    // MARK: - Microphone Switching

    func switchMicrophone(
        to device: AudioDevice?,
        selectedApp: AudioApp?,
        micSource: AudioSource.MicrophoneSource? = nil
    ) async {
        selectedMicrophone = device
        self.selectedApp = selectedApp

        guard let audioManager else { return }
        let source = micSource ?? resolveMicSource()
        let task = switches.run {
            try? await audioManager.switchApp(to: selectedApp, micSource: source)
        }
        await task.value
    }

    /// Write the live transcript to the recovery file immediately — called
    /// when an error puts the recording at risk of a destructive exit.
    func flushAutoSaveNow() {
        transcriptManager?.flushAutoSave()
    }

    // MARK: - Crash Recovery

    func checkCrashRecovery() -> MeetingCrashRecovery? {
        transcriptManagerFactory().checkForCrashRecovery()
    }

    // MARK: - Private: Detach & Teardown

    private struct DetachedCapture {
        let audio: (any MeetingAudioManaging)?
        let transcript: (any MeetingTranscriptManaging)?
        let pendingTasks: [Task<Void, Never>]
        let duration: TimeInterval
        let appName: String?
    }

    /// Removes the live capture from session state synchronously — no awaits.
    /// After this returns, nothing in this class references the capture; the
    /// caller owns it exclusively and a new start() cannot touch it.
    private func detachCurrentCapture() -> DetachedCapture {
        epoch += 1
        durationTicker.stop()
        powerMonitor.endRecording()

        let capture = DetachedCapture(
            audio: audioManager,
            transcript: transcriptManager,
            pendingTasks: chunkTranscriptionTasks,
            duration: durationTicker.duration,
            appName: selectedApp?.name
        )
        audioManager = nil
        transcriptManager = nil
        chunkTranscriptionTasks = []

        capture.transcript?.stopAutoSave()
        for task in capture.pendingTasks {
            task.cancel()
        }
        clearCallbacks(audio: capture.audio, transcript: capture.transcript)
        return capture
    }

    private func clearCallbacks(
        audio: (any MeetingAudioManaging)?,
        transcript: (any MeetingTranscriptManaging)?
    ) {
        audio?.onAudioLevel = nil
        audio?.onTranscriptionChunk = nil
        audio?.onError = nil
        transcript?.onSegmentsUpdated = nil
        transcript?.audioFileReferenceProvider = nil
    }

    // MARK: - Private: Callback Wiring

    private func wireCallbacks(
        audio: any MeetingAudioManaging,
        transcript: any MeetingTranscriptManaging,
        streamingEnabled: Bool
    ) {
        audio.onAudioLevel = { [weak self, weak transcript] level in
            guard let self else { return }
            // The initial autosave at start indexes the spool files before
            // the sample rates are known (they arrive with the first chunk).
            // Re-flush once on the first audio activity so a crash after
            // second one carries real rates, not zeros.
            if !self.didFlushOnFirstAudio, let transcript,
               self.transcriptManager === transcript {
                self.didFlushOnFirstAudio = true
                transcript.flushAutoSave()
            }
            self.onAudioLevel?(level)
        }
        audio.onError = { [weak self] message in
            self?.onError?(message)
        }
        transcript.onSegmentsUpdated = { [weak self] segments in
            self?.onSegmentsUpdated?(segments)
        }
        transcript.audioFileReferenceProvider = { [weak audio] in
            audio?.audioFileReferences
        }

        guard streamingEnabled else {
            audio.onTranscriptionChunk = nil
            return
        }
        audio.onTranscriptionChunk = { [weak self, weak transcript] chunk in
            // The identity check drops chunks that raced a detach: once a
            // capture is detached its transcript is no longer published here.
            guard let self, let transcript,
                  self.transcriptManager === transcript else { return }
            let task = transcript.transcribeChunk(chunk)
            self.chunkTranscriptionTasks.append(task)
        }
    }

    // MARK: - Private: Source Resolution

    private func resolveMicSource() -> AudioSource.MicrophoneSource {
        if let selectedMicrophone {
            return .specific(selectedMicrophone)
        }
        return .systemDefault
    }

    private func resolveAppSelection() -> AppSelection {
        if let selectedApp {
            return .only([selectedApp])
        }
        return .all
    }
}
#endif
