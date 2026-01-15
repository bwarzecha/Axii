//
//  HotkeySettingView.swift
//  dictaitor
//
//  Hotkey configuration with key recorder.
//

#if os(macOS)
import AppKit
import SwiftUI

struct HotkeySettingView: View {
    var hotkeyConfig: HotkeyConfig
    var onUpdate: (HotkeyConfig) -> Void
    var onReset: () -> Void
    var onStartRecording: () -> Void
    var onStopRecording: () -> Void

    @State private var isRecording = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Toggle Recording")
                .font(.headline)

            HStack(spacing: 12) {
                // Recorder button with key capture view
                Button(action: startRecording) {
                    Text(isRecording ? "Press keys..." : hotkeyConfig.displayString)
                        .frame(minWidth: 150)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .background(isRecording ? Color.accentColor.opacity(0.1) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .background {
                    if isRecording {
                        HotkeyRecorderView(
                            onKeyPressed: handleKeyPress,
                            onCancel: cancelRecording
                        )
                    }
                }

                if hotkeyConfig != .default {
                    Button("Reset") {
                        onReset()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            Text("Press a key combination with at least one modifier (Control, Option, Shift, or Command)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func startRecording() {
        onStartRecording()
        isRecording = true
    }

    private func handleKeyPress(_ event: NSEvent) {
        let newConfig = HotkeyConfig(from: event)
        if newConfig.hasModifiers {
            onUpdate(newConfig)
        }
        cancelRecording()
    }

    private func cancelRecording() {
        isRecording = false
        onStopRecording()
    }
}

/// NSViewRepresentable that captures key events via direct keyDown override.
struct HotkeyRecorderView: NSViewRepresentable {
    let onKeyPressed: (NSEvent) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> HotkeyRecorderNSView {
        let view = HotkeyRecorderNSView()
        view.onKeyPressed = onKeyPressed
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ nsView: HotkeyRecorderNSView, context: Context) {
        nsView.onKeyPressed = onKeyPressed
        nsView.onCancel = onCancel

        // Become first responder when shown
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
        }
    }
}

/// NSView that becomes first responder to capture key events.
final class HotkeyRecorderNSView: NSView {
    var onKeyPressed: ((NSEvent) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            window?.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        // Escape cancels recording
        if event.keyCode == 53 {
            onCancel?()
            return
        }

        // Only accept keys with modifiers
        let modifiers = event.modifierFlags.intersection([.control, .option, .shift, .command])
        if !modifiers.isEmpty {
            onKeyPressed?(event)
            return
        }

        // Pass through other keys
        super.keyDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        onCancel?()
        return super.resignFirstResponder()
    }
}
#endif
