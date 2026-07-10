//
//  ModeConfigHotSwapTests.swift
//  AxiiIntegrationTests
//
//  Contract tests for editing a mode's config while it is in use:
//  - in-place edits defer while the mode holds data (the turn contract a
//    capture started under governs it to completion)
//  - the hotkey route cannot flip under a live recording
//  - capture-type changes rebuild the feature, but only when quiescent
//

import XCTest
@testable import Axii

@MainActor
final class ModeConfigHotSwapTests: XCTestCase {

    private var settings: SettingsService!
    private var historyService: HistoryService!
    private var tempDir: URL!

    override func setUp() async throws {
        settings = SettingsService(
            defaults: UserDefaults(suiteName: "ModeHotSwap-\(UUID().uuidString)")!
        )
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AxiiModeHotSwap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        historyService = HistoryService(historyDirectory: tempDir)
    }

    override func tearDown() async throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
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

    // MARK: - Helpers

    private func makeConfig(
        id: UUID = UUID(),
        name: String = "Custom",
        isDual: Bool = false,
        multiTurn: Bool = false
    ) -> ModeConfig {
        let base = DefaultModes.dictation()
        return ModeConfig(
            id: id,
            name: name,
            icon: "mic",
            isBuiltIn: false,
            hotkey: nil,
            audioCapture: isDual
                ? .dual(DualCaptureConfig(
                    devicePreference: .lastUsed, appSelection: .userSelected
                ))
                : base.audioCapture,
            transcription: base.transcription,
            processing: multiTurn
                ? [.llmTransform(LLMTransformConfig(multiTurn: true))]
                : base.processing,
            outputs: base.outputs,
            lifecycle: base.lifecycle,
            panel: base.panel
        )
    }

    private func makeFeature(config: ModeConfig) -> ModeFeature {
        ModeFeature(
            config: config,
            transcriptionService: StubTranscriber(),
            micPermission: MicrophonePermissionService(),
            screenPermission: config.audioCapture.isDual
                ? ScreenRecordingPermissionService() : nil,
            pasteService: StubPasteProvider(),
            clipboardService: ClipboardService(),
            settings: settings,
            historyService: historyService,
            mediaControlService: MediaControlService()
        )
    }

    // MARK: - Deferral While Data-Bearing

    func testEditDuringRecordingIsDeferredUntilPanelCloses() {
        let config = makeConfig(name: "Before")
        let feature = makeFeature(config: config)
        feature.state.phase = .recording
        feature.isActive = true

        var renamed = config
        renamed.name = "After"
        feature.updateConfig(renamed)

        XCTAssertEqual(feature.config.name, "Before",
                       "A live capture keeps the contract it started under")
        XCTAssertEqual(feature.pendingConfig?.name, "After")

        feature.cancelAndDeactivate()

        XCTAssertEqual(feature.config.name, "After",
                       "The deferred edit lands once nothing is in flight")
        XCTAssertNil(feature.pendingConfig)
    }

    func testEditWhileIdleAppliesImmediately() {
        let config = makeConfig(name: "Before")
        let feature = makeFeature(config: config)

        var renamed = config
        renamed.name = "After"
        feature.updateConfig(renamed)

        XCTAssertEqual(feature.config.name, "After")
        XCTAssertNil(feature.pendingConfig)
    }

    /// The concrete data-loss shape this exists to prevent: flipping a mode
    /// to multi-turn mid-recording would route the stop keystroke to a
    /// processor the mode does not have, stranding the live capture in
    /// .error while the helper still records.
    func testHotkeyRouteCannotFlipUnderLiveRecording() {
        let config = makeConfig()
        let feature = makeFeature(config: config)
        feature.state.phase = .recording
        XCTAssertEqual(feature.hotkeyRoute, .singleShot)

        feature.updateConfig(makeConfig(id: config.id, multiTurn: true))

        XCTAssertEqual(feature.hotkeyRoute, .singleShot,
                       "The stop keystroke must hit the family the recording started under")
    }

    func testLatestDeferredEditWins() {
        let config = makeConfig(name: "v1")
        let feature = makeFeature(config: config)
        feature.state.phase = .recording

        var v2 = config; v2.name = "v2"
        var v3 = config; v3.name = "v3"
        feature.updateConfig(v2)
        feature.updateConfig(v3)

        feature.state.phase = .idle
        feature.applyPendingConfigIfIdle()

        XCTAssertEqual(feature.config.name, "v3")
    }

    // MARK: - Capture-Type Rebuild (FeatureManager)

    private func makeManager() -> FeatureManager {
        FeatureManager(hotkeyService: HotkeyService(), settings: settings)
    }

    func testCaptureTypeChangeRebuildsFeatureWhenIdle() {
        let config = makeConfig()
        let feature = makeFeature(config: config)
        let manager = makeManager()
        manager.register(feature)

        var created: ModeFeature?
        manager.modeFeatureFactory = { [weak self] cfg in
            let fresh = self?.makeFeature(config: cfg)
            created = fresh
            return fresh
        }

        let dualConfig = makeConfig(id: config.id, isDual: true)
        XCTAssertTrue(manager.updateModeConfig(dualConfig))

        let fresh = created
        XCTAssertNotNil(fresh, "A capture-type change must rebuild the feature")
        XCTAssertTrue(fresh?.config.audioCapture.isDual == true)
        XCTAssertNotNil(fresh?.meetingHandler,
                        "The rebuilt feature has the runtime shape its config needs")
        XCTAssertNotNil(fresh?.context, "The rebuilt feature is registered")
        XCTAssertNil(feature.context,
                     "The replaced feature released its external footprint")
    }

    func testCaptureTypeChangeWhileRecordingDefersAndWarnsOnce() {
        let config = makeConfig()
        let feature = makeFeature(config: config)
        let manager = makeManager()
        manager.register(feature)
        manager.modeFeatureFactory = { [weak self] in self?.makeFeature(config: $0) }

        feature.state.phase = .recording

        let dualConfig = makeConfig(id: config.id, isDual: true)
        XCTAssertFalse(manager.updateModeConfig(dualConfig),
                       "The save that introduces an unappliable capture change reports it")
        XCTAssertNil(feature.meetingHandler,
                     "No rebuild under a live recording")
        XCTAssertEqual(feature.pendingConfig?.audioCapture.isDual, true)

        // The editor auto-saves every keystroke; follow-up saves of the same
        // pending capture change must not re-warn.
        var alsoRenamed = dualConfig
        alsoRenamed.name = "Renamed"
        XCTAssertTrue(manager.updateModeConfig(alsoRenamed))
        XCTAssertEqual(feature.pendingConfig?.name, "Renamed",
                       "Non-structural fields of the follow-up edit still land")
    }
}
