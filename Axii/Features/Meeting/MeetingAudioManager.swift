//
//  MeetingAudioManager.swift
//  Axii
//
//  Manages audio capture for meeting transcription.
//  Handles combined mic + system audio, file streaming, and source switching.
//

#if os(macOS)
import Accelerate
import Foundation

/// Audio chunk ready for transcription (resampled to 16kHz).
struct TranscriptionChunk: Sendable {
    let samples: [Float]
    let source: ChunkSource
    let timestamp: Date

    enum ChunkSource: Sendable {
        case microphone
        case systemAudio
    }
}

/// Manages audio capture for meeting transcription.
/// Streams audio to disk for reliability, provides chunks for real-time transcription.
@MainActor
final class MeetingAudioManager {
    // MARK: - Configuration

    private static let targetSampleRate: Double = 16000
    private static let chunkDurationSeconds: Double = 15.0
    private var chunkSampleCount: Int {
        Int(Self.targetSampleRate * Self.chunkDurationSeconds)
    }

    // MARK: - State

    private var audioSession: AudioSession?
    private var chunkTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?

    private(set) var isRecording = false
    private var sessionSampleRate: Double = 48000

    // Audio buffers (accumulate until chunk size)
    private var micBuffer: [Float] = []
    private var systemBuffer: [Float] = []

    // File streaming for reliability
    private var micFileHandle: FileHandle?
    private var systemFileHandle: FileHandle?
    private(set) var micFilePath: URL?
    private(set) var systemFilePath: URL?
    private var micSampleCount: Int = 0
    private var systemSampleCount: Int = 0

    // MARK: - Callbacks

    var onAudioLevel: ((Float) -> Void)?
    var onTranscriptionChunk: ((TranscriptionChunk) -> Void)?
    var onError: ((String) -> Void)?

    // MARK: - Lifecycle

    /// Start recording from mic and system audio.
    func start(
        micSource: AudioSource.MicrophoneSource,
        appSelection: AppSelection
    ) async throws {
        guard !isRecording else { return }

        // Reset buffers
        micBuffer = []
        systemBuffer = []

        // Setup temp files for streaming
        setupTempAudioFiles()

        // Create and configure session
        let session = AudioSession()
        audioSession = session

        // Process chunks
        chunkTask = Task { [weak self] in
            for await chunk in session.chunks {
                await self?.handleChunk(chunk)
            }
        }

        // Process events
        eventTask = Task { [weak self] in
            for await event in session.events {
                await self?.handleEvent(event)
            }
        }

        // Start combined capture
        try await session.start(config: SessionConfig(
            source: .combined(microphone: micSource, apps: appSelection),
            onDeviceDisconnect: .fallbackToDefault
        ))

        isRecording = true
    }

    /// Stop recording and return file paths.
    func stop() -> (micFile: URL?, systemFile: URL?) {
        guard isRecording else { return (nil, nil) }

        // Cancel tasks
        chunkTask?.cancel()
        eventTask?.cancel()
        chunkTask = nil
        eventTask = nil

        // Stop session
        audioSession?.stop()
        audioSession = nil

        // Flush remaining buffers
        if !micBuffer.isEmpty {
            writeSamplesToFile(micBuffer, handle: micFileHandle)
            micSampleCount += micBuffer.count
        }
        if !systemBuffer.isEmpty {
            writeSamplesToFile(systemBuffer, handle: systemFileHandle)
            systemSampleCount += systemBuffer.count
        }
        micBuffer = []
        systemBuffer = []

        // Close file handles
        try? micFileHandle?.close()
        try? systemFileHandle?.close()
        micFileHandle = nil
        systemFileHandle = nil

        isRecording = false

        return (micFilePath, systemFilePath)
    }

    /// Switch the app being captured (brief gap acceptable).
    func switchApp(to app: AudioApp?, micSource: AudioSource.MicrophoneSource) async throws {
        guard isRecording else { return }

        let micPath = micFilePath
        let sysPath = systemFilePath
        let currentMicCount = micSampleCount
        let currentSysCount = systemSampleCount

        // Stop current session (preserves files)
        _ = stop()

        // Restore file state
        micFilePath = micPath
        systemFilePath = sysPath
        micSampleCount = currentMicCount
        systemSampleCount = currentSysCount

        // Reopen file handles for appending
        if let path = micFilePath {
            micFileHandle = try? FileHandle(forWritingTo: path)
            micFileHandle?.seekToEndOfFile()
        }
        if let path = systemFilePath {
            systemFileHandle = try? FileHandle(forWritingTo: path)
            systemFileHandle?.seekToEndOfFile()
        }

        // Build app selection
        let appSelection: AppSelection
        if let app = app {
            appSelection = .only([app])
        } else {
            appSelection = .all
        }

        // Restart with new app selection
        let session = AudioSession()
        audioSession = session

        chunkTask = Task { [weak self] in
            for await chunk in session.chunks {
                await self?.handleChunk(chunk)
            }
        }

        eventTask = Task { [weak self] in
            for await event in session.events {
                await self?.handleEvent(event)
            }
        }

        try await session.start(config: SessionConfig(
            source: .combined(microphone: micSource, apps: appSelection),
            onDeviceDisconnect: .fallbackToDefault
        ))

        isRecording = true
    }

    /// Read all samples from a file (for final transcription).
    func readSamplesFromFile(_ url: URL?) -> [Float] {
        guard let url = url else { return [] }

        do {
            let data = try Data(contentsOf: url)
            let count = data.count / MemoryLayout<Float>.size
            var samples = [Float](repeating: 0, count: count)
            _ = samples.withUnsafeMutableBufferPointer { buffer in
                data.copyBytes(to: buffer)
            }
            return samples
        } catch {
            print("MeetingAudioManager: Failed to read samples: \(error)")
            return []
        }
    }

    /// Clean up temp files.
    func cleanupTempFiles() {
        try? micFileHandle?.close()
        try? systemFileHandle?.close()
        micFileHandle = nil
        systemFileHandle = nil

        if let path = micFilePath {
            try? FileManager.default.removeItem(at: path)
        }
        if let path = systemFilePath {
            try? FileManager.default.removeItem(at: path)
        }
        micFilePath = nil
        systemFilePath = nil
        micSampleCount = 0
        systemSampleCount = 0
    }

    /// Get list of apps that can be captured.
    static func audioProducingApps() async -> [AudioApp] {
        await SystemAudioCapture.audioProducingApps()
    }

    /// Get available microphones.
    static func availableMicrophones() -> [AudioDevice] {
        AudioSession.availableMicrophones()
    }

    // MARK: - Private Methods

    private func setupTempAudioFiles() {
        let tempDir = FileManager.default.temporaryDirectory
        let timestamp = Int(Date().timeIntervalSince1970)

        micFilePath = tempDir.appendingPathComponent("meeting_mic_\(timestamp).raw")
        systemFilePath = tempDir.appendingPathComponent("meeting_system_\(timestamp).raw")
        micSampleCount = 0
        systemSampleCount = 0

        FileManager.default.createFile(atPath: micFilePath!.path, contents: nil)
        FileManager.default.createFile(atPath: systemFilePath!.path, contents: nil)

        do {
            micFileHandle = try FileHandle(forWritingTo: micFilePath!)
            systemFileHandle = try FileHandle(forWritingTo: systemFilePath!)
        } catch {
            print("MeetingAudioManager: Failed to create temp files: \(error)")
        }
    }

    private func handleChunk(_ chunk: AudioSessionChunk) {
        sessionSampleRate = chunk.sampleRate

        // Log for debugging sample rate issues (once per source to reduce spam)
        #if DEBUG
        let sourceStr: String
        switch chunk.source {
        case .microphone: sourceStr = "MIC"
        case .systemAudio: sourceStr = "SYS"
        }
        struct ChunkLogState { static var micLogged = false; static var sysLogged = false }
        let shouldLog: Bool
        switch chunk.source {
        case .microphone: shouldLog = !ChunkLogState.micLogged; ChunkLogState.micLogged = true
        case .systemAudio: shouldLog = !ChunkLogState.sysLogged; ChunkLogState.sysLogged = true
        }
        if shouldLog {
            let chunkDuration = Double(chunk.samples.count) / chunk.sampleRate
            let expectedResampledCount = Int(Double(chunk.samples.count) * (Self.targetSampleRate / chunk.sampleRate))
            print("MeetingAudioManager[\(sourceStr)]: rate=\(chunk.sampleRate), samples=\(chunk.samples.count), duration=\(String(format: "%.3f", chunkDuration))s, expectedResampled=\(expectedResampledCount)")
        }
        #endif

        // Calculate audio level for visualization
        let rms = calculateRMS(chunk.samples)
        let normalized = min(sqrt(rms) * 3.0, 1.0)
        onAudioLevel?(normalized)

        // Resample to 16kHz for transcription
        let resampled = resampleTo16kHz(chunk.samples, fromRate: chunk.sampleRate)

        #if DEBUG
        if resampled.count != Int(Double(chunk.samples.count) * (Self.targetSampleRate / chunk.sampleRate)) {
            print("MeetingAudioManager[\(sourceStr)]: WARNING resampled count mismatch! got=\(resampled.count), expected=\(Int(Double(chunk.samples.count) * (Self.targetSampleRate / chunk.sampleRate)))")
        }
        #endif

        // Route to appropriate buffer
        switch chunk.source {
        case .microphone:
            micBuffer.append(contentsOf: resampled)
            processMicBuffer()

        case .systemAudio:
            systemBuffer.append(contentsOf: resampled)
            processSystemBuffer()
        }
    }

    private func processMicBuffer() {
        guard micBuffer.count >= chunkSampleCount else { return }

        let chunk = Array(micBuffer.prefix(chunkSampleCount))
        micBuffer = Array(micBuffer.dropFirst(chunkSampleCount))

        // Write to file
        writeSamplesToFile(chunk, handle: micFileHandle)
        micSampleCount += chunk.count

        // Emit for real-time transcription (skip silence)
        if !isSilent(chunk) {
            onTranscriptionChunk?(TranscriptionChunk(
                samples: chunk,
                source: .microphone,
                timestamp: Date()
            ))
        }
    }

    private func processSystemBuffer() {
        guard systemBuffer.count >= chunkSampleCount else { return }

        let chunk = Array(systemBuffer.prefix(chunkSampleCount))
        systemBuffer = Array(systemBuffer.dropFirst(chunkSampleCount))

        // Write to file
        writeSamplesToFile(chunk, handle: systemFileHandle)
        systemSampleCount += chunk.count

        // Emit for real-time transcription (skip silence)
        if !isSilent(chunk) {
            onTranscriptionChunk?(TranscriptionChunk(
                samples: chunk,
                source: .systemAudio,
                timestamp: Date()
            ))
        }
    }

    private func writeSamplesToFile(_ samples: [Float], handle: FileHandle?) {
        guard let handle = handle else { return }
        samples.withUnsafeBufferPointer { buffer in
            let data = Data(buffer: buffer)
            do {
                try handle.write(contentsOf: data)
            } catch {
                print("MeetingAudioManager: Failed to write samples: \(error)")
            }
        }
    }

    private func handleEvent(_ event: AudioEvent) {
        switch event {
        case .error(let error):
            onError?(error.localizedDescription)
        case .deviceDisconnected(let device):
            print("MeetingAudioManager: Device disconnected: \(device.name)")
        case .deviceChanged(let device):
            print("MeetingAudioManager: Device changed to: \(device.name)")
        case .interrupted(let reason):
            onError?("Audio interrupted: \(reason)")
        case .signalState:
            break
        }
    }

    private func resampleTo16kHz(_ samples: [Float], fromRate: Double) -> [Float] {
        let targetRate = Self.targetSampleRate
        guard fromRate != targetRate else { return samples }
        guard samples.count > 1 else { return samples }

        let ratio = targetRate / fromRate
        let outputCount = Int(Double(samples.count) * ratio)
        guard outputCount > 0 else { return [] }

        // Use vDSP for high-quality vectorized linear interpolation
        var output = [Float](repeating: 0, count: outputCount)

        // Generate interpolation indices
        var indices = [Float](repeating: 0, count: outputCount)
        var index: Float = 0
        var increment = Float(fromRate / targetRate)
        vDSP_vramp(&index, &increment, &indices, 1, vDSP_Length(outputCount))

        // Clamp indices to valid range
        var maxIndex = Float(samples.count - 1)
        vDSP_vclip(indices, 1, &index, &maxIndex, &indices, 1, vDSP_Length(outputCount))

        // Perform vectorized linear interpolation
        vDSP_vlint(samples, indices, 1, &output, 1, vDSP_Length(outputCount), vDSP_Length(samples.count))

        return output
    }

    private func calculateRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        return rms
    }

    private func isSilent(_ samples: [Float]) -> Bool {
        let maxAmplitude = samples.map { abs($0) }.max() ?? 0.0
        return maxAmplitude < 0.001
    }
}
#endif
