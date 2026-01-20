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
    let hotkeyHint: String
    var onMicrophoneSwitch: ((AudioDevice?) -> Void)?

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
            if state.isWaitingForSignal {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("Waiting for signal...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                audioWaveform
            }
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
            if state.isWaitingForSignal {
                Text("Bluetooth warming up")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            } else {
                Text("Listening...")
                    .font(.subheadline)
            }

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

    /// Selected device name for display.
    private var selectedDeviceName: String {
        state.selectedMicrophone?.name ?? "System Default"
    }

    /// Icon for transport type.
    private func transportIcon(for device: AudioDevice?) -> String {
        guard let device = device else { return "mic" }

        switch device.transportType {
        case .bluetooth, .bluetoothLE:
            return "wave.3.right"
        case .usb:
            return "cable.connector"
        case .builtIn:
            return "laptopcomputer"
        case .aggregate, .virtual:
            return "rectangle.stack"
        case .unknown:
            return "mic"
        }
    }

    private var microphonePicker: some View {
        HStack(spacing: 4) {
            Image(systemName: micIcon)
                .font(.caption2)
                .foregroundStyle(micIconColor)
            Menu {
                // System Default option
                Button {
                    if state.selectedMicrophone != nil {
                        onMicrophoneSwitch?(nil)
                    }
                } label: {
                    HStack {
                        Image(systemName: "gear")
                        Text("System Default")
                        if state.selectedMicrophone == nil {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }

                Divider()

                // Available devices
                ForEach(state.availableMicrophones) { device in
                    Button {
                        if device.uid != state.selectedMicrophone?.uid {
                            onMicrophoneSwitch?(device)
                        }
                    } label: {
                        HStack {
                            Image(systemName: transportIcon(for: device))
                            Text(device.name)
                            if device.uid == state.selectedMicrophone?.uid {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(selectedDeviceName)
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

    private var micIcon: String {
        if state.phase == .recording {
            if state.selectedMicrophone?.isBluetooth == true {
                return "wave.3.right"
            }
            return "mic.fill"
        }
        return "mic"
    }

    private var micIconColor: Color {
        if state.phase == .recording {
            if state.isWaitingForSignal {
                return .orange
            }
            return .red
        }
        return .secondary
    }
}

#Preview("Idle") {
    DictationPanelView(
        state: DictationState(),
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
        hotkeyHint: "Control+Shift+Space"
    )
    .frame(width: 360, height: 100)
    .background(.black.opacity(0.5))
}

#Preview("Waiting for Signal") {
    let state = DictationState()
    state.phase = .recording
    state.isWaitingForSignal = true
    return DictationPanelView(
        state: state,
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
