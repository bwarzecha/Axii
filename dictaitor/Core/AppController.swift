//
//  AppController.swift
//  dictaitor
//
//  Thin coordinator - sets up services and features.
//  Logic lives in features, not here.
//

#if os(macOS)
import AppKit

/// Application coordinator. Sets up services and registers features.
/// Feature logic is owned by the features themselves.
@MainActor
final class AppController {
    private let hotkeyService: HotkeyService
    private let featureManager: FeatureManager
    private var panelController: FloatingPanelController?

    // Services (exposed for onboarding and settings)
    private let transcriptionService: TranscriptionService
    private let audioService: AudioCaptureService
    private let clipboardService: ClipboardService
    let micPermission: MicrophonePermissionService
    let accessibilityPermission: AccessibilityPermissionService
    let microphoneSelection: MicrophoneSelectionService
    private let pasteService: PasteService
    let settings: SettingsService
    let llmSettings: LLMSettingsService
    private let llmService: LLMService
    private let ttsService: TextToSpeechService
    private let playbackService: AudioPlaybackService
    let historyService: HistoryService

    // Features
    let dictationFeature: DictationFeature
    let conversationFeature: ConversationFeature

    init() {
        // Create services
        hotkeyService = HotkeyService()
        featureManager = FeatureManager(hotkeyService: hotkeyService)
        transcriptionService = TranscriptionService()
        audioService = AudioCaptureService()
        clipboardService = ClipboardService()
        micPermission = MicrophonePermissionService()
        accessibilityPermission = AccessibilityPermissionService()
        microphoneSelection = MicrophoneSelectionService()
        settings = SettingsService()
        llmSettings = LLMSettingsService()
        llmService = LLMService(settings: llmSettings)
        ttsService = TextToSpeechService()
        playbackService = AudioPlaybackService()
        historyService = HistoryService()
        pasteService = PasteService(
            clipboard: clipboardService,
            accessibilityPermission: accessibilityPermission
        )

        // Create features with injected services
        dictationFeature = DictationFeature(
            audioService: audioService,
            transcriptionService: transcriptionService,
            micPermission: micPermission,
            microphoneSelection: microphoneSelection,
            pasteService: pasteService,
            settings: settings,
            historyService: historyService
        )
        conversationFeature = ConversationFeature(
            audioService: audioService,
            transcriptionService: transcriptionService,
            micPermission: micPermission,
            settings: settings,
            llmService: llmService,
            ttsService: ttsService,
            playbackService: playbackService,
            historyService: historyService
        )

        // Setup
        setupPanel()
        registerFeatures()
        wireSettingsCallbacks()

        // Sync history enabled state
        historyService.isEnabled = settings.isHistoryEnabled

        // Start background tasks
        startModelDownload()
        startHistoryLoad()
    }

    private func wireSettingsCallbacks() {
        // Pause/resume hotkeys during hotkey recording
        settings.onHotkeyRecordingStarted = { [weak self] in
            self?.hotkeyService.pause()
        }
        settings.onHotkeyRecordingStopped = { [weak self] in
            self?.hotkeyService.resume()
        }
        // Sync history setting to service
        settings.onHistorySettingChanged = { [weak self] enabled in
            self?.historyService.isEnabled = enabled
        }
    }

    private func startHistoryLoad() {
        Task {
            await historyService.loadAllMetadata()
        }
    }

    private func setupPanel() {
        panelController = FloatingPanelController()
        featureManager.setPanelController(panelController!)
    }

    private func registerFeatures() {
        featureManager.register(dictationFeature)
        featureManager.register(conversationFeature)
    }

    private func startModelDownload() {
        Task {
            do {
                try await transcriptionService.prepare()
                print("Transcription model ready")
            } catch {
                print("Transcription model loading failed: \(error)")
            }
        }
        Task {
            do {
                try await ttsService.prepare()
                print("TTS model ready")
            } catch {
                print("TTS model loading failed: \(error)")
            }
        }
    }
}
#endif
