//
//  ModeEditorOutput.swift
//  Axii
//
//  Output section: destination checkboxes with inline config.
//

#if os(macOS)
import SwiftUI

struct ModeEditorOutput: View {
    @Binding var config: ModeConfig
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send results to:")
                .font(.subheadline.bold())

            // Paste at cursor
            destinationToggle(
                label: "Paste at cursor",
                isEnabled: hasPaste,
                onToggle: { togglePaste($0) }
            )
            if let pasteIndex = pasteIndex {
                pasteConfig(index: pasteIndex)
                    .padding(.leading, 24)
                    .transition(.opacity)
            }

            // Clipboard
            destinationToggle(
                label: "Copy to clipboard",
                isEnabled: hasClipboard,
                onToggle: { toggleClipboard($0) }
            )

            // Display
            destinationToggle(
                label: "Show in panel",
                isEnabled: hasDisplay,
                onToggle: { toggleDisplay($0) }
            )

            // File
            destinationToggle(
                label: "Save to file",
                isEnabled: hasFile,
                onToggle: { toggleFile($0) }
            )
            if let fileIndex = fileIndex {
                fileConfig(index: fileIndex)
                    .padding(.leading, 24)
                    .transition(.opacity)
            }

            // History
            destinationToggle(
                label: "Save to history",
                isEnabled: hasHistory,
                onToggle: { toggleHistory($0) }
            )
            if let historyIndex = historyIndex {
                historyConfig(index: historyIndex)
                    .padding(.leading, 24)
                    .transition(.opacity)
            }

            // Warning
            if config.outputs.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text("No outputs selected. Mode will run but discard results.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Toggle Helper

    private func destinationToggle(label: String, isEnabled: Bool, onToggle: @escaping (Bool) -> Void) -> some View {
        Toggle(label, isOn: Binding(
            get: { isEnabled },
            set: { onToggle($0) }
        ))
    }

    // MARK: - Paste Config

    @ViewBuilder
    private func pasteConfig(index: Int) -> some View {
        if case .pasteAtCursor(let paste) = config.outputs[index] {
            VStack(alignment: .leading, spacing: 6) {
                Picker("If paste fails:", selection: Binding(
                    get: { paste.failureBehavior },
                    set: {
                        config.outputs[index] = .pasteAtCursor(PasteConfig(failureBehavior: $0, restoreClipboard: paste.restoreClipboard))
                        onSave()
                    }
                )) {
                    ForEach(InsertionFailureBehavior.allCases, id: \.self) { behavior in
                        Text(behavior.displayName).tag(behavior)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 280)

                Toggle("Restore clipboard after paste", isOn: Binding(
                    get: { paste.restoreClipboard },
                    set: {
                        config.outputs[index] = .pasteAtCursor(PasteConfig(failureBehavior: paste.failureBehavior, restoreClipboard: $0))
                        onSave()
                    }
                ))
            }
            .font(.caption)
        }
    }

    // MARK: - File Config

    @ViewBuilder
    private func fileConfig(index: Int) -> some View {
        if case .file(let fileOutput) = config.outputs[index] {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Path:")
                    TextField("~/Documents/{mode_name}/{date}.md", text: Binding(
                        get: { fileOutput.pathTemplate },
                        set: {
                            var updated = fileOutput
                            updated.pathTemplate = $0
                            config.outputs[index] = .file(updated)
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { onSave() }
                }

                Picker("Write mode:", selection: Binding(
                    get: { fileOutput.writeMode },
                    set: {
                        var updated = fileOutput
                        updated.writeMode = $0
                        config.outputs[index] = .file(updated)
                        onSave()
                    }
                )) {
                    Text("Append").tag(FileWriteMode.append)
                    Text("Overwrite").tag(FileWriteMode.overwrite)
                    Text("New file each time").tag(FileWriteMode.newFile)
                }
                .pickerStyle(.menu)
                .frame(width: 250)

                Text("Variables: {date}, {time}, {year}, {month}, {day}, {mode_name}, {app_name}")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
        }
    }

    // MARK: - History Config

    @ViewBuilder
    private func historyConfig(index: Int) -> some View {
        if case .history(let hist) = config.outputs[index] {
            Toggle("Save audio recording", isOn: Binding(
                get: { hist.saveAudio },
                set: {
                    config.outputs[index] = .history(HistoryConfig(saveAudio: $0, audioFormat: hist.audioFormat))
                    onSave()
                }
            ))
            .font(.caption)
        }
    }

    // MARK: - Index Helpers

    private var pasteIndex: Int? {
        config.outputs.firstIndex { if case .pasteAtCursor = $0 { return true }; return false }
    }
    private var fileIndex: Int? {
        config.outputs.firstIndex { if case .file = $0 { return true }; return false }
    }
    private var historyIndex: Int? {
        config.outputs.firstIndex { if case .history = $0 { return true }; return false }
    }

    private var hasPaste: Bool { pasteIndex != nil }
    private var hasClipboard: Bool {
        config.outputs.contains { if case .clipboard = $0 { return true }; return false }
    }
    private var hasDisplay: Bool {
        config.outputs.contains { if case .display = $0 { return true }; return false }
    }
    private var hasFile: Bool { fileIndex != nil }
    private var hasHistory: Bool { historyIndex != nil }

    // MARK: - Toggle Actions

    private func togglePaste(_ on: Bool) {
        if on { config.outputs.append(.pasteAtCursor(PasteConfig())) }
        else if let i = pasteIndex { config.outputs.remove(at: i) }
        onSave()
    }

    private func toggleClipboard(_ on: Bool) {
        if on { config.outputs.append(.clipboard) }
        else if let i = config.outputs.firstIndex(where: { if case .clipboard = $0 { return true }; return false }) {
            config.outputs.remove(at: i)
        }
        onSave()
    }

    private func toggleDisplay(_ on: Bool) {
        if on { config.outputs.append(.display) }
        else if let i = config.outputs.firstIndex(where: { if case .display = $0 { return true }; return false }) {
            config.outputs.remove(at: i)
        }
        onSave()
    }

    private func toggleFile(_ on: Bool) {
        if on {
            config.outputs.append(.file(FileOutputConfig(
                pathTemplate: "~/Documents/Axii/{mode_name}/{date}.md"
            )))
        } else if let i = fileIndex { config.outputs.remove(at: i) }
        onSave()
    }

    private func toggleHistory(_ on: Bool) {
        if on { config.outputs.append(.history(HistoryConfig())) }
        else if let i = historyIndex { config.outputs.remove(at: i) }
        onSave()
    }
}
#endif
