//
//  AudioSampleExtraction.swift
//  Axii
//
//  One correct conversion from raw PCM block-buffer bytes to mono float32,
//  honoring the stream description: sample format (float32/int16/int32),
//  channel count, and interleaved vs planar layout.
//
//  Shared by every capture path. MicrophoneCapture used to assume mono
//  float32 and silently corrupted stereo devices — a planar 2-channel input
//  (BlackHole, USB audio interfaces) had each buffer's content emitted
//  twice back-to-back, garbling transcription and the level display.
//

#if os(macOS)
import CoreMedia
import Foundation

enum AudioSampleExtraction {

    /// Extract mono float samples (and the delivered sample rate) from a
    /// capture buffer. Returns nil when the buffer carries no readable data.
    static func monoFloatSamples(
        from sampleBuffer: CMSampleBuffer
    ) -> (samples: [Float], sampleRate: Double)? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(
                  formatDesc
              )?.pointee,
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer)
        else { return nil }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        )
        guard status == kCMBlockBufferNoErr, let data = dataPointer else {
            return nil
        }

        let samples = monoFloatSamples(
            data: UnsafeRawPointer(data), byteLength: length, asbd: asbd
        )
        return (samples, asbd.mSampleRate)
    }

    /// Pure conversion — separated so unit tests can drive every format and
    /// layout combination without constructing CMSampleBuffers.
    static func monoFloatSamples(
        data: UnsafeRawPointer,
        byteLength: Int,
        asbd: AudioStreamBasicDescription
    ) -> [Float] {
        let raw = floatSamples(
            data: data,
            byteLength: byteLength,
            bitsPerChannel: asbd.mBitsPerChannel,
            isFloat: asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        )
        return downmixed(
            raw,
            channels: Int(asbd.mChannelsPerFrame),
            isPlanar: asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        )
    }

    // MARK: - Private

    private static func floatSamples(
        data: UnsafeRawPointer,
        byteLength: Int,
        bitsPerChannel: UInt32,
        isFloat: Bool
    ) -> [Float] {
        if !isFloat && bitsPerChannel == 16 {
            let count = byteLength / MemoryLayout<Int16>.size
            let pointer = data.bindMemory(to: Int16.self, capacity: count)
            return UnsafeBufferPointer(start: pointer, count: count)
                .map { Float($0) / Float(Int16.max) }
        }
        if !isFloat && bitsPerChannel == 32 {
            let count = byteLength / MemoryLayout<Int32>.size
            let pointer = data.bindMemory(to: Int32.self, capacity: count)
            return UnsafeBufferPointer(start: pointer, count: count)
                .map { Float($0) / Float(Int32.max) }
        }
        // Float32 — and the historical fallback for unknown formats.
        let count = byteLength / MemoryLayout<Float>.size
        let pointer = data.bindMemory(to: Float.self, capacity: count)
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }

    /// Average all channels into mono. Handles any channel count so a
    /// 16-channel virtual device degrades gracefully rather than corrupting.
    private static func downmixed(
        _ samples: [Float], channels: Int, isPlanar: Bool
    ) -> [Float] {
        guard channels >= 2, samples.count >= channels else { return samples }
        let frames = samples.count / channels
        var mono = [Float](repeating: 0, count: frames)
        if isPlanar {
            // [c0f0, c0f1, ..., c1f0, c1f1, ...] — one plane per channel
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels {
                    sum += samples[channel * frames + frame]
                }
                mono[frame] = sum / Float(channels)
            }
        } else {
            // [c0f0, c1f0, c0f1, c1f1, ...] — channels interleaved per frame
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels {
                    sum += samples[frame * channels + channel]
                }
                mono[frame] = sum / Float(channels)
            }
        }
        return mono
    }
}
#endif
