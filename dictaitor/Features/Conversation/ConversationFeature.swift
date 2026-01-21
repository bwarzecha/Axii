//
//  ConversationFeature.swift
//  dictaitor
//
//  Self-contained conversation/agent feature. Registers hotkey, manages state machine.
//  Uses RecordingSessionHelper for microphone capture.
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
    private let transcriptionService: TranscriptionService
    private let micPermission: MicrophonePermissionService
    private let settings: SettingsService
    private let llmService: LLMService
    private let ttsService: TextToSpeechService
    private let playbackService: AudioPlaybackService
    private let historyService: HistoryService

    // Recording helper (created per recording)
    private var recordingHelper: RecordingSessionHelper?

    // Current conversation being built (for history)
    private var currentConversationId: UUID?

    init(
        transcriptionService: TranscriptionService,
        micPermission: MicrophonePermissionService,
        settings: SettingsService,
        llmService: LLMService,
        ttsService: TextToSpeechService,
        playbackService: AudioPlaybackService,
        historyService: HistoryService
    ) {
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
            hotkeyHint: settings.conversationHotkeyConfig.symbolString
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
        recordingHelper?.cancel()
        recordingHelper = nil
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
            interruptAndContinue()
        case .processing, .done, .error:
            cancelAndDeactivate()
        }
    }

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
        state.phase = .processing

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
        let helper = RecordingSessionHelper()
        recordingHelper = helper

        // Wire up callbacks
        helper.onVisualizationUpdate = { [weak self] update in
            guard self?.state.isListening == true else { return }
            self?.state.audioLevel = update.audioLevel
            self?.state.spectrum = update.spectrum
        }

        helper.onSignalStateChanged = { [weak self] isWaiting in
            self?.state.isWaitingForSignal = isWaiting
        }

        helper.onError = { [weak self] error in
            self?.handleSessionError(error)
        }

        Task {
            do {
                try await helper.start(source: .systemDefault)
                state.phase = .listening
                isActive = true
                context?.onActivate?(self)
            } catch let error as AudioSessionError {
                handleSessionError(error)
            } catch {
                state.phase = .error(message: "Microphone error")
                scheduleDeactivation(delay: 2.0)
            }
        }
    }

    private func handleSessionError(_ error: AudioSessionError) {
        switch error {
        case .permissionDenied:
            if micPermission.state.isBlocked {
                micPermission.openSystemSettings()
            }
            state.phase = .error(message: "Microphone permission required")
        case .deviceUnavailable:
            state.phase = .error(message: "Microphone unavailable")
        case .configurationFailed(let reason):
            state.phase = .error(message: reason)
        case .captureFailure(let reason):
            state.phase = .error(message: reason)
        }
        scheduleDeactivation(delay: 2.0)
    }

    private func stopListening() {
        guard state.isListening, let helper = recordingHelper else { return }

        let (samples, sampleRate) = helper.stop()
        recordingHelper = nil

        state.audioLevel = 0
        state.spectrum = []
        state.isWaitingForSignal = false
        state.phase = .processing

        Task {
            do {
                let text = try await transcriptionService.transcribe(
                    samples: samples,
                    sampleRate: sampleRate
                )

                if text.isEmpty {
                    state.transcript = ""
                    state.phase = .done
                    scheduleDeactivation(delay: 2.0)
                    return
                }

                state.transcript = text
                state.addUserMessage(text)

                let conversationId = await saveUserMessage(text)
                currentConversationId = conversationId

                let response: String
                if let conversationId = conversationId,
                   let messages = await loadConversationMessages(conversationId: conversationId),
                   messages.count > 1 {
                    response = try await llmService.send(messages: messages)
                } else {
                    response = try await llmService.send(message: text)
                }
                state.response = response
                state.addAssistantMessage(response)
                state.phase = .responding

                if let conversationId {
                    await updateWithAssistantMessage(conversationId: conversationId, message: response)
                }

                let audioData = try await ttsService.synthesize(text: response)

                try playbackService.play(wavData: audioData) { [weak self] in
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

    private func cancelAndDeactivate() {
        recordingHelper?.cancel()
        recordingHelper = nil
        playbackService.stop()
        resetState(clearConversation: true)
        isActive = false
        context?.onDeactivate?()
    }

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
        state.isWaitingForSignal = false
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

    private func saveUserMessage(_ text: String) async -> UUID? {
        guard historyService.isEnabled else { return currentConversationId }

        do {
            if let existingId = currentConversationId {
                let interaction = try await historyService.loadInteraction(id: existingId)
                guard case .conversation(var conversation) = interaction else {
                    return await createNewConversation(with: text)
                }
                conversation.addMessage(Message(role: .user, content: text))
                try await historyService.save(.conversation(conversation))
                return existingId
            }

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

    private func updateWithAssistantMessage(conversationId: UUID, message: String) async {
        guard historyService.isEnabled else { return }

        do {
            let interaction = try await historyService.loadInteraction(id: conversationId)
            guard case .conversation(var conversation) = interaction else { return }

            conversation.addMessage(Message(role: .assistant, content: message))

            try await historyService.save(.conversation(conversation))
        } catch {
            print("ConversationFeature: Failed to update with assistant message: \(error)")
        }
    }

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
