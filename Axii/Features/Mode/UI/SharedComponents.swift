//
//  SharedComponents.swift
//  Axii
//
//  Reusable UI components for the Mode panel system.
//  Prefixed with "Mode" to avoid collision with existing private types.
//

#if os(macOS)
import SwiftUI

// MARK: - Type Aliases (decouple from Meeting-prefixed names)

typealias RecordingAnimationView = MeetingAnimationView
typealias RecordingAnimationStyle = MeetingAnimationStyle
typealias TranscriptSegment = MeetingSegment

// MARK: - ModeKeyCap

/// Styled keyboard key cap for hotkey hints.
struct ModeKeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.primary)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(.primary.opacity(0.15), lineWidth: 0.5)
            )
    }
}

// MARK: - ModeMicrophonePicker

/// Microphone selection menu for mode panels.
struct ModeMicrophonePicker: View {
    let availableMicrophones: [AudioDevice]
    let selectedMicrophone: AudioDevice?
    let onSelect: (AudioDevice?) -> Void
    /// The device actually capturing (when known). Shown next to the
    /// selection whenever it differs — after an unplug forces a fallback,
    /// the panel must name the mic that is really recording.
    var activeCaptureDevice: AudioDevice? = nil

    var body: some View {
        Menu {
            Button {
                onSelect(nil)
            } label: {
                HStack {
                    Image(systemName: "gear")
                    Text("System Default")
                    if selectedMicrophone == nil {
                        Spacer()
                        Image(systemName: "checkmark")
                    }
                }
            }

            Divider()

            ForEach(availableMicrophones) { device in
                Button {
                    onSelect(device)
                } label: {
                    HStack {
                        Image(systemName: transportIcon(for: device))
                        Text(device.name)
                        if device.uid == selectedMicrophone?.uid {
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
                if let fallback = activeFallback {
                    Text("→ \(fallback.name)")
                        .font(.caption)
                        .foregroundStyle(fallback.isWarning ? Color.orange : Color.secondary)
                        .lineLimit(1)
                        .help("Recording from \(activeCaptureDevice?.name ?? fallback.name)")
                }
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// Non-nil when capture runs on a different device than the selection
    /// claims — the truth wins over the preference. Orange when an explicit
    /// selection silently diverged (a fallback took over); plain when the
    /// selection is "Default" and this merely names the concrete device.
    private var activeFallback: (name: String, isWarning: Bool)? {
        guard let active = activeCaptureDevice,
              active.uid != selectedMicrophone?.uid else { return nil }
        return (shortName(for: active), selectedMicrophone != nil)
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
        guard let device = selectedMicrophone else { return "Default" }
        return shortName(for: device)
    }

    private func shortName(for device: AudioDevice) -> String {
        if device.name.contains("MacBook") || device.name.contains("Built-in") {
            return "Built-in"
        }
        return device.name.count > 15 ? String(device.name.prefix(12)) + "..." : device.name
    }
}

// MARK: - ModeAppPicker

/// Application selection menu for dual-capture modes.
struct ModeAppPicker: View {
    let availableApps: [AudioApp]
    let selectedApp: AudioApp?
    let onSelect: (AudioApp?) -> Void
    let onRefresh: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Menu {
                Button {
                    onSelect(nil)
                } label: {
                    HStack {
                        Text("All Apps")
                        if selectedApp == nil {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }

                Divider()

                ForEach(availableApps) { app in
                    Button {
                        onSelect(app)
                    } label: {
                        HStack {
                            Text(truncatedAppName(app.name))
                            if selectedApp?.pid == app.pid {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "app.badge")
                        .font(.caption)
                    Text(selectedAppLabel)
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private func truncatedAppName(_ name: String) -> String {
        name.count > 12 ? String(name.prefix(10)) + "..." : name
    }

    private var selectedAppLabel: String {
        guard let app = selectedApp else { return "All Apps" }
        return truncatedAppName(app.name)
    }
}

// MARK: - ModeSegmentRow

/// A single transcript segment row with speaker badge and timestamp.
struct ModeSegmentRow: View {
    let segment: TranscriptSegment

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
                            .fill(
                                (segment.isFromMicrophone ? Color.blue : Color.orange)
                                    .opacity(0.15)
                            )
                    )

                Spacer()

                Text(formatTimestamp(segment.startTime))
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

    private func formatTimestamp(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - ModeMessageBubble

/// A single message bubble for conversation-style modes.
struct ModeMessageBubble: View {
    let message: DisplayMessage

    private var isUser: Bool {
        message.role == .user
    }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 40) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Text(isUser ? "You" : "Assistant")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(message.content)
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(
                                isUser
                                    ? Color.accentColor.opacity(0.2)
                                    : Color.secondary.opacity(0.15)
                            )
                    )
                    .foregroundStyle(.primary)
            }

            if !isUser { Spacer(minLength: 40) }
        }
    }
}

// MARK: - ModePanelBackground

/// Standard panel background with ultraThinMaterial and border.
struct ModePanelBackground: View {
    var cornerRadius: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.primary.opacity(0.1), lineWidth: 1)
            )
    }
}

// MARK: - Duration Formatter

/// Formats a TimeInterval as "M:SS" (under 1 hour) or "H:MM:SS" (1 hour+).
func formatDuration(_ time: TimeInterval) -> String {
    let totalSeconds = Int(time)
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let seconds = totalSeconds % 60

    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    } else {
        return String(format: "%d:%02d", minutes, seconds)
    }
}
#endif
