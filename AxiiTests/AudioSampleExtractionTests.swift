//
//  AudioSampleExtractionTests.swift
//  AxiiTests
//
//  AudioSampleExtraction behavior:
//  1. Mono float32 passes through untouched
//  2. Planar (non-interleaved) stereo averages planes frame-by-frame —
//     the BlackHole/USB-interface regression (was: emitted both planes
//     sequentially, doubling every buffer)
//  3. Interleaved stereo averages per frame
//  4. Int16/Int32 inputs are scaled to [-1, 1] floats
//  5. Any channel count downmixes, not just 2
//

import CoreAudioTypes
import XCTest
@testable import Axii

final class AudioSampleExtractionTests: XCTestCase {

    private func asbd(
        channels: UInt32, bits: UInt32, isFloat: Bool, planar: Bool
    ) -> AudioStreamBasicDescription {
        var flags: AudioFormatFlags = 0
        if isFloat { flags |= kAudioFormatFlagIsFloat }
        if planar { flags |= kAudioFormatFlagIsNonInterleaved }
        if !isFloat { flags |= kAudioFormatFlagIsSignedInteger }
        return AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: flags, mBytesPerPacket: 0, mFramesPerPacket: 1,
            mBytesPerFrame: 0, mChannelsPerFrame: channels,
            mBitsPerChannel: bits, mReserved: 0
        )
    }

    private func extract<T>(
        _ values: [T], _ description: AudioStreamBasicDescription
    ) -> [Float] {
        let byteLength = values.count * MemoryLayout<T>.size
        let raw = UnsafeMutableRawBufferPointer.allocate(
            byteCount: max(byteLength, MemoryLayout<T>.size),
            alignment: MemoryLayout<T>.alignment
        )
        defer { raw.deallocate() }
        if !values.isEmpty {
            values.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        return AudioSampleExtraction.monoFloatSamples(
            data: UnsafeRawPointer(raw.baseAddress!),
            byteLength: byteLength,
            asbd: description
        )
    }

    func testMonoFloatPassesThrough() {
        let samples: [Float] = [0.1, -0.2, 0.3, -0.4]
        let result = extract(
            samples, asbd(channels: 1, bits: 32, isFloat: true, planar: true)
        )
        XCTAssertEqual(result, samples)
    }

    func testPlanarStereoAveragesPlanesNotConcatenatesThem() {
        // Channel 0 plane then channel 1 plane. The old code emitted all 6
        // values as mono — the clip played twice. Correct: 3 averaged frames.
        let planar: [Float] = [1, 1, 1, 0, 0, 0]
        let result = extract(
            planar, asbd(channels: 2, bits: 32, isFloat: true, planar: true)
        )
        XCTAssertEqual(result, [0.5, 0.5, 0.5])
    }

    func testPlanarStereoPreservesFrameOrder() {
        let planar: [Float] = [0.2, 0.4, 0.6, 0.0, 0.0, 0.0]
        let result = extract(
            planar, asbd(channels: 2, bits: 32, isFloat: true, planar: true)
        )
        XCTAssertEqual(result, [0.1, 0.2, 0.3])
    }

    func testInterleavedStereoAveragesPerFrame() {
        let interleaved: [Float] = [1, 0, 0.5, 0.5, 0, 1]
        let result = extract(
            interleaved, asbd(channels: 2, bits: 32, isFloat: true, planar: false)
        )
        XCTAssertEqual(result, [0.5, 0.5, 0.5])
    }

    func testInt16ScalesToUnitRange() {
        let ints: [Int16] = [Int16.max, 0, Int16.min / 2]
        let result = extract(
            ints, asbd(channels: 1, bits: 16, isFloat: false, planar: false)
        )
        XCTAssertEqual(result[0], 1.0, accuracy: 0.001)
        XCTAssertEqual(result[1], 0.0, accuracy: 0.001)
        XCTAssertEqual(result[2], -0.5, accuracy: 0.001)
    }

    func testInt32ScalesToUnitRange() {
        let ints: [Int32] = [Int32.max, Int32.min / 4]
        let result = extract(
            ints, asbd(channels: 1, bits: 32, isFloat: false, planar: false)
        )
        XCTAssertEqual(result[0], 1.0, accuracy: 0.001)
        XCTAssertEqual(result[1], -0.25, accuracy: 0.001)
    }

    func testQuadChannelDownmixes() {
        // 4 channels interleaved, one frame: average of 0.4, 0.0, 0.8, 0.0
        let interleaved: [Float] = [0.4, 0.0, 0.8, 0.0]
        let result = extract(
            interleaved, asbd(channels: 4, bits: 32, isFloat: true, planar: false)
        )
        XCTAssertEqual(result, [0.3])
    }

    func testEmptyInputYieldsEmptyOutput() {
        let result = extract(
            [Float](), asbd(channels: 2, bits: 32, isFloat: true, planar: true)
        )
        XCTAssertTrue(result.isEmpty)
    }
}
