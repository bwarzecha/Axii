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
    var hotkey: HotkeyConfig?     // nil = no hotkey assigned
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
    var label: String? = nil
}

// MARK: - Output

enum OutputDestination: Codable {
    case pasteAtCursor(PasteConfig)
    case clipboard(ClipboardConfig)
    case file(FileOutputConfig)
    case display(DisplayConfig)
    case history(HistoryConfig)

    // Backward compatibility: decode old bare .clipboard / .display cases
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let raw = try? container.decode(String.self) {
            switch raw {
            case "clipboard": self = .clipboard(ClipboardConfig()); return
            case "display": self = .display(DisplayConfig()); return
            default: break
            }
        }
        // Fall through to default keyed decoding
        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try keyed.decodeIfPresent(PasteConfig.self, forKey: .pasteAtCursor) {
            self = .pasteAtCursor(v)
        } else if let v = try keyed.decodeIfPresent(ClipboardConfig.self, forKey: .clipboard) {
            self = .clipboard(v)
        } else if let v = try keyed.decodeIfPresent(FileOutputConfig.self, forKey: .file) {
            self = .file(v)
        } else if let v = try keyed.decodeIfPresent(DisplayConfig.self, forKey: .display) {
            self = .display(v)
        } else if let v = try keyed.decodeIfPresent(HistoryConfig.self, forKey: .history) {
            self = .history(v)
        } else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown OutputDestination")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pasteAtCursor(let v): try container.encode(v, forKey: .pasteAtCursor)
        case .clipboard(let v): try container.encode(v, forKey: .clipboard)
        case .file(let v): try container.encode(v, forKey: .file)
        case .display(let v): try container.encode(v, forKey: .display)
        case .history(let v): try container.encode(v, forKey: .history)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case pasteAtCursor, clipboard, file, display, history
    }
}

struct PasteConfig: Codable {
    var failureBehavior: InsertionFailureBehavior = .showCopyButton
    var restoreClipboard: Bool = false
    var contentTemplate: String? = nil
}

struct ClipboardConfig: Codable {
    var contentTemplate: String? = nil
}

struct DisplayConfig: Codable {
    var contentTemplate: String? = nil
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
