//
//  PipelineRunner.swift
//  Axii
//
//  Orchestrates processing pipeline execution.
//  Iterates through configured ProcessingSteps, creates the right
//  executor for each, and runs them sequentially against a shared
//  PipelineContext.
//

#if os(macOS)
import Foundation
import os.log

private let logger = Logger(subsystem: "com.axii", category: "PipelineRunner")

@MainActor
final class PipelineRunner {
    private let llmService: LLMService?
    private let diarizationService: DiarizationService?
    let templateResolver = TemplateResolver()

    init(
        llmService: LLMService? = nil,
        diarizationService: DiarizationService? = nil
    ) {
        self.llmService = llmService
        self.diarizationService = diarizationService
    }

    /// Run all processing steps against the context.
    /// Returns the final context with all results.
    func run(
        steps: [ProcessingStep],
        context: PipelineContext
    ) async throws -> PipelineContext {
        guard !steps.isEmpty else { return context }

        var ctx = context
        logger.info("Pipeline: running \(steps.count) step(s)")

        for (index, step) in steps.enumerated() {
            let executor = try createExecutor(for: step)
            logger.info("Pipeline: step \(index + 1)/\(steps.count) — \(step.shortName)")
            try await executor.execute(context: &ctx)
        }

        logger.info("Pipeline: complete")
        return ctx
    }

    // MARK: - Executor Factory

    private func createExecutor(
        for step: ProcessingStep
    ) throws -> PipelineStepExecutor {
        switch step {
        case .diarize(let config):
            return DiarizeStepExecutor(
                config: config,
                diarizationService: diarizationService
            )

        case .segmentMerge(let config):
            return SegmentMergeStepExecutor(config: config)

        case .llmTransform(let config):
            guard let llm = llmService else {
                throw PipelineError.serviceMissing("LLM service not configured")
            }
            return LLMTransformStepExecutor(
                config: config,
                llmService: llm,
                templateResolver: templateResolver
            )
        }
    }
}

// MARK: - Errors

enum PipelineError: LocalizedError {
    case serviceMissing(String)

    var errorDescription: String? {
        switch self {
        case .serviceMissing(let detail):
            return "Pipeline error: \(detail)"
        }
    }
}
#endif
