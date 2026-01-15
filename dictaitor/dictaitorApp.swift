//
//  DictAItorApp.swift
//  dictaitor
//
//  Menu bar app with floating panel triggered by global hotkey.
//

import SwiftUI

#if os(macOS)
import AppKit

@main
struct DictAItorApp: App {
    @State private var controller = AppController()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // Menu bar for status and quit
        MenuBarExtra("DictAItor", systemImage: menuBarIcon) {
            MenuBarView(
                dictationState: controller.dictationFeature.state,
                onShowOnboarding: { openWindow(id: "onboarding") }
            )
        }
        .menuBarExtraStyle(.menu)

        // Onboarding window
        Window("Setup", id: "onboarding") {
            OnboardingView(
                micPermission: controller.micPermission,
                accessibilityPermission: controller.accessibilityPermission,
                onComplete: {
                    hasCompletedOnboarding = true
                    NSApp.keyWindow?.close()
                }
            )
            .onAppear {
                // Bring window to front and activate app
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(hasCompletedOnboarding ? .suppressed : .presented)
    }

    private var menuBarIcon: String {
        controller.dictationFeature.isActive ? "waveform" : "mic"
    }
}

/// Menu bar dropdown content.
struct MenuBarView: View {
    var dictationState: DictationState
    var onShowOnboarding: () -> Void

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 8) {
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Hotkey: Control+Shift+Space")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Divider()

            Button("Setup Permissions...") {
                openWindow(id: "onboarding")
                onShowOnboarding()
            }

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: [.command])
        }
        .padding(.vertical, 8)
        .frame(width: 180)
    }

    private var statusText: String {
        switch dictationState.phase {
        case .idle:
            return "Ready"
        case .loadingModel:
            return "Loading model..."
        case .recording:
            return "Recording..."
        case .transcribing:
            return "Transcribing..."
        case .done:
            return "Done"
        case .error:
            return "Error"
        }
    }
}

#else
// iOS version - simple recording and transcription test
@main
struct DictAItorApp: App {
    var body: some Scene {
        WindowGroup {
            IOSDictationView()
        }
    }
}

/// Simple iOS dictation test view.
struct IOSDictationView: View {
    @State private var controller = IOSDictationController()

    var body: some View {
        VStack(spacing: 24) {
            Text("DictAItor")
                .font(.largeTitle)
                .fontWeight(.bold)

            Spacer()

            // Status display
            statusView

            // Transcription result
            if case .done(let text) = controller.state.phase {
                transcriptionResultView(text: text)
            }

            Spacer()

            // Record button
            recordButton

            // Permission warning
            if controller.micPermission.state.isBlocked {
                permissionWarning
            }
        }
        .padding()
        .task {
            await controller.setup()
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch controller.state.phase {
        case .idle:
            Text("Tap to record")
                .foregroundStyle(.secondary)
        case .loadingModel:
            HStack {
                ProgressView()
                Text("Loading model...")
            }
        case .recording:
            HStack {
                Circle()
                    .fill(.red)
                    .frame(width: 12, height: 12)
                Text("Recording...")
            }
        case .transcribing:
            HStack {
                ProgressView()
                Text("Transcribing...")
            }
        case .done:
            Text("Done!")
                .foregroundStyle(.green)
        case .error(let message):
            Text(message)
                .foregroundStyle(.red)
        }
    }

    private func transcriptionResultView(text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Result:")
                .font(.headline)
            Text(text)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.gray.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var recordButton: some View {
        Button {
            Task {
                await controller.toggleRecording()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(controller.state.isRecording ? .red : .blue)
                    .frame(width: 80, height: 80)
                Image(systemName: controller.state.isRecording ? "stop.fill" : "mic.fill")
                    .font(.title)
                    .foregroundStyle(.white)
            }
        }
        .disabled(isButtonDisabled)
    }

    private var isButtonDisabled: Bool {
        switch controller.state.phase {
        case .loadingModel, .transcribing:
            return true
        default:
            return controller.micPermission.state.isBlocked
        }
    }

    private var permissionWarning: some View {
        VStack(spacing: 8) {
            Text("Microphone access required")
                .font(.caption)
                .foregroundStyle(.orange)
            Button("Open Settings") {
                controller.micPermission.openSystemSettings()
            }
            .font(.caption)
        }
    }
}

/// Simple iOS dictation controller.
@MainActor @Observable
final class IOSDictationController {
    let state = DictationState()
    let micPermission = MicrophonePermissionService()

    private let audioCapture = AudioCaptureService()
    private let transcription = TranscriptionService()

    func setup() async {
        // Request mic permission if needed
        if micPermission.state.needsPrompt {
            _ = await micPermission.requestAccess()
        }
    }

    func toggleRecording() async {
        if state.isRecording {
            await stopRecording()
        } else {
            await startRecording()
        }
    }

    private func startRecording() async {
        // Check permission
        guard micPermission.state.isAuthorized else {
            state.phase = .error(message: "Microphone permission denied")
            return
        }

        // Load model if needed
        let isReady = await transcription.isReady
        if !isReady {
            state.phase = .loadingModel
            do {
                try await transcription.prepare()
            } catch {
                state.phase = .error(message: "Failed to load model: \(error.localizedDescription)")
                return
            }
        }

        // Start recording
        do {
            state.phase = .recording
            try audioCapture.startCapture()
        } catch {
            state.phase = .error(message: "Failed to start recording: \(error.localizedDescription)")
        }
    }

    private func stopRecording() async {
        let (samples, stats) = audioCapture.stopCapture()

        guard stats.sampleCount > 0 else {
            state.phase = .error(message: "No audio recorded")
            return
        }

        state.phase = .transcribing

        do {
            let text = try await transcription.transcribe(samples: samples, sampleRate: stats.sampleRate)
            state.phase = .done(text: text)
        } catch {
            state.phase = .error(message: error.localizedDescription)
        }
    }
}
#endif
