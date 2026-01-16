//
//  ConversationFeature.swift
//  dictaitor
//
//  Self-contained conversation/agent feature. Registers hotkey, manages state machine.
//

#if os(macOS)
import SwiftUI

/// Self-contained conversation feature for voice agent interactions.
@MainActor
final class ConversationFeature: Feature {
    let state = ConversationState()
    private var context: FeatureContext?
    private(set) var isActive = false

    // Services
    private let audioService: AudioCaptureService
    private let transcriptionService: TranscriptionService
    private let micPermission: MicrophonePermissionService
    private let settings: SettingsService
    private let llmService: LLMService
    private let ttsService: TextToSpeechService
    private let playbackService: AudioPlaybackService

    // VAD for auto-stop on silence
    private var vad = VoiceActivityDetector()

    init(
        audioService: AudioCaptureService,
        transcriptionService: TranscriptionService,
        micPermission: MicrophonePermissionService,
        settings: SettingsService,
        llmService: LLMService,
        ttsService: TextToSpeechService,
        playbackService: AudioPlaybackService
    ) {
        self.audioService = audioService
        self.transcriptionService = transcriptionService
        self.micPermission = micPermission
        self.settings = settings
        self.llmService = llmService
        self.ttsService = ttsService
        self.playbackService = playbackService
    }

    // MARK: - Feature Protocol

    var panelContent: AnyView {
        AnyView(ConversationPanelView(
            state: state,
            hotkeyHint: settings.conversationHotkeyConfig.displayString
        ))
    }

    func register(with context: FeatureContext) {
        self.context = context
        registerHotkey()

        settings.onConversationHotkeyChanged = { [weak self] in
            self?.registerHotkey()
        }
    }

    private func registerHotkey() {
        guard let context else { return }
        let config = settings.conversationHotkeyConfig
        context.hotkeyService.register(
            .conversation,
            key: config.key,
            modifiers: config.nsModifiers
        ) { [weak self] in
            self?.handleHotkey()
        }
    }

    func cancel() {
        if audioService.isRecording {
            _ = audioService.stopCapture()
        }
        playbackService.stop()
        resetState()
        isActive = false
    }

    // MARK: - Hotkey Handling

    private func handleHotkey() {
        switch state.phase {
        case .idle:
            startListeningIfReady()
        case .listening:
            stopListening()
        case .processing, .responding, .done, .error:
            cancelAndDeactivate()
        }
    }

    func handleEscape() {
        cancelAndDeactivate()
    }

    // MARK: - Conversation Flow

    private func startListeningIfReady() {
        Task {
            let isReady = await transcriptionService.isReady

            if isReady {
                startListening()
            } else {
                waitForModelAndListen()
            }
        }
    }

    private func waitForModelAndListen() {
        isActive = true
        context?.onActivate?(self)
        state.phase = .processing  // Show "loading" state

        Task {
            do {
                try await transcriptionService.prepare()
                startListening()
            } catch {
                state.phase = .error(message: "Model loading failed")
                scheduleDeactivation(delay: 3.0)
            }
        }
    }

    private func startListening() {
        // Check mic permission first
        guard micPermission.state.isAuthorized else {
            if micPermission.state.needsPrompt {
                Task { await micPermission.requestAccess() }
            } else if micPermission.state.isBlocked {
                micPermission.openSystemSettings()
            }
            state.phase = .error(message: "Microphone permission required")
            scheduleDeactivation(delay: 2.0)
            return
        }

        // Reset VAD for new session
        vad.reset()

        // Wire audio chunk handling for this session
        audioService.onChunk = { [weak self] chunk in
            guard let self, self.state.isListening else { return }

            // Update UI visualization
            let result = self.vad.process(chunk: chunk)
            let normalized = min(sqrt(result.rms) * 3.0, 1.0)
            self.state.audioLevel = normalized
            self.state.spectrum = SpectrumAnalyzer.calculateSpectrum(chunk.samples)

            // Auto-stop when speech ends
            if result.didEndSpeech {
                self.stopListening()
            }
        }

        do {
            try audioService.startCapture()
            state.phase = .listening
            isActive = true
            context?.onActivate?(self)
        } catch {
            state.phase = .error(message: "Microphone error")
            scheduleDeactivation(delay: 2.0)
        }
    }

    private func stopListening() {
        guard state.isListening else { return }

        let (samples, stats) = audioService.stopCapture()
        state.audioLevel = 0
        state.spectrum = []
        state.phase = .processing

        Task {
            do {
                // Transcribe user speech
                let text = try await transcriptionService.transcribe(
                    samples: samples,
                    sampleRate: stats.sampleRate
                )

                if text.isEmpty {
                    state.transcript = ""
                    state.phase = .done
                    scheduleDeactivation(delay: 2.0)
                    return
                }

                state.transcript = text

                // Get LLM response
                let response = try await llmService.send(message: text)
                state.response = response
                state.phase = .responding

                // Synthesize and play TTS response
                let audioData = try await ttsService.synthesize(text: response)
                try playbackService.play(wavData: audioData) { [weak self] in
                    self?.cancelAndDeactivate()
                }

            } catch {
                let message: String
                if let localizedError = error as? LocalizedError,
                   let desc = localizedError.errorDescription {
                    message = desc
                } else {
                    message = "Request failed"
                }
                state.phase = .error(message: message)
                scheduleDeactivation(delay: 3.0)
            }
        }
    }

    private func cancelAndDeactivate() {
        if audioService.isRecording {
            _ = audioService.stopCapture()
        }
        playbackService.stop()
        resetState()
        isActive = false
        context?.onDeactivate?()
    }

    private func resetState() {
        state.phase = .idle
        state.audioLevel = 0
        state.spectrum = []
        state.transcript = ""
        state.response = ""
        vad.reset()
    }

    private func scheduleDeactivation(delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.cancelAndDeactivate()
        }
    }

}
#endif
