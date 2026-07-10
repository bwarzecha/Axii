//
//  HistoryDetailPreviews.swift
//  Axii
//
//  Preview-only detail view and sample data for HistoryDetailView.
//  Extracted to keep each file within line limits.
//

#if os(macOS)
import SwiftUI

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
#endif
