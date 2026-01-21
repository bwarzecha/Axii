//
//  ModelDownloadTypes.swift
//  Axii
//
//  Types for model download with progress tracking.
//

import Foundation

/// Model categories that can be downloaded
enum ModelCategory: String, CaseIterable, Identifiable, Sendable {
    case asr = "Speech Recognition"
    case diarization = "Speaker Diarization"

    var id: String { rawValue }

    var isRequired: Bool { self == .asr }

    /// HuggingFace repository path
    var repoPath: String {
        switch self {
        case .asr:
            return "FluidInference/parakeet-tdt-0.6b-v3-coreml"
        case .diarization:
            return "FluidInference/speaker-diarization-coreml"
        }
    }

    /// Local folder name for caching
    var folderName: String {
        switch self {
        case .asr:
            return "parakeet-tdt-0.6b-v3-coreml"
        case .diarization:
            return "speaker-diarization-coreml"
        }
    }

    /// Required model files (directories ending in .mlmodelc)
    var requiredFiles: Set<String> {
        switch self {
        case .asr:
            return [
                "Encoder.mlmodelc",
                "Decoder.mlmodelc",
                "JointDecision.mlmodelc",
                "Preprocessor.mlmodelc",
                "parakeet_vocab.json"
            ]
        case .diarization:
            return [
                "pyannote_segmentation.mlmodelc",
                "wespeaker_v2.mlmodelc"
            ]
        }
    }

    /// Estimated download size in bytes
    var estimatedSize: Int64 {
        switch self {
        case .asr:
            return 2_500_000_000  // ~2.5 GB
        case .diarization:
            return 200_000_000   // ~200 MB
        }
    }

    /// Human-readable size string
    var sizeString: String {
        switch self {
        case .asr:
            return "~2.5 GB"
        case .diarization:
            return "~200 MB"
        }
    }

    /// Description for UI
    var subtitle: String {
        switch self {
        case .asr:
            return "Required for transcription"
        case .diarization:
            return "Identifies who is speaking"
        }
    }
}

/// State for a single model download
enum ModelDownloadState: Equatable, Sendable {
    case idle
    case checking
    case downloading(bytesDownloaded: Int64, totalBytes: Int64)
    case completed
    case failed(error: String)
    case skipped

    var isComplete: Bool {
        self == .completed
    }

    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    var progress: Double {
        if case .downloading(let downloaded, let total) = self, total > 0 {
            return Double(downloaded) / Double(total)
        }
        return 0
    }

    var progressText: String? {
        if case .downloading(let downloaded, let total) = self {
            return "\(formatBytes(downloaded)) / \(formatBytes(total))"
        }
        return nil
    }

    var errorMessage: String? {
        if case .failed(let error) = self {
            return error
        }
        return nil
    }
}

/// File info from HuggingFace API
struct HFFileInfo: Decodable, Sendable {
    let path: String
    let type: String  // "file" or "directory"
    let size: Int64?

    var isFile: Bool { type == "file" }
    var isDirectory: Bool { type == "directory" }
}

/// Download error types
enum ModelDownloadError: LocalizedError {
    case networkUnavailable
    case rateLimited(retryAfter: TimeInterval?)
    case fileNotFound(path: String)
    case insufficientStorage(required: Int64, available: Int64)
    case downloadInterrupted
    case verificationFailed(model: String)
    case timeout
    case invalidResponse(statusCode: Int)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .networkUnavailable:
            return "Network unavailable"
        case .rateLimited(let retryAfter):
            if let seconds = retryAfter {
                return "Rate limited. Retry in \(Int(seconds)) seconds"
            }
            return "Rate limited. Please try again later"
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .insufficientStorage(let required, let available):
            return "Not enough storage. Need \(formatBytes(required)), have \(formatBytes(available))"
        case .downloadInterrupted:
            return "Download interrupted"
        case .verificationFailed(let model):
            return "Verification failed for \(model)"
        case .timeout:
            return "Download timed out"
        case .invalidResponse(let code):
            return "Invalid response (HTTP \(code))"
        case .cancelled:
            return "Download cancelled"
        }
    }

    var isRetryable: Bool {
        switch self {
        case .networkUnavailable, .rateLimited, .downloadInterrupted, .timeout:
            return true
        case .fileNotFound, .insufficientStorage, .verificationFailed, .invalidResponse, .cancelled:
            return false
        }
    }
}

// MARK: - Helpers

func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}
