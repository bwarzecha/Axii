//
//  MeetingRetranscriptionService.swift
//  Axii
//
//  Re-runs transcription over a stored meeting's audio and updates the
//  history record in place. This is the recovery path for meetings whose
//  audio survived but whose transcript did not (error exits, crash
//  recoveries of streaming-off sessions, failed finalizations) — and a
//  redo path when a better ASR model lands.
//

#if os(macOS)
import AVFoundation
import Foundation

enum MeetingRetranscriptionError: LocalizedError {
    case noAudio
    case producedEmptyTranscript
    case historyDisabled
    case meetingDeleted

    var errorDescription: String? {
        switch self {
        case .noAudio:
            return "This meeting has no stored audio to transcribe"
        case .producedEmptyTranscript:
            return "Transcription found no speech; the existing transcript was kept"
        case .historyDisabled:
            return "History is disabled, so the new transcript cannot be saved"
        case .meetingDeleted:
            return "This meeting was deleted while transcription was running"
        }
    }
}

@MainActor
final class MeetingRetranscriptionService {
    private let finalization: MeetingFinalizationService
    private let historyService: HistoryService

    init(
        transcriptionService: any TranscriptionProviding,
        historyService: HistoryService
    ) {
        self.finalization = MeetingFinalizationService(
            transcriptionService: transcriptionService
        )
        self.historyService = historyService
    }

    /// Re-transcribe a stored meeting from its audio and persist the result
    /// under the same identity (id, createdAt, recordings all preserved).
    ///
    /// Refuses to REPLACE an existing transcript with nothing: a re-run that
    /// finds no speech throws instead of destroying the only transcript the
    /// meeting has.
    func retranscribe(
        _ meeting: Meeting,
        onProgress: @escaping (Double, String) -> Void = { _, _ in }
    ) async throws -> Meeting {
        let mic = decodeSamples(at: audioURL(for: meeting.micRecording, meetingID: meeting.id))
        let system = decodeSamples(at: audioURL(for: meeting.systemRecording, meetingID: meeting.id))
        guard mic != nil || system != nil else {
            throw MeetingRetranscriptionError.noAudio
        }

        // Audio is the truth for duration (matches the live-capture rule);
        // keep the stored value only if decoding yields nothing measurable.
        let derivedDuration = max(
            mic.map { Double($0.samples.count) / $0.sampleRate } ?? 0,
            system.map { Double($0.samples.count) / $0.sampleRate } ?? 0
        )

        let payload = await finalization.finalize(
            input: MeetingFinalizationInput(
                micSamples: mic?.samples ?? [],
                micSampleRate: mic?.sampleRate ?? 0,
                systemSamples: system?.samples ?? [],
                systemSampleRate: system?.sampleRate ?? 0,
                duration: derivedDuration > 0 ? derivedDuration : meeting.duration,
                appName: meeting.appName
            ),
            onProgress: onProgress
        )

        if payload.segments.isEmpty, !meeting.segments.isEmpty {
            throw MeetingRetranscriptionError.producedEmptyTranscript
        }

        // Minutes may have passed. If the user deleted the meeting while
        // transcription ran, saving now would resurrect a zombie record
        // whose audio files the delete already removed.
        guard historyService.cache[meeting.id] != nil else {
            throw MeetingRetranscriptionError.meetingDeleted
        }

        let updated = Meeting(
            id: meeting.id,
            segments: payload.segments,
            duration: derivedDuration > 0 ? derivedDuration : meeting.duration,
            micRecording: meeting.micRecording,
            systemRecording: meeting.systemRecording,
            appName: meeting.appName,
            createdAt: meeting.createdAt
        )
        guard try await historyService.save(.meeting(updated)) == .saved else {
            throw MeetingRetranscriptionError.historyDisabled
        }
        return updated
    }

    // MARK: - Private

    private func audioURL(
        for recording: AudioRecording?,
        meetingID: UUID
    ) -> URL? {
        guard let recording else { return nil }
        return historyService.getAudioURL(recording, for: meetingID)
    }

    /// Decode a stored audio file (wav/m4a — whatever AVAudioFile reads)
    /// into mono float samples at the file's native rate.
    private func decodeSamples(
        at url: URL?
    ) -> (samples: [Float], sampleRate: Double)? {
        guard let url, let file = try? AVAudioFile(forReading: url) else {
            return nil
        }
        let format = file.processingFormat
        let capacity = AVAudioFrameCount(file.length)
        guard capacity > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity),
              (try? file.read(into: buffer)) != nil,
              let channels = buffer.floatChannelData,
              buffer.frameLength > 0
        else { return nil }
        let samples = Array(UnsafeBufferPointer(
            start: channels[0], count: Int(buffer.frameLength)
        ))
        return (samples, format.sampleRate)
    }
}
#endif
