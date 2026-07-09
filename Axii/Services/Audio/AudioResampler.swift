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

        var output = [Float](repeating: 0, count: outputCount)
        var indices = [Float](repeating: 0, count: outputCount)
        var index: Float = 0
        var increment = Float(sourceRate / targetRate)
        vDSP_vramp(&index, &increment, &indices, 1, vDSP_Length(outputCount))

        var maxIndex = Float(samples.count - 1)
        vDSP_vclip(indices, 1, &index, &maxIndex, &indices, 1, vDSP_Length(outputCount))
        vDSP_vlint(samples, indices, 1, &output, 1, vDSP_Length(outputCount), vDSP_Length(samples.count))

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
