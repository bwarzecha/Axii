//
//  AppController.swift
//  Axii
//
//  Thin coordinator — sets up services and registers mode-driven features.
//  The mode runtime (ModeFeature via FeatureManager) is the only app-shell
//  execution path. Legacy feature classes still exist in the repo but are
//  not constructed or registered here.
//

#if os(macOS)
import AppKit

/// Application coordinator. Sets up services and registers features.
/// All features are mode-driven ModeFeature instances loaded from ModeService.
@MainActor
final class AppController {
    private let hotkeyService: HotkeyService
    private let advancedHotkeyService: AdvancedHotkeyService
    let featureManager: FeatureManager
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
    let historyService: HistoryService
    let modelDownloadService: ModelDownloadService
    let mediaControlService: MediaControlService

    // Mode runtime — the sole feature system.
    let modeService = ModeService()

    /// Re-runs transcription over stored meeting audio; used by the history
    /// UI to build transcripts for auto-saved meetings that never got one.
    lazy var meetingRetranscriber = MeetingRetranscriptionService(
        transcriptionService: transcriptionService,
        historyService: historyService
    )

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
        AxiiAppDelegate.featureManager = featureManager
        transcriptionService = TranscriptionService()
        diarizationService = DiarizationService()
        clipboardService = ClipboardService()
        micPermission = MicrophonePermissionService()
        accessibilityPermission = AccessibilityPermissionService()
        screenPermission = ScreenRecordingPermissionService()
        llmSettings = LLMSettingsService()
        llmService = LLMService(settings: llmSettings)
        historyService = HistoryService()
        modelDownloadService = ModelDownloadService()
        mediaControlService = MediaControlService()
        pasteService = PasteService(
            clipboard: clipboardService,
            accessibilityPermission: accessibilityPermission
        )

        // Setup
        setupPanel()
        wireSettingsCallbacks()
        // Capture-type edits rebuild the feature (different runtime shape);
        // construction stays on the single makeModeFeature path.
        featureManager.modeFeatureFactory = { [weak self] config in
            self.map { $0.makeModeFeature(from: config) }
        }

        // Sync history enabled state
        historyService.isEnabled = settings.isHistoryEnabled

        // Start background tasks
        startHistoryLoad()

        // Always check downloads and try to activate features
        startModelDownload()
    }

    // MARK: - ModeFeature Construction

    /// Single construction path for ModeFeature instances. Used by both
    /// startup registration and runtime custom-mode creation.
    private func makeModeFeature(from config: ModeConfig) -> ModeFeature {
        ModeFeature(
            config: config,
            transcriptionService: transcriptionService,
            micPermission: micPermission,
            screenPermission: config.audioCapture.isDual ? screenPermission : nil,
            pasteService: pasteService,
            clipboardService: clipboardService,
            settings: settings,
            historyService: historyService,
            mediaControlService: mediaControlService,
            llmService: llmService,
            diarizationService: config.audioCapture.isDual ? diarizationService : nil
        )
    }

    // MARK: - Settings Callbacks

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
            // Re-register EVERY feature with the now-active service —
            // the legacy settings callbacks cover only built-in modes.
            featureManager.reRegisterAllHotkeys()
        }
    }

    private func handleHotkeyModeChange() {
        // Clean up both services before switching
        hotkeyService.unregisterAll()
        advancedHotkeyService.stop()
        advancedHotkeyService.unregisterAll()

        // Start the appropriate service based on mode
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

        // Every registration — custom modes and the active feature's Escape
        // included — died in the wipe above. Re-arm them all: a mode
        // mid-recording whose finish hotkey stays dead is unstoppable.
        featureManager.reRegisterAllHotkeys()
    }

    // MARK: - Feature Registration

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

        // Register ModeFeature instances for all modes loaded from ModeService.
        let modes = modeService.loadAllModes()
        for config in modes {
            featureManager.register(makeModeFeature(from: config))
        }
        print("Mode features activated (\(modes.count) modes)")
    }

    /// Registers a new ModeFeature at runtime (for custom modes created in the editor).
    func registerNewMode(_ config: ModeConfig) {
        featureManager.register(makeModeFeature(from: config))
    }

    // MARK: - Readiness & Model Loading

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
