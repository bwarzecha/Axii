//
//  StandardPanelView.swift
//  Axii
//
//  Config-driven panel composed of independent sections.
//  Each section's visibility is determined by its own config flag.
//  Panel size auto-adjusts based on which sections are present.
//
//  Sections are split across extension files:
//  - StandardPanelSections.swift     (header + footer)
//  - StandardPanelVisualization.swift (indicator + overlay)
//  - StandardPanelTranscript.swift   (transcript display)
//

#if os(macOS)
import SwiftUI

// MARK: - Panel Layout Constants

enum PanelLayout {
    static let compactWidth: CGFloat = 220
    static let compactHeight: CGFloat = 50
    static let cornerRadius: CGFloat = 20
    static let compactCornerRadius: CGFloat = 12

    static let headerHeight: CGFloat = 65
    static let visualizationHeight: CGFloat = 120
    static let statusAndHintsHeight: CGFloat = 40
    static let fullTranscriptHeight: CGFloat = 250
    static let minimalTranscriptHeight: CGFloat = 24
    static let footerHeight: CGFloat = 85
    static let automaticPadding: CGFloat = 60
}

struct StandardPanelView: View {
    let state: ModeRuntimeState
    let config: ModeConfig
    let hotkeyHint: String
    var onStart: (() -> Void)? = nil
    var onStop: (() -> Void)? = nil
    var onClose: (() -> Void)? = nil
    var onMicrophoneSwitch: ((AudioDevice?) -> Void)? = nil
    var onAppSelect: ((AudioApp?) -> Void)? = nil
    var onRefreshApps: (() -> Void)? = nil
    var onModeChange: ((PanelDisplayMode) -> Void)? = nil
    var onCopy: ((String) -> Void)? = nil

    var body: some View {
        if config.panel.preferences.compactModeEnabled
            && state.panelMode == .compact
            && state.phase.isRecording
        {
            compactLayout
        } else {
            expandedLayout
        }
    }

    // MARK: - Compact Layout

    var compactLayout: some View {
        ZStack {
            ModePanelBackground(cornerRadius: PanelLayout.compactCornerRadius)
            HStack(spacing: 12) {
                RecordingAnimationView(
                    style: compactAnimationStyle,
                    audioLevel: state.audioLevel,
                    isRecording: state.phase.isRecording
                )
                .accessibilityElement()
                .accessibilityIdentifier(AccessibilityID.panelAudioLevel)
                .accessibilityValue(String(format: "%.3f", state.audioLevel))
                Text(formatDuration(state.duration))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier(AccessibilityID.panelDuration)
                    .accessibilityValue(String(Int(state.duration)))
                Spacer()
                Button(action: { onModeChange?(.expanded) }) {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Expand panel")
                .accessibilityIdentifier(AccessibilityID.panelExpandButton)
                Button(action: { onStop?() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "stop.fill").font(.caption)
                        Text("Stop").font(.caption.weight(.medium))
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
                .accessibilityIdentifier(AccessibilityID.panelStopButton)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: PanelLayout.compactWidth, height: PanelLayout.compactHeight)
    }

    // MARK: - Expanded Layout

    var expandedLayout: some View {
        ZStack {
            ModePanelBackground(cornerRadius: PanelLayout.cornerRadius)
            VStack(spacing: config.lifecycle.startMode == .automatic ? 8 : 0) {
                headerSection
                visualizationSection
                statusRowSection
                transcriptSection
                footerSection
                keyboardHintsSection
            }
            .padding(.vertical, config.lifecycle.startMode == .automatic ? 14 : 0)
            .padding(.horizontal, config.lifecycle.startMode == .automatic ? 16 : 0)
        }
        .frame(width: panelWidth, height: panelHeight)
        .clipShape(RoundedRectangle(cornerRadius: PanelLayout.cornerRadius, style: .continuous))
    }

    // MARK: - Section: Status Row (startMode == .automatic)

    @ViewBuilder
    var statusRowSection: some View {
        if config.lifecycle.startMode == .automatic {
            Group {
                switch state.phase {
                case .idle, .preparing, .recording:
                    ModeMicrophonePicker(
                        availableMicrophones: state.availableMicrophones,
                        selectedMicrophone: state.selectedMicrophone,
                        onSelect: { onMicrophoneSwitch?($0) },
                        activeCaptureDevice: state.activeCaptureDevice
                    )
                case .transcribing:
                    Text("Transcribing...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .done:
                    Text(state.finalText)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                case .processing:
                    Text("Processing...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .error(let message):
                    Text(message)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(.red)
                }
            }
            .frame(height: 20)
            .accessibilityIdentifier(AccessibilityID.panelPhase)
            .accessibilityValue(String(describing: state.phase))
        }
    }

    // MARK: - Section: Keyboard Hints (startMode == .automatic)

    @ViewBuilder
    var keyboardHintsSection: some View {
        if config.lifecycle.startMode == .automatic {
            Group {
                switch state.phase {
                case .idle, .preparing:
                    HStack(spacing: 4) {
                        ModeKeyCap(text: hotkeyHint)
                        Text("to start")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                case .recording:
                    HStack(spacing: 12) {
                        HStack(spacing: 4) {
                            ModeKeyCap(text: hotkeyHint)
                            Text("Finish").font(.caption).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 4) {
                            ModeKeyCap(text: "esc")
                            Text("Cancel").font(.caption).foregroundStyle(.secondary)
                        }
                    }

                case .error:
                    HStack(spacing: 12) {
                        HStack(spacing: 4) {
                            ModeKeyCap(text: hotkeyHint)
                            Text("Retry").font(.caption).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 4) {
                            ModeKeyCap(text: "esc")
                            Text("Dismiss").font(.caption).foregroundStyle(.secondary)
                        }
                    }

                case .done where state.needsManualCopy:
                    HStack(spacing: 12) {
                        Button("Copy") { onCopy?(state.manualCopyText) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .accessibilityIdentifier(AccessibilityID.panelCopyButton)
                        HStack(spacing: 4) {
                            ModeKeyCap(text: "esc")
                            Text("Dismiss").font(.caption).foregroundStyle(.secondary)
                        }
                    }

                default:
                    Color.clear
                }
            }
            .frame(height: 20)
        }
    }

    // MARK: - Auto-Adjusting Size

    var panelWidth: CGFloat {
        switch config.panel.preferences.transcriptDisplay {
        case .full: return 320
        case .minimal: return 240
        case .none: return 200
        }
    }

    var panelHeight: CGFloat {
        var h: CGFloat = 0
        if config.lifecycle.startMode == .manual { h += PanelLayout.headerHeight }
        if config.panel.preferences.recordingIndicatorStyle == .radialBar {
            h += PanelLayout.visualizationHeight
        }
        if config.lifecycle.startMode == .automatic { h += PanelLayout.statusAndHintsHeight }
        switch config.panel.preferences.transcriptDisplay {
        case .full: h += PanelLayout.fullTranscriptHeight
        case .minimal: h += PanelLayout.minimalTranscriptHeight
        case .none: break
        }
        if config.lifecycle.startMode == .manual { h += PanelLayout.footerHeight }
        if config.lifecycle.startMode == .automatic { h += PanelLayout.automaticPadding }
        return h
    }

    var compactAnimationStyle: RecordingAnimationStyle {
        switch config.panel.preferences.recordingIndicatorStyle {
        case .pulsingDot: return .pulsingDot
        case .waveform: return .waveform
        default: return .pulsingDot
        }
    }
}
#endif
