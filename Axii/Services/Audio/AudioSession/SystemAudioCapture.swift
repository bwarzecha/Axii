//
//  SystemAudioCapture.swift
//  Axii
//
//  ScreenCaptureKit wrapper for capturing system audio (and optionally microphone).
//  Emits chunks via callbacks, parallel to MicrophoneCapture.
//
//  For combined mode (macOS 14.4+), uses SCStreamConfiguration.captureMicrophone
//  to capture both sources in a single synchronized stream.
//

#if os(macOS)
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Internal component for system audio capture via ScreenCaptureKit.
/// Emits audio chunks with source attribution.
final class SystemAudioCapture: NSObject, @unchecked Sendable {
    private var stream: SCStream?
    private let captureQueue = DispatchQueue(label: "audio.system.capture", qos: .userInteractive)

    private var appSelection: AppSelection = .all
    private var includeMicrophone: Bool = false
    private var micDevice: AudioDevice?

    private(set) var isCapturing = false

    /// Called with each audio chunk during capture.
    var onChunk: ((AudioSessionChunk) -> Void)?

    /// Called when an error occurs during capture.
    var onError: ((AudioSessionError) -> Void)?

    // MARK: - Public API

    /// Start capturing system audio.
    /// - Parameters:
    ///   - apps: Which apps to capture audio from.
    ///   - includeMicrophone: Whether to also capture microphone (combined mode, macOS 14.4+).
    ///   - micDevice: Specific microphone device for combined mode (nil = system default).
    func start(apps: AppSelection, includeMicrophone: Bool = false, micDevice: AudioDevice? = nil) async throws {
        guard !isCapturing else { return }

        self.appSelection = apps
        self.includeMicrophone = includeMicrophone
        self.micDevice = micDevice

        // Check screen recording permission
        guard CGPreflightScreenCaptureAccess() else {
            throw AudioSessionError.configurationFailed("Screen recording permission required")
        }

        // Get shareable content (includes minimized/hidden apps)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        // Build content filter based on app selection
        let filter = try buildContentFilter(from: content, apps: apps)

        // Configure stream
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48000
        config.channelCount = 2

        // Combined mode: capture microphone too (macOS 14.4+)
        if includeMicrophone {
            if #available(macOS 14.4, *) {
                config.captureMicrophone = true
                if let device = micDevice {
                    config.microphoneCaptureDeviceID = device.uid
                }
            } else {
                throw AudioSessionError.configurationFailed("Combined capture requires macOS 14.4+")
            }
        }

        // Minimal video settings (required by ScreenCaptureKit but not used)
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        // Create and configure stream
        let newStream = SCStream(filter: filter, configuration: config, delegate: self)

        // Store reference before adding outputs to ensure retention
        stream = newStream

        // Add audio output first (primary use case)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)

        // Add microphone output if in combined mode
        if includeMicrophone {
            if #available(macOS 14.4, *) {
                try newStream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: captureQueue)
            }
        }

        // Add screen output last (required by SCStream but we ignore it)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)

        // Start capture
        try await newStream.startCapture()

        isCapturing = true
    }

    /// Stop capturing.
    func stop() {
        guard isCapturing, let currentStream = stream else { return }

        Task {
            try? await currentStream.stopCapture()
        }

        stream = nil
        isCapturing = false
    }

    // MARK: - Content Filter Building

    private func buildContentFilter(from content: SCShareableContent, apps: AppSelection) throws -> SCContentFilter {
        guard let display = content.displays.first else {
            throw AudioSessionError.configurationFailed("No display available")
        }

        // Get our own app's bundle ID to always exclude ourselves
        let ownBundleID = Bundle.main.bundleIdentifier

        switch apps {
        case .all:
            // Exclude our own app to avoid feedback loops
            let excludedApps = content.applications.filter { app in
                app.bundleIdentifier == ownBundleID
            }
            return SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])

        case .only(let selectedApps):
            // Find matching SCRunningApplications (excluding ourselves)
            let scApps = selectedApps.compactMap { app in
                content.applications.first {
                    $0.processID == app.pid && $0.bundleIdentifier != ownBundleID
                }
            }
            guard !scApps.isEmpty else {
                throw AudioSessionError.configurationFailed("No matching applications found")
            }
            // Use including: to capture only specific apps (macOS 12.3+)
            return SCContentFilter(display: display, including: scApps, exceptingWindows: [])

        case .excluding(let excludedApps):
            var scAppsToExclude = excludedApps.compactMap { app in
                content.applications.first { $0.processID == app.pid }
            }
            // Also exclude ourselves
            if let ownApp = content.applications.first(where: { $0.bundleIdentifier == ownBundleID }) {
                scAppsToExclude.append(ownApp)
            }
            return SCContentFilter(display: display, excludingApplications: scAppsToExclude, exceptingWindows: [])
        }
    }
}

// MARK: - SCStreamDelegate

extension SystemAudioCapture: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.onError?(.captureFailure(underlying: error.localizedDescription))
            self?.isCapturing = false
            self?.stream = nil
        }
    }
}

// MARK: - SCStreamOutput

extension SystemAudioCapture: SCStreamOutput {
    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        // Only process audio types
        guard outputType == .audio || outputType == .microphone else { return }

        // Get format description
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return
        }

        let sampleRate = asbd.pointee.mSampleRate
        let channelCount = Int(asbd.pointee.mChannelsPerFrame)

        // Extract samples
        guard let samples = extractSamples(from: sampleBuffer, channelCount: channelCount) else {
            return
        }

        // Determine source
        let source: AudioSessionChunk.ChunkSource
        if outputType == .microphone {
            // Combined mode microphone audio
            let device = micDevice ?? DeviceMonitor.systemDefaultDevice()
            if let device = device {
                source = .microphone(device: device)
            } else {
                return // No device info available
            }
        } else {
            // System audio
            source = .systemAudio
        }

        let chunk = AudioSessionChunk(
            samples: samples,
            sampleRate: sampleRate,
            timestamp: mach_absolute_time(),
            source: source
        )

        DispatchQueue.main.async { [weak self] in
            self?.onChunk?(chunk)
        }
    }

    private func extractSamples(from sampleBuffer: CMSampleBuffer, channelCount: Int) -> [Float]? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?

        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        )

        guard status == kCMBlockBufferNoErr, let data = dataPointer else {
            return nil
        }

        // Convert to float samples (assuming 32-bit float PCM)
        let floatCount = length / MemoryLayout<Float>.size
        let floatPointer = UnsafeRawPointer(data).bindMemory(to: Float.self, capacity: floatCount)
        var samples = Array(UnsafeBufferPointer(start: floatPointer, count: floatCount))

        // Convert stereo to mono if needed
        if channelCount == 2 && samples.count >= 2 {
            var monoSamples = [Float](repeating: 0, count: samples.count / 2)
            for i in 0..<monoSamples.count {
                monoSamples[i] = (samples[i * 2] + samples[i * 2 + 1]) / 2.0
            }
            samples = monoSamples
        }

        return samples
    }
}

// MARK: - Static Helpers

extension SystemAudioCapture {
    /// List applications currently running (requires screen recording permission).
    static func audioProducingApps() async -> [AudioApp] {
        // Check permission first
        guard CGPreflightScreenCaptureAccess() else {
            print("SystemAudioCapture: Screen recording permission required to list apps")
            return []
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let apps = content.applications.map { app in
                AudioApp(
                    pid: app.processID,
                    bundleIdentifier: app.bundleIdentifier,
                    name: app.applicationName
                )
            }
            print("SystemAudioCapture: Found \(apps.count) apps")
            return apps
        } catch {
            print("SystemAudioCapture: Failed to get apps: \(error)")
            return []
        }
    }

    /// Check screen recording permission status.
    static func permissionStatus() -> PermissionStatus {
        if CGPreflightScreenCaptureAccess() {
            return .authorized
        }
        return .notDetermined
    }

    /// Request screen recording permission.
    static func requestPermission() {
        CGRequestScreenCaptureAccess()
    }
}
#endif
