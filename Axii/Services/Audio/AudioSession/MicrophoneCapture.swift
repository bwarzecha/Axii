//
//  MicrophoneCapture.swift
//  Axii
//
//  AVCaptureSession wrapper for microphone capture.
//  Streams chunks and detects signal state for Bluetooth warm-up.
//

#if os(macOS)
import AVFoundation
import CoreMedia
import Foundation

/// Internal component for microphone capture via AVCaptureSession.
/// Emits audio chunks and signal state changes via callbacks.
final class MicrophoneCapture: NSObject, @unchecked Sendable {
    private var captureSession: AVCaptureSession?
    private var audioOutput: AVCaptureAudioDataOutput?
    private let captureQueue = DispatchQueue(label: "audio.capture", qos: .userInteractive)
    /// Serial queue for startRunning/stopRunning. Must be separate from
    /// captureQueue: stopRunning blocks until teardown completes and can wait
    /// on pending sample-buffer delivery, so running it on the delegate queue
    /// (or synchronously from the main thread) can deadlock the app.
    private let sessionQueue = DispatchQueue(label: "audio.capture.session", qos: .userInteractive)

    // Confined to captureQueue: written only via captureQueue.async from
    // start()/stop(), read only inside captureOutput (which runs on
    // captureQueue). Never touch these from the caller thread directly —
    // stop() returns while delegate callbacks may still be executing.
    private var currentDevice: AudioDevice?
    private var sampleRate: Double = 48000
    private var lastSignalState: SignalState = .silence
    private let noiseFloor: Float = 0.0001  // -80dB

    private(set) var isCapturing = false

    /// Called with each audio chunk during capture.
    var onChunk: ((AudioSessionChunk) -> Void)?

    /// Called when signal state changes (silence ↔ signal).
    var onSignalStateChange: ((SignalState) -> Void)?

    /// Called when an error occurs during capture.
    var onError: ((AudioSessionError) -> Void)?

    // MARK: - Public API

    /// Start capturing from the specified device or system default.
    /// - Parameter device: Specific device to capture from, or nil for system default.
    func start(device: AudioDevice?) throws {
        guard !isCapturing else { return }

        let session = AVCaptureSession()
        session.beginConfiguration()

        // Get audio device
        let audioDevice: AVCaptureDevice
        let resolvedDevice: AudioDevice?
        if let device = device {
            guard let specificDevice = findAVCaptureDevice(uid: device.uid) else {
                throw AudioSessionError.deviceUnavailable
            }
            audioDevice = specificDevice
            resolvedDevice = device
        } else {
            guard let defaultDevice = AVCaptureDevice.default(for: .audio) else {
                throw AudioSessionError.deviceUnavailable
            }
            audioDevice = defaultDevice
            // Get device info for the default
            resolvedDevice = DeviceMonitor.systemDefaultDevice()
        }

        // Add audio input
        let audioInput: AVCaptureDeviceInput
        do {
            audioInput = try AVCaptureDeviceInput(device: audioDevice)
        } catch {
            throw AudioSessionError.configurationFailed("Failed to create audio input: \(error.localizedDescription)")
        }

        guard session.canAddInput(audioInput) else {
            throw AudioSessionError.configurationFailed("Cannot add audio input to session")
        }
        session.addInput(audioInput)

        // Add audio output. The delivery format is PINNED to float32 LPCM:
        // unpinned, AVFoundation delivers whatever the environment
        // negotiates (observed: an integer PCM variant under the XCUITest
        // runner), and a format the extraction misreads turns every
        // recording into constant-power noise. Deterministic delivery
        // beats trusting per-buffer descriptors alone.
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        output.setSampleBufferDelegate(self, queue: captureQueue)

        guard session.canAddOutput(output) else {
            throw AudioSessionError.configurationFailed("Cannot add audio output to session")
        }
        session.addOutput(output)

        session.commitConfiguration()

        captureSession = session
        audioOutput = output
        isCapturing = true

        // Seed delegate state on captureQueue before any callback can run:
        // callbacks are enqueued FIFO behind this block, and none exist until
        // startRunning below completes.
        captureQueue.async { [self] in
            currentDevice = resolvedDevice
            lastSignalState = .silence
            sampleRate = 48000
        }

        // Start on session queue to avoid blocking
        sessionQueue.async {
            session.startRunning()
        }

        // Setup interruption observers
        setupInterruptionObservers()
    }

    /// Stop capturing.
    func stop() {
        guard isCapturing, let session = captureSession else { return }

        removeInterruptionObservers()

        captureSession = nil
        audioOutput = nil
        isCapturing = false

        // Clear delegate state on its own queue: callbacks already enqueued
        // ahead of this block still deliver (legitimate pre-stop audio, same
        // as the old synchronous teardown); anything after it is dropped by
        // captureOutput's currentDevice guard — no cross-thread access.
        captureQueue.async { [self] in
            currentDevice = nil
        }

        // Tear down asynchronously; the caller (main actor) must not wait.
        // stopRunning blocks until teardown completes, so it must run neither
        // on the caller thread nor on the delegate queue (deadlock risk).
        // The session is retained by the closure until teardown completes.
        sessionQueue.async {
            session.stopRunning()
        }
    }

    // MARK: - Device Lookup

    private func findAVCaptureDevice(uid: String) -> AVCaptureDevice? {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )

        return discoverySession.devices.first { $0.uniqueID == uid }
    }

    // MARK: - Interruption Handling

    private func setupInterruptionObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVCaptureSession.wasInterruptedNotification,
            object: captureSession
        )

        // Note: AVAudioSession.mediaServicesWereResetNotification is iOS-only
        // On macOS, we rely on AVCaptureSession interruption notifications
    }

    private func removeInterruptionObservers() {
        NotificationCenter.default.removeObserver(
            self,
            name: AVCaptureSession.wasInterruptedNotification,
            object: nil
        )
    }

    @objc private func handleInterruption(_ notification: Notification) {
        // AVCaptureSession interruption handling
        // Note: On macOS, interruption reasons may differ from iOS
        // Deliver on main like the chunk path — the notification can arrive
        // on the posting thread, and consumers mutate main-actor state.
        DispatchQueue.main.async { [weak self] in
            self?.onError?(.captureFailure(underlying: "Audio session was interrupted"))
        }
    }
}

// MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

extension MicrophoneCapture: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Honor the delivered format: stereo/planar/int inputs (BlackHole,
        // USB audio interfaces) corrupt when read as raw mono float32.
        guard let extracted = AudioSampleExtraction.monoFloatSamples(
            from: sampleBuffer
        ) else { return }
        if extracted.sampleRate > 0 {
            sampleRate = extracted.sampleRate
        }
        let samples = extracted.samples

        // Detect signal state
        let maxAmplitude = samples.lazy.map { abs($0) }.max() ?? 0
        let currentSignalState: SignalState = maxAmplitude > noiseFloor ? .signal : .silence

        if currentSignalState != lastSignalState {
            lastSignalState = currentSignalState
            DispatchQueue.main.async { [weak self] in
                self?.onSignalStateChange?(currentSignalState)
            }
        }

        // Create chunk with source attribution
        guard let device = currentDevice else { return }

        let chunk = AudioSessionChunk(
            samples: samples,
            sampleRate: sampleRate,
            timestamp: mach_absolute_time(),
            source: .microphone(device: device)
        )

        // Emit chunk
        DispatchQueue.main.async { [weak self] in
            self?.onChunk?(chunk)
        }
    }
}
#endif
