//
//  DiscardSalvageTests.swift
//  AxiiIntegrationTests
//
//  Discard-to-trash for simple captures: the user's exact bug report was
//  "accidentally hit ESC in dictate mode — the recording is lost". These
//  tests pin the fix: every user-initiated discard of a dictation or
//  conversation capture ≥1s lands in "Recently Deleted" (audio + best-
//  effort transcript), restorable — never destroyed. Sub-second captures,
//  delivered turns, and history-off stay out of the trash.
//

import XCTest
@testable import Axii

@MainActor
final class DiscardSalvageTests: XCTestCase {

    private var settings: SettingsService!
    private var historyService: HistoryService!
    private var tempDir: URL!

    override func setUp() async throws {
        settings = SettingsService(
            defaults: UserDefaults(suiteName: "DiscardSalvage-\(UUID().uuidString)")!
        )
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AxiiDiscardSalvage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        historyService = HistoryService(historyDirectory: tempDir)
        historyService.isEnabled = true
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

    /// A live capture holding a fixed number of seconds of audio.
    @MainActor
    private final class StubRecordingHelper: RecordingSessionProviding {
        var currentDevice: AudioDevice?
        var onVisualizationUpdate: ((VisualizationUpdate) -> Void)?
        var onSignalStateChanged: ((Bool) -> Void)?
        var onError: ((AudioSessionError) -> Void)?
        var onDeviceChanged: ((AudioDevice) -> Void)?
        var captureSpool: (any CaptureSpooling)?

        private var samples: [Float]
        private(set) var cancelled = false

        init(seconds: Double) {
            samples = testTone(seconds: seconds)
        }

        func start(source: AudioSource) async throws {}
        func stop() -> (samples: [Float], sampleRate: Double) {
            defer { samples = [] }
            return (samples, 16_000)
        }
        func cancel() {
            cancelled = true
            samples = []
        }
    }

    private func makeFeature(
        config: ModeConfig = DefaultModes.dictation(),
        transcriber: any TranscriptionProviding = CannedTranscriber("salvaged words")
    ) -> ModeFeature {
        ModeFeature(
            config: config,
            transcriptionService: transcriber,
            micPermission: MicrophonePermissionService(),
            pasteService: NoopPasteProvider(),
            clipboardService: ClipboardService(),
            settings: settings,
            historyService: historyService,
            mediaControlService: MediaControlService()
        )
    }

    private func putFeatureInRecording(
        _ feature: ModeFeature, seconds: Double
    ) -> StubRecordingHelper {
        let helper = StubRecordingHelper(seconds: seconds)
        feature.recordingHelper = helper
        feature.state.phase = .recording
        feature.isActive = true
        return helper
    }

    private func awaitSalvage(_ feature: ModeFeature) async {
        await feature.discardArchiver.drain()
    }

    private func discardedTranscriptions() -> [InteractionMetadata] {
        historyService.discardedMetadata().filter { $0.type == .transcription }
    }

    // MARK: - The reported bug: Escape mid-recording

    func testEscapeMidRecordingLandsCaptureInRecentlyDeleted() async {
        let feature = makeFeature()
        let helper = putFeatureInRecording(feature, seconds: 2)

        feature.handleEscape()
        await awaitSalvage(feature)

        let discarded = discardedTranscriptions()
        XCTAssertEqual(discarded.count, 1,
                       "an accidental Escape must trash the capture, not destroy it")
        XCTAssertFalse(helper.cancelled,
                       "the helper was stopped (audio taken), never cancelled")
        XCTAssertEqual(discarded.first?.preview, "salvaged words",
                       "the trashed capture is enriched with its transcript")
        if case .transcription(let details) = discarded.first!.details {
            XCTAssertTrue(details.hasAudio, "audio is the recovery guarantee")
        } else {
            XCTFail("expected transcription details")
        }
        XCTAssertTrue(historyService.activeMetadata().isEmpty,
                      "a discarded capture must not appear in the main list")
    }

    func testCloseButtonMidRecordingSalvages() async {
        let feature = makeFeature()
        _ = putFeatureInRecording(feature, seconds: 2)

        feature.handleCloseButton()
        await awaitSalvage(feature)

        XCTAssertEqual(discardedTranscriptions().count, 1)
    }

    // MARK: - Cancel after stop (in-flight turn)

    func testEscapeDuringTranscribingSalvagesInFlightCapture() async {
        let feature = makeFeature()
        feature.inFlightTurnCapture = (
            StubRecordingHelper(seconds: 2).stop().samples, 16_000
        )
        feature.state.phase = .transcribing
        feature.isActive = true

        feature.handleEscape()
        await awaitSalvage(feature)

        XCTAssertEqual(discardedTranscriptions().count, 1,
                       "cancelling during transcription must not lose the capture")
    }

    // MARK: - Errored turns

    func testErroredTurnIsSalvagedOnTeardown() async {
        let feature = makeFeature(transcriber: ThrowingTranscriber())
        _ = putFeatureInRecording(feature, seconds: 2)

        feature.stopSimpleRecording()
        await feature.turnTask?.value
        guard case .error = feature.state.phase else {
            return XCTFail("expected the turn to error, got \(feature.state.phase)")
        }

        feature.cancelAndDeactivate()
        await awaitSalvage(feature)

        let discarded = discardedTranscriptions()
        XCTAssertEqual(discarded.count, 1,
                       "a turn that died undelivered keeps its audio in the trash")
        XCTAssertEqual(discarded.first?.preview,
                       Transcription.discardedPreviewPlaceholder,
                       "no transcript (ASR failed) — placeholder preview, audio kept")
    }

    func testConversationSessionErrorSalvagesToTrash() async {
        let feature = makeFeature(config: DefaultModes.conversation())
        _ = putFeatureInRecording(feature, seconds: 2)

        feature.handleSessionError(.deviceUnavailable)
        await awaitSalvage(feature)

        XCTAssertEqual(discardedTranscriptions().count, 1,
                       "a conversation capture error must trash the audio, not destroy it")
    }

    // MARK: - What must NOT reach the trash

    func testSubSecondCaptureIsNotTrashed() async {
        let feature = makeFeature()
        _ = putFeatureInRecording(feature, seconds: 0.3)

        feature.handleEscape()
        await awaitSalvage(feature)

        XCTAssertTrue(discardedTranscriptions().isEmpty,
                      "sub-second accidental opens must not spam the trash")
        XCTAssertTrue(historyService.activeMetadata().isEmpty)
        XCTAssertEqual(feature.state.phase, .idle)
    }

    func testDeliveredTurnCreatesNoDiscardedEntry() async {
        let feature = makeFeature()
        _ = putFeatureInRecording(feature, seconds: 2)

        feature.stopSimpleRecording()
        await feature.turnTask?.value
        XCTAssertEqual(feature.state.phase, .done)

        feature.cancelAndDeactivate()
        await awaitSalvage(feature)

        XCTAssertTrue(discardedTranscriptions().isEmpty,
                      "a delivered turn's normal dismiss must not duplicate into the trash")
        XCTAssertEqual(historyService.activeMetadata().count, 1,
                       "the delivered turn saved normally")
    }

    func testHistoryDisabledSkipsSalvage() async {
        historyService.isEnabled = false
        let feature = makeFeature()
        _ = putFeatureInRecording(feature, seconds: 2)

        feature.handleEscape()
        await awaitSalvage(feature)

        XCTAssertTrue(historyService.discardedMetadata().isEmpty,
                      "history off is the user's explicit opt-out of any persistence")
    }

    // MARK: - Trash round trip

    func testRestoreDiscardedTranscriptionReturnsItToMainList() async throws {
        let entry = Transcription(text: "restore me", discardedAt: Date())
        try await historyService.save(.transcription(entry))
        XCTAssertEqual(discardedTranscriptions().count, 1)

        let restored = try await historyService.restoreDiscarded(id: entry.id)

        XCTAssertTrue(restored)
        XCTAssertTrue(historyService.discardedMetadata().isEmpty)
        XCTAssertEqual(historyService.activeMetadata().first?.preview, "restore me")
    }

    func testSweepRemovesExpiredDiscardedTranscription() async throws {
        let old = Transcription(
            text: "expired",
            discardedAt: Date().addingTimeInterval(-8 * 24 * 3_600)
        )
        try await historyService.save(.transcription(old))

        await historyService.sweepExpiredDiscards()

        XCTAssertTrue(historyService.discardedMetadata().isEmpty,
                      "the trash retention window applies to dictations like meetings")
    }

    // MARK: - Crash-spool custody

    @MainActor
    private final class FakeSpool: CaptureSpooling {
        private(set) var discarded = false
        func append(samples: [Float], sampleRate: Double) {}
        func noteDevice(_ device: AudioDevice?) {}
        func discard() { discarded = true }
    }

    func testDeliveredTurnDiscardsItsCrashSpool() async {
        let feature = makeFeature()
        let spool = FakeSpool()
        feature.activeCaptureSpool = spool
        _ = putFeatureInRecording(feature, seconds: 2)

        feature.stopSimpleRecording()
        await feature.turnTask?.value

        XCTAssertEqual(feature.state.phase, .done)
        XCTAssertTrue(spool.discarded,
                      "a delivered capture no longer needs its crash net")
    }

    func testSalvagedDiscardKeepsSpoolUntilTrashWriteIsDurable() async {
        let feature = makeFeature()
        let spool = FakeSpool()
        feature.activeCaptureSpool = spool
        _ = putFeatureInRecording(feature, seconds: 2)

        feature.handleEscape()
        await awaitSalvage(feature)

        XCTAssertTrue(spool.discarded,
                      "spool released once the trash copy is on disk")
        XCTAssertNil(feature.activeCaptureSpool)
    }

    func testErroredTurnKeepsSpoolForRecovery() async {
        let feature = makeFeature(transcriber: ThrowingTranscriber())
        let spool = FakeSpool()
        feature.activeCaptureSpool = spool
        _ = putFeatureInRecording(feature, seconds: 2)

        feature.stopSimpleRecording()
        await feature.turnTask?.value

        guard case .error = feature.state.phase else {
            return XCTFail("expected error phase")
        }
        XCTAssertFalse(spool.discarded,
                       "an undelivered capture keeps its crash net armed")
    }

    // MARK: - Backward compatibility

    func testPreTrashTranscriptionMetadataDecodesWithNilDiscardedAt() throws {
        let legacyJSON = Data("""
        {"wordCount": 3, "hasAudio": true, "hasContext": false}
        """.utf8)
        let decoded = try JSONDecoder().decode(
            TranscriptionMetadata.self, from: legacyJSON
        )
        XCTAssertNil(decoded.discardedAt,
                     "1.x metadata (no discardedAt key) must decode as active")
    }
}
