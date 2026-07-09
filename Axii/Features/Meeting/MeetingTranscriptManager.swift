//
//  MeetingTranscriptManager.swift
//  Axii
//
//  Manages transcription, segments, auto-save, and crash recovery for meetings.
//

#if os(macOS)
import Foundation

/// Auto-save data structure for crash recovery.
/// sessionID is optional so files written by older builds still decode.
private struct AutoSaveData: Codable {
    let segments: [MeetingSegment]
    let duration: TimeInterval
    let startTime: Date
    let selectedAppName: String?
    var sessionID: UUID?
    var audioFiles: MeetingAudioFileReferences?
}

/// Manages meeting transcription with auto-save for reliability.
@MainActor
final class MeetingTranscriptManager {
    // MARK: - Configuration

    private static let autoSaveIntervalSeconds: TimeInterval = 60
    private static let targetSampleRate: Double = 16000

    // MARK: - Dependencies

    private let transcriptionService: any TranscriptionProviding

    // MARK: - State

    private(set) var segments: [MeetingSegment] = []
    /// Identifies this recording in the autosave file so that clearing
    /// recovery data for one session can never delete another session's.
    private(set) var sessionID = UUID()
    private var recordingStartTime: Date?
    private var autoSaveTimer: Timer?
    private var selectedAppName: String?

    // Speaker continuity tracking
    private var lastMicSegmentIndex: Int?
    private var lastSystemSegmentIndex: Int?

    // Serialization chain: ensures only one transcription runs at a time.
    // AsrManager (FluidAudio) is not reentrant - concurrent calls cause
    // use-after-free on TdtDecoderState.
    //
    // Keep this optional instead of eagerly creating a placeholder Task.
    // Lightweight helper instances are created during crash-recovery checks,
    // and they should not allocate/deallocate unused Task machinery.
    private var transcriptionChain: Task<Void, Never>?

    // MARK: - Callbacks

    var onSegmentsUpdated: (([MeetingSegment]) -> Void)?
    var audioFileReferenceProvider: (() -> MeetingAudioFileReferences?)?

    // MARK: - Auto-save Path

    /// The production autosave location. Injectable per instance so tests
    /// never read or write a real user's recovery file.
    static var defaultAutosaveFileURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let axiiDir = appSupport.appendingPathComponent("Axii")

        // Ensure directory exists
        try? FileManager.default.createDirectory(
            at: axiiDir,
            withIntermediateDirectories: true
        )

        return axiiDir.appendingPathComponent("meeting_autosave.json")
    }

    let autosaveFileURL: URL
    private var autoSavePath: URL { autosaveFileURL }

    // MARK: - Initialization

    init(
        transcriptionService: any TranscriptionProviding,
        autosaveFileURL: URL? = nil
    ) {
        self.transcriptionService = transcriptionService
        self.autosaveFileURL = autosaveFileURL ?? Self.defaultAutosaveFileURL
    }

    deinit {
        autoSaveTimer?.invalidate()
        transcriptionChain?.cancel()
    }

    // MARK: - Lifecycle

    /// Reset for a new meeting.
    func reset() {
        transcriptionChain?.cancel()
        transcriptionChain = nil
        segments = []
        sessionID = UUID()
        recordingStartTime = Date()
        selectedAppName = nil
        lastMicSegmentIndex = nil
        lastSystemSegmentIndex = nil
        onSegmentsUpdated?(segments)
    }

    /// Set the selected app name for auto-save context.
    func setSelectedApp(_ app: AudioApp?) {
        selectedAppName = app?.name
    }

    // MARK: - Auto-Save

    /// Start the auto-save timer.
    func startAutoSave() {
        recordingStartTime = Date()
        autoSaveTimer = Timer.scheduledTimer(
            withTimeInterval: Self.autoSaveIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.performAutoSave()
            }
        }
    }

    /// Stop the auto-save timer.
    func stopAutoSave() {
        autoSaveTimer?.invalidate()
        autoSaveTimer = nil
    }

    /// Write the current transcript to the recovery file immediately.
    /// Called at stop so recovery is not up to one autosave interval stale
    /// during the finalize/persist window.
    func flushAutoSave() {
        performAutoSave()
    }

    /// Perform auto-save to disk.
    /// Written even with zero segments as long as audio references exist:
    /// with streaming transcription OFF a meeting produces no live segments,
    /// and without this file the spooled audio is unreachable after a crash
    /// (the expiry sweep would silently delete a complete recording).
    private func performAutoSave() {
        let audioFiles = audioFileReferenceProvider?()
        guard !segments.isEmpty || audioFiles != nil else { return }

        let duration = Date().timeIntervalSince(recordingStartTime ?? Date())
        let data = AutoSaveData(
            segments: segments,
            duration: duration,
            startTime: recordingStartTime ?? Date(),
            selectedAppName: selectedAppName,
            sessionID: sessionID,
            audioFiles: audioFiles
        )

        do {
            let jsonData = try JSONEncoder().encode(data)
            try jsonData.write(to: autoSavePath, options: .atomic)
            print("MeetingTranscriptManager: Auto-saved \(segments.count) segments")
        } catch {
            print("MeetingTranscriptManager: Auto-save failed: \(error)")
        }
    }

    /// Check for a recoverable crashed session.
    ///
    /// Reading does NOT delete the file: recovery data survives until the
    /// recovered meeting is persisted, superseded by a new recording's
    /// autosave, or expires. Deleting on read would make recovery a
    /// single-shot that a second crash erases.
    ///
    /// Scope: recovery covers streamed transcript segments only. With
    /// streaming transcription disabled nothing is autosaved, and temp
    /// audio in the system temp directory is not recovered.
    func checkForCrashRecovery() -> MeetingCrashRecovery? {
        guard FileManager.default.fileExists(atPath: autoSavePath.path) else {
            return nil
        }

        do {
            // Expiry is keyed to when the file was last WRITTEN, not when
            // the recording started: a 3-hour meeting autosaved seconds
            // before a crash is fresh, not expired.
            let attributes = try FileManager.default.attributesOfItem(
                atPath: autoSavePath.path
            )
            if let modified = attributes[.modificationDate] as? Date,
               Date().timeIntervalSince(modified) > 3600 {
                removeAutoSaveFile()
                return nil
            }

            let jsonData = try Data(contentsOf: autoSavePath)
            let data = try JSONDecoder().decode(AutoSaveData.self, from: jsonData)

            print("MeetingTranscriptManager: Found recovery data with \(data.segments.count) segments")
            return MeetingCrashRecovery(
                segments: data.segments,
                duration: data.duration,
                appName: data.selectedAppName,
                sessionID: data.sessionID,
                autosaveFileURL: autosaveFileURL,
                audioFiles: data.audioFiles
            )
        } catch {
            print("MeetingTranscriptManager: Failed to read recovery data: \(error)")
            removeAutoSaveFile()
            return nil
        }
    }

    /// Clear auto-save file (deliberate discard of the live session).
    /// Session-scoped: if this session never wrote the file, it may still
    /// hold a CRASHED session's recovery data — discarding a brand-new
    /// recording must not destroy that.
    func clearAutoSave() {
        Self.clearAutoSave(matching: sessionID, at: autoSavePath)
    }

    /// Unconditional removal — only for expired or unreadable files, which
    /// cannot be ownership-checked and are useless for recovery anyway.
    private func removeAutoSaveFile() {
        try? FileManager.default.removeItem(at: autoSavePath)
    }

    /// Clear the auto-save file only if it belongs to the given session.
    /// Used at the persistence commit point, which may run long after the
    /// capture ended — by then a newer recording may own the file.
    static func clearAutoSave(matching sessionID: UUID, at fileURL: URL) {
        guard let jsonData = try? Data(contentsOf: fileURL),
              let data = try? JSONDecoder().decode(AutoSaveData.self, from: jsonData)
        else { return }
        // Files from older builds have no sessionID; treat them as owned by
        // whoever is committing (there can only have been one writer).
        guard data.sessionID == nil || data.sessionID == sessionID else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Real-Time Transcription

    /// Queue a chunk for transcription. Returns the task handle for cancellation.
    /// Chunks are serialized to prevent concurrent AsrManager access.
    @discardableResult
    func transcribeChunk(_ chunk: TranscriptionChunk) -> Task<Void, Never> {
        let previous = transcriptionChain
        let task = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            await self.performTranscription(chunk)
        }
        transcriptionChain = task
        return task
    }

    private func performTranscription(_ chunk: TranscriptionChunk) async {
        let speakerId: String
        let isFromMicrophone: Bool

        switch chunk.source {
        case .microphone:
            speakerId = "You"
            isFromMicrophone = true
        case .systemAudio:
            speakerId = "Remote"
            isFromMicrophone = false
        }

        do {
            let text = try await transcriptionService.transcribe(
                samples: chunk.samples,
                sampleRate: Self.targetSampleRate
            )

            // Bail out if cancelled while awaiting transcription
            guard !Task.isCancelled else { return }

            let cleanedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedText.isEmpty else { return }

            let chunkDuration = Double(chunk.samples.count) / Self.targetSampleRate
            let startTime = chunk.timestamp.timeIntervalSince(recordingStartTime ?? Date())

            addSegment(
                text: cleanedText,
                speakerId: speakerId,
                isFromMicrophone: isFromMicrophone,
                startTime: max(0, startTime),
                endTime: startTime + chunkDuration
            )
        } catch {
            if !Task.isCancelled {
                print("MeetingTranscriptManager: Transcription error: \(error)")
            }
        }
    }

    private func addSegment(
        text: String,
        speakerId: String,
        isFromMicrophone: Bool,
        startTime: TimeInterval,
        endTime: TimeInterval
    ) {
        if isFromMicrophone {
            // Check if we should append to previous mic segment
            if let lastIndex = lastMicSegmentIndex,
               lastIndex < segments.count,
               segments[lastIndex].isFromMicrophone {
                let existing = segments[lastIndex]
                segments[lastIndex] = MeetingSegment(
                    id: existing.id,
                    text: existing.text + " " + text,
                    speakerId: speakerId,
                    isFromMicrophone: true,
                    startTime: existing.startTime,
                    endTime: endTime
                )
            } else {
                let segment = MeetingSegment(
                    text: text,
                    speakerId: speakerId,
                    isFromMicrophone: true,
                    startTime: startTime,
                    endTime: endTime
                )
                segments.append(segment)
                lastMicSegmentIndex = segments.count - 1
                lastSystemSegmentIndex = nil
            }
        } else {
            // Check if we should append to previous system segment
            if let lastIndex = lastSystemSegmentIndex,
               lastIndex < segments.count,
               !segments[lastIndex].isFromMicrophone {
                let existing = segments[lastIndex]
                segments[lastIndex] = MeetingSegment(
                    id: existing.id,
                    text: existing.text + " " + text,
                    speakerId: speakerId,
                    isFromMicrophone: false,
                    startTime: existing.startTime,
                    endTime: endTime
                )
            } else {
                let segment = MeetingSegment(
                    text: text,
                    speakerId: speakerId,
                    isFromMicrophone: false,
                    startTime: startTime,
                    endTime: endTime
                )
                segments.append(segment)
                lastSystemSegmentIndex = segments.count - 1
                lastMicSegmentIndex = nil
            }
        }

        onSegmentsUpdated?(segments)
    }

}
#endif
