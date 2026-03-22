//
//  MultiTurnOrchestrationTests.swift
//  AxiiIntegrationTests
//
//  Adapter-level integration tests for ModeFeature multi-turn wiring.
//  These verify that the runtime adapter correctly delegates to the
//  multi-turn processor and handles adapter-owned concerns (guard,
//  cleanup, session reset on cancel/deactivate).
//
//  The primary multi-turn behavior matrix (first turn, continuation,
//  history-disabled, empty, errors, message projection) lives in
//  MultiTurnModeTurnProcessorTests, not here.
//

import XCTest
@testable import Axii

@MainActor
final class MultiTurnOrchestrationTests: XCTestCase {

    private var fakeTranscriber: FakeTranscriber!
    private var fakePaste: FakePasteProvider!
    private var historyService: HistoryService!
    private var settings: SettingsService!
    private var clipboardService: ClipboardService!
    private var micPermission: MicrophonePermissionService!
    private var mediaControlService: MediaControlService!
    private var llmSettings: LLMSettingsService!
    private var llmService: LLMService!
    private var tempDir: URL!

    override func setUp() async throws {
        fakeTranscriber = FakeTranscriber()
        fakePaste = FakePasteProvider()

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
        llmSettings = LLMSettingsService()
        llmService = LLMService(settings: llmSettings)
    }

    override func tearDown() async throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        fakeTranscriber = nil
        fakePaste = nil
        historyService = nil
        settings = nil
        clipboardService = nil
        micPermission = nil
        mediaControlService = nil
        llmSettings = nil
        llmService = nil
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
            llmService: llmService
        )

        feature.state.phase = .recording
        feature.recordingHelper = RecordingSessionHelper()
        feature.isActive = true

        return feature
    }

    // MARK: - Adapter Wiring Tests

    /// Verify the adapter delegates to the multi-turn processor.
    /// The LLM call will fail (no real provider configured) but the
    /// adapter should still reach the error phase via the processor.
    func testAdapterDelegatesToProcessorOnMultiTurn() async throws {
        await fakeTranscriber.setTextToReturn("Hello")
        let feature = makeFeatureInRecordingState()

        XCTAssertTrue(feature.hasMultiTurnLLM)

        feature.stopAndProcessMultiTurn()

        // The LLM provider is not configured, so the processor will
        // produce an error — but the point is the adapter delegated.
        try await waitUntil { feature.state.phase != .processing }

        // Processor ran: either error (provider not configured) or done
        let phase = feature.state.phase
        let reachedProcessorOutcome = phase == .done || {
            if case .error = phase { return true }
            return false
        }()
        XCTAssertTrue(reachedProcessorOutcome,
                        "Adapter should delegate to processor, got: \(phase)")
    }

    /// Guard: stopAndProcessMultiTurn does nothing when not recording.
    func testGuardRejectsWhenNotRecording() async throws {
        let feature = makeFeatureInRecordingState()
        feature.state.phase = .idle
        feature.stopAndProcessMultiTurn()

        try await Task.sleep(for: .milliseconds(50))
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
}
