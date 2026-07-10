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
        let helper = RecordingSessionHelper()
        recordingHelper = helper
        helper.onVisualizationUpdate = { [weak self] update in
            guard self?.state.phase.isRecording == true else { return }
            self?.state.audioLevel = update.audioLevel
            self?.state.spectrum = update.spectrum
        }
        helper.onSignalStateChanged = { [weak self] in self?.state.isWaitingForSignal = $0 }
        helper.onError = { [weak self] in self?.handleSessionError($0) }
        helper.onDeviceChanged = { [weak self] device in
            self?.state.activeCaptureDevice = device
        }

        let source: AudioSource = resolveSelectedMicrophone().map { .microphone($0) } ?? .systemDefault
        Task {
            do {
                try await helper.start(source: source)
                state.phase = .recording; isActive = true; context?.onActivate?(self)
                state.activeCaptureDevice = helper.currentDevice
            } catch let error as AudioSessionError { handleSessionError(error) }
            catch { state.phase = .error("Microphone error"); scheduleDismiss(after: 2.0) }
        }
    }

    func stopSimpleRecording() {
        guard state.phase.isRecording, let helper = recordingHelper else { return }
        let (samples, sampleRate) = takeCombinedRecording(finishing: helper)
        recordingHelper = nil
        state.audioLevel = 0; state.isWaitingForSignal = false; state.phase = .transcribing
        state.activeCaptureDevice = nil

        processSingleShotCapture(samples: samples, sampleRate: sampleRate)
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
        guard state.phase.isRecording, let helper = recordingHelper else { return }
        guard let processor = multiTurnProcessor else {
            state.phase = .error("Conversation not available")
            scheduleDismiss(after: 2.0)
            return
        }

        let (samples, sampleRate) = takeCombinedRecording(finishing: helper)
        recordingHelper = nil
        state.audioLevel = 0; state.isWaitingForSignal = false; state.phase = .processing
        state.activeCaptureDevice = nil

        let capture = CompletedCapture(
            samples: samples, sampleRate: sampleRate, focusSnapshot: nil
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
        }
    }

    // MARK: - Recording Helpers

    func resumeMediaIfNeeded() {
        guard config.lifecycle.pauseMedia else { return }
        Task { await mediaControlService.resumeIfWasPlaying() }
    }

    /// Stop the live helper and merge its audio with anything carried
    /// across mic switches. Clears the carried buffer.
    private func takeCombinedRecording(
        finishing helper: RecordingSessionHelper
    ) -> (samples: [Float], sampleRate: Double) {
        let current = helper.stop()
        var segments = carriedRecordingSegments
        carriedRecordingSegments = []
        micSwitchRestartWorkItem?.cancel(); micSwitchRestartWorkItem = nil
        if !current.samples.isEmpty { segments.append(current) }
        return AudioResampler.combine(segments: segments)
    }

    func handleSessionError(_ error: AudioSessionError) {
        // Salvage a meaningful partial dictation instead of discarding it:
        // a capture failure ten minutes in should deliver ten minutes of
        // transcript, not an error toast. The ~1s threshold keeps Bluetooth
        // warmup timeouts (silence-only buffers, same error path) out.
        if case .captureFailure = error,
           state.phase.isRecording,
           case .singleShot = hotkeyRoute,
           let helper = recordingHelper {
            let (samples, sampleRate) = takeCombinedRecording(finishing: helper)
            recordingHelper = nil
            if sampleRate > 0, Double(samples.count) / sampleRate > 1.0 {
                state.audioLevel = 0; state.isWaitingForSignal = false
                state.phase = .transcribing
                state.activeCaptureDevice = nil
                processSingleShotCapture(samples: samples, sampleRate: sampleRate)
                return
            }
        }
        // Whatever the error, the capture is over — stop claiming a device
        // is recording.
        state.activeCaptureDevice = nil
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: item)
        }
    }
}
#endif
