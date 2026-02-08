//
//  ModeEditorOutput.swift
//  Axii
//
//  Output section: ordered list of output destinations with inline config.
//  Supports multiple instances of the same type and contentTemplate editors.
//

#if os(macOS)
import SwiftUI

struct ModeEditorOutput: View {
    @Binding var config: ModeConfig
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if config.outputs.isEmpty {
                Text("No outputs. Results will be discarded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(Array(config.outputs.enumerated()), id: \.offset) { index, output in
                    outputRow(index: index, output: output)
                    if index < config.outputs.count - 1 {
                        Divider().padding(.leading, 8)
                    }
                }
            }

            addOutputMenu
        }
    }

    // MARK: - Output Row

    @ViewBuilder
    private func outputRow(index: Int, output: OutputDestination) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(output.shortName)")
                    .font(.subheadline.bold())
                Spacer()
                Button {
                    config.outputs.remove(at: index)
                    onSave()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            outputConfig(index: index, output: output)
                .padding(.leading, 8)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Per-Output Config

    @ViewBuilder
    private func outputConfig(index: Int, output: OutputDestination) -> some View {
        switch output {
        case .pasteAtCursor(let cfg):
            pasteConfigView(index: index, cfg: cfg)
        case .clipboard(let cfg):
            clipboardConfigView(index: index, cfg: cfg)
        case .display(let cfg):
            displayConfigView(index: index, cfg: cfg)
        case .file(let cfg):
            fileConfigView(index: index, cfg: cfg)
        case .history(let cfg):
            historyConfigView(index: index, cfg: cfg)
        }
    }

    // MARK: - Paste Config

    @ViewBuilder
    private func pasteConfigView(index: Int, cfg: PasteConfig) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("If paste fails:", selection: Binding(
                get: { cfg.failureBehavior },
                set: {
                    var updated = cfg; updated.failureBehavior = $0
                    config.outputs[index] = .pasteAtCursor(updated); onSave()
                }
            )) {
                ForEach(InsertionFailureBehavior.allCases, id: \.self) { behavior in
                    Text(behavior.displayName).tag(behavior)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 280)

            Toggle("Restore clipboard after paste", isOn: Binding(
                get: { cfg.restoreClipboard },
                set: {
                    var updated = cfg; updated.restoreClipboard = $0
                    config.outputs[index] = .pasteAtCursor(updated); onSave()
                }
            ))

            contentTemplateEditor(
                template: cfg.contentTemplate,
                onUpdate: {
                    var updated = cfg; updated.contentTemplate = $0
                    config.outputs[index] = .pasteAtCursor(updated); onSave()
                }
            )
        }
        .font(.caption)
    }

    // MARK: - Clipboard Config

    @ViewBuilder
    private func clipboardConfigView(index: Int, cfg: ClipboardConfig) -> some View {
        contentTemplateEditor(
            template: cfg.contentTemplate,
            onUpdate: {
                config.outputs[index] = .clipboard(ClipboardConfig(contentTemplate: $0))
                onSave()
            }
        )
    }

    // MARK: - Display Config

    @ViewBuilder
    private func displayConfigView(index: Int, cfg: DisplayConfig) -> some View {
        contentTemplateEditor(
            template: cfg.contentTemplate,
            onUpdate: {
                config.outputs[index] = .display(DisplayConfig(contentTemplate: $0))
                onSave()
            }
        )
    }

    // MARK: - File Config

    @ViewBuilder
    private func fileConfigView(index: Int, cfg: FileOutputConfig) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Path:")
                TextField("~/Documents/{mode_name}/{date}.md", text: Binding(
                    get: { cfg.pathTemplate },
                    set: {
                        var updated = cfg; updated.pathTemplate = $0
                        config.outputs[index] = .file(updated)
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .onSubmit { onSave() }
            }

            Picker("Write mode:", selection: Binding(
                get: { cfg.writeMode },
                set: {
                    var updated = cfg; updated.writeMode = $0
                    config.outputs[index] = .file(updated); onSave()
                }
            )) {
                Text("Append").tag(FileWriteMode.append)
                Text("Overwrite").tag(FileWriteMode.overwrite)
                Text("New file each time").tag(FileWriteMode.newFile)
            }
            .pickerStyle(.menu)
            .frame(width: 250)

            contentTemplateEditor(
                template: cfg.contentTemplate,
                onUpdate: {
                    var updated = cfg; updated.contentTemplate = $0
                    config.outputs[index] = .file(updated); onSave()
                }
            )
        }
        .font(.caption)
    }

    // MARK: - History Config

    @ViewBuilder
    private func historyConfigView(index: Int, cfg: HistoryConfig) -> some View {
        Toggle("Save audio recording", isOn: Binding(
            get: { cfg.saveAudio },
            set: {
                config.outputs[index] = .history(
                    HistoryConfig(saveAudio: $0, audioFormat: cfg.audioFormat)
                )
                onSave()
            }
        ))
        .font(.caption)
    }

    // MARK: - Content Template Editor

    @ViewBuilder
    private func contentTemplateEditor(
        template: String?,
        onUpdate: @escaping (String?) -> Void
    ) -> some View {
        DisclosureGroup("Content template") {
            VStack(alignment: .leading, spacing: 4) {
                TextEditor(text: Binding(
                    get: { template ?? "" },
                    set: { onUpdate($0.isEmpty ? nil : $0) }
                ))
                .font(.system(.caption, design: .monospaced))
                .frame(height: 50)
                .border(Color.secondary.opacity(0.3))

                variableChips
            }
            .padding(.top, 4)
        }
        .font(.caption)
    }

    // MARK: - Variable Chips

    @ViewBuilder
    private var variableChips: some View {
        let chips = availableVariables
        HStack(spacing: 4) {
            Text("Default: {text}")
                .font(.caption2)
                .foregroundStyle(.secondary)
            ForEach(chips, id: \.self) { chip in
                Text(chip)
                    .font(.caption2.monospaced())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.1))
                    .cornerRadius(4)
            }
        }
    }

    private var availableVariables: [String] {
        var vars = ["{transcription}", "{text}"]
        if config.processing.contains(where: { if case .diarize = $0 { return true }; return false }) {
            vars.append("{segments}")
        }
        for step in config.processing {
            if case .llmTransform(let cfg) = step, let label = cfg.label {
                vars.append("{\(label)}")
            }
        }
        vars += ["{date}", "{time}", "{mode_name}"]
        return vars
    }

    // MARK: - Add Output Menu

    private var addOutputMenu: some View {
        Menu {
            Button("Paste at Cursor") {
                config.outputs.append(.pasteAtCursor(PasteConfig())); onSave()
            }
            Button("Copy to Clipboard") {
                config.outputs.append(.clipboard(ClipboardConfig())); onSave()
            }
            Button("Show in Panel") {
                config.outputs.append(.display(DisplayConfig())); onSave()
            }
            Button("Save to File") {
                config.outputs.append(.file(FileOutputConfig(
                    pathTemplate: "~/Documents/Axii/{mode_name}/{date}.md"
                )))
                onSave()
            }
            Button("Save to History") {
                config.outputs.append(.history(HistoryConfig())); onSave()
            }
        } label: {
            Label("Add Output", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .frame(width: 140)
    }
}
#endif
