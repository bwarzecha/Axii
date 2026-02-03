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

    @State private var interaction: Interaction?
    @State private var isLoading = true
    @State private var error: String?
    @State private var audioPlayer: AVAudioPlayer?
    @State private var audioPlayer2: AVAudioPlayer?  // For "Both" mode
    @State private var audioDelegate: AudioPlayerDelegate?
    @State private var isPlaying = false
    @State private var showCopied = false
    @State private var audioError: String?
    @State private var selectedAudioTrack: MeetingAudioTrack = .both

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

    private func meetingContent(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Meeting stats
            HStack(spacing: 16) {
                Label(formattedDuration(meeting.duration), systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Label("\(meeting.wordCount) words", systemImage: "text.word.spacing")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let appName = meeting.appName {
                    Label(appName, systemImage: "app.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // Segments
            ForEach(meeting.segments) { segment in
                meetingSegmentView(segment)
            }
        }
    }

    private func meetingSegmentView(_ segment: MeetingSegment) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: segment.isFromMicrophone ? "person.fill" : "person.wave.2.fill")
                .foregroundStyle(segment.isFromMicrophone ? .blue : .green)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(segment.displayName)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(segment.isFromMicrophone ? .blue : .green)

                    Text(formatTimestamp(segment.startTime))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(segment.text)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
    }


    private func hasMeetingAudio(_ meeting: Meeting) -> Bool {
        switch selectedAudioTrack {
        case .you:
            return meeting.micRecording != nil
        case .remote:
            return meeting.systemRecording != nil
        case .both:
            return meeting.micRecording != nil || meeting.systemRecording != nil
        }
    }

    private func toggleMeetingAudio(_ meeting: Meeting) {
        if isPlaying {
            stopAudio()
        } else {
            playMeetingAudio(meeting)
        }
    }

    private func playMeetingAudio(_ meeting: Meeting) {
        audioError = nil

        switch selectedAudioTrack {
        case .you:
            guard let recording = meeting.micRecording,
                  let url = historyService.getAudioURL(recording, for: meeting.id) else { return }
            playAudio(url: url)

        case .remote:
            guard let recording = meeting.systemRecording,
                  let url = historyService.getAudioURL(recording, for: meeting.id) else { return }
            playAudio(url: url)

        case .both:
            // Play both tracks simultaneously
            let micURL = meeting.micRecording.flatMap { historyService.getAudioURL($0, for: meeting.id) }
            let sysURL = meeting.systemRecording.flatMap { historyService.getAudioURL($0, for: meeting.id) }

            guard micURL != nil || sysURL != nil else { return }

            do {
                if let micURL {
                    let player1 = try AVAudioPlayer(contentsOf: micURL)
                    player1.prepareToPlay()
                    audioPlayer = player1
                }

                if let sysURL {
                    let player2 = try AVAudioPlayer(contentsOf: sysURL)
                    player2.prepareToPlay()
                    audioPlayer2 = player2
                }

                // Set delegate on first available player for finish callback
                let delegate = AudioPlayerDelegate { [self] in
                    isPlaying = false
                }
                audioDelegate = delegate
                audioPlayer?.delegate = delegate

                // Start both players
                audioPlayer?.play()
                audioPlayer2?.play()
                isPlaying = true
            } catch {
                audioError = "Cannot play audio: \(error.localizedDescription)"
            }
        }
    }

    private func getMeetingAudioURL(_ meeting: Meeting) -> URL? {
        switch selectedAudioTrack {
        case .you:
            guard let recording = meeting.micRecording else { return nil }
            return historyService.getAudioURL(recording, for: meeting.id)
        case .remote:
            guard let recording = meeting.systemRecording else { return nil }
            return historyService.getAudioURL(recording, for: meeting.id)
        case .both:
            if let recording = meeting.micRecording {
                return historyService.getAudioURL(recording, for: meeting.id)
            }
            if let recording = meeting.systemRecording {
                return historyService.getAudioURL(recording, for: meeting.id)
            }
            return nil
        }
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func formatTimestamp(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
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
        VStack(alignment: .leading, spacing: 0) {
            // Fixed header with actions
            VStack(alignment: .leading, spacing: 8) {
                HStack {
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

                    Spacer()

                    HStack(spacing: 8) {
                        Button {} label: {
                            Label("Play", systemImage: "play.fill")
                        }
                        Button {} label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        Button(role: .destructive) {} label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .padding()

            Divider()

            // Scrollable content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
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

                    case .meeting(let meeting):
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(meeting.segments) { segment in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: segment.isFromMicrophone ? "person.fill" : "person.wave.2.fill")
                                        .foregroundStyle(segment.isFromMicrophone ? .blue : .green)
                                        .frame(width: 20)

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(segment.displayName)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(segment.text)
                                            .textSelection(.enabled)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }
                .padding()
            }
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
