//
//  MediaControlService.swift
//  Axii
//
//  Controls media playback during dictation.
//  Uses media-control CLI which bypasses macOS 15.4+ MediaRemote restrictions.
//
//  Install: brew tap ungive/media-control && brew install media-control
//

#if os(macOS)
import Foundation

/// Service for pausing/resuming media playback during dictation.
/// Uses the media-control CLI tool which works on macOS 15.4+.
@MainActor
final class MediaControlService {
    private var wasPlayingBeforePause = false
    private var mediaControlPath: String?

    /// Possible locations for media-control binary
    private static let possiblePaths = [
        "/opt/homebrew/bin/media-control",  // Apple Silicon
        "/usr/local/bin/media-control"       // Intel
    ]

    /// Find and cache the media-control path
    private func findMediaControlPath() -> String? {
        if let cached = mediaControlPath {
            return cached
        }

        for path in Self.possiblePaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                mediaControlPath = path
                print("MediaControlService: Found media-control at \(path)")
                return path
            }
        }

        print("MediaControlService: media-control not found. Install with: brew tap ungive/media-control && brew install media-control")
        return nil
    }

    /// Check if media-control CLI is installed
    /// Set forceRecheck to true to clear cache and recheck (e.g., after user installs)
    func checkAvailability(forceRecheck: Bool = false) -> Bool {
        if forceRecheck {
            mediaControlPath = nil
        }
        return findMediaControlPath() != nil
    }

    /// Check if media is currently playing
    func isPlaying() async -> Bool {
        guard let path = findMediaControlPath() else { return false }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let output = self.runMediaControl(path: path, arguments: ["get"])
                let isPlaying = self.parsePlaybackState(from: output)
                continuation.resume(returning: isPlaying)
            }
        }
    }

    /// Pause media if something is playing, remembering the state for later resume
    func pauseIfPlaying() async {
        guard let path = findMediaControlPath() else { return }

        let playing = await isPlaying()
        wasPlayingBeforePause = playing

        if playing {
            await sendCommand(.pause, path: path)
            print("MediaControlService: Paused media playback")
        }
    }

    /// Resume media if something was playing before we paused
    func resumeIfWasPlaying() async {
        guard wasPlayingBeforePause else { return }
        wasPlayingBeforePause = false

        guard let path = findMediaControlPath() else { return }

        // Only resume if still paused (user didn't manually resume)
        let currentlyPlaying = await isPlaying()
        if !currentlyPlaying {
            await sendCommand(.play, path: path)
            print("MediaControlService: Resumed media playback")
        }
    }

    /// Reset the pause state without resuming (e.g., on cancel)
    func resetState() {
        wasPlayingBeforePause = false
    }

    // MARK: - Private

    private enum Command: String {
        case play = "play"
        case pause = "pause"
    }

    private func sendCommand(_ cmd: Command, path: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                _ = self.runMediaControl(path: path, arguments: [cmd.rawValue])
                continuation.resume()
            }
        }
    }

    nonisolated private func parsePlaybackState(from json: String) -> Bool {
        guard let data = json.data(using: .utf8) else { return false }

        do {
            if let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // Check playbackRate (1 = playing, 0 = paused)
                if let rate = dict["playbackRate"] as? Double, rate > 0 {
                    return true
                }
                // Fallback to playing boolean
                if let playing = dict["playing"] as? Bool {
                    return playing
                }
            }
        } catch {
            // JSON parse failed - no media playing
        }

        return false
    }

    nonisolated private func runMediaControl(path: String, arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            print("MediaControlService: Failed to run \(path): \(error)")
            return ""
        }
    }
}
#endif
