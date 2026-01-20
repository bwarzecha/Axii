//
//  AudioSession.swift
//  dictaitor
//
//  MainActor-isolated audio capture abstraction.
//  Single-use: create a new instance for each recording session.
//  See docs/design/audio-session-abstraction-v2.md for design details.
//

#if os(macOS)
import AVFoundation
import Foundation

/// MainActor-isolated audio session for microphone capture.
/// Single-use: create a new instance for each recording.
///
/// Usage:
/// ```swift
/// let session = AudioSession()
///
/// // Listen for chunks
/// Task {
///     for await chunk in session.chunks {
///         accumulator.append(contentsOf: chunk.samples)
///     }
/// }
///
/// // Listen for events
/// Task {
///     for await event in session.events {
///         switch event {
///         case .signalState(let state): ...
///         case .error(let error): ...
///         }
///     }
/// }
///
/// // Start capture
/// try await session.start(config: SessionConfig(source: .systemDefault))
///
/// // Stop when done
/// session.stop()
/// ```
@MainActor
final class AudioSession {
    // MARK: - Public Streams

    /// Stream of audio chunks - consumer decides accumulation.
    /// All chunks are emitted, including silent ones.
    let chunks: AsyncStream<AudioSessionChunk>

    /// Stream of state change events.
    let events: AsyncStream<AudioEvent>

    // MARK: - Private State

    private let chunkContinuation: AsyncStream<AudioSessionChunk>.Continuation
    private let eventContinuation: AsyncStream<AudioEvent>.Continuation

    private var capture: MicrophoneCapture?
    private var deviceMonitor: DeviceMonitor?
    private var config: SessionConfig?
    private var currentDevice: AudioDevice?
    private(set) var isRunning = false

    // MARK: - Initialization

    init() {
        var chunkCont: AsyncStream<AudioSessionChunk>.Continuation!
        var eventCont: AsyncStream<AudioEvent>.Continuation!

        chunks = AsyncStream(bufferingPolicy: .bufferingOldest(100)) { continuation in
            chunkCont = continuation
        }

        events = AsyncStream(bufferingPolicy: .bufferingOldest(50)) { continuation in
            eventCont = continuation
        }

        chunkContinuation = chunkCont
        eventContinuation = eventCont
    }

    // MARK: - Lifecycle

    /// Start capturing from specified source.
    /// - Parameter config: Session configuration including source and disconnect behavior.
    /// - Throws: AudioSessionError if permission denied, device unavailable, or configuration fails.
    func start(config: SessionConfig) async throws {
        guard !isRunning else { return }

        self.config = config

        // Check permission first
        let status = Self.microphonePermissionStatus()
        switch status {
        case .denied:
            throw AudioSessionError.permissionDenied
        case .notDetermined:
            // Request permission
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                throw AudioSessionError.permissionDenied
            }
        case .authorized:
            break
        }

        // Determine target device
        let targetDevice: AudioDevice?
        switch config.source {
        case .systemDefault:
            targetDevice = nil  // MicrophoneCapture will use system default
        case .microphone(let device):
            targetDevice = device
        }

        // Setup device monitor
        let monitor = DeviceMonitor()
        monitor.onDeviceDisconnected = { [weak self] device in
            self?.handleDeviceDisconnected(device)
        }
        if let device = targetDevice {
            monitor.monitorDevice(device)
        }
        deviceMonitor = monitor

        // Setup capture
        let mic = MicrophoneCapture()
        mic.onChunk = { [weak self] chunk in
            self?.handleChunk(chunk)
        }
        mic.onSignalStateChange = { [weak self] state in
            self?.handleSignalStateChange(state)
        }
        mic.onError = { [weak self] error in
            self?.handleError(error)
        }
        capture = mic

        // Start capture
        do {
            try mic.start(device: targetDevice)
            currentDevice = targetDevice ?? DeviceMonitor.systemDefaultDevice()
            isRunning = true
        } catch let error as AudioSessionError {
            throw error
        } catch {
            throw AudioSessionError.captureFailure(underlying: error.localizedDescription)
        }
    }

    /// Stop capturing, streams finish.
    func stop() {
        guard isRunning else { return }

        capture?.stop()
        capture = nil
        deviceMonitor = nil
        isRunning = false

        chunkContinuation.finish()
        eventContinuation.finish()
    }

    // MARK: - Event Handlers

    private func handleChunk(_ chunk: AudioSessionChunk) {
        chunkContinuation.yield(chunk)
    }

    private func handleSignalStateChange(_ state: SignalState) {
        eventContinuation.yield(.signalState(state))
    }

    private func handleError(_ error: AudioSessionError) {
        eventContinuation.yield(.error(error))
        stop()
    }

    private func handleDeviceDisconnected(_ device: AudioDevice) {
        guard isRunning else { return }

        eventContinuation.yield(.deviceDisconnected(device))

        guard let config = config else { return }

        switch config.onDeviceDisconnect {
        case .stop:
            eventContinuation.yield(.error(.deviceUnavailable))
            stop()

        case .fallbackToDefault:
            // Try to switch to system default
            guard let defaultDevice = DeviceMonitor.systemDefaultDevice() else {
                eventContinuation.yield(.error(.deviceUnavailable))
                stop()
                return
            }

            // Stop current capture
            capture?.stop()

            // Start new capture with default device
            let newCapture = MicrophoneCapture()
            newCapture.onChunk = { [weak self] chunk in
                self?.handleChunk(chunk)
            }
            newCapture.onSignalStateChange = { [weak self] state in
                self?.handleSignalStateChange(state)
            }
            newCapture.onError = { [weak self] error in
                self?.handleError(error)
            }

            do {
                try newCapture.start(device: nil)
                capture = newCapture
                currentDevice = defaultDevice
                deviceMonitor?.monitorDevice(nil)
                eventContinuation.yield(.deviceChanged(to: defaultDevice))
            } catch {
                eventContinuation.yield(.error(.deviceUnavailable))
                stop()
            }
        }
    }

    // MARK: - Static API

    /// List available microphone devices.
    nonisolated static func availableMicrophones() -> [AudioDevice] {
        DeviceMonitor.availableMicrophones()
    }

    /// Check microphone permission status without prompting or starting a session.
    nonisolated static func microphonePermissionStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .authorized
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .notDetermined
        }
    }

    /// Get the current system default microphone.
    nonisolated static func systemDefaultDevice() -> AudioDevice? {
        DeviceMonitor.systemDefaultDevice()
    }
}
#endif
