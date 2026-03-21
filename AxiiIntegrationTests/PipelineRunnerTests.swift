//
//  PipelineRunnerTests.swift
//  AxiiIntegrationTests
//
//  Integration tests for PipelineRunner with segment merge steps.
//  LLM tests are skipped in this phase since they require Bedrock.
//

import XCTest
@testable import Axii

@MainActor
final class PipelineRunnerTests: XCTestCase {

    private var runner: PipelineRunner!

    override func setUp() async throws {
        runner = PipelineRunner()
    }

    override func tearDown() async throws {
        runner = nil
    }

    // MARK: - Tests

    func testNoStepsReturnsOriginalContext() async throws {
        let context = PipelineContext(
            transcription: "Original text",
            modeName: "Test"
        )

        let result = try await runner.run(steps: [], context: context)

        XCTAssertEqual(result.text, "Original text")
        XCTAssertEqual(result.results["transcription"], "Original text")
        XCTAssertNil(result.segments)
    }

    func testSegmentMergeMergesConsecutiveSameSpeaker() async throws {
        var context = PipelineContext(
            transcription: "test",
            modeName: "Test"
        )
        context.segments = [
            MeetingSegment(
                text: "Hello",
                speakerId: "Alice",
                isFromMicrophone: true,
                startTime: 0,
                endTime: 2.0
            ),
            MeetingSegment(
                text: "world",
                speakerId: "Alice",
                isFromMicrophone: true,
                startTime: 2.0,
                endTime: 4.0
            ),
            MeetingSegment(
                text: "Goodbye",
                speakerId: "Bob",
                isFromMicrophone: false,
                startTime: 4.0,
                endTime: 6.0
            ),
        ]

        let steps: [ProcessingStep] = [
            .segmentMerge(SegmentMergeConfig(mergeConsecutiveSameSpeaker: true)),
        ]

        let result = try await runner.run(steps: steps, context: context)

        XCTAssertEqual(result.segments?.count, 2)
        XCTAssertEqual(result.segments?[0].speakerId, "Alice")
        XCTAssertEqual(result.segments?[0].text, "Hello world")
        XCTAssertEqual(result.segments?[0].endTime, 4.0)
        XCTAssertEqual(result.segments?[1].speakerId, "Bob")
    }

    func testSegmentMergePreservesDifferentSpeakers() async throws {
        var context = PipelineContext(
            transcription: "test",
            modeName: "Test"
        )
        context.segments = [
            MeetingSegment(
                text: "Hello",
                speakerId: "Alice",
                isFromMicrophone: true,
                startTime: 0,
                endTime: 2.0
            ),
            MeetingSegment(
                text: "Hi there",
                speakerId: "Bob",
                isFromMicrophone: false,
                startTime: 2.0,
                endTime: 4.0
            ),
            MeetingSegment(
                text: "How are you?",
                speakerId: "Alice",
                isFromMicrophone: true,
                startTime: 4.0,
                endTime: 6.0
            ),
        ]

        let steps: [ProcessingStep] = [
            .segmentMerge(SegmentMergeConfig(mergeConsecutiveSameSpeaker: true)),
        ]

        let result = try await runner.run(steps: steps, context: context)

        XCTAssertEqual(
            result.segments?.count, 3,
            "Alternating speakers should not be merged"
        )
        XCTAssertEqual(result.segments?[0].speakerId, "Alice")
        XCTAssertEqual(result.segments?[1].speakerId, "Bob")
        XCTAssertEqual(result.segments?[2].speakerId, "Alice")
    }

    func testSegmentMergeSortsByStartTime() async throws {
        var context = PipelineContext(
            transcription: "test",
            modeName: "Test"
        )
        // Provide segments out of order
        context.segments = [
            MeetingSegment(
                text: "Third",
                speakerId: "Alice",
                isFromMicrophone: true,
                startTime: 6.0,
                endTime: 8.0
            ),
            MeetingSegment(
                text: "First",
                speakerId: "Bob",
                isFromMicrophone: false,
                startTime: 0,
                endTime: 3.0
            ),
            MeetingSegment(
                text: "Second",
                speakerId: "Alice",
                isFromMicrophone: true,
                startTime: 3.0,
                endTime: 6.0
            ),
        ]

        let steps: [ProcessingStep] = [
            .segmentMerge(SegmentMergeConfig(mergeConsecutiveSameSpeaker: true)),
        ]

        let result = try await runner.run(steps: steps, context: context)

        // After sorting: Bob(0-3), Alice(3-6), Alice(6-8) -> merged to Bob(0-3), Alice(3-8)
        XCTAssertEqual(result.segments?.count, 2)
        XCTAssertEqual(result.segments?[0].speakerId, "Bob")
        XCTAssertEqual(result.segments?[0].text, "First")
        XCTAssertEqual(result.segments?[1].speakerId, "Alice")
        XCTAssertEqual(result.segments?[1].text, "Second Third")
        XCTAssertEqual(result.segments?[1].endTime, 8.0)
    }
}
