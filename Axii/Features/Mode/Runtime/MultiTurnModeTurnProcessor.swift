//
//  MultiTurnModeTurnProcessor.swift
//  Axii
//
//  Post-capture execution processor for the multi-turn mode family.
//  Owns: transcription, empty-result handling, display message projection,
//  session store interaction, LLM request shape selection, state.finalText,
//  state.currentSessionId, phase mapping, and empty-turn dismiss.
//
//  Used by any mode that follows the multi-turn execution pattern:
//  built-in Conversation, custom multi-turn modes.
//
//  Does NOT own: hotkeys, panel lifecycle, capture start/stop,
//  activation/deactivation, or session cleanup on cancel/deactivate.
//

#if os(macOS)
import Foundation

@MainActor
final class MultiTurnModeTurnProcessor {

    private let transcriber: any TranscriptionProviding
    private let responder: any ConversationResponding
    private let sessionStore: any ConversationSessionStoring
    private weak var dismissController: (any ModeDismissControlling)?

    init(
        transcriber: any TranscriptionProviding,
        responder: any ConversationResponding,
        sessionStore: any ConversationSessionStoring,
        dismissController: any ModeDismissControlling
    ) {
        self.transcriber = transcriber
        self.responder = responder
        self.sessionStore = sessionStore
        self.dismissController = dismissController
    }

    /// Execute the multi-turn post-capture turn.
    /// Caller is responsible for setting state.phase = .processing before calling.
    func process(
        capture: CompletedCapture,
        config: MultiTurnTurnConfig,
        state: ModeRuntimeState
    ) async {
        do {
            // 1. Transcribe
            let text = try await transcriber.transcribe(
                samples: capture.samples,
                sampleRate: capture.sampleRate
            )

            // 2. Empty transcription → done + dismiss
            guard !text.isEmpty else {
                state.phase = .done
                dismissController?.scheduleDismiss(after: 2.0)
                return
            }

            // 3. Update live transcript
            state.liveTranscript = text

            // 4. Append user display message
            state.messages.append(DisplayMessage(role: .user, content: text))

            // 5. Interact with session store
            let turn = try await sessionStore.beginTurn(
                userText: text,
                currentSessionId: state.currentSessionId
            )
            state.currentSessionId = turn.sessionId

            // 6. Choose LLM request shape and get response
            let response: String
            let isExistingSession = turn.persistedMessages != nil
            if config.llmTransform.multiTurn,
               isExistingSession,
               let messages = turn.persistedMessages,
               messages.count > 1 {
                // Continuation with prior context
                response = try await responder.send(messages: messages)
            } else {
                // First turn or single-message mode
                response = try await responder.send(message: text)
            }

            // 7. Append assistant display message
            state.messages.append(DisplayMessage(role: .assistant, content: response))

            // 8. Persist assistant reply (failure does not fail the turn)
            if let sessionId = turn.sessionId {
                await sessionStore.appendAssistantReply(
                    sessionId: sessionId,
                    text: response
                )
            }

            // 9. Update final text and phase
            state.finalText = response
            state.phase = .done

        } catch {
            let msg = (error as? TranscriptionError)?.errorDescription
                ?? (error as? LocalizedError)?.errorDescription
                ?? "Processing failed"
            state.phase = .error(msg)
        }
    }
}

#endif
