//
//  ModeUnregisterTests.swift
//  AxiiIntegrationTests
//
//  Contract tests for mode deletion teardown:
//  - unregister() releases the global hotkey (no keystroke-driveable zombie)
//  - FeatureManager refuses to unregister a busy mode (never destroys data)
//  - deletion clears the persisted per-mode device preference
//

import AppKit
import HotKey
import XCTest
@testable import Axii

@MainActor
private final class RecordingHotkeyRegistrar: HotkeyRegistering {
    private(set) var handlers: [HotkeyID: () -> Void] = [:]

    func register(
        _ id: HotkeyID,
        key: Key,
        modifiers: NSEvent.ModifierFlags,
        handler: @escaping () -> Void
    ) {
        handlers[id] = handler
    }

    func unregister(_ id: HotkeyID) {
        handlers[id] = nil
    }
}

@MainActor
final class ModeUnregisterTests: XCTestCase {

    private var hotkeys: RecordingHotkeyRegistrar!
    private var settings: SettingsService!
    private var historyService: HistoryService!
    private var tempDir: URL!

    override func setUp() async throws {
        hotkeys = RecordingHotkeyRegistrar()
        settings = SettingsService(
            defaults: UserDefaults(suiteName: "ModeUnregister-\(UUID().uuidString)")!
        )
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AxiiModeUnregister-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        historyService = HistoryService(historyDirectory: tempDir)
    }

    override func tearDown() async throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        hotkeys = nil
        settings = nil
        historyService = nil
        tempDir = nil
    }

    // MARK: - Fakes

    private actor StubTranscriber: TranscriptionProviding {
        var isReady: Bool { true }
        func prepare() async throws {}
        func transcribe(samples: [Float], sampleRate: Double) async throws -> String { "" }
    }

    private final class StubPasteProvider: PasteProviding {
        func paste(
            text: String,
            focusSnapshot: FocusSnapshot?,
            finishBehavior: FinishBehavior,
            failureBehavior: InsertionFailureBehavior
        ) async -> PasteService.Outcome { .skipped }
    }

    /// A custom (deletable) mode with its own hotkey so registration and
    /// unregistration are observable on the fake registrar.
    private func makeCustomConfig(id: UUID = UUID()) -> ModeConfig {
        var config = DefaultModes.dictation()
        return ModeConfig(
            id: id,
            name: "Custom",
            icon: "mic",
            isBuiltIn: false,
            hotkey: HotkeyConfig(key: .f19, modifiers: [.command, .shift]),
            audioCapture: config.audioCapture,
            transcription: config.transcription,
            processing: config.processing,
            outputs: config.outputs,
            lifecycle: config.lifecycle,
            panel: config.panel
        )
    }

    private func makeFeature(config: ModeConfig) -> ModeFeature {
        ModeFeature(
            config: config,
            transcriptionService: StubTranscriber(),
            micPermission: MicrophonePermissionService(),
            pasteService: StubPasteProvider(),
            clipboardService: ClipboardService(),
            settings: settings,
            historyService: historyService,
            mediaControlService: MediaControlService()
        )
    }

    private func makeContext() -> FeatureContext {
        FeatureContext(hotkeyService: hotkeys, settings: settings)
    }

    // MARK: - Hotkey Release

    func testUnregisterReleasesHotkey() {
        let config = makeCustomConfig()
        let feature = makeFeature(config: config)
        feature.register(with: makeContext())

        XCTAssertNotNil(hotkeys.handlers[.mode(config.id)],
                        "Registration must claim the mode's hotkey")

        feature.unregister()

        XCTAssertNil(hotkeys.handlers[.mode(config.id)],
                     "A removed mode must not stay keystroke-driveable")
        XCTAssertNil(feature.context)
    }

    // MARK: - Manager-Level Deletion Guard

    private func makeManager() -> FeatureManager {
        FeatureManager(hotkeyService: HotkeyService(), settings: settings)
    }

    /// A hotkey-less custom config, so manager tests never register a REAL
    /// global hotkey on the machine running the suite.
    private func makeHotkeylessConfig() -> ModeConfig {
        let base = makeCustomConfig()
        return ModeConfig(
            id: base.id, name: base.name, icon: base.icon, isBuiltIn: false,
            hotkey: nil,
            audioCapture: base.audioCapture, transcription: base.transcription,
            processing: base.processing, outputs: base.outputs,
            lifecycle: base.lifecycle, panel: base.panel
        )
    }

    func testUnregisterModeRefusedWhileRecording() {
        let config = makeHotkeylessConfig()
        let feature = makeFeature(config: config)
        let manager = makeManager()
        manager.register(feature)

        feature.state.phase = .recording

        XCTAssertFalse(manager.canDeleteMode(config.id))
        XCTAssertFalse(manager.unregisterMode(id: config.id),
                       "Deleting a recording mode must be refused, not honored destructively")
        XCTAssertNotNil(feature.context,
                        "A refused unregister must leave the mode fully wired")
    }

    func testUnregisterModeRefusedWhilePanelActive() {
        let config = makeHotkeylessConfig()
        let feature = makeFeature(config: config)
        let manager = makeManager()
        manager.register(feature)

        feature.isActive = true

        XCTAssertFalse(manager.canDeleteMode(config.id))
        XCTAssertFalse(manager.unregisterMode(id: config.id))
    }

    // MARK: - Duplicate Registration (pre-activation mode creation)

    /// A mode created before feature activation registers immediately AND
    /// again in the later registerFeatures sweep. Two live instances would
    /// split the hotkey and the editor between different configs.
    func testRegisteringSameModeIdReplacesQuiescentDuplicate() {
        let config = makeHotkeylessConfig()
        let first = makeFeature(config: config)
        let second = makeFeature(config: config)
        let manager = makeManager()

        manager.register(first)
        manager.register(second)

        XCTAssertNil(first.context, "The quiescent duplicate is fully released")
        XCTAssertNotNil(second.context, "The replacement owns the registration")
    }

    func testRegisteringSameModeIdKeepsBusyOriginal() {
        let config = makeHotkeylessConfig()
        let first = makeFeature(config: config)
        let second = makeFeature(config: config)
        let manager = makeManager()

        manager.register(first)
        first.state.phase = .recording

        manager.register(second)

        XCTAssertNotNil(first.context,
                        "A recording instance is never displaced by a duplicate")
        XCTAssertNil(second.context, "The newcomer is dropped instead")
    }

    func testUnregisterModeRemovesIdleModeAndItsPreferences() {
        let config = makeHotkeylessConfig()
        let feature = makeFeature(config: config)
        let manager = makeManager()
        manager.register(feature)
        feature.selectedDeviceUID = "usb-mic"

        XCTAssertTrue(manager.canDeleteMode(config.id))
        XCTAssertTrue(manager.unregisterMode(id: config.id))
        XCTAssertNil(feature.context)
        XCTAssertNil(UserDefaults.standard.string(forKey: feature.deviceUIDKey),
                     "A deleted mode's persisted device choice must not linger")

        // Unknown id after removal — deletion is idempotent.
        XCTAssertTrue(manager.unregisterMode(id: config.id))
        XCTAssertTrue(manager.canDeleteMode(config.id))
    }
}
