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

    // MARK: Callbacks

    /// Progress updates: (fractionComplete in [0, 1], userVisibleStatusText)
    /// Stage texts preserved exactly from prior behavior so UI does not regress.
    var onProgressUpdated: ((Double, String) -> Void)?

    // MARK: Init

    init(transcriptionService: any TranscriptionProviding) {
        self.transcriptionService = transcriptionService
    }

    // MARK: API

    /// Produce the final persistable payload for a meeting.
    /// Always completes; per-chunk transcription failures are tolerated.
    func finalize(
        input: MeetingFinalizationInput
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
        onProgressUpdated?(0, "Transcribing your audio...")
        await transcribeFullTrack(
            samples: micResampled,
            speakerId: "You",
            isFromMicrophone: true,
            into: &segments
        ) { [weak self] in
            completedChunks += 1
            let progress = totalChunks > 0
                ? Double(completedChunks) / Double(totalChunks)
                : 0
            self?.onProgressUpdated?(progress, "Transcribing your audio...")
        }

        // System track.
        let systemStartProgress = totalChunks > 0
            ? Double(micChunks) / Double(totalChunks)
            : 0
        onProgressUpdated?(systemStartProgress, "Transcribing remote audio...")
        await transcribeFullTrack(
            samples: systemResampled,
            speakerId: "Remote",
            isFromMicrophone: false,
            into: &segments
        ) { [weak self] in
            completedChunks += 1
            let progress = totalChunks > 0
                ? Double(completedChunks) / Double(totalChunks)
                : 0
            self?.onProgressUpdated?(progress, "Transcribing remote audio...")
        }

        // Sort + merge consecutive same-speaker segments.
        onProgressUpdated?(0.95, "Merging transcript...")
        segments = mergeConsecutiveSpeakerSegments(segments)

        onProgressUpdated?(1.0, "Done")

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
    /// Preserved verbatim from MeetingTranscriptManager.resample.
    private func resample(_ samples: [Float], from sampleRate: Double) -> [Float] {
        guard !samples.isEmpty, sampleRate > 0 else { return [] }
        guard sampleRate != Self.targetSampleRate else { return samples }
        guard samples.count > 1 else { return samples }

        let outputCount = Int(Double(samples.count) * Self.targetSampleRate / sampleRate)
        guard outputCount > 0 else { return [] }

        var output = [Float](repeating: 0, count: outputCount)
        var indices = [Float](repeating: 0, count: outputCount)
        var index: Float = 0
        var increment = Float(sampleRate / Self.targetSampleRate)
        vDSP_vramp(&index, &increment, &indices, 1, vDSP_Length(outputCount))

        var maxIndex = Float(samples.count - 1)
        vDSP_vclip(indices, 1, &index, &maxIndex, &indices, 1, vDSP_Length(outputCount))
        vDSP_vlint(samples, indices, 1, &output, 1, vDSP_Length(outputCount), vDSP_Length(samples.count))

        return output
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
