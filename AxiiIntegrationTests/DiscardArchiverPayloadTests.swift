//
//  DiscardArchiverPayloadTests.swift
//  AxiiIntegrationTests
//
//  The archiver's payload-durability contract — what onPayloadDurable
//  means per config, and what holds the quit gate (pendingWrites):
//  - saveAudio ON: audio is the payload; the gate releases and the crash
//    spool may die once entry+audio are on disk; the transcript is
//    best-effort enrichment afterward.
//  - saveAudio OFF (built-in Conversation): the TRANSCRIPT is the payload;
//    durability and the gate wait for it, and any failure or empty result
//    keeps the crash spool for next-launch retry. (Regression test for the
//    confirmed bug where the spool died after a husk-only entry —
//    guaranteed loss on Quit-and-Discard.)
//

import XCTest
@testable import Axii

@MainActor
final class DiscardArchiverPayloadTests: XCTestCase {

    private var historyService: HistoryService!
    private var tempDir: URL!
    private var payloadDurable = false

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AxiiArchiver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        historyService = HistoryService(historyDirectory: tempDir)
        historyService.isEnabled = true
        payloadDurable = false
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        historyService = nil
    }

    private func makeArchiver(
        transcriber: any TranscriptionProviding
    ) -> DiscardedCaptureArchiver {
        DiscardedCaptureArchiver(
            history: historyService, transcriber: transcriber
        )
    }

    private func archive(
        _ archiver: DiscardedCaptureArchiver, saveAudio: Bool
    ) {
        archiver.archive(
            samples: testTone(seconds: 2), sampleRate: 16_000,
            config: HistoryConfig(saveAudio: saveAudio),
            onPayloadDurable: { self.payloadDurable = true }
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 10, _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: - Transcript as payload (saveAudio off)

    func testTranscriptPayloadHoldsGateUntilTranscriptDurable() async {
        let transcriber = GatedTranscriber("conversation words")
        let archiver = makeArchiver(transcriber: transcriber)

        archive(archiver, saveAudio: false)
        XCTAssertEqual(archiver.pendingWrites, 1,
                       "the quit gate must hold while the payload is pending")
        XCTAssertFalse(payloadDurable,
                       "nothing worth keeping is durable before the transcript")

        await transcriber.release()
        await archiver.drain()

        XCTAssertTrue(payloadDurable)
        XCTAssertEqual(archiver.pendingWrites, 0)
        XCTAssertEqual(
            historyService.discardedMetadata().first?.preview,
            "conversation words"
        )
    }

    func testTranscriptPayloadFailureReleasesGateButNotTheSpool() async {
        let archiver = makeArchiver(transcriber: ThrowingTranscriber())

        archive(archiver, saveAudio: false)
        await archiver.drain()

        XCTAssertFalse(
            payloadDurable,
            "ASR failure = no payload = the crash spool must survive for retry"
        )
        XCTAssertEqual(archiver.pendingWrites, 0,
                       "a failed archive must not hold the quit gate forever")
    }

    func testEmptyTranscriptIsNotDurable() async {
        let archiver = makeArchiver(transcriber: CannedTranscriber(""))

        archive(archiver, saveAudio: false)
        await archiver.drain()

        XCTAssertFalse(payloadDurable,
                       "an empty transcript persists nothing worth keeping")
    }

    // MARK: - Audio as payload (saveAudio on)

    func testAudioPayloadDurableAndGateReleasedBeforeEnrichment() async {
        let transcriber = GatedTranscriber("enriched words")
        let archiver = makeArchiver(transcriber: transcriber)

        archive(archiver, saveAudio: true)
        // The audio write is async; the transcript is still gated — durability
        // and the quit gate must resolve on the audio alone.
        await waitUntil { payloadDurable }

        XCTAssertTrue(payloadDurable,
                      "audio on disk = payload durable, spool may die")
        XCTAssertEqual(archiver.pendingWrites, 0,
                       "the quit gate must not wait for best-effort enrichment")

        await transcriber.release()
        await archiver.drain()
        XCTAssertEqual(
            historyService.discardedMetadata().first?.preview,
            "enriched words"
        )
    }
}
