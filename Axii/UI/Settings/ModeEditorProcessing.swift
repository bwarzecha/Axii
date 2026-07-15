//
//  ModeEditorProcessing.swift
//  Axii
//
//  Processing section: ordered step list with inline config.
//

#if os(macOS)
import SwiftUI

struct ModeEditorProcessing: View {
    @Binding var config: ModeConfig
    let onSave: () -> Void
    /// Save path for live-typed text (prompt, input template). Debounced so
    /// the cursor does not jump to the end on every keystroke.
    let onTypingSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if config.processing.isEmpty {
                Text("No processing steps. Transcription goes directly to output.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(Array(config.processing.enumerated()), id: \.offset) { index, step in
                    stepRow(index: index, step: step)
                    if index < config.processing.count - 1 {
                        Divider().padding(.leading, 8)
                    }
                }
            }

            addStepMenu
        }
    }

    // MARK: - Step Row

    @ViewBuilder
    private func stepRow(index: Int, step: ProcessingStep) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Step \(index + 1): \(step.shortName)")
                    .font(.subheadline.bold())
                Spacer()
                Button {
                    config.processing.remove(at: index)
                    onSave()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            stepConfig(index: index, step: step)
                .padding(.leading, 8)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Per-Step Config

    @ViewBuilder
    private func stepConfig(index: Int, step: ProcessingStep) -> some View {
        switch step {
        case .diarize(let diarizeConfig):
            diarizeConfigView(index: index, diarizeConfig: diarizeConfig)
        case .segmentMerge(let mergeConfig):
            Toggle("Merge consecutive same-speaker segments", isOn: Binding(
                get: { mergeConfig.mergeConsecutiveSameSpeaker },
                set: {
                    config.processing[index] = .segmentMerge(SegmentMergeConfig(mergeConsecutiveSameSpeaker: $0))
                    onSave()
                }
            ))
            .font(.caption)
        case .llmTransform(let llmConfig):
            llmConfigView(index: index, llmConfig: llmConfig)
        }
    }

    // MARK: - Diarize Config

    @ViewBuilder
    private func diarizeConfigView(index: Int, diarizeConfig: DiarizeConfig) -> some View {
        if config.audioCapture.isDual {
            if case .sourceLabels(let mic, let system) = diarizeConfig.mode {
                HStack {
                    Text("Mic label:")
                    TextField("", text: Binding(
                        get: { mic },
                        set: {
                            let newConfig = DiarizeConfig(mode: .sourceLabels(micLabel: $0, systemLabel: system))
                            config.processing[index] = .diarize(newConfig)
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .onSubmit { onSave() }
                }

                HStack {
                    Text("System label:")
                    TextField("", text: Binding(
                        get: { system },
                        set: {
                            let newConfig = DiarizeConfig(mode: .sourceLabels(micLabel: mic, systemLabel: $0))
                            config.processing[index] = .diarize(newConfig)
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .onSubmit { onSave() }
                }
            }
        } else {
            Text("Uses speaker diarization model to distinguish speakers from single stream.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - LLM Config

    @ViewBuilder
    private func llmConfigView(index: Int, llmConfig: LLMTransformConfig) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Prompt:")
                .font(.caption)
            StableTextEditor(text: llmConfig.systemPrompt) {
                var updated = llmConfig
                updated.systemPrompt = $0
                config.processing[index] = .llmTransform(updated)
                onTypingSave()
            }
            .font(.system(.caption, design: .monospaced))
            .frame(height: 60)
            .border(Color.secondary.opacity(0.3))

            HStack {
                Text("Context:")
                Picker("", selection: Binding(
                    get: { llmConfig.multiTurn },
                    set: {
                        var updated = llmConfig
                        updated.multiTurn = $0
                        config.processing[index] = .llmTransform(updated)
                        onSave()
                    }
                )) {
                    Text("Single request").tag(false)
                    Text("Multi-turn conversation").tag(true)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 200)
            }

            DisclosureGroup("Advanced") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Label:")
                            .font(.caption)
                        TextField("e.g. summary", text: Binding(
                            get: { llmConfig.label ?? "" },
                            set: {
                                var updated = llmConfig
                                updated.label = $0.isEmpty ? nil : $0
                                config.processing[index] = .llmTransform(updated)
                                onTypingSave()
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                    }
                    if let label = llmConfig.label,
                       PipelineContext.reservedLabels.contains(label) {
                        Text("'\(label)' is a built-in variable and will be shadowed")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }

                    Text("Input template:")
                        .font(.caption)
                    StableTextEditor(text: llmConfig.promptTemplate ?? "") {
                        var updated = llmConfig
                        updated.promptTemplate = $0.isEmpty ? nil : $0
                        config.processing[index] = .llmTransform(updated)
                        onTypingSave()
                    }
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 50)
                    .border(Color.secondary.opacity(0.3))

                    templateChips(forStepAt: index)
                }
                .padding(.top, 4)
            }
            .font(.caption)
        }
    }

    // MARK: - Template Chips

    @ViewBuilder
    private func templateChips(forStepAt index: Int) -> some View {
        let labels = labelsBeforeStep(at: index)
        let chips = ["{transcription}", "{text}"]
            + (hasDiarizeStep ? ["{segments}"] : [])
            + labels.map { "{\($0)}" }

        HStack(spacing: 4) {
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

    private func labelsBeforeStep(at index: Int) -> [String] {
        config.processing.prefix(index).compactMap { step in
            if case .llmTransform(let cfg) = step { return cfg.label }
            return nil
        }
    }

    // MARK: - Add Step

    private var addStepMenu: some View {
        Menu {
            Button("Speaker Identification") {
                config.processing.append(.diarize(DiarizeConfig()))
                onSave()
            }

            Button("Merge Speaker Segments") {
                config.processing.append(.segmentMerge(SegmentMergeConfig()))
                onSave()
            }
            .disabled(!hasDiarizeStep)

            Button("AI Transform") {
                config.processing.append(.llmTransform(LLMTransformConfig()))
                onSave()
            }
        } label: {
            Label("Add Processing Step", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .frame(width: 180)
    }

    private var hasDiarizeStep: Bool {
        config.processing.contains { if case .diarize = $0 { return true }; return false }
    }
}
#endif
