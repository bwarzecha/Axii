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

    func testMigrationStripsUnknownSteps() throws {
        // Write a mode JSON with an unknown processing step key
        let modeId = UUID()
        let json = """
        {
            "id": "\(modeId.uuidString)",
            "name": "Broken Mode",
            "icon": "exclamationmark.triangle",
            "isBuiltIn": false,
            "audioCapture": {
                "simple": {
                    "devicePreference": "systemDefault",
                    "enableStreamingChunks": false
                }
            },
            "transcription": {
                "batch": {
                    "minimumDuration": 0.5
                }
            },
            "processing": [
                {
                    "unknownStep": {
                        "someParam": true
                    }
                }
            ],
            "outputs": [
                {
                    "display": {}
                }
            ],
            "lifecycle": {
                "startMode": "automatic",
                "panelPersistence": {
                    "autoDismiss": {
                        "delay": 2.0
                    }
                },
                "escapeBehavior": "alwaysCancel",
                "pauseMedia": false,
                "captureFocus": false,
                "permissions": ["microphone"],
                "enableCrashRecovery": false
            },
            "panel": {
                "layout": "standard",
                "preferences": {
                    "recordingIndicatorStyle": "radialBar",
                    "transcriptDisplay": "none",
                    "showDurationTimer": false,
                    "showCopyButton": true,
                    "compactModeEnabled": false
                }
            }
        }
        """

        let fileURL = tempDir.appendingPathComponent("\(modeId.uuidString).json")
        try json.data(using: .utf8)!.write(to: fileURL)

        // loadAllModes should handle this gracefully (skip the broken mode)
        let modes = modeService.loadAllModes()

        // The broken mode should fail to decode because of the unknown processing step,
        // so it gets skipped. Only 3 built-ins should remain.
        let brokenMode = modes.first { $0.id == modeId }
        XCTAssertNil(
            brokenMode,
            "Mode with unknown processing step should be skipped during load"
        )

        // Built-ins should still load fine
        XCTAssertGreaterThanOrEqual(modes.count, 3)
    }
}
