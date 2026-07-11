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

    // Original sample rates (captured from incoming chunks, 0 = not yet received)
    private(set) var micOriginalSampleRate: Double = 0
    private(set) var systemOriginalSampleRate: Double = 0

    // Transcription buffers (16kHz resampled, for real-time transcription)
    private var transcriptionMicBuffer: [Float] = []
    private var transcriptionSystemBuffer: [Float] = []

    // File streaming for reliability (stores ORIGINAL quality samples)
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

        // Reset transcription buffers
        transcriptionMicBuffer = []
        transcriptionSystemBuffer = []

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
        do {
            try await session.start(config: SessionConfig(
                source: .combined(microphone: micSource, apps: appSelection),
                onDeviceDisconnect: .fallbackToDefault
            ))
        } catch {
            // The stream tasks await continuations that never finish when
            // start throws (AudioSession.stop no-ops before isRunning), so
            // they must be cancelled here or they leak for the app lifetime.
            chunkTask?.cancel()
            eventTask?.cancel()
            chunkTask = nil
            eventTask = nil
            audioSession = nil
            try? micFileHandle?.close()
            try? systemFileHandle?.close()
            micFileHandle = nil
            systemFileHandle = nil
            throw error
        }

        isRecording = true
    }

    /// Stop recording and return file paths with their original sample rates.
    /// Also returns the paths when not actively recording: after a failed
    /// switchApp restart leg the capture is dead but the temp files still
    /// hold the entire recording — returning nil here would persist an
    /// empty meeting and let the commit delete the recovery data.
    func stop() -> (micFile: URL?, micRate: Double, systemFile: URL?, systemRate: Double) {
        guard isRecording else {
            return (micFilePath, micOriginalSampleRate, systemFilePath, systemOriginalSampleRate)
        }

        // Cancel tasks
        chunkTask?.cancel()
        eventTask?.cancel()
        chunkTask = nil
        eventTask = nil

        // Stop session
        audioSession?.stop()
        audioSession = nil

        // Clear transcription buffers (original samples already written to files)
        transcriptionMicBuffer = []
        transcriptionSystemBuffer = []

        // Close file handles
        try? micFileHandle?.close()
        try? systemFileHandle?.close()
        micFileHandle = nil
        systemFileHandle = nil

        isRecording = false

        return (micFilePath, micOriginalSampleRate, systemFilePath, systemOriginalSampleRate)
    }

    /// Switch the app being captured (brief gap acceptable).
    func switchApp(to app: AudioApp?, micSource: AudioSource.MicrophoneSource) async throws {
        guard isRecording else { return }

        // Preserve file state before stopping
        let micPath = micFilePath
        let sysPath = systemFilePath
        let currentMicCount = micSampleCount
        let currentSysCount = systemSampleCount
        let currentMicRate = micOriginalSampleRate
        let currentSysRate = systemOriginalSampleRate

        // Stop current session (preserves files)
        _ = stop()

        // Restore file state
        micFilePath = micPath
        systemFilePath = sysPath
        micSampleCount = currentMicCount
        systemSampleCount = currentSysCount
        micOriginalSampleRate = currentMicRate
        systemOriginalSampleRate = currentSysRate

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

        do {
            try await session.start(config: SessionConfig(
                source: .combined(microphone: micSource, apps: appSelection),
                onDeviceDisconnect: .fallbackToDefault
            ))
        } catch {
            chunkTask?.cancel()
            eventTask?.cancel()
            chunkTask = nil
            eventTask = nil
            audioSession = nil
            try? micFileHandle?.close()
            try? systemFileHandle?.close()
            micFileHandle = nil
            systemFileHandle = nil
            onError?("Failed to switch audio source: \(error.localizedDescription)")
            throw error
        }

        isRecording = true
    }

    /// In-progress recordings live in Application Support (not the system
    /// temp directory) so a crashed session's audio survives for recovery.
    /// Files are deleted at the persistence commit point, on discard, or by
    /// the expiry sweep at launch.
    static var recordingSpoolDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("Axii/InProgressRecordings")
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        return dir
    }

    /// Remove spool files whose last write is older than the recovery
    /// window. Run at launch, before any capture starts, so it can never
    /// touch a live recording.
    static func cleanExpiredSpoolFiles(
        olderThan age: TimeInterval = MeetingRecoveryPolicy.artifactLifetime
    ) {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: recordingSpoolDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for file in files {
            let modified = (try? file.resourceValues(
                forKeys: [.contentModificationDateKey]
            ))?.contentModificationDate
            if let modified, Date().timeIntervalSince(modified) > age {
                try? fileManager.removeItem(at: file)
            }
        }
    }

    var audioFileReferences: MeetingAudioFileReferences? {
        guard micFilePath != nil || systemFilePath != nil else { return nil }
        return MeetingAudioFileReferences(
            micFileURL: micFilePath,
            micSampleRate: micOriginalSampleRate,
            systemFileURL: systemFilePath,
            systemSampleRate: systemOriginalSampleRate
        )
    }

    /// Read all samples from a file (for final transcription).
    func readSamplesFromFile(_ url: URL?) -> [Float] {
        Self.readRawSamples(from: url)
    }

    /// Raw float32 spool-file reader — also used by crash recovery, which
    /// has no live manager instance.
    static func readRawSamples(from url: URL?) -> [Float] {
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
        let spoolDir = Self.recordingSpoolDirectory
        // UUID, not a timestamp: a stop-and-restart within the same second
        // must never produce colliding paths, or the finishing session reads
        // and deletes the new session's live files.
        let sessionToken = UUID().uuidString

        micFilePath = spoolDir.appendingPathComponent("meeting_mic_\(sessionToken).raw")
        systemFilePath = spoolDir.appendingPathComponent("meeting_system_\(sessionToken).raw")
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
        // Capture original sample rate from first chunk of each source
        switch chunk.source {
        case .microphone:
            if micOriginalSampleRate == 0 {
                micOriginalSampleRate = chunk.sampleRate
            }
        case .systemAudio:
            if systemOriginalSampleRate == 0 {
                systemOriginalSampleRate = chunk.sampleRate
            }
        }

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
            print("MeetingAudioManager[\(sourceStr)]: rate=\(chunk.sampleRate), samples=\(chunk.samples.count), duration=\(String(format: "%.3f", chunkDuration))s")
        }
        #endif

        // Calculate audio level for visualization
        let rms = calculateRMS(chunk.samples)
        let normalized = min(sqrt(rms) * 3.0, 1.0)
        onAudioLevel?(normalized)

        // 1. Write ORIGINAL samples to temp file (for history playback)
        // 2. Resample to 16kHz for transcription buffer
        let resampled = resampleTo16kHz(chunk.samples, fromRate: chunk.sampleRate)

        switch chunk.source {
        case .microphone:
            // Write original quality to file
            writeSamplesToFile(chunk.samples, handle: micFileHandle)
            micSampleCount += chunk.samples.count
            // Accumulate resampled for transcription
            transcriptionMicBuffer.append(contentsOf: resampled)
            processTranscriptionMicBuffer()

        case .systemAudio:
            // Write original quality to file
            writeSamplesToFile(chunk.samples, handle: systemFileHandle)
            systemSampleCount += chunk.samples.count
            // Accumulate resampled for transcription
            transcriptionSystemBuffer.append(contentsOf: resampled)
            processTranscriptionSystemBuffer()
        }
    }

    /// Process transcription mic buffer - emits 16kHz chunks for real-time transcription.
    private func processTranscriptionMicBuffer() {
        guard transcriptionMicBuffer.count >= chunkSampleCount else { return }

        let chunk = Array(transcriptionMicBuffer.prefix(chunkSampleCount))
        transcriptionMicBuffer = Array(transcriptionMicBuffer.dropFirst(chunkSampleCount))

        // Emit for real-time transcription (skip silence)
        if !isSilent(chunk) {
            onTranscriptionChunk?(TranscriptionChunk(
                samples: chunk,
                source: .microphone,
                timestamp: Date()
            ))
        }
    }

    /// Process transcription system buffer - emits 16kHz chunks for real-time transcription.
    private func processTranscriptionSystemBuffer() {
        guard transcriptionSystemBuffer.count >= chunkSampleCount else { return }

        let chunk = Array(transcriptionSystemBuffer.prefix(chunkSampleCount))
        transcriptionSystemBuffer = Array(transcriptionSystemBuffer.dropFirst(chunkSampleCount))

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
