//
//  DictationFeature.swift
//  dictaitor
//
//  Self-contained dictation feature. Registers hotkey, manages state machine.
//

#if os(macOS)
import Accelerate
import AppKit
import HotKey
import SwiftUI

/// Configuration for dictation hotkey.
enum DictationConfig {
    static let hotkeyKey: Key = .space
    static let hotkeyModifiers: NSEvent.ModifierFlags = [.control, .shift]
    static let hotkeyDisplay = "Control+Shift+Space"
}

/// Self-contained dictation feature with real audio capture and transcription.
@MainActor
final class DictationFeature: Feature {
    let state = DictationState()
    private var context: FeatureContext?
    private(set) var isActive = false

    // Services
    private let audioService: AudioCaptureService
    private let transcriptionService: TranscriptionService
    private let clipboardService: ClipboardService

    init(
        audioService: AudioCaptureService,
        transcriptionService: TranscriptionService,
        clipboardService: ClipboardService
    ) {
        self.audioService = audioService
        self.transcriptionService = transcriptionService
        self.clipboardService = clipboardService

        // Wire audio chunk handling - calculate RMS for visualization
        self.audioService.onChunk = { [weak self] chunk in
            let level = Self.calculateRMS(chunk.samples)
            // Normalize for UI (RMS is typically 0-0.1 for speech)
            self?.state.audioLevel = min(level * 5, 1.0)
        }
    }

    // MARK: - Feature Protocol

    var panelContent: AnyView {
        AnyView(DictationPanelView(state: state, hotkeyHint: DictationConfig.hotkeyDisplay))
    }

    func register(with context: FeatureContext) {
        self.context = context

        context.hotkeyService.register(
            .togglePanel,
            key: DictationConfig.hotkeyKey,
            modifiers: DictationConfig.hotkeyModifiers
        ) { [weak self] in
            self?.handleHotkey()
        }
    }

    func cancel() {
        if audioService.isRecording {
            _ = audioService.stopCapture()
        }
        state.phase = .idle
        state.audioLevel = 0
        isActive = false
    }

    // MARK: - Hotkey Handling

    private func handleHotkey() {
        switch state.phase {
        case .idle:
            startRecordingIfReady()
        case .loadingModel:
            // Ignore - wait for model to load
            break
        case .recording:
            stopRecording()
        case .transcribing, .done, .error:
            cancelAndDeactivate()
        }
    }

    func handleEscape() {
        cancelAndDeactivate()
    }

    // MARK: - Recording Flow

    private func startRecordingIfReady() {
        Task {
            let isReady = await transcriptionService.isReady

            if isReady {
                startRecording()
            } else {
                waitForModelAndRecord()
            }
        }
    }

    private func waitForModelAndRecord() {
        isActive = true
        context?.onActivate?(self)
        state.phase = .loadingModel

        Task {
            do {
                try await transcriptionService.prepare()
                // Model ready - start recording automatically
                startRecording()
            } catch {
                state.phase = .error(message: "Model loading failed")
                scheduleDeactivation(delay: 3.0)
            }
        }
    }

    private func startRecording() {
        do {
            try audioService.startCapture()
            state.phase = .recording
            isActive = true
            context?.onActivate?(self)
        } catch {
            state.phase = .error(message: "Microphone error")
            scheduleDeactivation(delay: 2.0)
        }
    }

    private func stopRecording() {
        guard state.isRecording else { return }

        let (samples, stats) = audioService.stopCapture()
        state.audioLevel = 0
        state.phase = .transcribing

        Task {
            do {
                let text = try await transcriptionService.transcribe(samples: samples, sampleRate: stats.sampleRate)

                if text.isEmpty {
                    state.phase = .done(text: "No speech detected")
                } else {
                    clipboardService.copy(text)
                    state.phase = .done(text: text)
                }

                scheduleDeactivation(delay: 2.0)
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

    private func cancelAndDeactivate() {
        if audioService.isRecording {
            _ = audioService.stopCapture()
        }
        state.phase = .idle
        state.audioLevel = 0
        isActive = false
        context?.onDeactivate?()
    }

    private func scheduleDeactivation(delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.cancelAndDeactivate()
        }
    }

    // MARK: - Audio Processing

    private static func calculateRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        return rms
    }
}
#endif
