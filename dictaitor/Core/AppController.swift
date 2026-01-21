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
    private let diarizationService: DiarizationService
    private let clipboardService: ClipboardService
    let micPermission: MicrophonePermissionService
    let accessibilityPermission: AccessibilityPermissionService
    let screenPermission: ScreenRecordingPermissionService
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
    let meetingFeature: MeetingFeature

    init() {
        // Create services
        hotkeyService = HotkeyService()
        featureManager = FeatureManager(hotkeyService: hotkeyService)
        transcriptionService = TranscriptionService()
        diarizationService = DiarizationService()
        clipboardService = ClipboardService()
        micPermission = MicrophonePermissionService()
        accessibilityPermission = AccessibilityPermissionService()
        screenPermission = ScreenRecordingPermissionService()
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
        // Features use AudioSession internally (single-use per recording)
        dictationFeature = DictationFeature(
            transcriptionService: transcriptionService,
            micPermission: micPermission,
            pasteService: pasteService,
            settings: settings,
            historyService: historyService
        )
        conversationFeature = ConversationFeature(
            transcriptionService: transcriptionService,
            micPermission: micPermission,
            settings: settings,
            llmService: llmService,
            ttsService: ttsService,
            playbackService: playbackService,
            historyService: historyService
        )
        meetingFeature = MeetingFeature(
            transcriptionService: transcriptionService,
            screenPermission: screenPermission,
            micPermission: micPermission,
            settings: settings,
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
        featureManager.register(meetingFeature)
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
        Task {
            do {
                try await diarizationService.prepare()
                print("Diarization model ready")
            } catch {
                print("Diarization model loading failed: \(error)")
            }
        }
    }
}
#endif
