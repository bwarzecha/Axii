//
//  AudioSessionTypes.swift
//  dictaitor
//
//  Core types for the AudioSession abstraction.
//  See docs/design/audio-session-abstraction-v2.md for design details.
//

#if os(macOS)
import CoreAudio
import Foundation

// MARK: - AudioDevice

/// Represents an audio input device with transport type information.
struct AudioDevice: Sendable, Equatable, Identifiable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transportType: TransportType

    enum TransportType: Sendable {
        case builtIn        // kAudioDeviceTransportTypeBuiltIn
        case usb            // kAudioDeviceTransportTypeUSB
        case bluetooth      // kAudioDeviceTransportTypeBluetooth
        case bluetoothLE    // kAudioDeviceTransportTypeBluetoothLE
        case aggregate      // kAudioDeviceTransportTypeAggregate
        case virtual        // kAudioDeviceTransportTypeVirtual
        case unknown
    }

    var isBluetooth: Bool {
        transportType == .bluetooth || transportType == .bluetoothLE
    }
}

// MARK: - AudioSessionChunk

/// Audio chunk delivered via AsyncStream.
/// Includes source attribution for diarization support.
struct AudioSessionChunk: Sendable {
    let samples: [Float]
    let sampleRate: Double
    let timestamp: UInt64  // mach_absolute_time() for precise timing
    let source: ChunkSource

    /// Duration of this chunk in seconds.
    var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return TimeInterval(samples.count) / sampleRate
    }

    enum ChunkSource: Sendable {
        /// Audio from microphone input
        case microphone(device: AudioDevice)

        /// Audio from system (all apps combined)
        /// Consumer can buffer this separately from mic for diarization
        case systemAudio
    }
}

// MARK: - AudioEvent

/// Events emitted by AudioSession for state changes.
enum AudioEvent: Sendable {
    /// Signal state changed - silence (no signal above noise floor) or signal detected.
    /// UI can show "Waiting for signal..." when silence, switch to recording when signal.
    case signalState(SignalState)

    /// Device was disconnected.
    /// In combined mode: session continues with system audio only.
    case deviceDisconnected(AudioDevice)

    /// Session switched to different device (after fallback).
    case deviceChanged(to: AudioDevice)

    /// Session was interrupted by system.
    case interrupted(reason: InterruptionReason)

    /// Fatal error, session stopping.
    /// Only emitted for truly unrecoverable errors (e.g., all sources failed).
    case error(AudioSessionError)
}

/// Signal detection state for Bluetooth warm-up handling.
enum SignalState: Sendable, Equatable {
    /// All samples at or below noise floor.
    /// We don't know WHY - could be Bluetooth negotiating, noise cancellation, or quiet room.
    case silence

    /// Non-zero samples detected.
    case signal
}

/// Reasons for audio session interruption.
enum InterruptionReason: Sendable {
    /// Another app took exclusive access to audio device.
    case audioDeviceInUseByAnotherClient

    /// Media services were reset (rare but must handle).
    case mediaServicesReset

    /// Unknown interruption.
    case unknown
}

/// Errors that can occur during audio session lifecycle.
enum AudioSessionError: Error, Sendable {
    case permissionDenied
    case deviceUnavailable
    case configurationFailed(String)
    case captureFailure(underlying: String)
}

// MARK: - SessionConfig

/// Configuration for starting an AudioSession.
struct SessionConfig: Sendable {
    let source: AudioSource
    let onDeviceDisconnect: DisconnectBehavior

    init(source: AudioSource, onDeviceDisconnect: DisconnectBehavior = .fallbackToDefault) {
        self.source = source
        self.onDeviceDisconnect = onDeviceDisconnect
    }
}

/// Audio source specification.
enum AudioSource: Sendable {
    /// Follow system default microphone.
    case systemDefault

    /// Specific microphone device by UID.
    case microphone(AudioDevice)

    // Future: case systemAudio(apps: AppSelection)
    // Future: case combined(microphone: MicrophoneSource, apps: AppSelection)
}

/// Behavior when selected device disconnects.
enum DisconnectBehavior: Sendable {
    /// Stop session, emit error event.
    case stop

    /// Fallback to system default, emit deviceChanged event, continue.
    case fallbackToDefault
}

// MARK: - PermissionStatus

/// Permission status for audio capture.
enum PermissionStatus: Sendable {
    case authorized
    case denied
    case notDetermined  // Will prompt when session starts
}
#endif
