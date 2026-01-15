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

    // Features
    let dictationFeature: DictationFeature

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
            settings: settings
        )

        // Setup
        setupPanel()
        registerFeatures()
        wireSettingsCallbacks()

        // Start background model download
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
    }

    private func setupPanel() {
        panelController = FloatingPanelController()
        featureManager.setPanelController(panelController!)
    }

    private func registerFeatures() {
        featureManager.register(dictationFeature)
    }

    private func startModelDownload() {
        Task {
            do {
                try await transcriptionService.prepare()
                print("Transcription model ready")
            } catch {
                print("Model loading failed: \(error)")
            }
        }
    }
}
#endif
