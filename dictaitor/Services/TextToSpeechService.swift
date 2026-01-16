//
//  TextToSpeechService.swift
//  dictaitor
//
//  FluidAudio wrapper for TTS model lifecycle and synthesis.
//

#if os(macOS)
import FluidAudio
import FluidAudioTTS
import Foundation

/// Actor-based text-to-speech service wrapping FluidAudio TTS.
actor TextToSpeechService {
    private var ttsManager: TtSManager?
    private(set) var modelState: ModelState = .notLoaded

    var isReady: Bool {
        modelState == .ready
    }

    /// Prepare the TTS service by downloading and loading models.
    /// Call this on app launch - models are cached after first download.
    func prepare() async throws {
        guard modelState != .ready && modelState != .loading else { return }

        modelState = .loading

        do {
            let manager = TtSManager()
            try await manager.initialize()
            self.ttsManager = manager
            modelState = .ready
        } catch {
            modelState = .failed(message: error.localizedDescription)
            throw error
        }
    }

    /// Synthesize text to WAV audio data.
    /// - Parameters:
    ///   - text: Text to synthesize
    ///   - voice: Optional voice identifier (defaults to recommended voice)
    ///   - speed: Speech speed multiplier (default 1.0)
    /// - Returns: WAV audio data
    func synthesize(
        text: String,
        voice: String? = nil,
        speed: Float = 1.0
    ) async throws -> Data {
        guard let manager = ttsManager else {
            throw TTSServiceError.notReady
        }
        return try await manager.synthesize(
            text: text,
            voice: voice,
            voiceSpeed: speed
        )
    }

    /// Cleanup TTS resources.
    func cleanup() {
        ttsManager?.cleanup()
        ttsManager = nil
        modelState = .notLoaded
    }
}

enum TTSServiceError: LocalizedError {
    case notReady

    var errorDescription: String? {
        switch self {
        case .notReady:
            return "TTS model not loaded"
        }
    }
}
#endif
