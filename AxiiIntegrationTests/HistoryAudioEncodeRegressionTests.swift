//
//  HistoryAudioEncodeRegressionTests.swift
//  AxiiIntegrationTests
//
//  Regression tripwire for the hour-long-recording encode wedge
//  (2026-07-15): a single AVAudioFile.write of a whole track wedges the AAC
//  codec once the input buffer crosses ~512MB (2^29 bytes ≈ 46.6 min of
//  48kHz mono Float32) — it degenerates into re-zeroing its output per
//  packet and burns 20+ CPU-minutes without finishing, freezing the app
//  (HistoryService is @MainActor). HistoryService now encodes in bounded
//  chunks; these tests pin bounded completion at a size ABOVE the knee.
//
//  The time budgets are wedge detectors, not performance targets: the
//  healthy encode is seconds, the wedge is tens of minutes.
//

import XCTest
@testable import Axii

@MainActor
final class HistoryAudioEncodeRegressionTests: XCTestCase {

    /// 48 min @ 48kHz mono Float32 = 553MB — above the 512MB codec knee.
    private static let aboveKneeSampleCount = 48 * 60 * 48_000
    private static let sampleRate = 48_000.0
    private static let wedgeBudgetSeconds = 120.0

    private var tempDir: URL!
    private var history: HistoryService!
    private var interactionId: UUID!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AxiiEncodeRegression-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        history = HistoryService(historyDirectory: tempDir)
        history.isEnabled = true
        // saveAudioCompressed requires an existing metadata cache entry.
        let transcription = Transcription(text: "encode regression")
        _ = try await history.save(.transcription(transcription))
        interactionId = transcription.id
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil; history = nil; interactionId = nil
    }

    /// Non-silent hour-scale track, built cheaply from a tiled 0.1s sine.
    private func aboveKneeTrack() -> [Float] {
        let tile = (0..<4_800).map { index in
            sinf(2 * .pi * 220 * Float(index) / 48_000) * 0.3
        }
        var samples: [Float] = []
        samples.reserveCapacity(Self.aboveKneeSampleCount + tile.count)
        while samples.count < Self.aboveKneeSampleCount {
            samples.append(contentsOf: tile)
        }
        return samples
    }

    func testAboveKneeAACEncodeCompletesInBoundedTime() async throws {
        let samples = aboveKneeTrack()
        let start = Date()
        _ = try await history.saveAudioCompressed(
            samples: samples,
            sampleRate: Self.sampleRate,
            format: .aac,
            for: interactionId
        )
        XCTAssertLessThan(
            Date().timeIntervalSince(start), Self.wedgeBudgetSeconds,
            "AAC encode of an hour-scale track wedged — chunked writes regressed"
        )
    }

    func testAboveKneeALACEncodeCompletesInBoundedTime() async throws {
        let samples = aboveKneeTrack()
        let start = Date()
        _ = try await history.saveAudioCompressed(
            samples: samples,
            sampleRate: Self.sampleRate,
            format: .alac,
            for: interactionId
        )
        XCTAssertLessThan(
            Date().timeIntervalSince(start), Self.wedgeBudgetSeconds,
            "ALAC encode of an hour-scale track wedged — chunked writes regressed"
        )
    }
}
