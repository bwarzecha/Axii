//
//  MeetingCompactView.swift
//  Axii
//
//  Compact meeting panel showing animation, duration, and stop button.
//

#if os(macOS)
import SwiftUI

/// Compact view for meeting recording - minimal footprint.
struct MeetingCompactView: View {
    let animationStyle: MeetingAnimationStyle
    let audioLevel: Float
    let duration: TimeInterval
    let isRecording: Bool
    var onExpand: (() -> Void)?
    var onStop: (() -> Void)?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.primary.opacity(0.1), lineWidth: 1)
                )

            HStack(spacing: 12) {
                // Recording animation
                MeetingAnimationView(
                    style: animationStyle,
                    audioLevel: audioLevel,
                    isRecording: isRecording
                )

                // Duration
                Text(formattedDuration)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.primary)

                Spacer()

                // Expand button
                Button(action: { onExpand?() }) {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Expand panel")

                // Stop button
                Button(action: { onStop?() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "stop.fill")
                            .font(.caption)
                        Text("Stop")
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(.red)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.red.opacity(0.15))
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 220, height: 50)
    }

    private var formattedDuration: String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}

// MARK: - Previews

#Preview("Recording") {
    MeetingCompactView(
        animationStyle: .pulsingDot,
        audioLevel: 0.5,
        duration: 125,
        isRecording: true
    )
    .padding()
    .background(.black.opacity(0.8))
}

#Preview("Waveform") {
    MeetingCompactView(
        animationStyle: .waveform,
        audioLevel: 0.7,
        duration: 3725,
        isRecording: true
    )
    .padding()
    .background(.black.opacity(0.8))
}

#Preview("No Animation") {
    MeetingCompactView(
        animationStyle: .none,
        audioLevel: 0.3,
        duration: 45,
        isRecording: true
    )
    .padding()
    .background(.black.opacity(0.8))
}
#endif
