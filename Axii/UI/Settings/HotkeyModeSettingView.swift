//
//  HotkeyModeSettingView.swift
//  Axii
//
//  UI for switching between Standard and Advanced hotkey modes.
//

#if os(macOS)
import SwiftUI

struct HotkeyModeSettingView: View {
    let currentMode: HotkeyMode
    let isPermissionGranted: Bool
    let onModeChange: (HotkeyMode) -> Void
    let onRequestPermission: () -> Void

    @State private var showingAdvancedConfirmation = false
    @State private var showingStandardConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hotkey Mode")
                .font(.headline)

            HStack(spacing: 12) {
                Picker("Mode", selection: Binding(
                    get: { currentMode },
                    set: { newMode in
                        if newMode == .advanced && currentMode == .standard {
                            showingAdvancedConfirmation = true
                        } else if newMode == .standard && currentMode == .advanced {
                            showingStandardConfirmation = true
                        }
                    }
                )) {
                    Text("Standard").tag(HotkeyMode.standard)
                    Text("Advanced").tag(HotkeyMode.advanced)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)

                if currentMode == .advanced {
                    if isPermissionGranted {
                        Label("Input Monitoring granted", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Button("Grant Permission") {
                            onRequestPermission()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }

            Text(helpText)
                .font(.caption)
                .foregroundStyle(.secondary)

            if currentMode == .advanced && !isPermissionGranted {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Hotkeys won't work until Input Monitoring permission is granted.")
                        .font(.caption)
                }
            }
        }
        .alert("Switch to Advanced Mode?", isPresented: $showingAdvancedConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Switch to Advanced") {
                onModeChange(.advanced)
            }
        } message: {
            Text("This will:\n• Reset all your hotkeys to defaults\n• Require Input Monitoring permission\n\nYou'll be able to use the Fn key in your shortcuts.")
        }
        .alert("Switch to Standard Mode?", isPresented: $showingStandardConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Switch to Standard") {
                onModeChange(.standard)
            }
        } message: {
            Text("This will reset all your hotkeys to defaults.\nThe Fn key will no longer be available.")
        }
    }

    private var helpText: String {
        switch currentMode {
        case .standard:
            return "Standard mode uses Control, Option, Shift, and Command modifiers."
        case .advanced:
            return "Advanced mode adds Fn key support. Requires Input Monitoring permission."
        }
    }
}
#endif
