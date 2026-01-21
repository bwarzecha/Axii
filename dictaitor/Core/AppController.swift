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
    let modelDownloadService: ModelDownloadService

    // Features
    let dictationFeature: DictationFeature
    let conversationFeature: ConversationFeature
    let meetingFeature: MeetingFeature

    // Track if features have been activated
    private var featuresActivated = false

    /// True if onboarding should be shown (models not downloaded or permissions missing)
    var needsOnboarding: Bool {
        !modelDownloadService.isASRReady
            || !micPermission.state.isAuthorized
            || !accessibilityPermission.isTrusted
    }

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
        modelDownloadService = ModelDownloadService()
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
        wireSettingsCallbacks()

        // Sync history enabled state
        historyService.isEnabled = settings.isHistoryEnabled

        // Start background tasks
        startHistoryLoad()

        // Always check downloads and try to activate features
        startModelDownload()
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
        guard !featuresActivated else { return }
        featuresActivated = true

        featureManager.register(dictationFeature)
        featureManager.register(conversationFeature)
        featureManager.register(meetingFeature)
        print("Features activated")
    }

    /// Check if all requirements are met to activate features
    private var canActivateFeatures: Bool {
        micPermission.state.isAuthorized
            && accessibilityPermission.isTrusted
            && modelDownloadService.isASRReady
    }

    /// Try to activate features if all requirements are met
    private func activateFeaturesIfReady() {
        guard canActivateFeatures else {
            print("Cannot activate features yet - mic: \(micPermission.state.isAuthorized), accessibility: \(accessibilityPermission.isTrusted), ASR: \(modelDownloadService.isASRReady)")
            return
        }
        registerFeatures()
    }

    private func startModelDownload() {
        Task {
            // Check what's already downloaded
            await modelDownloadService.checkExistingDownloads()

            // If ASR already downloaded, prepare transcription service
            if modelDownloadService.isASRReady {
                do {
                    try await transcriptionService.prepare(
                        modelsDirectory: modelDownloadService.modelsDirectory
                    )
                    print("Transcription model ready")
                    activateFeaturesIfReady()
                } catch {
                    print("Transcription model loading failed: \(error)")
                }
            }

            // If TTS already downloaded, prepare TTS service
            if modelDownloadService.isTTSReady {
                do {
                    try await ttsService.prepare()
                    print("TTS model ready")
                } catch {
                    print("TTS model loading failed: \(error)")
                }
            }

            // If Diarization already downloaded, prepare diarization service
            if modelDownloadService.isDiarizationReady {
                do {
                    try await diarizationService.prepare(
                        modelsDirectory: modelDownloadService.modelsDirectory
                    )
                    print("Diarization model ready")
                } catch {
                    print("Diarization model loading failed: \(error)")
                }
            }
        }
    }

    /// Called after onboarding completes to initialize services and activate features
    func initializeServicesAfterDownload() {
        Task {
            // Initialize ASR if downloaded (prepare() guards against double init)
            if modelDownloadService.isASRReady {
                do {
                    try await transcriptionService.prepare(
                        modelsDirectory: modelDownloadService.modelsDirectory
                    )
                    print("Transcription model ready (post-onboarding)")
                } catch {
                    print("Transcription model loading failed: \(error)")
                }
            }

            // Initialize TTS if downloaded
            if modelDownloadService.isTTSReady {
                do {
                    try await ttsService.prepare()
                    print("TTS model ready (post-onboarding)")
                } catch {
                    print("TTS model loading failed: \(error)")
                }
            }

            // Initialize Diarization if downloaded
            if modelDownloadService.isDiarizationReady {
                do {
                    try await diarizationService.prepare(
                        modelsDirectory: modelDownloadService.modelsDirectory
                    )
                    print("Diarization model ready (post-onboarding)")
                } catch {
                    print("Diarization model loading failed: \(error)")
                }
            }

            // Activate features now that onboarding is complete
            activateFeaturesIfReady()
        }
    }
}
#endif
