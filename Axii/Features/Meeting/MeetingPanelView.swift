//
//  MeetingPanelView.swift
//  Axii
//
//  SwiftUI view for the meeting transcription panel.
//

#if os(macOS)
import SwiftUI

/// Panel view displayed during meeting transcription.
struct MeetingPanelView: View {
    var state: MeetingState
    var onStop: (() -> Void)?
    var onMicrophoneSwitch: ((AudioDevice?) -> Void)?
    var onAppSelect: ((AudioApp?) -> Void)?
    var onRefreshApps: (() -> Void)?

    private let panelWidth: CGFloat = 320
    private let panelMinHeight: CGFloat = 300
    private let panelMaxHeight: CGFloat = 500

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(.primary.opacity(0.1), lineWidth: 1)
                )

            VStack(spacing: 0) {
                // Header with status
                headerView
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 12)

                Divider()
                    .background(.primary.opacity(0.1))

                // Transcript segments
                segmentsList
                    .frame(maxHeight: .infinity)

                Divider()
                    .background(.primary.opacity(0.1))

                // Footer with controls
                footerView
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
        .frame(width: panelWidth)
        .frame(minHeight: panelMinHeight, maxHeight: panelMaxHeight)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: - Header

    @ViewBuilder
    private var headerView: some View {
        HStack {
            // Recording indicator
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

            // Audio level indicator (small)
            if state.isRecording {
                AudioLevelIndicator(level: state.audioLevel)
                    .frame(width: 40, height: 20)
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
        case .recording:
            return .red
        case .processing:
            return .orange
        case .loadingModels:
            return .orange
        case .permissionRequired:
            return .yellow
        case .error:
            return .red
        case .ready:
            return .blue
        case .idle:
            return .gray
        }
    }

    private var statusTitle: String {
        switch state.phase {
        case .idle:
            return "Idle"
        case .ready:
            return "Ready"
        case .loadingModels:
            return "Loading models..."
        case .permissionRequired:
            return "Permission required"
        case .recording:
            return "Recording"
        case .processing:
            return "Processing..."
        case .error(let message):
            return message
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
                            SegmentRow(segment: segment)
                                .id(segment.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .onChange(of: state.segments.count) { _, _ in
                    // Auto-scroll to latest segment
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
        case .recording:
            return "Listening for speech..."
        case .processing:
            return "Finishing transcription..."
        case .loadingModels:
            return "Preparing transcription models..."
        case .permissionRequired:
            return "Grant screen recording permission to capture meeting audio"
        case .error:
            return "An error occurred"
        case .ready:
            return "Select an app to capture and press Start"
        case .idle:
            return "Press hotkey to start meeting mode"
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
            // App picker row (show when can configure)
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

            // Mic picker and action button row
            HStack {
                if canConfigure {
                    microphonePicker
                }

                Spacer()

                // Action button (hidden during processing)
                if case .processing = state.phase {
                    Text("Done")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                } else {
                    Button(action: { onStop?() }) {
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
            if app.name.count > 12 {
                return String(app.name.prefix(10)) + "..."
            }
            return app.name
        }
        return "All Apps"
    }

    // MARK: - Microphone Picker

    private var microphonePicker: some View {
        Menu {
            Button {
                if state.selectedMicrophone != nil {
                    onMicrophoneSwitch?(nil)
                }
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
                    if device.uid != state.selectedMicrophone?.uid {
                        onMicrophoneSwitch?(device)
                    }
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
        case .bluetooth, .bluetoothLE:
            return "wave.3.right"
        case .usb:
            return "cable.connector"
        case .builtIn:
            return "laptopcomputer"
        case .aggregate, .virtual:
            return "rectangle.stack"
        case .unknown:
            return "mic"
        }
    }

    private var shortDeviceName: String {
        if let device = state.selectedMicrophone {
            if device.name.contains("MacBook") || device.name.contains("Built-in") {
                return "Built-in"
            }
            if device.name.count > 12 {
                return String(device.name.prefix(10)) + "..."
            }
            return device.name
        }
        return "Default"
    }
}

// MARK: - Segment Row

private struct SegmentRow: View {
    let segment: MeetingSegment

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                // Speaker badge
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

                // Timestamp
                Text(formatTime(segment.startTime))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            // Text content
            Text(segment.text)
                .font(.body)
                .foregroundStyle(.primary)
                .opacity(segment.isConfirmed ? 1.0 : 0.7)
        }
        .padding(.vertical, 4)
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Audio Level Indicator

private struct AudioLevelIndicator: View {
    let level: Float
    private let barCount = 5

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(barColor(for: index))
                    .frame(width: 4)
            }
        }
    }

    private func barColor(for index: Int) -> Color {
        let threshold = Float(index + 1) / Float(barCount)
        let isActive = level >= threshold * 0.8
        return isActive ? .green : .gray.opacity(0.3)
    }
}

// MARK: - Previews

#Preview("Recording") {
    let state = MeetingState()
    state.phase = .recording
    state.duration = 125  // 2:05
    state.audioLevel = 0.6
    state.segments = [
        MeetingSegment(
            text: "Hello everyone, let's start the meeting.",
            speakerId: "you",
            isFromMicrophone: true,
            startTime: 5,
            endTime: 10
        ),
        MeetingSegment(
            text: "Thanks for organizing this. I have a few updates to share.",
            speakerId: "speaker_1",
            isFromMicrophone: false,
            startTime: 12,
            endTime: 18
        ),
        MeetingSegment(
            text: "Great, go ahead.",
            speakerId: "you",
            isFromMicrophone: true,
            startTime: 20,
            endTime: 22
        ),
    ]

    return MeetingPanelView(state: state)
        .padding(20)
        .background(.black.opacity(0.8))
}

#Preview("Empty") {
    let state = MeetingState()
    state.phase = .recording
    state.duration = 3

    return MeetingPanelView(state: state)
        .padding(20)
        .background(.black.opacity(0.8))
}

#Preview("Loading") {
    let state = MeetingState()
    state.phase = .loadingModels

    return MeetingPanelView(state: state)
        .padding(20)
        .background(.black.opacity(0.8))
}
#endif
