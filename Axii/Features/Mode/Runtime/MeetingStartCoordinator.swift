//
//  MeetingStartCoordinator.swift
//  Axii
//
//  Owns meeting start gates: microphone permission, screen recording
//  permission, and transcription model readiness.
//

#if os(macOS)
import Foundation

@MainActor
protocol MeetingMicrophonePermissionChecking: AnyObject {
    var state: MicrophonePermissionService.State { get }
    func openSystemSettings()
}

extension MicrophonePermissionService: MeetingMicrophonePermissionChecking {}

@MainActor
protocol MeetingScreenRecordingPermissionChecking: AnyObject {
    var isGranted: Bool { get }
    func request()
}

extension ScreenRecordingPermissionService: MeetingScreenRecordingPermissionChecking {}

enum MeetingStartOutcome: Equatable {
    case readyToRecord
    case waitingForScreenRecording
    case blocked(String)
}

@MainActor
final class MeetingStartCoordinator {
    private let transcriptionService: any TranscriptionProviding
    private let screenPermission: any MeetingScreenRecordingPermissionChecking
    private let micPermission: any MeetingMicrophonePermissionChecking
    private var permissionPollTimer: Timer?

    init(
        transcriptionService: any TranscriptionProviding,
        screenPermission: any MeetingScreenRecordingPermissionChecking,
        micPermission: any MeetingMicrophonePermissionChecking
    ) {
        self.transcriptionService = transcriptionService
        self.screenPermission = screenPermission
        self.micPermission = micPermission
    }

    deinit {
        permissionPollTimer?.invalidate()
    }

    func requestStart() async throws -> MeetingStartOutcome {
        if micPermission.state.isBlocked {
            micPermission.openSystemSettings()
            return .blocked("Microphone permission required")
        }

        guard screenPermission.isGranted else {
            screenPermission.request()
            return .waitingForScreenRecording
        }

        try await prepareTranscriptionIfNeeded()
        return .readyToRecord
    }

    func startScreenPermissionPolling(
        while shouldContinue: @escaping @MainActor () -> Bool,
        onGranted: @escaping @MainActor () async -> Void
    ) {
        permissionPollTimer?.invalidate()
        permissionPollTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0,
            repeats: true
        ) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self else {
                    timer.invalidate()
                    return
                }

                guard shouldContinue() else {
                    timer.invalidate()
                    self.permissionPollTimer = nil
                    return
                }

                if self.screenPermission.isGranted {
                    timer.invalidate()
                    self.permissionPollTimer = nil
                    await onGranted()
                }
            }
        }
    }

    func cancelPermissionPolling() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
    }

    private func prepareTranscriptionIfNeeded() async throws {
        let isReady = await transcriptionService.isReady
        if !isReady {
            try await transcriptionService.prepare()
        }
    }
}
#endif
