//
//  SimpleCaptureSpool.swift
//  Axii
//
//  Crash spool for simple-mode (dictation/conversation) captures — the
//  counterpart of MeetingAudioManager's recording spool. Samples stream
//  to disk from the moment capture starts: raw float32 at a fixed 16 kHz
//  plus a JSON sidecar, headerless so a process death at any byte leaves
//  a readable file. One spool per capture SESSION (it survives mic
//  switches and the post-stop turn); it is discarded only when the
//  capture reaches a terminal state — delivered to history, durably
//  trashed, or below the salvage threshold. Anything else is an orphan
//  that launch recovery archives into "Recently Deleted".
//

#if os(macOS)
import Foundation
import os.log

private let logger = Logger(subsystem: "com.axii", category: "CaptureSpool")

@MainActor
protocol CaptureSpooling: AnyObject {
    func append(samples: [Float], sampleRate: Double)
    /// Capture-device provenance for the sidecar — which mic actually
    /// fed this spool (diagnosable after a crash, shown on recovery).
    func noteDevice(_ device: AudioDevice?)
    /// Terminal state reached elsewhere: remove the spool from disk.
    func discard()
}

@MainActor
final class SimpleCaptureSpool: CaptureSpooling {

    /// Spool rate. The spool is a crash NET, not the primary artifact
    /// (a delivered turn saves original-quality audio through the normal
    /// path), so the ASR's native rate is enough — and a fixed rate keeps
    /// the file single-rate across mic switches.
    static let sampleRate: Double = 16_000

    /// Sidecar payload. `createdAt` lets recovery restore the recording
    /// under its original date, like meeting recovery does; the device
    /// fields record which mic actually fed the capture.
    struct Sidecar: Codable {
        let createdAt: Date
        let sampleRate: Double
        var deviceName: String?
        var deviceUID: String?
    }

    nonisolated static var spoolDirectory: URL {
        let dir: URL
        if let override = AppLaunchOverrides.recoveryDirectoryOverride() {
            dir = override.appendingPathComponent("InProgressDictations")
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!
            dir = appSupport.appendingPathComponent("Axii/InProgressDictations")
        }
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        return dir
    }

    let dataURL: URL
    let sidecarURL: URL
    private var handle: FileHandle?
    private var sidecarWritten = false
    private let createdAt = Date()
    private var device: AudioDevice?

    init?(directory: URL = SimpleCaptureSpool.spoolDirectory) {
        let name = UUID().uuidString.lowercased()
        dataURL = directory.appendingPathComponent("\(name).pcm")
        sidecarURL = directory.appendingPathComponent("\(name).json")
        guard FileManager.default.createFile(atPath: dataURL.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: dataURL)
        else {
            logger.error("Capture spool could not be created — recording proceeds unspooled")
            return nil
        }
        self.handle = handle
    }

    func noteDevice(_ device: AudioDevice?) {
        self.device = device
        if sidecarWritten { writeSidecar() }
    }

    private func writeSidecar() {
        let sidecar = Sidecar(
            createdAt: createdAt, sampleRate: Self.sampleRate,
            deviceName: device?.name, deviceUID: device?.uid
        )
        if let data = try? JSONEncoder.iso8601.encode(sidecar) {
            try? data.write(to: sidecarURL, options: .atomic)
        }
    }

    func append(samples: [Float], sampleRate: Double) {
        guard let handle, !samples.isEmpty, sampleRate > 0 else { return }
        if !sidecarWritten {
            // Written on first audio, not at init: an aborted start leaves
            // no sidecar, and recovery treats sidecar-less .pcm as noise.
            sidecarWritten = true
            writeSidecar()
        }
        let normalized = sampleRate == Self.sampleRate
            ? samples
            : AudioResampler.resample(samples, from: sampleRate, to: Self.sampleRate)
        normalized.withUnsafeBufferPointer { buffer in
            try? handle.write(contentsOf: Data(buffer: buffer))
        }
    }

    func discard() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: dataURL)
        try? FileManager.default.removeItem(at: sidecarURL)
    }
}

// MARK: - Launch Recovery

/// Archives orphaned capture spools into "Recently Deleted" at launch —
/// runs before any capture starts, so it can never touch a live spool.
enum SimpleCaptureRecovery {

    @MainActor
    static func run(
        history: HistoryService,
        transcriber: any TranscriptionProviding,
        directory: URL = SimpleCaptureSpool.spoolDirectory,
        now: Date = Date(),
        lifetime: TimeInterval = MeetingRecoveryPolicy.artifactLifetime
    ) async {
        // History off is the user's opt-out of persistence: leave the
        // spools alone (they may re-enable within the retention window);
        // the age sweep below still applies at the next enabled launch.
        guard history.isEnabled else { return }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }

        let archiver = DiscardedCaptureArchiver(
            history: history, transcriber: transcriber
        )
        for sidecarURL in files where sidecarURL.pathExtension == "json" {
            let dataURL = sidecarURL.deletingPathExtension()
                .appendingPathExtension("pcm")
            let removeBoth = {
                try? FileManager.default.removeItem(at: dataURL)
                try? FileManager.default.removeItem(at: sidecarURL)
            }
            guard
                let raw = try? Data(contentsOf: sidecarURL),
                let sidecar = try? JSONDecoder.iso8601.decode(
                    SimpleCaptureSpool.Sidecar.self, from: raw
                ),
                let pcm = try? Data(contentsOf: dataURL)
            else {
                removeBoth() // corrupt or half-created: not recoverable
                continue
            }
            guard now.timeIntervalSince(sidecar.createdAt) <= lifetime else {
                removeBoth() // same retention window as every artifact
                continue
            }
            let samples = pcm.withUnsafeBytes {
                Array($0.bindMemory(to: Float.self))
            }
            let seconds = Double(samples.count) / sidecar.sampleRate
            guard seconds >= ModeFeature.discardSalvageMinimumSeconds else {
                removeBoth()
                continue
            }
            logger.info("Recovering crashed capture: \(Int(seconds))s")
            archiver.archive(
                samples: samples, sampleRate: sidecar.sampleRate,
                config: nil, createdAt: sidecar.createdAt,
                onAudioDurable: { removeBoth() }
            )
        }
        // The recovered entries must be durable before this launch task
        // reports done (tests and the artifact lifecycle rely on it).
        await archiver.drain()
    }

    /// Orphaned .pcm files with no sidecar never gain one after the fact —
    /// sweep them by age like every other artifact.
    @MainActor
    static func sweepExpired(
        directory: URL = SimpleCaptureSpool.spoolDirectory,
        now: Date = Date(),
        lifetime: TimeInterval = MeetingRecoveryPolicy.artifactLifetime
    ) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for file in files {
            let modified = (try? file.resourceValues(
                forKeys: [.contentModificationDateKey]
            ))?.contentModificationDate
            if let modified, now.timeIntervalSince(modified) > lifetime {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}

private extension JSONEncoder {
    static var iso8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
#endif
