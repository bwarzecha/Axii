//
//  MeetingCrashRecoveryTests.swift
//  AxiiIntegrationTests
//
//  Crash-matrix tests for the recovery model (docs/meeting-reliability-model.md)
//  using the REAL MeetingTranscriptManager against an injected temp-dir
//  autosave file — a "crash" is simulated by abandoning one manager instance
//  and reading the file back with a fresh one, exactly what an app relaunch
//  does. These tests never touch the real Application Support autosave path.
//

import XCTest
@testable import Axii

@MainActor
final class MeetingCrashRecoveryTests: XCTestCase {

    private var autosaveURL: URL!

    override func setUp() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AxiiCrashRecovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        autosaveURL = dir.appendingPathComponent("meeting_autosave.json")
    }

    override func tearDown() async throws {
        if let autosaveURL {
            try? FileManager.default.removeItem(
                at: autosaveURL.deletingLastPathComponent()
            )
        }
        autosaveURL = nil
    }

    private actor FixedTranscriber: TranscriptionProviding {
        var isReady: Bool { true }
        func prepare() async throws {}
        func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
            "recovered words"
        }
    }

    /// A manager with one real transcribed segment and a flushed autosave.
    private func makeCrashedSession() async -> MeetingTranscriptManager {
        let manager = MeetingTranscriptManager(
            transcriptionService: FixedTranscriber(),
            autosaveFileURL: autosaveURL
        )
        manager.reset()
        let chunk = TranscriptionChunk(
            samples: [Float](repeating: 0.2, count: 16_000),
            source: .microphone,
            timestamp: Date()
        )
        await manager.transcribeChunk(chunk).value
        manager.flushAutoSave()
        return manager
    }

    // MARK: - Crash While Recording

    func testCrashDuringRecordingIsRecoverableOnRelaunch() async throws {
        let crashed = await makeCrashedSession()
        XCTAssertFalse(crashed.segments.isEmpty, "precondition: segment transcribed")

        // "Relaunch": a fresh manager reads the same file.
        let relaunched = MeetingTranscriptManager(
            transcriptionService: FixedTranscriber(),
            autosaveFileURL: autosaveURL
        )
        let recovery = relaunched.checkForCrashRecovery()

        XCTAssertEqual(recovery?.segments.first?.text, "recovered words")
    }

    // MARK: - Read Does Not Destroy

    func testRecoveryReadLeavesFileForASecondCrash() async throws {
        _ = await makeCrashedSession()

        let firstRelaunch = MeetingTranscriptManager(
            transcriptionService: FixedTranscriber(),
            autosaveFileURL: autosaveURL
        )
        XCTAssertNotNil(firstRelaunch.checkForCrashRecovery())

        // The app crashes AGAIN before the recovered meeting is saved; the
        // next relaunch must still find the data.
        let secondRelaunch = MeetingTranscriptManager(
            transcriptionService: FixedTranscriber(),
            autosaveFileURL: autosaveURL
        )
        XCTAssertNotNil(secondRelaunch.checkForCrashRecovery())
    }

    // MARK: - Expiry Uses Last Write, Not Recording Start

    func testExpiryKeyedToFileModificationTime() async throws {
        _ = await makeCrashedSession()

        // Age the FILE two hours; a fresh write time would keep it alive
        // regardless of when the recording started.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-7_200)],
            ofItemAtPath: autosaveURL.path
        )

        let relaunched = MeetingTranscriptManager(
            transcriptionService: FixedTranscriber(),
            autosaveFileURL: autosaveURL
        )
        XCTAssertNil(relaunched.checkForCrashRecovery())
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: autosaveURL.path),
            "Expired recovery data is deleted"
        )
    }

    // MARK: - Corrupt File Is Cleared, Not Crashed On

    func testCorruptAutosaveIsRemovedGracefully() throws {
        try Data("not json".utf8).write(to: autosaveURL)

        let relaunched = MeetingTranscriptManager(
            transcriptionService: FixedTranscriber(),
            autosaveFileURL: autosaveURL
        )
        XCTAssertNil(relaunched.checkForCrashRecovery())
        XCTAssertFalse(FileManager.default.fileExists(atPath: autosaveURL.path))
    }

    // MARK: - Session-Scoped Clearing

    func testMatchingClearOnlyRemovesOwnSessionsFile() async throws {
        let crashed = await makeCrashedSession()
        let owner = crashed.sessionID

        // A stale commit from some OTHER session must not delete this file.
        MeetingTranscriptManager.clearAutoSave(matching: UUID(), at: autosaveURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: autosaveURL.path))

        // The owning session's commit removes it.
        MeetingTranscriptManager.clearAutoSave(matching: owner, at: autosaveURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: autosaveURL.path))
    }

    // MARK: - Flush Is Immediate

    func testFlushWritesWithoutWaitingForTimer() async throws {
        let manager = await makeCrashedSession()
        _ = manager
        // makeCrashedSession never started the 60s autosave timer — the file
        // exists purely because flushAutoSave wrote it synchronously.
        XCTAssertTrue(FileManager.default.fileExists(atPath: autosaveURL.path))
    }

    // MARK: - Artifacts Clear End-To-End

    func testRecoveryArtifactsClearRemovesTempAudioAndOwnAutosave() async throws {
        let crashed = await makeCrashedSession()
        let dir = autosaveURL.deletingLastPathComponent()
        let micFile = dir.appendingPathComponent("mic.raw")
        let systemFile = dir.appendingPathComponent("system.raw")
        try Data([1, 2, 3]).write(to: micFile)
        try Data([4, 5, 6]).write(to: systemFile)

        let artifacts = MeetingRecoveryArtifacts(
            sessionID: crashed.sessionID,
            autosaveFileURL: autosaveURL,
            micFileURL: micFile,
            systemFileURL: systemFile
        )
        artifacts.clear()

        XCTAssertFalse(FileManager.default.fileExists(atPath: micFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: systemFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: autosaveURL.path))
    }
}
