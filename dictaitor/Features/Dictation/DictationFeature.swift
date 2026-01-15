//
//  DictationFeature.swift
//  dictaitor
//
//  Self-contained dictation feature. Registers hotkey, manages state machine.
//

import AppKit
import HotKey
import SwiftUI

/// Configuration for dictation hotkey.
enum DictationConfig {
    static let hotkeyKey: Key = .space
    static let hotkeyModifiers: NSEvent.ModifierFlags = [.control, .shift]
    static let hotkeyDisplay = "Control+Shift+Space"
}

/// Self-contained dictation feature.
@MainActor
final class DictationFeature: Feature {
    let state = DictationState()
    private var context: FeatureContext?
    private(set) var isActive = false

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
        state.phase = .idle
        state.audioLevel = 0
        isActive = false
    }

    // MARK: - Hotkey Handling

    private func handleHotkey() {
        switch state.phase {
        case .idle:
            startRecording()
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

    private func startRecording() {
        state.phase = .recording
        isActive = true
        context?.onActivate?(self)
        simulateAudioLevels()
    }

    private func stopRecording() {
        guard state.isRecording else { return }
        state.phase = .transcribing
        simulateTranscription()
    }

    private func cancelAndDeactivate() {
        state.phase = .idle
        state.audioLevel = 0
        isActive = false
        context?.onDeactivate?()
    }

    private func completeAndDeactivate() {
        state.phase = .idle
        state.audioLevel = 0
        isActive = false
        context?.onDeactivate?()
    }

    // MARK: - Simulation (temporary)

    private func simulateAudioLevels() {
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            guard let self, self.state.isRecording else {
                timer.invalidate()
                return
            }
            self.state.audioLevel = Float.random(in: 0.1...0.8)
        }
    }

    private func simulateTranscription() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.isActive else { return }
            self.state.phase = .done(text: "Simulated transcription result")

            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.completeAndDeactivate()
            }
        }
    }
}
