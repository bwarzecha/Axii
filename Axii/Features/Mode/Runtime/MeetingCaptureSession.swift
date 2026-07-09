//
//  MeetingCaptureSession.swift
//  Axii
//
//  Owns the active meeting capture session: audio manager, live transcript
//  manager, chunk tasks, autosave timer control, and capture cleanup.
//

#if os(macOS)
import Foundation

@MainActor
final class MeetingCaptureSession {
    typealias AudioManagerFactory = @MainActor () -> any MeetingAudioManaging
    typealias TranscriptManagerFactory = @MainActor () -> any MeetingTranscriptManaging

    private let audioManagerFactory: AudioManagerFactory
    private let transcriptManagerFactory: TranscriptManagerFactory

    private var audioManager: (any MeetingAudioManaging)?
    private var transcriptManager: (any MeetingTranscriptManaging)?
    private var durationTimer: Timer?
    private var chunkTranscriptionTasks: [Task<Void, Never>] = []
    private var currentDuration: TimeInterval = 0
    private var selectedApp: AudioApp?
    private var selectedMicrophone: AudioDevice?

    var onAudioLevel: ((Float) -> Void)?
    var onSegmentsUpdated: (([MeetingSegment]) -> Void)?
    var onError: ((String) -> Void)?
    var onDurationUpdated: ((TimeInterval) -> Void)?

    var isRecording: Bool {
        audioManager != nil
    }

    init(
        transcriptionService: any TranscriptionProviding,
        audioManagerFactory: @escaping AudioManagerFactory = {
            MeetingAudioManager()
        },
        transcriptManagerFactory: TranscriptManagerFactory? = nil
    ) {
        self.audioManagerFactory = audioManagerFactory
        self.transcriptManagerFactory = transcriptManagerFactory ?? {
            MeetingTranscriptManager(transcriptionService: transcriptionService)
        }
    }

    deinit {
        durationTimer?.invalidate()
        for task in chunkTranscriptionTasks {
            task.cancel()
        }
    }

    func start(configuration: MeetingCaptureStartConfiguration) async throws {
        if audioManager != nil || transcriptManager != nil {
            cancel()
        }
        resetTransientState()

        selectedApp = configuration.selectedApp
        selectedMicrophone = configuration.selectedMicrophone

        let audio = audioManagerFactory()
        let transcript = transcriptManagerFactory()
        audioManager = audio
        transcriptManager = transcript

        audio.onAudioLevel = { [weak self] level in
            self?.onAudioLevel?(level)
        }

        audio.onTranscriptionChunk = nil
        if configuration.streamingEnabled {
            audio.onTranscriptionChunk = { [weak self] chunk in
                guard let self, let transcript = self.transcriptManager else {
                    return
                }
                let task = transcript.transcribeChunk(chunk)
                self.chunkTranscriptionTasks.append(task)
                if self.chunkTranscriptionTasks.count > 20 {
                    self.chunkTranscriptionTasks.removeAll {
                        $0.isCancelled
                    }
                }
            }
        }

        audio.onError = { [weak self] message in
            self?.onError?(message)
        }

        transcript.onSegmentsUpdated = { [weak self] segments in
            self?.onSegmentsUpdated?(segments)
        }
        transcript.setSelectedApp(configuration.selectedApp)
        transcript.reset()

        do {
            try await audio.start(
                micSource: resolveMicSource(),
                appSelection: resolveAppSelection()
            )
        } catch {
            clearCallbacks(audio: audio, transcript: transcript)
            audio.cleanupTempFiles()
            audioManager = nil
            transcriptManager = nil
            throw error
        }

        transcript.startAutoSave()
        startDurationTimer()
    }

    func stop(saveToHistory: Bool) async -> MeetingCapturedAudio? {
        stopDurationTimer()
        transcriptManager?.stopAutoSave()

        let pendingTasks = chunkTranscriptionTasks
        for task in pendingTasks {
            task.cancel()
        }
        chunkTranscriptionTasks = []

        guard let audio = audioManager else {
            clearCallbacks(audio: nil, transcript: transcriptManager)
            transcriptManager = nil
            return nil
        }

        let stoppedAudio = audio.stop()
        let duration = currentDuration

        guard saveToHistory else {
            clearCallbacks(audio: audio, transcript: transcriptManager)
            audio.cleanupTempFiles()
            audioManager = nil
            transcriptManager = nil
            return nil
        }

        for task in pendingTasks {
            await task.value
        }

        let captured = MeetingCapturedAudio(
            micSamples: audio.readSamplesFromFile(stoppedAudio.micFile),
            micSampleRate: stoppedAudio.micRate,
            systemSamples: audio.readSamplesFromFile(stoppedAudio.systemFile),
            systemSampleRate: stoppedAudio.systemRate,
            duration: duration,
            appName: selectedApp?.name
        )

        transcriptManager?.clearAutoSave()
        clearCallbacks(audio: audio, transcript: transcriptManager)
        audio.cleanupTempFiles()
        audioManager = nil
        transcriptManager = nil

        return captured
    }

    func cancel() {
        stopDurationTimer()
        transcriptManager?.stopAutoSave()

        for task in chunkTranscriptionTasks {
            task.cancel()
        }
        chunkTranscriptionTasks = []

        _ = audioManager?.stop()
        clearCallbacks(audio: audioManager, transcript: transcriptManager)
        audioManager?.cleanupTempFiles()
        audioManager = nil
        transcriptManager = nil
    }

    func selectApp(_ app: AudioApp?) {
        selectedApp = app
        transcriptManager?.setSelectedApp(app)

        guard let audioManager else { return }
        let micSource = resolveMicSource()
        Task {
            try? await audioManager.switchApp(
                to: app,
                micSource: micSource
            )
        }
    }

    func switchMicrophone(
        to device: AudioDevice?,
        selectedApp: AudioApp?,
        micSource: AudioSource.MicrophoneSource? = nil
    ) async {
        selectedMicrophone = device
        self.selectedApp = selectedApp

        guard let audioManager else { return }
        try? await audioManager.switchApp(
            to: selectedApp,
            micSource: micSource ?? resolveMicSource()
        )
    }

    func checkCrashRecovery() -> (
        segments: [MeetingSegment],
        duration: TimeInterval
    )? {
        let transcript = transcriptManagerFactory()
        guard let recovery = transcript.checkForCrashRecovery() else {
            return nil
        }
        transcript.clearAutoSave()
        return recovery
    }

    private func resetTransientState() {
        stopDurationTimer()
        for task in chunkTranscriptionTasks {
            task.cancel()
        }
        chunkTranscriptionTasks = []
        currentDuration = 0
    }

    private func startDurationTimer() {
        let startTime = Date()
        durationTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentDuration = Date().timeIntervalSince(startTime)
                self.onDurationUpdated?(self.currentDuration)
            }
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }

    private func clearCallbacks(
        audio: (any MeetingAudioManaging)?,
        transcript: (any MeetingTranscriptManaging)?
    ) {
        audio?.onAudioLevel = nil
        audio?.onTranscriptionChunk = nil
        audio?.onError = nil
        transcript?.onSegmentsUpdated = nil
    }

    private func resolveMicSource() -> AudioSource.MicrophoneSource {
        if let selectedMicrophone {
            return .specific(selectedMicrophone)
        }
        return .systemDefault
    }

    private func resolveAppSelection() -> AppSelection {
        if let selectedApp {
            return .only([selectedApp])
        }
        return .all
    }
}
#endif
