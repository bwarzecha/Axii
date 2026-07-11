//
//  HistoryTrashTests.swift
//  AxiiIntegrationTests
//
//  "Recently Deleted" for meetings: a discarded meeting keeps its audio and
//  transcript (recoverable), is hidden from the main list, can be restored,
//  and is swept for good only after the retention window.
//

import XCTest
@testable import Axii

@MainActor
final class HistoryTrashTests: XCTestCase {

    private var historyService: HistoryService!
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AxiiTrash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        historyService = HistoryService(historyDirectory: tempDir)
    }

    override func tearDown() async throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        historyService = nil
        tempDir = nil
    }

    private func makeMeeting(discardedAt: Date? = nil) -> Meeting {
        Meeting(
            segments: [
                MeetingSegment(
                    text: "hello", speakerId: "You",
                    isFromMicrophone: true, startTime: 0, endTime: 1
                )
            ],
            duration: 30,
            appName: "Zoom",
            discardedAt: discardedAt
        )
    }

    // MARK: - Discarded Meetings Are Hidden But Kept

    func testDiscardedMeetingIsHiddenFromMainListButKept() async throws {
        let kept = makeMeeting()
        let trashed = makeMeeting(discardedAt: Date())
        try await historyService.save(.meeting(kept))
        try await historyService.save(.meeting(trashed))

        let active = historyService.activeMetadata(type: .meeting)
        XCTAssertEqual(active.map(\.id), [kept.id],
                       "The main list shows only non-discarded meetings")

        let discarded = historyService.discardedMetadata()
        XCTAssertEqual(discarded.map(\.id), [trashed.id])

        // The data is intact — the transcript loads back.
        guard case .meeting(let loaded) = try await historyService.loadInteraction(
            id: trashed.id
        ) else { return XCTFail("Expected meeting") }
        XCTAssertEqual(loaded.segments.first?.text, "hello",
                       "A discarded meeting keeps its transcript for recovery")
        XCTAssertTrue(loaded.isDiscarded)
    }

    // MARK: - Restore

    func testRestoreBringsMeetingBackToMainList() async throws {
        let trashed = makeMeeting(discardedAt: Date())
        try await historyService.save(.meeting(trashed))

        let restored = try await historyService.restoreDiscarded(id: trashed.id)
        XCTAssertTrue(restored)

        XCTAssertTrue(historyService.discardedMetadata().isEmpty)
        XCTAssertEqual(historyService.activeMetadata(type: .meeting).map(\.id),
                       [trashed.id])

        guard case .meeting(let loaded) = try await historyService.loadInteraction(
            id: trashed.id
        ) else { return XCTFail("Expected meeting") }
        XCTAssertFalse(loaded.isDiscarded, "Restore clears the discard flag")
        XCTAssertEqual(loaded.segments.first?.text, "hello",
                       "Restore preserves the data — it does not re-transcribe")
    }

    func testRestoreOnNonDiscardedIsANoOp() async throws {
        let kept = makeMeeting()
        try await historyService.save(.meeting(kept))
        let restored = try await historyService.restoreDiscarded(id: kept.id)
        XCTAssertFalse(restored)
    }

    // MARK: - Sweep

    func testSweepRemovesOnlyExpiredDiscards() async throws {
        let fresh = makeMeeting(discardedAt: Date())
        let old = makeMeeting(
            discardedAt: Date().addingTimeInterval(
                -MeetingRecoveryPolicy.artifactLifetime - 3_600
            )
        )
        let kept = makeMeeting()
        try await historyService.save(.meeting(fresh))
        try await historyService.save(.meeting(old))
        try await historyService.save(.meeting(kept))

        await historyService.sweepExpiredDiscards()

        let ids = Set(historyService.listMetadata().map(\.id))
        XCTAssertTrue(ids.contains(fresh.id), "A fresh discard stays recoverable")
        XCTAssertTrue(ids.contains(kept.id), "A non-discarded meeting is untouched")
        XCTAssertFalse(ids.contains(old.id),
                       "A discard past the retention window is permanently gone")
    }

    func testSweepNeverTouchesNonDiscardedRegardlessOfAge() async throws {
        // A months-old KEPT meeting must never be swept.
        let ancient = Meeting(
            segments: [],
            duration: 10,
            createdAt: Date().addingTimeInterval(-365 * 24 * 3_600)
        )
        try await historyService.save(.meeting(ancient))

        await historyService.sweepExpiredDiscards()

        XCTAssertTrue(historyService.listMetadata().map(\.id).contains(ancient.id),
                      "The sweep only ever removes DISCARDED entries")
    }
}
