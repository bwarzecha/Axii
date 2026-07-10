//
//  RecordingSessionHelper.swift
//  Axii
//
//  Helper that encapsulates AudioSession lifecycle, sample accumulation,
//  and visualization updates. Used by ModeFeature (and legacy feature classes).
//

#if os(macOS)
import Accelerate

/// Visualization data emitted during recording.
struct VisualizationUpdate {
    let audioLevel: Float
    let spectrum: [Float]
}

/// Capture boundary for the mode runtime. RecordingSessionHelper is the
/// production conformer; the interaction fuzzer substitutes a gate-controlled
/// fake so schedules can be explored without hardware.
@MainActor
protocol RecordingSessionProviding: AnyObject {
    var currentDevice: AudioDevice? { get }
    var onVisualizationUpdate: ((VisualizationUpdate) -> Void)? { get set }
    var onSignalStateChanged: ((Bool) -> Void)? { get set }
    var onError: ((AudioSessionError) -> Void)? { get set }
    var onDeviceChanged: ((AudioDevice) -> Void)? { get set }
    func start(source: AudioSource) async throws
    func stop() -> (samples: [Float], sampleRate: Double)
    func cancel()
}

/// Helper for managing audio recording sessions with sample accumulation.
/// Encapsulates AudioSession lifecycle and provides callbacks for UI updates.
@MainActor
final class RecordingSessionHelper: RecordingSessionProviding {
    // Accumulated audio data
    private(set) var samples: [Float] = []
    private(set) var sampleRate: Double = 48000

    // Current device (for Bluetooth detection)
    private(set) var currentDevice: AudioDevice?

    // Callbacks
    var onVisualizationUpdate: ((VisualizationUpdate) -> Void)?
    var onSignalStateChanged: ((Bool) -> Void)?  // isWaitingForSignal (initial warmup)
    var onError: ((AudioSessionError) -> Void)?
    /// Fired when capture silently moves to a different device (unplug →
    /// fallback). The UI must show the mic that is actually recording, not
    /// the one the user picked and lost.
    var onDeviceChanged: ((AudioDevice) -> Void)?

    // Internal state
    private var audioSession: AudioSession?
    private var chunkTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var warmupTimeoutTask: Task<Void, Never>?
    private var warmupWasStarted = false       // True once warmup phase began
    private var initialWarmupComplete = false  // Track if initial Bluetooth warmup finished
    // Bumped by start/stop. session.start can suspend for seconds (permission
    // prompt, device spin-up) and a stop() issued during that suspension is a
    // no-op on the not-yet-running AVCaptureSession — the resumed start must
    // detect it was superseded and stop the session it just brought up, or a
    // microphone runs with no owner.
    private var startEpoch = 0

    // Timeout for Bluetooth warmup (seconds)
    private let warmupTimeout: TimeInterval = 20.0

    /// Start recording from the specified source.
    func start(source: AudioSource) async throws {
        startEpoch += 1
        let epoch = startEpoch
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

        // stop()/cancel() arrived while the start was suspended (permission
        // prompt, device spin-up): their session.stop() no-ops on a session
        // that is not running yet, so the teardown must happen HERE, where
        // the session is fully started and stop() works.
        guard startEpoch == epoch else {
            session.stop()
            throw CancellationError()
        }

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
        startEpoch += 1
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
        // One buffer, one rate: after a device fallback the incoming rate
        // can change mid-recording — normalize the chunk instead of
        // mislabeling everything recorded so far (garbled transcription).
        if samples.isEmpty {
            sampleRate = chunk.sampleRate
        }
        if chunk.sampleRate == sampleRate {
            samples.append(contentsOf: chunk.samples)
        } else {
            samples.append(contentsOf: AudioResampler.resample(
                chunk.samples, from: chunk.sampleRate, to: sampleRate
            ))
        }

        // Calculate visualization
        let rms = Self.calculateRMS(chunk.samples)
        let normalized = min(sqrt(rms) * 3.0, 1.0)
        let spectrum = SpectrumAnalyzer.calculateSpectrum(chunk.samples)

        onVisualizationUpdate?(VisualizationUpdate(
            audioLevel: normalized,
            spectrum: spectrum
        ))
    }

    // Internal (not private) so tests can inject device events — the
    // AudioSession that produces them needs real hardware.
    func handleEvent(_ event: AudioEvent) {
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
            onDeviceChanged?(newDevice)
            if newDevice.isBluetooth {
                // Re-arm the warmup state machine: without this, the
                // waiting flag can stick forever after a wired->BT fallback
                // (no .signal clear, no timeout armed).
                warmupWasStarted = true
                initialWarmupComplete = false
                onSignalStateChanged?(true)
                startWarmupTimeout()
            } else {
                // Falling back to a wired mic mid-warmup must not fire the
                // "Bluetooth failed to start" abort.
                cancelWarmupTimeout()
                onSignalStateChanged?(false)
            }

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
