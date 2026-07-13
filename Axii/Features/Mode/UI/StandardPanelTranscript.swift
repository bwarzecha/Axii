//
//  StandardPanelTranscript.swift
//  Axii
//
//  Transcript display sections for StandardPanelView.
//  Extracted to keep each file under 300 lines.
//

#if os(macOS)
import SwiftUI

extension StandardPanelView {

    // MARK: - Transcript Section

    @ViewBuilder
    var transcriptSection: some View {
        switch config.panel.preferences.transcriptDisplay {
        case .full:
            fullTranscriptArea
                .frame(maxHeight: .infinity)
        case .minimal where !state.liveTranscript.isEmpty:
            Text(state.liveTranscript)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
                .accessibilityIdentifier(AccessibilityID.panelTranscript)
        default:
            EmptyView()
        }
    }

    // MARK: - Full Transcript Area

    @ViewBuilder
    var fullTranscriptArea: some View {
        if state.segments.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.system(size: 36))
                    .foregroundStyle(.tertiary)
                Text(transcriptEmptyText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(state.segments) { segment in
                            ModeSegmentRow(segment: segment)
                                .id(segment.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .onChange(of: state.segments.count) { _, _ in
                    if let last = state.segments.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .accessibilityIdentifier(AccessibilityID.panelTranscript)
            }
            .overlay(alignment: .topTrailing) {
                if state.phase.isRecording, let onCopyLive {
                    LiveTranscriptCopyButton(onCopy: onCopyLive)
                        .padding(.top, 6)
                        .padding(.trailing, 10)
                }
            }
        }
    }

    var transcriptEmptyText: String {
        switch state.phase {
        case .recording: return "Listening for speech..."
        case .processing, .transcribing: return "Finishing transcription..."
        case .preparing: return "Preparing transcription..."
        case .error: return "An error occurred"
        case .idle: return "Press Start to begin"
        case .done: return "Recording complete"
        }
    }
}

// MARK: - Live Transcript Copy Button

/// Copies the running transcript mid-recording without stopping the meeting.
/// Flashes a checkmark for confirmation, since nothing else changes on screen.
struct LiveTranscriptCopyButton: View {
    let onCopy: () -> Void
    @State private var showCopied = false

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 4) {
                Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                Text(showCopied ? "Copied" : "Copy")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(showCopied ? Color.green : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(.background.opacity(0.85))
            )
            .overlay(Capsule().stroke(.primary.opacity(0.1), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Copy transcript so far")
        .accessibilityIdentifier(AccessibilityID.panelCopyLiveButton)
    }

    private func copy() {
        onCopy()
        withAnimation { showCopied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation { showCopied = false }
        }
    }
}
#endif
