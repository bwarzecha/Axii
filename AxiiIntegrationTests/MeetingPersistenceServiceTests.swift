//
//  MeetingPersistenceServiceTests.swift
//  AxiiIntegrationTests
//
//  Service-level tests for MeetingPersistenceService.
//  These are the main source of truth for meeting persistence behavior.
//  Tests exercise the real service against a temp-directory HistoryService.
//

import XCTest
@testable import Axii

@MainActor
final class MeetingPersistenceServiceTests: XCTestCase {

    private var historyService: HistoryService!
    private var service: MeetingPersistenceService!
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AxiiMeetingPersistence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        historyService = HistoryService(historyDirectory: tempDir)
        service = MeetingPersistenceService(historyService: historyService)
    }

    override func tearDown() async throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        service = nil
        historyService = nil
        tempDir = nil
    }

    // MARK: - Helpers

    /// Synthetic sine-wave samples for AAC encoding (constant buffers can fail).
    private func syntheticSamples(
        count: Int,
        sampleRate: Double = 44100
    ) -> [Float] {
        (0..<count).map { i in
            Float(sin(Double(i) * 2.0 * .pi * 440.0 / sampleRate) * 0.5)
        }
    }

    private func makeBothTracksPayload(
        sampleRate: Double = 44100
    ) -> MeetingPersistencePayload {
        MeetingPersistencePayload(
            micSamples: syntheticSamples(count: Int(sampleRate), sampleRate: sampleRate),
            micSampleRate: sampleRate,
            systemSamples: syntheticSamples(count: Int(sampleRate), sampleRate: sampleRate),
            systemSampleRate: sampleRate,
            segments: [
                MeetingSegment(text: "Hello from mic", speakerId: "You",
                               isFromMicrophone: true, startTime: 0, endTime: 5),
                MeetingSegment(text: "Hello from remote", speakerId: "Remote",
                               isFromMicrophone: false, startTime: 5, endTime: 10),
            ],
            duration: 60.0,
            appName: "Zoom"
        )
    }

    // MARK: - Both Tracks

    func testPersistWithBothTracks_AttachesBothRecordings() async throws {
        let payload = makeBothTracksPayload()
        let meeting = try await service.persist(payload: payload, audioFormat: .aac)

        XCTAssertNotNil(meeting.micRecording, "Mic recording should be attached")
        XCTAssertNotNil(meeting.systemRecording, "System recording should be attached")
        XCTAssertEqual(meeting.segments.count, 2)
        XCTAssertEqual(meeting.duration, 60.0)
        XCTAssertEqual(meeting.appName, "Zoom")

        // Verify persisted and reloadable
        let meetings = historyService.listMetadata(type: .meeting)
        XCTAssertEqual(meetings.count, 1, "One logical meeting entry")

        let loaded = try await historyService.loadInteraction(id: meeting.id)
        guard case .meeting(let reloaded) = loaded else {
            XCTFail("Expected meeting interaction")
            return
        }
        XCTAssertNotNil(reloaded.micRecording)
        XCTAssertNotNil(reloaded.systemRecording)
    }

    // MARK: - Compressed Format

    func testPersistPreservesConfiguredCompressedFormat() async throws {
        let payload = makeBothTracksPayload()
        let meeting = try await service.persist(payload: payload, audioFormat: .aac)

        XCTAssertTrue(
            meeting.micRecording?.filename.hasSuffix(".m4a") == true,
            "Mic recording should use .m4a for AAC"
        )
        XCTAssertTrue(
            meeting.systemRecording?.filename.hasSuffix(".m4a") == true,
            "System recording should use .m4a for AAC"
        )

        // Verify files on disk
        let metadata = historyService.listMetadata(type: .meeting).first!
        let audioDir = tempDir
            .appendingPathComponent(metadata.folderName)
            .appendingPathComponent("audio")
        let audioFiles = try FileManager.default.contentsOfDirectory(
            at: audioDir, includingPropertiesForKeys: nil
        )
        XCTAssertEqual(audioFiles.count, 2)
        for file in audioFiles {
            XCTAssertEqual(file.pathExtension, "m4a")
        }
    }

    // MARK: - Resolvable References

    func testPersistRecordingReferencesResolveToExistingFiles() async throws {
        let payload = makeBothTracksPayload()
        let meeting = try await service.persist(payload: payload, audioFormat: .aac)

        let micURL = historyService.getAudioURL(meeting.micRecording!, for: meeting.id)
        let sysURL = historyService.getAudioURL(meeting.systemRecording!, for: meeting.id)
        XCTAssertNotNil(micURL)
        XCTAssertNotNil(sysURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: micURL!.path),
                       "Mic audio file should exist at resolved URL")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sysURL!.path),
                       "System audio file should exist at resolved URL")
    }

    // MARK: - No Audio

    func testPersistWithNoAudio_SavesMeetingWithoutRecordings() async throws {
        let payload = MeetingPersistencePayload(
            micSamples: [],
            micSampleRate: 0,
            systemSamples: [],
            systemSampleRate: 0,
            segments: [
                MeetingSegment(text: "Silent meeting", speakerId: "You",
                               isFromMicrophone: true, startTime: 0, endTime: 30),
            ],
            duration: 30.0,
            appName: "FaceTime"
        )

        let meeting = try await service.persist(payload: payload, audioFormat: .aac)

        XCTAssertNil(meeting.micRecording, "No mic recording for empty samples")
        XCTAssertNil(meeting.systemRecording, "No system recording for empty samples")
        XCTAssertEqual(meeting.segments.count, 1)
        XCTAssertEqual(meeting.appName, "FaceTime")

        let meetings = historyService.listMetadata(type: .meeting)
        XCTAssertEqual(meetings.count, 1)
    }

    // MARK: - Partial Audio (Mic Only)

    func testPersistWithMicOnly_SavesOnlyMicRecording() async throws {
        let sampleRate: Double = 44100
        let payload = MeetingPersistencePayload(
            micSamples: syntheticSamples(count: Int(sampleRate), sampleRate: sampleRate),
            micSampleRate: sampleRate,
            systemSamples: [],
            systemSampleRate: 0,
            segments: [
                MeetingSegment(text: "Mic only", speakerId: "You",
                               isFromMicrophone: true, startTime: 0, endTime: 10),
            ],
            duration: 10.0,
            appName: nil
        )

        let meeting = try await service.persist(payload: payload, audioFormat: .aac)

        XCTAssertNotNil(meeting.micRecording, "Mic recording should be attached")
        XCTAssertNil(meeting.systemRecording, "System recording should be nil")

        let loaded = try await historyService.loadInteraction(id: meeting.id)
        guard case .meeting(let reloaded) = loaded else {
            XCTFail("Expected meeting interaction")
            return
        }
        XCTAssertNotNil(reloaded.micRecording)
        XCTAssertNil(reloaded.systemRecording)
    }

    // MARK: - Identity Stability

    func testPersistPreservesIdentityAcrossAudioAttachReSave() async throws {
        let payload = makeBothTracksPayload()
        let meeting = try await service.persist(payload: payload, audioFormat: .aac)

        // Reload and verify id and createdAt are preserved
        let loaded = try await historyService.loadInteraction(id: meeting.id)
        guard case .meeting(let reloaded) = loaded else {
            XCTFail("Expected meeting interaction")
            return
        }

        XCTAssertEqual(reloaded.id, meeting.id, "Meeting ID must be stable")
        // HistoryService JSON encoding may truncate sub-second precision,
        // so we compare with 1-second accuracy. The important invariant is
        // that the re-save does not change the date to a new value.
        XCTAssertEqual(
            reloaded.createdAt.timeIntervalSince1970,
            meeting.createdAt.timeIntervalSince1970,
            accuracy: 1.0,
            "createdAt must be stable across re-save"
        )

        // Only one logical entry in history
        let meetings = historyService.listMetadata(type: .meeting)
        XCTAssertEqual(meetings.count, 1, "Should be one logical meeting, not two")
    }
}
