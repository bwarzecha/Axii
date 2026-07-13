//
//  DiscardedCaptureArchiver.swift
//  Axii
//
//  Persists a discarded simple-mode capture into "Recently Deleted".
//  Durability order: entry first, audio second, transcript last — the
//  audio write is the recovery guarantee; the transcript is best-effort
//  enrichment (models missing or ASR failure must not cost recovery).
//

#if os(macOS)
import Foundation
import os.log

private let logger = Logger(subsystem: "com.axii", category: "DiscardArchiver")

@MainActor
final class DiscardedCaptureArchiver {

    private let history: HistoryService
    private let transcriber: any TranscriptionProviding

    /// The in-flight archive write, nil once everything scheduled has
    /// finished. Chained (each archive awaits its predecessor, so folder
    /// writes never interleave) and awaitable, so tests — and any exit
    /// path that must not outrun the write — can join via drain().
    private(set) var currentTask: Task<Void, Never>?
    /// Archives whose AUDIO write hasn't landed yet. While nonzero the
    /// owning feature stays data-bearing, so the quit-gate drain loop
    /// holds termination until the discarded capture is durable on disk.
    private(set) var pendingWrites = 0
    /// Identity for currentTask cleanup: only the newest archive may nil
    /// the handle when it finishes.
    private var taskGeneration = 0

    init(history: HistoryService, transcriber: any TranscriptionProviding) {
        self.history = history
        self.transcriber = transcriber
    }

    /// Await every archive scheduled so far (including ones chained while
    /// waiting).
    func drain() async {
        while let task = currentTask {
            await task.value
            await Task.yield()
        }
    }

    /// Archive a capture as a DISCARDED transcription entry. `config`
    /// shapes the persistence (audio on/off, format); nil uses defaults.
    /// `createdAt` backdates the entry (crash recovery restores a capture
    /// under its original date). `onAudioDurable` fires on the main actor
    /// once entry + audio are on disk — the point where any crash spool
    /// backing this capture may be deleted; it is NOT called on failure,
    /// so a failed archive leaves the spool for the next launch to retry.
    /// Detached: must outlive the panel teardown that triggered it.
    func archive(
        samples: [Float], sampleRate: Double, config: HistoryConfig?,
        createdAt: Date = Date(),
        onAudioDurable: (@MainActor @Sendable () -> Void)? = nil
    ) {
        guard history.isEnabled else { return }
        let config = config ?? HistoryConfig()
        let history = history
        let transcriber = transcriber
        let previous = currentTask
        pendingWrites += 1
        taskGeneration += 1
        let generation = taskGeneration
        currentTask = Task.detached(priority: .utility) { [weak self] in
            await previous?.value
            await Self.persist(
                samples: samples, sampleRate: sampleRate, config: config,
                createdAt: createdAt,
                history: history, transcriber: transcriber,
                onAudioDurable: onAudioDurable
            ) {
                // Audio durable (or failed-and-logged) either way: release
                // the quit gate — nothing more can be waited for.
                Task { @MainActor in self?.pendingWrites -= 1 }
            }
            Task { @MainActor in
                guard let self, self.taskGeneration == generation else { return }
                self.currentTask = nil
            }
        }
    }

    private static func persist(
        samples: [Float], sampleRate: Double, config: HistoryConfig,
        createdAt: Date,
        history: HistoryService, transcriber: any TranscriptionProviding,
        onAudioDurable: (@MainActor @Sendable () -> Void)?,
        onAudioSettled: () -> Void
    ) async {
        let discarded = Transcription(
            text: "", createdAt: createdAt, discardedAt: Date()
        )
        var audio: AudioRecording?
        do {
            defer { onAudioSettled() }
            try await history.save(.transcription(discarded))
            if config.saveAudio {
                audio = try await history.saveAudioCompressed(
                    samples: samples, sampleRate: sampleRate,
                    format: config.audioFormat, for: discarded.id
                )
                try await history.save(.transcription(
                    discarded.with(audio: audio)
                ))
            }
            if let onAudioDurable {
                await MainActor.run { onAudioDurable() }
            }
        } catch {
            logger.error(
                "Discard archive failed: \(error.localizedDescription)"
            )
            return
        }
        do {
            if await !transcriber.isReady { try await transcriber.prepare() }
            let text = try await transcriber.transcribe(
                samples: samples, sampleRate: sampleRate
            )
            guard !text.isEmpty else { return }
            try await history.save(.transcription(
                discarded.with(audio: audio, text: text)
            ))
        } catch {
            // Audio is already durable; a failed transcript costs
            // nothing the user can't recover later.
            logger.warning(
                "Discard archive kept audio without transcript: \(error.localizedDescription)"
            )
        }
    }
}

private extension Transcription {
    func with(audio: AudioRecording?, text: String? = nil) -> Transcription {
        Transcription(
            id: id, text: text ?? self.text, audioRecording: audio,
            pastedTo: pastedTo, focusContext: focusContext,
            createdAt: createdAt, discardedAt: discardedAt
        )
    }
}
#endif
