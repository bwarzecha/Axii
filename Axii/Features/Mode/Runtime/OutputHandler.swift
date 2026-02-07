//
//  OutputHandler.swift
//  Axii
//
//  Executes output actions after transcription/processing completes.
//  Handles paste-at-cursor, copy-to-clipboard, and history saving
//  based on OutputConfig from ModeConfig.
//

#if os(macOS)
import Foundation

@MainActor
final class OutputHandler {
    private let pasteService: PasteService
    private let clipboardService: ClipboardService
    private let historyService: HistoryService
    private let settings: SettingsService

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

    /// Execute output actions based on config.
    /// Updates state.phase to .done and sets needsManualCopy when needed,
    /// or schedules deactivation via the state.
    func executeOutput(
        config: OutputConfig,
        text: String,
        state: ModeRuntimeState,
        modeConfig: ModeConfig,
        samples: [Float]?,
        sampleRate: Double?
    ) async {
        var pastedToApp: String?

        // 1. Paste at cursor if configured
        if config.pasteAtCursor {
            let outcome = await pasteService.paste(
                text: text,
                focusSnapshot: state.focusSnapshot,
                finishBehavior: settings.finishBehavior,
                failureBehavior: settings.insertionFailureBehavior
            )

            switch outcome {
            case .pasted:
                state.finalText = text
                state.phase = .done
                pastedToApp = state.focusSnapshot?.bundleIdentifier

            case .pastedAndCopied:
                state.finalText = text
                state.phase = .done
                pastedToApp = state.focusSnapshot?.bundleIdentifier

            case .copiedOnly:
                state.finalText = "\(text)\n(Copied to clipboard)"
                state.phase = .done

            case .copiedFallback(let reason):
                state.finalText = "\(text)\n(Copied: \(reason))"
                state.phase = .done

            case .needsManualCopy:
                state.finalText = text
                state.needsManualCopy = true
                state.manualCopyText = text
                state.phase = .done

            case .skipped:
                state.finalText = "No speech detected"
                state.phase = .done
            }
        } else if config.copyToClipboard {
            // 2. Copy to clipboard if configured (and not pasting)
            clipboardService.copy(text)
            state.finalText = "\(text)\n(Copied to clipboard)"
            state.phase = .done
        } else {
            // Neither paste nor copy - just show the result
            state.finalText = text
            state.phase = .done
        }

        // 3. Save to history if configured
        if config.saveToHistory {
            await saveToHistory(
                config: config,
                text: text,
                samples: samples,
                sampleRate: sampleRate,
                pastedToApp: pastedToApp,
                focusSnapshot: state.focusSnapshot
            )
        }
    }

    // MARK: - History Saving

    private func saveToHistory(
        config: OutputConfig,
        text: String,
        samples: [Float]?,
        sampleRate: Double?,
        pastedToApp: String?,
        focusSnapshot: FocusSnapshot?
    ) async {
        guard historyService.isEnabled else { return }

        switch config.historyType {
        case .transcription:
            await saveTranscription(
                text: text,
                samples: samples,
                sampleRate: sampleRate,
                pastedToApp: pastedToApp,
                focusSnapshot: focusSnapshot
            )
        case .conversation:
            // Handled by ConversationHandler in Phase 1B
            break
        case .meeting:
            // Handled by MeetingPipelineHandler in Phase 1C
            break
        }
    }

    private func saveTranscription(
        text: String,
        samples: [Float]?,
        sampleRate: Double?,
        pastedToApp: String?,
        focusSnapshot: FocusSnapshot?
    ) async {
        let focusContext = focusSnapshot.map { FocusContext(from: $0) }

        do {
            let transcription = Transcription(
                text: text,
                pastedTo: pastedToApp,
                focusContext: focusContext
            )

            try await historyService.save(.transcription(transcription))

            // Save audio if samples provided
            if let samples, let sampleRate,
               !samples.isEmpty, sampleRate > 0 {
                let audioRecording = try await historyService
                    .saveAudioCompressed(
                        samples: samples,
                        sampleRate: sampleRate,
                        format: settings.audioStorageFormat,
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
            print("OutputHandler: Failed to save transcription: \(error)")
        }
    }
}
#endif
