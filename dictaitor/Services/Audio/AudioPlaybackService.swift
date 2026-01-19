//
//  AudioPlaybackService.swift
//  dictaitor
//
//  Audio playback service for WAV data.
//

#if os(macOS)
import AVFoundation
import Foundation

/// Service for playing audio data (WAV format).
@MainActor
final class AudioPlaybackService: NSObject {
    private var player: AVAudioPlayer?
    private var completionHandler: (() -> Void)?

    private(set) var isPlaying = false

    /// Play WAV audio data.
    /// - Parameters:
    ///   - wavData: WAV format audio data
    ///   - onComplete: Called when playback finishes (not called if stopped early)
    func play(wavData: Data, onComplete: (() -> Void)? = nil) throws {
        stop()

        player = try AVAudioPlayer(data: wavData)
        player?.delegate = self
        completionHandler = onComplete

        // Preload buffers to reduce latency at start
        player?.prepareToPlay()

        guard player?.play() == true else {
            throw PlaybackError.playbackFailed
        }
        isPlaying = true
    }

    /// Stop current playback.
    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        completionHandler = nil
    }
}

// MARK: - AVAudioPlayerDelegate

extension AudioPlaybackService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            let handler = self.completionHandler
            self.completionHandler = nil
            handler?()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            self.isPlaying = false
            self.completionHandler = nil
        }
    }
}

enum PlaybackError: LocalizedError {
    case playbackFailed

    var errorDescription: String? {
        switch self {
        case .playbackFailed:
            return "Failed to start audio playback"
        }
    }
}
#endif
