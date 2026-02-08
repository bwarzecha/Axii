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
            catch { state.phase = .error("Microphone error"); scheduleDeactivation(delay: 2.0) }
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

        Task {
            defer { resumeMediaIfNeeded() }
            do {
                let text = try await transcriptionService.transcribe(samples: samples, sampleRate: sampleRate)
                if text.isEmpty {
                    state.finalText = "No speech detected"; state.phase = .done
                    scheduleDeactivation(delay: 2.0)
                } else {
                    // Build pipeline context from transcription result
                    let duration = sampleRate > 0 ? TimeInterval(samples.count) / sampleRate : nil
                    let initialContext = PipelineContext(
                        transcription: text,
                        samples: samples,
                        sampleRate: sampleRate,
                        modeName: config.name,
                        appName: state.focusSnapshot?.appName,
                        duration: duration,
                        date: Date(),
                        focusSnapshot: state.focusSnapshot
                    )

                    // Run processing pipeline if steps exist
                    let pipelineSteps = config.processing.filter {
                        // Skip multiTurn LLM steps — those use ConversationHandler
                        if case .llmTransform(let cfg) = $0 { return !cfg.multiTurn }
                        return true
                    }

                    let finalContext: PipelineContext
                    if !pipelineSteps.isEmpty {
                        state.phase = .processing
                        finalContext = try await pipelineRunner.run(
                            steps: pipelineSteps, context: initialContext
                        )
                    } else {
                        finalContext = initialContext
                    }

                    state.finalText = finalContext.text
                    await outputHandler.executeOutputs(
                        destinations: config.outputs,
                        context: finalContext,
                        state: state
                    )
                    if !state.needsManualCopy,
                       case .autoDismiss(let delay) = config.lifecycle.panelPersistence {
                        scheduleDeactivation(delay: delay)
                    }
                }
                state.focusSnapshot = nil
            } catch {
                let msg = (error as? TranscriptionError)?.errorDescription
                    ?? (error as? LocalizedError)?.errorDescription
                    ?? "Processing failed"
                state.phase = .error(msg); scheduleDeactivation(delay: 2.0)
            }
        }
    }

    // MARK: - Multi Turn (Conversation)

    func stopAndProcessMultiTurn() {
        guard state.phase.isRecording, let helper = recordingHelper else { return }
        let (samples, sampleRate) = helper.stop()
        recordingHelper = nil
        state.audioLevel = 0; state.isWaitingForSignal = false; state.phase = .processing

        Task {
            do {
                let text = try await transcriptionService.transcribe(samples: samples, sampleRate: sampleRate)
                guard !text.isEmpty else {
                    state.phase = .done
                    scheduleDeactivation(delay: 2.0)
                    return
                }
                state.liveTranscript = text

                let llmConfig = config.processing.compactMap { step -> LLMTransformConfig? in
                    if case .llmTransform(let cfg) = step { return cfg }
                    return nil
                }.first

                if let llmConfig, let handler = conversationHandler {
                    let response = try await handler.processTranscription(text, config: llmConfig)
                    state.finalText = response
                } else {
                    state.messages.append(DisplayMessage(role: .user, content: text))
                    state.finalText = text
                }
                state.phase = .done
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? "Processing failed"
                state.phase = .error(msg)
            }
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
        scheduleDeactivation(delay: 2.0)
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
