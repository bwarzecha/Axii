//
//  TranscriptionService.swift
//  Axii
//
//  FluidAudio wrapper for model lifecycle and transcription.
//

import FluidAudio
import Foundation

/// Model readiness state.
enum ModelState: Equatable {
    case notLoaded
    case loading
    case ready
    case failed(message: String)

    static func == (lhs: ModelState, rhs: ModelState) -> Bool {
        switch (lhs, rhs) {
        case (.notLoaded, .notLoaded), (.loading, .loading), (.ready, .ready):
            return true
        case (.failed(let a), .failed(let b)):
            return a == b
        default:
            return false
        }
    }
}

/// Actor-based transcription service wrapping FluidAudio.
actor TranscriptionService {
    private var asrManager: AsrManager?
    private var decoderLayerCount: Int?
    private let audioConverter = AudioConverter()
    private(set) var modelState: ModelState = .notLoaded

    var isReady: Bool {
        if case .ready = modelState { return true }
        return false
    }

    /// Prepare the transcription service by loading models.
    /// - Parameter modelsDirectory: Optional directory containing pre-downloaded models.
    ///   If nil, uses FluidAudio's default download behavior.
    func prepare(modelsDirectory: URL? = nil) async throws {
        switch modelState {
        case .ready, .loading:
            return
        case .notLoaded, .failed:
            break
        }

        modelState = .loading

        do {
            let models: AsrModels
            if let directory = modelsDirectory {
                // Load from pre-downloaded models directory
                let modelPath = directory.appendingPathComponent("parakeet-tdt-0.6b-v3-coreml")
                models = try await AsrModels.load(from: modelPath, version: .v3)
            } else {
                // Fall back to FluidAudio's download + load
                models = try await AsrModels.downloadAndLoad(version: .v3)
            }

            // Initialize the ASR manager
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)

            self.asrManager = manager
            self.decoderLayerCount = await manager.decoderLayerCount
            modelState = .ready
        } catch {
            modelState = .failed(message: error.localizedDescription)
            decoderLayerCount = nil
            throw error
        }
    }

    /// Transcribe audio samples to text.
    /// - Parameters:
    ///   - samples: Float32 audio samples
    ///   - sampleRate: Sample rate of the input audio
    /// - Returns: Transcribed text
    func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
        guard let manager = asrManager, let decoderLayerCount else {
            throw TranscriptionError.notReady
        }

        // Resample to 16kHz (FluidAudio requirement)
        let resampled = try audioConverter.resample(samples, from: sampleRate)

        // Minimum ~0.5s of audio at 16kHz
        guard resampled.count > 8000 else {
            throw TranscriptionError.tooShort
        }

        // Fresh decoder state per call. The actor is reentrant at the await
        // below, so a shared state would be mutated by interleaved calls
        // (TdtDecoderState copies share their MLMultiArray buffers — that is
        // a use-after-free, not just an accuracy bug). Per-call state also
        // keeps independent streams (dictation, meeting mic, meeting system)
        // from polluting each other's decoder context.
        var decoderState = try TdtDecoderState(decoderLayers: decoderLayerCount)
        let result = try await manager.transcribe(resampled, decoderState: &decoderState)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum TranscriptionError: LocalizedError {
    case notReady
    case tooShort

    var errorDescription: String? {
        switch self {
        case .notReady:
            return "Transcription model not loaded"
        case .tooShort:
            return "Recording too short"
        }
    }
}
