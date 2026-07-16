//
//  AudioResampler.swift
//  Axii
//
//  Shared linear-interpolation resampler (vDSP), used wherever buffers with
//  different sample rates must be combined — device switches mid-recording
//  produce exactly that.
//

import Accelerate
import Foundation

enum AudioResampler {
    /// Output samples per vDSP window. The interpolation indices are Float32:
    /// a single ramp across a long recording quantizes once values pass 2^24
    /// (~5.8 min of 48kHz source) — indices stall in runs and the tail
    /// degrades to sample-and-hold garbage. Windowing keeps every ramp value
    /// small (≤ windowSize × ratio), where Float32 still has fine fractional
    /// precision, at any recording length.
    private static let windowSize = 4_096

    /// Resample `samples` from `sourceRate` to `targetRate`.
    /// Returns the input unchanged when rates match or inputs are trivial.
    static func resample(
        _ samples: [Float],
        from sourceRate: Double,
        to targetRate: Double
    ) -> [Float] {
        guard sourceRate > 0, targetRate > 0, sourceRate != targetRate,
              samples.count > 1 else { return samples }

        let outputCount = Int(Double(samples.count) * targetRate / sourceRate)
        guard outputCount > 0 else { return [] }

        let ratio = sourceRate / targetRate
        var output = [Float](repeating: 0, count: outputCount)
        var indices = [Float](repeating: 0, count: Self.windowSize)

        samples.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                var windowStart = 0
                while windowStart < outputCount {
                    let count = min(Self.windowSize, outputCount - windowStart)
                    // The window's base source position is computed in Double,
                    // so only the small ramp lives in Float32.
                    let sourcePosition = Double(windowStart) * ratio
                    let baseIndex = min(Int(sourcePosition), samples.count - 1)
                    let span = samples.count - baseIndex

                    var rampStart = Float(sourcePosition - Double(baseIndex))
                    var rampIncrement = Float(ratio)
                    vDSP_vramp(
                        &rampStart, &rampIncrement, &indices, 1, vDSP_Length(count)
                    )
                    var low: Float = 0
                    var high = Float(span - 1)
                    vDSP_vclip(indices, 1, &low, &high, &indices, 1, vDSP_Length(count))
                    vDSP_vlint(
                        source.baseAddress! + baseIndex,
                        indices, 1,
                        destination.baseAddress! + windowStart, 1,
                        vDSP_Length(count),
                        vDSP_Length(span)
                    )
                    windowStart += count
                }
            }
        }

        return output
    }

    /// Concatenate segments recorded at (possibly) different rates into one
    /// buffer at the LAST segment's rate.
    static func combine(
        segments: [(samples: [Float], sampleRate: Double)]
    ) -> (samples: [Float], sampleRate: Double) {
        guard let last = segments.last else { return ([], 0) }
        guard segments.count > 1 else { return last }

        var combined: [Float] = []
        for segment in segments {
            combined.append(contentsOf: resample(
                segment.samples, from: segment.sampleRate, to: last.sampleRate
            ))
        }
        return (combined, last.sampleRate)
    }
}
