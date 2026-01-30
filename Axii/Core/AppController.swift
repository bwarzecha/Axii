//
//  AppController.swift
//  Axii
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
    private let advancedHotkeyService: AdvancedHotkeyService
    private let featureManager: FeatureManager
    private var panelController: FloatingPanelController?

    // Services (exposed for onboarding and settings)
    private let transcriptionService: TranscriptionService
    private let diarizationService: DiarizationService
    private let clipboardService: ClipboardService
    let micPermission: MicrophonePermissionService
    let accessibilityPermission: AccessibilityPermissionService
    let screenPermission: ScreenRecordingPermissionService
    let inputMonitoringPermission: InputMonitoringPermissionService
    private let pasteService: PasteService
    let settings: SettingsService
    let llmSettings: LLMSettingsService
    let llmService: LLMService
    private let playbackService: AudioPlaybackService
    let historyService: HistoryService
    let modelDownloadService: ModelDownloadService
    let mediaControlService: MediaControlService

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
        // Create services (order matters due to dependencies)
        settings = SettingsService()
        hotkeyService = HotkeyService()
        inputMonitoringPermission = InputMonitoringPermissionService()
        advancedHotkeyService = AdvancedHotkeyService(permission: inputMonitoringPermission)
        featureManager = FeatureManager(
            hotkeyService: hotkeyService,
            advancedHotkeyService: advancedHotkeyService,
            settings: settings
        )
        transcriptionService = TranscriptionService()
        diarizationService = DiarizationService()
        clipboardService = ClipboardService()
        micPermission = MicrophonePermissionService()
        accessibilityPermission = AccessibilityPermissionService()
        screenPermission = ScreenRecordingPermissionService()
        llmSettings = LLMSettingsService()
        llmService = LLMService(settings: llmSettings)
        playbackService = AudioPlaybackService()
        historyService = HistoryService()
        modelDownloadService = ModelDownloadService()
        mediaControlService = MediaControlService()
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
            clipboardService: clipboardService,
            settings: settings,
            historyService: historyService,
            mediaControlService: mediaControlService
        )
        conversationFeature = ConversationFeature(
            transcriptionService: transcriptionService,
            micPermission: micPermission,
            settings: settings,
            llmService: llmService,
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
            self?.advancedHotkeyService.pause()
        }
        settings.onHotkeyRecordingStopped = { [weak self] in
            self?.hotkeyService.resume()
            self?.advancedHotkeyService.resume()
        }
        // Handle hotkey mode changes
        settings.onHotkeyModeChanged = { [weak self] in
            self?.handleHotkeyModeChange()
        }
        // Sync history setting to service
        settings.onHistorySettingChanged = { [weak self] enabled in
            self?.historyService.isEnabled = enabled
        }
        // Start advanced hotkey service when permission is granted (if in advanced mode)
        inputMonitoringPermission.onPermissionGranted = { [weak self] in
            self?.handleInputMonitoringPermissionGranted()
        }
    }

    private func handleInputMonitoringPermissionGranted() {
        // Only start if we're in advanced mode and the service isn't already running
        guard settings.hotkeyMode == .advanced, !advancedHotkeyService.isActive else { return }

        if advancedHotkeyService.start() {
            print("Advanced hotkey mode started after permission granted")
            // Re-register hotkeys with the now-active service
            settings.onHotkeyChanged?()
            settings.onConversationHotkeyChanged?()
        }
    }

    private func handleHotkeyModeChange() {
        // Clean up both services before switching
        hotkeyService.unregisterAll()
        advancedHotkeyService.stop()
        advancedHotkeyService.unregisterAll()

        // Start the appropriate service based on mode
        // Features will re-register via onHotkeyChanged callback (fired after this)
        switch settings.hotkeyMode {
        case .standard:
            print("Switched to Standard hotkey mode")
        case .advanced:
            if advancedHotkeyService.start() {
                print("Switched to Advanced hotkey mode")
            } else {
                print("Failed to start Advanced hotkey mode - permission not granted")
            }
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

        // Start the appropriate hotkey service based on mode
        if settings.hotkeyMode == .advanced {
            if advancedHotkeyService.start() {
                print("Advanced hotkey mode active")
            } else {
                print("Advanced hotkey mode failed to start - permission not granted")
            }
        }

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
