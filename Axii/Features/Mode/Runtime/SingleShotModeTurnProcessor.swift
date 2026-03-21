//
//  SingleShotModeTurnProcessor.swift
//  Axii
//
//  Post-capture execution processor for the single-shot mode family.
//  Owns: transcription, empty-result handling, pipeline execution,
//  output execution, turn-completion phase, dismiss decisions, and
//  error mapping.
//
//  Used by any mode that follows the single-shot execution pattern:
//  built-in Dictation, custom single-shot modes.
//
//  Does NOT own: hotkeys, panel lifecycle, capture start/stop,
//  activation/deactivation, or explicit cancel behavior.
//

#if os(macOS)
import Foundation

@MainActor
final class SingleShotModeTurnProcessor {

    private let transcriber: any TranscriptionProviding
    private let pipeline: any PipelineExecuting
    private let output: any ModeOutputExecuting
    private weak var dismissController: (any ModeDismissControlling)?

    init(
        transcriber: any TranscriptionProviding,
        pipeline: any PipelineExecuting,
        output: any ModeOutputExecuting,
        dismissController: any ModeDismissControlling
    ) {
        self.transcriber = transcriber
        self.pipeline = pipeline
        self.output = output
        self.dismissController = dismissController
    }

    /// Execute the single-shot post-capture turn.
    /// Caller is responsible for setting state.phase = .transcribing before calling.
    func process(
        capture: CompletedCapture,
        config: SingleShotTurnConfig,
        state: ModeRuntimeState
    ) async {
        do {
            let text = try await transcriber.transcribe(
                samples: capture.samples,
                sampleRate: capture.sampleRate
            )

            if text.isEmpty {
                state.finalText = "No speech detected"
                state.phase = .done
                dismissController?.scheduleDismiss(after: 2.0)
                return
            }

            // Build pipeline context from transcription result
            let duration = capture.sampleRate > 0
                ? TimeInterval(capture.samples.count) / capture.sampleRate
                : nil

            let initialContext = PipelineContext(
                transcription: text,
                samples: capture.samples,
                sampleRate: capture.sampleRate,
                modeName: config.modeName,
                appName: capture.focusSnapshot?.appName,
                duration: duration,
                date: Date(),
                focusSnapshot: capture.focusSnapshot
            )

            // Filter out multi-turn LLM steps — those use ConversationHandler
            let pipelineSteps = config.processing.filter {
                if case .llmTransform(let cfg) = $0 { return !cfg.multiTurn }
                return true
            }

            let finalContext: PipelineContext
            if !pipelineSteps.isEmpty {
                state.phase = .processing
                finalContext = try await pipeline.run(
                    steps: pipelineSteps, context: initialContext
                )
            } else {
                finalContext = initialContext
            }

            state.finalText = finalContext.text
            await output.executeOutputs(
                destinations: config.outputs,
                context: finalContext,
                state: state
            )

            // Turn completion — processor owns this, not the output executor
            state.phase = .done

            // Dismiss decision
            if !state.needsManualCopy,
               case .autoDismiss(let delay) = config.panelPersistence {
                dismissController?.scheduleDismiss(after: delay)
            }
        } catch {
            let msg = (error as? TranscriptionError)?.errorDescription
                ?? (error as? LocalizedError)?.errorDescription
                ?? "Processing failed"
            state.phase = .error(msg)
            dismissController?.scheduleDismiss(after: 2.0)
        }
    }
}

#endif
