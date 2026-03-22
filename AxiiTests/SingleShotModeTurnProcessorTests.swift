//
//  SingleShotModeTurnProcessorTests.swift
//  AxiiTests
//
//  Primary test suite for the single-shot post-capture execution contract.
//  These tests verify the processor's behavior through its boundary
//  interfaces using fakes, with real ModeRuntimeState for observable
//  assertions.
//
//  This is the main source of truth for single-shot mode behavior:
//  transcription, empty-result, pipeline, output, dismiss, and error.
//

import XCTest
@testable import Axii

// MARK: - Test Doubles

private actor FakeTranscriber: TranscriptionProviding {
    var isReady: Bool = true
    var textToReturn: String = "Hello world"
    var errorToThrow: Error?

    func setTextToReturn(_ text: String) { textToReturn = text }
    func setErrorToThrow(_ error: Error?) { errorToThrow = error }
    func prepare() async throws {}

    func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
        if let error = errorToThrow { throw error }
        return textToReturn
    }
}

@MainActor
private final class FakePipeline: PipelineExecuting {
    var contextToReturn: PipelineContext?
    var errorToThrow: Error?
    var receivedSteps: [ProcessingStep] = []
    /// Called during run() — allows tests to observe state mid-execution.
    var onRun: (() -> Void)?

    func run(
        steps: [ProcessingStep],
        context: PipelineContext
    ) async throws -> PipelineContext {
        receivedSteps = steps
        onRun?()
        if let error = errorToThrow { throw error }
        return contextToReturn ?? context
    }
}

@MainActor
private final class FakeOutput: ModeOutputExecuting {
    var executedDestinations: [OutputDestination] = []
    var lastState: ModeRuntimeState?
    var onExecute: ((ModeRuntimeState) -> Void)?

    func executeOutputs(
        destinations: [OutputDestination],
        context: PipelineContext,
        state: ModeRuntimeState
    ) async {
        executedDestinations = destinations
        lastState = state
        onExecute?(state)
    }
}

@MainActor
private final class FakeDismissController: ModeDismissControlling {
    var scheduledDelay: TimeInterval?
    var cancelCalled = false

    func cancelScheduledDismiss() { cancelCalled = true }
    func scheduleDismiss(after delay: TimeInterval) { scheduledDelay = delay }
}

// MARK: - Tests

@MainActor
final class SingleShotModeTurnProcessorTests: XCTestCase {

    private var transcriber: FakeTranscriber!
    private var pipeline: FakePipeline!
    private var output: FakeOutput!
    private var dismissController: FakeDismissController!
    private var state: ModeRuntimeState!
    private var processor: SingleShotModeTurnProcessor!

    override func setUp() {
        transcriber = FakeTranscriber()
        pipeline = FakePipeline()
        output = FakeOutput()
        dismissController = FakeDismissController()
        state = ModeRuntimeState()

        processor = SingleShotModeTurnProcessor(
            transcriber: transcriber,
            pipeline: pipeline,
            output: output,
            dismissController: dismissController
        )
    }

    override func tearDown() {
        transcriber = nil
        pipeline = nil
        output = nil
        dismissController = nil
        state = nil
        processor = nil
    }

    // MARK: - Helpers

    private func makeCapture(
        samples: [Float] = [0.1, 0.2, 0.3],
        sampleRate: Double = 16000.0,
        focusSnapshot: FocusSnapshot? = nil
    ) -> CompletedCapture {
        CompletedCapture(
            samples: samples,
            sampleRate: sampleRate,
            focusSnapshot: focusSnapshot
        )
    }

    private func makeConfig(
        modeName: String = "Test Mode",
        processing: [ProcessingStep] = [],
        outputs: [OutputDestination] = [.display(DisplayConfig())],
        panelPersistence: PanelPersistence = .autoDismiss(delay: 2.0)
    ) -> SingleShotTurnConfig {
        SingleShotTurnConfig(
            modeName: modeName,
            processing: processing,
            outputs: outputs,
            panelPersistence: panelPersistence
        )
    }

    // MARK: - Transcription Success (No Pipeline)

    func testSuccessNoPipeline_SetsFinalTextAndDone() async {
        await transcriber.setTextToReturn("Hello world")

        await processor.process(
            capture: makeCapture(),
            config: makeConfig(),
            state: state
        )

        XCTAssertEqual(state.phase, .done)
        XCTAssertEqual(state.finalText, "Hello world")
    }

    func testSuccessNoPipeline_ExecutesOutputs() async {
        await transcriber.setTextToReturn("Hello")

        let config = makeConfig(outputs: [.display(DisplayConfig())])
        await processor.process(
            capture: makeCapture(), config: config, state: state
        )

        XCTAssertEqual(output.executedDestinations.count, 1)
    }

    func testSuccessNoPipeline_SchedulesDismissWhenAutoDismiss() async {
        await transcriber.setTextToReturn("Hello")

        await processor.process(
            capture: makeCapture(),
            config: makeConfig(panelPersistence: .autoDismiss(delay: 3.0)),
            state: state
        )

        XCTAssertEqual(dismissController.scheduledDelay, 3.0)
    }

    // MARK: - Transcription Success (With Pipeline)

    func testSuccessWithPipeline_EntersProcessingPhase() async {
        await transcriber.setTextToReturn("Raw text")
        let step = ProcessingStep.segmentMerge(SegmentMergeConfig())

        // Capture the phase during pipeline execution
        var phaseDuringPipelineRun: ModePhase?
        let observedState = self.state
        pipeline.onRun = {
            phaseDuringPipelineRun = observedState?.phase
        }

        await processor.process(
            capture: makeCapture(),
            config: makeConfig(processing: [step]),
            state: state
        )

        XCTAssertEqual(phaseDuringPipelineRun, .processing,
                        "Processor must enter .processing before pipeline runs")
        XCTAssertEqual(state.phase, .done)
        XCTAssertEqual(pipeline.receivedSteps.count, 1)
    }

    func testSuccessWithPipeline_UsesTransformedText() async {
        await transcriber.setTextToReturn("Raw text")
        let step = ProcessingStep.segmentMerge(SegmentMergeConfig())

        // Pipeline transforms the text
        let transformed = PipelineContext(
            transcription: "Transformed text",
            modeName: "Test"
        )
        pipeline.contextToReturn = transformed

        await processor.process(
            capture: makeCapture(),
            config: makeConfig(processing: [step]),
            state: state
        )

        XCTAssertEqual(state.finalText, "Transformed text")
    }

    // MARK: - Empty Transcription

    func testEmptyTranscription_ShowsNoSpeechDetected() async {
        await transcriber.setTextToReturn("")

        await processor.process(
            capture: makeCapture(), config: makeConfig(), state: state
        )

        XCTAssertEqual(state.phase, .done)
        XCTAssertEqual(state.finalText, "No speech detected")
    }

    func testEmptyTranscription_SchedulesDismiss() async {
        await transcriber.setTextToReturn("")

        await processor.process(
            capture: makeCapture(), config: makeConfig(), state: state
        )

        XCTAssertEqual(dismissController.scheduledDelay, 2.0)
    }

    func testEmptyTranscription_DoesNotExecuteOutputs() async {
        await transcriber.setTextToReturn("")

        await processor.process(
            capture: makeCapture(), config: makeConfig(), state: state
        )

        XCTAssertTrue(output.executedDestinations.isEmpty)
    }

    // MARK: - Manual Copy Required

    func testManualCopy_PreventsAutoDismiss() async {
        await transcriber.setTextToReturn("Copy me")
        output.onExecute = { state in
            // Simulate OutputHandler setting needsManualCopy
            state.needsManualCopy = true
            state.manualCopyText = "Copy me"
        }

        await processor.process(
            capture: makeCapture(),
            config: makeConfig(panelPersistence: .autoDismiss(delay: 2.0)),
            state: state
        )

        XCTAssertEqual(state.phase, .done)
        XCTAssertTrue(state.needsManualCopy)
        XCTAssertNil(dismissController.scheduledDelay,
                      "Auto-dismiss must not be scheduled when manual copy is required")
    }

    // MARK: - Copy Fallback

    func testCopiedFallback_AllowsAutoDismiss() async {
        await transcriber.setTextToReturn("Fallback text")
        output.onExecute = { state in
            state.finalText = "Fallback text\n(Copied: App not found)"
        }

        await processor.process(
            capture: makeCapture(),
            config: makeConfig(panelPersistence: .autoDismiss(delay: 2.0)),
            state: state
        )

        XCTAssertEqual(state.phase, .done)
        XCTAssertFalse(state.needsManualCopy)
        XCTAssertEqual(dismissController.scheduledDelay, 2.0)
    }

    // MARK: - Stay Open

    func testStayOpen_DoesNotScheduleDismiss() async {
        await transcriber.setTextToReturn("Stay open text")

        await processor.process(
            capture: makeCapture(),
            config: makeConfig(panelPersistence: .stayOpen),
            state: state
        )

        XCTAssertEqual(state.phase, .done)
        XCTAssertNil(dismissController.scheduledDelay)
    }

    // MARK: - Transcription Error

    func testTranscriptionError_SetsErrorPhase() async {
        await transcriber.setErrorToThrow(TranscriptionError.tooShort)

        await processor.process(
            capture: makeCapture(), config: makeConfig(), state: state
        )

        if case .error(let msg) = state.phase {
            XCTAssertEqual(msg, "Recording too short")
        } else {
            XCTFail("Expected error phase, got \(state.phase)")
        }
    }

    func testTranscriptionError_SchedulesDismiss() async {
        await transcriber.setErrorToThrow(TranscriptionError.tooShort)

        await processor.process(
            capture: makeCapture(), config: makeConfig(), state: state
        )

        XCTAssertEqual(dismissController.scheduledDelay, 2.0)
    }

    // MARK: - Pipeline Error

    func testPipelineError_SetsErrorPhase() async {
        await transcriber.setTextToReturn("Some text")
        let step = ProcessingStep.segmentMerge(SegmentMergeConfig())
        pipeline.errorToThrow = PipelineError.serviceMissing("test error")

        await processor.process(
            capture: makeCapture(),
            config: makeConfig(processing: [step]),
            state: state
        )

        if case .error(let msg) = state.phase {
            XCTAssertTrue(msg.contains("test error"))
        } else {
            XCTFail("Expected error phase, got \(state.phase)")
        }
    }

    func testPipelineError_SchedulesDismiss() async {
        await transcriber.setTextToReturn("Some text")
        let step = ProcessingStep.segmentMerge(SegmentMergeConfig())
        pipeline.errorToThrow = PipelineError.serviceMissing("broken")

        await processor.process(
            capture: makeCapture(),
            config: makeConfig(processing: [step]),
            state: state
        )

        XCTAssertEqual(dismissController.scheduledDelay, 2.0)
    }

    // MARK: - Multi-Turn LLM Steps Filtered

    func testMultiTurnLLMSteps_AreSkippedInSingleShot() async {
        await transcriber.setTextToReturn("Some text")

        let multiTurnStep = ProcessingStep.llmTransform(
            LLMTransformConfig(multiTurn: true)
        )
        let singleShotStep = ProcessingStep.segmentMerge(SegmentMergeConfig())

        await processor.process(
            capture: makeCapture(),
            config: makeConfig(processing: [multiTurnStep, singleShotStep]),
            state: state
        )

        // Only the segmentMerge step should reach the pipeline
        XCTAssertEqual(pipeline.receivedSteps.count, 1)
        if case .segmentMerge = pipeline.receivedSteps.first {
            // correct
        } else {
            XCTFail("Expected segmentMerge, got \(String(describing: pipeline.receivedSteps.first))")
        }
    }

    func testAllMultiTurnStepsFiltered_SkipsPipeline() async {
        await transcriber.setTextToReturn("Some text")

        let multiTurnStep = ProcessingStep.llmTransform(
            LLMTransformConfig(multiTurn: true)
        )

        await processor.process(
            capture: makeCapture(),
            config: makeConfig(processing: [multiTurnStep]),
            state: state
        )

        // Pipeline should not have been called (empty steps after filtering)
        XCTAssertTrue(pipeline.receivedSteps.isEmpty)
        XCTAssertEqual(state.phase, .done)
    }

    // MARK: - Generic Error Fallback

    func testGenericError_ShowsProcessingFailed() async {
        struct SomeError: Error {}
        await transcriber.setErrorToThrow(SomeError())

        await processor.process(
            capture: makeCapture(), config: makeConfig(), state: state
        )

        if case .error(let msg) = state.phase {
            XCTAssertEqual(msg, "Processing failed")
        } else {
            XCTFail("Expected error phase")
        }
    }
}
