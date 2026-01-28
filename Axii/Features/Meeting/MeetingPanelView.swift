//
//  MeetingPanelView.swift
//  Axii
//
//  Main panel view that switches between compact and expanded modes.
//

#if os(macOS)
import SwiftUI

/// Panel mode for meeting view.
enum MeetingPanelMode: String, Codable {
    case compact
    case expanded
}

/// Main meeting panel view - switches between compact and expanded.
struct MeetingPanelView: View {
    var state: MeetingState
    var animationStyle: MeetingAnimationStyle
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onClose: (() -> Void)?
    var onMicrophoneSwitch: ((AudioDevice?) -> Void)?
    var onAppSelect: ((AudioApp?) -> Void)?
    var onRefreshApps: (() -> Void)?
    var onModeChange: ((MeetingPanelMode) -> Void)?

    var body: some View {
        Group {
            switch state.panelMode {
            case .compact:
                MeetingCompactView(
                    animationStyle: animationStyle,
                    audioLevel: state.audioLevel,
                    duration: state.duration,
                    isRecording: state.isRecording,
                    onExpand: { onModeChange?(.expanded) },
                    onStop: onStop
                )
            case .expanded:
                MeetingExpandedView(
                    state: state,
                    onCollapse: { onModeChange?(.compact) },
                    onClose: onClose,
                    onStart: onStart,
                    onStop: onStop,
                    onMicrophoneSwitch: onMicrophoneSwitch,
                    onAppSelect: onAppSelect,
                    onRefreshApps: onRefreshApps
                )
            }
        }
        .animation(.easeInOut(duration: 0.2), value: state.panelMode)
    }
}

// MARK: - Previews

#Preview("Expanded - Ready") {
    let state = MeetingState()
    state.phase = .ready
    state.panelMode = .expanded
    return MeetingPanelView(state: state, animationStyle: .pulsingDot)
        .padding(20)
        .background(.black.opacity(0.8))
}

#Preview("Compact - Recording") {
    let state = MeetingState()
    state.phase = .recording
    state.panelMode = .compact
    state.duration = 125
    state.audioLevel = 0.5
    return MeetingPanelView(state: state, animationStyle: .pulsingDot)
        .padding(20)
        .background(.black.opacity(0.8))
}

#Preview("Expanded - Recording") {
    let state = MeetingState()
    state.phase = .recording
    state.panelMode = .expanded
    state.duration = 65
    state.segments = [
        MeetingSegment(text: "Hello everyone", speakerId: "You", isFromMicrophone: true, startTime: 5, endTime: 10)
    ]
    return MeetingPanelView(state: state, animationStyle: .waveform)
        .padding(20)
        .background(.black.opacity(0.8))
}
#endif
