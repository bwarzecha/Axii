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

    private let transcriptionService: TranscriptionService

    // MARK: - State

    private(set) var segments: [MeetingSegment] = []
    private var recordingStartTime: Date?
    private var autoSaveTimer: Timer?
    private var selectedAppName: String?

    // Speaker continuity tracking
    private var lastMicSegmentIndex: Int?
    private var lastSystemSegmentIndex: Int?

    // MARK: - Callbacks

    var onSegmentsUpdated: (([MeetingSegment]) -> Void)?
    var onProgressUpdated: ((Double, String) -> Void)?

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

    init(transcriptionService: TranscriptionService) {
        self.transcriptionService = transcriptionService
    }

    // MARK: - Lifecycle

    /// Reset for a new meeting.
    func reset() {
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

    /// Transcribe a chunk and add to segments.
    func transcribeChunk(_ chunk: TranscriptionChunk) async {
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

            let cleanedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedText.isEmpty else { return }

            let chunkDuration = Double(chunk.samples.count) / Self.targetSampleRate
            let startTime = chunk.timestamp.timeIntervalSince(recordingStartTime ?? Date())

            await MainActor.run {
                addSegment(
                    text: cleanedText,
                    speakerId: speakerId,
                    isFromMicrophone: isFromMicrophone,
                    startTime: max(0, startTime),
                    endTime: startTime + chunkDuration
                )
            }
        } catch {
            print("MeetingTranscriptManager: Transcription error: \(error)")
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

    // MARK: - Final Transcription

    /// Transcribe full audio files for best quality (call after recording stops).
    func transcribeFullAudio(
        micSamples: [Float],
        systemSamples: [Float]
    ) async {
        // Clear real-time segments
        segments = []
        lastMicSegmentIndex = nil
        lastSystemSegmentIndex = nil

        // Calculate total chunks for progress
        let chunkSize = Int(Self.targetSampleRate * 30.0)
        let micChunks = micSamples.isEmpty ? 0 : (micSamples.count + chunkSize - 1) / chunkSize
        let systemChunks = systemSamples.isEmpty ? 0 : (systemSamples.count + chunkSize - 1) / chunkSize
        let totalChunks = micChunks + systemChunks
        var completedChunks = 0

        // Transcribe mic audio
        onProgressUpdated?(0, "Transcribing your audio...")
        await transcribeFullTrack(
            samples: micSamples,
            speakerId: "You",
            isFromMicrophone: true
        ) { [weak self] in
            completedChunks += 1
            let progress = totalChunks > 0 ? Double(completedChunks) / Double(totalChunks) : 0
            self?.onProgressUpdated?(progress, "Transcribing your audio...")
        }

        // Transcribe system audio
        onProgressUpdated?(Double(micChunks) / Double(max(totalChunks, 1)), "Transcribing remote audio...")
        await transcribeFullTrack(
            samples: systemSamples,
            speakerId: "Remote",
            isFromMicrophone: false
        ) { [weak self] in
            completedChunks += 1
            let progress = totalChunks > 0 ? Double(completedChunks) / Double(totalChunks) : 0
            self?.onProgressUpdated?(progress, "Transcribing remote audio...")
        }

        // Merge and sort by time
        onProgressUpdated?(0.95, "Merging transcript...")
        mergeConsecutiveSpeakerSegments()

        onProgressUpdated?(1.0, "Done")
        onSegmentsUpdated?(segments)
    }

    private func transcribeFullTrack(
        samples: [Float],
        speakerId: String,
        isFromMicrophone: Bool,
        onChunkComplete: @escaping () -> Void
    ) async {
        guard !samples.isEmpty else { return }

        // Use 30-second chunks for better quality
        let chunkSize = Int(Self.targetSampleRate * 30.0)
        var currentOffset = 0

        while currentOffset < samples.count {
            let endOffset = min(currentOffset + chunkSize, samples.count)
            let chunk = Array(samples[currentOffset..<endOffset])

            // Skip silent chunks
            let maxAmp = chunk.map { abs($0) }.max() ?? 0.0
            if maxAmp < 0.001 {
                currentOffset = endOffset
                onChunkComplete()
                continue
            }

            let chunkStartTime = Double(currentOffset) / Self.targetSampleRate
            let chunkEndTime = Double(endOffset) / Self.targetSampleRate

            do {
                let text = try await transcriptionService.transcribe(
                    samples: chunk,
                    sampleRate: Self.targetSampleRate
                )

                let cleanedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleanedText.isEmpty {
                    let segment = MeetingSegment(
                        text: cleanedText,
                        speakerId: speakerId,
                        isFromMicrophone: isFromMicrophone,
                        startTime: chunkStartTime,
                        endTime: chunkEndTime
                    )
                    segments.append(segment)
                }
            } catch {
                print("MeetingTranscriptManager: Final transcription error: \(error)")
            }

            currentOffset = endOffset
            onChunkComplete()
        }
    }

    private func mergeConsecutiveSpeakerSegments() {
        guard segments.count > 1 else { return }

        // Sort by start time
        segments.sort { $0.startTime < $1.startTime }

        var merged: [MeetingSegment] = []
        var current = segments[0]

        for i in 1..<segments.count {
            let next = segments[i]

            if current.speakerId == next.speakerId {
                // Merge same speaker
                current = MeetingSegment(
                    id: current.id,
                    text: current.text + " " + next.text,
                    speakerId: current.speakerId,
                    isFromMicrophone: current.isFromMicrophone,
                    startTime: current.startTime,
                    endTime: max(current.endTime, next.endTime)
                )
            } else {
                merged.append(current)
                current = next
            }
        }
        merged.append(current)

        segments = merged
    }
}
#endif
