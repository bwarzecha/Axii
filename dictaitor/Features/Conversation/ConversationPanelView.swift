//
//  ConversationPanelView.swift
//  dictaitor
//
//  SwiftUI view for the conversation panel.
//

#if os(macOS)
import SwiftUI

/// Panel view displayed during conversation.
struct ConversationPanelView: View {
    var state: ConversationState
    let hotkeyHint: String

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
                    phaseIndicator
                    Spacer()
                    statusText
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
        }
        .frame(width: 340, height: 88)
    }

    @ViewBuilder
    private var topArea: some View {
        switch state.phase {
        case .idle:
            Text("Press \(hotkeyHint)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .listening:
            audioWaveform
        case .processing:
            Text(state.transcript.isEmpty ? "Processing..." : state.transcript)
                .font(.caption)
                .lineLimit(2)
                .foregroundStyle(.secondary)
        case .responding:
            Text(state.response)
                .font(.caption)
                .lineLimit(2)
                .foregroundStyle(.primary)
        case .done:
            Text(state.transcript.isEmpty ? "No speech detected" : "You: \(state.transcript)")
                .font(.caption)
                .lineLimit(2)
                .foregroundStyle(.secondary)
        case .error:
            Color.clear
        }
    }

    @ViewBuilder
    private var phaseIndicator: some View {
        switch state.phase {
        case .listening:
            HStack(spacing: 4) {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                Text("Agent")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .processing:
            HStack(spacing: 4) {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 8, height: 8)
                Text("Agent")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .responding:
            HStack(spacing: 4) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption2)
                    .foregroundStyle(.blue)
                Text("Agent")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        default:
            HStack(spacing: 4) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("Agent")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch state.phase {
        case .idle:
            Text("Ready")
                .font(.subheadline)
                .foregroundStyle(.secondary)

        case .listening:
            Text("Listening...")
                .font(.subheadline)

        case .processing:
            Text("Thinking...")
                .font(.subheadline)

        case .responding:
            Text("Speaking...")
                .font(.subheadline)

        case .done:
            Text("Done")
                .font(.subheadline)
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
}

#Preview("Idle") {
    ConversationPanelView(
        state: ConversationState(),
        hotkeyHint: "Cmd+Shift+Space"
    )
    .frame(width: 360, height: 100)
    .background(.black.opacity(0.5))
}

#Preview("Listening") {
    let state = ConversationState()
    state.phase = .listening
    state.audioLevel = 0.6
    return ConversationPanelView(
        state: state,
        hotkeyHint: "Cmd+Shift+Space"
    )
    .frame(width: 360, height: 100)
    .background(.black.opacity(0.5))
}

#Preview("Processing") {
    let state = ConversationState()
    state.phase = .processing
    state.transcript = "What's the weather like today?"
    return ConversationPanelView(
        state: state,
        hotkeyHint: "Cmd+Shift+Space"
    )
    .frame(width: 360, height: 100)
    .background(.black.opacity(0.5))
}

#Preview("Responding") {
    let state = ConversationState()
    state.phase = .responding
    state.response = "The weather is sunny with a high of 72 degrees."
    return ConversationPanelView(
        state: state,
        hotkeyHint: "Cmd+Shift+Space"
    )
    .frame(width: 360, height: 100)
    .background(.black.opacity(0.5))
}
#endif
