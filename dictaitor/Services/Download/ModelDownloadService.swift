//
//  ModelDownloadService.swift
//  dictaitor
//
//  Orchestrates model downloads with progress tracking.
//

#if os(macOS)
import Foundation

@MainActor @Observable
final class ModelDownloadService {
    // MARK: - Observable State

    private(set) var asrState: ModelDownloadState = .idle
    private(set) var ttsState: ModelDownloadState = .idle
    private(set) var diarizationState: ModelDownloadState = .idle

    // MARK: - Cache Paths

    /// Base directory for ASR and Diarization models
    let modelsDirectory: URL

    /// TTS uses a different cache location (FluidAudio hardcoded path)
    let ttsCacheDirectory: URL

    // MARK: - Private

    private let downloader = HuggingFaceDownloader()
    private var activeTasks: [ModelCategory: Task<Void, Never>] = [:]

    // Per-model download tracking
    private var downloadedBytes: [ModelCategory: Int64] = [:]
    private var totalBytes: [ModelCategory: Int64] = [:]

    // MARK: - Init

    init() {
        // All models stored in ~/Library/Application Support/dictaitor/Models/
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!

        let baseDir = appSupport.appendingPathComponent("dictaitor", isDirectory: true)
        modelsDirectory = baseDir.appendingPathComponent("Models", isDirectory: true)

        // TTS also uses the same Models directory
        ttsCacheDirectory = modelsDirectory

        // Check model availability synchronously on init
        checkExistingDownloadsSync()
    }

    /// Synchronous check of existing downloads (called during init)
    private func checkExistingDownloadsSync() {
        asrState = modelsExist(for: .asr) ? .completed : .idle
        ttsState = modelsExist(for: .tts) ? .completed : .idle
        diarizationState = modelsExist(for: .diarization) ? .completed : .idle
    }

    // MARK: - Public API

    /// Check what's already downloaded
    func checkExistingDownloads() async {
        asrState = .checking
        ttsState = .checking
        diarizationState = .checking

        // Small delay to show checking state
        try? await Task.sleep(nanoseconds: 100_000_000)

        asrState = modelsExist(for: .asr) ? .completed : .idle
        ttsState = modelsExist(for: .tts) ? .completed : .idle
        diarizationState = modelsExist(for: .diarization) ? .completed : .idle
    }

    /// Download ASR models (required)
    func downloadASR() async throws {
        try await download(category: .asr)
    }

    /// Download TTS models (optional)
    func downloadTTS() async throws {
        try await download(category: .tts)
    }

    /// Download Diarization models (optional)
    func downloadDiarization() async throws {
        try await download(category: .diarization)
    }

    /// Skip an optional model
    func skip(_ category: ModelCategory) {
        guard !category.isRequired else { return }
        setState(.skipped, for: category)
    }

    /// Retry a failed download
    func retry(_ category: ModelCategory) async throws {
        try await download(category: category)
    }

    /// Cancel download for a category
    func cancel(_ category: ModelCategory) {
        activeTasks[category]?.cancel()
        activeTasks[category] = nil
        setState(.idle, for: category)
    }

    /// Get directory path for a model category
    func cacheDirectory(for category: ModelCategory) -> URL {
        switch category {
        case .tts:
            return ttsCacheDirectory.appendingPathComponent(category.folderName, isDirectory: true)
        case .asr, .diarization:
            return modelsDirectory.appendingPathComponent(category.folderName, isDirectory: true)
        }
    }

    // MARK: - Download Logic

    private func download(category: ModelCategory) async throws {
        // Cancel any existing download for this category
        activeTasks[category]?.cancel()

        // Reset progress
        downloadedBytes[category] = 0
        totalBytes[category] = 0

        setState(.downloading(bytesDownloaded: 0, totalBytes: 0), for: category)

        do {
            // List all files in the repo
            let allFiles = try await downloader.listAllFiles(repo: category.repoPath)

            // Filter to required model files
            let modelFiles = filterRequiredFiles(allFiles, for: category)

            guard !modelFiles.isEmpty else {
                throw ModelDownloadError.fileNotFound(path: category.repoPath)
            }

            // Calculate total size
            let total = modelFiles.reduce(0) { $0 + ($1.size ?? 0) }
            totalBytes[category] = total
            setState(.downloading(bytesDownloaded: 0, totalBytes: total), for: category)

            // Destination directory
            let destDir = cacheDirectory(for: category)
            try FileManager.default.createDirectory(
                at: destDir,
                withIntermediateDirectories: true
            )

            // Download each file
            var cumulativeDownloaded: Int64 = 0

            for file in modelFiles {
                try Task.checkCancellation()

                let destPath = destDir.appendingPathComponent(file.path)

                // Skip if already exists
                if FileManager.default.fileExists(atPath: destPath.path) {
                    cumulativeDownloaded += file.size ?? 0
                    downloadedBytes[category] = cumulativeDownloaded
                    setState(
                        .downloading(bytesDownloaded: cumulativeDownloaded, totalBytes: total),
                        for: category
                    )
                    continue
                }

                let fileStartBytes = cumulativeDownloaded

                _ = try await downloader.downloadFile(
                    repo: category.repoPath,
                    filePath: file.path,
                    to: destPath,
                    progress: { [weak self] bytesWritten, _ in
                        guard let self = self else { return }
                        let newTotal = fileStartBytes + bytesWritten
                        self.downloadedBytes[category] = newTotal
                        self.setState(
                            .downloading(bytesDownloaded: newTotal, totalBytes: total),
                            for: category
                        )
                    }
                )

                cumulativeDownloaded += file.size ?? 0
                downloadedBytes[category] = cumulativeDownloaded
            }

            // Verify download
            if modelsExist(for: category) {
                setState(.completed, for: category)
            } else {
                throw ModelDownloadError.verificationFailed(model: category.rawValue)
            }

        } catch is CancellationError {
            setState(.idle, for: category)
            throw ModelDownloadError.cancelled
        } catch {
            setState(.failed(error: error.localizedDescription), for: category)
            throw error
        }
    }

    /// Filter files to only those needed for required models
    private func filterRequiredFiles(_ files: [HFFileInfo], for category: ModelCategory) -> [HFFileInfo] {
        let required = category.requiredFiles

        return files.filter { file in
            // Check if file belongs to a required model directory
            for requiredFile in required {
                if requiredFile.hasSuffix(".mlmodelc") {
                    // It's a directory, check if file is inside it
                    let dirPrefix = requiredFile.replacingOccurrences(of: ".mlmodelc", with: ".mlmodelc/")
                    if file.path.hasPrefix(requiredFile) || file.path.hasPrefix(dirPrefix) {
                        return true
                    }
                    // Also check without trailing slash
                    if file.path.hasPrefix(requiredFile.dropLast(9) + ".mlmodelc") {
                        return true
                    }
                } else {
                    // Regular file (e.g., vocab.json)
                    if file.path == requiredFile || file.path.hasSuffix("/\(requiredFile)") {
                        return true
                    }
                }
            }
            return false
        }
    }

    /// Check if models exist for a category
    private func modelsExist(for category: ModelCategory) -> Bool {
        let destDir = cacheDirectory(for: category)

        for requiredFile in category.requiredFiles {
            let filePath = destDir.appendingPathComponent(requiredFile)
            if !FileManager.default.fileExists(atPath: filePath.path) {
                return false
            }
        }

        return true
    }

    /// Update state for a category
    private func setState(_ state: ModelDownloadState, for category: ModelCategory) {
        switch category {
        case .asr:
            asrState = state
        case .tts:
            ttsState = state
        case .diarization:
            diarizationState = state
        }
    }
}

// MARK: - Convenience

extension ModelDownloadService {
    /// True if ASR is ready (required for basic functionality)
    var isASRReady: Bool {
        asrState.isComplete
    }

    /// True if TTS is ready
    var isTTSReady: Bool {
        ttsState.isComplete
    }

    /// True if Diarization is ready
    var isDiarizationReady: Bool {
        diarizationState.isComplete
    }

    /// True if any download is in progress
    var isDownloading: Bool {
        asrState.isDownloading || ttsState.isDownloading || diarizationState.isDownloading
    }

    /// Start all downloads (ASR required, others optional)
    func startAllDownloads() {
        Task {
            if !asrState.isComplete && !asrState.isDownloading {
                try? await downloadASR()
            }
        }
        Task {
            if !ttsState.isComplete && !ttsState.isDownloading && ttsState != .skipped {
                try? await downloadTTS()
            }
        }
        Task {
            if !diarizationState.isComplete && !diarizationState.isDownloading && diarizationState != .skipped {
                try? await downloadDiarization()
            }
        }
    }
}
#endif
