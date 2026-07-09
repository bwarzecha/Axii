//
//  MeetingCaptureInterfaces.swift
//  Axii
//
//  Collaborator surfaces and boundary types for MeetingCaptureSession:
//  audio/transcript manager protocols and capture start/result values.
//

#if os(macOS)
import Foundation

@MainActor
protocol MeetingAudioManaging: AnyObject {
    var onAudioLevel: ((Float) -> Void)? { get set }
    var onTranscriptionChunk: ((TranscriptionChunk) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }

    func start(
        micSource: AudioSource.MicrophoneSource,
        appSelection: AppSelection
    ) async throws
    func stop() -> (
        micFile: URL?,
        micRate: Double,
        systemFile: URL?,
        systemRate: Double
    )
    func switchApp(
        to app: AudioApp?,
        micSource: AudioSource.MicrophoneSource
    ) async throws
    func readSamplesFromFile(_ url: URL?) -> [Float]
    func cleanupTempFiles()
}

extension MeetingAudioManager: MeetingAudioManaging {}

@MainActor
protocol MeetingTranscriptManaging: AnyObject {
    var onSegmentsUpdated: (([MeetingSegment]) -> Void)? { get set }

    func reset()
    func setSelectedApp(_ app: AudioApp?)
    func startAutoSave()
    func stopAutoSave()
    func clearAutoSave()
    func checkForCrashRecovery() -> (
        segments: [MeetingSegment],
        duration: TimeInterval
    )?
    @discardableResult
    func transcribeChunk(_ chunk: TranscriptionChunk) -> Task<Void, Never>
}

extension MeetingTranscriptManager: MeetingTranscriptManaging {}

struct MeetingCaptureStartConfiguration {
    let selectedApp: AudioApp?
    let selectedMicrophone: AudioDevice?
    let streamingEnabled: Bool
}

struct MeetingCapturedAudio {
    let micSamples: [Float]
    let micSampleRate: Double
    let systemSamples: [Float]
    let systemSampleRate: Double
    let duration: TimeInterval
    let appName: String?
}
#endif
