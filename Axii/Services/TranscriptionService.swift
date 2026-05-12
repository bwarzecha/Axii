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
    private var decoderState: TdtDecoderState?
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
            let decoderLayerCount = await manager.decoderLayerCount

            self.asrManager = manager
            self.decoderState = try TdtDecoderState(decoderLayers: decoderLayerCount)
            modelState = .ready
        } catch {
            modelState = .failed(message: error.localizedDescription)
            decoderState = nil
            throw error
        }
    }

    /// Transcribe audio samples to text.
    /// - Parameters:
    ///   - samples: Float32 audio samples
    ///   - sampleRate: Sample rate of the input audio
    /// - Returns: Transcribed text
    func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
        guard let manager = asrManager else {
            throw TranscriptionError.notReady
        }
        guard var decoderState else {
            throw TranscriptionError.notReady
        }

        // Resample to 16kHz (FluidAudio requirement)
        let resampled = try audioConverter.resample(samples, from: sampleRate)

        // Minimum ~0.5s of audio at 16kHz
        guard resampled.count > 8000 else {
            throw TranscriptionError.tooShort
        }

        let result = try await manager.transcribe(resampled, decoderState: &decoderState)
        self.decoderState = decoderState
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
