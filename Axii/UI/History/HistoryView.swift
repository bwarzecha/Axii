//
//  HistoryView.swift
//  Axii
//
//  Main history browsing view with list and detail.
//

#if os(macOS)
import SwiftUI

struct HistoryView: View {
    let historyService: HistoryService

    @State private var selectedId: UUID?
    @State private var searchText = ""
    @State private var filterType: InteractionType?

    var body: some View {
        NavigationSplitView {
            listView
                .navigationSplitViewColumnWidth(min: 250, ideal: 300)
        } detail: {
            detailView
        }
        .frame(minWidth: 600, minHeight: 400)
        .task {
            // Ensure history is loaded when view appears
            if !historyService.isLoaded {
                await historyService.loadAllMetadata()
            }
        }
    }

    private var listView: some View {
        VStack(spacing: 0) {
            // Search and filter bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search", text: $searchText)
                    .textFieldStyle(.plain)

                Picker("Filter", selection: $filterType) {
                    Text("All").tag(nil as InteractionType?)
                    Text("Dictations").tag(InteractionType.transcription as InteractionType?)
                    Text("Conversations").tag(InteractionType.conversation as InteractionType?)
                    Text("Meetings").tag(InteractionType.meeting as InteractionType?)
                }
                .pickerStyle(.menu)
                .frame(width: 130)
            }
            .padding(8)
            .background(.bar)

            Divider()

            // List content
            if !historyService.isLoaded {
                loadingView
            } else if filteredItems.isEmpty {
                emptyStateView
            } else {
                List(filteredItems, selection: $selectedId) { item in
                    HistoryRowView(metadata: item) {
                        copyInteraction(id: item.id)
                    }
                    .tag(item.id)
                }
                .listStyle(.plain)
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading history...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var detailView: some View {
        if let selectedId, let metadata = historyService.cache[selectedId] {
            HistoryDetailView(
                metadata: metadata,
                historyService: historyService,
                onDelete: {
                    self.selectedId = nil
                }
            )
        } else {
            Text("Select an item to view details")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No history yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Your dictations, conversations, and meetings will appear here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var filteredItems: [InteractionMetadata] {
        var items = historyService.listMetadata()

        // Filter by type
        if let filterType {
            items = items.filter { $0.type == filterType }
        }

        // Filter by search text
        if !searchText.isEmpty {
            items = items.filter { $0.preview.localizedCaseInsensitiveContains(searchText) }
        }

        return items
    }

    private func copyInteraction(id: UUID) {
        Task {
            do {
                let interaction = try await historyService.loadInteraction(id: id)
                let textToCopy = extractText(from: interaction)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(textToCopy, forType: .string)
            } catch {
                print("Failed to copy interaction: \(error)")
            }
        }
    }

    private func extractText(from interaction: Interaction) -> String {
        switch interaction {
        case .transcription(let transcription):
            return transcription.text
        case .conversation(let conversation):
            return conversation.messages.map { message in
                let role = message.role == .user ? "You" : "Assistant"
                return "\(role): \(message.content)"
            }.joined(separator: "\n\n")
        case .meeting(let meeting):
            return meeting.fullText
        }
    }
}
#endif

// MARK: - Preview

/// Preview-only history view with mock data (no HistoryService dependency)
private struct PreviewHistoryView: View {
    @State private var selectedId: UUID?
    @State private var searchText = ""
    @State private var filterType: InteractionType?

    let items: [InteractionMetadata]

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                // Search and filter bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.plain)

                    Picker("Filter", selection: $filterType) {
                        Text("All").tag(nil as InteractionType?)
                        Text("Dictations").tag(InteractionType.transcription as InteractionType?)
                        Text("Conversations").tag(InteractionType.conversation as InteractionType?)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 130)
                }
                .padding(8)
                .background(.bar)

                Divider()

                List(filteredItems, selection: $selectedId) { item in
                    HistoryRowView(metadata: item)
                        .tag(item.id)
                }
                .listStyle(.plain)
            }
            .navigationSplitViewColumnWidth(min: 250, ideal: 300)
        } detail: {
            if let selectedId, let item = items.first(where: { $0.id == selectedId }) {
                PreviewDetailContent(metadata: item)
            } else {
                Text("Select an item to view details")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 600, minHeight: 400)
    }

    private var filteredItems: [InteractionMetadata] {
        var result = items

        if let filterType {
            result = result.filter { $0.type == filterType }
        }

        if !searchText.isEmpty {
            result = result.filter { $0.preview.localizedCaseInsensitiveContains(searchText) }
        }

        return result
    }
}

private struct PreviewDetailContent: View {
    let metadata: InteractionMetadata

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Fixed header with actions
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: metadata.type == .transcription ? "mic.fill" : "bubble.left.and.bubble.right.fill")
                            .foregroundStyle(metadata.type == .transcription ? .blue : .purple)
                        Text(metadata.type == .transcription ? "Transcription" : "Conversation")
                            .font(.headline)
                    }
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
            .padding()

            Divider()

            // Scrollable content
            ScrollView {
                Text(metadata.preview)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
    }
}

#Preview("History View - With Items") {
    PreviewHistoryView(items: [
        .previewTranscription,
        .previewConversation,
        .previewLongTranscription
    ])
    .frame(width: 700, height: 500)
}

#Preview("History View - Empty") {
    PreviewHistoryView(items: [])
        .frame(width: 700, height: 500)
}
