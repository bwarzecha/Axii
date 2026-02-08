//
//  OutputHandler.swift
//  Axii
//
//  Executes output actions after transcription/processing completes.
//  Iterates over [OutputDestination] from ModeConfig, executing each
//  destination independently (non-short-circuiting).
//

#if os(macOS)
import Foundation
import os.log

private let logger = Logger(subsystem: "com.axii", category: "OutputHandler")

@MainActor
final class OutputHandler {
    private let pasteService: PasteService
    private let clipboardService: ClipboardService
    private let historyService: HistoryService
    private let settings: SettingsService
    private let fileOutputService = FileOutputService()

    init(
        pasteService: PasteService,
        clipboardService: ClipboardService,
        historyService: HistoryService,
        settings: SettingsService
    ) {
        self.pasteService = pasteService
        self.clipboardService = clipboardService
        self.historyService = historyService
        self.settings = settings
    }

    /// Execute all output destinations from config, non-short-circuiting.
    func executeOutputs(
        destinations: [OutputDestination],
        text: String,
        state: ModeRuntimeState,
        modeName: String = "",
        samples: [Float]?,
        sampleRate: Double?
    ) async {
        var pastedToApp: String?

        for destination in destinations {
            switch destination {
            case .pasteAtCursor(let pasteConfig):
                pastedToApp = await executePaste(
                    config: pasteConfig, text: text, state: state
                )

            case .clipboard:
                clipboardService.copy(text)

            case .display:
                state.finalText = text

            case .file(let fileConfig):
                let context = FileTemplateContext(
                    modeName: modeName,
                    appName: state.focusSnapshot?.appName
                )
                do {
                    try await fileOutputService.write(
                        text: text, config: fileConfig, context: context
                    )
                } catch {
                    logger.error("File output failed: \(error.localizedDescription)")
                }

            case .history(let historyConfig):
                await saveTranscriptionHistory(
                    config: historyConfig, text: text,
                    samples: samples, sampleRate: sampleRate,
                    pastedToApp: pastedToApp,
                    focusSnapshot: state.focusSnapshot
                )
            }
        }

        state.phase = .done
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
