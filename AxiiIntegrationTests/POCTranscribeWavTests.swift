//
//  POCTranscribeWavTests.swift
//  AxiiIntegrationTests
//
//  TEMPORARY POC (ui-e2e research): transcribe an arbitrary WAV supplied via
//  AXII_POC_WAV with the real Parakeet models. Used to validate that audio
//  captured through the BlackHole loopback transcribes correctly.
//  Delete once the real E2E suite lands.
//

import AVFoundation
import XCTest
@testable import Axii

@MainActor
final class POCTranscribeWavTests: XCTestCase {

    private static let modelsDirectory = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    ).first!.appendingPathComponent("Axii/Models")

    func testTranscribesSuppliedWav() async throws {
        guard let path = ProcessInfo.processInfo.environment["AXII_POC_WAV"] else {
            throw XCTSkip("POC only: set AXII_POC_WAV to a WAV path")
        }

        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: frameCount
        ) else { return XCTFail("buffer alloc failed") }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData else {
            return XCTFail("expected float samples")
        }
        let samples = Array(
            UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength))
        )
        let rate = file.processingFormat.sampleRate

        let service = TranscriptionService()
        try await service.prepare(modelsDirectory: Self.modelsDirectory)
        let text = try await service.transcribe(samples: samples, sampleRate: rate)

        // Sidecar file: xcodebuild log plumbing for print() is unreliable.
        let report = "rate=\(rate) samples=\(samples.count)\n\(text)\n"
        try report.write(
            to: URL(fileURLWithPath: path + ".transcript.txt"),
            atomically: true, encoding: .utf8
        )
        XCTAssertFalse(text.isEmpty, "Expected a non-empty transcript")
    }
}
