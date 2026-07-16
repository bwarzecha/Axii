//
//  AudioResamplerTests.swift
//  AxiiTests
//
//  Pins the windowed vDSP resampler's tail correctness for long recordings.
//  The previous implementation generated ONE Float32 index ramp across the
//  whole track: past 2^24 (~5.8 min of 48kHz source) the ramp values
//  quantize, indices stall in runs of repeated values, and the resampled
//  tail degrades to sample-and-hold garbage — meeting transcripts silently
//  corrupted from ~12 minutes onward (found 2026-07-15).
//

import XCTest
@testable import Axii

final class AudioResamplerTests: XCTestCase {

    /// A 50Hz sine is slow enough that linear interpolation error is
    /// negligible against the analytic signal — any visible deviation in
    /// the tail is index corruption, not interpolation error. The old
    /// single-ramp code shows errors here two orders of magnitude larger.
    func testLongResampleTailMatchesAnalyticSignal() {
        let sourceRate = 48_000.0
        let targetRate = 16_000.0
        let minutes = 8.0  // source indices reach 23M, well past 2^24
        let frequency = 50.0

        let sourceCount = Int(sourceRate * 60 * minutes)
        var source = [Float](repeating: 0, count: sourceCount)
        for index in 0..<sourceCount {
            source[index] = Float(sin(2.0 * .pi * frequency * Double(index) / sourceRate))
        }

        let output = AudioResampler.resample(source, from: sourceRate, to: targetRate)

        var maxTailError = 0.0
        for index in (output.count - 100_000)..<output.count {
            let expected = sin(2.0 * .pi * frequency * Double(index) / targetRate)
            maxTailError = max(maxTailError, abs(Double(output[index]) - expected))
        }
        XCTAssertLessThan(
            maxTailError, 0.01,
            "resample tail deviates from the analytic signal — Float32 index precision regressed"
        )
    }

    func testShortResampleIsUnchangedByWindowing() {
        let source = (0..<48_000).map { Float(sin(2.0 * .pi * 440 * Double($0) / 48_000)) }
        let output = AudioResampler.resample(source, from: 48_000, to: 16_000)
        XCTAssertEqual(output.count, 16_000)
        var maxError = 0.0
        for index in 0..<output.count {
            let expected = sin(2.0 * .pi * 440 * Double(index) / 16_000)
            maxError = max(maxError, abs(Double(output[index]) - expected))
        }
        // 440Hz @ 48kHz linear interpolation error bound is ~4e-3.
        XCTAssertLessThan(maxError, 0.01)
    }
}
