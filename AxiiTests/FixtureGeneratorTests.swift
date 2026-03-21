import XCTest
@testable import Axii

/// Utility test that generates correct fixture JSON from current code.
/// Run these tests individually to regenerate fixtures if the models change.
final class FixtureGeneratorTests: XCTestCase {

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }

    func testGenerateModeFixtures() throws {
        let modes: [(String, ModeConfig)] = [
            ("builtin-dictation-vcurrent", DefaultModes.dictation()),
            ("builtin-conversation-vcurrent", DefaultModes.conversation()),
            ("builtin-meeting-vcurrent", DefaultModes.meeting()),
        ]

        for (name, mode) in modes {
            // Null out the hotkey for fixture portability
            var config = mode
            // ModeConfig.hotkey is var, so we can set it
            config.hotkey = nil

            let data = try encoder.encode(config)
            let url = fixturesDir
                .appendingPathComponent("Modes")
                .appendingPathComponent("\(name).json")
            try data.write(to: url)
            print("Wrote fixture: \(url.lastPathComponent) (\(data.count) bytes)")
        }
    }

    func testGenerateCustomModeFixture() throws {
        let config = ModeConfig(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            name: "Custom Test Mode",
            icon: "wand.and.stars",
            isBuiltIn: false,
            hotkey: nil,
            audioCapture: .simple(SimpleCaptureConfig(devicePreference: .systemDefault)),
            transcription: .batch(BatchTranscriptionConfig()),
            processing: [
                .segmentMerge(SegmentMergeConfig()),
                .llmTransform(LLMTransformConfig(
                    systemPrompt: "Summarize this",
                    label: "summary"
                )),
            ],
            outputs: [
                .display(DisplayConfig()),
                .clipboard(ClipboardConfig()),
                .history(HistoryConfig(saveAudio: false)),
            ],
            lifecycle: LifecycleConfig(
                startMode: .automatic,
                panelPersistence: .autoDismiss(delay: 3.0),
                escapeBehavior: .alwaysCancel
            ),
            panel: PanelConfig(
                layout: .standard,
                preferences: PanelPreferences()
            )
        )

        let data = try encoder.encode(config)
        let url = fixturesDir
            .appendingPathComponent("Modes")
            .appendingPathComponent("custom-sample-vcurrent.json")
        try data.write(to: url)
        print("Wrote fixture: \(url.lastPathComponent) (\(data.count) bytes)")
    }
}
