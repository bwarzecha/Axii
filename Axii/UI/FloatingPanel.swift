//
//  FloatingPanel.swift
//  Axii
//
//  Floating panel that stays on top of all windows without stealing focus.
//  Content is provided dynamically by features.
//

#if os(macOS)
import AppKit
import SwiftUI

/// Controller that manages the floating panel lifecycle.
/// Content is set dynamically via updateContent().
@MainActor
final class FloatingPanelController: NSObject {
    private let panel: NonActivatingPanel
    private let hostingView: NSHostingView<AnyView>

    /// Callback when panel is dismissed (e.g., by clicking outside).
    var onDismiss: (() -> Void)?

    /// Creates a floating panel with empty placeholder content.
    override init() {
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

        // Start with empty content - features will provide their views
        let placeholder = AnyView(EmptyView())
        hostingView = NSHostingView(rootView: placeholder)
        hostingView.frame = NSRect(origin: .zero, size: contentSize)
        panel.contentView = hostingView

        super.init()
        panel.delegate = self
    }

    /// Updates the panel content with a new SwiftUI view.
    func updateContent(_ view: AnyView) {
        hostingView.rootView = view
    }

    /// Shows the panel centered at the top of the main screen.
    func show() {
        positionAtTopCenter()
        panel.orderFrontRegardless()
    }

    /// Hides the panel.
    func hide() {
        panel.orderOut(nil)
    }

    /// Returns whether the panel is currently visible.
    var isVisible: Bool {
        panel.isVisible
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
#endif
