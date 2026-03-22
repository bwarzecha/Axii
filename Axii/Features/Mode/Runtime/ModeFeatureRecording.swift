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
        if config.lifecycle.captureFocus { state.focusSnapshot = FocusSnapshot.capture() }
        if config.lifecycle.pauseMedia { Task { await mediaControlService.pauseIfPlaying() } }

        let helper = RecordingSessionHelper()
        recordingHelper = helper
        helper.onVisualizationUpdate = { [weak self] update in
            guard self?.state.phase.isRecording == true else { return }
            self?.state.audioLevel = update.audioLevel
            self?.state.spectrum = update.spectrum
        }
        helper.onSignalStateChanged = { [weak self] in self?.state.isWaitingForSignal = $0 }
        helper.onError = { [weak self] in self?.handleSessionError($0) }

        let source: AudioSource = resolveSelectedMicrophone().map { .microphone($0) } ?? .systemDefault
        Task {
            do {
                try await helper.start(source: source)
                state.phase = .recording; isActive = true; context?.onActivate?(self)
            } catch let error as AudioSessionError { handleSessionError(error) }
            catch { state.phase = .error("Microphone error"); scheduleDismiss(after: 2.0) }
        }
        Task {
            if !(await transcriptionService.isReady) { try? await transcriptionService.prepare() }
        }
    }

    func stopSimpleRecording() {
        guard state.phase.isRecording, let helper = recordingHelper else { return }
        let (samples, sampleRate) = helper.stop()
        recordingHelper = nil
        state.audioLevel = 0; state.isWaitingForSignal = false; state.phase = .transcribing

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

        Task {
            await singleShotProcessor.process(
                capture: capture, config: turnConfig, state: state
            )
            state.focusSnapshot = nil
            resumeMediaIfNeeded()
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

        let (samples, sampleRate) = helper.stop()
        recordingHelper = nil
        state.audioLevel = 0; state.isWaitingForSignal = false; state.phase = .processing

        let capture = CompletedCapture(
            samples: samples, sampleRate: sampleRate, focusSnapshot: nil
        )
        let llmConfig = config.processing.compactMap { step -> LLMTransformConfig? in
            if case .llmTransform(let cfg) = step { return cfg }
            return nil
        }.first ?? LLMTransformConfig(multiTurn: true)

        let turnConfig = MultiTurnTurnConfig(llmTransform: llmConfig)

        Task {
            await processor.process(
                capture: capture, config: turnConfig, state: state
            )
        }
    }

    // MARK: - Recording Helpers

    func resumeMediaIfNeeded() {
        guard config.lifecycle.pauseMedia else { return }
        Task { await mediaControlService.resumeIfWasPlaying() }
    }

    func handleSessionError(_ error: AudioSessionError) {
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
        } else if wasRecording {
            recordingHelper?.cancel(); recordingHelper = nil
            state.audioLevel = 0; state.isWaitingForSignal = false
        }
        selectedDeviceUID = device?.uid; state.selectedMicrophone = device
        if wasRecording && meetingHandler == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.startSimpleRecording()
            }
        }
    }
}
#endif
