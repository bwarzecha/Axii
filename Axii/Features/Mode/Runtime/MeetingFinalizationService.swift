//
//  MeetingFinalizationService.swift
//  Axii
//
//  Owns final meeting transcription and segment assembly.
//  Consumes a MeetingFinalizationInput (raw mic + system samples)
//  and produces a MeetingPersistencePayload with sorted, merged,
//  source-labelled MeetingSegments.
//
//  Does not own: live capture, autosave, crash recovery, audio I/O,
//  temp-file cleanup, or persistence. Those remain in their existing
//  owners (MeetingAudioManager, MeetingTranscriptManager,
//  MeetingPipelineHandler, MeetingPersistenceService).
//

#if os(macOS)
import Accelerate
import Foundation

// MARK: - Input Boundary

/// Explicit input contract for finalization. Captures the raw audio
/// produced by the live recording pipeline plus the envelope data
/// needed to build a MeetingPersistencePayload.
struct MeetingFinalizationInput {
    let micSamples: [Float]
    let micSampleRate: Double
    let systemSamples: [Float]
    let systemSampleRate: Double
    let duration: TimeInterval
    let appName: String?
}

// MARK: - Service

/// Service that turns raw post-stop meeting audio into a persistable
/// payload. Behavior preserved from MeetingTranscriptManager's
/// previous final-transcription path:
///   - resample to 16 kHz
///   - 30-second chunks
///   - skip chunks with max amplitude < 0.001
///   - per-chunk transcription failures are best-effort (logged, not fatal)
///   - source labels: mic → "You" / isFromMicrophone=true,
///                    system → "Remote" / isFromMicrophone=false
///   - segments sorted by startTime and consecutive same-speaker merged
@MainActor
final class MeetingFinalizationService {

    // MARK: Configuration

    private static let targetSampleRate: Double = 16000
    private static let chunkSeconds: Double = 30
    private static let silenceThreshold: Float = 0.001

    // MARK: Dependencies

    private let transcriptionService: any TranscriptionProviding

    // MARK: Init

    init(transcriptionService: any TranscriptionProviding) {
        self.transcriptionService = transcriptionService
    }

    // MARK: API

    /// Produce the final persistable payload for a meeting.
    /// Always completes; per-chunk transcription failures are tolerated.
    ///
    /// Progress is reported through the closure PARAMETER, not shared
    /// service state: overlapping finalize calls (an old detached stop
    /// racing a new one) each keep their own reporting channel, and the
    /// caller decides whether a given call may still write to the UI.
    /// (fractionComplete in [0, 1], userVisibleStatusText — stage texts
    /// preserved exactly from prior behavior so UI does not regress.)
    func finalize(
        input: MeetingFinalizationInput,
        onProgress: @escaping (Double, String) -> Void = { _, _ in }
    ) async -> MeetingPersistencePayload {
        // Resample to 16 kHz for transcription.
        let micResampled = resample(input.micSamples, from: input.micSampleRate)
        let systemResampled = resample(input.systemSamples, from: input.systemSampleRate)

        // Compute progress denominator.
        let chunkSize = Int(Self.targetSampleRate * Self.chunkSeconds)
        let micChunks = micResampled.isEmpty
            ? 0
            : (micResampled.count + chunkSize - 1) / chunkSize
        let systemChunks = systemResampled.isEmpty
            ? 0
            : (systemResampled.count + chunkSize - 1) / chunkSize
        let totalChunks = micChunks + systemChunks
        var completedChunks = 0

        var segments: [MeetingSegment] = []

        // Mic track.
        onProgress(0, "Transcribing your audio...")
        await transcribeFullTrack(
            samples: micResampled,
            speakerId: "You",
            isFromMicrophone: true,
            into: &segments
        ) {
            completedChunks += 1
            let progress = totalChunks > 0
                ? Double(completedChunks) / Double(totalChunks)
                : 0
            onProgress(progress, "Transcribing your audio...")
        }

        // System track.
        let systemStartProgress = totalChunks > 0
            ? Double(micChunks) / Double(totalChunks)
            : 0
        onProgress(systemStartProgress, "Transcribing remote audio...")
        await transcribeFullTrack(
            samples: systemResampled,
            speakerId: "Remote",
            isFromMicrophone: false,
            into: &segments
        ) {
            completedChunks += 1
            let progress = totalChunks > 0
                ? Double(completedChunks) / Double(totalChunks)
                : 0
            onProgress(progress, "Transcribing remote audio...")
        }

        // Sort + merge consecutive same-speaker segments.
        onProgress(0.95, "Merging transcript...")
        segments = mergeConsecutiveSpeakerSegments(segments)

        onProgress(1.0, "Done")

        return MeetingPersistencePayload(
            micSamples: input.micSamples,
            micSampleRate: input.micSampleRate,
            systemSamples: input.systemSamples,
            systemSampleRate: input.systemSampleRate,
            segments: segments,
            duration: input.duration,
            appName: input.appName
        )
    }

    // MARK: - Internal: Track Transcription

    private func transcribeFullTrack(
        samples: [Float],
        speakerId: String,
        isFromMicrophone: Bool,
        into segments: inout [MeetingSegment],
        onChunkComplete: () -> Void
    ) async {
        guard !samples.isEmpty else { return }

        let chunkSize = Int(Self.targetSampleRate * Self.chunkSeconds)
        var currentOffset = 0

        while currentOffset < samples.count {
            let endOffset = min(currentOffset + chunkSize, samples.count)
            let chunk = Array(samples[currentOffset..<endOffset])

            // Skip silent chunks (max amplitude below threshold).
            let maxAmp = chunk.map { abs($0) }.max() ?? 0.0
            if maxAmp < Self.silenceThreshold {
                currentOffset = endOffset
                onChunkComplete()
                continue
            }

            let chunkStartTime = Double(currentOffset) / Self.targetSampleRate
            let chunkEndTime = Double(endOffset) / Self.targetSampleRate

            do {
                let text = try await transcriptionService.transcribe(
                    samples: chunk,
                    sampleRate: Self.targetSampleRate
                )
                let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    segments.append(MeetingSegment(
                        text: cleaned,
                        speakerId: speakerId,
                        isFromMicrophone: isFromMicrophone,
                        startTime: chunkStartTime,
                        endTime: chunkEndTime
                    ))
                }
            } catch {
                // Best-effort: log and continue. Matches prior behavior in
                // MeetingTranscriptManager.transcribeFullTrack.
                print("MeetingFinalizationService: chunk transcription error: \(error)")
            }

            currentOffset = endOffset
            onChunkComplete()
        }
    }

    // MARK: - Internal: Resample

    /// Resample audio to 16 kHz. Returns input unchanged if already 16 kHz.
    /// Delegates to the shared windowed resampler: this service's previous
    /// private copy used one Float32 ramp across the whole track, whose
    /// indices quantize past 2^24 — every meeting longer than ~12 minutes
    /// got a silently garbled transcript tail.
    private func resample(_ samples: [Float], from sampleRate: Double) -> [Float] {
        guard !samples.isEmpty, sampleRate > 0 else { return [] }
        return AudioResampler.resample(
            samples, from: sampleRate, to: Self.targetSampleRate
        )
    }

    // MARK: - Internal: Sort + Merge

    /// Sort by startTime and merge runs of same-speakerId segments.
    /// Preserved verbatim from MeetingTranscriptManager.mergeConsecutiveSpeakerSegments.
    private func mergeConsecutiveSpeakerSegments(
        _ input: [MeetingSegment]
    ) -> [MeetingSegment] {
        guard input.count > 1 else { return input }

        let sorted = input.sorted { $0.startTime < $1.startTime }
        var merged: [MeetingSegment] = []
        var current = sorted[0]

        for i in 1..<sorted.count {
            let next = sorted[i]
            if current.speakerId == next.speakerId {
                current = MeetingSegment(
                    id: current.id,
                    text: current.text + " " + next.text,
                    speakerId: current.speakerId,
                    isFromMicrophone: current.isFromMicrophone,
                    startTime: current.startTime,
                    endTime: max(current.endTime, next.endTime)
                )
            } else {
                merged.append(current)
                current = next
            }
        }
        merged.append(current)
        return merged
    }
}
#endif
