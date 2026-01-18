//
//  ConversationPanelView.swift
//  dictaitor
//
//  SwiftUI view for the conversation panel.
//

#if os(macOS)
import SwiftUI

/// Panel view displayed during conversation - unified layout with visualization and chat.
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
                // Status bar at top
                statusBar

                Divider()

                // Visualization area (always visible, fixed height)
                visualizationArea
                    .frame(height: 60)

                Divider()

                // Messages list (scrollable, takes remaining space)
                messagesArea

                Divider()

                // Hint bar at bottom
                hintBar
            }
        }
        .frame(width: 400, height: 400)
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack {
            phaseIndicator
            Spacer()
            statusText
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var phaseIndicator: some View {
        HStack(spacing: 6) {
            switch state.phase {
            case .listening:
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
            case .processing:
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 8, height: 8)
            case .responding:
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption2)
                    .foregroundStyle(.blue)
            default:
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text("Agent")
                .font(.caption2)
                .foregroundStyle(.secondary)
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

    // MARK: - Visualization Area

    @ViewBuilder
    private var visualizationArea: some View {
        switch state.phase {
        case .listening:
            SpectrumView(spectrum: state.spectrum, level: CGFloat(state.audioLevel))
                .padding(.horizontal, 16)
        case .processing:
            VStack(spacing: 4) {
                if !state.transcript.isEmpty {
                    Text(state.transcript)
                        .font(.callout)
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                } else {
                    ProgressView()
                    Text("Processing...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
        case .responding:
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(.blue)
                    .symbolEffect(.variableColor.iterative)
                Text("Speaking response...")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .idle, .done:
            if state.messages.isEmpty {
                Text("Press \(hotkeyHint) to start")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Press \(hotkeyHint) to continue")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.red)
        }
    }

    // MARK: - Messages Area

    private var messagesArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if state.messages.isEmpty {
                    emptyMessagesView
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(state.messages) { message in
                            MessageBubbleView(message: message)
                        }
                        // Invisible anchor at the bottom for reliable scrolling
                        Color.clear
                            .frame(height: 1)
                            .id("messagesBottom")
                    }
                    .padding()
                }
            }
            .onChange(of: state.messages.count) { _, _ in
                withAnimation {
                    proxy.scrollTo("messagesBottom", anchor: .bottom)
                }
            }
        }
    }

    private var emptyMessagesView: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.largeTitle)
                .foregroundStyle(.quaternary)
            Text("No messages yet")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Hint Bar

    private var hintBar: some View {
        HStack {
            Text(hintText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("ESC to close")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var hintText: String {
        switch state.phase {
        case .listening:
            return "Press \(hotkeyHint) to stop"
        default:
            return "Press \(hotkeyHint) to speak"
        }
    }
}

// MARK: - Message Bubble View

/// A single message bubble in the conversation
struct MessageBubbleView: View {
    let message: DisplayMessage

    private var isUser: Bool {
        message.role == .user
    }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 40) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Text(isUser ? "You" : "Assistant")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(message.content)
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(isUser ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.15))
                    )
                    .foregroundStyle(.primary)
            }

            if !isUser { Spacer(minLength: 40) }
        }
    }
}

// MARK: - Previews

#Preview("Idle - Empty") {
    ConversationPanelView(
        state: ConversationState(),
        hotkeyHint: "Cmd+Shift+Space"
    )
    .background(.black.opacity(0.5))
}

#Preview("Listening") {
    let state = ConversationState()
    state.phase = .listening
    state.audioLevel = 0.6
    state.spectrum = Array(repeating: 0.3, count: 32)
    return ConversationPanelView(
        state: state,
        hotkeyHint: "Cmd+Shift+Space"
    )
    .background(.black.opacity(0.5))
}

#Preview("Processing") {
    let state = ConversationState()
    state.phase = .processing
    state.transcript = "What's the weather like today?"
    state.messages = [
        DisplayMessage(role: .user, content: "What's the weather like today?")
    ]
    return ConversationPanelView(
        state: state,
        hotkeyHint: "Cmd+Shift+Space"
    )
    .background(.black.opacity(0.5))
}

#Preview("Multi-turn Conversation") {
    let state = ConversationState()
    state.messages = [
        DisplayMessage(role: .user, content: "What's the weather like today?"),
        DisplayMessage(role: .assistant, content: "I don't have access to real-time weather data, but I'd be happy to help if you tell me your location!"),
        DisplayMessage(role: .user, content: "I'm in San Francisco"),
        DisplayMessage(role: .assistant, content: "San Francisco typically has mild weather year-round. For current conditions, I'd recommend checking a weather app.")
    ]
    state.phase = .idle
    return ConversationPanelView(
        state: state,
        hotkeyHint: "Cmd+Shift+Space"
    )
    .background(.black.opacity(0.5))
}

#Preview("Message Bubble - User") {
    MessageBubbleView(message: DisplayMessage(role: .user, content: "What's the weather like today?"))
        .padding()
        .frame(width: 350)
}

#Preview("Message Bubble - Assistant") {
    MessageBubbleView(message: DisplayMessage(role: .assistant, content: "The weather is sunny with a high of 72 degrees Fahrenheit."))
        .padding()
        .frame(width: 350)
}
#endif
