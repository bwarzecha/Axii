//
//  ConversationSessionStoreTests.swift
//  AxiiIntegrationTests
//
//  Tests for ConversationSessionStore — the persisted conversation
//  session collaborator used by the multi-turn processor.
//
//  These test the persistence/session contract: creating sessions,
//  appending messages, loading context, and history-disabled behavior.
//  They do NOT test runtime state mutation or LLM request policy.
//

import XCTest
@testable import Axii

@MainActor
final class ConversationSessionStoreTests: XCTestCase {

    private var historyService: HistoryService!
    private var store: ConversationSessionStore!
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AxiiSessionStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        historyService = HistoryService(historyDirectory: tempDir)
        store = ConversationSessionStore(historyService: historyService)
    }

    override func tearDown() async throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        store = nil
        historyService = nil
        tempDir = nil
    }

    // MARK: - First Turn Creates Session

    func testFirstTurn_CreatesPersistedConversation() async throws {
        let result = try await store.beginTurn(
            userText: "Hello",
            currentSessionId: nil
        )

        XCTAssertNotNil(result.sessionId, "First turn should create a session")
        XCTAssertNil(result.persistedMessages,
                      "First turn returns nil messages (no prior context for LLM)")

        // Verify the conversation was persisted
        let interaction = try await historyService.loadInteraction(id: result.sessionId!)
        guard case .conversation(let conversation) = interaction else {
            XCTFail("Persisted interaction should be a conversation")
            return
        }
        XCTAssertEqual(conversation.messages.count, 1)
        XCTAssertEqual(conversation.messages[0].role, .user)
        XCTAssertEqual(conversation.messages[0].content, "Hello")
    }

    // MARK: - Continuation Turn Appends And Returns Messages

    func testContinuationTurn_AppendsAndReturnsMessages() async throws {
        // First turn
        let firstResult = try await store.beginTurn(
            userText: "Hello",
            currentSessionId: nil
        )
        let sessionId = firstResult.sessionId!

        // Simulate assistant reply persisted
        await store.appendAssistantReply(sessionId: sessionId, text: "Hi there!")

        // Second turn (continuation)
        let secondResult = try await store.beginTurn(
            userText: "How are you?",
            currentSessionId: sessionId
        )

        XCTAssertEqual(secondResult.sessionId, sessionId,
                        "Continuation should reuse the same session")
        XCTAssertNotNil(secondResult.persistedMessages,
                        "Continuation should return persisted messages")

        let messages = secondResult.persistedMessages!
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[0].content, "Hello")
        XCTAssertEqual(messages[1].role, .assistant)
        XCTAssertEqual(messages[1].content, "Hi there!")
        XCTAssertEqual(messages[2].role, .user)
        XCTAssertEqual(messages[2].content, "How are you?")
    }

    // MARK: - History Disabled

    func testHistoryDisabled_ReturnsNoSessionAndNoMessages() async throws {
        historyService.isEnabled = false

        let result = try await store.beginTurn(
            userText: "Hello",
            currentSessionId: nil
        )

        XCTAssertNil(result.sessionId,
                      "History-disabled mode should return no session")
        XCTAssertNil(result.persistedMessages,
                      "History-disabled mode should return no persisted messages")
    }

    func testHistoryDisabled_ContinuationAlsoStateless() async throws {
        // Enable history, create a session
        let firstResult = try await store.beginTurn(
            userText: "Hello",
            currentSessionId: nil
        )
        let sessionId = firstResult.sessionId!

        // Disable history for the next turn
        historyService.isEnabled = false

        let result = try await store.beginTurn(
            userText: "How are you?",
            currentSessionId: sessionId
        )

        XCTAssertNil(result.sessionId,
                      "With history disabled, even continuation returns no session")
        XCTAssertNil(result.persistedMessages)
    }

    // MARK: - Assistant Append Failure Is Swallowed

    func testAppendAssistantReply_SwallowsFailureOnInvalidSession() async throws {
        // Call with a non-existent session ID — should not throw
        let bogusId = UUID()
        await store.appendAssistantReply(sessionId: bogusId, text: "Reply")
        // If we get here without a crash, the failure was swallowed
    }

    func testAppendAssistantReply_PersistsSuccessfully() async throws {
        let firstResult = try await store.beginTurn(
            userText: "Hello",
            currentSessionId: nil
        )
        let sessionId = firstResult.sessionId!

        await store.appendAssistantReply(sessionId: sessionId, text: "Hi!")

        // Verify it was persisted
        let interaction = try await historyService.loadInteraction(id: sessionId)
        guard case .conversation(let conversation) = interaction else {
            XCTFail("Should be a conversation")
            return
        }
        XCTAssertEqual(conversation.messages.count, 2)
        XCTAssertEqual(conversation.messages[1].role, .assistant)
        XCTAssertEqual(conversation.messages[1].content, "Hi!")
    }

    // MARK: - Non-Conversation Mismatch Falls Back

    func testMismatchedInteractionType_FallsBackToNewSession() async throws {
        // Save a transcription interaction to create a non-conversation at a known ID
        let transcription = Transcription(text: "Some text")
        try await historyService.save(.transcription(transcription))

        // Try to continue with that ID as if it were a conversation
        let result = try await store.beginTurn(
            userText: "Hello",
            currentSessionId: transcription.id
        )

        // Should fall back to creating a new session
        XCTAssertNotNil(result.sessionId)
        XCTAssertNotEqual(result.sessionId, transcription.id,
                           "Should have created a new session, not reused the transcription")
    }
}
