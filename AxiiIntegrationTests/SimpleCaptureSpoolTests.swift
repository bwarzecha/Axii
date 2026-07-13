//
//  SimpleCaptureSpoolTests.swift
//  AxiiIntegrationTests
//
//  The dictation crash net: samples stream to a headerless disk spool
//  from capture start, and an orphaned spool (process died before a
//  terminal state) is archived into "Recently Deleted" at launch under
//  its original date. Corrupt, expired, and sub-second spools are swept,
//  and history-off leaves spools untouched.
//

import XCTest
@testable import Axii

@MainActor
final class SimpleCaptureSpoolTests: XCTestCase {

    private var spoolDir: URL!
    private var historyDir: URL!
    private var historyService: HistoryService!

    override func setUp() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("AxiiSpoolTests-\(UUID().uuidString)")
        spoolDir = base.appendingPathComponent("spool")
        historyDir = base.appendingPathComponent("history")
        for dir in [spoolDir!, historyDir!] {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true
            )
        }
        historyService = HistoryService(historyDirectory: historyDir)
        historyService.isEnabled = true
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(
            at: spoolDir.deletingLastPathComponent()
        )
        historyService = nil
    }

    // MARK: - Fakes

    private actor StubTranscriber: TranscriptionProviding {
        var isReady: Bool { true }
        func prepare() async throws {}
        func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
            "recovered words"
        }
    }

    private func tone(seconds: Double, rate: Double) -> [Float] {
        (0..<Int(seconds * rate)).map { i in
            Float(sin(Double(i) * 2.0 * .pi * 440.0 / rate) * 0.5)
        }
    }

    private func writeSpool(
        seconds: Double, createdAt: Date? = nil
    ) throws -> SimpleCaptureSpool {
        let spool = SimpleCaptureSpool(directory: spoolDir)!
        spool.append(samples: tone(seconds: seconds, rate: 16_000),
                     sampleRate: 16_000)
        // Rewrite the sidecar when a test needs a specific recording date.
        if let createdAt {
            let sidecar = SimpleCaptureSpool.Sidecar(
                createdAt: createdAt, sampleRate: 16_000
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(sidecar).write(to: spool.sidecarURL)
        }
        return spool
    }

    private func spoolFileCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(
            at: spoolDir, includingPropertiesForKeys: nil
        ))?.count ?? 0
    }

    // MARK: - Spool mechanics

    func testAppendStreamsResampledSamplesToDisk() throws {
        let spool = SimpleCaptureSpool(directory: spoolDir)!
        spool.append(samples: tone(seconds: 2, rate: 48_000),
                     sampleRate: 48_000)

        let bytes = try Data(contentsOf: spool.dataURL)
        let seconds = Double(bytes.count / 4) / SimpleCaptureSpool.sampleRate
        XCTAssertEqual(seconds, 2.0, accuracy: 0.05,
                       "48 kHz input must land as 16 kHz on disk")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: spool.sidecarURL.path),
            "sidecar written with the first audio"
        )
    }

    func testDiscardRemovesBothFiles() throws {
        let spool = try writeSpool(seconds: 2)
        spool.discard()
        XCTAssertEqual(spoolFileCount(), 0)
    }

    func testAbortedStartLeavesNoSidecar() {
        let spool = SimpleCaptureSpool(directory: spoolDir)!
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: spool.sidecarURL.path),
            "no audio, no sidecar — recovery must not see empty shells"
        )
        spool.discard()
    }

    // MARK: - Launch recovery

    func testOrphanedSpoolRecoversToRecentlyDeletedUnderOriginalDate() async throws {
        let recordedAt = Date().addingTimeInterval(-3_600)
        _ = try writeSpool(seconds: 2, createdAt: recordedAt)

        await SimpleCaptureRecovery.run(
            history: historyService, transcriber: StubTranscriber(),
            directory: spoolDir
        )

        let discarded = historyService.discardedMetadata()
        XCTAssertEqual(discarded.count, 1,
                       "a crashed capture must surface in Recently Deleted")
        XCTAssertEqual(discarded.first?.preview, "recovered words")
        XCTAssertEqual(
            discarded.first!.createdAt.timeIntervalSince(recordedAt), 0,
            accuracy: 1.0,
            "recovered under the ORIGINAL recording date"
        )
        XCTAssertEqual(spoolFileCount(), 0,
                       "a durably archived spool is consumed")
    }

    func testExpiredSpoolIsSweptWithoutRecovery() async throws {
        _ = try writeSpool(
            seconds: 2, createdAt: Date().addingTimeInterval(-8 * 24 * 3_600)
        )

        await SimpleCaptureRecovery.run(
            history: historyService, transcriber: StubTranscriber(),
            directory: spoolDir
        )

        XCTAssertTrue(historyService.discardedMetadata().isEmpty)
        XCTAssertEqual(spoolFileCount(), 0)
    }

    func testCorruptSidecarIsSwept() async throws {
        let spool = try writeSpool(seconds: 2)
        try Data("not json".utf8).write(to: spool.sidecarURL)

        await SimpleCaptureRecovery.run(
            history: historyService, transcriber: StubTranscriber(),
            directory: spoolDir
        )

        XCTAssertTrue(historyService.discardedMetadata().isEmpty)
        XCTAssertEqual(spoolFileCount(), 0)
    }

    func testSubSecondSpoolIsSwept() async throws {
        _ = try writeSpool(seconds: 0.3)

        await SimpleCaptureRecovery.run(
            history: historyService, transcriber: StubTranscriber(),
            directory: spoolDir
        )

        XCTAssertTrue(historyService.discardedMetadata().isEmpty)
        XCTAssertEqual(spoolFileCount(), 0)
    }

    func testHistoryDisabledLeavesSpoolsAlone() async throws {
        historyService.isEnabled = false
        _ = try writeSpool(seconds: 2)

        await SimpleCaptureRecovery.run(
            history: historyService, transcriber: StubTranscriber(),
            directory: spoolDir
        )

        XCTAssertEqual(spoolFileCount(), 2,
                       "history off must not consume — the user may re-enable")
    }
}
