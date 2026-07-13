//
//  AccessibilityID.swift
//  Axii
//
//  Stable accessibility identifiers for UI controls the E2E suite targets.
//  One constant per control — never inline identifier strings in views.
//  These double as VoiceOver anchors, so treat renames as breaking changes.
//

enum AccessibilityID {
    // Floating panel — compact view
    static let panelStopButton = "panel.stop"
    static let panelExpandButton = "panel.expand"
    static let panelCopyButton = "panel.copy"
    static let panelCopyLiveButton = "panel.copyLive"

    // Floating panel — expanded view
    static let panelActionButton = "panel.action"
    static let panelCollapseButton = "panel.collapse"
    static let panelCloseButton = "panel.close"
    static let panelMicPicker = "panel.micPicker"
    static let panelAppPicker = "panel.appPicker"

    // Floating panel — observable state (values exposed for assertions)
    static let panelPhase = "panel.phase"
    static let panelDuration = "panel.duration"
    static let panelAudioLevel = "panel.audioLevel"
    static let panelTranscript = "panel.transcript"

    // History window
    static let historyList = "history.list"
    static let historyTrashToggle = "history.trashToggle"
    static let historyRestoreButton = "history.restore"
    static let historyDeleteNowButton = "history.deleteNow"
    static let historySearchField = "history.search"
}
