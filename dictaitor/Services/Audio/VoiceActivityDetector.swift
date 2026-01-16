//
//  VoiceActivityDetector.swift
//  dictaitor
//
//  Energy-based voice activity detection for auto-stop on silence.
//

import Accelerate

/// Detects speech start/end based on audio energy levels.
struct VoiceActivityDetector {
    struct Configuration {
        let activationThreshold: Float
        let deactivationThreshold: Float
        let minimumSpeechDuration: TimeInterval
        let trailingSilenceDuration: TimeInterval

        static let `default` = Configuration(
            activationThreshold: 0.015,
            deactivationThreshold: 0.010,
            minimumSpeechDuration: 0.18,
            trailingSilenceDuration: 0.85
        )
    }

    struct Result {
        let rms: Float
        let isSpeech: Bool
        let didStartSpeech: Bool
        let didEndSpeech: Bool
    }

    private let config: Configuration

    private var isSpeechActive = false
    private var speechDuration: TimeInterval = 0
    private var silenceDuration: TimeInterval = 0

    init(configuration: Configuration = .default) {
        self.config = configuration
    }

    mutating func reset() {
        isSpeechActive = false
        speechDuration = 0
        silenceDuration = 0
    }

    mutating func process(chunk: AudioChunk) -> Result {
        let rms = calculateRMS(samples: chunk.samples)
        let duration = chunk.duration

        var didStart = false
        var didEnd = false

        if isSpeechActive {
            speechDuration += duration
            if rms < config.deactivationThreshold {
                silenceDuration += duration
                if silenceDuration >= config.trailingSilenceDuration {
                    isSpeechActive = false
                    didEnd = true
                    speechDuration = 0
                    silenceDuration = 0
                }
            } else {
                silenceDuration = 0
            }
        } else {
            if rms >= config.activationThreshold {
                speechDuration += duration
                silenceDuration = 0
                if speechDuration >= config.minimumSpeechDuration {
                    isSpeechActive = true
                    didStart = true
                    silenceDuration = 0
                }
            } else {
                speechDuration = 0
                silenceDuration += duration
            }
        }

        return Result(rms: rms, isSpeech: isSpeechActive, didStartSpeech: didStart, didEndSpeech: didEnd)
    }

    private func calculateRMS(samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var total: Float = 0
        vDSP_svesq(samples, 1, &total, vDSP_Length(samples.count))
        let meanSquare = total / Float(samples.count)
        return sqrtf(meanSquare)
    }
}
