//
//  ModeConfigExecutionTests.swift
//  AxiiTests
//
//  Contract tests for config-driven execution family selection.
//

import XCTest
@testable import Axii

final class ModeConfigExecutionTests: XCTestCase {

    func testDictationConfig_IsNotMultiTurn() {
        XCTAssertFalse(DefaultModes.dictation().usesMultiTurnProcessing)
    }

    func testConversationConfig_IsMultiTurn() {
        XCTAssertTrue(DefaultModes.conversation().usesMultiTurnProcessing)
    }

    func testSingleTurnLLMTransform_IsNotMultiTurn() {
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

        XCTAssertFalse(config.usesMultiTurnProcessing)
    }
}
