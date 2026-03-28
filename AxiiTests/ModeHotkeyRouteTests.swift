//
//  ModeHotkeyRouteTests.swift
//  AxiiTests
//
//  Regression tests for config-driven hotkey route selection.
//

import XCTest
@testable import Axii

final class ModeHotkeyRouteTests: XCTestCase {

    func testMeetingHandlerAlwaysSelectsMeetingRoute() {
        XCTAssertEqual(
            ModeHotkeyRoute.select(
                hasMeetingHandler: true,
                config: DefaultModes.dictation()
            ),
            .meeting
        )
    }

    func testDictationSelectsSingleShotRoute() {
        XCTAssertEqual(
            ModeHotkeyRoute.select(
                hasMeetingHandler: false,
                config: DefaultModes.dictation()
            ),
            .singleShot
        )
    }

    func testConversationSelectsMultiTurnRoute() {
        XCTAssertEqual(
            ModeHotkeyRoute.select(
                hasMeetingHandler: false,
                config: DefaultModes.conversation()
            ),
            .multiTurn
        )
    }

    func testSingleTurnLLMTransformSelectsSingleShotRoute() {
        let config = ModeConfig(
            id: UUID(),
            name: "Single Turn Transform",
            icon: "wand.and.stars",
            isBuiltIn: false,
            hotkey: nil,
            audioCapture: .simple(SimpleCaptureConfig()),
            transcription: .batch(BatchTranscriptionConfig()),
            processing: [.llmTransform(LLMTransformConfig(systemPrompt: "Rewrite", multiTurn: false))],
            outputs: [.display(DisplayConfig())],
            lifecycle: LifecycleConfig(panelPersistence: .autoDismiss(delay: 2.0)),
            panel: PanelConfig(layout: .standard)
        )

        XCTAssertEqual(
            ModeHotkeyRoute.select(
                hasMeetingHandler: false,
                config: config
            ),
            .singleShot
        )
    }
}
