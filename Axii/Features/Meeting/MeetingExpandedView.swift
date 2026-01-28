//
//  MeetingExpandedView.swift
//  Axii
//
//  Full meeting panel with transcript, app/mic pickers, and controls.
//

#if os(macOS)
import SwiftUI

/// Expanded view for meeting - full transcript and controls.
struct MeetingExpandedView: View {
    let state: MeetingState
    var onCollapse: (() -> Void)?
    var onClose: (() -> Void)?
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onMicrophoneSwitch: ((AudioDevice?) -> Void)?
    var onAppSelect: ((AudioApp?) -> Void)?
    var onRefreshApps: (() -> Void)?

    private let panelWidth: CGFloat = 320
    private let panelHeight: CGFloat = 400

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(.primary.opacity(0.1), lineWidth: 1)
                )

            VStack(spacing: 0) {
                headerView
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 12)

                Divider()
                    .background(.primary.opacity(0.1))

                segmentsList
                    .frame(maxHeight: .infinity)

                Divider()
                    .background(.primary.opacity(0.1))

                footerView
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
        .frame(width: panelWidth, height: panelHeight)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: - Header

    @ViewBuilder
    private var headerView: some View {
        HStack {
            HStack(spacing: 8) {
                recordingIndicator

                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    if state.isRecording {
                        Text(formattedDuration)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }

            Spacer()

            // Collapse button (only during recording)
            if state.isRecording {
                Button(action: { onCollapse?() }) {
                    Image(systemName: "chevron.up")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .background(
                            Circle()
                                .fill(.primary.opacity(0.05))
                        )
                }
                .buttonStyle(.plain)
                .help("Collapse to compact view")
            }

            // Close button (when not recording or processing)
            if !state.isRecording && !state.isProcessing {
                Button(action: { onClose?() }) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .background(
                            Circle()
                                .fill(.primary.opacity(0.05))
                        )
                }
                .buttonStyle(.plain)
                .help("Close")
            }
        }
    }

    @ViewBuilder
    private var recordingIndicator: some View {
        Circle()
            .fill(indicatorColor)
            .frame(width: 12, height: 12)
            .overlay(
                Circle()
                    .fill(indicatorColor.opacity(0.5))
                    .scaleEffect(state.isRecording ? 1.5 : 1.0)
                    .animation(
                        state.isRecording
                            ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true)
                            : .default,
                        value: state.isRecording
                    )
            )
    }

    private var indicatorColor: Color {
        switch state.phase {
        case .recording: return .red
        case .processing: return .orange
        case .loadingModels: return .orange
        case .permissionRequired: return .yellow
        case .error: return .red
        case .ready: return .blue
        case .idle: return .gray
        }
    }

    private var statusTitle: String {
        switch state.phase {
        case .idle: return "Meeting"
        case .ready: return "Ready"
        case .loadingModels: return "Loading..."
        case .permissionRequired: return "Permission Required"
        case .recording: return "Recording"
        case .processing:
            if state.processingStatus.isEmpty {
                return "Processing..."
            }
            return state.processingStatus
        case .error(let message): return message
        }
    }

    private var formattedDuration: String {
        let hours = Int(state.duration) / 3600
        let minutes = (Int(state.duration) % 3600) / 60
        let seconds = Int(state.duration) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }

    // MARK: - Segments List

    @ViewBuilder
    private var segmentsList: some View {
        if state.segments.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(state.segments) { segment in
                            SegmentRowView(segment: segment)
                                .id(segment.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .onChange(of: state.segments.count) { _, _ in
                    if let lastSegment = state.segments.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(lastSegment.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)

            Text(emptyStateText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var emptyStateText: String {
        switch state.phase {
        case .recording: return "Listening for speech..."
        case .processing: return "Finishing transcription..."
        case .loadingModels: return "Preparing transcription..."
        case .permissionRequired: return "Grant screen recording permission to capture meeting audio"
        case .error: return "An error occurred"
        case .ready: return "Select an app and press Start"
        case .idle: return "Press hotkey to start"
        }
    }

    // MARK: - Footer

    private var canConfigure: Bool {
        switch state.phase {
        case .idle, .ready, .permissionRequired, .error:
            return true
        case .loadingModels, .recording, .processing:
            return false
        }
    }

    @ViewBuilder
    private var footerView: some View {
        VStack(spacing: 8) {
            if canConfigure {
                HStack {
                    appPicker
                    Spacer()
                    Button(action: { onRefreshApps?() }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            HStack {
                if canConfigure {
                    microphonePicker
                }
                Spacer()
                actionButton
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
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
        } else {
            Button(action: { state.isRecording ? onStop?() : onStart?() }) {
                HStack(spacing: 6) {
                    Image(systemName: state.isRecording ? "stop.fill" : "record.circle")
                    Text(state.isRecording ? "Stop" : "Start")
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(state.isRecording ? .red : .blue)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill((state.isRecording ? Color.red : Color.blue).opacity(0.15))
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - App Picker

    private var appPicker: some View {
        Menu {
            Button {
                onAppSelect?(nil)
            } label: {
                HStack {
                    Image(systemName: "app.badge")
                    Text("All Apps")
                    if state.selectedApp == nil {
                        Spacer()
                        Image(systemName: "checkmark")
                    }
                }
            }

            if !state.availableApps.isEmpty {
                Divider()
                ForEach(state.availableApps) { app in
                    Button {
                        onAppSelect?(app)
                    } label: {
                        HStack {
                            Text(app.name)
                            if state.selectedApp?.pid == app.pid {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "speaker.wave.2")
                    .font(.caption)
                Text("App: \(selectedAppName)")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var selectedAppName: String {
        if let app = state.selectedApp {
            return app.name.count > 12 ? String(app.name.prefix(10)) + "..." : app.name
        }
        return "All Apps"
    }

    // MARK: - Microphone Picker

    private var microphonePicker: some View {
        Menu {
            Button {
                onMicrophoneSwitch?(nil)
            } label: {
                HStack {
                    Image(systemName: "gear")
                    Text("System Default")
                    if state.selectedMicrophone == nil {
                        Spacer()
                        Image(systemName: "checkmark")
                    }
                }
            }

            Divider()

            ForEach(state.availableMicrophones) { device in
                Button {
                    onMicrophoneSwitch?(device)
                } label: {
                    HStack {
                        Image(systemName: transportIcon(for: device))
                        Text(device.name)
                        if device.uid == state.selectedMicrophone?.uid {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "mic")
                    .font(.caption)
                Text(shortDeviceName)
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func transportIcon(for device: AudioDevice) -> String {
        switch device.transportType {
        case .bluetooth, .bluetoothLE: return "wave.3.right"
        case .usb: return "cable.connector"
        case .builtIn: return "laptopcomputer"
        case .aggregate, .virtual: return "rectangle.stack"
        case .unknown: return "mic"
        }
    }

    private var shortDeviceName: String {
        if let device = state.selectedMicrophone {
            if device.name.contains("MacBook") || device.name.contains("Built-in") {
                return "Built-in"
            }
            return device.name.count > 12 ? String(device.name.prefix(10)) + "..." : device.name
        }
        return "Default"
    }
}

// MARK: - Segment Row

private struct SegmentRowView: View {
    let segment: MeetingSegment

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(segment.displayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(segment.isFromMicrophone ? .blue : .orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill((segment.isFromMicrophone ? Color.blue : Color.orange).opacity(0.15))
                    )

                Spacer()

                Text(formatTime(segment.startTime))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            Text(segment.text)
                .font(.body)
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 4)
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Previews

#Preview("Ready") {
    let state = MeetingState()
    state.phase = .ready
    return MeetingExpandedView(state: state)
        .padding(20)
        .background(.black.opacity(0.8))
}

#Preview("Recording with Segments") {
    let state = MeetingState()
    state.phase = .recording
    state.duration = 125
    state.segments = [
        MeetingSegment(text: "Hello everyone, let's start.", speakerId: "You", isFromMicrophone: true, startTime: 5, endTime: 10),
        MeetingSegment(text: "Thanks for organizing this.", speakerId: "Remote", isFromMicrophone: false, startTime: 12, endTime: 18),
        MeetingSegment(text: "Great, let's begin.", speakerId: "You", isFromMicrophone: true, startTime: 20, endTime: 22),
    ]
    return MeetingExpandedView(state: state)
        .padding(20)
        .background(.black.opacity(0.8))
}
#endif
