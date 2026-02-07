//
//  ModeConfig.swift
//  Axii
//
//  Declarative configuration that drives a generic ModeFeature.
//  Each ModeConfig describes audio capture, transcription, processing,
//  output, lifecycle, and panel layout for one mode.
//

#if os(macOS)
import Foundation

// MARK: - Main Config

struct ModeConfig: Codable, Identifiable {
    let id: UUID
    var name: String
    var icon: String              // SF Symbol name
    var isBuiltIn: Bool
    var audioCapture: AudioCaptureConfig
    var transcription: TranscriptionConfig
    var processing: [ProcessingStep]
    var output: OutputConfig
    var lifecycle: LifecycleConfig
    var panel: PanelConfig
}

// MARK: - Audio Capture

enum AudioCaptureConfig: Codable {
    case simple(SimpleCaptureConfig)
    case dual(DualCaptureConfig)

    var isDual: Bool {
        if case .dual = self { return true }
        return false
    }
}

struct SimpleCaptureConfig: Codable {
    var devicePreference: DevicePreference = .systemDefault
}

struct DualCaptureConfig: Codable {
    var devicePreference: DevicePreference = .systemDefault
    var appSelection: AppSelectionConfig = .all
}

enum DevicePreference: String, Codable {
    case systemDefault
    case lastUsed
}

enum AppSelectionConfig: String, Codable {
    case all
    case userSelected
}

// MARK: - Transcription

enum TranscriptionConfig: Codable {
    case batch
    case streaming(StreamingConfig)
}

struct StreamingConfig: Codable {
    var chunkDurationSeconds: TimeInterval = 15.0
}

// MARK: - Processing

enum ProcessingStep: Codable {
    case diarize
    case llmTransform(LLMTransformConfig)
    case format(FormatConfig)
}

struct LLMTransformConfig: Codable {
    var systemPrompt: String = ""
    var multiTurn: Bool = false
}

struct FormatConfig: Codable {
    var template: String = ""
}

// MARK: - Output

struct OutputConfig: Codable {
    var pasteAtCursor: Bool = false
    var copyToClipboard: Bool = false
    var saveToHistory: Bool = true
    var historyType: HistoryType = .transcription
}

enum HistoryType: String, Codable {
    case transcription
    case conversation
    case meeting
}

// MARK: - Lifecycle

struct LifecycleConfig: Codable {
    var sessionType: SessionType
    var startMode: StartMode = .automatic
    var escapeAllowedDuringRecording: Bool = true
    var pauseMedia: Bool = false
    var captureFocus: Bool = false
    var autoDeactivateDelay: TimeInterval? = 2.0
    var permissions: [PermissionType] = [.microphone]
    var enableCrashRecovery: Bool = false
}

enum SessionType: String, Codable {
    case singleShot    // Dictation: one recording -> output -> done
    case multiTurn     // Conversation: loop until escape
    case longRunning   // Meeting: manual start/stop with streaming
}

enum StartMode: String, Codable {
    case automatic     // Hotkey immediately starts recording
    case manual        // Hotkey shows panel, user clicks Start
}

enum PermissionType: String, Codable {
    case microphone
    case screenRecording
}

// MARK: - Panel

struct PanelConfig: Codable {
    var layout: PanelLayoutType
    var preferences: PanelPreferences = PanelPreferences()
}

enum PanelLayoutType: String, Codable {
    case standard
    case conversation
}

struct PanelPreferences: Codable {
    var recordingIndicatorStyle: RecordingIndicatorStyle = .radialBar
    var transcriptDisplay: TranscriptDisplay = .none
    var showDurationTimer: Bool = false
    var showCopyButton: Bool = true
    var compactModeEnabled: Bool = false
}

enum RecordingIndicatorStyle: String, Codable {
    case radialBar
    case pulsingDot
    case waveform
    case none
}

enum TranscriptDisplay: String, Codable {
    case none
    case minimal
    case full
}

enum PanelDisplayMode: String, Codable {
    case `default`
    case compact
    case expanded
}
#endif
