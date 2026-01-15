//
//  DictationPanelView.swift
//  dictaitor
//
//  SwiftUI view for the dictation panel.
//

#if os(macOS)
import SwiftUI

/// Panel view displayed during dictation.
struct DictationPanelView: View {
    var state: DictationState
    var microphoneSelection: MicrophoneSelectionService
    let hotkeyHint: String
    var onMicrophoneSwitch: ((AudioInputDevice) -> Void)?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(0.2), lineWidth: 1)
                )

            VStack(spacing: 0) {
                topArea
                    .frame(height: 32)
                    .padding(.top, 10)
                Spacer(minLength: 0)
                HStack {
                    if showMicrophonePicker {
                        microphonePicker
                    }
                    Spacer()
                    statusText
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
        }
        .frame(width: 340, height: 88)
    }

    private var showMicrophonePicker: Bool {
        switch state.phase {
        case .idle, .recording, .loadingModel:
            return true
        default:
            return false
        }
    }

    @ViewBuilder
    private var topArea: some View {
        switch state.phase {
        case .idle, .loadingModel:
            Text("Press \(hotkeyHint)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .recording:
            audioWaveform
        default:
            Color.clear
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch state.phase {
        case .idle:
            Text("Ready")
                .font(.subheadline)
                .foregroundStyle(.secondary)

        case .loadingModel:
            Text("Loading...")
                .font(.subheadline)
                .foregroundStyle(.secondary)

        case .recording:
            Text("Listening...")
                .font(.subheadline)

        case .transcribing:
            Text("Transcribing...")
                .font(.subheadline)

        case .done(let text):
            Text(text)
                .font(.caption)
                .lineLimit(2)
                .foregroundStyle(.secondary)

        case .error(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private var audioWaveform: some View {
        SpectrumView(spectrum: state.spectrum, level: CGFloat(state.audioLevel))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 8)
    }

    private var microphonePicker: some View {
        HStack(spacing: 4) {
            Image(systemName: state.phase == .recording ? "mic.fill" : "mic")
                .font(.caption2)
                .foregroundStyle(state.phase == .recording ? Color.red : Color.secondary)
            Menu {
                ForEach(microphoneSelection.availableDevices) { device in
                    Button {
                        if device != microphoneSelection.selectedDevice {
                            onMicrophoneSwitch?(device)
                        }
                    } label: {
                        HStack {
                            Text(device.name)
                            if device == microphoneSelection.selectedDevice {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(microphoneSelection.selectedDevice.name)
                        .font(.caption)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}

#Preview("Idle") {
    DictationPanelView(
        state: DictationState(),
        microphoneSelection: MicrophoneSelectionService(),
        hotkeyHint: "Control+Shift+Space"
    )
    .frame(width: 360, height: 100)
    .background(.black.opacity(0.5))
}

#Preview("Recording") {
    let state = DictationState()
    state.phase = .recording
    state.audioLevel = 0.6
    return DictationPanelView(
        state: state,
        microphoneSelection: MicrophoneSelectionService(),
        hotkeyHint: "Control+Shift+Space"
    )
    .frame(width: 360, height: 100)
    .background(.black.opacity(0.5))
}

#Preview("Spectrum Animated") {
    struct AnimatedPreview: View {
        let state = DictationState()
        @State private var timer: Timer?
        @State private var phase: Float = 0

        var body: some View {
            DictationPanelView(
                state: state,
                microphoneSelection: MicrophoneSelectionService(),
                hotkeyHint: "Control+Shift+Space"
            )
            .frame(width: 360, height: 100)
            .background(.black.opacity(0.8))
            .onAppear {
                state.phase = .recording
                timer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { _ in
                    phase += 0.3
                    let level = Float.random(in: 0.3...0.9)
                    state.audioLevel = level
                    // Simulate spectrum with flowing wave
                    state.spectrum = (0..<64).map { i in
                        let wave = sin(Float(i) * 0.15 + phase) * 0.5 + 0.5
                        let noise = Float.random(in: 0.8...1.2)
                        return wave * level * noise
                    }
                }
            }
            .onDisappear {
                timer?.invalidate()
            }
        }
    }
    return AnimatedPreview()
}
#endif
