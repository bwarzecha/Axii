//
//  VoiceRingsIndicator.swift
//  dictaitor
//
//  Radial bar voice visualization - macOS dictation style.
//

import SwiftUI

// MARK: - Radial Bar Visualizer (macOS dictation style)

/// Circular ring with bars that pulse outward - like macOS dictation UI.
struct RadialBarIndicator: View {
    let level: CGFloat
    var noSignal: Bool = false
    var spinning: Bool = false
    var colorOverride: Color? = nil
    var size: CGFloat = 80

    private let barCount = 48

    private var color: Color {
        if let override = colorOverride { return override }
        return noSignal ? .orange : Color(red: 0.3, green: 0.6, blue: 1.0)
    }

    var body: some View {
        if spinning {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
                RadialBarContent(
                    level: level,
                    noSignal: noSignal,
                    spinning: true,
                    spinTime: timeline.date.timeIntervalSinceReferenceDate,
                    color: color,
                    size: size,
                    barCount: barCount
                )
            }
        } else {
            RadialBarContent(
                level: level,
                noSignal: noSignal,
                spinning: false,
                spinTime: 0,
                color: color,
                size: size,
                barCount: barCount
            )
        }
    }
}

/// Inner content view for RadialBarIndicator - separated to work with TimelineView.
private struct RadialBarContent: View {
    let level: CGFloat
    let noSignal: Bool
    let spinning: Bool
    let spinTime: TimeInterval
    let color: Color
    let size: CGFloat
    let barCount: Int

    var body: some View {
        ZStack {
            // Glow effect
            Circle()
                .fill(
                    RadialGradient(
                        colors: [color.opacity(noSignal ? 0.1 : 0.2 + Double(level) * 0.15), .clear],
                        center: .center,
                        startRadius: size * 0.25,
                        endRadius: size * 0.55
                    )
                )
                .frame(width: size, height: size)

            // Radial bars
            ForEach(0..<barCount, id: \.self) { index in
                radialBar(index: index)
            }
        }
        .frame(width: size, height: size)
    }

    private func radialBar(index: Int) -> some View {
        let angle = Double(index) / Double(barCount) * 360.0

        // Base bar length
        let baseLength: CGFloat = size * 0.08

        // For spinning mode, highlight bars near the spin position
        let barLength: CGFloat
        let opacity: Double

        if spinning {
            // Calculate spin position based on time (one rotation per 1.2 seconds)
            let spinAngle = spinTime.truncatingRemainder(dividingBy: 1.2) / 1.2 * Double(barCount)
            let distance = min(
                abs(Double(index) - spinAngle),
                abs(Double(index) - spinAngle + Double(barCount)),
                abs(Double(index) - spinAngle - Double(barCount))
            )

            // Tail effect: bars close to spin position are highlighted
            let tailLength = 10.0
            let highlight = max(0, 1.0 - distance / tailLength)

            barLength = baseLength + CGFloat(highlight) * size * 0.08
            opacity = 0.25 + highlight * 0.7
        } else {
            // Normal level-based rendering
            let levelBoost = noSignal ? 0 : level * size * 0.06
            barLength = baseLength + levelBoost
            opacity = noSignal ? 0.4 : 0.5 + Double(level) * 0.5
        }

        // Inner radius (where bar starts)
        let innerRadius = size * 0.32

        // Bar width
        let barWidth: CGFloat = 2.5

        return RoundedRectangle(cornerRadius: 1)
            .fill(color.opacity(opacity))
            .frame(width: barWidth, height: barLength)
            .offset(y: -(innerRadius + barLength / 2))
            .rotationEffect(.degrees(angle))
    }
}

// MARK: - Previews

#Preview("Radial Bars") {
    VStack(spacing: 30) {
        RadialBarIndicator(level: 0.3, size: 100)
        RadialBarIndicator(level: 0.7, size: 100)
        RadialBarIndicator(level: 0.02, noSignal: true, size: 100)
    }
    .padding(40)
    .background(.black.opacity(0.9))
}

#Preview("Spinning (Warmup)") {
    RadialBarIndicator(level: 0.3, spinning: true, size: 120)
        .padding(40)
        .background(.black.opacity(0.9))
}

#Preview("Done State (Green)") {
    ZStack {
        RadialBarIndicator(level: 1.0, colorOverride: .green, size: 120)
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 40))
            .foregroundStyle(.green)
    }
    .padding(40)
    .background(.black.opacity(0.9))
}

#Preview("Small (Conversation)") {
    RadialBarIndicator(level: 0.5, size: 50)
        .padding(40)
        .background(.black.opacity(0.9))
}
