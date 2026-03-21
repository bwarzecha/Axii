//
//  OutputHandlerTests.swift
//  AxiiIntegrationTests
//
//  Integration tests for OutputHandler output effects. Tests display, file,
//  history, and paste-outcome behavior using real OutputHandler with fake
//  PasteProviding. Turn-completion phase (.done) is owned by the processor
//  layer, not OutputHandler — these tests only assert output effects.
//

import XCTest
@testable import Axii

@MainActor
final class OutputHandlerTests: XCTestCase {

    private var historyService: HistoryService!
    private var settings: SettingsService!
    private var clipboardService: ClipboardService!
    private var pasteService: PasteService!
    private var outputHandler: OutputHandler!
    private var tempHistoryDir: URL!
    private var tempOutputDir: URL!

    override func setUp() async throws {
        // History service with temp dir
        tempHistoryDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AxiiOutputTests-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempHistoryDir, withIntermediateDirectories: true
        )
        historyService = HistoryService(historyDirectory: tempHistoryDir)

        // Temp dir for file output tests
        tempOutputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AxiiOutputTests-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempOutputDir, withIntermediateDirectories: true
        )

        // Settings with isolated UserDefaults
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        settings = SettingsService(defaults: defaults)

        // Real services (we avoid calling paste methods in tests)
        clipboardService = ClipboardService()
        let accessibilityPermission = AccessibilityPermissionService()
        pasteService = PasteService(
            clipboard: clipboardService,
            accessibilityPermission: accessibilityPermission
        )

        outputHandler = OutputHandler(
            pasteService: pasteService,
            clipboardService: clipboardService,
            historyService: historyService,
            settings: settings
        )
    }

    override func tearDown() async throws {
        if let tempHistoryDir,
           FileManager.default.fileExists(atPath: tempHistoryDir.path) {
            try? FileManager.default.removeItem(at: tempHistoryDir)
        }
        if let tempOutputDir,
           FileManager.default.fileExists(atPath: tempOutputDir.path) {
            try? FileManager.default.removeItem(at: tempOutputDir)
        }
        outputHandler = nil
        pasteService = nil
        clipboardService = nil
        settings = nil
        historyService = nil
        tempHistoryDir = nil
        tempOutputDir = nil
    }

    // MARK: - Tests

    func testDisplayOutputWritesFinalText() async {
        let context = PipelineContext(
            transcription: "Display this text",
            modeName: "Test"
        )
        let state = ModeRuntimeState()

        await outputHandler.executeOutputs(
            destinations: [.display(DisplayConfig())],
            context: context,
            state: state
        )

        XCTAssertEqual(state.finalText, "Display this text")
    }

    func testHistoryOutputSavesTranscription() async {
        let context = PipelineContext(
            transcription: "Save this to history",
            modeName: "Test"
        )
        let state = ModeRuntimeState()

        await outputHandler.executeOutputs(
            destinations: [.history(HistoryConfig(saveAudio: false))],
            context: context,
            state: state
        )

        // Verify something was saved to history
        let metadata = historyService.listMetadata()
        XCTAssertEqual(metadata.count, 1)
        XCTAssertEqual(metadata.first?.type, .transcription)

        // Load full interaction and verify text
        if let id = metadata.first?.id {
            let interaction = try? await historyService.loadInteraction(id: id)
            if case .transcription(let t) = interaction {
                XCTAssertEqual(t.text, "Save this to history")
            } else {
                XCTFail("Expected transcription interaction")
            }
        }
    }

    func testHistoryOutputWithAudioSavesCompressedRecording() async throws {
        // Synthetic sine-wave samples (AAC needs varying data, not constant)
        let sampleRate: Double = 44100
        let sampleCount = Int(sampleRate) // 1 second
        let samples: [Float] = (0..<sampleCount).map { i in
            Float(sin(Double(i) * 2.0 * .pi * 440.0 / sampleRate) * 0.5)
        }

        let context = PipelineContext(
            transcription: "Audio history test",
            samples: samples,
            sampleRate: sampleRate,
            modeName: "Test"
        )
        let state = ModeRuntimeState()

        // Execute with saveAudio: true, AAC format
        await outputHandler.executeOutputs(
            destinations: [.history(HistoryConfig(saveAudio: true, audioFormat: .aac))],
            context: context,
            state: state
        )

        // Verify transcription was saved
        let allMetadata = historyService.listMetadata()
        XCTAssertEqual(allMetadata.count, 1, "One transcription should be saved")
        let meta = allMetadata.first!
        XCTAssertEqual(meta.type, .transcription)

        // Load full interaction and verify audio recording is attached
        let interaction = try await historyService.loadInteraction(id: meta.id)
        guard case .transcription(let t) = interaction else {
            XCTFail("Expected transcription interaction")
            return
        }
        XCTAssertEqual(t.text, "Audio history test")
        XCTAssertNotNil(t.audioRecording, "AudioRecording should be attached after save-with-audio")

        let recording = t.audioRecording!
        XCTAssertTrue(recording.filename.hasSuffix(".m4a"), "Should use .m4a for AAC")
        XCTAssertEqual(recording.sampleRate, sampleRate)
        XCTAssertEqual(recording.duration, 1.0, accuracy: 0.01)

        // Verify the actual audio file exists on disk
        let audioURL = historyService.getAudioURL(recording, for: t.id)
        XCTAssertNotNil(audioURL)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: audioURL!.path),
            "Compressed audio file should exist on disk"
        )

        let attrs = try FileManager.default.attributesOfItem(atPath: audioURL!.path)
        let fileSize = attrs[.size] as? Int ?? 0
        XCTAssertGreaterThan(fileSize, 0, "Audio file should have content")

        // Verify metadata round-trips (reload from disk)
        let metadataFile = tempHistoryDir
            .appendingPathComponent(meta.folderName)
            .appendingPathComponent("metadata.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadataFile.path))

        let interactionFile = tempHistoryDir
            .appendingPathComponent(meta.folderName)
            .appendingPathComponent("interaction.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: interactionFile.path))
    }

    func testFileOutputWritesToTempPath() async {
        let outputPath = tempOutputDir.appendingPathComponent("output.txt").path
        let fileConfig = FileOutputConfig(
            pathTemplate: outputPath,
            writeMode: .overwrite,
            contentTemplate: nil,
            createDirectories: true
        )
        let context = PipelineContext(
            transcription: "File output content",
            modeName: "Test"
        )
        let state = ModeRuntimeState()

        await outputHandler.executeOutputs(
            destinations: [.file(fileConfig)],
            context: context,
            state: state
        )

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: outputPath),
            "Output file should exist"
        )

        let written = try? String(contentsOfFile: outputPath, encoding: .utf8)
        XCTAssertEqual(written, "File output content")
    }
}

// MARK: - Paste Outcome Tests

/// Tests the real OutputHandler paste-outcome branches using a fake PasteProviding.
/// These cover the user-visible state mutations for each PasteService.Outcome.
@MainActor
final class OutputHandlerPasteOutcomeTests: XCTestCase {

    private var fakePaste: FakePasteProvider!
    private var outputHandler: OutputHandler!
    private var settings: SettingsService!

    override func setUp() {
        fakePaste = FakePasteProvider()
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        settings = SettingsService(defaults: defaults)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AxiiPasteTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        outputHandler = OutputHandler(
            pasteService: fakePaste,
            clipboardService: ClipboardService(),
            historyService: HistoryService(historyDirectory: tempDir),
            settings: settings
        )
    }

    override func tearDown() {
        outputHandler = nil
        settings = nil
        fakePaste = nil
    }

    private func makeContext(_ text: String) -> PipelineContext {
        PipelineContext(transcription: text, modeName: "Test")
    }

    // MARK: - .pasted

    func testPasted_SetsFinalText() async {
        fakePaste.outcomeToReturn = .pasted
        let state = ModeRuntimeState()

        await outputHandler.executeOutputs(
            destinations: [.pasteAtCursor(PasteConfig())],
            context: makeContext("Hello"),
            state: state
        )

        XCTAssertEqual(state.finalText, "Hello")
        XCTAssertFalse(state.needsManualCopy)
    }

    // MARK: - .pastedAndCopied

    func testPastedAndCopied_SetsFinalText() async {
        fakePaste.outcomeToReturn = .pastedAndCopied
        let state = ModeRuntimeState()

        await outputHandler.executeOutputs(
            destinations: [.pasteAtCursor(PasteConfig())],
            context: makeContext("Hello"),
            state: state
        )

        XCTAssertEqual(state.finalText, "Hello")
        XCTAssertFalse(state.needsManualCopy)
    }

    // MARK: - .copiedOnly

    func testCopiedOnly_AppendsCopiedToClipboard() async {
        fakePaste.outcomeToReturn = .copiedOnly
        let state = ModeRuntimeState()

        await outputHandler.executeOutputs(
            destinations: [.pasteAtCursor(PasteConfig())],
            context: makeContext("Clipboard text"),
            state: state
        )

        XCTAssertTrue(
            state.finalText.hasSuffix("(Copied to clipboard)"),
            "Expected clipboard suffix, got: \(state.finalText)"
        )
        XCTAssertFalse(state.needsManualCopy)
    }

    // MARK: - .copiedFallback

    func testCopiedFallback_IncludesReason() async {
        fakePaste.outcomeToReturn = .copiedFallback(reason: "App not found")
        let state = ModeRuntimeState()

        await outputHandler.executeOutputs(
            destinations: [.pasteAtCursor(PasteConfig())],
            context: makeContext("Fallback text"),
            state: state
        )

        XCTAssertTrue(
            state.finalText.contains("(Copied: App not found)"),
            "Expected fallback reason, got: \(state.finalText)"
        )
        XCTAssertFalse(state.needsManualCopy)
    }

    // MARK: - .needsManualCopy

    func testNeedsManualCopy_SetsManualCopyState() async {
        fakePaste.outcomeToReturn = .needsManualCopy(reason: "No AX access")
        let state = ModeRuntimeState()

        await outputHandler.executeOutputs(
            destinations: [.pasteAtCursor(PasteConfig())],
            context: makeContext("Manual copy text"),
            state: state
        )

        XCTAssertEqual(state.finalText, "Manual copy text")
        XCTAssertTrue(state.needsManualCopy)
        XCTAssertEqual(state.manualCopyText, "Manual copy text")
    }

    // MARK: - .skipped

    func testSkipped_ShowsNoSpeechDetected() async {
        fakePaste.outcomeToReturn = .skipped
        let state = ModeRuntimeState()

        await outputHandler.executeOutputs(
            destinations: [.pasteAtCursor(PasteConfig())],
            context: makeContext("Should be overwritten"),
            state: state
        )

        XCTAssertEqual(state.finalText, "No speech detected")
        XCTAssertFalse(state.needsManualCopy)
    }
}
