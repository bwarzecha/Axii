//
//  ModeEditorView.swift
//  Axii
//
//  Unified mode editor. Same form for built-in and custom modes.
//  Auto-saves on field change (no Save/Cancel buttons).
//
//  Section views: ModeEditorBasicInfo.swift, ModeEditorAudioInput.swift,
//  ModeEditorTranscription.swift, ModeEditorProcessing.swift,
//  ModeEditorOutput.swift, ModeEditorBehavior.swift
//

#if os(macOS)
import SwiftUI

struct ModeEditorView: View {
    @State var config: ModeConfig
    let modeService: ModeService
    let settings: SettingsService
    let mediaControlService: MediaControlService
    let onConfigChanged: (ModeConfig) -> Void
    let onDelete: () -> Void
    let onReset: () -> Void
    let onDuplicate: () -> Void

    @State private var expandedSections: Set<EditorSection> = Set(EditorSection.allCases)
    @State private var showDeleteConfirmation = false
    @State private var showResetConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                headerRow
                collapsibleSection(.basicInfo) {
                    ModeEditorBasicInfo(config: $config, settings: settings, onSave: saveConfig)
                }
                collapsibleSection(.audioInput) {
                    ModeEditorAudioInput(config: $config, onSave: saveConfig)
                }
                collapsibleSection(.transcription) {
                    ModeEditorTranscription(config: $config, onSave: saveConfig)
                }
                collapsibleSection(.processing) {
                    ModeEditorProcessing(config: $config, onSave: saveConfig)
                }
                collapsibleSection(.output) {
                    ModeEditorOutput(config: $config, onSave: saveConfig)
                }
                collapsibleSection(.behavior) {
                    ModeEditorBehavior(
                        config: $config,
                        mediaControlService: mediaControlService,
                        onSave: saveConfig
                    )
                }
            }
            .padding()
        }
        .alert("Delete Mode", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Delete \"\(config.name)\"? This cannot be undone.")
        }
        .alert("Reset to Defaults", isPresented: $showResetConfirmation) {
            Button("Reset", role: .destructive) {
                onReset()
                if let fresh = reloadConfig() { config = fresh }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Reset \"\(config.name)\" to default settings?")
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack {
            Image(systemName: config.icon)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(config.name)
                .font(.title2.bold())
            Spacer()
            Button("Duplicate") { onDuplicate() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.caption)
            if config.isBuiltIn {
                Button("Reset to Defaults") { showResetConfirmation = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                Button("Delete Mode", role: .destructive) { showDeleteConfirmation = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
        .padding(.bottom, 4)
    }

    // MARK: - Collapsible Section

    @ViewBuilder
    private func collapsibleSection<Content: View>(
        _ section: EditorSection,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        let isExpanded = expandedSections.contains(section)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded {
                        expandedSections.remove(section)
                    } else {
                        expandedSections.insert(section)
                    }
                }
            } label: {
                HStack {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    Text(section.title)
                        .font(.headline)
                    Spacer()
                    if !isExpanded {
                        Text(sectionSummary(section))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 6)

            if isExpanded {
                content()
                    .padding(.leading, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
            }
        }
        .padding(.horizontal, 4)
        Divider()
    }

    // MARK: - Save

    private func saveConfig() {
        guard (try? modeService.save(config)) != nil else { return }
        onConfigChanged(config)
    }

    private func reloadConfig() -> ModeConfig? {
        modeService.loadAllModes().first { $0.id == config.id }
    }

    // MARK: - Section Summaries

    private func sectionSummary(_ section: EditorSection) -> String {
        switch section {
        case .basicInfo:
            let hotkey = config.hotkey?.symbolString ?? "No hotkey"
            return "\(config.name) \(hotkey)"
        case .audioInput:
            return config.audioCapture.isDual ? "Mic + System Audio" : "Microphone only"
        case .transcription:
            if case .streaming = config.transcription { return "Streaming" }
            return "Batch"
        case .processing:
            if config.processing.isEmpty { return "None" }
            return config.processing.map { $0.shortName }.joined(separator: " → ")
        case .output:
            return config.outputs.map { $0.shortName }.joined(separator: ", ")
        case .behavior:
            if case .autoDismiss(let d) = config.lifecycle.panelPersistence {
                return "Auto-dismiss \(Int(d))s"
            }
            return "Stay open"
        }
    }
}

// MARK: - Editor Sections Enum

enum EditorSection: String, CaseIterable, Hashable {
    case basicInfo
    case audioInput
    case transcription
    case processing
    case output
    case behavior

    var title: String {
        switch self {
        case .basicInfo: return "Basic Info"
        case .audioInput: return "Audio Input"
        case .transcription: return "Transcription"
        case .processing: return "Processing"
        case .output: return "Output"
        case .behavior: return "Behavior"
        }
    }
}

// MARK: - Display Helpers

extension ProcessingStep {
    var shortName: String {
        switch self {
        case .diarize: return "Speaker ID"
        case .segmentMerge: return "Merge"
        case .llmTransform(let cfg):
            if let label = cfg.label { return "AI Transform → \(label)" }
            return "AI Transform"
        }
    }
}

extension OutputDestination {
    var shortName: String {
        switch self {
        case .pasteAtCursor: return "Paste"
        case .clipboard: return "Clipboard"
        case .file: return "File"
        case .display: return "Display"
        case .history: return "History"
        }
    }
}
#endif
