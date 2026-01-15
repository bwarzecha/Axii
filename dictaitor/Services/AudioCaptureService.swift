//
//  AudioCaptureService.swift
//  dictaitor
//
//  AVAudioEngine wrapper for microphone capture.
//  Streams raw audio chunks - UI decides how to visualize.
//

#if os(macOS)
import AVFoundation
import AVFAudio

/// Raw audio chunk delivered to consumer.
struct AudioChunk: Sendable {
    let samples: [Float]
    let sampleRate: Double
}

/// Recording statistics returned on stop.
struct AudioStats {
    let duration: TimeInterval
    let sampleCount: Int
    let sampleRate: Double
}

/// Audio capture service - streams raw chunks, accumulates for transcription.
@MainActor
final class AudioCaptureService {
    private let engine = AVAudioEngine()
    private var accumulatedSamples: [Float] = []
    private var startTime: Date?
    private var sampleRate: Double = 0
    private(set) var isRecording = false

    /// Called with each audio chunk during recording.
    /// Consumer (UI) decides how to use the samples (level bar, waveform, etc.)
    var onChunk: ((AudioChunk) -> Void)?

    /// Start capturing audio from the microphone.
    /// Permission should be checked by caller before invoking this method.
    func startCapture() throws {
        guard !isRecording else { return }

        accumulatedSamples = []
        startTime = Date()

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        guard format.sampleRate > 0 && format.channelCount > 0 else {
            throw AudioCaptureError.invalidFormat
        }

        sampleRate = format.sampleRate

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.processBuffer(buffer)
        }

        try engine.start()
        isRecording = true
    }

    /// Stop capturing and return accumulated samples for transcription.
    func stopCapture() -> (samples: [Float], stats: AudioStats) {
        guard isRecording else {
            return ([], AudioStats(duration: 0, sampleCount: 0, sampleRate: 0))
        }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false

        let duration = startTime.map { Date().timeIntervalSince($0) } ?? 0
        let stats = AudioStats(duration: duration, sampleCount: accumulatedSamples.count, sampleRate: sampleRate)

        return (accumulatedSamples, stats)
    }

    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }

        let frameCount = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))

        // Accumulate for final transcription
        accumulatedSamples.append(contentsOf: samples)

        // Stream chunk to consumer
        let chunk = AudioChunk(samples: samples, sampleRate: sampleRate)
        Task { @MainActor in
            self.onChunk?(chunk)
        }
    }
}

enum AudioCaptureError: LocalizedError {
    case invalidFormat

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "Microphone not available"
        }
    }
}
#endif
