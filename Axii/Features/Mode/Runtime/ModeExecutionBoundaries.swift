//
//  ModeExecutionBoundaries.swift
//  Axii
//
//  Narrow boundary interfaces for mode turn execution processors.
//  These exist to make processor tests stable without pinning them
//  to runtime adapter internals.
//

#if os(macOS)
import Foundation

/// Wraps PipelineRunner for processor-level testing.
@MainActor
protocol PipelineExecuting {
    func run(
        steps: [ProcessingStep],
        context: PipelineContext
    ) async throws -> PipelineContext
}

/// Wraps OutputHandler for processor-level testing.
@MainActor
protocol ModeOutputExecuting {
    func executeOutputs(
        destinations: [OutputDestination],
        context: PipelineContext,
        state: ModeRuntimeState
    ) async
}

/// Dismiss control seam so processor tests can verify dismiss decisions
/// without reaching into DispatchWorkItem internals.
@MainActor
protocol ModeDismissControlling: AnyObject {
    func cancelScheduledDismiss()
    func scheduleDismiss(after delay: TimeInterval)
}

#endif
