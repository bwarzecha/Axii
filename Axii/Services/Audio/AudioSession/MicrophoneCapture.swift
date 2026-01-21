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
        if let device = device {
            guard let specificDevice = findAVCaptureDevice(uid: device.uid) else {
                throw AudioSessionError.deviceUnavailable
            }
            audioDevice = specificDevice
            currentDevice = device
        } else {
            guard let defaultDevice = AVCaptureDevice.default(for: .audio) else {
                throw AudioSessionError.deviceUnavailable
            }
            audioDevice = defaultDevice
            // Get device info for the default
            currentDevice = DeviceMonitor.systemDefaultDevice()
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

        // Add audio output
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: captureQueue)

        guard session.canAddOutput(output) else {
            throw AudioSessionError.configurationFailed("Cannot add audio output to session")
        }
        session.addOutput(output)

        session.commitConfiguration()

        captureSession = session
        audioOutput = output
        isCapturing = true
        lastSignalState = .silence

        // Start on capture queue to avoid blocking
        captureQueue.async {
            session.startRunning()
        }

        // Setup interruption observers
        setupInterruptionObservers()
    }

    /// Stop capturing.
    func stop() {
        guard isCapturing, let session = captureSession else { return }

        removeInterruptionObservers()

        captureQueue.sync {
            session.stopRunning()
        }

        captureSession = nil
        audioOutput = nil
        isCapturing = false
        currentDevice = nil
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
        onError?(.captureFailure(underlying: "Audio session was interrupted"))
    }
}

// MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

extension MicrophoneCapture: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Get format description for sample rate
        if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) {
            let rate = asbd.pointee.mSampleRate
            if rate > 0 {
                sampleRate = rate
            }
        }

        // Extract audio samples
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?

        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        )

        guard status == kCMBlockBufferNoErr, let data = dataPointer else { return }

        // Convert to float samples (assuming 32-bit float PCM)
        let floatCount = length / MemoryLayout<Float>.size
        let floatPointer = UnsafeRawPointer(data).bindMemory(to: Float.self, capacity: floatCount)
        let samples = Array(UnsafeBufferPointer(start: floatPointer, count: floatCount))

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
