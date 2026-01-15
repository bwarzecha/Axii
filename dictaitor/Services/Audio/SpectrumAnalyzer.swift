//
//  SpectrumAnalyzer.swift
//  dictaitor
//
//  Audio waveform analyzer for visualization - shows amplitude variation across bars.
//

import Accelerate

/// Analyzes audio samples and produces waveform data for visualization.
/// Each bar represents the amplitude of a segment of the audio buffer.
enum SpectrumAnalyzer {
    static let bandCount = 80

    /// Calculate waveform bars from audio samples.
    /// - Parameter samples: Raw audio samples
    /// - Returns: Array of normalized bar heights (0-1)
    static func calculateSpectrum(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else {
            return Array(repeating: 0, count: bandCount)
        }

        // Divide samples into segments, one per bar
        let segmentSize = max(1, samples.count / bandCount)
        var bars = [Float](repeating: 0, count: bandCount)

        for i in 0..<bandCount {
            let start = i * segmentSize
            let end = min(start + segmentSize, samples.count)

            if start < samples.count {
                // Calculate RMS for this segment
                let segment = Array(samples[start..<end])
                var rms: Float = 0
                vDSP_rmsqv(segment, 1, &rms, vDSP_Length(segment.count))
                bars[i] = rms
            }
        }

        // Find max for normalization (with minimum threshold to avoid division issues)
        var maxVal: Float = 0
        vDSP_maxv(bars, 1, &maxVal, vDSP_Length(bandCount))

        // Use adaptive scaling: quiet sounds still show, loud sounds don't clip
        // Scale so typical speech easily reaches full height
        let scaleFactor: Float = 20.0  // Boost to make normal voice hit 100%
        let noiseFloor: Float = 0.08   // Minimum level to filter out background noise
        for i in 0..<bandCount {
            // Apply boost and clamp to 0-1
            var value = min(1.0, bars[i] * scaleFactor)
            // Apply noise gate
            if value < noiseFloor {
                value = 0
            }
            bars[i] = value
        }

        // Light spatial smoothing only (no temporal decay)
        var smoothed = bars
        for i in 1..<(bandCount - 1) {
            smoothed[i] = (bars[i-1] + bars[i] * 2 + bars[i+1]) / 4
        }

        return smoothed
    }

}
