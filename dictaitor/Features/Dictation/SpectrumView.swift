//
//  SpectrumView.swift
//  dictaitor
//
//  Cross-platform spectrum visualization view.
//

import SwiftUI

/// Displays audio waveform as animated vertical bars that grow from center.
/// Bar color transitions from grey (quiet) to white (loud).
struct SpectrumView: View {
    let spectrum: [Float]
    let level: CGFloat

    private static let defaultBandCount = 80
    private static let minHeight: CGFloat = 3
    private static let maxHeight: CGFloat = 40

    var body: some View {
        GeometryReader { geometry in
            let bandCount = spectrum.isEmpty ? Self.defaultBandCount : spectrum.count
            let spacing: CGFloat = 1.5
            let totalSpacing = CGFloat(bandCount - 1) * spacing
            let barWidth = (geometry.size.width - totalSpacing) / CGFloat(bandCount)
            let maxBarHeight = geometry.size.height

            HStack(alignment: .center, spacing: spacing) {
                if spectrum.isEmpty {
                    ForEach(0..<Self.defaultBandCount, id: \.self) { _ in
                        Capsule()
                            .fill(.white.opacity(0.3))
                            .frame(width: barWidth, height: Self.minHeight)
                    }
                } else {
                    ForEach(Array(spectrum.enumerated()), id: \.offset) { _, value in
                        let height = Self.minHeight + CGFloat(value) * (maxBarHeight - Self.minHeight)
                        let opacity = 0.3 + Double(value) * 0.7
                        Capsule()
                            .fill(.white.opacity(opacity))
                            .frame(width: barWidth, height: height)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .clipped()
        .animation(.easeOut(duration: 0.05), value: spectrum)
    }
}

#Preview("Spectrum Static") {
    SpectrumView(
        spectrum: (0..<64).map { i in
            let center = Float(32)
            let distance = abs(Float(i) - center) / center
            return (1.0 - distance * distance) * 0.8
        },
        level: 0.7
    )
    .frame(height: 40)
    .padding()
    .background(.black)
}

#Preview("Spectrum Animated") {
    struct AnimatedPreview: View {
        @State private var spectrum: [Float] = Array(repeating: 0.1, count: 64)
        @State private var timer: Timer?
        @State private var phase: Float = 0

        var body: some View {
            SpectrumView(spectrum: spectrum, level: 0.7)
                .frame(height: 40)
                .padding()
                .background(.black)
                .onAppear {
                    timer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { _ in
                        phase += 0.3
                        let level = Float.random(in: 0.3...0.9)
                        spectrum = (0..<64).map { i in
                            let wave = sin(Float(i) * 0.15 + phase) * 0.5 + 0.5
                            let noise = Float.random(in: 0.85...1.15)
                            return wave * level * noise
                        }
                    }
                }
                .onDisappear {
                    timer?.invalidate()
                }
        }
    }
    return AnimatedPreview()
}
