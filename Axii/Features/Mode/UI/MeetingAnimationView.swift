//
//  MeetingAnimationView.swift
//  Axii
//
//  Configurable recording animation for meeting compact view.
//

#if os(macOS)
import SwiftUI

/// Configurable recording animation based on user preference.
struct MeetingAnimationView: View {
    let style: MeetingAnimationStyle
    let audioLevel: Float
    let isRecording: Bool

    @State private var isPulsing = false

    var body: some View {
        switch style {
        case .pulsingDot:
            pulsingDotView
        case .waveform:
            waveformView
        case .none:
            staticDotView
        }
    }

    // MARK: - Pulsing Dot

    private var pulsingDotView: some View {
        ZStack {
            // Outer pulse
            Circle()
                .fill(Color.red.opacity(0.3))
                .frame(width: 24, height: 24)
                .scaleEffect(isPulsing && isRecording ? 1.5 : 1.0)
                .animation(
                    isRecording
                        ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true)
                        : .default,
                    value: isPulsing
                )

            // Inner dot
            Circle()
                .fill(isRecording ? Color.red : Color.gray)
                .frame(width: 12, height: 12)
        }
        .onAppear {
            isPulsing = true
        }
    }

    // MARK: - Waveform

    private var waveformView: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                WaveformBar(
                    level: barLevel(for: index),
                    isRecording: isRecording
                )
            }
        }
        .frame(width: 24, height: 20)
    }

    private func barLevel(for index: Int) -> Float {
        guard isRecording else { return 0.2 }

        // Create varied levels based on audio level
        let baseLevel = audioLevel * 0.8
        let variation = sin(Float(index) * 1.5) * 0.2
        return min(max(baseLevel + variation, 0.1), 1.0)
    }

    // MARK: - Static Dot

    private var staticDotView: some View {
        Circle()
            .fill(isRecording ? Color.red : Color.gray)
            .frame(width: 12, height: 12)
    }
}

// MARK: - Waveform Bar

private struct WaveformBar: View {
    let level: Float
    let isRecording: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(isRecording ? Color.red : Color.gray.opacity(0.5))
            .frame(width: 3, height: barHeight)
            .animation(.easeInOut(duration: 0.1), value: level)
    }

    private var barHeight: CGFloat {
        let minHeight: CGFloat = 4
        let maxHeight: CGFloat = 16
        return minHeight + CGFloat(level) * (maxHeight - minHeight)
    }
}

// MARK: - Previews

#Preview("Pulsing Dot - Recording") {
    MeetingAnimationView(
        style: .pulsingDot,
        audioLevel: 0.5,
        isRecording: true
    )
    .padding()
    .background(.black.opacity(0.8))
}

#Preview("Waveform - Recording") {
    MeetingAnimationView(
        style: .waveform,
        audioLevel: 0.6,
        isRecording: true
    )
    .padding()
    .background(.black.opacity(0.8))
}

#Preview("None - Recording") {
    MeetingAnimationView(
        style: .none,
        audioLevel: 0.5,
        isRecording: true
    )
    .padding()
    .background(.black.opacity(0.8))
}

#Preview("All Styles - Not Recording") {
    HStack(spacing: 20) {
        MeetingAnimationView(style: .pulsingDot, audioLevel: 0, isRecording: false)
        MeetingAnimationView(style: .waveform, audioLevel: 0, isRecording: false)
        MeetingAnimationView(style: .none, audioLevel: 0, isRecording: false)
    }
    .padding()
    .background(.black.opacity(0.8))
}
#endif
