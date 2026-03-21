import XCTest
@testable import Axii

/// Tests that decode real historical persisted data from January 2026.
/// These fixtures were captured from a live Axii installation and anonymized.
/// They protect backward compatibility with the on-disk format that real users have.
final class LegacyFixtureDecodeTests: XCTestCase {

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Helper

    private func loadFixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            throw FixtureError.notFound(name)
        }
        return try Data(contentsOf: url)
    }

    private enum FixtureError: LocalizedError {
        case notFound(String)
        var errorDescription: String? {
            switch self {
            case .notFound(let name):
                return "Legacy fixture '\(name).json' not found in test bundle."
            }
        }
    }

    // MARK: - Legacy Mode Fixtures

    func testDecodeLegacyDictationMode() throws {
        let data = try loadFixture("legacy-mode-dictation-2026-01")
        let config = try decoder.decode(ModeConfig.self, from: data)

        XCTAssertEqual(config.id, DefaultModes.dictationId)
        XCTAssertEqual(config.name, "Dictation")
        XCTAssertTrue(config.isBuiltIn)

        // Hotkey is present in real persisted file (not null like synthetic fixtures)
        XCTAssertNotNil(config.hotkey, "Live mode file should have hotkey")
        XCTAssertEqual(config.hotkey?.keyCode, 49)

        // _0 wrapper for enum associated values decodes correctly
        if case .simple(let capture) = config.audioCapture {
            XCTAssertEqual(capture.devicePreference, .lastUsed)
        } else {
            XCTFail("Expected simple audio capture")
        }

        if case .batch(let batch) = config.transcription {
            XCTAssertEqual(batch.minimumDuration, 0.5)
        } else {
            XCTFail("Expected batch transcription")
        }

        XCTAssertTrue(config.processing.isEmpty)
        XCTAssertEqual(config.outputs.count, 2)
    }

    func testDecodeLegacyConversationMode() throws {
        let data = try loadFixture("legacy-mode-conversation-2026-01")
        let config = try decoder.decode(ModeConfig.self, from: data)

        XCTAssertEqual(config.id, DefaultModes.conversationId)
        XCTAssertEqual(config.name, "Conversation")
        XCTAssertTrue(config.isBuiltIn)

        // Hotkey present with different modifiers than dictation
        XCTAssertNotNil(config.hotkey)
        XCTAssertEqual(config.hotkey?.keyCode, 49)
        XCTAssertEqual(config.hotkey?.modifiers, 6144)

        // llmTransform processing step with _0 wrapper
        XCTAssertEqual(config.processing.count, 1)
        if case .llmTransform(let llmConfig) = config.processing.first {
            XCTAssertTrue(llmConfig.multiTurn)
            XCTAssertEqual(llmConfig.systemPrompt, "")
        } else {
            XCTFail("Expected llmTransform processing step")
        }

        // stayOpen persistence
        if case .stayOpen = config.lifecycle.panelPersistence {} else {
            XCTFail("Expected stayOpen panel persistence")
        }
    }

    func testDecodeLegacyMeetingMode() throws {
        // This fixture uses compact JSON encoding (not pretty-printed),
        // exactly as it was persisted on disk.
        let data = try loadFixture("legacy-mode-meeting-2026-01")
        let config = try decoder.decode(ModeConfig.self, from: data)

        XCTAssertEqual(config.id, DefaultModes.meetingId)
        XCTAssertEqual(config.name, "Meeting")
        XCTAssertTrue(config.isBuiltIn)

        // Hotkey present
        XCTAssertNotNil(config.hotkey)
        XCTAssertEqual(config.hotkey?.keyCode, 46)

        // Dual capture with _0 wrapper
        if case .dual(let dualConfig) = config.audioCapture {
            XCTAssertEqual(dualConfig.appSelection, .userSelected)
            XCTAssertEqual(dualConfig.chunkDuration, 15)
            XCTAssertEqual(dualConfig.devicePreference, .lastUsed)
        } else {
            XCTFail("Expected dual audio capture")
        }

        // Streaming transcription with _0 wrapper
        if case .streaming(let streamConfig) = config.transcription {
            XCTAssertEqual(streamConfig.chunkDurationSeconds, 15)
            XCTAssertTrue(streamConfig.enableRealTimeDisplay)
            XCTAssertTrue(streamConfig.enableFinalTranscription)
        } else {
            XCTFail("Expected streaming transcription")
        }

        // Meeting-specific lifecycle
        XCTAssertEqual(config.lifecycle.startMode, .manual)
        XCTAssertTrue(config.lifecycle.enableCrashRecovery)
        XCTAssertEqual(config.lifecycle.escapeBehavior, .blockWhileRecording)
        XCTAssertEqual(config.lifecycle.permissions, [.microphone, .screenRecording])

        // Empty processing array
        XCTAssertTrue(config.processing.isEmpty)
    }

    // MARK: - Legacy Transcription Without FocusContext (Jan 21, 2026)

    func testDecodeLegacyTranscriptionWithoutFocusContext_Metadata() throws {
        let data = try loadFixture("legacy-transcription-2026-01-21-no-focuscontext-metadata")
        let metadata = try decoder.decode(InteractionMetadata.self, from: data)

        XCTAssertEqual(metadata.type, .transcription)
        XCTAssertEqual(metadata.id, UUID(uuidString: "A2856011-B5FD-4F70-8E38-16F52B24500B"))

        if case .transcription(let details) = metadata.details {
            XCTAssertTrue(details.hasAudio)
            XCTAssertEqual(details.wordCount, 7)
            XCTAssertNotNil(details.pastedTo, "pastedTo should be preserved")
            // hasContext and appName should be absent/default in this older format
            XCTAssertFalse(details.hasContext)
            XCTAssertNil(details.appName)
            XCTAssertNil(details.windowTitle)
        } else {
            XCTFail("Expected transcription details")
        }
    }

    func testDecodeLegacyTranscriptionWithoutFocusContext_Interaction() throws {
        let data = try loadFixture("legacy-transcription-2026-01-21-no-focuscontext-interaction")
        let interaction = try decoder.decode(Interaction.self, from: data)

        XCTAssertEqual(interaction.type, .transcription)
        guard case .transcription(let t) = interaction else {
            XCTFail("Expected transcription")
            return
        }

        // focusContext was not captured in this early version
        XCTAssertNil(t.focusContext, "Early transcription should have no focusContext")

        // Audio recording is present and uses .wav format
        XCTAssertNotNil(t.audioRecording)
        XCTAssertTrue(t.audioRecording!.filename.hasSuffix(".wav"), "Early recordings used WAV")
        XCTAssertEqual(t.audioRecording!.sampleRate, 48000)
        XCTAssertEqual(t.audioRecording!.duration, 2.3786666666666667, accuracy: 0.001)

        // pastedTo preserved
        XCTAssertNotNil(t.pastedTo)
    }

    // MARK: - Legacy Transcription With FocusContext (Jan 26, 2026)

    func testDecodeLegacyTranscriptionWithFocusContext_Metadata() throws {
        let data = try loadFixture("legacy-transcription-2026-01-26-with-focuscontext-metadata")
        let metadata = try decoder.decode(InteractionMetadata.self, from: data)

        XCTAssertEqual(metadata.type, .transcription)
        XCTAssertEqual(metadata.id, UUID(uuidString: "BF72A43A-D6A9-4A9D-AEC4-F32B8EA19D2A"))

        if case .transcription(let details) = metadata.details {
            XCTAssertTrue(details.hasAudio)
            XCTAssertTrue(details.hasContext, "This version has focusContext")
            XCTAssertNotNil(details.appName)
            XCTAssertNotNil(details.windowTitle)
            XCTAssertNotNil(details.pastedTo)
            XCTAssertEqual(details.wordCount, 1)
        } else {
            XCTFail("Expected transcription details")
        }
    }

    func testDecodeLegacyTranscriptionWithFocusContext_Interaction() throws {
        let data = try loadFixture("legacy-transcription-2026-01-26-with-focuscontext-interaction")
        let interaction = try decoder.decode(Interaction.self, from: data)

        guard case .transcription(let t) = interaction else {
            XCTFail("Expected transcription")
            return
        }

        // focusContext IS present
        XCTAssertNotNil(t.focusContext, "Later transcription should have focusContext")
        XCTAssertNotNil(t.focusContext?.appBundleId)
        XCTAssertNotNil(t.focusContext?.appName)
        XCTAssertNotNil(t.focusContext?.windowTitle)
        XCTAssertNotNil(t.focusContext?.surroundingText)
        XCTAssertNotNil(t.focusContext?.surroundingText?.selected)

        // Audio recording present, WAV format, different sample rate
        XCTAssertNotNil(t.audioRecording)
        XCTAssertTrue(t.audioRecording!.filename.hasSuffix(".wav"))
        XCTAssertEqual(t.audioRecording!.sampleRate, 24000)
        XCTAssertEqual(t.audioRecording!.duration, 4.02, accuracy: 0.001)
    }

    // MARK: - Legacy Conversation (Jan 23, 2026)

    func testDecodeLegacyConversation_Metadata() throws {
        let data = try loadFixture("legacy-conversation-2026-01-23-metadata")
        let metadata = try decoder.decode(InteractionMetadata.self, from: data)

        XCTAssertEqual(metadata.type, .conversation)
        XCTAssertEqual(metadata.id, UUID(uuidString: "A92E272A-0165-42D0-9780-EBC47058D6D1"))

        if case .conversation(let details) = metadata.details {
            XCTAssertEqual(details.messageCount, 2)
            XCTAssertEqual(details.turnCount, 1)
            XCTAssertFalse(details.hasAudio)
        } else {
            XCTFail("Expected conversation details")
        }
    }

    func testDecodeLegacyConversation_Interaction() throws {
        let data = try loadFixture("legacy-conversation-2026-01-23-interaction")
        let interaction = try decoder.decode(Interaction.self, from: data)

        guard case .conversation(let c) = interaction else {
            XCTFail("Expected conversation")
            return
        }

        XCTAssertEqual(c.messages.count, 2)
        XCTAssertTrue(c.audioRecordings.isEmpty, "Early conversations had empty audioRecordings")

        // Message roles preserved
        XCTAssertEqual(c.messages[0].role, .user)
        XCTAssertEqual(c.messages[1].role, .assistant)

        // updatedAt is different from createdAt (assistant reply came 1 second later)
        XCTAssertGreaterThan(c.updatedAt, c.createdAt)
    }

    // MARK: - Legacy Meeting (Jan 28, 2026)

    func testDecodeLegacyMeeting_Metadata() throws {
        let data = try loadFixture("legacy-meeting-2026-01-28-metadata")
        let metadata = try decoder.decode(InteractionMetadata.self, from: data)

        XCTAssertEqual(metadata.type, .meeting)
        XCTAssertEqual(metadata.id, UUID(uuidString: "1D6DBD5A-AADD-4CA0-A3F9-6003A1E8713B"))

        if case .meeting(let details) = metadata.details {
            XCTAssertEqual(details.segmentCount, 4)
            XCTAssertEqual(details.wordCount, 222)
            XCTAssertTrue(details.hasMicAudio)
            XCTAssertTrue(details.hasSystemAudio)
            // Fractional duration preserved exactly
            XCTAssertEqual(details.duration, 37.00040292739868, accuracy: 0.00001)
        } else {
            XCTFail("Expected meeting details")
        }
    }

    func testDecodeLegacyMeeting_Interaction() throws {
        let data = try loadFixture("legacy-meeting-2026-01-28-interaction")
        let interaction = try decoder.decode(Interaction.self, from: data)

        guard case .meeting(let m) = interaction else {
            XCTFail("Expected meeting")
            return
        }

        XCTAssertEqual(m.segments.count, 4)
        XCTAssertEqual(m.duration, 37.00040292739868, accuracy: 0.00001)

        // Both audio recordings present, both WAV format at 16kHz
        XCTAssertNotNil(m.micRecording)
        XCTAssertNotNil(m.systemRecording)
        XCTAssertTrue(m.micRecording!.filename.hasSuffix(".wav"), "Early meetings used WAV")
        XCTAssertTrue(m.systemRecording!.filename.hasSuffix(".wav"), "Early meetings used WAV")
        XCTAssertEqual(m.micRecording!.sampleRate, 16000)
        XCTAssertEqual(m.systemRecording!.sampleRate, 16000)

        // Segment structure: 2 mic (isFromMicrophone=true) + 2 system (false)
        let micSegments = m.segments.filter(\.isFromMicrophone)
        let systemSegments = m.segments.filter { !$0.isFromMicrophone }
        XCTAssertEqual(micSegments.count, 2)
        XCTAssertEqual(systemSegments.count, 2)

        // Speaker IDs: "You" for mic, "Remote" for system
        XCTAssertTrue(micSegments.allSatisfy { $0.speakerId == "You" })
        XCTAssertTrue(systemSegments.allSatisfy { $0.speakerId == "Remote" })

        // Time boundaries: first pair at 0-30, second pair at 30+
        XCTAssertEqual(m.segments[0].startTime, 0)
        XCTAssertEqual(m.segments[0].endTime, 30)
        XCTAssertEqual(m.segments[2].startTime, 30)

        // Fractional end times preserved
        XCTAssertEqual(m.micRecording!.duration, 37.601875, accuracy: 0.001)
        XCTAssertEqual(m.systemRecording!.duration, 37.82, accuracy: 0.001)
    }
}
