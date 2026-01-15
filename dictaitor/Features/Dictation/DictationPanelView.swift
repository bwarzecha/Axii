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

            VStack(spacing: 12) {
                statusIcon
                statusText
                if state.isRecording {
                    audioLevelBar
                }
                if showMicrophonePicker {
                    microphonePicker
                }
            }
            .padding(20)
        }
        .frame(width: 280, height: dynamicHeight)
    }

    private var showMicrophonePicker: Bool {
        switch state.phase {
        case .idle, .recording, .loadingModel:
            return true
        default:
            return false
        }
    }

    private var dynamicHeight: CGFloat {
        var height: CGFloat = 120
        if state.isRecording { height += 20 }
        if showMicrophonePicker { height += 30 }
        return height
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch state.phase {
        case .idle:
            Image(systemName: "mic")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)

        case .loadingModel:
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 36))
                .foregroundStyle(.blue)
                .symbolEffect(.pulse, options: .repeating, isActive: true)

        case .recording:
            Image(systemName: "mic.fill")
                .font(.system(size: 36))
                .foregroundStyle(.red)
                .symbolEffect(.pulse, options: .repeating, isActive: true)

        case .transcribing:
            ProgressView()
                .scaleEffect(1.5)

        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.green)

        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch state.phase {
        case .idle:
            Text("Press \(hotkeyHint)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

        case .loadingModel:
            Text("Loading model...")
                .font(.subheadline)
                .foregroundStyle(.secondary)

        case .recording:
            Text("Listening...")
                .font(.headline)

        case .transcribing:
            Text("Transcribing...")
                .font(.headline)

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

    private var audioLevelBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(.gray.opacity(0.3))
                RoundedRectangle(cornerRadius: 3)
                    .fill(.green.gradient)
                    .frame(width: geo.size.width * CGFloat(state.audioLevel))
            }
        }
        .frame(height: 6)
        .padding(.horizontal, 20)
    }

    private var microphonePicker: some View {
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
                Image(systemName: "mic")
                    .font(.caption2)
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

#Preview("Idle") {
    DictationPanelView(
        state: DictationState(),
        microphoneSelection: MicrophoneSelectionService(),
        hotkeyHint: "Control+Shift+Space"
    )
    .frame(width: 300, height: 200)
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
    .frame(width: 300, height: 200)
    .background(.black.opacity(0.5))
}
#endif
