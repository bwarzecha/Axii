//
//  ModeEditorAudioInput.swift
//  Axii
//
//  Audio Input section: source type, device preference, app selection.
//

#if os(macOS)
import SwiftUI

struct ModeEditorAudioInput: View {
    @Binding var config: ModeConfig
    let onSave: () -> Void

    private var isDual: Bool {
        config.audioCapture.isDual
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Source type
            VStack(alignment: .leading, spacing: 6) {
                Text("Source")
                    .font(.subheadline.bold())

                Picker("", selection: Binding(
                    get: { isDual },
                    set: { switchAudioSource(dual: $0) }
                )) {
                    Text("Microphone only").tag(false)
                    Text("Microphone + System Audio").tag(true)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            // Device preference
            VStack(alignment: .leading, spacing: 6) {
                Text("Device preference")
                    .font(.subheadline.bold())

                Picker("", selection: Binding(
                    get: { devicePreference },
                    set: { setDevicePreference($0) }
                )) {
                    Text("System Default").tag(DevicePreference.systemDefault)
                    Text("Remember last used").tag(DevicePreference.lastUsed)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 200)
            }

            // App selection (only for dual capture)
            if isDual {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Capture audio from")
                        .font(.subheadline.bold())

                    Picker("", selection: Binding(
                        get: { dualConfig?.appSelection ?? .all },
                        set: { setAppSelection($0) }
                    )) {
                        Text("All applications").tag(AppSelectionConfig.all)
                        Text("User-selected application").tag(AppSelectionConfig.userSelected)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - Helpers

    private var devicePreference: DevicePreference {
        switch config.audioCapture {
        case .simple(let c): return c.devicePreference
        case .dual(let c): return c.devicePreference
        }
    }

    private var dualConfig: DualCaptureConfig? {
        if case .dual(let c) = config.audioCapture { return c }
        return nil
    }

    private func switchAudioSource(dual: Bool) {
        if dual {
            config.audioCapture = .dual(DualCaptureConfig(
                devicePreference: devicePreference
            ))
        } else {
            config.audioCapture = .simple(SimpleCaptureConfig(
                devicePreference: devicePreference
            ))
        }
        onSave()
    }

    private func setDevicePreference(_ pref: DevicePreference) {
        switch config.audioCapture {
        case .simple(var c):
            c.devicePreference = pref
            config.audioCapture = .simple(c)
        case .dual(var c):
            c.devicePreference = pref
            config.audioCapture = .dual(c)
        }
        onSave()
    }

    private func setAppSelection(_ sel: AppSelectionConfig) {
        if case .dual(var c) = config.audioCapture {
            c.appSelection = sel
            config.audioCapture = .dual(c)
            onSave()
        }
    }
}
#endif
