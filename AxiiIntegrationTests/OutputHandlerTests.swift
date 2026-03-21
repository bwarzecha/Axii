//
//  OutputHandlerTests.swift
//  AxiiIntegrationTests
//
//  Integration tests for OutputHandler. Tests display, file, and history
//  outputs that do not require hardware (AppKit paste/clipboard).
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
        XCTAssertEqual(state.phase, .done)
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
        XCTAssertEqual(state.phase, .done)
    }
}
