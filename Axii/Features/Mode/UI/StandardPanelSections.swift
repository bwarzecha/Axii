//
//  StandardPanelSections.swift
//  Axii
//
//  Header and footer sections for StandardPanelView.
//  Extracted to keep each file under 300 lines.
//

#if os(macOS)
import SwiftUI

// MARK: - Header Section

extension StandardPanelView {

    @ViewBuilder
    var headerSection: some View {
        if config.lifecycle.startMode == .manual {
            VStack(spacing: 0) {
                HStack {
                    HStack(spacing: 8) {
                        headerRecordingIndicator

                        VStack(alignment: .leading, spacing: 2) {
                            Text(headerStatusTitle)
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .accessibilityIdentifier(AccessibilityID.panelPhase)
                                .accessibilityValue(String(describing: state.phase))

                            if config.panel.preferences.showDurationTimer
                                && state.phase.isRecording
                            {
                                Text(formatDuration(state.duration))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                    .accessibilityIdentifier(AccessibilityID.panelDuration)
                                    .accessibilityValue(String(Int(state.duration)))
                            }
                        }
                    }

                    Spacer()

                    if config.panel.preferences.compactModeEnabled && state.phase.isRecording {
                        Button(action: { onModeChange?(.compact) }) {
                            Image(systemName: "chevron.up")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(6)
                                .background(Circle().fill(.primary.opacity(0.05)))
                        }
                        .buttonStyle(.plain)
                        .help("Collapse to compact view")
                        .accessibilityIdentifier(AccessibilityID.panelCollapseButton)
                    }

                    if !state.phase.isRecording, state.phase != .processing {
                        Button(action: { onClose?() }) {
                            Image(systemName: "xmark")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(6)
                                .background(Circle().fill(.primary.opacity(0.05)))
                        }
                        .buttonStyle(.plain)
                        .help("Close")
                        .accessibilityIdentifier(AccessibilityID.panelCloseButton)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

                Divider()
            }
        }
    }

    var headerRecordingIndicator: some View {
        Circle()
            .fill(headerIndicatorColor)
            .frame(width: 12, height: 12)
            .overlay(
                Circle()
                    .fill(headerIndicatorColor.opacity(0.5))
                    .scaleEffect(state.phase.isRecording ? 1.5 : 1.0)
                    .animation(
                        state.phase.isRecording
                            ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true)
                            : .default,
                        value: state.phase.isRecording
                    )
            )
    }

    var headerIndicatorColor: Color {
        switch state.phase {
        case .recording: return .red
        case .processing, .transcribing, .preparing: return .orange
        case .error: return .red
        case .idle, .done: return .blue
        }
    }

    var headerStatusTitle: String {
        switch state.phase {
        case .idle: return "Ready"
        case .preparing: return "Preparing..."
        case .recording: return "Recording"
        case .processing:
            return state.processingStatus.isEmpty ? "Processing..." : state.processingStatus
        case .transcribing: return "Transcribing..."
        case .done: return state.needsManualCopy ? "Not saved to history" : "Done"
        case .error(let msg): return msg
        }
    }
}

// MARK: - Footer Section

extension StandardPanelView {

    @ViewBuilder
    var footerSection: some View {
        if config.lifecycle.startMode == .manual {
            VStack(spacing: 0) {
                Divider()

                VStack(spacing: 8) {
                    if canConfigureFooter {
                        HStack {
                            if config.audioCapture.isDual {
                                ModeAppPicker(
                                    availableApps: state.availableApps,
                                    selectedApp: state.selectedApp,
                                    onSelect: { onAppSelect?($0) },
                                    onRefresh: { onRefreshApps?() }
                                )
                            }
                            Spacer()
                        }
                    }

                    HStack {
                        if canConfigureFooter {
                            ModeMicrophonePicker(
                                availableMicrophones: state.availableMicrophones,
                                selectedMicrophone: state.selectedMicrophone,
                                onSelect: { onMicrophoneSwitch?($0) },
                                activeCaptureDevice: state.activeCaptureDevice
                            )
                        }
                        Spacer()
                        footerActionButton
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    var canConfigureFooter: Bool {
        switch state.phase {
        case .idle, .preparing, .error, .done: return true
        case .recording, .processing, .transcribing: return false
        }
    }

    @ViewBuilder
    var footerActionButton: some View {
        if case .processing = state.phase {
            HStack(spacing: 8) {
                ProgressView(value: state.processingProgress)
                    .progressViewStyle(.linear)
                    .frame(width: 80)
                Text("\(Int(state.processingProgress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
        } else if state.phase == .done, state.needsManualCopy {
            // This recording was never written to history. Copy is the only
            // way it survives the panel closing.
            Button("Copy Transcript") { onCopy?(state.manualCopyText) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier(AccessibilityID.panelCopyButton)
        } else {
            Button(action: {
                if state.phase.isRecording { onStop?() } else { onStart?() }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: state.phase.isRecording ? "stop.fill" : "record.circle")
                    Text(state.phase.isRecording ? "Stop" : "Start")
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(state.phase.isRecording ? .red : .blue)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill((state.phase.isRecording ? Color.red : Color.blue).opacity(0.15))
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.panelActionButton)
        }
    }
}
#endif
