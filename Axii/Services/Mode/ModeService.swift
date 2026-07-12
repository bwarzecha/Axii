//
//  ModeService.swift
//  Axii
//
//  Manages loading, saving, and migrating ModeConfig instances.
//  Each mode is stored as a JSON file in the modes directory.
//  Built-in modes get default configs written on first launch.
//

#if os(macOS)
import Foundation
import os.log

private let logger = Logger(subsystem: "com.axii", category: "ModeService")

@MainActor
final class ModeService {
    private let modesDirectory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Create a ModeService using the default Application Support path.
    convenience init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("Axii")
        self.init(modesDirectory: appSupport.appendingPathComponent("Modes"))
    }

    /// Create a ModeService with an injected modes directory.
    /// Use this in tests with a temp directory to avoid touching real user data.
    init(modesDirectory: URL) {
        self.modesDirectory = modesDirectory
        self.encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
    }

    // MARK: - Public API

    func loadAllModes() -> [ModeConfig] {
        ensureDirectoryExists()
        ensureBuiltInModesExist()

        let files = (try? FileManager.default.contentsOfDirectory(
            at: modesDirectory,
            includingPropertiesForKeys: nil
        )) ?? []

        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { loadMode(from: $0) }
            .sorted { $0.name < $1.name }
    }

    func save(_ config: ModeConfig) throws {
        ensureDirectoryExists()
        let fileURL = modeFileURL(for: config.id)
        let data = try encoder.encode(config)
        try data.write(to: fileURL, options: .atomic)
    }

    func delete(id: UUID) throws {
        let fileURL = modeFileURL(for: id)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    func resetToDefault(id: UUID) throws {
        guard let defaultConfig = builtInDefault(for: id) else { return }
        try save(defaultConfig)
    }

    // MARK: - Private

    private func modeFileURL(for id: UUID) -> URL {
        modesDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    private func loadMode(from url: URL) -> ModeConfig? {
        guard let data = try? Data(contentsOf: url) else {
            logger.error("Failed to read mode file: \(url.lastPathComponent)")
            return nil
        }

        // Try direct decode first (fast path)
        if let config = try? decoder.decode(ModeConfig.self, from: data) {
            return config
        }

        // If direct decode fails, try migrating and re-decoding
        if let migrated = migrateJSON(data) {
            do {
                let config = try decoder.decode(ModeConfig.self, from: migrated)
                // Re-save the migrated version so future loads are fast
                try? migrated.write(to: url, options: .atomic)
                logger.info("Migrated mode: \(url.lastPathComponent)")
                return config
            } catch {
                logger.error("Failed to decode migrated mode: \(url.lastPathComponent): \(error.localizedDescription)")
                return nil
            }
        }

        logger.error("Failed to decode mode: \(url.lastPathComponent)")
        return nil
    }

    // MARK: - Migration

    /// Strip unknown processing steps from mode JSON so the mode is preserved.
    /// Returns migrated data, or nil if the JSON is fundamentally broken.
    func migrateJSON(_ data: Data) -> Data? {
        guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let knownStepKeys: Set<String> = ["diarize", "segmentMerge", "llmTransform"]

        if let steps = json["processing"] as? [[String: Any]] {
            let filtered = steps.filter { step in
                step.keys.contains(where: { knownStepKeys.contains($0) })
            }
            if filtered.count != steps.count {
                logger.info("Migration: stripped \(steps.count - filtered.count) unknown processing step(s)")
            }
            json["processing"] = filtered
        }

        return try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    }

    private func ensureDirectoryExists() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: modesDirectory.path) {
            try? fm.createDirectory(at: modesDirectory, withIntermediateDirectories: true)
        }
    }

    private func ensureBuiltInModesExist() {
        let builtIns: [ModeConfig] = [
            DefaultModes.dictation(),
            DefaultModes.conversation(),
            DefaultModes.meeting(),
        ]
        for mode in builtIns {
            let fileURL = modeFileURL(for: mode.id)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                do {
                    // A missing built-in file means first launch — either a
                    // fresh install (no legacy keys; seeding is a no-op) or
                    // an upgrade from the pre-mode-runtime app, whose custom
                    // hotkeys/mics/toggles must carry over.
                    try save(LegacyModeMigration.seeded(mode))
                } catch {
                    logger.error("Failed to write built-in mode \(mode.name): \(error.localizedDescription)")
                }
            }
        }
    }

    private func builtInDefault(for id: UUID) -> ModeConfig? {
        switch id {
        case DefaultModes.dictationId: return DefaultModes.dictation()
        case DefaultModes.conversationId: return DefaultModes.conversation()
        case DefaultModes.meetingId: return DefaultModes.meeting()
        default: return nil
        }
    }
}
#endif
