//
//  HuggingFaceDownloader.swift
//  dictaitor
//
//  URLSession-based downloader with progress tracking for HuggingFace models.
//

import Foundation

/// Callback for download progress updates
typealias DownloadProgressHandler = @MainActor (Int64, Int64) -> Void

/// Callback for download completion
typealias DownloadCompletionHandler = @MainActor (Result<URL, Error>) -> Void

/// Downloads files from HuggingFace with progress tracking
final class HuggingFaceDownloader: NSObject, Sendable {
    private let session: URLSession
    private let baseURL: String

    /// Active download tasks and their handlers
    private let state = DownloaderState()

    init(baseURL: String = "https://huggingface.co") {
        self.baseURL = baseURL

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 1800  // 30 minutes for large files

        // Temporary session, will be replaced in super.init
        self.session = URLSession(configuration: config)

        super.init()

        // Create session with delegate
        let delegateSession = URLSession(
            configuration: config,
            delegate: self,
            delegateQueue: nil
        )

        // Store in state for use
        state.setSession(delegateSession)
    }

    // MARK: - Public API

    /// List files in a HuggingFace repository
    func listFiles(repo: String, path: String = "") async throws -> [HFFileInfo] {
        let apiPath = path.isEmpty ? "tree/main" : "tree/main/\(path)"
        let urlString = "\(baseURL)/api/models/\(repo)/\(apiPath)"

        guard let url = URL(string: urlString) else {
            throw ModelDownloadError.fileNotFound(path: urlString)
        }

        let request = authorizedRequest(url: url)
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ModelDownloadError.invalidResponse(statusCode: -1)
        }

        if httpResponse.statusCode == 429 {
            let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
                .flatMap { Double($0) }
            throw ModelDownloadError.rateLimited(retryAfter: retryAfter)
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ModelDownloadError.invalidResponse(statusCode: httpResponse.statusCode)
        }

        return try JSONDecoder().decode([HFFileInfo].self, from: data)
    }

    /// Recursively list all files in a repository path
    func listAllFiles(repo: String, path: String = "") async throws -> [HFFileInfo] {
        var allFiles: [HFFileInfo] = []
        let items = try await listFiles(repo: repo, path: path)

        for item in items {
            if item.isDirectory {
                let subFiles = try await listAllFiles(repo: repo, path: item.path)
                allFiles.append(contentsOf: subFiles)
            } else {
                allFiles.append(item)
            }
        }

        return allFiles
    }

    /// Download a single file with progress tracking
    func downloadFile(
        repo: String,
        filePath: String,
        to destination: URL,
        progress: @escaping DownloadProgressHandler,
        completion: @escaping DownloadCompletionHandler
    ) {
        let encodedPath = filePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filePath
        let urlString = "\(baseURL)/\(repo)/resolve/main/\(encodedPath)"

        guard let url = URL(string: urlString) else {
            Task { @MainActor in
                completion(.failure(ModelDownloadError.fileNotFound(path: filePath)))
            }
            return
        }

        let request = authorizedRequest(url: url)
        guard let session = state.getSession() else {
            Task { @MainActor in
                completion(.failure(ModelDownloadError.networkUnavailable))
            }
            return
        }

        let task = session.downloadTask(with: request)
        let taskId = task.taskIdentifier

        state.registerTask(
            taskId: taskId,
            destination: destination,
            progress: progress,
            completion: completion
        )

        task.resume()
    }

    /// Download a file and wait for completion
    func downloadFile(
        repo: String,
        filePath: String,
        to destination: URL,
        progress: @escaping DownloadProgressHandler
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            downloadFile(
                repo: repo,
                filePath: filePath,
                to: destination,
                progress: progress,
                completion: { result in
                    continuation.resume(with: result)
                }
            )
        }
    }

    /// Cancel all active downloads
    func cancelAll() {
        state.getSession()?.invalidateAndCancel()
    }

    // MARK: - Private

    private var huggingFaceToken: String? {
        ProcessInfo.processInfo.environment["HF_TOKEN"]
            ?? ProcessInfo.processInfo.environment["HUGGING_FACE_HUB_TOKEN"]
            ?? ProcessInfo.processInfo.environment["HUGGINGFACEHUB_API_TOKEN"]
    }

    private func authorizedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if let token = huggingFaceToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}

// MARK: - URLSessionDownloadDelegate

extension HuggingFaceDownloader: URLSessionDownloadDelegate {

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let taskId = downloadTask.taskIdentifier

        guard let taskInfo = state.getTaskInfo(taskId: taskId) else { return }

        do {
            // Create parent directory if needed
            let parentDir = taskInfo.destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: parentDir,
                withIntermediateDirectories: true
            )

            // Remove existing file if present
            if FileManager.default.fileExists(atPath: taskInfo.destination.path) {
                try FileManager.default.removeItem(at: taskInfo.destination)
            }

            // Move downloaded file to destination
            try FileManager.default.moveItem(at: location, to: taskInfo.destination)

            Task { @MainActor in
                taskInfo.completion(.success(taskInfo.destination))
            }
        } catch {
            Task { @MainActor in
                taskInfo.completion(.failure(error))
            }
        }

        state.removeTask(taskId: taskId)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let taskId = downloadTask.taskIdentifier

        guard let taskInfo = state.getTaskInfo(taskId: taskId) else { return }

        Task { @MainActor in
            taskInfo.progress(totalBytesWritten, totalBytesExpectedToWrite)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error = error else { return }

        let taskId = task.taskIdentifier
        guard let taskInfo = state.getTaskInfo(taskId: taskId) else { return }

        let downloadError: Error
        if (error as NSError).code == NSURLErrorCancelled {
            downloadError = ModelDownloadError.cancelled
        } else if (error as NSError).code == NSURLErrorTimedOut {
            downloadError = ModelDownloadError.timeout
        } else if (error as NSError).code == NSURLErrorNotConnectedToInternet {
            downloadError = ModelDownloadError.networkUnavailable
        } else {
            downloadError = error
        }

        Task { @MainActor in
            taskInfo.completion(.failure(downloadError))
        }

        state.removeTask(taskId: taskId)
    }
}

// MARK: - Thread-safe state management

private final class DownloaderState: @unchecked Sendable {
    private var session: URLSession?
    private var tasks: [Int: TaskInfo] = [:]
    private let lock = NSLock()

    struct TaskInfo {
        let destination: URL
        let progress: DownloadProgressHandler
        let completion: DownloadCompletionHandler
    }

    func setSession(_ session: URLSession) {
        lock.lock()
        defer { lock.unlock() }
        self.session = session
    }

    func getSession() -> URLSession? {
        lock.lock()
        defer { lock.unlock() }
        return session
    }

    func registerTask(
        taskId: Int,
        destination: URL,
        progress: @escaping DownloadProgressHandler,
        completion: @escaping DownloadCompletionHandler
    ) {
        lock.lock()
        defer { lock.unlock() }
        tasks[taskId] = TaskInfo(
            destination: destination,
            progress: progress,
            completion: completion
        )
    }

    func getTaskInfo(taskId: Int) -> TaskInfo? {
        lock.lock()
        defer { lock.unlock() }
        return tasks[taskId]
    }

    func removeTask(taskId: Int) {
        lock.lock()
        defer { lock.unlock() }
        tasks.removeValue(forKey: taskId)
    }
}
