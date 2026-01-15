//
//  RecordingPanelView.swift
//  dictaitor
//
//  SwiftUI view displayed inside the floating panel.
//

import SwiftUI

struct RecordingPanelView: View {
    let isListening: Bool
    let hotkeyHint: String

    var body: some View {
        ZStack {
            // Background with rounded corners and material
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(0.2), lineWidth: 1)
                )

            // Content
            VStack(spacing: 12) {
                statusIcon
                statusText
                if isListening {
                    audioLevelBar
                }
            }
            .padding(20)
        }
        .frame(width: 280, height: 120)
    }

    @ViewBuilder
    private var statusIcon: some View {
        Image(systemName: isListening ? "mic.fill" : "mic")
            .font(.system(size: 36))
            .foregroundStyle(isListening ? .red : .secondary)
            .symbolEffect(.pulse, options: .repeating, isActive: isListening)
    }

    @ViewBuilder
    private var statusText: some View {
        if isListening {
            Text("Listening...")
                .font(.headline)
        } else {
            Text("Press \(hotkeyHint) to start")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var audioLevelBar: some View {
        // Static placeholder - will be dynamic in future slices
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(.gray.opacity(0.3))
                RoundedRectangle(cornerRadius: 3)
                    .fill(.green.gradient)
                    .frame(width: geo.size.width * 0.4)  // Static 40% for now
            }
        }
        .frame(height: 6)
        .padding(.horizontal, 20)
    }
}

#Preview("Idle") {
    RecordingPanelView(isListening: false, hotkeyHint: "Shift+Option+Space")
        .padding()
        .background(.black.opacity(0.5))
}

#Preview("Listening") {
    RecordingPanelView(isListening: true, hotkeyHint: "Shift+Option+Space")
        .padding()
        .background(.black.opacity(0.5))
}
