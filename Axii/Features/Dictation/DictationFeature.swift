//
//  DictationFeature.swift
//  Axii
//
//  Self-contained dictation feature. Registers hotkey, manages state machine.
//  Uses RecordingSessionHelper for microphone capture.
//

#if os(macOS)
import AppKit
import HotKey
import SwiftUI

/// Self-contained dictation feature with real audio capture and transcription.
@MainActor
final class DictationFeature: Feature {
    let state = DictationState()
    private var context: FeatureContext?
    private(set) var isActive = false

    // Services
    private let transcriptionService: TranscriptionService
    private let micPermission: MicrophonePermissionService
    private let pasteService: PasteService
    private let clipboardService: ClipboardService
    private let settings: SettingsService
    private let historyService: HistoryService

    // Recording helper (created per recording)
    private var recordingHelper: RecordingSessionHelper?

    // Tracks scheduled deactivation so it can be cancelled
    private var deactivationWorkItem: DispatchWorkItem?

    // Device selection persistence
    private let deviceUIDKey = "selectedMicrophoneUID"
    private var selectedDeviceUID: String? {
        get { UserDefaults.standard.string(forKey: deviceUIDKey) }
        set { UserDefaults.standard.set(newValue, forKey: deviceUIDKey) }
    }

    // State for focus tracking
    private var focusSnapshot: FocusSnapshot?

    // Device list monitor (for UI refresh when devices connect/disconnect)
    private let deviceListMonitor = DeviceMonitor()

    init(
        transcriptionService: TranscriptionService,
        micPermission: MicrophonePermissionService,
        pasteService: PasteService,
        clipboardService: ClipboardService,
        settings: SettingsService,
        historyService: HistoryService
    ) {
        self.transcriptionService = transcriptionService
        self.micPermission = micPermission
        self.pasteService = pasteService
        self.clipboardService = clipboardService
        self.settings = settings
        self.historyService = historyService
    }

    // MARK: - Feature Protocol

    var panelContent: AnyView {
        AnyView(DictationPanelView(
            state: state,
            hotkeyHint: settings.hotkeyConfig.symbolString,
            onMicrophoneSwitch: { [weak self] device in
                self?.switchMicrophone(to: device)
            },
            onCopy: { [weak self] text in
                self?.copyAndDismiss(text)
            }
        ))
    }

    /// Currently selected microphone (or nil for system default).
    private var selectedMicrophone: AudioDevice? {
        guard let uid = selectedDeviceUID else { return nil }
        return state.availableMicrophones.first { $0.uid == uid }
    }

    func register(with context: FeatureContext) {
        self.context = context

        // Register hotkey with current settings
        registerHotkey()

        // Re-register when settings change
        settings.onHotkeyChanged = { [weak self] in
            self?.registerHotkey()
        }

        // Initialize device list and monitor for changes
        refreshDeviceList()
        deviceListMonitor.onDeviceListChanged = { [weak self] in
            Task { @MainActor in
                self?.refreshDeviceList()
            }
        }
    }

    private func refreshDeviceList() {
        state.availableMicrophones = AudioSession.availableMicrophones()
        state.selectedMicrophone = selectedMicrophone
    }

    private func registerHotkey() {
        guard let context else { return }
        let config = settings.hotkeyConfig
        context.registerHotkey(.togglePanel, config: config) { [weak self] in
            self?.handleHotkey()
        }
    }

    func cancel() {
        cancelDeactivationTimer()
        recordingHelper?.cancel()
        recordingHelper = nil
        state.phase = .idle
        state.audioLevel = 0
        state.isWaitingForSignal = false
        isActive = false
    }

    // MARK: - Hotkey Handling

    private func handleHotkey() {
        switch state.phase {
        case .idle:
            startRecordingIfReady()
        case .loadingModel:
            break
        case .recording:
            stopRecording()
        case .done:
            // User wants to continue dictating - start new recording
            cancelDeactivationTimer()
            startRecordingIfReady()
        case .transcribing, .error:
            cancelAndDeactivate()
        case .doneNeedsCopy(let text, _):
            // Hotkey during copy button state: copy and dismiss
            copyAndDismiss(text)
        }
    }

    func handleEscape() {
        cancelAndDeactivate()
    }

    // MARK: - Recording Flow

    private func startRecordingIfReady() {
        startRecording()

        Task {
            let isReady = await transcriptionService.isReady
            if !isReady {
                try? await transcriptionService.prepare()
            }
        }
    }

    private func startRecording() {
        focusSnapshot = FocusSnapshot.capture()

        let helper = RecordingSessionHelper()
        recordingHelper = helper

        // Wire up callbacks
        helper.onVisualizationUpdate = { [weak self] update in
            guard self?.state.isRecording == true else { return }
            self?.state.audioLevel = update.audioLevel
            self?.state.spectrum = update.spectrum
        }

        helper.onSignalStateChanged = { [weak self] isWaiting in
            self?.state.isWaitingForSignal = isWaiting
        }

        helper.onError = { [weak self] error in
            self?.handleSessionError(error)
        }

        // Determine source
        let source: AudioSource
        if let device = selectedMicrophone {
            source = .microphone(device)
        } else {
            source = .systemDefault
        }

        Task {
            do {
                try await helper.start(source: source)
                state.phase = .recording
                isActive = true
                context?.onActivate?(self)
            } catch let error as AudioSessionError {
                handleSessionError(error)
            } catch {
                state.phase = .error(message: "Microphone error")
                scheduleDeactivation(delay: 2.0)
            }
        }
    }

    private func handleSessionError(_ error: AudioSessionError) {
        switch error {
        case .permissionDenied:
            if micPermission.state.isBlocked {
                micPermission.openSystemSettings()
            }
            state.phase = .error(message: "Microphone permission required")
        case .deviceUnavailable:
            state.phase = .error(message: "Microphone unavailable")
        case .configurationFailed(let reason):
            state.phase = .error(message: reason)
        case .captureFailure(let reason):
            state.phase = .error(message: reason)
        }
        scheduleDeactivation(delay: 2.0)
    }

    private func stopRecording() {
        guard state.isRecording, let helper = recordingHelper else { return }

        let (samples, sampleRate) = helper.stop()
        recordingHelper = nil

        state.audioLevel = 0
        state.isWaitingForSignal = false
        state.phase = .transcribing

        Task {
            do {
                let text = try await transcriptionService.transcribe(
                    samples: samples,
                    sampleRate: sampleRate
                )

                var pastedToApp: String?
                var shouldScheduleDeactivation = true

                if text.isEmpty {
                    state.phase = .done(text: "No speech detected")
                } else {
                    let outcome = await pasteService.paste(
                        text: text,
                        focusSnapshot: focusSnapshot,
                        finishBehavior: settings.finishBehavior,
                        failureBehavior: settings.insertionFailureBehavior
                    )

                    switch outcome {
                    case .pasted:
                        state.phase = .done(text: text)
                        pastedToApp = focusSnapshot?.bundleIdentifier

                    case .pastedAndCopied:
                        state.phase = .done(text: text)
                        pastedToApp = focusSnapshot?.bundleIdentifier

                    case .copiedOnly:
                        state.phase = .done(text: "\(text)\n(Copied to clipboard)")

                    case .copiedFallback(let reason):
                        state.phase = .done(text: "\(text)\n(Copied: \(reason))")

                    case .needsManualCopy(let reason):
                        // Don't auto-dismiss, wait for user to click Copy or Escape
                        state.phase = .doneNeedsCopy(text: text, reason: reason)
                        shouldScheduleDeactivation = false

                    case .skipped:
                        state.phase = .done(text: "No speech detected")
                    }
                }

                focusSnapshot = nil

                if shouldScheduleDeactivation {
                    scheduleDeactivation(delay: 2.0)
                }

                if !text.isEmpty {
                    await saveTranscriptionToHistory(
                        text: text,
                        samples: samples,
                        sampleRate: sampleRate,
                        pastedTo: pastedToApp
                    )
                }
            } catch let error as TranscriptionError {
                let message = error.errorDescription ?? "Transcription failed"
                state.phase = .error(message: message)
                scheduleDeactivation(delay: 2.0)
            } catch {
                state.phase = .error(message: "Transcription failed")
                scheduleDeactivation(delay: 2.0)
            }
        }
    }

    private func saveTranscriptionToHistory(
        text: String,
        samples: [Float],
        sampleRate: Double,
        pastedTo: String?
    ) async {
        guard historyService.isEnabled else { return }

        do {
            let transcription = Transcription(
                text: text,
                pastedTo: pastedTo
            )

            try await historyService.save(.transcription(transcription))

            let audioRecording = try await historyService.saveAudio(
                samples: samples,
                sampleRate: sampleRate,
                for: transcription.id
            )

            let updatedTranscription = Transcription(
                id: transcription.id,
                text: text,
                audioRecording: audioRecording,
                pastedTo: pastedTo,
                createdAt: transcription.createdAt
            )

            try await historyService.save(.transcription(updatedTranscription))
        } catch {
            print("DictationFeature: Failed to save transcription to history: \(error)")
        }
    }

    private func cancelAndDeactivate() {
        cancelDeactivationTimer()
        recordingHelper?.cancel()
        recordingHelper = nil
        state.phase = .idle
        state.audioLevel = 0
        state.isWaitingForSignal = false
        isActive = false
        context?.onDeactivate?()
    }

    private func cancelDeactivationTimer() {
        deactivationWorkItem?.cancel()
        deactivationWorkItem = nil
    }

    private func scheduleDeactivation(delay: TimeInterval) {
        cancelDeactivationTimer()

        let workItem = DispatchWorkItem { [weak self] in
            self?.deactivationWorkItem = nil
            self?.cancelAndDeactivate()
        }
        deactivationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    /// Copy text to clipboard and dismiss the panel.
    /// Used when user clicks the Copy button in doneNeedsCopy state.
    private func copyAndDismiss(_ text: String) {
        clipboardService.copy(text)
        cancelAndDeactivate()
    }

    // MARK: - Microphone Switching

    private func switchMicrophone(to device: AudioDevice?) {
        let wasRecording = state.isRecording

        if wasRecording {
            recordingHelper?.cancel()
            recordingHelper = nil
            state.audioLevel = 0
            state.isWaitingForSignal = false
        }

        selectedDeviceUID = device?.uid
        state.selectedMicrophone = device

        if wasRecording {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.startRecording()
            }
        }
    }
}
#endif
