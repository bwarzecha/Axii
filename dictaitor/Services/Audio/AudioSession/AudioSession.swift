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
import CoreGraphics
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
    private var systemCapture: SystemAudioCapture?
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

        switch config.source {
        case .systemDefault, .microphone:
            try await startMicrophoneOnly(config: config)

        case .systemAudio(let apps):
            try await startSystemAudioOnly(apps: apps)

        case .combined(let micSource, let apps):
            try await startCombined(micSource: micSource, apps: apps, config: config)
        }

        isRunning = true
    }

    // MARK: - Source-Specific Start Methods

    private func startMicrophoneOnly(config: SessionConfig) async throws {
        // Check microphone permission
        let status = Self.microphonePermissionStatus()
        switch status {
        case .denied:
            throw AudioSessionError.permissionDenied
        case .notDetermined:
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
            targetDevice = nil
        case .microphone(let device):
            targetDevice = device
        default:
            targetDevice = nil
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

        // Setup and start microphone capture
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

        do {
            try mic.start(device: targetDevice)
            currentDevice = targetDevice ?? DeviceMonitor.systemDefaultDevice()
        } catch let error as AudioSessionError {
            throw error
        } catch {
            throw AudioSessionError.captureFailure(underlying: error.localizedDescription)
        }
    }

    private func startSystemAudioOnly(apps: AppSelection) async throws {
        // Check screen recording permission
        guard CGPreflightScreenCaptureAccess() else {
            throw AudioSessionError.configurationFailed("Screen recording permission required")
        }

        // Setup and start system audio capture
        let sys = SystemAudioCapture()
        sys.onChunk = { [weak self] chunk in
            self?.handleChunk(chunk)
        }
        sys.onError = { [weak self] error in
            self?.handleError(error)
        }
        systemCapture = sys

        try await sys.start(apps: apps, includeMicrophone: false)
    }

    private func startCombined(micSource: AudioSource.MicrophoneSource, apps: AppSelection, config: SessionConfig) async throws {
        // Check both permissions
        let micStatus = Self.microphonePermissionStatus()
        switch micStatus {
        case .denied:
            throw AudioSessionError.permissionDenied
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                throw AudioSessionError.permissionDenied
            }
        case .authorized:
            break
        }

        guard CGPreflightScreenCaptureAccess() else {
            throw AudioSessionError.configurationFailed("Screen recording permission required")
        }

        // Determine mic device
        let micDevice: AudioDevice?
        switch micSource {
        case .systemDefault:
            micDevice = nil
        case .specific(let device):
            micDevice = device
        }

        // Setup device monitor for mic
        let monitor = DeviceMonitor()
        monitor.onDeviceDisconnected = { [weak self] device in
            self?.handleDeviceDisconnected(device)
        }
        if let device = micDevice {
            monitor.monitorDevice(device)
        }
        deviceMonitor = monitor
        currentDevice = micDevice ?? DeviceMonitor.systemDefaultDevice()

        // Use SystemAudioCapture with combined mode (macOS 14.4+)
        let sys = SystemAudioCapture()
        sys.onChunk = { [weak self] chunk in
            self?.handleChunk(chunk)
        }
        sys.onError = { [weak self] error in
            self?.handleError(error)
        }
        systemCapture = sys

        try await sys.start(apps: apps, includeMicrophone: true, micDevice: micDevice)
    }

    /// Stop capturing, streams finish.
    func stop() {
        guard isRunning else { return }

        capture?.stop()
        capture = nil
        systemCapture?.stop()
        systemCapture = nil
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
