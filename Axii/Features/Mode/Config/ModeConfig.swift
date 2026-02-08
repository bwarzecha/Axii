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
    var outputs: [OutputDestination]
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
    var enableStreamingChunks: Bool = false
    var chunkDuration: TimeInterval? = nil
}

struct DualCaptureConfig: Codable {
    var devicePreference: DevicePreference = .systemDefault
    var appSelection: AppSelectionConfig = .all
    var chunkDuration: TimeInterval = 15.0
    var silenceThreshold: Float = 0.001
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
    case batch(BatchTranscriptionConfig)
    case streaming(StreamingConfig)
}

struct BatchTranscriptionConfig: Codable {
    var minimumDuration: TimeInterval = 0.5
}

struct StreamingConfig: Codable {
    var chunkDurationSeconds: TimeInterval = 15.0
    var enableRealTimeDisplay: Bool = true
    var enableFinalTranscription: Bool = true
}

// MARK: - Processing

enum ProcessingStep: Codable {
    case diarize(DiarizeConfig)
    case segmentMerge(SegmentMergeConfig)
    case llmTransform(LLMTransformConfig)
    case format(FormatConfig)
}

struct DiarizeConfig: Codable {
    var mode: DiarizeMode = .sourceLabels(micLabel: "You", systemLabel: "Remote")
}

enum DiarizeMode: Codable {
    case sourceLabels(micLabel: String, systemLabel: String)
    case speakerModel
}

struct SegmentMergeConfig: Codable {
    var mergeConsecutiveSameSpeaker: Bool = true
}

struct LLMTransformConfig: Codable {
    var systemPrompt: String = ""
    var promptTemplate: String? = nil
    var model: String? = nil
    var temperature: Double? = nil
    var multiTurn: Bool = false
}

struct FormatConfig: Codable {
    var outputFormat: OutputFormat = .plain
}

enum OutputFormat: String, Codable {
    case plain
    case markdown
    case json
}

// MARK: - Output

enum OutputDestination: Codable {
    case pasteAtCursor(PasteConfig)
    case clipboard
    case file(FileOutputConfig)
    case display
    case history(HistoryConfig)
}

struct PasteConfig: Codable {
    var failureBehavior: InsertionFailureBehavior = .showCopyButton
    var restoreClipboard: Bool = false
}

struct FileOutputConfig: Codable {
    var pathTemplate: String
    var writeMode: FileWriteMode = .append
    var contentTemplate: String? = nil
    var createDirectories: Bool = true
}

enum FileWriteMode: String, Codable {
    case append
    case overwrite
    case newFile
}

struct HistoryConfig: Codable {
    var saveAudio: Bool = true
    var audioFormat: AudioStorageFormat = .aac
}

// MARK: - Lifecycle

struct LifecycleConfig: Codable {
    var startMode: StartMode = .automatic
    var panelPersistence: PanelPersistence = .autoDismiss(delay: 2.0)
    var escapeBehavior: EscapeBehavior = .alwaysCancel
    var pauseMedia: Bool = false
    var captureFocus: Bool = false
    var permissions: [PermissionType] = [.microphone]
    var enableCrashRecovery: Bool = false
}

enum PanelPersistence: Codable {
    case autoDismiss(delay: TimeInterval)
    case stayOpen
}

enum EscapeBehavior: String, Codable {
    case alwaysCancel
    case blockWhileRecording
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
