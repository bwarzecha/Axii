//
//  RecordingSessionHelper.swift
//  Axii
//
//  Helper that encapsulates AudioSession lifecycle, sample accumulation,
//  and visualization updates. Used by DictationFeature and ConversationFeature.
//

#if os(macOS)
import Accelerate

/// Visualization data emitted during recording.
struct VisualizationUpdate {
    let audioLevel: Float
    let spectrum: [Float]
}

/// Helper for managing audio recording sessions with sample accumulation.
/// Encapsulates AudioSession lifecycle and provides callbacks for UI updates.
@MainActor
final class RecordingSessionHelper {
    // Accumulated audio data
    private(set) var samples: [Float] = []
    private(set) var sampleRate: Double = 48000

    // Current device (for Bluetooth detection)
    private(set) var currentDevice: AudioDevice?

    // Callbacks
    var onVisualizationUpdate: ((VisualizationUpdate) -> Void)?
    var onSignalStateChanged: ((Bool) -> Void)?  // isWaitingForSignal (initial warmup)
    var onError: ((AudioSessionError) -> Void)?

    // Internal state
    private var audioSession: AudioSession?
    private var chunkTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var warmupTimeoutTask: Task<Void, Never>?
    private var warmupWasStarted = false       // True once warmup phase began
    private var initialWarmupComplete = false  // Track if initial Bluetooth warmup finished

    // Timeout for Bluetooth warmup (seconds)
    private let warmupTimeout: TimeInterval = 20.0

    /// Start recording from the specified source.
    func start(source: AudioSource) async throws {
        // Reset state
        samples = []
        warmupWasStarted = false
        initialWarmupComplete = false

        // Resolve current device (RecordingSessionHelper only supports microphone sources)
        switch source {
        case .microphone(let device):
            currentDevice = device
        case .systemDefault:
            currentDevice = AudioSession.systemDefaultDevice()
        case .systemAudio, .combined:
            // RecordingSessionHelper is designed for mic-only use (Dictation, Conversation)
            // For combined capture, use AudioSession directly
            fatalError("RecordingSessionHelper does not support system audio sources")
        }

        // Create new audio session
        let session = AudioSession()
        audioSession = session

        // Start chunk iteration task
        chunkTask = Task { [weak self] in
            for await chunk in session.chunks {
                self?.handleChunk(chunk)
            }
        }

        // Start event iteration task
        eventTask = Task { [weak self] in
            for await event in session.events {
                self?.handleEvent(event)
            }
        }

        // Start capture
        try await session.start(config: SessionConfig(
            source: source,
            onDeviceDisconnect: .fallbackToDefault
        ))

        // If Bluetooth, start in waiting-for-signal state with timeout
        if currentDevice?.isBluetooth == true {
            warmupWasStarted = true
            onSignalStateChanged?(true)
            startWarmupTimeout()
        }
    }

    /// Start timeout for Bluetooth warmup - fires error if signal not received in time.
    private func startWarmupTimeout() {
        warmupTimeoutTask?.cancel()
        warmupTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.warmupTimeout ?? 5.0))
            guard !Task.isCancelled else { return }
            // Still waiting for signal after timeout
            self?.onError?(.captureFailure(underlying: "Bluetooth microphone failed to start. Try again or switch to a different mic."))
        }
    }

    /// Cancel warmup timeout (called when signal is received).
    private func cancelWarmupTimeout() {
        warmupTimeoutTask?.cancel()
        warmupTimeoutTask = nil
    }

    /// Stop recording and return accumulated samples.
    func stop() -> (samples: [Float], sampleRate: Double) {
        chunkTask?.cancel()
        eventTask?.cancel()
        warmupTimeoutTask?.cancel()
        chunkTask = nil
        eventTask = nil
        warmupTimeoutTask = nil
        audioSession?.stop()
        audioSession = nil

        let result = (samples: samples, sampleRate: sampleRate)
        samples = []
        return result
    }

    /// Cancel without returning samples.
    func cancel() {
        _ = stop()
    }

    // MARK: - Private

    private func handleChunk(_ chunk: AudioSessionChunk) {
        // Accumulate samples
        samples.append(contentsOf: chunk.samples)
        sampleRate = chunk.sampleRate

        // Calculate visualization
        let rms = Self.calculateRMS(chunk.samples)
        let normalized = min(sqrt(rms) * 3.0, 1.0)
        let spectrum = SpectrumAnalyzer.calculateSpectrum(chunk.samples)

        onVisualizationUpdate?(VisualizationUpdate(
            audioLevel: normalized,
            spectrum: spectrum
        ))
    }

    private func handleEvent(_ event: AudioEvent) {
        switch event {
        case .signalState(let signalState):
            // Only process signal events for Bluetooth devices after warmup has been initiated
            guard currentDevice?.isBluetooth == true, warmupWasStarted else { return }

            if signalState == .signal {
                cancelWarmupTimeout()
                onSignalStateChanged?(false)
                initialWarmupComplete = true
            } else if !initialWarmupComplete {
                // Still in warmup phase
                onSignalStateChanged?(true)
                startWarmupTimeout()
            }
            // After warmup complete, silence is normal - no action needed

        case .deviceDisconnected(let device):
            print("RecordingSessionHelper: Device disconnected: \(device.name)")

        case .deviceChanged(let newDevice):
            currentDevice = newDevice
            onSignalStateChanged?(newDevice.isBluetooth)

        case .interrupted:
            onError?(.captureFailure(underlying: "Audio interrupted"))

        case .error(let error):
            onError?(error)
        }
    }

    private static func calculateRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        return rms
    }
}
#endif
