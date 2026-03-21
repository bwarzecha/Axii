//
//  ModeServiceTests.swift
//  AxiiIntegrationTests
//
//  Integration tests for ModeService with injected temp directory.
//

import XCTest
@testable import Axii

@MainActor
final class ModeServiceTests: XCTestCase {

    private var modeService: ModeService!
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AxiiModeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        modeService = ModeService(modesDirectory: tempDir)
    }

    override func tearDown() async throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        modeService = nil
        tempDir = nil
    }

    // MARK: - Tests

    func testBuiltInModesCreatedIfAbsent() {
        let modes = modeService.loadAllModes()

        XCTAssertEqual(modes.count, 3, "Should create 3 built-in modes")

        let names = Set(modes.map(\.name))
        XCTAssertTrue(names.contains("Dictation"))
        XCTAssertTrue(names.contains("Conversation"))
        XCTAssertTrue(names.contains("Meeting"))

        let ids = Set(modes.map(\.id))
        XCTAssertTrue(ids.contains(DefaultModes.dictationId))
        XCTAssertTrue(ids.contains(DefaultModes.conversationId))
        XCTAssertTrue(ids.contains(DefaultModes.meetingId))
    }

    func testCustomModeSaveLoadDelete() throws {
        // Ensure built-ins exist first
        _ = modeService.loadAllModes()

        let customMode = ModeConfig(
            id: UUID(),
            name: "Custom Test Mode",
            icon: "star.fill",
            isBuiltIn: false,
            hotkey: nil,
            audioCapture: .simple(SimpleCaptureConfig()),
            transcription: .batch(BatchTranscriptionConfig()),
            processing: [],
            outputs: [.display(DisplayConfig())],
            lifecycle: LifecycleConfig(),
            panel: PanelConfig(layout: .standard)
        )

        try modeService.save(customMode)

        let allModes = modeService.loadAllModes()
        let found = allModes.first { $0.id == customMode.id }
        XCTAssertNotNil(found, "Custom mode should be found after save")
        XCTAssertEqual(found?.name, "Custom Test Mode")

        // Now total should be 4 (3 built-in + 1 custom)
        XCTAssertEqual(allModes.count, 4)

        try modeService.delete(id: customMode.id)

        let afterDelete = modeService.loadAllModes()
        let notFound = afterDelete.first { $0.id == customMode.id }
        XCTAssertNil(notFound, "Custom mode should be gone after delete")
        XCTAssertEqual(afterDelete.count, 3)
    }

    func testResetToDefaultRestoresContent() throws {
        // Load to create built-ins
        let original = modeService.loadAllModes()
        let dictation = original.first { $0.id == DefaultModes.dictationId }!

        // Modify and save
        var modified = dictation
        modified.name = "Modified Dictation"
        try modeService.save(modified)

        // Verify modification persisted
        let afterModify = modeService.loadAllModes()
        let modifiedLoaded = afterModify.first { $0.id == DefaultModes.dictationId }
        XCTAssertEqual(modifiedLoaded?.name, "Modified Dictation")

        // Reset to default
        try modeService.resetToDefault(id: DefaultModes.dictationId)

        let afterReset = modeService.loadAllModes()
        let restored = afterReset.first { $0.id == DefaultModes.dictationId }
        XCTAssertEqual(restored?.name, "Dictation", "Name should be restored to default")
    }

    func testMigrationStripsUnknownStepsAndPreservesMode() throws {
        // Start by generating a valid mode, then inject an unknown step
        let modeId = UUID()
        let validMode = ModeConfig(
            id: modeId,
            name: "Mode With Future Step",
            icon: "exclamationmark.triangle",
            isBuiltIn: false,
            hotkey: nil,
            audioCapture: .simple(SimpleCaptureConfig()),
            transcription: .batch(BatchTranscriptionConfig()),
            processing: [.segmentMerge(SegmentMergeConfig())],
            outputs: [.display(DisplayConfig())],
            lifecycle: LifecycleConfig(),
            panel: PanelConfig(layout: .standard)
        )

        // Encode the valid mode, then tamper the JSON to add an unknown step
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(validMode)
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var steps = json["processing"] as! [[String: Any]]
        steps.append(["futureUnknownStep": ["someParam": true]])
        json["processing"] = steps
        let tamperedData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])

        let fileURL = tempDir.appendingPathComponent("\(modeId.uuidString).json")
        try tamperedData.write(to: fileURL)

        // loadAllModes should migrate: strip the unknown step, keep the mode
        let modes = modeService.loadAllModes()

        let loaded = modes.first { $0.id == modeId }
        XCTAssertNotNil(loaded, "Mode should be preserved after stripping unknown steps")
        XCTAssertEqual(loaded?.name, "Mode With Future Step")

        // The known segmentMerge step should survive
        XCTAssertEqual(loaded?.processing.count, 1, "Known step should be kept")
        if case .segmentMerge = loaded?.processing.first {
            // expected
        } else {
            XCTFail("Expected segmentMerge step to survive migration")
        }

        // Built-ins should still load fine — total should be 4
        XCTAssertEqual(modes.count, 4)
    }

    func testMigrationStripsAllUnknownStepsLeavingEmptyProcessing() throws {
        // Mode with ONLY unknown steps — should still load with empty processing
        let modeId = UUID()
        let validMode = ModeConfig(
            id: modeId,
            name: "All Unknown Steps",
            icon: "questionmark",
            isBuiltIn: false,
            hotkey: nil,
            audioCapture: .simple(SimpleCaptureConfig()),
            transcription: .batch(BatchTranscriptionConfig()),
            processing: [],
            outputs: [.display(DisplayConfig())],
            lifecycle: LifecycleConfig(),
            panel: PanelConfig(layout: .standard)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(validMode)
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json["processing"] = [["totallyUnknown": ["x": 1]]]
        let tamperedData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])

        let fileURL = tempDir.appendingPathComponent("\(modeId.uuidString).json")
        try tamperedData.write(to: fileURL)

        let modes = modeService.loadAllModes()
        let loaded = modes.first { $0.id == modeId }
        XCTAssertNotNil(loaded, "Mode should be preserved even with all steps stripped")
        XCTAssertEqual(loaded?.processing.count, 0, "All unknown steps should be stripped")
    }
}
