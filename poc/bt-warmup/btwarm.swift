//
//  btwarm.swift — POC: measure & force AirPods A2DP→HFP mic warm-up.
//
//  Goal: find the fastest reliable way to get non-silent mic samples from
//  multipoint-connected AirPods. Hypotheses under test:
//    H1  Nominal sample rate drop (<44.1kHz) is a deterministic "HFP engaged"
//        signal (wispr's waitForBluetoothHFP).
//    H2  Grabbing the AirPods via a silent OUTPUT stream first (ownership
//        steal on the A2DP path) makes the subsequent mic open fast/reliable.
//    H3  A capture session opened before the profile switch can wedge
//        (zeros forever); rebuilding after the rate settles unwedges it.
//
//  Usage:
//    btwarm list
//    btwarm watch  <name-substring> [seconds]
//    btwarm grab   <name-substring> [seconds]        # silent output stream
//    btwarm mic    <name-substring> [seconds]        # capture, Axii-style
//    btwarm combo  <name-substring> [grabSeconds]    # grab, then mic
//
//  Results are timestamped to stdout; run each scenario a few times.
//

import AVFoundation
import CoreAudio
import Foundation

// MARK: - Timestamping

let t0 = Date()
func log(_ msg: String) {
    let dt = Date().timeIntervalSince(t0)
    print(String(format: "[%8.3fs] %@", dt, msg))
    fflush(stdout)
}

// MARK: - CoreAudio property helpers

func propAddress(_ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                               mElement: kAudioObjectPropertyElementMain)
}

func allDeviceIDs() -> [AudioDeviceID] {
    var addr = propAddress(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size) == noErr else { return [] }
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                     &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func deviceString(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = propAddress(selector)
    var size = UInt32(MemoryLayout<CFString?>.size)
    var value: Unmanaged<CFString>?
    let status = withUnsafeMutablePointer(to: &value) { ptr in
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
    }
    guard status == noErr, let cf = value?.takeRetainedValue() else { return nil }
    return cf as String
}

func deviceName(_ id: AudioDeviceID) -> String {
    deviceString(id, kAudioDevicePropertyDeviceNameCFString) ?? "?"
}

func deviceUID(_ id: AudioDeviceID) -> String {
    deviceString(id, kAudioDevicePropertyDeviceUID) ?? "?"
}

func transportType(_ id: AudioDeviceID) -> String {
    var addr = propAddress(kAudioDevicePropertyTransportType)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return "?" }
    switch value {
    case kAudioDeviceTransportTypeBuiltIn: return "builtin"
    case kAudioDeviceTransportTypeBluetooth: return "bluetooth"
    case kAudioDeviceTransportTypeBluetoothLE: return "bluetoothLE"
    case kAudioDeviceTransportTypeUSB: return "usb"
    case kAudioDeviceTransportTypeVirtual: return "virtual"
    case kAudioDeviceTransportTypeAggregate: return "aggregate"
    default: return String(format: "0x%08x", value)
    }
}

func nominalSampleRate(_ id: AudioDeviceID) -> Double? {
    var addr = propAddress(kAudioDevicePropertyNominalSampleRate)
    var value: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
    return value
}

func streamCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
    var addr = propAddress(kAudioDevicePropertyStreams, scope: scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr else { return 0 }
    return Int(size) / MemoryLayout<AudioStreamID>.size
}

func isRunningSomewhere(_ id: AudioDeviceID) -> Bool {
    var addr = propAddress(kAudioDevicePropertyDeviceIsRunningSomewhere)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return false }
    return value != 0
}

func matchingDevices(_ needle: String) -> [AudioDeviceID] {
    allDeviceIDs().filter { deviceName($0).localizedCaseInsensitiveContains(needle) }
}

/// The device with an INPUT stream side (the one capture opens).
func findDevice(matching needle: String) -> AudioDeviceID? {
    let matches = matchingDevices(needle)
    return matches.first { streamCount($0, scope: kAudioObjectPropertyScopeInput) > 0 }
        ?? matches.first
}

/// The device with an OUTPUT stream side (the one the grab opens).
func findOutputDevice(matching needle: String) -> AudioDeviceID? {
    let matches = matchingDevices(needle)
    return matches.first { streamCount($0, scope: kAudioObjectPropertyScopeOutput) > 0 }
        ?? matches.first
}

func stateLine(_ id: AudioDeviceID) -> String {
    let rate = nominalSampleRate(id).map { String(format: "%.0f", $0) } ?? "?"
    return "rate=\(rate)Hz in=\(streamCount(id, scope: kAudioObjectPropertyScopeInput))"
        + " out=\(streamCount(id, scope: kAudioObjectPropertyScopeOutput))"
        + " running=\(isRunningSomewhere(id))"
}

/// One line covering every device matching the needle (AirPods expose
/// separate :input and :output CoreAudio devices — watch both).
func multiStateLine(_ needle: String) -> String {
    matchingDevices(needle).map { id in
        let side = streamCount(id, scope: kAudioObjectPropertyScopeInput) > 0 ? "IN" : "OUT"
        return "\(side)(\(id)): \(stateLine(id))"
    }.joined(separator: "  |  ")
}

// MARK: - Commands

func cmdList() {
    for id in allDeviceIDs() {
        print("id=\(id)  [\(transportType(id))]  \(deviceName(id))")
        print("    \(stateLine(id))  uid=\(deviceUID(id))")
    }
}

/// Poll the device state; print every change. H1 instrumentation.
func cmdWatch(_ needle: String, seconds: Double) {
    guard let id = findDevice(matching: needle) else {
        log("no device matching '\(needle)'"); exit(1)
    }
    log("watching \(deviceName(id)) (id=\(id), \(transportType(id)))")
    var last = ""
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        let line = multiStateLine(needle)
        if line != last {
            log(line)
            last = line
        }
        usleep(50_000)
    }
}

/// Open a SILENT output stream on the device via a HAL output unit.
/// This is the "play inaudible sound" ownership grab, minus any actual sound.
/// Returns the started unit; caller stops it with stopSilentOutput.
func startSilentOutput(on id: AudioDeviceID) -> AudioUnit? {
    var desc = AudioComponentDescription(
        componentType: kAudioUnitType_Output,
        componentSubType: kAudioUnitSubType_HALOutput,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0, componentFlagsMask: 0)
    guard let comp = AudioComponentFindNext(nil, &desc) else {
        log("no HAL output component"); return nil
    }
    var unit: AudioUnit?
    guard AudioComponentInstanceNew(comp, &unit) == noErr, let au = unit else {
        log("AudioComponentInstanceNew failed"); return nil
    }
    var dev = id
    var status = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                      kAudioUnitScope_Global, 0,
                                      &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
    guard status == noErr else { log("set output device failed: \(status)"); return nil }

    var cb = AURenderCallbackStruct(
        inputProc: { _, _, _, _, _, ioData -> OSStatus in
            if let ioData {
                let buffers = UnsafeMutableAudioBufferListPointer(ioData)
                for buf in buffers {
                    if let data = buf.mData {
                        memset(data, 0, Int(buf.mDataByteSize))
                    }
                }
            }
            return noErr
        },
        inputProcRefCon: nil)
    status = AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback,
                                  kAudioUnitScope_Input, 0,
                                  &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
    guard status == noErr else { log("set render callback failed: \(status)"); return nil }
    guard AudioUnitInitialize(au) == noErr else { log("initialize failed"); return nil }
    guard AudioOutputUnitStart(au) == noErr else { log("start failed"); return nil }
    log("silent output STARTED on device \(id)")
    return au
}

func stopSilentOutput(_ au: AudioUnit) {
    AudioOutputUnitStop(au)
    AudioUnitUninitialize(au)
    AudioComponentInstanceDispose(au)
    log("silent output stopped")
}

func cmdGrab(_ needle: String, seconds: Double) {
    guard let id = findOutputDevice(matching: needle) else {
        log("no device matching '\(needle)'"); exit(1)
    }
    log("grab: opening silent output on \(deviceName(id)) — \(multiStateLine(needle))")
    guard let au = startSilentOutput(on: id) else { exit(1) }

    var last = ""
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        let line = multiStateLine(needle)
        if line != last { log(line); last = line }
        usleep(50_000)
    }
    stopSilentOutput(au)
    log("grab done — \(multiStateLine(needle))")
}

/// The minimal-fix candidate: mic session starts FIRST (wedged, zeros),
/// grab starts `grabDelay` later and stays open. Does the SAME session
/// start delivering signal, or does it stay wedged until rebuilt?
func cmdMicGrab(_ needle: String, grabDelay: Double) {
    guard let outID = findOutputDevice(matching: needle) else {
        log("no output device matching '\(needle)'"); exit(1)
    }
    var grabUnit: AudioUnit?
    // micAttempt blocks the main thread, so start the grab from a helper queue.
    let queue = DispatchQueue(label: "btwarm.grabdelay")
    queue.asyncAfter(deadline: .now() + grabDelay) {
        log(">>> starting grab while mic session keeps running")
        grabUnit = startSilentOutput(on: outID)
    }
    let ok = micAttempt(needle, seconds: 20)
    log(ok ? "SESSION RECOVERED IN PLACE" : "session stayed wedged despite grab")
    if let au = grabUnit { stopSilentOutput(au) }
}

// MARK: - Mic capture (Axii-style AVCaptureSession)

final class CaptureProbe: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    let needle: String
    var sawFirstBuffer = false
    var sawFirstSignal = false
    var bufferCount = 0

    init(needle: String) { self.needle = needle }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        bufferCount += 1
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length,
                                          dataPointerOut: &dataPointer) == noErr,
              let ptr = dataPointer else { return }
        let floats = UnsafeRawPointer(ptr).bindMemory(to: Float.self,
                                                      capacity: length / 4)
        var maxAmp: Float = 0
        for i in 0..<(length / 4) { maxAmp = max(maxAmp, abs(floats[i])) }

        if !sawFirstBuffer {
            sawFirstBuffer = true
            log("FIRST BUFFER  maxAmp=\(maxAmp)  \(multiStateLine(needle))")
        }
        if !sawFirstSignal && maxAmp > 0.0001 {
            sawFirstSignal = true
            log("FIRST SIGNAL (> -80dB)  maxAmp=\(maxAmp)  buffers=\(bufferCount)  \(multiStateLine(needle))")
        }
    }
}

func avDevice(forUID uid: String) -> AVCaptureDevice? {
    let discovery = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
    return discovery.devices.first { $0.uniqueID == uid }
}

func ensureMicPermission() {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return
    case .notDetermined:
        log("requesting mic permission...")
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        AVCaptureDevice.requestAccess(for: .audio) { granted in ok = granted; sem.signal() }
        sem.wait()
        log("mic permission granted=\(ok)")
        if !ok { exit(1) }
    default:
        log("mic permission DENIED for this host — grant it in System Settings"); exit(1)
    }
}

/// One capture attempt, Axii-style (pinned float32 output settings).
/// Returns true if a non-silent buffer arrived within `seconds`.
@discardableResult
func micAttempt(_ needle: String, seconds: Double) -> Bool {
    guard let id = findDevice(matching: needle) else {
        log("no device matching '\(needle)'"); exit(1)
    }
    ensureMicPermission()
    let uid = deviceUID(id)
    guard let dev = avDevice(forUID: uid) else {
        log("no AVCaptureDevice with uid \(uid) — device may have no input side yet")
        exit(1)
    }
    log("mic: starting capture on \(deviceName(id)) — \(multiStateLine(needle))")

    let session = AVCaptureSession()
    session.beginConfiguration()
    guard let input = try? AVCaptureDeviceInput(device: dev),
          session.canAddInput(input) else {
        log("cannot add input"); exit(1)
    }
    session.addInput(input)
    let output = AVCaptureAudioDataOutput()
    output.audioSettings = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false,
        AVLinearPCMIsBigEndianKey: false,
    ]
    let probe = CaptureProbe(needle: needle)
    let queue = DispatchQueue(label: "btwarm.capture")
    output.setSampleBufferDelegate(probe, queue: queue)
    guard session.canAddOutput(output) else { log("cannot add output"); exit(1) }
    session.addOutput(output)
    session.commitConfiguration()

    log("startRunning()...")
    session.startRunning()
    log("startRunning returned")

    var last = ""
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        let line = multiStateLine(needle)
        if line != last { log(line); last = line }
        usleep(50_000)
        if probe.sawFirstSignal { Thread.sleep(forTimeInterval: 0.5); break }
    }
    session.stopRunning()
    log("mic done — buffers=\(probe.bufferCount) firstBuffer=\(probe.sawFirstBuffer) firstSignal=\(probe.sawFirstSignal)")
    return probe.sawFirstSignal
}

func cmdMic(_ needle: String, seconds: Double) {
    micAttempt(needle, seconds: seconds)
}

/// H3: the candidate Axii fix — if a session delivers only zeros for
/// `attemptSeconds`, tear it down and open a FRESH one. Up to 4 attempts.
func cmdRebuild(_ needle: String, attemptSeconds: Double) {
    for attempt in 1...4 {
        log("=== rebuild attempt \(attempt) ===")
        if micAttempt(needle, seconds: attemptSeconds) {
            log("SUCCESS on attempt \(attempt)")
            return
        }
        Thread.sleep(forTimeInterval: 0.3)
    }
    log("FAILED: no signal after 4 attempts")
}

/// H2 full test: silent-output grab first, then capture.
func cmdCombo(_ needle: String, grabSeconds: Double) {
    guard let id = findDevice(matching: needle) else {
        log("no device matching '\(needle)'"); exit(1)
    }
    log("combo: grab \(grabSeconds)s then mic — \(deviceName(id))")
    cmdGrab(needle, seconds: grabSeconds)
    cmdMic(needle, seconds: 25)
    _ = id
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: btwarm list | watch <name> [s] | grab <name> [s] | mic <name> [s] | combo <name> [grabS] | rebuild <name> [attemptS]")
    exit(1)
}
switch args[1] {
case "list": cmdList()
case "watch": cmdWatch(args[2], seconds: args.count > 3 ? Double(args[3]) ?? 30 : 30)
case "grab": cmdGrab(args[2], seconds: args.count > 3 ? Double(args[3]) ?? 5 : 5)
case "mic": cmdMic(args[2], seconds: args.count > 3 ? Double(args[3]) ?? 25 : 25)
case "combo": cmdCombo(args[2], grabSeconds: args.count > 3 ? Double(args[3]) ?? 3 : 3)
case "rebuild": cmdRebuild(args[2], attemptSeconds: args.count > 3 ? Double(args[3]) ?? 3 : 3)
case "micgrab": cmdMicGrab(args[2], grabDelay: args.count > 3 ? Double(args[3]) ?? 1 : 1)
default: print("unknown command \(args[1])"); exit(1)
}
