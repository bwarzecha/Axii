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
    private let historyService: HistoryService

    // VAD for auto-stop on silence
    private var vad = VoiceActivityDetector()

    // Current conversation being built (for history)
    private var currentConversationId: UUID?

    init(
        audioService: AudioCaptureService,
        transcriptionService: TranscriptionService,
        micPermission: MicrophonePermissionService,
        settings: SettingsService,
        llmService: LLMService,
        ttsService: TextToSpeechService,
        playbackService: AudioPlaybackService,
        historyService: HistoryService
    ) {
        self.audioService = audioService
        self.transcriptionService = transcriptionService
        self.micPermission = micPermission
        self.settings = settings
        self.llmService = llmService
        self.ttsService = ttsService
        self.playbackService = playbackService
        self.historyService = historyService
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
        resetState(clearConversation: true)
        isActive = false
    }

    // MARK: - Hotkey Handling

    private func handleHotkey() {
        switch state.phase {
        case .idle:
            startListeningIfReady()
        case .listening:
            stopListening()
        case .responding:
            // Interrupt TTS and continue conversation (multi-turn)
            interruptAndContinue()
        case .processing, .done, .error:
            cancelAndDeactivate()
        }
    }

    /// Interrupt current TTS playback and start listening for next turn
    private func interruptAndContinue() {
        playbackService.stop()
        startListening()
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

        // Wire audio chunk handling for this session (visualization only, no auto-stop)
        audioService.onChunk = { [weak self] chunk in
            guard let self, self.state.isListening else { return }

            // Update UI visualization
            let result = self.vad.process(chunk: chunk)
            let normalized = min(sqrt(result.rms) * 3.0, 1.0)
            self.state.audioLevel = normalized
            self.state.spectrum = SpectrumAnalyzer.calculateSpectrum(chunk.samples)
            // Manual stop only - user presses hotkey again to stop
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
                state.addUserMessage(text)

                // Save user message to history immediately
                let conversationId = await saveUserMessage(text)
                currentConversationId = conversationId

                // Get LLM response with full conversation context
                let response: String
                if let conversationId = conversationId,
                   let messages = await loadConversationMessages(conversationId: conversationId),
                   messages.count > 1 {
                    // Multi-turn: send full history
                    response = try await llmService.send(messages: messages)
                } else {
                    // Single turn or no history: send just this message
                    response = try await llmService.send(message: text)
                }
                state.response = response
                state.addAssistantMessage(response)
                state.phase = .responding

                // Update history with assistant response
                if let conversationId {
                    await updateWithAssistantMessage(conversationId: conversationId, message: response)
                }

                // Synthesize and play TTS response
                let audioData = try await ttsService.synthesize(text: response)

                try playbackService.play(wavData: audioData) { [weak self] in
                    // Natural completion - keep conversation for multi-turn
                    self?.deactivateKeepingConversation()
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

    /// Cancel current operation and start fresh (clears conversation)
    private func cancelAndDeactivate() {
        if audioService.isRecording {
            _ = audioService.stopCapture()
        }
        playbackService.stop()
        resetState(clearConversation: true)
        isActive = false
        context?.onDeactivate?()
    }

    /// Deactivate but keep conversation for multi-turn continuation
    private func deactivateKeepingConversation() {
        playbackService.stop()
        resetState(clearConversation: false)
        isActive = false
        context?.onDeactivate?()
    }

    private func resetState(clearConversation: Bool) {
        state.phase = .idle
        state.audioLevel = 0
        state.spectrum = []
        state.transcript = ""
        state.response = ""
        vad.reset()
        if clearConversation {
            currentConversationId = nil
            state.clearMessages()
        }
    }

    private func scheduleDeactivation(delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.cancelAndDeactivate()
        }
    }

    // MARK: - History

    /// Save user message immediately after transcription, returns conversation ID
    /// If continuing an existing conversation, appends to it; otherwise creates new
    private func saveUserMessage(_ text: String) async -> UUID? {
        guard historyService.isEnabled else { return currentConversationId }

        do {
            // Continue existing conversation if available
            if let existingId = currentConversationId {
                let interaction = try await historyService.loadInteraction(id: existingId)
                guard case .conversation(var conversation) = interaction else {
                    return await createNewConversation(with: text)
                }
                conversation.addMessage(Message(role: .user, content: text))
                try await historyService.save(.conversation(conversation))
                return existingId
            }

            // Create new conversation
            return await createNewConversation(with: text)
        } catch {
            print("ConversationFeature: Failed to save user message: \(error)")
            return nil
        }
    }

    private func createNewConversation(with text: String) async -> UUID? {
        let conversation = Conversation(
            messages: [Message(role: .user, content: text)]
        )

        do {
            try await historyService.save(.conversation(conversation))
            return conversation.id
        } catch {
            print("ConversationFeature: Failed to create conversation: \(error)")
            return nil
        }
    }

    /// Update conversation with assistant response
    private func updateWithAssistantMessage(conversationId: UUID, message: String) async {
        guard historyService.isEnabled else { return }

        do {
            // Load existing conversation
            let interaction = try await historyService.loadInteraction(id: conversationId)
            guard case .conversation(var conversation) = interaction else { return }

            // Add assistant message
            conversation.addMessage(Message(role: .assistant, content: message))

            // Save updated conversation
            try await historyService.save(.conversation(conversation))
        } catch {
            print("ConversationFeature: Failed to update with assistant message: \(error)")
        }
    }

    /// Load all messages from a conversation for LLM context
    private func loadConversationMessages(conversationId: UUID) async -> [Message]? {
        do {
            let interaction = try await historyService.loadInteraction(id: conversationId)
            guard case .conversation(let conversation) = interaction else { return nil }
            return conversation.messages
        } catch {
            print("ConversationFeature: Failed to load conversation messages: \(error)")
            return nil
        }
    }
}
#endif
