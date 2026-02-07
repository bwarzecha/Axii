//
//  StandardPanelView.swift
//  Axii
//
//  Adaptive panel view for dictation-like and meeting-like modes.
//  Size and layout adapt based on ModeConfig and ModeRuntimeState.
//

#if os(macOS)
import SwiftUI

/// Standard panel view that adapts to dictation-like and meeting-like modes.
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

    private var isDualCapture: Bool { config.audioCapture.isDual }
    private var hasTranscript: Bool { config.panel.preferences.transcriptDisplay != .none }
    private var isManualStart: Bool { config.lifecycle.startMode == .manual }
    private var isMeetingLike: Bool { isDualCapture || hasTranscript }
    private var isCompactMode: Bool { state.panelMode == .compact && state.phase.isRecording }
    private var hasVisualization: Bool { config.panel.preferences.recordingIndicatorStyle != .none }

    private var panelWidth: CGFloat { isMeetingLike ? (isCompactMode ? 220 : 320) : 200 }
    private var panelHeight: CGFloat {
        if isCompactMode { return 50 }
        return isMeetingLike ? 400 : 220
    }

    var body: some View {
        if isCompactMode { compactLayout } else { expandedLayout }
    }

    // MARK: - Compact Layout

    private var compactLayout: some View {
        ZStack {
            ModePanelBackground(cornerRadius: 12)
            HStack(spacing: 12) {
                MeetingAnimationView(
                    style: animationStyle, audioLevel: state.audioLevel,
                    isRecording: state.phase.isRecording
                )
                Text(formatDuration(state.duration))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.primary)
                Spacer()
                Button(action: { onModeChange?(.expanded) }) {
                    Image(systemName: "chevron.down.circle")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).help("Expand panel")
                Button(action: { onStop?() }) {
                    Image(systemName: "stop.circle.fill").font(.body).foregroundStyle(.red)
                }
                .buttonStyle(.plain).help("Stop recording")
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(width: 220, height: 50)
    }

    // MARK: - Expanded Layout

    private var expandedLayout: some View {
        ZStack {
            ModePanelBackground(cornerRadius: 20)
            VStack(spacing: 0) {
                if isManualStart && isActivePhase { headerSection }
                if hasVisualization {
                    mainVisualizationArea.frame(height: isMeetingLike ? 80 : 120)
                }
                if config.panel.preferences.transcriptDisplay == .full && !state.segments.isEmpty {
                    Divider()
                    transcriptScrollArea.frame(maxHeight: .infinity)
                }
                if config.panel.preferences.transcriptDisplay == .minimal
                    && !state.liveTranscript.isEmpty
                {
                    Text(state.liveTranscript).font(.caption).lineLimit(1)
                        .foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 4)
                }
                if case .done = state.phase, !state.finalText.isEmpty { resultTextArea }
                if case .processing = state.phase { progressBar }
                if case .error = state.phase { errorDisplay }
                if isMeetingLike { Divider(); footerSection }
                keyboardHintsBar
            }
            .padding(.vertical, isMeetingLike ? 0 : 14)
            .padding(.horizontal, isMeetingLike ? 0 : 16)
        }
        .frame(width: panelWidth, height: panelHeight)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            Circle().fill(headerIndicatorColor).frame(width: 10, height: 10)
            Text(config.name).font(.headline).foregroundStyle(.primary)
            Spacer()
            if config.panel.preferences.showDurationTimer {
                Text(formatDuration(state.duration)).font(.caption)
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            if config.panel.preferences.compactModeEnabled && state.phase.isRecording {
                Button(action: { onModeChange?(.compact) }) {
                    Image(systemName: "chevron.up").font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary).padding(6)
                        .background(Circle().fill(.primary.opacity(0.05)))
                }.buttonStyle(.plain).help("Collapse to compact view")
            }
            if showCloseButton {
                Button(action: { onClose?() }) {
                    Image(systemName: "xmark").font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary).padding(6)
                        .background(Circle().fill(.primary.opacity(0.05)))
                }.buttonStyle(.plain).help("Close")
            }
        }
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)
    }

    private var showCloseButton: Bool {
        if state.phase.isRecording { return false }
        if case .processing = state.phase { return false }
        return true
    }

    // MARK: - Main Visualization

    @ViewBuilder
    private var mainVisualizationArea: some View {
        ZStack {
            switch config.panel.preferences.recordingIndicatorStyle {
            case .radialBar:
                RadialBarIndicator(
                    level: indicatorLevel, noSignal: state.isWaitingForSignal,
                    spinning: state.phase.isRecording && state.isWaitingForSignal,
                    colorOverride: indicatorColorOverride,
                    size: isMeetingLike ? 60 : 120
                )
            case .pulsingDot, .waveform:
                MeetingAnimationView(
                    style: animationStyle, audioLevel: state.audioLevel,
                    isRecording: state.phase.isRecording
                )
            case .none:
                EmptyView()
            }
            phaseOverlay
        }
        .padding()
    }

    @ViewBuilder
    private var phaseOverlay: some View {
        switch state.phase {
        case .done where !state.needsManualCopy:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40)).foregroundStyle(.green)
        case .done where state.needsManualCopy:
            Button(action: { onCopy?(state.manualCopyText) }) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 40)).foregroundStyle(.orange)
            }.buttonStyle(.plain)
        case .transcribing, .processing:
            ProgressView().scaleEffect(0.8)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40)).foregroundStyle(.red)
        default:
            EmptyView()
        }
    }

    // MARK: - Transcript

    private var transcriptScrollArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(state.segments) { segment in
                        ModeSegmentRow(segment: segment).id(segment.id)
                    }
                }.padding(.horizontal, 16).padding(.vertical, 12)
            }
            .onChange(of: state.segments.count) { _, _ in
                if let last = state.segments.last {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var resultTextArea: some View {
        Text(state.finalText).font(.body).foregroundStyle(.primary).padding()
    }

    // MARK: - Progress & Error

    private var progressBar: some View {
        HStack(spacing: 8) {
            ProgressView(value: state.processingProgress).progressViewStyle(.linear)
                .frame(maxWidth: .infinity)
            Text("\(Int(state.processingProgress * 100))%").font(.caption)
                .foregroundStyle(.secondary).monospacedDigit()
        }.padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var errorDisplay: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            if case .error(let message) = state.phase {
                Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
        }.padding(.horizontal, 16).padding(.vertical, 8)
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            if isDualCapture {
                ModeAppPicker(
                    availableApps: state.availableApps, selectedApp: state.selectedApp,
                    onSelect: { onAppSelect?($0) }, onRefresh: { onRefreshApps?() }
                )
            }
            ModeMicrophonePicker(
                availableMicrophones: state.availableMicrophones,
                selectedMicrophone: state.selectedMicrophone,
                onSelect: { onMicrophoneSwitch?($0) }
            )
            Spacer()
            if isManualStart { actionButton }
        }.padding(.horizontal, 16).padding(.vertical, 8)
    }

    @ViewBuilder
    private var actionButton: some View {
        if case .idle = state.phase {
            modeActionButton(label: "Start", color: .green, action: { onStart?() })
        } else if state.phase.isRecording {
            modeActionButton(label: "Stop", color: .red, action: { onStop?() })
        }
    }

    private func modeActionButton(label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.subheadline.weight(.medium)).foregroundStyle(color)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color.opacity(0.15)))
        }.buttonStyle(.plain)
    }

    // MARK: - Keyboard Hints

    private var keyboardHintsBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                ModeKeyCap(text: hotkeyHint)
                Text(hotkeyActionText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                ModeKeyCap(text: "esc")
                Text(escapeActionText).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.secondary.opacity(0.05))
    }

    // MARK: - Computed Helpers

    private var isActivePhase: Bool {
        switch state.phase {
        case .recording, .processing, .transcribing, .done: return true
        default: return false
        }
    }

    private var headerIndicatorColor: Color {
        switch state.phase {
        case .recording: return .red
        case .processing, .transcribing: return .orange
        case .done: return .green
        case .error: return .red
        default: return .gray
        }
    }

    private var indicatorLevel: CGFloat {
        switch state.phase {
        case .recording: return state.isWaitingForSignal ? 0.3 : CGFloat(state.audioLevel)
        case .transcribing: return 0.5
        case .done: return 1.0
        default: return 0
        }
    }

    private var indicatorColorOverride: Color? {
        switch state.phase {
        case .done where !state.needsManualCopy: return .green
        case .done where state.needsManualCopy: return .orange
        default: return nil
        }
    }

    private var animationStyle: MeetingAnimationStyle {
        switch config.panel.preferences.recordingIndicatorStyle {
        case .pulsingDot: return .pulsingDot
        case .waveform: return .waveform
        default: return .none
        }
    }

    private var hotkeyActionText: String {
        switch state.phase {
        case .idle: return "Start"
        case .recording: return "Stop"
        case .done:
            if state.needsManualCopy { return "Copy" }
            return config.lifecycle.sessionType == .singleShot ? "New recording" : "Continue"
        default: return "Start"
        }
    }

    private var escapeActionText: String {
        if case .recording = state.phase { return "Cancel" }
        return "Close"
    }
}
#endif
