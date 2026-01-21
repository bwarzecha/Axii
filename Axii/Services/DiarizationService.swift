//
//  DiarizationService.swift
//  Axii
//
//  FluidAudio wrapper for speaker diarization.
//  Uses offline diarization for accurate speaker separation.
//

import FluidAudio
import Foundation

/// Actor-based diarization service using FluidAudio's OfflineDiarizerManager.
actor DiarizationService {
    private var offlineDiarizer: OfflineDiarizerManager?
    private(set) var modelState: ModelState = .notLoaded

    var isReady: Bool {
        modelState == .ready
    }

    /// Prepare the diarization service by loading models.
    /// - Parameter modelsDirectory: Optional directory containing pre-downloaded models.
    ///   If nil, uses FluidAudio's default download behavior.
    func prepare(modelsDirectory: URL? = nil) async throws {
        guard modelState != .ready && modelState != .loading else { return }

        modelState = .loading

        do {
            // Configure for video call audio which has compression artifacts
            // - Lower threshold = more strict matching = more speakers
            // - Force minimum 2 speakers since we know there are remote participants
            // - Export embeddings for debugging
            let exportPath = FileManager.default.temporaryDirectory
                .appendingPathComponent("diarization_embeddings.json").path

            let config = OfflineDiarizerConfig(
                clusteringThreshold: 0.4,  // More aggressive separation
                embeddingExportPath: exportPath
            ).withSpeakers(min: 2)  // Force at least 2 speakers

            let diarizer = OfflineDiarizerManager(config: config)

            // Load from custom directory or use default
            let modelPath = modelsDirectory?.appendingPathComponent("speaker-diarization-coreml")
            try await diarizer.prepareModels(directory: modelPath)

            self.offlineDiarizer = diarizer
            modelState = .ready
            print("DiarizationService: Offline diarizer ready (threshold=0.4, minSpeakers=2)")
            print("DiarizationService: Embeddings will be exported to: \(exportPath)")
        } catch {
            modelState = .failed(message: error.localizedDescription)
            throw error
        }
    }

    /// Perform offline speaker diarization on complete audio.
    /// - Parameters:
    ///   - samples: Float32 audio samples at 16kHz
    /// - Returns: Array of speaker segments with timestamps and speaker IDs
    func diarizeOffline(samples: [Float]) async throws -> [TimedSpeakerSegment] {
        guard let diarizer = offlineDiarizer else {
            throw DiarizationError.notReady
        }

        guard samples.count > 16000 else {
            throw DiarizationError.tooShort
        }

        let durationSeconds = Float(samples.count) / 16000.0

        // Audio stats for debugging
        let maxAmp = samples.map { abs($0) }.max() ?? 0
        let rms = sqrt(samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count))
        print("DiarizationService: Starting offline diarization of \(String(format: "%.1f", durationSeconds))s audio...")
        print("DiarizationService: Audio stats - samples: \(samples.count), maxAmp: \(String(format: "%.4f", maxAmp)), rms: \(String(format: "%.4f", rms))")

        let result = try await diarizer.process(audio: samples)

        let uniqueSpeakers = Set(result.segments.map { $0.speakerId })
        print("DiarizationService: Found \(result.segments.count) segments, \(uniqueSpeakers.count) unique speakers")

        for segment in result.segments {
            let duration = segment.endTimeSeconds - segment.startTimeSeconds
            print("  - Speaker \(segment.speakerId): \(String(format: "%.1f", segment.startTimeSeconds))s - \(String(format: "%.1f", segment.endTimeSeconds))s (\(String(format: "%.1f", duration))s)")
        }

        return result.segments
    }
}

enum DiarizationError: LocalizedError {
    case notReady
    case tooShort

    var errorDescription: String? {
        switch self {
        case .notReady:
            return "Diarization model not loaded"
        case .tooShort:
            return "Audio too short for diarization"
        }
    }
}
