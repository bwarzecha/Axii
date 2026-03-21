import XCTest
@testable import Axii

final class FixtureDecodeTests: XCTestCase {

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    // MARK: - Helper

    private func loadFixture(_ path: String) throws -> Data {
        // Fixtures are in the AxiiTests bundle
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: path, withExtension: "json") else {
            // Fall back to filesystem path relative to project root
            let projectRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent() // AxiiTests/
            let fileURL = projectRoot.appendingPathComponent("Fixtures").appendingPathComponent(path + ".json")
            return try Data(contentsOf: fileURL)
        }
        return try Data(contentsOf: url)
    }

    // MARK: - Mode Fixture Decode Tests

    func testDecodeDictationMode() throws {
        let data = try loadFixture("Modes/builtin-dictation-vcurrent")
        let config = try decoder.decode(ModeConfig.self, from: data)
        XCTAssertEqual(config.name, "Dictation")
        XCTAssertTrue(config.isBuiltIn)
        XCTAssertEqual(config.id, DefaultModes.dictationId)
        if case .simple(let capture) = config.audioCapture {
            XCTAssertEqual(capture.devicePreference, .lastUsed)
        } else {
            XCTFail("Expected simple audio capture")
        }
        if case .batch = config.transcription {} else {
            XCTFail("Expected batch transcription")
        }
        XCTAssertTrue(config.processing.isEmpty)
        XCTAssertEqual(config.outputs.count, 2)
    }

    func testDecodeConversationMode() throws {
        let data = try loadFixture("Modes/builtin-conversation-vcurrent")
        let config = try decoder.decode(ModeConfig.self, from: data)
        XCTAssertEqual(config.name, "Conversation")
        XCTAssertTrue(config.isBuiltIn)
        XCTAssertEqual(config.processing.count, 1)
        if case .llmTransform(let llmConfig) = config.processing.first {
            XCTAssertTrue(llmConfig.multiTurn)
        } else {
            XCTFail("Expected llmTransform processing step")
        }
    }

    func testDecodeMeetingMode() throws {
        let data = try loadFixture("Modes/builtin-meeting-vcurrent")
        let config = try decoder.decode(ModeConfig.self, from: data)
        XCTAssertEqual(config.name, "Meeting")
        XCTAssertTrue(config.isBuiltIn)
        if case .dual(let dualConfig) = config.audioCapture {
            XCTAssertEqual(dualConfig.appSelection, .userSelected)
        } else {
            XCTFail("Expected dual audio capture")
        }
        if case .streaming(let streamConfig) = config.transcription {
            XCTAssertEqual(streamConfig.chunkDurationSeconds, 15.0)
        } else {
            XCTFail("Expected streaming transcription")
        }
        XCTAssertEqual(config.lifecycle.startMode, .manual)
        XCTAssertTrue(config.lifecycle.enableCrashRecovery)
    }

    func testDecodeCustomMode() throws {
        let data = try loadFixture("Modes/custom-sample-vcurrent")
        let config = try decoder.decode(ModeConfig.self, from: data)
        XCTAssertEqual(config.name, "Custom Test Mode")
        XCTAssertFalse(config.isBuiltIn)
        XCTAssertEqual(config.processing.count, 2)
    }

    // MARK: - Mode Round-trip Tests

    func testRoundTripDictationMode() throws {
        let original = DefaultModes.dictation()
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(ModeConfig.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.isBuiltIn, original.isBuiltIn)
        XCTAssertEqual(decoded.outputs.count, original.outputs.count)
    }

    func testRoundTripConversationMode() throws {
        let original = DefaultModes.conversation()
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(ModeConfig.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.processing.count, original.processing.count)
    }

    func testRoundTripMeetingMode() throws {
        let original = DefaultModes.meeting()
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(ModeConfig.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.lifecycle.enableCrashRecovery, original.lifecycle.enableCrashRecovery)
    }

    // MARK: - History Metadata Decode Tests

    func testDecodeTranscriptionMetadata() throws {
        let data = try loadFixture("History/Transcription/transcription-metadata")
        let metadata = try decoder.decode(InteractionMetadata.self, from: data)
        XCTAssertEqual(metadata.type, .transcription)
        XCTAssertEqual(metadata.id, UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        if case .transcription(let details) = metadata.details {
            XCTAssertEqual(details.wordCount, 8)
            XCTAssertEqual(details.pastedTo, "com.apple.TextEdit")
            XCTAssertTrue(details.hasAudio)
            XCTAssertTrue(details.hasContext)
        } else {
            XCTFail("Expected transcription details")
        }
    }

    func testDecodeConversationMetadata() throws {
        let data = try loadFixture("History/Conversation/conversation-metadata")
        let metadata = try decoder.decode(InteractionMetadata.self, from: data)
        XCTAssertEqual(metadata.type, .conversation)
        if case .conversation(let details) = metadata.details {
            XCTAssertEqual(details.turnCount, 2)
            XCTAssertEqual(details.messageCount, 4)
        } else {
            XCTFail("Expected conversation details")
        }
    }

    func testDecodeMeetingMetadata() throws {
        let data = try loadFixture("History/Meeting/meeting-metadata")
        let metadata = try decoder.decode(InteractionMetadata.self, from: data)
        XCTAssertEqual(metadata.type, .meeting)
        if case .meeting(let details) = metadata.details {
            XCTAssertEqual(details.segmentCount, 4)
            XCTAssertEqual(details.duration, 300.0)
            XCTAssertTrue(details.hasMicAudio)
            XCTAssertTrue(details.hasSystemAudio)
        } else {
            XCTFail("Expected meeting details")
        }
    }

    // MARK: - History Interaction Decode Tests

    func testDecodeTranscriptionInteraction() throws {
        let data = try loadFixture("History/Transcription/transcription-interaction")
        let interaction = try decoder.decode(Interaction.self, from: data)
        XCTAssertEqual(interaction.type, .transcription)
        if case .transcription(let t) = interaction {
            XCTAssertEqual(t.text, "Hello world this is a test transcription")
            XCTAssertNotNil(t.audioRecording)
            XCTAssertEqual(t.pastedTo, "com.apple.TextEdit")
            XCTAssertNotNil(t.focusContext)
        } else {
            XCTFail("Expected transcription")
        }
    }

    func testDecodeConversationInteraction() throws {
        let data = try loadFixture("History/Conversation/conversation-interaction")
        let interaction = try decoder.decode(Interaction.self, from: data)
        XCTAssertEqual(interaction.type, .conversation)
        if case .conversation(let c) = interaction {
            XCTAssertEqual(c.messages.count, 4)
            XCTAssertEqual(c.turnCount, 2)
        } else {
            XCTFail("Expected conversation")
        }
    }

    func testDecodeMeetingInteraction() throws {
        let data = try loadFixture("History/Meeting/meeting-interaction")
        let interaction = try decoder.decode(Interaction.self, from: data)
        XCTAssertEqual(interaction.type, .meeting)
        if case .meeting(let m) = interaction {
            XCTAssertEqual(m.segments.count, 4)
            XCTAssertEqual(m.duration, 300.0)
            XCTAssertNotNil(m.micRecording)
            XCTAssertNotNil(m.systemRecording)
            XCTAssertEqual(m.appName, "Zoom")
        } else {
            XCTFail("Expected meeting")
        }
    }

    // MARK: - Interaction.toMetadata() Shape Tests

    func testTranscriptionToMetadataShape() throws {
        let transcription = Transcription(
            text: "Test transcription text for metadata",
            audioRecording: AudioRecording(filename: "audio/test.wav", duration: 1.5, sampleRate: 16000),
            pastedTo: "com.apple.TextEdit",
            focusContext: FocusContext(appBundleId: "com.apple.TextEdit", appName: "TextEdit", windowTitle: "Test")
        )
        let metadata = Interaction.transcription(transcription).toMetadata()
        XCTAssertEqual(metadata.id, transcription.id)
        XCTAssertEqual(metadata.type, .transcription)
        if case .transcription(let details) = metadata.details {
            XCTAssertEqual(details.wordCount, 5)
            XCTAssertEqual(details.pastedTo, "com.apple.TextEdit")
            XCTAssertTrue(details.hasAudio)
            XCTAssertTrue(details.hasContext)
            XCTAssertEqual(details.appName, "TextEdit")
        } else {
            XCTFail("Expected transcription details")
        }

        // Verify metadata round-trips through JSON
        let data = try encoder.encode(metadata)
        let decoded = try decoder.decode(InteractionMetadata.self, from: data)
        XCTAssertEqual(decoded.id, metadata.id)
        XCTAssertEqual(decoded.type, metadata.type)
    }

    func testConversationToMetadataShape() throws {
        var conversation = Conversation()
        conversation.addMessage(Message(role: .user, content: "Hello"))
        conversation.addMessage(Message(role: .assistant, content: "Hi there"))
        let metadata = Interaction.conversation(conversation).toMetadata()
        XCTAssertEqual(metadata.type, .conversation)
        if case .conversation(let details) = metadata.details {
            XCTAssertEqual(details.turnCount, 1)
            XCTAssertEqual(details.messageCount, 2)
        } else {
            XCTFail("Expected conversation details")
        }

        let data = try encoder.encode(metadata)
        let decoded = try decoder.decode(InteractionMetadata.self, from: data)
        XCTAssertEqual(decoded.id, metadata.id)
    }

    func testMeetingToMetadataShape() throws {
        let meeting = Meeting(
            segments: [
                MeetingSegment(text: "Hello world", speakerId: "You", isFromMicrophone: true, startTime: 0, endTime: 5),
                MeetingSegment(text: "Hi there friend", speakerId: "Remote", isFromMicrophone: false, startTime: 5, endTime: 10),
            ],
            duration: 10.0,
            micRecording: AudioRecording(filename: "audio/mic.m4a", duration: 10.0, sampleRate: 16000),
            appName: "Zoom"
        )
        let metadata = Interaction.meeting(meeting).toMetadata()
        XCTAssertEqual(metadata.type, .meeting)
        if case .meeting(let details) = metadata.details {
            XCTAssertEqual(details.segmentCount, 2)
            XCTAssertEqual(details.duration, 10.0)
            XCTAssertEqual(details.wordCount, 5) // "Hello world" = 2, "Hi there friend" = 3
            XCTAssertTrue(details.hasMicAudio)
            XCTAssertFalse(details.hasSystemAudio)
        } else {
            XCTFail("Expected meeting details")
        }

        let data = try encoder.encode(metadata)
        let decoded = try decoder.decode(InteractionMetadata.self, from: data)
        XCTAssertEqual(decoded.id, metadata.id)
    }
}
