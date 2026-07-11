// POC 2 (recorder side): capture N seconds from a SPECIFIC input device by
// UID via AVCaptureSession — the same API path Axii's MicrophoneCapture
// uses (AVCaptureDevice matched on uniqueID). Writes a WAV and prints peak
// and RMS so silence (a dead loopback or muted BlackHole volume) is
// detectable, not just "a file exists".
//
// Usage: record_from_device <device-uid> <seconds> <out-wav-path>

import AVFoundation
import Foundation

guard CommandLine.arguments.count == 4,
      let seconds = Double(CommandLine.arguments[2]) else {
    print("usage: record_from_device <device-uid> <seconds> <out-wav>")
    exit(2)
}
let uid = CommandLine.arguments[1]
let outURL = URL(fileURLWithPath: CommandLine.arguments[3])

let discovery = AVCaptureDevice.DiscoverySession(
    deviceTypes: [.microphone, .external],
    mediaType: .audio,
    position: .unspecified
)
guard let device = discovery.devices.first(where: { $0.uniqueID == uid }) else {
    print("DEVICE_NOT_FOUND uid=\(uid)")
    print("AVAILABLE: \(discovery.devices.map { "\($0.uniqueID)|\($0.localizedName)" }.joined(separator: ", "))")
    exit(1)
}
print("DEVICE_FOUND \(device.localizedName)")

final class Sink: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    var samples: [Float] = []
    var sampleRate: Double = 0

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee
        else { return }
        sampleRate = asbd.mSampleRate
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(
            block, atOffset: 0, lengthAtOffsetOut: nil,
            totalLengthOut: &length, dataPointerOut: &pointer
        ) == noErr, let pointer else { return }

        let channels = Int(asbd.mChannelsPerFrame)
        if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            let count = length / MemoryLayout<Float>.size
            pointer.withMemoryRebound(to: Float.self, capacity: count) { floats in
                for frame in stride(from: 0, to: count, by: channels) {
                    samples.append(floats[frame])
                }
            }
        } else if asbd.mBitsPerChannel == 16 {
            let count = length / MemoryLayout<Int16>.size
            pointer.withMemoryRebound(to: Int16.self, capacity: count) { ints in
                for frame in stride(from: 0, to: count, by: channels) {
                    samples.append(Float(ints[frame]) / Float(Int16.max))
                }
            }
        }
    }
}

let session = AVCaptureSession()
let input = try AVCaptureDeviceInput(device: device)
session.addInput(input)
let output = AVCaptureAudioDataOutput()
let sink = Sink()
output.setSampleBufferDelegate(sink, queue: DispatchQueue(label: "poc.capture"))
session.addOutput(output)
session.startRunning()
print("RECORDING \(seconds)s at whatever rate the device delivers")

RunLoop.current.run(until: Date().addingTimeInterval(seconds))
session.stopRunning()
Thread.sleep(forTimeInterval: 0.3)

let samples = sink.samples
guard !samples.isEmpty else {
    print("NO_SAMPLES (permission denied or dead device?)")
    exit(1)
}
let peak = samples.map(abs).max() ?? 0
let rms = (samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
print(String(
    format: "CAPTURED samples=%d rate=%.0f peak=%.4f rms=%.4f",
    samples.count, sink.sampleRate, peak, rms
))

// Write mono float32 WAV for transcription checks.
let format = AVAudioFormat(
    commonFormat: .pcmFormatFloat32, sampleRate: sink.sampleRate,
    channels: 1, interleaved: false
)!
let buffer = AVAudioPCMBuffer(
    pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)
)!
buffer.frameLength = AVAudioFrameCount(samples.count)
samples.withUnsafeBufferPointer { source in
    buffer.floatChannelData!.pointee.update(from: source.baseAddress!, count: samples.count)
}
let file = try AVAudioFile(
    forWriting: outURL,
    settings: format.settings,
    commonFormat: .pcmFormatFloat32,
    interleaved: false
)
try file.write(from: buffer)
file.close() // exit() below skips deinit; close or the header stays 0-length
print("WROTE \(outURL.path)")
exit(peak > 0.01 ? 0 : 3) // exit 3 = captured but silent
