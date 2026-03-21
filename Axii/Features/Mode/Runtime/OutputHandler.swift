//
//  OutputHandler.swift
//  Axii
//
//  Executes output actions after transcription/processing completes.
//  Iterates over [OutputDestination] from ModeConfig, executing each
//  destination independently (non-short-circuiting).
//
//  Each output resolves its contentTemplate against PipelineContext.
//  If no template is set, uses context.text (the traveling text).
//

#if os(macOS)
import Foundation
import os.log

private let logger = Logger(subsystem: "com.axii", category: "OutputHandler")

@MainActor
final class OutputHandler: ModeOutputExecuting {
    private let pasteService: any PasteProviding
    private let clipboardService: ClipboardService
    private let historyService: HistoryService
    private let settings: SettingsService
    private let fileOutputService = FileOutputService()
    private let templateResolver = TemplateResolver()

    init(
        pasteService: any PasteProviding,
        clipboardService: ClipboardService,
        historyService: HistoryService,
        settings: SettingsService
    ) {
        self.pasteService = pasteService
        self.clipboardService = clipboardService
        self.historyService = historyService
        self.settings = settings
    }

    /// Execute all output destinations, non-short-circuiting.
    func executeOutputs(
        destinations: [OutputDestination],
        context: PipelineContext,
        state: ModeRuntimeState
    ) async {
        var pastedToApp: String?

        for destination in destinations {
            switch destination {
            case .pasteAtCursor(let pasteConfig):
                let text = resolveContent(pasteConfig.contentTemplate, context: context)
                pastedToApp = await executePaste(
                    config: pasteConfig, text: text, state: state
                )

            case .clipboard(let clipConfig):
                let text = resolveContent(clipConfig.contentTemplate, context: context)
                clipboardService.copy(text)

            case .display(let displayConfig):
                let text = resolveContent(displayConfig.contentTemplate, context: context)
                state.finalText = text

            case .file(let fileConfig):
                do {
                    try await fileOutputService.write(
                        config: fileConfig, context: context,
                        templateResolver: templateResolver
                    )
                } catch {
                    logger.error("File output failed: \(error.localizedDescription)")
                }

            case .history(let historyConfig):
                await saveTranscriptionHistory(
                    config: historyConfig,
                    text: context.text,
                    samples: context.samples,
                    sampleRate: context.sampleRate,
                    pastedToApp: pastedToApp,
                    focusSnapshot: state.focusSnapshot
                )
            }
        }
    }

    // MARK: - Template Resolution

    private func resolveContent(
        _ template: String?,
        context: PipelineContext
    ) -> String {
        guard let template, !template.isEmpty else {
            return context.text
        }
        return templateResolver.resolve(template, context: context)
    }

    // MARK: - Paste

    private func executePaste(
        config: PasteConfig,
        text: String,
        state: ModeRuntimeState
    ) async -> String? {
        let outcome = await pasteService.paste(
            text: text,
            focusSnapshot: state.focusSnapshot,
            finishBehavior: settings.finishBehavior,
            failureBehavior: config.failureBehavior
        )

        switch outcome {
        case .pasted, .pastedAndCopied:
            state.finalText = text
            return state.focusSnapshot?.bundleIdentifier

        case .copiedOnly:
            state.finalText = "\(text)\n(Copied to clipboard)"
            return nil

        case .copiedFallback(let reason):
            state.finalText = "\(text)\n(Copied: \(reason))"
            return nil

        case .needsManualCopy:
            state.finalText = text
            state.needsManualCopy = true
            state.manualCopyText = text
            return nil

        case .skipped:
            state.finalText = "No speech detected"
            return nil
        }
    }

    // MARK: - History

    private func saveTranscriptionHistory(
        config: HistoryConfig,
        text: String,
        samples: [Float]?,
        sampleRate: Double?,
        pastedToApp: String?,
        focusSnapshot: FocusSnapshot?
    ) async {
        guard historyService.isEnabled else { return }
        let focusContext = focusSnapshot.map { FocusContext(from: $0) }

        do {
            let transcription = Transcription(
                text: text,
                pastedTo: pastedToApp,
                focusContext: focusContext
            )

            try await historyService.save(.transcription(transcription))

            if config.saveAudio,
               let samples, let sampleRate,
               !samples.isEmpty, sampleRate > 0 {
                let audioRecording = try await historyService
                    .saveAudioCompressed(
                        samples: samples,
                        sampleRate: sampleRate,
                        format: config.audioFormat,
                        for: transcription.id
                    )

                let updated = Transcription(
                    id: transcription.id,
                    text: text,
                    audioRecording: audioRecording,
                    pastedTo: pastedToApp,
                    focusContext: focusContext,
                    createdAt: transcription.createdAt
                )

                try await historyService.save(.transcription(updated))
            }
        } catch {
            logger.error("Failed to save transcription: \(error.localizedDescription)")
        }
    }
}
#endif
