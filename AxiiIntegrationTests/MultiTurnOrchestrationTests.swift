//
//  MultiTurnOrchestrationTests.swift
//  AxiiIntegrationTests
//
//  Adapter-level integration tests for ModeFeature multi-turn wiring.
//  These verify that the runtime adapter correctly delegates to the
//  multi-turn processor and handles adapter-owned concerns (guard,
//  cleanup, session reset on cancel/deactivate, error-retry).
//
//  The primary multi-turn behavior matrix (first turn, continuation,
//  history-disabled, empty, errors, message projection) lives in
//  MultiTurnModeTurnProcessorTests, not here.
//

import XCTest
@testable import Axii

// MARK: - Test Doubles

@MainActor
private final class FakeConversationResponder: ConversationResponding {
    var responseToReturn: String = "Fake response"

    func send(message: String) async throws -> String {
        responseToReturn
    }

    func send(messages: [Message]) async throws -> String {
        responseToReturn
    }
}

@MainActor
private final class FakeSessionStore: ConversationSessionStoring {
    var turnResult = PreparedConversationTurn(sessionId: nil, persistedMessages: nil)

    func beginTurn(userText: String, currentSessionId: UUID?) async throws -> PreparedConversationTurn {
        turnResult
    }

    func appendAssistantReply(sessionId: UUID, text: String) async {}
}

// MARK: - Tests

@MainActor
final class MultiTurnOrchestrationTests: XCTestCase {

    private var fakeTranscriber: FakeTranscriber!
    private var fakePaste: FakePasteProvider!
    private var fakeResponder: FakeConversationResponder!
    private var fakeStore: FakeSessionStore!
    private var historyService: HistoryService!
    private var settings: SettingsService!
    private var clipboardService: ClipboardService!
    private var micPermission: MicrophonePermissionService!
    private var mediaControlService: MediaControlService!
    private var tempDir: URL!

    override func setUp() async throws {
        fakeTranscriber = FakeTranscriber()
        fakePaste = FakePasteProvider()
        fakeResponder = FakeConversationResponder()
        fakeStore = FakeSessionStore()

        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AxiiMultiTurnTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        historyService = HistoryService(historyDirectory: tempDir)

        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        settings = SettingsService(defaults: defaults)
        clipboardService = ClipboardService()
        micPermission = MicrophonePermissionService()
        mediaControlService = MediaControlService()
    }

    override func tearDown() async throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        fakeTranscriber = nil
        fakePaste = nil
        fakeResponder = nil
        fakeStore = nil
        historyService = nil
        settings = nil
        clipboardService = nil
        micPermission = nil
        mediaControlService = nil
        tempDir = nil
    }

    // MARK: - Helpers

    private func waitUntil(
        timeout: TimeInterval = 2.0,
        interval: TimeInterval = 0.01,
        _ condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for condition after \(timeout)s")
                return
            }
            try await Task.sleep(for: .milliseconds(Int(interval * 1000)))
        }
    }

    /// Create a multi-turn conversation-style ModeConfig for testing.
    private func makeConversationConfig() -> ModeConfig {
        ModeConfig(
            id: UUID(),
            name: "Test Conversation",
            icon: "bubble.left",
            isBuiltIn: false,
            hotkey: nil,
            audioCapture: .simple(SimpleCaptureConfig()),
            transcription: .batch(BatchTranscriptionConfig()),
            processing: [
                .llmTransform(LLMTransformConfig(multiTurn: true))
            ],
            outputs: [],
            lifecycle: LifecycleConfig(panelPersistence: .stayOpen),
            panel: PanelConfig(layout: .conversation)
        )
    }

    /// Build a ModeFeature for multi-turn testing in recording state.
    /// Injects fake responder and session store directly so tests do
    /// not depend on real LLM provider configuration.
    private func makeFeatureInRecordingState(
        config: ModeConfig? = nil
    ) -> ModeFeature {
        let cfg = config ?? makeConversationConfig()
        let feature = ModeFeature(
            config: cfg,
            transcriptionService: fakeTranscriber,
            micPermission: micPermission,
            pasteService: fakePaste,
            clipboardService: clipboardService,
            settings: settings,
            historyService: historyService,
            mediaControlService: mediaControlService,
            conversationResponder: fakeResponder,
            conversationSessionStore: fakeStore
        )

        feature.state.phase = .recording
        feature.recordingHelper = RecordingSessionHelper()
        feature.isActive = true

        return feature
    }

    // MARK: - Adapter Wiring Tests

    /// Verify the adapter delegates to the multi-turn processor and reaches done.
    func testAdapterDelegatesToProcessorAndReachesDone() async throws {
        await fakeTranscriber.setTextToReturn("Hello")
        fakeResponder.responseToReturn = "Hi there"

        let feature = makeFeatureInRecordingState()
        feature.stopAndProcessMultiTurn()

        try await waitUntil { feature.state.phase == .done }

        XCTAssertEqual(feature.state.finalText, "Hi there")
        XCTAssertEqual(feature.state.phase, .done)
    }

    /// Guard: stopAndProcessMultiTurn does nothing when not recording.
    /// The guard is synchronous — no async wait needed after the call.
    func testGuardRejectsWhenNotRecording() async throws {
        let feature = makeFeatureInRecordingState()
        feature.state.phase = .idle
        feature.stopAndProcessMultiTurn()

        XCTAssertEqual(feature.state.phase, .idle)
    }

    /// Recording helper is cleared synchronously after stop.
    func testRecordingHelperClearedAfterStop() async throws {
        let feature = makeFeatureInRecordingState()
        feature.stopAndProcessMultiTurn()

        XCTAssertNil(feature.recordingHelper)
    }

    /// Visualization state is cleared synchronously after stop.
    func testVisualizationStateClearedAfterStop() async throws {
        let feature = makeFeatureInRecordingState()
        feature.state.audioLevel = 0.8
        feature.state.isWaitingForSignal = true
        feature.stopAndProcessMultiTurn()

        XCTAssertEqual(feature.state.audioLevel, 0)
        XCTAssertFalse(feature.state.isWaitingForSignal)
    }

    // MARK: - Session Cleanup on Cancel/Deactivate

    /// Cancel clears multi-turn conversation session state.
    func testCancelClearsConversationSession() async throws {
        let feature = makeFeatureInRecordingState()
        feature.state.messages = [
            DisplayMessage(role: .user, content: "Hello"),
            DisplayMessage(role: .assistant, content: "Hi")
        ]
        feature.state.currentSessionId = UUID()
        feature.state.liveTranscript = "test"
        feature.state.finalText = "response"

        feature.cancel()

        XCTAssertTrue(feature.state.messages.isEmpty,
                        "Cancel should clear messages")
        XCTAssertNil(feature.state.currentSessionId,
                      "Cancel should clear session ID")
        XCTAssertEqual(feature.state.liveTranscript, "",
                        "Cancel should clear live transcript")
        XCTAssertEqual(feature.state.finalText, "",
                        "Cancel should clear final text")
    }

    /// cancelAndDeactivate also clears conversation session state.
    func testCancelAndDeactivateClearsConversationSession() async throws {
        let feature = makeFeatureInRecordingState()
        feature.state.messages = [
            DisplayMessage(role: .user, content: "Hello")
        ]
        feature.state.currentSessionId = UUID()

        feature.cancelAndDeactivate()

        XCTAssertTrue(feature.state.messages.isEmpty)
        XCTAssertNil(feature.state.currentSessionId)
        XCTAssertFalse(feature.isActive)
    }

    /// Empty transcription reaches done and schedules dismiss via processor.
    func testEmptyTranscription_ReachesDoneViaDismiss() async throws {
        await fakeTranscriber.setTextToReturn("")
        let feature = makeFeatureInRecordingState()

        feature.stopAndProcessMultiTurn()

        try await waitUntil { feature.state.phase == .done }
        XCTAssertEqual(feature.state.phase, .done)
    }

    // MARK: - Error-Retry Preserves Conversation Session

    /// When the mode is in .error and reset() is called (as in the error-retry
    /// hotkey path), conversation session state must be preserved.
    func testErrorRetry_PreservesConversationSession() async throws {
        let feature = makeFeatureInRecordingState()
        let sessionId = UUID()

        // Simulate a conversation in progress that hit an error
        feature.state.messages = [
            DisplayMessage(role: .user, content: "Hello"),
            DisplayMessage(role: .assistant, content: "Hi there")
        ]
        feature.state.currentSessionId = sessionId
        feature.state.phase = .error("Provider failed")

        // This is what handleMultiTurnHotkey does on .error:
        feature.state.reset()

        // Conversation session must survive the reset
        XCTAssertEqual(feature.state.messages.count, 2,
                        "Messages must be preserved across error-retry reset")
        XCTAssertEqual(feature.state.currentSessionId, sessionId,
                        "Session ID must be preserved across error-retry reset")
        XCTAssertEqual(feature.state.phase, .idle,
                        "Phase should be reset to idle")
    }

    // MARK: - Nil Processor Fails Fast

    /// A mode with multi-turn config but no available processor must not
    /// get stuck in .processing. It should fail fast to .error.
    func testNilProcessor_FailsFastToError() async throws {
        let cfg = makeConversationConfig()
        let feature = ModeFeature(
            config: cfg,
            transcriptionService: fakeTranscriber,
            micPermission: micPermission,
            pasteService: fakePaste,
            clipboardService: clipboardService,
            settings: settings,
            historyService: historyService,
            mediaControlService: mediaControlService
            // No llmService → multiTurnProcessor will be nil
        )

        feature.state.phase = .recording
        feature.recordingHelper = RecordingSessionHelper()
        feature.isActive = true

        feature.stopAndProcessMultiTurn()

        // Should immediately go to error, not stay stuck in .processing
        if case .error(let msg) = feature.state.phase {
            XCTAssertTrue(msg.contains("not available"),
                           "Error message should indicate conversation is not available")
        } else {
            XCTFail("Expected error phase, got \(feature.state.phase)")
        }
    }
}
