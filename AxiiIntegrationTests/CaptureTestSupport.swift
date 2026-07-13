//
//  CaptureTestSupport.swift
//  AxiiIntegrationTests
//
//  Shared fakes for capture/salvage/archive tests — extracted after the
//  third copy of near-identical stubs (ModeTurnSalvageTests,
//  DiscardSalvageTests, SimpleCaptureSpoolTests).
//

import Foundation
@testable import Axii

/// Transcriber returning a fixed string.
actor CannedTranscriber: TranscriptionProviding {
    private let text: String
    init(_ text: String) { self.text = text }
    var isReady: Bool { true }
    func prepare() async throws {}
    func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
        text
    }
}

/// Transcriber whose every call fails — the ASR-unavailable world.
actor ThrowingTranscriber: TranscriptionProviding {
    var isReady: Bool { true }
    func prepare() async throws {}
    func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
        throw TranscriptionError.notReady
    }
}

/// Transcriber that suspends until released — pins WHERE in a sequence
/// gates and custody resolve relative to transcription.
actor GatedTranscriber: TranscriptionProviding {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private let text: String
    init(_ text: String) { self.text = text }
    var isReady: Bool { true }
    func prepare() async throws {}
    func release() {
        released = true
        continuations.forEach { $0.resume() }
        continuations.removeAll()
    }
    func transcribe(samples: [Float], sampleRate: Double) async throws -> String {
        if !released {
            await withCheckedContinuation { continuations.append($0) }
        }
        return text
    }
}

final class NoopPasteProvider: PasteProviding {
    func paste(
        text: String,
        focusSnapshot: FocusSnapshot?,
        finishBehavior: FinishBehavior,
        failureBehavior: InsertionFailureBehavior
    ) async -> PasteService.Outcome { .skipped }
}

/// A 440 Hz sine — real signal above any silence threshold.
func testTone(seconds: Double, sampleRate: Double = 16_000) -> [Float] {
    (0..<Int(seconds * sampleRate)).map { i in
        Float(sin(Double(i) * 2.0 * .pi * 440.0 / sampleRate) * 0.5)
    }
}
