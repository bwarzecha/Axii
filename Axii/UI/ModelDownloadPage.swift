//
//  ModelDownloadPage.swift
//  Axii
//
//  Onboarding page for downloading ML models with progress tracking.
//

#if os(macOS)
import SwiftUI

struct ModelDownloadPage: View {
    let downloadService: ModelDownloadService
    let onComplete: () -> Void

    @State private var hasStartedDownload = false

    var body: some View {
        VStack(spacing: 24) {
            // Header
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.green)

            Text("Download Models")
                .font(.title)
                .bold()

            Text("Axii needs to download ML models for transcription.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            // Model cards
            VStack(spacing: 12) {
                ModelDownloadCard(
                    category: .asr,
                    state: downloadService.asrState,
                    onRetry: { Task { try? await downloadService.downloadASR() } },
                    onSkip: nil  // Required, can't skip
                )

                ModelDownloadCard(
                    category: .diarization,
                    state: downloadService.diarizationState,
                    onRetry: { Task { try? await downloadService.downloadDiarization() } },
                    onSkip: { downloadService.skip(.diarization) }
                )
            }
            .padding(.horizontal, 24)

            Spacer()

            // Continue button (only enabled when ASR is complete)
            if downloadService.isASRReady {
                Button("Continue") {
                    onComplete()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Text("Waiting for Speech Recognition model...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(32)
        .onAppear {
            startDownloadsIfNeeded()
        }
    }

    private func startDownloadsIfNeeded() {
        guard !hasStartedDownload else { return }
        hasStartedDownload = true

        Task {
            await downloadService.checkExistingDownloads()

            // Auto-start ASR download if not complete
            if !downloadService.isASRReady {
                try? await downloadService.downloadASR()
            }

            // Auto-start optional downloads if not complete/skipped
            if downloadService.diarizationState == .idle {
                try? await downloadService.downloadDiarization()
            }
        }
    }
}

// MARK: - Model Download Card

private struct ModelDownloadCard: View {
    let category: ModelCategory
    let state: ModelDownloadState
    let onRetry: () -> Void
    let onSkip: (() -> Void)?

    var body: some View {
        HStack(spacing: 16) {
            // Icon
            categoryIcon
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 32)

            // Info
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(category.rawValue)
                        .font(.headline)

                    if category.isRequired {
                        Text("Required")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.2))
                            .foregroundColor(.blue)
                            .cornerRadius(4)
                    }
                }

                Text(category.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // State indicator
            stateView
        }
        .padding(16)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(12)
    }

    private var categoryIcon: some View {
        Group {
            switch category {
            case .asr:
                Image(systemName: "waveform")
            case .diarization:
                Image(systemName: "person.2")
            }
        }
    }

    @ViewBuilder
    private var stateView: some View {
        switch state {
        case .idle:
            HStack(spacing: 8) {
                Text(category.sizeString)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let onSkip = onSkip {
                    Button("Skip") {
                        onSkip()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

        case .checking:
            ProgressView()
                .scaleEffect(0.7)

        case .downloading(let downloaded, let total):
            VStack(alignment: .trailing, spacing: 4) {
                ProgressView(value: Double(downloaded), total: Double(max(total, 1)))
                    .frame(width: 100)

                Text("\(formatBytes(downloaded)) / \(formatBytes(total))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundColor(.green)

        case .failed(let error):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)

                VStack(alignment: .trailing, spacing: 2) {
                    Button("Retry") {
                        onRetry()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }

        case .skipped:
            HStack(spacing: 8) {
                Text("Skipped")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Download") {
                    onRetry()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}

#endif
