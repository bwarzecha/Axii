//
//  TranscriptionService.swift
//  dictaitor
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
    private let audioConverter = AudioConverter()
    private(set) var modelState: ModelState = .notLoaded

    var isReady: Bool {
        modelState == .ready
    }

    /// Prepare the transcription service by downloading and loading models.
    /// Call this on app launch - models are cached after first download.
    func prepare() async throws {
        guard modelState != .ready && modelState != .loading else { return }

        modelState = .loading

        do {
            // Download and load models (FluidAudio handles caching)
            // Note: No progress callback available - download happens internally
            let models = try await AsrModels.downloadAndLoad(version: .v3)

            // Initialize the ASR manager
            let manager = AsrManager(config: .default)
            try await manager.initialize(models: models)

            self.asrManager = manager
            modelState = .ready
        } catch {
            modelState = .failed(message: error.localizedDescription)
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

        // Resample to 16kHz (FluidAudio requirement)
        let resampled = try audioConverter.resample(samples, from: sampleRate)

        // Minimum ~0.5s of audio at 16kHz
        guard resampled.count > 8000 else {
            throw TranscriptionError.tooShort
        }

        let result = try await manager.transcribe(resampled, source: .microphone)
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
