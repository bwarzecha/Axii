//
//  DictationPanelView.swift
//  dictaitor
//
//  SwiftUI view for the dictation panel.
//

import SwiftUI

/// Panel view displayed during dictation.
struct DictationPanelView: View {
    var state: DictationState
    let hotkeyHint: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(0.2), lineWidth: 1)
                )

            VStack(spacing: 12) {
                statusIcon
                statusText
                if state.isRecording {
                    audioLevelBar
                }
            }
            .padding(20)
        }
        .frame(width: 280, height: 120)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch state.phase {
        case .idle:
            Image(systemName: "mic")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)

        case .recording:
            Image(systemName: "mic.fill")
                .font(.system(size: 36))
                .foregroundStyle(.red)
                .symbolEffect(.pulse, options: .repeating, isActive: true)

        case .transcribing:
            ProgressView()
                .scaleEffect(1.5)

        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.green)

        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch state.phase {
        case .idle:
            Text("Press \(hotkeyHint)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

        case .recording:
            Text("Listening...")
                .font(.headline)

        case .transcribing:
            Text("Transcribing...")
                .font(.headline)

        case .done(let text):
            Text(text)
                .font(.caption)
                .lineLimit(2)
                .foregroundStyle(.secondary)

        case .error(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private var audioLevelBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(.gray.opacity(0.3))
                RoundedRectangle(cornerRadius: 3)
                    .fill(.green.gradient)
                    .frame(width: geo.size.width * CGFloat(state.audioLevel))
            }
        }
        .frame(height: 6)
        .padding(.horizontal, 20)
    }
}
