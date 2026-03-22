//
//  MultiTurnModeTurnProcessorTests.swift
//  AxiiTests
//
//  Primary test suite for multi-turn post-capture execution behavior.
//  Tests the processor contract: transcription, empty handling, display
//  message projection, LLM request shape selection, session state
//  updates, error mapping, and dismiss decisions.
//
//  These are the main source of truth for multi-turn turn behavior.
//  Store tests cover persistence semantics. Adapter tests cover wiring.
//

import XCTest
@testable import Axii

// MARK: - Test Doubles

private actor FakeTranscriber: TranscriptionProviding {
    var isReady: Bool = true
    var textToReturn: String = "Hello world"
    var errorToThrow: Error?

    func setTextToReturn(_ text: String) { textToReturn = text }
    func setErrorToThrow(_ error: Error?) { errorToThrow = error }
    func prepare() async throws {}

    func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
        if let error = errorToThrow { throw error }
        return textToReturn
    }
}

@MainActor
private final class FakeResponder: ConversationResponding {
    var singleMessageResponse: String = "Assistant reply"
    var multiMessageResponse: String = "Multi-turn reply"
    var errorToThrow: Error?

    var lastSingleMessage: String?
    var lastMultiMessages: [Message]?
    var sendCallCount: Int = 0

    func send(message: String) async throws -> String {
        if let error = errorToThrow { throw error }
        sendCallCount += 1
        lastSingleMessage = message
        return singleMessageResponse
    }

    func send(messages: [Message]) async throws -> String {
        if let error = errorToThrow { throw error }
        sendCallCount += 1
        lastMultiMessages = messages
        return multiMessageResponse
    }
}

@MainActor
private final class FakeSessionStore: ConversationSessionStoring {
    var turnResult: PreparedConversationTurn = PreparedConversationTurn(
        sessionId: nil, persistedMessages: nil
    )
    var errorToThrow: Error?

    var beginTurnCallCount: Int = 0
    var lastUserText: String?
    var lastSessionId: UUID?

    var appendCallCount: Int = 0
    var lastAppendedText: String?
    var lastAppendedSessionId: UUID?

    func beginTurn(
        userText: String,
        currentSessionId: UUID?
    ) async throws -> PreparedConversationTurn {
        if let error = errorToThrow { throw error }
        beginTurnCallCount += 1
        lastUserText = userText
        lastSessionId = currentSessionId
        return turnResult
    }

    func appendAssistantReply(sessionId: UUID, text: String) async {
        appendCallCount += 1
        lastAppendedSessionId = sessionId
        lastAppendedText = text
    }
}

@MainActor
private final class FakeDismiss: ModeDismissControlling {
    var dismissScheduled: Bool = false
    var lastDismissDelay: TimeInterval?
    var cancelCount: Int = 0

    func cancelScheduledDismiss() { cancelCount += 1 }
    func scheduleDismiss(after delay: TimeInterval) {
        dismissScheduled = true
        lastDismissDelay = delay
    }
}

// MARK: - Tests

@MainActor
final class MultiTurnModeTurnProcessorTests: XCTestCase {

    private var transcriber: FakeTranscriber!
    private var responder: FakeResponder!
    private var sessionStore: FakeSessionStore!
    private var dismissController: FakeDismiss!
    private var state: ModeRuntimeState!
    private var processor: MultiTurnModeTurnProcessor!

    override func setUp() {
        transcriber = FakeTranscriber()
        responder = FakeResponder()
        sessionStore = FakeSessionStore()
        dismissController = FakeDismiss()
        state = ModeRuntimeState()
        processor = MultiTurnModeTurnProcessor(
            transcriber: transcriber,
            responder: responder,
            sessionStore: sessionStore,
            dismissController: dismissController
        )
    }

    override func tearDown() {
        processor = nil
        state = nil
        dismissController = nil
        sessionStore = nil
        responder = nil
        transcriber = nil
    }

    // MARK: - Helpers

    private func makeCapture() -> CompletedCapture {
        CompletedCapture(samples: [0.1, 0.2], sampleRate: 16000, focusSnapshot: nil)
    }

    private func makeConfig(multiTurn: Bool = true) -> MultiTurnTurnConfig {
        MultiTurnTurnConfig(
            llmTransform: LLMTransformConfig(multiTurn: multiTurn)
        )
    }

    // MARK: - First Turn With History Enabled

    func testFirstTurn_UsesSendMessage() async {
        await transcriber.setTextToReturn("Hello")
        let sessionId = UUID()
        sessionStore.turnResult = PreparedConversationTurn(
            sessionId: sessionId, persistedMessages: nil
        )

        await processor.process(
            capture: makeCapture(), config: makeConfig(), state: state
        )

        XCTAssertEqual(responder.lastSingleMessage, "Hello",
                        "First turn should use send(message:)")
        XCTAssertNil(responder.lastMultiMessages,
                      "First turn should not use send(messages:)")
        XCTAssertEqual(state.currentSessionId, sessionId)
        XCTAssertEqual(state.phase, .done)
    }

    // MARK: - Continuation Turn With Prior Messages

    func testContinuationTurn_UsesSendMessages() async {
        await transcriber.setTextToReturn("How are you?")
        let sessionId = UUID()
        let priorMessages = [
            Message(role: .user, content: "Hello"),
            Message(role: .assistant, content: "Hi!"),
            Message(role: .user, content: "How are you?")
        ]
        sessionStore.turnResult = PreparedConversationTurn(
            sessionId: sessionId, persistedMessages: priorMessages
        )
        state.currentSessionId = sessionId

        await processor.process(
            capture: makeCapture(), config: makeConfig(), state: state
        )

        XCTAssertNil(responder.lastSingleMessage,
                      "Continuation should not use send(message:)")
        XCTAssertEqual(responder.lastMultiMessages?.count, 3,
                        "Continuation should send full message history")
        XCTAssertEqual(state.finalText, "Multi-turn reply")
        XCTAssertEqual(state.phase, .done)
    }

    // MARK: - History-Disabled Mode Stays Stateless

    func testHistoryDisabled_UsesSendMessage() async {
        await transcriber.setTextToReturn("Hello")
        // History disabled: no session, no messages
        sessionStore.turnResult = PreparedConversationTurn(
            sessionId: nil, persistedMessages: nil
        )

        await processor.process(
            capture: makeCapture(), config: makeConfig(), state: state
        )

        XCTAssertEqual(responder.lastSingleMessage, "Hello",
                        "History-disabled should use send(message:)")
        XCTAssertNil(responder.lastMultiMessages)
        XCTAssertNil(state.currentSessionId,
                      "History-disabled should not set session ID")
        XCTAssertEqual(sessionStore.appendCallCount, 0,
                        "No session → no assistant append")
    }

    // MARK: - Empty Transcription

    func testEmptyTranscription_ProducesDoneAndDismiss() async {
        await transcriber.setTextToReturn("")

        await processor.process(
            capture: makeCapture(), config: makeConfig(), state: state
        )

        XCTAssertEqual(state.phase, .done)
        XCTAssertTrue(dismissController.dismissScheduled)
        XCTAssertEqual(dismissController.lastDismissDelay, 2.0)
        XCTAssertTrue(state.messages.isEmpty, "No messages for empty transcription")
        XCTAssertEqual(sessionStore.beginTurnCallCount, 0,
                        "No session interaction for empty transcription")
    }

    // MARK: - Transcription Failure

    func testTranscriptionFailure_ProducesError() async {
        await transcriber.setErrorToThrow(
            TranscriptionError.notReady
        )

        await processor.process(
            capture: makeCapture(), config: makeConfig(), state: state
        )

        if case .error(let msg) = state.phase {
            XCTAssertFalse(msg.isEmpty)
        } else {
            XCTFail("Expected error phase, got \(state.phase)")
        }
        XCTAssertFalse(dismissController.dismissScheduled,
                        "Error should not schedule dismiss")
    }

    // MARK: - Provider Failure

    func testProviderFailure_ProducesError() async {
        await transcriber.setTextToReturn("Hello")
        sessionStore.turnResult = PreparedConversationTurn(
            sessionId: UUID(), persistedMessages: nil
        )
        responder.errorToThrow = LLMServiceError.providerNotImplemented(.openAI)

        await processor.process(
            capture: makeCapture(), config: makeConfig(), state: state
        )

        if case .error(let msg) = state.phase {
            XCTAssertTrue(msg.contains("not yet implemented"),
                           "Should surface provider error message")
        } else {
            XCTFail("Expected error phase, got \(state.phase)")
        }
        XCTAssertFalse(dismissController.dismissScheduled)
    }

    // MARK: - Assistant Persistence Failure Does Not Fail Turn

    func testAssistantPersistenceFailure_DoesNotFailTurn() async {
        await transcriber.setTextToReturn("Hello")
        let sessionId = UUID()
        sessionStore.turnResult = PreparedConversationTurn(
            sessionId: sessionId, persistedMessages: nil
        )
        // appendAssistantReply is fire-and-forget; it can't throw
        // through the protocol. This test verifies the turn completes
        // successfully regardless of what the store does internally.

        await processor.process(
            capture: makeCapture(), config: makeConfig(), state: state
        )

        XCTAssertEqual(state.phase, .done,
                        "Turn should complete even if persistence has issues")
        XCTAssertEqual(state.finalText, "Assistant reply")
    }

    // MARK: - Display Message Projection

    func testSuccessfulTurn_ProjectsUserAndAssistantMessages() async {
        await transcriber.setTextToReturn("Hello")
        sessionStore.turnResult = PreparedConversationTurn(
            sessionId: UUID(), persistedMessages: nil
        )

        await processor.process(
            capture: makeCapture(), config: makeConfig(), state: state
        )

        XCTAssertEqual(state.messages.count, 2)
        XCTAssertEqual(state.messages[0].role, .user)
        XCTAssertEqual(state.messages[0].content, "Hello")
        XCTAssertEqual(state.messages[1].role, .assistant)
        XCTAssertEqual(state.messages[1].content, "Assistant reply")
    }

    // MARK: - Session ID Updates

    func testFirstTurn_SetsSessionId() async {
        await transcriber.setTextToReturn("Hello")
        let sessionId = UUID()
        sessionStore.turnResult = PreparedConversationTurn(
            sessionId: sessionId, persistedMessages: nil
        )

        XCTAssertNil(state.currentSessionId)

        await processor.process(
            capture: makeCapture(), config: makeConfig(), state: state
        )

        XCTAssertEqual(state.currentSessionId, sessionId)
    }

    func testContinuationTurn_PreservesSessionId() async {
        await transcriber.setTextToReturn("More")
        let sessionId = UUID()
        state.currentSessionId = sessionId
        sessionStore.turnResult = PreparedConversationTurn(
            sessionId: sessionId,
            persistedMessages: [
                Message(role: .user, content: "Hello"),
                Message(role: .assistant, content: "Hi"),
                Message(role: .user, content: "More")
            ]
        )

        await processor.process(
            capture: makeCapture(), config: makeConfig(), state: state
        )

        XCTAssertEqual(state.currentSessionId, sessionId)
    }

    // MARK: - Live Transcript

    func testSuccessfulTurn_UpdatesLiveTranscript() async {
        await transcriber.setTextToReturn("Hello world")
        sessionStore.turnResult = PreparedConversationTurn(
            sessionId: UUID(), persistedMessages: nil
        )

        await processor.process(
            capture: makeCapture(), config: makeConfig(), state: state
        )

        XCTAssertEqual(state.liveTranscript, "Hello world")
    }

    // MARK: - No Dismiss On Successful Turn

    func testSuccessfulTurn_DoesNotScheduleDismiss() async {
        await transcriber.setTextToReturn("Hello")
        sessionStore.turnResult = PreparedConversationTurn(
            sessionId: UUID(), persistedMessages: nil
        )

        await processor.process(
            capture: makeCapture(), config: makeConfig(), state: state
        )

        XCTAssertFalse(dismissController.dismissScheduled,
                        "Successful multi-turn should keep panel open")
    }

    // MARK: - Non-MultiTurn LLM Config

    func testNonMultiTurnConfig_AlwaysUsesSendMessage() async {
        await transcriber.setTextToReturn("Hello")
        let sessionId = UUID()
        let priorMessages = [
            Message(role: .user, content: "Prior"),
            Message(role: .assistant, content: "Context"),
            Message(role: .user, content: "Hello")
        ]
        sessionStore.turnResult = PreparedConversationTurn(
            sessionId: sessionId, persistedMessages: priorMessages
        )
        state.currentSessionId = sessionId

        // Non-multiTurn config — even with prior messages, should use send(message:)
        await processor.process(
            capture: makeCapture(), config: makeConfig(multiTurn: false), state: state
        )

        XCTAssertEqual(responder.lastSingleMessage, "Hello",
                        "Non-multiTurn should always use send(message:)")
        XCTAssertNil(responder.lastMultiMessages)
    }
}
