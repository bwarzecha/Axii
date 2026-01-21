//
//  HistoryRowView.swift
//  Axii
//
//  List row for displaying an interaction in history.
//

import SwiftUI

struct HistoryRowView: View {
    let metadata: InteractionMetadata

    var body: some View {
        HStack(spacing: 12) {
            // Type icon
            Image(systemName: iconName)
                .font(.title3)
                .foregroundStyle(iconColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                // Preview text
                Text(metadata.preview)
                    .lineLimit(2)
                    .font(.body)

                // Metadata row
                HStack(spacing: 8) {
                    Text(relativeTime)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let details = detailsText {
                        Text(details)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            // Audio indicator
            if hasAudio {
                Image(systemName: "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var iconName: String {
        switch metadata.type {
        case .transcription:
            return "mic.fill"
        case .conversation:
            return "bubble.left.and.bubble.right.fill"
        }
    }

    private var iconColor: Color {
        switch metadata.type {
        case .transcription:
            return .blue
        case .conversation:
            return .purple
        }
    }

    private var relativeTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: metadata.createdAt, relativeTo: Date())
    }

    private var detailsText: String? {
        switch metadata.details {
        case .transcription(let details):
            return "\(details.wordCount) words"
        case .conversation(let details):
            return "\(details.turnCount) turns"
        }
    }

    private var hasAudio: Bool {
        switch metadata.details {
        case .transcription(let details):
            return details.hasAudio
        case .conversation(let details):
            return details.hasAudio
        }
    }
}

// MARK: - Preview

#Preview("Transcription Row") {
    HistoryRowView(metadata: .previewTranscription)
        .padding()
        .frame(width: 300)
}

#Preview("Conversation Row") {
    HistoryRowView(metadata: .previewConversation)
        .padding()
        .frame(width: 300)
}

#Preview("List of Rows") {
    List {
        HistoryRowView(metadata: .previewTranscription)
        HistoryRowView(metadata: .previewConversation)
        HistoryRowView(metadata: .previewLongTranscription)
    }
    .listStyle(.plain)
    .frame(width: 320, height: 300)
}

// MARK: - Preview Data

extension InteractionMetadata {
    static let previewTranscription = InteractionMetadata(
        id: UUID(),
        type: .transcription,
        createdAt: Date().addingTimeInterval(-120),
        updatedAt: Date().addingTimeInterval(-120),
        preview: "Testing one two three four five",
        details: .transcription(TranscriptionMetadata(
            wordCount: 5,
            pastedTo: "com.apple.Notes",
            hasAudio: true
        ))
    )

    static let previewConversation = InteractionMetadata(
        id: UUID(),
        type: .conversation,
        createdAt: Date().addingTimeInterval(-3600),
        updatedAt: Date().addingTimeInterval(-3500),
        preview: "What's the weather like today?",
        details: .conversation(ConversationMetadata(
            turnCount: 3,
            messageCount: 6,
            hasAudio: true
        ))
    )

    static let previewLongTranscription = InteractionMetadata(
        id: UUID(),
        type: .transcription,
        createdAt: Date().addingTimeInterval(-86400),
        updatedAt: Date().addingTimeInterval(-86400),
        preview: "This is a much longer transcription that spans multiple lines and should be truncated appropriately in the list view",
        details: .transcription(TranscriptionMetadata(
            wordCount: 22,
            pastedTo: nil,
            hasAudio: false
        ))
    )
}
