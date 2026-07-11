//
//  StandardPanelVisualization.swift
//  Axii
//
//  Visualization and indicator sections for StandardPanelView.
//  Extracted to keep each file under 300 lines.
//

#if os(macOS)
import SwiftUI

extension StandardPanelView {

    // MARK: - Visualization Section

    @ViewBuilder
    var visualizationSection: some View {
        if config.panel.preferences.recordingIndicatorStyle == .radialBar {
            ZStack {
                RadialBarIndicator(
                    level: indicatorLevel,
                    noSignal: indicatorNoSignal,
                    spinning: state.phase.isRecording && state.isWaitingForSignal,
                    colorOverride: indicatorColorOverride,
                    size: 120
                )
                .opacity(indicatorOpacity)
                .accessibilityElement()
                .accessibilityIdentifier(AccessibilityID.panelAudioLevel)
                .accessibilityValue(String(format: "%.3f", state.audioLevel))

                visualizationOverlay
            }
            .frame(height: PanelLayout.visualizationHeight)
        }
    }

    // MARK: - Indicator Properties

    var indicatorLevel: CGFloat {
        switch state.phase {
        case .idle, .preparing: return 0
        case .recording: return state.isWaitingForSignal ? 0.3 : CGFloat(state.audioLevel)
        case .transcribing: return 0.5
        case .done: return 1.0
        case .processing: return 0.5
        case .error: return 0
        }
    }

    var indicatorNoSignal: Bool {
        if case .error = state.phase { return true }
        return false
    }

    var indicatorColorOverride: Color? {
        switch state.phase {
        case .done where !state.needsManualCopy: return .green
        case .done where state.needsManualCopy: return .orange
        default: return nil
        }
    }

    var indicatorOpacity: Double {
        switch state.phase {
        case .idle, .preparing: return 0.5
        case .transcribing, .processing: return 0.6
        case .error: return 0.3
        default: return 1.0
        }
    }

    // MARK: - Visualization Overlay

    @ViewBuilder
    var visualizationOverlay: some View {
        switch state.phase {
        case .recording where state.isWaitingForSignal:
            Text("Warming up...")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .transcribing:
            ProgressView()
                .scaleEffect(0.8)
        case .done where !state.needsManualCopy:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)
        case .done where state.needsManualCopy:
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.red)
        default:
            EmptyView()
        }
    }
}
#endif
