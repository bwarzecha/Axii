//
//  FloatingPanel.swift
//  dictaitor
//
//  Floating panel that stays on top of all windows without stealing focus.
//

import AppKit
import HotKey
import SwiftUI

/// Controller that manages the floating panel lifecycle.
@MainActor
final class FloatingPanelController: NSObject {
    private let panel: NonActivatingPanel
    private let hostingView: NSHostingView<AnyView>
    private var onDismiss: (() -> Void)?
    private var escapeHotKey: HotKey?

    /// Creates a floating panel with the given SwiftUI content.
    init<Content: View>(content: Content) {
        let contentSize = NSSize(width: 280, height: 120)

        panel = NonActivatingPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )

        // Floating behavior
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        // Appearance
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .utilityWindow

        // Content
        hostingView = NSHostingView(rootView: AnyView(content))
        hostingView.frame = NSRect(origin: .zero, size: contentSize)
        panel.contentView = hostingView

        super.init()
        panel.delegate = self
    }

    /// Updates the panel content with new SwiftUI view.
    func updateContent<Content: View>(_ content: Content) {
        hostingView.rootView = AnyView(content)
    }

    /// Shows the panel centered at the top of the main screen.
    func show() {
        positionAtTopCenter()
        panel.orderFrontRegardless()
        startEscapeMonitor()
    }

    /// Hides the panel.
    func hide() {
        stopEscapeMonitor()
        panel.orderOut(nil)
    }

    private func startEscapeMonitor() {
        guard escapeHotKey == nil else { return }
        // Use HotKey library for Escape - no modifiers needed
        escapeHotKey = HotKey(key: .escape, modifiers: [])
        escapeHotKey?.keyDownHandler = { [weak self] in
            Task { @MainActor [weak self] in
                self?.hide()
                self?.onDismiss?()
            }
        }
    }

    private func stopEscapeMonitor() {
        escapeHotKey = nil  // Setting to nil unregisters the hotkey
    }

    /// Returns whether the panel is currently visible.
    var isVisible: Bool {
        panel.isVisible
    }

    /// Toggles panel visibility.
    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    /// Sets a callback for when panel is dismissed (e.g., via Escape).
    func setDismissHandler(_ handler: @escaping () -> Void) {
        self.onDismiss = handler
    }

    private func positionAtTopCenter() {
        guard let screen = NSScreen.main else { return }
        let margin: CGFloat = 80
        let panelSize = panel.frame.size
        let screenFrame = screen.visibleFrame
        let origin = NSPoint(
            x: screenFrame.midX - panelSize.width * 0.5,
            y: screenFrame.maxY - panelSize.height - margin
        )
        panel.setFrame(NSRect(origin: origin, size: panelSize), display: false)
    }

}

extension FloatingPanelController: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        // Panel stays visible even when not key
    }
}

/// Custom NSPanel that doesn't steal focus from other apps.
private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func mouseDown(with event: NSEvent) {
        // Enable dragging by clicking anywhere on the panel
        if event.type == .leftMouseDown {
            performDrag(with: event)
        } else {
            super.mouseDown(with: event)
        }
    }
}
