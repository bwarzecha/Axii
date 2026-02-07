//
//  ModeConversationView.swift
//  Axii
//
//  Fixed 400x400 message-list layout for conversation-like modes.
//  Uses ModeRuntimeState and ModeConfig instead of ConversationState.
//

#if os(macOS)
import SwiftUI

/// Conversation-style panel view with message list and visualization.
struct ModeConversationView: View {
    let state: ModeRuntimeState
    let config: ModeConfig
    let hotkeyHint: String
    var onMicrophoneSwitch: ((AudioDevice?) -> Void)? = nil
    var onCopy: ((String) -> Void)? = nil

    var body: some View {
        ZStack {
            ModePanelBackground(cornerRadius: 16)

            VStack(spacing: 0) {
                statusBar

                Divider()

                visualizationArea
                    .frame(height: 60)

                Divider()

                messagesArea

                Divider()

                footerSection

                hintBar
            }
        }
        .frame(width: 400, height: 400)
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack {
            HStack(spacing: 6) {
                phaseIndicator
                Text("Agent")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            statusText
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var phaseIndicator: some View {
        switch state.phase {
        case .recording:
            Circle()
                .fill(state.isWaitingForSignal ? .orange : .red)
                .frame(width: 8, height: 8)
        case .processing, .transcribing:
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: 8, height: 8)
        default:
            Circle()
                .fill(Color.secondary)
                .frame(width: 8, height: 8)
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch state.phase {
        case .recording:
            Text("Listening...")
                .font(.subheadline)
                .foregroundStyle(.primary)
        case .processing, .transcribing:
            Text("Thinking...")
                .font(.subheadline)
                .foregroundStyle(.primary)
        case .done:
            Text("Done")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .idle:
            Text("Ready")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .error:
            Text("Error")
                .font(.subheadline)
                .foregroundStyle(.red)
        case .preparing:
            Text("Preparing...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Visualization Area

    @ViewBuilder
    private var visualizationArea: some View {
        switch state.phase {
        case .recording:
            HStack(spacing: 12) {
                RadialBarIndicator(
                    level: state.isWaitingForSignal ? 0.3 : CGFloat(state.audioLevel),
                    noSignal: state.isWaitingForSignal,
                    spinning: state.isWaitingForSignal,
                    size: 50
                )
                Text("Listening...")
                    .font(.callout)
                    .foregroundStyle(state.isWaitingForSignal ? .secondary : .primary)
            }
        case .processing, .transcribing:
            HStack(spacing: 12) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Thinking...")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .done:
            HStack(spacing: 12) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                Text("Ready to continue")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .idle, .preparing:
            HStack(spacing: 12) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                Text(state.messages.isEmpty ? "Ready to chat" : "Ready to continue")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .error(let message):
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.red)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
    }

    // MARK: - Messages Area

    private var messagesArea: some View {
        Group {
            if state.messages.isEmpty {
                emptyMessagesView
            } else {
                messagesList
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

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(state.messages) { message in
                        ModeMessageBubble(message: message)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("modeMessagesBottom")
                }
                .padding()
            }
            .onChange(of: state.messages.count) { _, _ in
                withAnimation {
                    proxy.scrollTo("modeMessagesBottom", anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Footer Section

    private var footerSection: some View {
        HStack {
            ModeMicrophonePicker(
                availableMicrophones: state.availableMicrophones,
                selectedMicrophone: state.selectedMicrophone,
                onSelect: { onMicrophoneSwitch?($0) }
            )
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Hint Bar

    private var hintBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                ModeKeyCap(text: hotkeyHint)
                Text(hotkeyActionText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 4) {
                ModeKeyCap(text: "esc")
                Text("Close")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.05))
    }

    // MARK: - Computed Helpers

    private var hotkeyActionText: String {
        switch state.phase {
        case .recording: return "Finish"
        default: return "Speak"
        }
    }
}
#endif
