//
//  HistoryDetailView.swift
//  Axii
//
//  Detail view for a selected interaction.
//

#if os(macOS)
import SwiftUI
import AVFoundation

/// Audio track selection for meeting playback
enum MeetingAudioTrack: String, CaseIterable {
    case you = "You"
    case remote = "Remote"
    case both = "Both"
}

struct HistoryDetailView: View {
    let metadata: InteractionMetadata
    let historyService: HistoryService
    let onDelete: () -> Void
    /// Enables the meeting Re-transcribe action; nil hides it (previews).
    var retranscriber: MeetingRetranscriptionService? = nil

    // Shared with HistoryDetailMeetingSection.swift (internal, not private).
    @State var interaction: Interaction?
    @State private var isLoading = true
    @State private var error: String?
    @State var audioPlayer: AVAudioPlayer?
    @State var audioPlayer2: AVAudioPlayer?  // For "Both" mode
    @State var audioDelegate: AudioPlayerDelegate?
    @State var isPlaying = false
    @State private var showCopied = false
    @State var audioError: String?
    @State var selectedAudioTrack: MeetingAudioTrack = .both
    @State var isRetranscribing = false
    @State var retranscribeProgress: Double = 0
    @State var retranscribeStatus = ""

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
        VStack(alignment: .leading, spacing: 0) {
            // Fixed header with actions (always visible)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    headerView

                    Spacer()

                    // Action buttons
                    HStack(spacing: 8) {
                        if case .meeting(let meeting) = interaction {
                            if hasMeetingAudio(meeting) {
                                Button {
                                    toggleMeetingAudio(meeting)
                                } label: {
                                    Label(isPlaying ? "Stop" : "Play", systemImage: isPlaying ? "stop.fill" : "play.fill")
                                }
                            }
                            retranscribeControl(for: meeting)
                        } else if let audioURL = getAudioURL(for: interaction) {
                            Button {
                                toggleAudio(url: audioURL)
                            } label: {
                                Label(isPlaying ? "Stop" : "Play", systemImage: isPlaying ? "stop.fill" : "play.fill")
                            }
                        }

                        Button {
                            copyText(from: interaction)
                        } label: {
                            Label(showCopied ? "Copied" : "Copy", systemImage: showCopied ? "checkmark" : "doc.on.doc")
                        }

                        Button(role: .destructive) {
                            deleteInteraction()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }

                // Meeting audio track picker (below header, still fixed)
                if case .meeting(let meeting) = interaction {
                    HStack(spacing: 8) {
                        Picker("", selection: $selectedAudioTrack) {
                            ForEach(MeetingAudioTrack.allCases, id: \.self) { track in
                                Text(track.rawValue).tag(track)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 200)
                        .onChange(of: selectedAudioTrack) { _, _ in
                            stopAudio()
                        }

                        if !hasMeetingAudio(meeting) {
                            Text("No audio")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let audioError {
                    Text(audioError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Divider()
                .padding(.top, 8)

            // Scrollable content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch interaction {
                    case .transcription(let transcription):
                        transcriptionContent(transcription)
                    case .conversation(let conversation):
                        conversationContent(conversation)
                    case .meeting(let meeting):
                        meetingContent(meeting)
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: headerIcon)
                    .foregroundStyle(headerColor)
                Text(headerTitle)
                    .font(.headline)
            }

            Text(formattedDate)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var headerIcon: String {
        switch metadata.type {
        case .transcription: return "mic.fill"
        case .conversation: return "bubble.left.and.bubble.right.fill"
        case .meeting: return "person.2.fill"
        }
    }

    private var headerColor: Color {
        switch metadata.type {
        case .transcription: return .blue
        case .conversation: return .purple
        case .meeting: return .orange
        }
    }

    private var headerTitle: String {
        switch metadata.type {
        case .transcription: return "Transcription"
        case .conversation: return "Conversation"
        case .meeting: return "Meeting"
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

    // Meeting content, playback, and re-transcription live in
    // HistoryDetailMeetingSection.swift.

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
        case .meeting(let meeting):
            // Prefer mic recording for playback
            if let recording = meeting.micRecording {
                return historyService.getAudioURL(recording, for: meeting.id)
            }
            if let recording = meeting.systemRecording {
                return historyService.getAudioURL(recording, for: meeting.id)
            }
            return nil
        }
    }

    private func toggleAudio(url: URL) {
        if isPlaying {
            stopAudio()
        } else {
            playAudio(url: url)
        }
    }

    func playAudio(url: URL) {
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

    func stopAudio() {
        audioPlayer?.stop()
        audioPlayer = nil
        audioPlayer2?.stop()
        audioPlayer2 = nil
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
        case .meeting(let meeting):
            textToCopy = meeting.fullText
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textToCopy, forType: .string)

        showCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            showCopied = false
        }
    }
}

/// Helper class to handle AVAudioPlayer delegate callbacks.
/// Internal: also used by HistoryDetailMeetingSection.swift.
class AudioPlayerDelegate: NSObject, AVAudioPlayerDelegate {
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
