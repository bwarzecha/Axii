//
//  BuiltInModeHotkeyContractTests.swift
//  AxiiIntegrationTests
//
//  Product-level contract tests for the three built-in modes.
//  These drive the real registered hotkey callbacks and assert that
//  each built-in mode preserves its execution family.
//

import XCTest
import AppKit
import HotKey
@testable import Axii

@MainActor
private final class RecordingHotkeyRegistrar: HotkeyRegistering {
    private(set) var handlers: [HotkeyID: () -> Void] = [:]

    func register(
        _ id: HotkeyID,
        key: Key,
        modifiers: NSEvent.ModifierFlags,
        handler: @escaping () -> Void
    ) {
        handlers[id] = handler
    }

    func unregister(_ id: HotkeyID) {
        handlers[id] = nil
    }
}

@MainActor
private final class CountingPasteProvider: PasteProviding {
    var outcomeToReturn: PasteService.Outcome = .pasted
    private(set) var callCount = 0
    private(set) var lastPastedText: String?

    func paste(
        text: String,
        focusSnapshot: FocusSnapshot?,
        finishBehavior: FinishBehavior,
        failureBehavior: InsertionFailureBehavior
    ) async -> PasteService.Outcome {
        callCount += 1
        lastPastedText = text
        return outcomeToReturn
    }
}

actor CountingTranscriber: TranscriptionProviding {
    var isReady: Bool = true
    var textToReturn: String = "Hello"
    private(set) var callCount = 0

    func prepare() async throws {}

    func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
        callCount += 1
        return textToReturn
    }

    func setTextToReturn(_ text: String) {
        textToReturn = text
    }

    func getCallCount() -> Int {
        callCount
    }
}

@MainActor
private final class CountingConversationResponder: ConversationResponding {
    var responseToReturn: String = "Assistant reply"
    private(set) var sendMessageCallCount = 0
    private(set) var sendMessagesCallCount = 0

    func send(message: String) async throws -> String {
        sendMessageCallCount += 1
        return responseToReturn
    }

    func send(messages: [Message]) async throws -> String {
        sendMessagesCallCount += 1
        return responseToReturn
    }
}

@MainActor
private final class CountingSessionStore: ConversationSessionStoring {
    var turnResult = PreparedConversationTurn(sessionId: UUID(), persistedMessages: nil)
    private(set) var beginTurnCallCount = 0
    private(set) var appendAssistantReplyCallCount = 0

    func beginTurn(userText: String, currentSessionId: UUID?) async throws -> PreparedConversationTurn {
        beginTurnCallCount += 1
        return turnResult
    }

    func appendAssistantReply(sessionId: UUID, text: String) async {
        appendAssistantReplyCallCount += 1
    }
}

@MainActor
final class BuiltInModeHotkeyContractTests: XCTestCase {

    private var hotkeys: RecordingHotkeyRegistrar!
    private var fakePaste: CountingPasteProvider!
    private var fakeResponder: CountingConversationResponder!
    private var fakeStore: CountingSessionStore!
    private var fakeTranscriber: CountingTranscriber!
    private var historyService: HistoryService!
    private var settings: SettingsService!
    private var clipboardService: ClipboardService!
    private var micPermission: MicrophonePermissionService!
    private var mediaControlService: MediaControlService!
    private var tempDir: URL!

    override func setUp() async throws {
        hotkeys = RecordingHotkeyRegistrar()
        fakePaste = CountingPasteProvider()
        fakeResponder = CountingConversationResponder()
        fakeStore = CountingSessionStore()
        fakeTranscriber = CountingTranscriber()

        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AxiiBuiltInHotkeyContract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )

        historyService = HistoryService(historyDirectory: tempDir)
        settings = SettingsService(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
        clipboardService = ClipboardService()
        micPermission = MicrophonePermissionService()
        mediaControlService = MediaControlService()
    }

    override func tearDown() async throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        hotkeys = nil
        fakePaste = nil
        fakeResponder = nil
        fakeStore = nil
        fakeTranscriber = nil
        historyService = nil
        settings = nil
        clipboardService = nil
        micPermission = nil
        mediaControlService = nil
        tempDir = nil
    }

    private func waitUntil(
        timeout: TimeInterval = 2.0,
        interval: TimeInterval = 0.01,
        _ condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for condition after \(timeout)s")
                return
            }
            try await Task.sleep(for: .milliseconds(Int(interval * 1000)))
        }
    }

    private func makeContext() -> FeatureContext {
        FeatureContext(
            hotkeyService: hotkeys,
            settings: settings
        )
    }

    private func makeFeature(config: ModeConfig) -> ModeFeature {
        ModeFeature(
            config: config,
            transcriptionService: fakeTranscriber,
            micPermission: micPermission,
            screenPermission: config.audioCapture.isDual ? ScreenRecordingPermissionService() : nil,
            pasteService: fakePaste,
            clipboardService: clipboardService,
            settings: settings,
            historyService: historyService,
            mediaControlService: mediaControlService,
            conversationResponder: fakeResponder,
            conversationSessionStore: fakeStore
        )
    }

    private func prepareFeatureForStopPath(_ feature: ModeFeature) {
        feature.state.phase = .recording
        feature.recordingHelper = RecordingSessionHelper()
        feature.isActive = true
    }

    func testBuiltInDictation_HotkeyUsesSingleShotFamily() async throws {
        await fakeTranscriber.setTextToReturn("Dictation text")
        let feature = makeFeature(config: DefaultModes.dictation())
        feature.register(with: makeContext())
        prepareFeatureForStopPath(feature)

        guard let handler = hotkeys.handlers[.togglePanel] else {
            XCTFail("Expected dictation hotkey to be registered")
            return
        }

        handler()

        try await waitUntil { feature.state.phase == .done }

        let transcriberCallCount = await fakeTranscriber.getCallCount()
        XCTAssertEqual(transcriberCallCount, 1)
        XCTAssertEqual(fakePaste.callCount, 1, "Dictation must still paste on hotkey stop")
        XCTAssertEqual(fakePaste.lastPastedText, "Dictation text")
        XCTAssertEqual(fakeResponder.sendMessageCallCount, 0)
        XCTAssertEqual(fakeResponder.sendMessagesCallCount, 0)
        XCTAssertTrue(feature.state.messages.isEmpty, "Dictation must not project conversation messages")
        XCTAssertNil(feature.state.currentSessionId, "Dictation must not open a conversation session")
        XCTAssertEqual(feature.state.finalText, "Dictation text")
    }

    func testBuiltInConversation_HotkeyUsesMultiTurnFamily() async throws {
        await fakeTranscriber.setTextToReturn("User request")
        fakeResponder.responseToReturn = "Assistant reply"

        let feature = makeFeature(config: DefaultModes.conversation())
        feature.register(with: makeContext())
        prepareFeatureForStopPath(feature)

        guard let handler = hotkeys.handlers[.conversation] else {
            XCTFail("Expected conversation hotkey to be registered")
            return
        }

        handler()

        try await waitUntil { feature.state.phase == .done }

        let transcriberCallCount = await fakeTranscriber.getCallCount()
        XCTAssertEqual(transcriberCallCount, 1)
        XCTAssertEqual(fakePaste.callCount, 0, "Conversation must not paste on hotkey stop")
        XCTAssertEqual(fakeResponder.sendMessageCallCount, 1)
        XCTAssertEqual(fakeResponder.sendMessagesCallCount, 0)
        XCTAssertEqual(fakeStore.beginTurnCallCount, 1)
        XCTAssertEqual(fakeStore.appendAssistantReplyCallCount, 1)
        XCTAssertEqual(feature.state.messages.count, 2, "Conversation must project user + assistant messages")
        XCTAssertNotNil(feature.state.currentSessionId, "Conversation must preserve a session ID")
        XCTAssertEqual(feature.state.finalText, "Assistant reply")
    }

    func testBuiltInMeeting_HotkeyUsesMeetingFamilyWhileRecording() async throws {
        var config = DefaultModes.meeting()
        // Crash recovery is a separate contract. Disable it here so this test
        // stays focused on hotkey routing and recording-state behavior.
        config.lifecycle.enableCrashRecovery = false

        let feature = makeFeature(config: config)
        feature.register(with: makeContext())
        feature.state.phase = .recording
        feature.state.panelMode = .default
        feature.isActive = true

        guard let handler = hotkeys.handlers[.meeting] else {
            XCTFail("Expected meeting hotkey to be registered")
            return
        }

        handler()

        XCTAssertEqual(feature.state.phase, .recording, "Meeting hotkey during recording must not enter single-shot processing")
        XCTAssertNotEqual(feature.state.panelMode, .default, "Meeting hotkey during recording should be handled by the meeting path and toggle panel mode")
        XCTAssertEqual(fakePaste.callCount, 0)
        XCTAssertEqual(fakeResponder.sendMessageCallCount, 0)
        XCTAssertEqual(fakeResponder.sendMessagesCallCount, 0)
        XCTAssertEqual(feature.state.finalText, "")
        XCTAssertTrue(feature.state.messages.isEmpty)

        // Let the main actor drain any follow-up work before teardown.
        await Task.yield()
    }
}
