//
//  ModeTurnSalvageTests.swift
//  AxiiIntegrationTests
//
//  Contract tests from the async/state-machine audit (batch 1):
//  - ANY session error mid-recording salvages the audio, not just
//    .captureFailure — the mic dying must deliver the minutes already spoken
//  - a stop command inside the 0.1s mic-switch restart gap finalizes the
//    carried audio instead of being dropped and re-arming the microphone
//

import XCTest
@testable import Axii

@MainActor
final class ModeTurnSalvageTests: XCTestCase {

    private var settings: SettingsService!
    private var historyService: HistoryService!
    private var tempDir: URL!

    override func setUp() async throws {
        settings = SettingsService(
            defaults: UserDefaults(suiteName: "TurnSalvage-\(UUID().uuidString)")!
        )
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AxiiTurnSalvage-\(UUID().uuidString)")
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

    private func makeFeature() -> ModeFeature {
        ModeFeature(
            config: DefaultModes.dictation(),
            transcriptionService: CannedTranscriber("salvaged"),
            micPermission: MicrophonePermissionService(),
            pasteService: NoopPasteProvider(),
            clipboardService: ClipboardService(),
            settings: settings,
            historyService: historyService,
            mediaControlService: MediaControlService()
        )
    }

    /// A recording mid mic-switch: no live helper, audio carried, restart armed.
    private func putFeatureInSwitchGap(
        _ feature: ModeFeature,
        carriedSeconds: Double
    ) -> DispatchWorkItem {
        feature.state.phase = .recording
        feature.isActive = true
        feature.recordingHelper = nil
        feature.carriedRecordingSegments = [(testTone(seconds: carriedSeconds), 16_000)]
        let restart = DispatchWorkItem {}
        feature.micSwitchRestartWorkItem = restart
        return restart
    }

    // MARK: - Salvage On Any Error Kind

    func testDeviceUnavailableMidRecordingSalvagesAudio() {
        let feature = makeFeature()
        let restart = putFeatureInSwitchGap(feature, carriedSeconds: 2)

        feature.handleSessionError(.deviceUnavailable)

        XCTAssertEqual(feature.state.phase, .transcribing,
                       "The mic dying must deliver the audio already spoken, not an error toast")
        XCTAssertTrue(feature.carriedRecordingSegments.isEmpty)
        XCTAssertTrue(restart.isCancelled,
                      "The pending restart must not re-arm a mic for a salvaged turn")
    }

    func testConfigurationFailedMidRecordingSalvagesAudio() {
        let feature = makeFeature()
        _ = putFeatureInSwitchGap(feature, carriedSeconds: 2)

        feature.handleSessionError(.configurationFailed("boom"))

        XCTAssertEqual(feature.state.phase, .transcribing)
    }

    /// The ~1s threshold — not the error kind — filters Bluetooth-warmup
    /// timeouts, which arrive with only silence buffered.
    func testSubSecondRecordingStillSurfacesError() {
        let feature = makeFeature()
        _ = putFeatureInSwitchGap(feature, carriedSeconds: 0.3)

        feature.handleSessionError(.deviceUnavailable)

        XCTAssertEqual(feature.state.phase, .error("Microphone unavailable"))
    }

    // MARK: - Stop Inside The Mic-Switch Restart Gap

    func testStopDuringSwitchGapFinalizesCarriedAudio() {
        let feature = makeFeature()
        let restart = putFeatureInSwitchGap(feature, carriedSeconds: 2)

        feature.stopSimpleRecording()

        XCTAssertEqual(feature.state.phase, .transcribing,
                       "A stop command in the restart gap finishes the turn with the carried audio")
        XCTAssertTrue(restart.isCancelled,
                      "The microphone must never re-arm after the user commanded stop")
        XCTAssertTrue(feature.carriedRecordingSegments.isEmpty)
    }

    func testStopAndPreserveDuringSwitchGapDeliversCarriedAudio() {
        let feature = makeFeature()
        let restart = putFeatureInSwitchGap(feature, carriedSeconds: 2)

        feature.stopAndPreserve()

        XCTAssertEqual(feature.state.phase, .transcribing,
                       "A takeover during the restart gap must deliver the audio, not cancel it")
        XCTAssertTrue(restart.isCancelled)
        XCTAssertFalse(feature.isActive)
    }

    // MARK: - Hotkeys Are Inert During Modal Sessions

    /// Carbon hotkeys deliver during modal alerts. Acting on them corrupts
    /// the question the dialog is asking (nested dialogs, stale verdicts) —
    /// while a modal is up, the hotkey must do nothing.
    func testHotkeyIsInertWhileModalSessionActive() {
        let feature = makeFeature()
        _ = putFeatureInSwitchGap(feature, carriedSeconds: 2)
        feature.isModalSessionActive = { true }

        feature.handleHotkey()

        XCTAssertEqual(feature.state.phase, .recording,
                       "The stop keystroke must not act behind a modal dialog")

        feature.isModalSessionActive = { false }
        feature.handleHotkey()

        XCTAssertEqual(feature.state.phase, .transcribing,
                       "Once the modal is gone the same keystroke works normally")
    }
}
