//
//  CreditsView.swift
//  Axii
//
//  Displays open source model attributions and licenses.
//

#if os(macOS)
import SwiftUI

struct CreditsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Acknowledgments")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("This app uses the following open source models and libraries:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Divider()

                // CC-BY-4.0 Models (attribution required)
                VStack(alignment: .leading, spacing: 16) {
                    ModelCreditRow(
                        name: "Parakeet TDT",
                        author: "NVIDIA",
                        license: "CC-BY-4.0",
                        url: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3",
                        description: "Speech recognition model"
                    )

                    ModelCreditRow(
                        name: "WeSpeaker",
                        author: "WeNet",
                        license: "CC-BY-4.0",
                        url: "https://github.com/wenet-e2e/wespeaker",
                        description: "Speaker embedding model"
                    )

                    ModelCreditRow(
                        name: "Streaming Sortformer",
                        author: "NVIDIA",
                        license: "CC-BY-4.0",
                        url: "https://huggingface.co/nvidia/diar_streaming_sortformer_4spk-v2",
                        description: "Speaker diarization model"
                    )
                }

                Divider()

                // MIT Licensed Models
                VStack(alignment: .leading, spacing: 16) {
                    ModelCreditRow(
                        name: "pyannote segmentation",
                        author: "pyannote",
                        license: "MIT",
                        url: "https://huggingface.co/pyannote/speaker-diarization-3.1",
                        description: "Speaker segmentation model"
                    )

                    ModelCreditRow(
                        name: "Silero VAD",
                        author: "Silero",
                        license: "MIT",
                        url: "https://github.com/snakers4/silero-vad",
                        description: "Voice activity detection"
                    )
                }

                Spacer(minLength: 20)
            }
            .padding(24)
        }
        .frame(width: 450, height: 420)
    }
}

struct ModelCreditRow: View {
    let name: String
    let author: String
    let license: String
    let url: String
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name)
                    .font(.headline)
                Text("by \(author)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Text(license)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.1))
                    .cornerRadius(4)

                Link(url, destination: URL(string: url)!)
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
        }
    }
}

#Preview {
    CreditsView()
}
#endif
