//
//  ModeFeaturePanel.swift
//  Axii
//
//  Panel content construction: which SwiftUI view a mode's panel hosts,
//  and the callback wiring from view controls into the runtime.
//

#if os(macOS)
import SwiftUI

extension ModeFeature {

    var panelContent: AnyView {
        switch config.panel.layout {
        case .standard:
            AnyView(StandardPanelView(
                state: state, config: config, hotkeyHint: hotkeyHint,
                onStart: { [weak self] in self?.handleStartButton() },
                onStop: { [weak self] in self?.handleStopButton() },
                onClose: { [weak self] in self?.handleCloseButton() },
                onMicrophoneSwitch: { [weak self] in self?.switchMicrophone(to: $0) },
                onAppSelect: { [weak self] in self?.meetingHandler?.selectApp($0) },
                onRefreshApps: { [weak self] in Task { await self?.meetingHandler?.refreshAppList() } },
                onModeChange: { [weak self] in self?.state.panelMode = $0 },
                onCopy: { [weak self] in self?.copyAndDismiss($0) },
                onCopyLive: { [weak self] in self?.copyLiveTranscript() }
            ))
        case .conversation:
            AnyView(ModeConversationView(
                state: state, config: config, hotkeyHint: hotkeyHint,
                onMicrophoneSwitch: { [weak self] in self?.switchMicrophone(to: $0) },
                onCopy: { [weak self] in self?.copyAndDismiss($0) }
            ))
        }
    }
}
#endif
