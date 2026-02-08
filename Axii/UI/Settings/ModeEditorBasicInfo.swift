//
//  ModeEditorBasicInfo.swift
//  Axii
//
//  Basic Info section: name, icon, hotkey.
//

#if os(macOS)
import SwiftUI

struct ModeEditorBasicInfo: View {
    @Binding var config: ModeConfig
    let settings: SettingsService
    let onSave: () -> Void

    private static let commonIcons: [(symbol: String, name: String)] = [
        ("mic.fill", "Microphone"),
        ("bubble.left.and.bubble.right.fill", "Conversation"),
        ("person.2.fill", "People"),
        ("doc.text.fill", "Document"),
        ("clipboard.fill", "Clipboard"),
        ("folder.fill", "Folder"),
        ("note.text", "Note"),
        ("pencil", "Pencil"),
        ("waveform", "Waveform"),
        ("brain.head.profile", "Brain"),
        ("text.bubble.fill", "Text Bubble"),
        ("quote.bubble.fill", "Quote"),
        ("book.fill", "Book"),
        ("list.bullet", "List"),
        ("checkmark.circle.fill", "Checkmark"),
        ("star.fill", "Star"),
        ("heart.fill", "Heart"),
        ("bolt.fill", "Bolt"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Name
            HStack {
                Text("Name")
                    .frame(width: 80, alignment: .trailing)
                TextField("Mode name", text: $config.name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { onSave() }
            }

            // Icon
            HStack {
                Text("Icon")
                    .frame(width: 80, alignment: .trailing)
                Picker("", selection: $config.icon) {
                    ForEach(Self.commonIcons, id: \.symbol) { icon in
                        Label(icon.name, systemImage: icon.symbol).tag(icon.symbol)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 200)
                .onChange(of: config.icon) { onSave() }
            }

            // Hotkey
            HStack(alignment: .top) {
                Text("Hotkey")
                    .frame(width: 80, alignment: .trailing)
                HotkeySettingView(
                    hotkeyConfig: config.hotkey ?? .default,
                    onUpdate: { newHotkey in
                        config.hotkey = newHotkey
                        onSave()
                    },
                    onReset: {
                        config.hotkey = nil
                        onSave()
                    },
                    onStartRecording: { settings.startHotkeyRecording() },
                    onStopRecording: { settings.stopHotkeyRecording() },
                    allowFnKey: settings.hotkeyMode == .advanced
                )
            }
        }
    }
}
#endif
