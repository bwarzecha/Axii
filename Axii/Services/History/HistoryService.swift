//
//  HistoryService.swift
//  Axii
//
//  Unified storage service for all interaction types.
//  Stores history in ~/Library/Application Support/Axii/history/
//

import Foundation

#if os(macOS)

/// Errors that can occur during history operations
enum HistoryError: LocalizedError {
    case directoryCreationFailed
    case saveFailed(Error)
    case loadFailed(Error)
    case interactionNotFound(UUID)
    case audioWriteFailed(Error)

    var errorDescription: String? {
        switch self {
        case .directoryCreationFailed:
            return "Failed to create history directory"
        case .saveFailed(let error):
            return "Failed to save interaction: \(error.localizedDescription)"
        case .loadFailed(let error):
            return "Failed to load interaction: \(error.localizedDescription)"
        case .interactionNotFound(let id):
            return "Interaction not found: \(id)"
        case .audioWriteFailed(let error):
            return "Failed to write audio file: \(error.localizedDescription)"
        }
    }
}

/// Unified storage service for all interaction types.
/// Caches metadata in memory for instant listing, loads full data on demand.
@MainActor
@Observable
final class HistoryService {
    // MARK: - Public State

    /// Memory cache of all interaction metadata (populated at startup)
    private(set) var cache: [UUID: InteractionMetadata] = [:]

    /// Whether the initial metadata load has completed
    private(set) var isLoaded: Bool = false

    /// Whether history saving is enabled (bound to settings)
    var isEnabled: Bool = true

    // MARK: - Private

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Base directory for history storage
    private var historyDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Axii/history", isDirectory: true)
    }

    // MARK: - Initialization

    init() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    // MARK: - Startup

    /// Load all metadata from disk into memory cache.
    /// Call once at app launch - runs in background.
    func loadAllMetadata() async {
        do {
            try ensureDirectoryExists()
        } catch {
            print("HistoryService: Failed to create directory: \(error)")
            isLoaded = true
            return
        }

        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: historyDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            print("HistoryService: Failed to list history directory: \(error)")
            isLoaded = true
            return
        }

        var loadedCache: [UUID: InteractionMetadata] = [:]

        for url in contents {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }

            let metadataURL = url.appendingPathComponent("metadata.json")
            guard fileManager.fileExists(atPath: metadataURL.path) else {
                continue
            }

            do {
                let data = try Data(contentsOf: metadataURL)
                let metadata = try decoder.decode(InteractionMetadata.self, from: data)
                loadedCache[metadata.id] = metadata
            } catch {
                print("HistoryService: Failed to load metadata from \(url.lastPathComponent): \(error)")
            }
        }

        cache = loadedCache
        isLoaded = true
        print("HistoryService: Loaded \(cache.count) interactions from history")
    }

    // MARK: - Listing (from cache)

    /// List all interaction metadata, sorted by creation date (newest first)
    func listMetadata() -> [InteractionMetadata] {
        cache.values.sorted { $0.createdAt > $1.createdAt }
    }

    /// List interaction metadata filtered by type
    func listMetadata(type: InteractionType) -> [InteractionMetadata] {
        cache.values
            .filter { $0.type == type }
            .sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Full Interaction (on-demand)

    /// Load full interaction data from disk
    func loadInteraction(id: UUID) async throws -> Interaction {
        guard let metadata = cache[id] else {
            throw HistoryError.interactionNotFound(id)
        }

        let folderURL = historyDirectory.appendingPathComponent(metadata.folderName)
        let interactionURL = folderURL.appendingPathComponent("interaction.json")

        do {
            let data = try Data(contentsOf: interactionURL)
            return try decoder.decode(Interaction.self, from: data)
        } catch {
            throw HistoryError.loadFailed(error)
        }
    }

    // MARK: - Save

    /// Save an interaction (writes both metadata.json and interaction.json, updates cache)
    func save(_ interaction: Interaction) async throws {
        guard isEnabled else { return }

        let metadata = interaction.toMetadata()
        let folderURL = historyDirectory.appendingPathComponent(metadata.folderName)

        do {
            try ensureDirectoryExists()
            try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)

            // Write metadata.json
            let metadataData = try encoder.encode(metadata)
            let metadataURL = folderURL.appendingPathComponent("metadata.json")
            try metadataData.write(to: metadataURL)

            // Write interaction.json
            let interactionData = try encoder.encode(interaction)
            let interactionURL = folderURL.appendingPathComponent("interaction.json")
            try interactionData.write(to: interactionURL)

            // Update cache
            cache[metadata.id] = metadata
        } catch {
            throw HistoryError.saveFailed(error)
        }
    }

    /// Update an existing interaction's metadata in cache after modifying it
    func updateMetadata(_ metadata: InteractionMetadata) {
        cache[metadata.id] = metadata
    }

    // MARK: - Delete

    /// Delete an interaction (removes folder and updates cache)
    func delete(id: UUID) async throws {
        guard let metadata = cache[id] else {
            throw HistoryError.interactionNotFound(id)
        }

        let folderURL = historyDirectory.appendingPathComponent(metadata.folderName)

        do {
            try fileManager.removeItem(at: folderURL)
            cache.removeValue(forKey: id)
        } catch {
            throw HistoryError.saveFailed(error)
        }
    }

    // MARK: - Audio Operations

    /// Save audio samples as a WAV file for an interaction
    /// Returns the AudioRecording metadata
    func saveAudio(
        samples: [Float],
        sampleRate: Double,
        for interactionId: UUID
    ) async throws -> AudioRecording {
        guard isEnabled else {
            // Return a placeholder recording without actually saving
            return AudioRecording(
                filename: "",
                duration: Double(samples.count) / sampleRate,
                sampleRate: sampleRate
            )
        }

        guard let metadata = cache[interactionId] else {
            throw HistoryError.interactionNotFound(interactionId)
        }

        let folderURL = historyDirectory.appendingPathComponent(metadata.folderName)
        let audioDir = folderURL.appendingPathComponent("audio")

        try fileManager.createDirectory(at: audioDir, withIntermediateDirectories: true)

        let recordingId = UUID()
        let filename = "audio/\(recordingId.uuidString.lowercased()).wav"
        let fileURL = folderURL.appendingPathComponent(filename)

        do {
            let wavData = createWAVData(samples: samples, sampleRate: sampleRate)
            try wavData.write(to: fileURL)
        } catch {
            throw HistoryError.audioWriteFailed(error)
        }

        let duration = Double(samples.count) / sampleRate
        return AudioRecording(
            id: recordingId,
            filename: filename,
            duration: duration,
            sampleRate: sampleRate
        )
    }

    /// Get the full URL for an audio recording
    func getAudioURL(_ recording: AudioRecording, for interactionId: UUID) -> URL? {
        guard let metadata = cache[interactionId] else { return nil }
        let folderURL = historyDirectory.appendingPathComponent(metadata.folderName)
        return folderURL.appendingPathComponent(recording.filename)
    }

    // MARK: - Private Helpers

    private func ensureDirectoryExists() throws {
        var isDirectory: ObjCBool = false
        if !fileManager.fileExists(atPath: historyDirectory.path, isDirectory: &isDirectory) {
            try fileManager.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        }
    }

    /// Create WAV file data from Float samples (16-bit PCM, mono)
    private func createWAVData(samples: [Float], sampleRate: Double) -> Data {
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let dataSize = UInt32(samples.count * 2)  // 16-bit = 2 bytes per sample
        let fileSize = 36 + dataSize

        var data = Data()

        // RIFF header
        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
        data.append(contentsOf: "WAVE".utf8)

        // fmt chunk
        data.append(contentsOf: "fmt ".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })  // chunk size
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })   // PCM format
        data.append(contentsOf: withUnsafeBytes(of: numChannels.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })

        // data chunk
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })

        // Convert Float samples to 16-bit PCM
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let int16Value = Int16(clamped * Float(Int16.max))
            data.append(contentsOf: withUnsafeBytes(of: int16Value.littleEndian) { Array($0) })
        }

        return data
    }
}

#endif
