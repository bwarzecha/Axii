//
//  MeetingKillDuringPersistRecoveryTests.swift
//  AxiiIntegrationTests
//
//  Pins the commit-after-persist recovery guarantee at the exact state a
//  force-kill during finalize/persist leaves behind: stop() has flushed the
//  final autosave (segments + audio spool references) and the spool files
//  are closed on disk, but nothing reached history. A relaunch must recover
//  the meeting WITH its audio, and release the artifacts only after the
//  meeting is durably persisted.
//
//  Motivated by a real incident (2026-07-15): the AAC encoder wedged the
//  main thread during persist of an hour-long meeting and the app had to be
//  force-killed — this state is exactly what was on disk at that moment.
//

import XCTest
@testable import Axii

@MainActor
final class MeetingKillDuringPersistRecoveryTests: XCTestCase {

    private var tempDir: URL!
    private var autosaveURL: URL!
    private var micSpool: URL!
    private var systemSpool: URL!

    private static let micSampleCount = 48_000
    private static let systemSampleCount = 24_000

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AxiiKillPersist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        autosaveURL = tempDir.appendingPathComponent("meeting_autosave.json")
        micSpool = tempDir.appendingPathComponent("meeting_mic_test.raw")
        systemSpool = tempDir.appendingPathComponent("meeting_system_test.raw")
        try rawSpool(count: Self.micSampleCount).write(to: micSpool)
        try rawSpool(count: Self.systemSampleCount).write(to: systemSpool)
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil; autosaveURL = nil; micSpool = nil; systemSpool = nil
    }

    private actor FixedTranscriber: TranscriptionProviding {
        var isReady: Bool { true }
        func prepare() async throws {}
        func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
            "kill persist recovery words"
        }
    }

    private func rawSpool(count: Int) -> Data {
        let samples = [Float](repeating: 0.25, count: count)
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Builds the on-disk state a kill during finalize/persist leaves:
    /// final autosave flushed with segments AND audio references, spools
    /// closed on disk, nothing in history. Returns the dead session's ID.
    private func simulateKillDuringPersist() async -> UUID {
        let manager = MeetingTranscriptManager(
            transcriptionService: FixedTranscriber(),
            autosaveFileURL: autosaveURL
        )
        manager.reset()
        manager.audioFileReferenceProvider = { [micSpool, systemSpool] in
            MeetingAudioFileReferences(
                micFileURL: micSpool, micSampleRate: 48_000,
                systemFileURL: systemSpool, systemSampleRate: 48_000
            )
        }
        let chunk = TranscriptionChunk(
            samples: [Float](repeating: 0.2, count: 16_000),
            source: .microphone,
            timestamp: Date()
        )
        await manager.transcribeChunk(chunk).value
        // stop()'s "final flush before the long finalize/persist window".
        manager.flushAutoSave()
        // The process dies here: the manager is simply abandoned.
        return manager.sessionID
    }

    // MARK: - Recovery state survives the kill

    func testKillDuringPersistLeavesRecoverableStateWithAudio() async throws {
        _ = await simulateKillDuringPersist()

        // "Relaunch": a fresh manager reads the shared autosave path.
        let relaunched = MeetingTranscriptManager(
            transcriptionService: FixedTranscriber(),
            autosaveFileURL: autosaveURL
        )
        let recovery = try XCTUnwrap(relaunched.checkForCrashRecovery())

        XCTAssertEqual(recovery.segments.first?.text, "kill persist recovery words")
        let micSamples = MeetingAudioManager.readRawSamples(
            from: recovery.audioFiles?.micFileURL
        )
        let systemSamples = MeetingAudioManager.readRawSamples(
            from: recovery.audioFiles?.systemFileURL
        )
        XCTAssertEqual(micSamples.count, Self.micSampleCount)
        XCTAssertEqual(systemSamples.count, Self.systemSampleCount)
    }

    // MARK: - Recovered meeting persists with audio, then releases artifacts

    func testRecoveredMeetingPersistsWithAudioAndReleasesArtifacts() async throws {
        let deadSessionID = await simulateKillDuringPersist()

        let relaunched = MeetingTranscriptManager(
            transcriptionService: FixedTranscriber(),
            autosaveFileURL: autosaveURL
        )
        let recovery = try XCTUnwrap(relaunched.checkForCrashRecovery())

        // Persist the way launch recovery does — through the real
        // persistence service, AAC (the format of the original incident).
        let history = HistoryService(
            historyDirectory: tempDir.appendingPathComponent("history")
        )
        history.isEnabled = true
        let persistence = MeetingPersistenceService(historyService: history)
        let persisted = try await persistence.persist(
            payload: MeetingPersistencePayload(
                micSamples: MeetingAudioManager.readRawSamples(
                    from: recovery.audioFiles?.micFileURL
                ),
                micSampleRate: recovery.audioFiles?.micSampleRate ?? 0,
                systemSamples: MeetingAudioManager.readRawSamples(
                    from: recovery.audioFiles?.systemFileURL
                ),
                systemSampleRate: recovery.audioFiles?.systemSampleRate ?? 0,
                segments: recovery.segments,
                duration: recovery.duration,
                appName: recovery.appName,
                startedAt: recovery.startedAt
            ),
            audioFormat: .aac
        )

        let meeting = try XCTUnwrap(persisted)
        let micRecording = try XCTUnwrap(meeting.micRecording)
        let micURL = try XCTUnwrap(history.getAudioURL(micRecording, for: meeting.id))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: micURL.path),
            "recovered mic audio must be durably in history"
        )

        // Commit point: artifacts are released only now.
        MeetingRecoveryArtifacts(
            sessionID: deadSessionID,
            autosaveFileURL: autosaveURL,
            micFileURL: micSpool,
            systemFileURL: systemSpool
        ).clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: micSpool.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: systemSpool.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: autosaveURL.path))
    }
}
