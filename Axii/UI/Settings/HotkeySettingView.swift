//
//  HotkeySettingView.swift
//  Axii
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
    var allowFnKey: Bool = false

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
                            allowFnKey: allowFnKey,
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

            Text(helpText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var helpText: String {
        if allowFnKey {
            return "Press a key with Fn, Control, Option, Shift, or Command."
        } else {
            return "Press a key combination with at least one modifier (Control, Option, Shift, or Command)"
        }
    }

    private func startRecording() {
        onStartRecording()
        isRecording = true
    }

    private func handleKeyPress(_ event: NSEvent, usesFnKey: Bool) {
        let newConfig = HotkeyConfig(from: event, usesFnKey: usesFnKey)
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
    let allowFnKey: Bool
    let onKeyPressed: (NSEvent, Bool) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> HotkeyRecorderNSView {
        let view = HotkeyRecorderNSView()
        view.allowFnKey = allowFnKey
        view.onKeyPressed = onKeyPressed
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ nsView: HotkeyRecorderNSView, context: Context) {
        nsView.allowFnKey = allowFnKey
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
    var allowFnKey: Bool = false
    var onKeyPressed: ((NSEvent, Bool) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            window.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {

        // Escape cancels recording
        if event.keyCode == 53 {
            onCancel?()
            return
        }

        // Check for Fn key if allowed
        let fnPressed = allowFnKey && event.modifierFlags.contains(.function)

        // Check for standard modifiers
        let standardModifiers = event.modifierFlags.intersection([.control, .option, .shift, .command])
        let hasStandardModifier = !standardModifiers.isEmpty

        // Accept if: has standard modifier OR (Fn is allowed AND Fn is pressed)
        if hasStandardModifier || fnPressed {
            onKeyPressed?(event, fnPressed)
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
