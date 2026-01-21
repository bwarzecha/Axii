//
//  MeetingFeature.swift
//  Axii
//
//  Meeting transcription feature with You vs Remote speaker labels.
//  Uses combined audio capture (mic + system audio) for meeting transcription.
//

#if os(macOS)
import AppKit
import Accelerate
import FluidAudio
import HotKey
import SwiftUI

/// Meeting transcription feature with You vs Remote speaker labels.
@MainActor
final class MeetingFeature: Feature {
    let state = MeetingState()
    private var context: FeatureContext?
    private(set) var isActive = false

    // Services
    private let transcriptionService: TranscriptionService
    private let screenPermission: ScreenRecordingPermissionService
    private let micPermission: MicrophonePermissionService
    private let settings: SettingsService
    private let historyService: HistoryService

    // Audio session (created per recording)
    private var audioSession: AudioSession?
    private var chunkTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var durationTimer: Timer?

    // Small buffers for real-time UI transcription feedback
    private var micBuffer: [Float] = []
    private var systemBuffer: [Float] = []
    private var micChunkStartTime: Date?
    private var systemChunkStartTime: Date?
    private var sampleRate: Double = 48000
    private var recordingStartTime: Date?

    // Stream audio directly to temp files (memory efficient)
    private var micFileHandle: FileHandle?
    private var systemFileHandle: FileHandle?
    private var micFilePath: URL?
    private var systemFilePath: URL?
    private var micSampleCount: Int = 0
    private var systemSampleCount: Int = 0

    // Audio processing constants - 15s chunks for real-time UI feedback only
    private static let chunkSeconds: Float = 15.0
    private static let targetSampleRate: Float = 16000
    private var chunkSamples: Int { Int(Self.targetSampleRate * Self.chunkSeconds) }
    private let silenceAmplitudeThreshold: Float = 0.001

    // Speaker continuity tracking
    private var lastMicSegmentIndex: Int?
    private var lastSystemSegmentIndex: Int?

    // Track if we're showing final results
    private var showingFinalResults = false

    // Device selection
    private let deviceUIDKey = "meetingSelectedMicUID"
    private var selectedDeviceUID: String? {
        get { UserDefaults.standard.string(forKey: deviceUIDKey) }
        set { UserDefaults.standard.set(newValue, forKey: deviceUIDKey) }
    }

    private let deviceListMonitor = DeviceMonitor()

    init(
        transcriptionService: TranscriptionService,
        screenPermission: ScreenRecordingPermissionService,
        micPermission: MicrophonePermissionService,
        settings: SettingsService,
        historyService: HistoryService
    ) {
        self.transcriptionService = transcriptionService
        self.screenPermission = screenPermission
        self.micPermission = micPermission
        self.settings = settings
        self.historyService = historyService
    }

    // MARK: - Feature Protocol

    var panelContent: AnyView {
        AnyView(MeetingPanelView(
            state: state,
            onStop: { [weak self] in self?.handleHotkey() },
            onMicrophoneSwitch: { [weak self] device in
                self?.switchMicrophone(to: device)
            },
            onAppSelect: { [weak self] app in
                self?.selectApp(app)
            },
            onRefreshApps: { [weak self] in
                self?.refreshAppList()
            }
        ))
    }

    private var selectedMicrophone: AudioDevice? {
        guard let uid = selectedDeviceUID else { return nil }
        return state.availableMicrophones.first { $0.uid == uid }
    }

    func register(with context: FeatureContext) {
        self.context = context

        // Register hotkey: Control+Option+T
        context.hotkeyService.register(
            .meeting,
            key: .t,
            modifiers: [.control, .option]
        ) { [weak self] in
            self?.handleHotkey()
        }

        refreshDeviceList()
        refreshAppList()
        deviceListMonitor.onDeviceListChanged = { [weak self] in
            Task { @MainActor in
                self?.refreshDeviceList()
            }
        }
    }

    private func refreshDeviceList() {
        state.availableMicrophones = AudioSession.availableMicrophones()
        state.selectedMicrophone = selectedMicrophone
    }

    /// Refresh list of apps that can be captured
    func refreshAppList() {
        Task {
            let apps = await SystemAudioCapture.audioProducingApps()
            // Filter to common meeting apps and active audio apps
            let meetingBundleIDs = [
                "us.zoom.xos",           // Zoom
                "com.google.Chrome",      // Chrome (for Meet, etc.)
                "com.apple.Safari",       // Safari (for web meetings)
                "com.microsoft.teams",    // Teams
                "com.microsoft.teams2",   // Teams 2.0
                "com.cisco.webexmeetingsapp", // WebEx
                "com.apple.FaceTime",     // FaceTime
                "com.slack.Slack",        // Slack
                "com.discord.Discord",    // Discord
                "com.brave.Browser",      // Brave
                "org.mozilla.firefox",    // Firefox
                "com.apple.podcasts",     // Podcasts (for testing)
                "com.spotify.client",     // Spotify (for testing)
            ]

            // Prioritize known meeting apps but include all
            let sortedApps = apps.sorted { app1, app2 in
                let isMeeting1 = meetingBundleIDs.contains(app1.bundleIdentifier ?? "")
                let isMeeting2 = meetingBundleIDs.contains(app2.bundleIdentifier ?? "")
                if isMeeting1 && !isMeeting2 { return true }
                if !isMeeting1 && isMeeting2 { return false }
                return app1.name < app2.name
            }

            await MainActor.run {
                state.availableApps = sortedApps
            }
        }
    }

    /// Set the app to capture audio from
    func selectApp(_ app: AudioApp?) {
        state.selectedApp = app
    }

    func cancel() {
        stopRecording(saveToHistory: false)
        cleanupTempFiles()
        state.phase = .idle
        state.reset()
        isActive = false
    }

    func handleEscape() {
        if showingFinalResults {
            // Dismiss when viewing results - files already cleaned up
            state.phase = .idle
            state.reset()
            isActive = false
            showingFinalResults = false
            context?.onDeactivate?()
        } else {
            cancel()
            context?.onDeactivate?()
        }
    }

    // MARK: - Hotkey Handling

    private func handleHotkey() {
        switch state.phase {
        case .idle:
            // First press: show panel to configure
            showPanel()
        case .ready:
            // Second press: start recording
            startRecordingIfReady()
        case .permissionRequired:
            startRecordingIfReady()
        case .loadingModels:
            break
        case .recording:
            stopRecording(saveToHistory: true)
        case .processing:
            // Ignore hotkey during processing - let it finish
            break
        case .error:
            cancel()
            context?.onDeactivate?()
        }
    }

    private func showPanel() {
        state.phase = .ready
        isActive = true
        context?.onActivate?(self)
        // Refresh app list when panel opens
        refreshAppList()
    }

    /// Public method to start a meeting - can be called from UI
    func startMeeting() {
        startRecordingIfReady()
    }

    /// Public method to stop a meeting - can be called from UI
    func stopMeeting() {
        if state.isRecording {
            stopRecording(saveToHistory: true)
        }
    }

    // MARK: - Recording Flow

    private func startRecordingIfReady() {
        // Check microphone permission first
        if micPermission.state.isBlocked {
            state.phase = .error(message: "Microphone permission required")
            micPermission.openSystemSettings()
            isActive = true
            context?.onActivate?(self)
            return
        }

        // Check screen recording permission
        guard screenPermission.isGranted else {
            state.phase = .permissionRequired
            screenPermission.request()
            isActive = true
            context?.onActivate?(self)

            // Poll for permission grant
            pollForScreenPermission()
            return
        }

        state.phase = .loadingModels
        isActive = true
        context?.onActivate?(self)

        Task {
            do {
                try await prepareTranscription()
                await startRecording()
            } catch {
                state.phase = .error(message: "Failed to load models: \(error.localizedDescription)")
            }
        }
    }

    private func pollForScreenPermission() {
        // Check every second if permission was granted
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self = self else {
                    timer.invalidate()
                    return
                }

                // Stop polling if no longer waiting for permission
                guard case .permissionRequired = self.state.phase else {
                    timer.invalidate()
                    return
                }

                // Check if permission was granted
                if self.screenPermission.isGranted {
                    timer.invalidate()
                    // Refresh app list now that we have permission
                    self.refreshAppList()
                    self.startRecordingIfReady()
                }
            }
        }
    }

    private func prepareTranscription() async throws {
        let isReady = await transcriptionService.isReady
        if !isReady {
            try await transcriptionService.prepare()
        }
    }

    private func startRecording() async {
        state.reset()
        micBuffer = []
        systemBuffer = []
        micChunkStartTime = nil
        systemChunkStartTime = nil
        chunkCount = 0
        recordingStartTime = Date()
        showingFinalResults = false

        // Reset speaker continuity tracking
        lastMicSegmentIndex = nil
        lastSystemSegmentIndex = nil

        // Create temp files for streaming audio (memory efficient)
        setupTempAudioFiles()

        let session = AudioSession()
        audioSession = session

        // Start chunk iteration
        chunkTask = Task { [weak self] in
            for await chunk in session.chunks {
                self?.handleChunk(chunk)
            }
        }

        // Start event iteration
        eventTask = Task { [weak self] in
            for await event in session.events {
                self?.handleEvent(event)
            }
        }

        // Determine microphone source
        let micSource: AudioSource.MicrophoneSource
        if let device = selectedMicrophone {
            micSource = .specific(device)
        } else {
            micSource = .systemDefault
        }

        // Determine app selection
        let appSelection: AppSelection
        if let selectedApp = state.selectedApp {
            appSelection = .only([selectedApp])
        } else {
            // Default: capture all apps (user should select one to avoid warning)
            appSelection = .all
        }

        do {
            // Start combined capture (mic + selected app)
            try await session.start(config: SessionConfig(
                source: .combined(microphone: micSource, apps: appSelection),
                onDeviceDisconnect: .fallbackToDefault
            ))

            state.phase = .recording

            // Start duration timer
            durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    if let start = self?.recordingStartTime {
                        self?.state.duration = Date().timeIntervalSince(start)
                    }
                }
            }
        } catch let error as AudioSessionError {
            handleSessionError(error)
        } catch {
            state.phase = .error(message: "Failed to start recording")
        }
    }

    private var chunkCount = 0

    private func handleChunk(_ chunk: AudioSessionChunk) {
        sampleRate = chunk.sampleRate
        chunkCount += 1

        // Log periodically
        if chunkCount % 100 == 0 {
            print("MeetingFeature: Received \(chunkCount) chunks, micBuffer=\(micBuffer.count), systemBuffer=\(systemBuffer.count)")
        }

        // Calculate visualization (combined for UI)
        let rms = calculateRMS(chunk.samples)
        let normalized = min(sqrt(rms) * 3.0, 1.0)
        state.audioLevel = normalized
        state.spectrum = SpectrumAnalyzer.calculateSpectrum(chunk.samples)

        // Resample to 16kHz for transcription (SamScribe uses 16kHz)
        let resampled = resampleTo16kHz(chunk.samples, fromRate: sampleRate)

        // Route to appropriate buffer based on source
        switch chunk.source {
        case .microphone:
            // Initialize chunk start time on first sample
            if micChunkStartTime == nil {
                micChunkStartTime = Date()
            }
            micBuffer.append(contentsOf: resampled)
            processMicBuffer()

        case .systemAudio:
            if systemChunkStartTime == nil {
                systemChunkStartTime = Date()
            }
            systemBuffer.append(contentsOf: resampled)
            processSystemBuffer()
        }
    }

    /// Resample audio from source rate to 16kHz for transcription
    private func resampleTo16kHz(_ samples: [Float], fromRate: Double) -> [Float] {
        let targetRate = Double(Self.targetSampleRate)
        guard fromRate != targetRate else { return samples }

        let ratio = targetRate / fromRate
        let outputCount = Int(Double(samples.count) * ratio)
        guard outputCount > 0 else { return [] }

        var output = [Float](repeating: 0, count: outputCount)
        for i in 0..<outputCount {
            let srcIndex = Double(i) / ratio
            let srcIndexInt = Int(srcIndex)
            let frac = Float(srcIndex - Double(srcIndexInt))

            if srcIndexInt + 1 < samples.count {
                output[i] = samples[srcIndexInt] * (1 - frac) + samples[srcIndexInt + 1] * frac
            } else if srcIndexInt < samples.count {
                output[i] = samples[srcIndexInt]
            }
        }
        return output
    }

    /// Process mic buffer - stream to file for final transcription
    private func processMicBuffer() {
        guard micBuffer.count >= chunkSamples else { return }

        let chunkToProcess = Array(micBuffer.prefix(chunkSamples))
        let chunkTime = micChunkStartTime ?? Date()

        // Remove processed samples from buffer
        micBuffer = Array(micBuffer.dropFirst(chunkSamples))
        micChunkStartTime = micBuffer.isEmpty ? nil : Date()

        // Stream to file for high-quality final transcription (memory efficient)
        writeMicSamples(chunkToProcess)

        // Check if entire chunk is silent (skip to prevent hallucinations)
        let maxAmplitude = chunkToProcess.map { abs($0) }.max() ?? 0.0
        if maxAmplitude < silenceAmplitudeThreshold {
            return
        }

        // Real-time transcription for feedback
        Task {
            await transcribeMicChunk(chunkToProcess, startTime: chunkTime)
        }
    }

    /// Process system buffer - stream to file for final transcription
    private func processSystemBuffer() {
        guard systemBuffer.count >= chunkSamples else { return }

        let chunkToProcess = Array(systemBuffer.prefix(chunkSamples))
        let chunkTime = systemChunkStartTime ?? Date()

        systemBuffer = Array(systemBuffer.dropFirst(chunkSamples))
        systemChunkStartTime = systemBuffer.isEmpty ? nil : Date()

        // Stream to file for high-quality final transcription (memory efficient)
        writeSystemSamples(chunkToProcess)

        let maxAmplitude = chunkToProcess.map { abs($0) }.max() ?? 0.0
        if maxAmplitude < silenceAmplitudeThreshold {
            return
        }

        // Real-time transcription for feedback
        Task {
            await transcribeSystemChunk(chunkToProcess, startTime: chunkTime)
        }
    }

    /// Transcribe a mic audio chunk (already 16kHz)
    /// Appends to previous mic segment if continuing, otherwise creates new segment
    private func transcribeMicChunk(_ samples: [Float], startTime: Date) async {
        guard state.isRecording else { return }

        let chunkDuration = Double(samples.count) / Double(Self.targetSampleRate)
        let segmentStartTime = startTime.timeIntervalSince(recordingStartTime ?? Date())

        do {
            let text = try await transcriptionService.transcribe(
                samples: samples,
                sampleRate: Double(Self.targetSampleRate)
            )

            let cleanedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedText.isEmpty else {
                print("MeetingFeature: Mic transcription returned empty")
                return
            }

            print("MeetingFeature: Mic result: \(cleanedText)")

            await MainActor.run {
                // Check if we should append to previous mic segment
                if let lastIndex = lastMicSegmentIndex,
                   lastIndex < state.segments.count,
                   state.segments[lastIndex].isFromMicrophone {
                    // Append to existing segment
                    let existingSegment = state.segments[lastIndex]
                    let updatedSegment = MeetingSegment(
                        id: existingSegment.id,
                        text: existingSegment.text + " " + cleanedText,
                        speakerId: "You",
                        isFromMicrophone: true,
                        startTime: existingSegment.startTime,
                        endTime: segmentStartTime + chunkDuration
                    )
                    state.segments[lastIndex] = updatedSegment
                } else {
                    // Create new segment
                    let segment = MeetingSegment(
                        text: cleanedText,
                        speakerId: "You",
                        isFromMicrophone: true,
                        startTime: max(0, segmentStartTime),
                        endTime: segmentStartTime + chunkDuration
                    )
                    state.segments.append(segment)
                    lastMicSegmentIndex = state.segments.count - 1
                    // Reset system continuity since mic spoke
                    lastSystemSegmentIndex = nil
                }
            }
        } catch {
            print("MeetingFeature: Mic transcription error: \(error)")
        }
    }

    /// Transcribe a system audio chunk (already 16kHz)
    /// Labels as "Remote" for all remote participants
    private func transcribeSystemChunk(_ samples: [Float], startTime: Date) async {
        guard state.isRecording else { return }

        let chunkDuration = Double(samples.count) / Double(Self.targetSampleRate)
        let chunkStartTime = startTime.timeIntervalSince(recordingStartTime ?? Date())

        do {
            let text = try await transcriptionService.transcribe(
                samples: samples,
                sampleRate: Double(Self.targetSampleRate)
            )

            let cleanedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanedText.isEmpty else { return }

            await MainActor.run {
                // Check if we should append to previous system segment
                if let lastIndex = lastSystemSegmentIndex,
                   lastIndex < state.segments.count,
                   !state.segments[lastIndex].isFromMicrophone {
                    // Append to existing segment
                    let existingSegment = state.segments[lastIndex]
                    let updatedSegment = MeetingSegment(
                        id: existingSegment.id,
                        text: existingSegment.text + " " + cleanedText,
                        speakerId: "Remote",
                        isFromMicrophone: false,
                        startTime: existingSegment.startTime,
                        endTime: chunkStartTime + chunkDuration
                    )
                    state.segments[lastIndex] = updatedSegment
                } else {
                    // Create new segment
                    let segment = MeetingSegment(
                        text: cleanedText,
                        speakerId: "Remote",
                        isFromMicrophone: false,
                        startTime: max(0, chunkStartTime),
                        endTime: chunkStartTime + chunkDuration
                    )
                    state.segments.append(segment)
                    lastSystemSegmentIndex = state.segments.count - 1
                    // Reset mic continuity since remote spoke
                    lastMicSegmentIndex = nil
                }
            }
        } catch {
            print("MeetingFeature: System audio processing error: \(error)")
        }
    }

    private func handleEvent(_ event: AudioEvent) {
        switch event {
        case .signalState:
            break  // Not handling signal state for meetings

        case .deviceDisconnected(let device):
            print("MeetingFeature: Device disconnected: \(device.name)")

        case .deviceChanged(let newDevice):
            state.selectedMicrophone = newDevice

        case .interrupted:
            state.phase = .error(message: "Audio interrupted")

        case .error(let error):
            handleSessionError(error)
        }
    }

    private func handleSessionError(_ error: AudioSessionError) {
        switch error {
        case .permissionDenied:
            state.phase = .permissionRequired
        case .deviceUnavailable:
            state.phase = .error(message: "Microphone unavailable")
        case .configurationFailed(let reason):
            state.phase = .error(message: reason)
        case .captureFailure(let reason):
            state.phase = .error(message: reason)
        }
    }

    private func stopRecording(saveToHistory: Bool) {
        durationTimer?.invalidate()
        durationTimer = nil

        chunkTask?.cancel()
        eventTask?.cancel()
        chunkTask = nil
        eventTask = nil

        audioSession?.stop()
        audioSession = nil

        // Write any remaining buffer samples to files
        if !micBuffer.isEmpty {
            writeMicSamples(micBuffer)
        }
        if !systemBuffer.isEmpty {
            writeSystemSamples(systemBuffer)
        }

        micBuffer = []
        systemBuffer = []
        micChunkStartTime = nil
        systemChunkStartTime = nil

        // Close file handles before reading
        try? micFileHandle?.close()
        try? systemFileHandle?.close()
        micFileHandle = nil
        systemFileHandle = nil

        // Process final transcription
        if saveToHistory {
            state.phase = .processing

            // Capture file paths before async context
            let micPath = micFilePath
            let systemPath = systemFilePath
            let micCount = micSampleCount
            let systemCount = systemSampleCount

            Task { [weak self] in
                guard let self = self else { return }

                // Clear real-time segments and do final transcription
                await MainActor.run {
                    self.state.segments.removeAll()
                }

                // Read full audio from files (memory efficient - only loads when needed)
                let micDuration = Float(micCount) / Self.targetSampleRate
                let systemDuration = Float(systemCount) / Self.targetSampleRate
                print("MeetingFeature: Reading audio files - mic: \(String(format: "%.1f", micDuration))s, system: \(String(format: "%.1f", systemDuration))s")

                let fullMicAudio = self.readSamplesFromFile(micPath)
                let fullSystemAudio = self.readSamplesFromFile(systemPath)

                // Transcribe full mic audio for best quality
                await self.transcribeFullAudio(
                    samples: fullMicAudio,
                    speakerId: "You",
                    isFromMicrophone: true
                )

                // Transcribe full system audio for best quality
                await self.transcribeFullAudio(
                    samples: fullSystemAudio,
                    speakerId: "Remote",
                    isFromMicrophone: false
                )

                // Merge consecutive segments from same speaker
                await MainActor.run {
                    self.mergeConsecutiveSpeakerSegments()
                }

                // Save to history
                if !self.state.segments.isEmpty {
                    await self.saveMeetingToHistory()
                }

                // Clean up temp files
                self.cleanupTempFiles()

                // Keep showing results - user presses ESC to dismiss
                await MainActor.run {
                    self.state.phase = .ready
                    self.state.audioLevel = 0
                    self.showingFinalResults = true
                    print("MeetingFeature: Showing final results. Press ESC to dismiss.")
                }
            }
        } else {
            cleanupTempFiles()
            state.phase = .idle
            state.audioLevel = 0
            isActive = false
            context?.onDeactivate?()
        }
    }

    /// Transcribe full accumulated audio in chunks for best quality
    private func transcribeFullAudio(samples: [Float], speakerId: String, isFromMicrophone: Bool) async {
        guard !samples.isEmpty else { return }

        // Use 30-second chunks for final transcription (better context = better quality)
        let chunkSize = Int(Self.targetSampleRate * 30.0)
        let totalDuration = Double(samples.count) / Double(Self.targetSampleRate)

        print("MeetingFeature: Transcribing \(String(format: "%.1f", totalDuration))s of \(speakerId) audio...")

        var currentOffset = 0
        var chunkIndex = 0

        while currentOffset < samples.count {
            let endOffset = min(currentOffset + chunkSize, samples.count)
            let chunk = Array(samples[currentOffset..<endOffset])

            // Skip silent chunks
            let maxAmp = chunk.map { abs($0) }.max() ?? 0.0
            if maxAmp < silenceAmplitudeThreshold {
                currentOffset = endOffset
                continue
            }

            let chunkStartTime = Double(currentOffset) / Double(Self.targetSampleRate)
            let chunkEndTime = Double(endOffset) / Double(Self.targetSampleRate)

            do {
                let text = try await transcriptionService.transcribe(
                    samples: chunk,
                    sampleRate: Double(Self.targetSampleRate)
                )

                let cleanedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleanedText.isEmpty {
                    await MainActor.run {
                        let segment = MeetingSegment(
                            text: cleanedText,
                            speakerId: speakerId,
                            isFromMicrophone: isFromMicrophone,
                            startTime: chunkStartTime,
                            endTime: chunkEndTime
                        )
                        state.segments.append(segment)
                    }
                    chunkIndex += 1
                }
            } catch {
                print("MeetingFeature: Transcription error for \(speakerId) chunk: \(error)")
            }

            currentOffset = endOffset
        }

        print("MeetingFeature: Completed \(chunkIndex) segments for \(speakerId)")
    }

    /// Merge consecutive segments from the same speaker and sort by time
    private func mergeConsecutiveSpeakerSegments() {
        guard state.segments.count > 1 else { return }

        // Sort by start time first
        state.segments.sort { $0.startTime < $1.startTime }

        var merged: [MeetingSegment] = []
        var current = state.segments[0]

        for i in 1..<state.segments.count {
            let next = state.segments[i]

            // Merge if same speaker
            if current.speakerId == next.speakerId {
                // Merge: combine text, extend time
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

        let beforeCount = state.segments.count
        state.segments = merged
        print("MeetingFeature: Merged segments: \(beforeCount) -> \(merged.count)")
    }

    private func saveMeetingToHistory() async {
        // TODO: Implement when Meeting history model is added
        print("MeetingFeature: Would save \(state.segments.count) segments to history")
    }

    // MARK: - Microphone Switching

    private func switchMicrophone(to device: AudioDevice?) {
        let wasRecording = state.isRecording

        if wasRecording {
            // Stop current session
            chunkTask?.cancel()
            eventTask?.cancel()
            audioSession?.stop()
            audioSession = nil
        }

        selectedDeviceUID = device?.uid
        state.selectedMicrophone = device

        if wasRecording {
            // Restart with new device
            Task {
                await startRecording()
            }
        }
    }

    // MARK: - Helpers

    private func calculateRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        return rms
    }

    // MARK: - File Streaming

    /// Create temp files for streaming audio during recording
    private func setupTempAudioFiles() {
        let tempDir = FileManager.default.temporaryDirectory
        let timestamp = Int(Date().timeIntervalSince1970)

        micFilePath = tempDir.appendingPathComponent("meeting_mic_\(timestamp).raw")
        systemFilePath = tempDir.appendingPathComponent("meeting_system_\(timestamp).raw")
        micSampleCount = 0
        systemSampleCount = 0

        // Create empty files
        FileManager.default.createFile(atPath: micFilePath!.path, contents: nil)
        FileManager.default.createFile(atPath: systemFilePath!.path, contents: nil)

        do {
            micFileHandle = try FileHandle(forWritingTo: micFilePath!)
            systemFileHandle = try FileHandle(forWritingTo: systemFilePath!)
            print("MeetingFeature: Created temp audio files")
        } catch {
            print("MeetingFeature: Failed to create temp files: \(error)")
        }
    }

    /// Write samples to mic temp file
    private func writeMicSamples(_ samples: [Float]) {
        guard let handle = micFileHandle else { return }
        samples.withUnsafeBufferPointer { buffer in
            let data = Data(buffer: buffer)
            do {
                try handle.write(contentsOf: data)
                micSampleCount += samples.count
            } catch {
                print("MeetingFeature: Failed to write mic samples: \(error)")
            }
        }
    }

    /// Write samples to system temp file
    private func writeSystemSamples(_ samples: [Float]) {
        guard let handle = systemFileHandle else { return }
        samples.withUnsafeBufferPointer { buffer in
            let data = Data(buffer: buffer)
            do {
                try handle.write(contentsOf: data)
                systemSampleCount += samples.count
            } catch {
                print("MeetingFeature: Failed to write system samples: \(error)")
            }
        }
    }

    /// Read all samples from a temp file
    private func readSamplesFromFile(_ url: URL?) -> [Float] {
        guard let url = url else { return [] }

        do {
            let data = try Data(contentsOf: url)
            let count = data.count / MemoryLayout<Float>.size
            var samples = [Float](repeating: 0, count: count)
            _ = samples.withUnsafeMutableBufferPointer { buffer in
                data.copyBytes(to: buffer)
            }
            return samples
        } catch {
            print("MeetingFeature: Failed to read samples from \(url.lastPathComponent): \(error)")
            return []
        }
    }

    /// Clean up temp files
    private func cleanupTempFiles() {
        // Close file handles
        try? micFileHandle?.close()
        try? systemFileHandle?.close()
        micFileHandle = nil
        systemFileHandle = nil

        // Delete temp files
        if let path = micFilePath {
            try? FileManager.default.removeItem(at: path)
        }
        if let path = systemFilePath {
            try? FileManager.default.removeItem(at: path)
        }
        micFilePath = nil
        systemFilePath = nil
        micSampleCount = 0
        systemSampleCount = 0
    }
}
#endif
