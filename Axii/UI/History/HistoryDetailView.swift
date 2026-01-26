//
//  HistoryDetailView.swift
//  Axii
//
//  Detail view for a selected interaction.
//

#if os(macOS)
import SwiftUI
import AVFoundation

struct HistoryDetailView: View {
    let metadata: InteractionMetadata
    let historyService: HistoryService
    let onDelete: () -> Void

    @State private var interaction: Interaction?
    @State private var isLoading = true
    @State private var error: String?
    @State private var audioPlayer: AVAudioPlayer?
    @State private var audioDelegate: AudioPlayerDelegate?
    @State private var isPlaying = false
    @State private var showCopied = false
    @State private var audioError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let interaction {
                contentView(for: interaction)
            }
        }
        .padding()
        .task(id: metadata.id) {
            await loadInteraction()
        }
        .onDisappear {
            stopAudio()
        }
    }

    @ViewBuilder
    private func contentView(for interaction: Interaction) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                headerView

                Divider()

                // Content based on type
                switch interaction {
                case .transcription(let transcription):
                    transcriptionContent(transcription)
                case .conversation(let conversation):
                    conversationContent(conversation)
                }

                Spacer()

                // Actions
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        if let audioURL = getAudioURL(for: interaction) {
                            Button {
                                toggleAudio(url: audioURL)
                            } label: {
                                Label(isPlaying ? "Stop" : "Play Audio", systemImage: isPlaying ? "stop.fill" : "play.fill")
                            }
                        }

                        Button {
                            copyText(from: interaction)
                        } label: {
                            Label(showCopied ? "Copied" : "Copy", systemImage: showCopied ? "checkmark" : "doc.on.doc")
                        }

                        Spacer()

                        Button(role: .destructive) {
                            deleteInteraction()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }

                    if let audioError {
                        Text(audioError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: metadata.type == .transcription ? "mic.fill" : "bubble.left.and.bubble.right.fill")
                    .foregroundStyle(metadata.type == .transcription ? .blue : .purple)
                Text(metadata.type == .transcription ? "Transcription" : "Conversation")
                    .font(.headline)
            }

            Text(formattedDate)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func transcriptionContent(_ transcription: Transcription) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(transcription.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let pastedTo = transcription.pastedTo {
                HStack {
                    Image(systemName: "arrow.right.doc.on.clipboard")
                        .foregroundStyle(.secondary)
                    Text("Pasted to: \(appName(for: pastedTo))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Focus context section
            if let context = transcription.focusContext {
                focusContextView(context)
            }
        }
    }

    @ViewBuilder
    private func focusContextView(_ context: FocusContext) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            Text("Context")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fontWeight(.semibold)

            if let appName = context.appName {
                HStack(spacing: 4) {
                    Image(systemName: "app.fill")
                        .foregroundStyle(.secondary)
                    Text(appName)
                        .font(.caption)
                }
            }

            if let windowTitle = context.windowTitle, !windowTitle.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "macwindow")
                        .foregroundStyle(.secondary)
                    Text(windowTitle)
                        .font(.caption)
                        .lineLimit(2)
                }
            }

            if let text = context.surroundingText {
                VStack(alignment: .leading, spacing: 4) {
                    if !text.before.isEmpty {
                        Text("Before cursor:")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(text.before.suffix(100))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    if !text.selected.isEmpty {
                        Text("Selected:")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(text.selected)
                            .font(.caption)
                            .foregroundStyle(.blue)
                            .lineLimit(2)
                    }
                    if !text.after.isEmpty {
                        Text("After cursor:")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(text.after.prefix(100))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                .padding(8)
                .background(.quaternary.opacity(0.5))
                .cornerRadius(6)
            }
        }
    }

    private func conversationContent(_ conversation: Conversation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(conversation.messages) { message in
                messageView(message)
            }
        }
    }

    private func messageView(_ message: Message) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: message.role == .user ? "person.fill" : "cpu")
                .foregroundStyle(message.role == .user ? .blue : .purple)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                Text(message.role == .user ? "You" : "Assistant")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(message.content)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: metadata.createdAt)
    }

    private func appName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundleID
    }

    private func loadInteraction() async {
        isLoading = true
        error = nil

        do {
            interaction = try await historyService.loadInteraction(id: metadata.id)
        } catch {
            self.error = "Failed to load: \(error.localizedDescription)"
        }

        isLoading = false
    }

    private func getAudioURL(for interaction: Interaction) -> URL? {
        switch interaction {
        case .transcription(let transcription):
            guard let recording = transcription.audioRecording else { return nil }
            return historyService.getAudioURL(recording, for: transcription.id)
        case .conversation(let conversation):
            guard let recording = conversation.audioRecordings.first else { return nil }
            return historyService.getAudioURL(recording, for: conversation.id)
        }
    }

    private func toggleAudio(url: URL) {
        if isPlaying {
            stopAudio()
        } else {
            playAudio(url: url)
        }
    }

    private func playAudio(url: URL) {
        audioError = nil
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            let delegate = AudioPlayerDelegate { [self] in
                isPlaying = false
            }
            player.delegate = delegate
            player.prepareToPlay()

            guard player.play() else {
                audioError = "Failed to start playback"
                return
            }

            // Retain both player and delegate
            audioPlayer = player
            audioDelegate = delegate
            isPlaying = true
        } catch {
            audioError = "Cannot play audio: \(error.localizedDescription)"
        }
    }

    private func stopAudio() {
        audioPlayer?.stop()
        audioPlayer = nil
        audioDelegate = nil
        isPlaying = false
    }

    private func deleteInteraction() {
        Task {
            do {
                try await historyService.delete(id: metadata.id)
                onDelete()
            } catch {
                print("Failed to delete: \(error)")
            }
        }
    }

    private func copyText(from interaction: Interaction) {
        let textToCopy: String
        switch interaction {
        case .transcription(let transcription):
            textToCopy = transcription.text
        case .conversation(let conversation):
            textToCopy = conversation.messages.map { message in
                let role = message.role == .user ? "You" : "Assistant"
                return "\(role): \(message.content)"
            }.joined(separator: "\n\n")
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textToCopy, forType: .string)

        showCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            showCopied = false
        }
    }
}

/// Helper class to handle AVAudioPlayer delegate callbacks
private class AudioPlayerDelegate: NSObject, AVAudioPlayerDelegate {
    let onFinish: () -> Void

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            onFinish()
        }
    }
}
#endif

// MARK: - Preview

/// Preview-only detail view that shows static content without loading from disk
private struct PreviewDetailView: View {
    let metadata: InteractionMetadata
    let interaction: Interaction

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: metadata.type == .transcription ? "mic.fill" : "bubble.left.and.bubble.right.fill")
                            .foregroundStyle(metadata.type == .transcription ? .blue : .purple)
                        Text(metadata.type == .transcription ? "Transcription" : "Conversation")
                            .font(.headline)
                    }

                    Text(formattedDate)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                // Content
                switch interaction {
                case .transcription(let transcription):
                    VStack(alignment: .leading, spacing: 12) {
                        Text(transcription.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if let pastedTo = transcription.pastedTo {
                            HStack {
                                Image(systemName: "arrow.right.doc.on.clipboard")
                                    .foregroundStyle(.secondary)
                                Text("Pasted to: \(pastedTo)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                case .conversation(let conversation):
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(conversation.messages) { message in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: message.role == .user ? "person.fill" : "cpu")
                                    .foregroundStyle(message.role == .user ? .blue : .purple)
                                    .frame(width: 20)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(message.role == .user ? "You" : "Assistant")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(message.content)
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Spacer()

                // Actions
                HStack {
                    Button {
                    } label: {
                        Label("Play Audio", systemImage: "play.fill")
                    }

                    Spacer()

                    Button(role: .destructive) {
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .padding()
        }
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: metadata.createdAt)
    }
}

#Preview("Transcription Detail") {
    PreviewDetailView(
        metadata: .previewTranscription,
        interaction: .previewTranscription
    )
    .frame(width: 400, height: 300)
}

#Preview("Conversation Detail") {
    PreviewDetailView(
        metadata: .previewConversation,
        interaction: .previewConversation
    )
    .frame(width: 400, height: 400)
}

// MARK: - Preview Data

extension Interaction {
    static let previewTranscription = Interaction.transcription(Transcription(
        id: InteractionMetadata.previewTranscription.id,
        text: "Testing one two three four five. This is a sample transcription that was captured and saved to history.",
        audioRecording: AudioRecording(
            filename: "audio/sample.wav",
            duration: 3.5,
            sampleRate: 48000
        ),
        pastedTo: "com.apple.Notes",
        createdAt: Date().addingTimeInterval(-120)
    ))

    static let previewConversation = Interaction.conversation(Conversation(
        id: InteractionMetadata.previewConversation.id,
        title: "Weather Chat",
        messages: [
            Message(role: .user, content: "What's the weather like today?"),
            Message(role: .assistant, content: "I don't have access to real-time weather data, but I'd be happy to help if you tell me your location!"),
            Message(role: .user, content: "I'm in San Francisco"),
            Message(role: .assistant, content: "San Francisco typically has mild weather. For current conditions, I'd recommend checking a weather app or website.")
        ],
        createdAt: Date().addingTimeInterval(-3600)
    ))
}
