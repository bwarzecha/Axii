//
//  DictationOrchestrationTests.swift
//  AxiiIntegrationTests
//
//  Adapter-level integration tests for ModeFeature single-shot wiring.
//  These verify that the runtime adapter correctly delegates to the
//  processor and handles adapter-owned concerns (guard, cleanup, media).
//
//  The primary single-shot behavior matrix (success, empty, copy fallback,
//  manual copy, errors, dismiss decisions) lives in
//  SingleShotModeTurnProcessorTests, not here.
//

import XCTest
@testable import Axii

// MARK: - Test Doubles

actor FakeTranscriber: TranscriptionProviding {
    var isReady: Bool = true
    var textToReturn: String = "Hello world"
    var errorToThrow: Error?

    func setTextToReturn(_ text: String) {
        textToReturn = text
    }

    func setErrorToThrow(_ error: Error?) {
        errorToThrow = error
    }

    func prepare() async throws {}

    func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
        if let error = errorToThrow { throw error }
        return textToReturn
    }
}

@MainActor
final class FakePasteProvider: PasteProviding {
    var outcomeToReturn: PasteService.Outcome = .pasted
    var lastPastedText: String?

    func paste(
        text: String,
        focusSnapshot: FocusSnapshot?,
        finishBehavior: FinishBehavior,
        failureBehavior: InsertionFailureBehavior
    ) async -> PasteService.Outcome {
        lastPastedText = text
        return outcomeToReturn
    }
}

// MARK: - Tests

@MainActor
final class DictationOrchestrationTests: XCTestCase {

    private var fakeTranscriber: FakeTranscriber!
    private var fakePaste: FakePasteProvider!
    private var historyService: HistoryService!
    private var settings: SettingsService!
    private var clipboardService: ClipboardService!
    private var micPermission: MicrophonePermissionService!
    private var mediaControlService: MediaControlService!
    private var tempDir: URL!

    override func setUp() async throws {
        fakeTranscriber = FakeTranscriber()
        fakePaste = FakePasteProvider()

        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AxiiDictTests-\(UUID().uuidString)")
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
        historyService = nil
        settings = nil
        clipboardService = nil
        micPermission = nil
        mediaControlService = nil
        tempDir = nil
    }

    // MARK: - Helpers

    /// Poll until a condition becomes true or timeout expires.
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

    /// Create a minimal dictation-style ModeConfig for testing.
    private func makeDictationConfig(
        outputs: [OutputDestination]? = nil,
        panelPersistence: PanelPersistence = .autoDismiss(delay: 2.0)
    ) -> ModeConfig {
        ModeConfig(
            id: UUID(),
            name: "Test Dictation",
            icon: "mic",
            isBuiltIn: false,
            hotkey: nil,
            audioCapture: .simple(SimpleCaptureConfig()),
            transcription: .batch(BatchTranscriptionConfig()),
            processing: [],
            outputs: outputs ?? [
                .pasteAtCursor(PasteConfig()),
                .history(HistoryConfig(saveAudio: false)),
            ],
            lifecycle: LifecycleConfig(
                panelPersistence: panelPersistence,
                captureFocus: false
            ),
            panel: PanelConfig(layout: .standard)
        )
    }

    /// Build a ModeFeature with the fake services and set it up
    /// with a fresh RecordingSessionHelper in recording state.
    private func makeFeatureInRecordingState(
        config: ModeConfig? = nil
    ) -> ModeFeature {
        let cfg = config ?? makeDictationConfig()
        let feature = ModeFeature(
            config: cfg,
            transcriptionService: fakeTranscriber,
            micPermission: micPermission,
            pasteService: fakePaste,
            clipboardService: clipboardService,
            settings: settings,
            historyService: historyService,
            mediaControlService: mediaControlService
        )

        // Simulate that recording has started by setting phase and helper
        feature.state.phase = .recording
        feature.recordingHelper = RecordingSessionHelper()
        feature.isActive = true

        return feature
    }

    // MARK: - Adapter Wiring Tests

    /// Verify the adapter delegates to the processor and reaches done.
    func testAdapterDelegatesToProcessorAndReachesDone() async throws {
        await fakeTranscriber.setTextToReturn("Hello world")
        fakePaste.outcomeToReturn = .pasted

        let feature = makeFeatureInRecordingState()
        feature.stopSimpleRecording()

        try await waitUntil { feature.state.phase == .done }

        XCTAssertEqual(feature.state.finalText, "Hello world")
    }

    /// Guard: stopSimpleRecording does nothing when not recording.
    func testGuardRejectsWhenNotRecording() async throws {
        let feature = makeFeatureInRecordingState()
        feature.state.phase = .idle
        feature.stopSimpleRecording()

        // Give a brief yield to ensure no async work kicks off
        try await Task.sleep(for: .milliseconds(50))

        // Phase should remain idle — guard prevented execution
        XCTAssertEqual(feature.state.phase, .idle)
    }

    /// Verify that recording helper is cleared after stop.
    func testRecordingHelperClearedAfterStop() async throws {
        await fakeTranscriber.setTextToReturn("test")
        fakePaste.outcomeToReturn = .pasted

        let feature = makeFeatureInRecordingState()
        feature.stopSimpleRecording()

        // Helper should be cleared synchronously
        XCTAssertNil(feature.recordingHelper)
    }

    /// Verify that visualization state is cleared after stop.
    func testVisualizationStateClearedAfterStop() async throws {
        await fakeTranscriber.setTextToReturn("test")
        fakePaste.outcomeToReturn = .pasted

        let feature = makeFeatureInRecordingState()
        feature.state.audioLevel = 0.8
        feature.state.isWaitingForSignal = true
        feature.stopSimpleRecording()

        XCTAssertEqual(feature.state.audioLevel, 0)
        XCTAssertFalse(feature.state.isWaitingForSignal)
    }

    /// Verify that focusSnapshot is cleared after processing completes.
    func testFocusSnapshotClearedAfterProcessing() async throws {
        await fakeTranscriber.setTextToReturn("test")
        fakePaste.outcomeToReturn = .pasted

        let feature = makeFeatureInRecordingState()
        feature.stopSimpleRecording()

        try await waitUntil { feature.state.phase == .done }

        XCTAssertNil(feature.state.focusSnapshot)
    }
}
