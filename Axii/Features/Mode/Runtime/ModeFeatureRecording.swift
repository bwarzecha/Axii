//
//  ModeFeatureRecording.swift
//  Axii
//
//  Simple recording logic (singleShot + multiTurn) for ModeFeature.
//  Extracted to keep each file under 300 lines.
//

#if os(macOS)
import Foundation

extension ModeFeature {

    // MARK: - Simple Recording (singleShot + multiTurn)

    func startSimpleRecording() {
        // A new turn records under the LATEST config — an edit deferred
        // during the previous turn lands before anything reads it.
        applyPendingConfigIfIdle()
        // A pending dismiss from a previous turn (e.g. its "No speech
        // detected" timeout) must never fire into this new recording.
        cancelScheduledDismiss()
        turnGeneration += 1
        // Idempotency: a leftover helper (double-start) must be released,
        // and a NEW recording never inherits a previous one's audio.
        recordingHelper?.cancel(); recordingHelper = nil
        micSwitchRestartWorkItem?.cancel(); micSwitchRestartWorkItem = nil
        carriedRecordingSegments = []
        // Published SYNCHRONOUSLY: capture start can suspend for seconds on
        // a permission prompt, and a second hotkey press in that window must
        // route to .preparing (no-op), not to a second start.
        state.phase = .preparing
        if config.lifecycle.captureFocus { state.focusSnapshot = FocusSnapshot.capture() }
        if config.lifecycle.pauseMedia { Task { await mediaControlService.pauseIfPlaying() } }

        beginCaptureSession()
        Task {
            if !(await transcriptionService.isReady) { try? await transcriptionService.prepare() }
        }
    }

    /// Creates and starts the capture helper. Split from startSimpleRecording
    /// so a mid-recording mic switch can resume capture WITHOUT resetting the
    /// turn (carried audio, focus snapshot, generation all survive).
    private func beginCaptureSession() {
        let helper = makeRecordingHelper()
        recordingHelper = helper
        // Every callback is IDENTITY-GUARDED: a superseded helper's late
        // events (errors from a dying device, visualization stragglers) are
        // noise about a capture that no longer exists — acting on them can
        // poison the current turn (e.g. a stale error arming a dismiss
        // timer that later fires into a live recording).
        helper.onVisualizationUpdate = { [weak self, weak helper] update in
            guard let self, let helper, self.recordingHelper === helper,
                  self.state.phase.isRecording else { return }
            self.state.audioLevel = update.audioLevel
            self.state.spectrum = update.spectrum
        }
        helper.onSignalStateChanged = { [weak self, weak helper] waiting in
            guard let self, let helper, self.recordingHelper === helper else { return }
            self.state.isWaitingForSignal = waiting
        }
        helper.onError = { [weak self, weak helper] error in
            guard let self, let helper, self.recordingHelper === helper else { return }
            self.handleSessionError(error)
        }
        helper.onDeviceChanged = { [weak self, weak helper] device in
            guard let self, let helper, self.recordingHelper === helper else { return }
            self.state.activeCaptureDevice = device
        }

        let source: AudioSource = resolveSelectedMicrophone().map { .microphone($0) } ?? .systemDefault
        // Ownership guard: helper.start can suspend for SECONDS (permission
        // prompt, Bluetooth spin-up). If a teardown, new turn, or mic switch
        // superseded this start, the resume must not publish .recording,
        // re-activate a dismissed panel, or leave the capture running.
        let gen = turnGeneration
        Task {
            do {
                try await helper.start(source: source)
                guard self.turnGeneration == gen, self.recordingHelper === helper else {
                    helper.cancel()
                    return
                }
                // Belt: if anything published an error (with its dismiss
                // timer) while this start was suspended, that timer must
                // not fire into the recording we are about to publish.
                cancelScheduledDismiss()
                state.phase = .recording; isActive = true; context?.onActivate?(self)
                state.activeCaptureDevice = helper.currentDevice
            } catch is CancellationError {
                // The helper detected supersession itself and already tore
                // the session down; whoever superseded owns the UI.
            } catch let error as AudioSessionError {
                guard self.turnGeneration == gen, self.recordingHelper === helper else { return }
                handleSessionError(error)
            } catch {
                guard self.turnGeneration == gen, self.recordingHelper === helper else { return }
                state.phase = .error("Microphone error"); scheduleDismiss(after: 2.0)
            }
        }
    }

    func stopSimpleRecording() {
        guard state.phase.isRecording else { return }
        let capture: (samples: [Float], sampleRate: Double)
        if let helper = recordingHelper {
            capture = takeCombinedRecording(finishing: helper)
            recordingHelper = nil
        } else if let carried = takeCarriedRecording() {
            // Stop pressed inside the 0.1s mic-switch restart gap: finish
            // with the carried audio — re-arming the microphone after the
            // user commanded stop is worse than losing the gap.
            capture = carried
        } else {
            return
        }
        state.audioLevel = 0; state.isWaitingForSignal = false; state.phase = .transcribing
        state.activeCaptureDevice = nil

        processSingleShotCapture(samples: capture.samples, sampleRate: capture.sampleRate)
    }

    /// Kick off the single-shot post-capture turn. Shared by the normal stop
    /// path and the error-salvage path.
    private func processSingleShotCapture(samples: [Float], sampleRate: Double) {
        let capture = CompletedCapture(
            samples: samples,
            sampleRate: sampleRate,
            focusSnapshot: state.focusSnapshot
        )
        let turnConfig = SingleShotTurnConfig(
            modeName: config.name,
            processing: config.processing,
            outputs: config.outputs,
            panelPersistence: config.lifecycle.panelPersistence
        )

        turnGeneration += 1
        let gen = turnGeneration
        turnTask = Task { [weak self] in
            await self?.singleShotProcessor.process(
                capture: capture, config: turnConfig, state: state,
                isCurrent: { [weak self] in self?.turnGeneration == gen }
            )
            guard let self, self.turnGeneration == gen else { return }
            self.state.focusSnapshot = nil
            self.resumeMediaIfNeeded()
        }
    }

    // MARK: - Multi Turn (Conversation)

    func stopAndProcessMultiTurn() {
        guard state.phase.isRecording else { return }
        guard let processor = multiTurnProcessor else {
            state.phase = .error("Conversation not available")
            scheduleDismiss(after: 2.0)
            return
        }

        let taken: (samples: [Float], sampleRate: Double)
        if let helper = recordingHelper {
            taken = takeCombinedRecording(finishing: helper)
            recordingHelper = nil
        } else if let carried = takeCarriedRecording() {
            // Stop inside the mic-switch restart gap — see stopSimpleRecording.
            taken = carried
        } else {
            return
        }
        state.audioLevel = 0; state.isWaitingForSignal = false; state.phase = .processing
        state.activeCaptureDevice = nil

        let capture = CompletedCapture(
            samples: taken.samples, sampleRate: taken.sampleRate, focusSnapshot: nil
        )
        let llmConfig = config.processing.compactMap { step -> LLMTransformConfig? in
            if case .llmTransform(let cfg) = step { return cfg }
            return nil
        }.first ?? LLMTransformConfig(multiTurn: true)

        let turnConfig = MultiTurnTurnConfig(llmTransform: llmConfig)

        turnGeneration += 1
        let gen = turnGeneration
        turnTask = Task { [weak self] in
            await processor.process(
                capture: capture, config: turnConfig, state: state,
                isCurrent: { [weak self] in self?.turnGeneration == gen }
            )
            // Pause/resume must pair in BOTH turn families, or a paused
            // podcast stays paused forever after a successful conversation.
            guard let self, self.turnGeneration == gen else { return }
            self.resumeMediaIfNeeded()
        }
    }

    // MARK: - Recording Helpers

    func resumeMediaIfNeeded() {
        guard config.lifecycle.pauseMedia else { return }
        // A detached turn (Save & Switch) finishing while ANOTHER mode holds
        // a live capture must not blast music into that recording. Inactive
        // means displaced — leave the media alone.
        guard isActive else { return }
        Task { await mediaControlService.resumeIfWasPlaying() }
    }

    /// Stop the live helper and merge its audio with anything carried
    /// across mic switches. Clears the carried buffer.
    private func takeCombinedRecording(
        finishing helper: any RecordingSessionProviding
    ) -> (samples: [Float], sampleRate: Double) {
        let current = helper.stop()
        var segments = carriedRecordingSegments
        carriedRecordingSegments = []
        micSwitchRestartWorkItem?.cancel(); micSwitchRestartWorkItem = nil
        if !current.samples.isEmpty { segments.append(current) }
        return AudioResampler.combine(segments: segments)
    }

    /// Take the audio carried across a mic switch when no helper is live
    /// (the 0.1s restart gap, or a restart that failed). Cancels the pending
    /// restart so the microphone cannot re-arm after this capture is taken.
    private func takeCarriedRecording() -> (samples: [Float], sampleRate: Double)? {
        guard !carriedRecordingSegments.isEmpty else { return nil }
        micSwitchRestartWorkItem?.cancel(); micSwitchRestartWorkItem = nil
        let segments = carriedRecordingSegments
        carriedRecordingSegments = []
        return AudioResampler.combine(segments: segments)
    }

    func handleSessionError(_ error: AudioSessionError) {
        // Salvage a meaningful partial dictation instead of discarding it:
        // a capture failure ten minutes in should deliver ten minutes of
        // transcript, not an error toast. The error KIND is irrelevant —
        // .deviceUnavailable (only mic died), .configurationFailed, and
        // .captureFailure all leave the same salvageable samples behind.
        // The ~1s threshold is the real filter: it keeps Bluetooth warmup
        // timeouts (silence-only buffers, same error path) out.
        if state.phase.isRecording, case .singleShot = hotkeyRoute {
            let salvage: (samples: [Float], sampleRate: Double)?
            if let helper = recordingHelper {
                salvage = takeCombinedRecording(finishing: helper)
                recordingHelper = nil
            } else {
                // A failed mic-switch restart: the helper died but the audio
                // recorded before the switch is carried — it must survive.
                salvage = takeCarriedRecording()
            }
            if let (samples, sampleRate) = salvage,
               sampleRate > 0, Double(samples.count) / sampleRate > 1.0 {
                state.audioLevel = 0; state.isWaitingForSignal = false
                state.phase = .transcribing
                state.activeCaptureDevice = nil
                processSingleShotCapture(samples: samples, sampleRate: sampleRate)
                return
            }
        }
        // Whatever the error, the capture is over — stop claiming a device
        // is recording, and SUPERSEDE the turn: a start still suspended for
        // this helper must not resume into the error UI and publish a
        // recording behind the dismiss timer armed below.
        state.activeCaptureDevice = nil
        turnGeneration += 1
        recordingHelper?.cancel()
        recordingHelper = nil
        switch error {
        case .permissionDenied:
            if micPermission.state.isBlocked { micPermission.openSystemSettings() }
            state.phase = .error("Microphone permission required")
        case .deviceUnavailable: state.phase = .error("Microphone unavailable")
        case .configurationFailed(let r): state.phase = .error(r)
        case .captureFailure(let r): state.phase = .error(r)
        }
        scheduleDismiss(after: 2.0)
    }

    // MARK: - Microphone Switching

    func switchMicrophone(to device: AudioDevice?) {
        let wasRecording = state.phase.isRecording
        if wasRecording, let handler = meetingHandler {
            let source: AudioSource.MicrophoneSource = device.map { .specific($0) } ?? .systemDefault
            Task { await handler.switchMicrophone(to: device, micSource: source) }
        } else if wasRecording, let helper = recordingHelper {
            // Carry the audio across the switch — what was already said is
            // never the price of changing devices.
            let finished = helper.stop()
            recordingHelper = nil
            if !finished.samples.isEmpty {
                carriedRecordingSegments.append(finished)
            }
            state.audioLevel = 0; state.isWaitingForSignal = false
        }
        selectedDeviceUID = device?.uid; state.selectedMicrophone = device
        if wasRecording && meetingHandler == nil {
            // Cancellable + guarded: a teardown in this gap must not be
            // resurrected, and a second switch must not stack restarts.
            micSwitchRestartWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.micSwitchRestartWorkItem = nil
                guard self.isActive, self.state.phase.isRecording,
                      self.recordingHelper == nil else { return }
                self.beginCaptureSession()
            }
            micSwitchRestartWorkItem = item
            scheduleDelayed(0.1, item)
        }
    }
}
#endif
