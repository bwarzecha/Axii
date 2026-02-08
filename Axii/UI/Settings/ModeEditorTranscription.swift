//
//  ModeEditorTranscription.swift
//  Axii
//
//  Transcription section: batch vs streaming, advanced options.
//

#if os(macOS)
import SwiftUI

struct ModeEditorTranscription: View {
    @Binding var config: ModeConfig
    let onSave: () -> Void

    @State private var showAdvanced = false

    private var isStreaming: Bool {
        if case .streaming = config.transcription { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Mode selection
            VStack(alignment: .leading, spacing: 6) {
                Text("Mode")
                    .font(.subheadline.bold())

                Picker("", selection: Binding(
                    get: { isStreaming },
                    set: { switchTranscriptionMode(streaming: $0) }
                )) {
                    Text("After recording stops (batch)").tag(false)
                    Text("While recording (streaming)").tag(true)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            // Streaming-specific options
            if isStreaming, case .streaming(var streamConfig) = config.transcription {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Show live text during recording", isOn: Binding(
                        get: { streamConfig.enableRealTimeDisplay },
                        set: {
                            streamConfig.enableRealTimeDisplay = $0
                            config.transcription = .streaming(streamConfig)
                            onSave()
                        }
                    ))

                    Toggle("Re-transcribe after stop (higher accuracy)", isOn: Binding(
                        get: { streamConfig.enableFinalTranscription },
                        set: {
                            streamConfig.enableFinalTranscription = $0
                            config.transcription = .streaming(streamConfig)
                            onSave()
                        }
                    ))
                }
                .padding(.leading, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Advanced
            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                advancedOptions
            }
            .font(.subheadline)
        }
    }

    // MARK: - Advanced Options

    @ViewBuilder
    private var advancedOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch config.transcription {
            case .batch(var batchConfig):
                HStack {
                    Text("Minimum duration:")
                    TextField("", value: Binding(
                        get: { batchConfig.minimumDuration },
                        set: {
                            batchConfig.minimumDuration = $0
                            config.transcription = .batch(batchConfig)
                            onSave()
                        }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    Text("seconds")
                        .foregroundStyle(.secondary)
                }

            case .streaming(var streamConfig):
                HStack {
                    Text("Chunk duration:")
                    TextField("", value: Binding(
                        get: { streamConfig.chunkDurationSeconds },
                        set: {
                            streamConfig.chunkDurationSeconds = $0
                            config.transcription = .streaming(streamConfig)
                            onSave()
                        }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    Text("seconds")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, 4)
        .font(.caption)
    }

    // MARK: - Helpers

    private func switchTranscriptionMode(streaming: Bool) {
        if streaming {
            config.transcription = .streaming(StreamingConfig())
        } else {
            config.transcription = .batch(BatchTranscriptionConfig())
        }
        onSave()
    }
}
#endif
