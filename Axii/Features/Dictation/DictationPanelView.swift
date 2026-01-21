//
//  DictationPanelView.swift
//  Axii
//
//  SwiftUI view for the dictation panel.
//

#if os(macOS)
import SwiftUI

/// Panel view displayed during dictation - vertical layout like macOS dictation.
struct DictationPanelView: View {
    var state: DictationState
    let hotkeyHint: String
    var onMicrophoneSwitch: ((AudioDevice?) -> Void)?

    private let panelWidth: CGFloat = 200
    private let panelHeight: CGFloat = 220

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(.primary.opacity(0.1), lineWidth: 1)
                )

            VStack(spacing: 8) {
                // Main visualization area (fixed height)
                mainContent
                    .frame(height: 120)

                // Status/mic row (fixed height to prevent shifting)
                statusRow
                    .frame(height: 20)

                // Keyboard hints (fixed height to prevent shifting)
                keyboardHints
                    .frame(height: 20)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
        }
        .frame(width: panelWidth, height: panelHeight)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder
    private var mainContent: some View {
        ZStack {
            // Single RadialBarIndicator that stays in place - only parameters change
            RadialBarIndicator(
                level: indicatorLevel,
                noSignal: indicatorNoSignal,
                spinning: indicatorSpinning,
                colorOverride: indicatorColor,
                size: 120
            )
            .opacity(indicatorOpacity)

            // Overlays for specific states
            overlay
        }
    }

    private var indicatorLevel: CGFloat {
        switch state.phase {
        case .idle, .loadingModel:
            return 0
        case .recording:
            return state.isWaitingForSignal ? 0.3 : CGFloat(state.audioLevel)
        case .transcribing:
            return 0.5
        case .done:
            return 1.0
        case .error:
            return 0
        }
    }

    private var indicatorNoSignal: Bool {
        if case .error = state.phase { return true }
        return false
    }

    private var indicatorSpinning: Bool {
        if case .recording = state.phase {
            return state.isWaitingForSignal
        }
        return false
    }

    private var indicatorColor: Color? {
        if case .done = state.phase { return .green }
        return nil
    }

    private var indicatorOpacity: Double {
        switch state.phase {
        case .idle, .loadingModel:
            return 0.5
        case .transcribing:
            return 0.6
        case .error:
            return 0.3
        default:
            return 1.0
        }
    }

    @ViewBuilder
    private var overlay: some View {
        switch state.phase {
        case .recording where state.isWaitingForSignal:
            Text("Warming up...")
                .font(.caption2)
                .foregroundStyle(.secondary)

        case .transcribing:
            ProgressView()
                .scaleEffect(0.8)

        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)

        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.red)

        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch state.phase {
        case .idle, .loadingModel, .recording:
            microphonePicker

        case .transcribing:
            Text("Transcribing...")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .done(let text):
            Text(text)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.secondary)

        case .error(let message):
            Text(message)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var keyboardHints: some View {
        switch state.phase {
        case .idle, .loadingModel:
            HStack(spacing: 4) {
                KeyCap(hotkeyHint)
                Text("to start")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

        case .recording:
            // Always show both hints to prevent layout shift
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    KeyCap(hotkeyHint)
                    Text("Finish")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    KeyCap("esc")
                    Text("Cancel")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

        case .error:
            // Match recording layout for consistency
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    KeyCap(hotkeyHint)
                    Text("Retry")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    KeyCap("esc")
                    Text("Dismiss")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

        default:
            Color.clear
        }
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
                Image(systemName: "mic")
                    .font(.caption)
                Text("Mic: \(shortDeviceName)")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// Short device name for display.
    private var shortDeviceName: String {
        if let device = state.selectedMicrophone {
            // Shorten common names
            if device.name.contains("MacBook") { return "Built-in" }
            if device.name.contains("Built-in") { return "Built-in" }
            if device.name.count > 15 {
                return String(device.name.prefix(12)) + "..."
            }
            return device.name
        }
        return "Default"
    }

}

// MARK: - Key Cap View

/// Styled keyboard key cap.
private struct KeyCap: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.primary)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(.primary.opacity(0.15), lineWidth: 0.5)
            )
    }
}

#Preview("Idle") {
    DictationPanelView(
        state: DictationState(),
        hotkeyHint: "⌃⇧␣"
    )
    .padding(20)
    .background(.black.opacity(0.5))
}

#Preview("Recording") {
    let state = DictationState()
    state.phase = .recording
    state.audioLevel = 0.6
    return DictationPanelView(
        state: state,
        hotkeyHint: "⌃⇧␣"
    )
    .padding(20)
    .background(.black.opacity(0.5))
}

#Preview("Recording Animated") {
    struct AnimatedPreview: View {
        let state = DictationState()
        @State private var timer: Timer?
        @State private var phase: Float = 0

        var body: some View {
            DictationPanelView(
                state: state,
                hotkeyHint: "⌃⇧␣"
            )
            .padding(20)
            .background(.black.opacity(0.8))
            .onAppear {
                state.phase = .recording
                timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                    phase += 0.2
                    let base = sin(phase) * 0.3 + 0.5
                    let burst = sin(phase * 3) * 0.15
                    let noise = Float.random(in: -0.1...0.1)
                    state.audioLevel = max(0.1, min(1, base + burst + noise))
                }
            }
            .onDisappear {
                timer?.invalidate()
            }
        }
    }
    return AnimatedPreview()
}

#Preview("Transcribing") {
    let state = DictationState()
    state.phase = .transcribing
    return DictationPanelView(
        state: state,
        hotkeyHint: "⌃⇧␣"
    )
    .padding(20)
    .background(.black.opacity(0.5))
}
#endif
