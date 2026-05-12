//
//  MeetingTranscriptManager.swift
//  Axii
//
//  Manages transcription, segments, auto-save, and crash recovery for meetings.
//

#if os(macOS)
import Foundation

/// Auto-save data structure for crash recovery.
private struct AutoSaveData: Codable {
    let segments: [MeetingSegment]
    let duration: TimeInterval
    let startTime: Date
    let selectedAppName: String?
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

    // MARK: - Auto-save Path

    private var autoSavePath: URL {
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

    // MARK: - Initialization

    init(transcriptionService: any TranscriptionProviding) {
        self.transcriptionService = transcriptionService
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

    /// Perform auto-save to disk.
    private func performAutoSave() {
        guard !segments.isEmpty else { return }

        let duration = Date().timeIntervalSince(recordingStartTime ?? Date())
        let data = AutoSaveData(
            segments: segments,
            duration: duration,
            startTime: recordingStartTime ?? Date(),
            selectedAppName: selectedAppName
        )

        do {
            let jsonData = try JSONEncoder().encode(data)
            try jsonData.write(to: autoSavePath, options: .atomic)
            print("MeetingTranscriptManager: Auto-saved \(segments.count) segments")
        } catch {
            print("MeetingTranscriptManager: Auto-save failed: \(error)")
        }
    }

    /// Check for and recover from a crashed session.
    func checkForCrashRecovery() -> (segments: [MeetingSegment], duration: TimeInterval)? {
        guard FileManager.default.fileExists(atPath: autoSavePath.path) else {
            return nil
        }

        do {
            let jsonData = try Data(contentsOf: autoSavePath)
            let data = try JSONDecoder().decode(AutoSaveData.self, from: jsonData)

            // Only recover if it's recent (within last hour)
            let age = Date().timeIntervalSince(data.startTime)
            if age > 3600 {
                clearAutoSave()
                return nil
            }

            print("MeetingTranscriptManager: Found recovery data with \(data.segments.count) segments")
            return (data.segments, data.duration)
        } catch {
            print("MeetingTranscriptManager: Failed to read recovery data: \(error)")
            clearAutoSave()
            return nil
        }
    }

    /// Clear auto-save file (call on successful meeting end).
    func clearAutoSave() {
        try? FileManager.default.removeItem(at: autoSavePath)
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
