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
#endif
