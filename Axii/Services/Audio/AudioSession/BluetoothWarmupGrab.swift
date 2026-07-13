//
//  BluetoothWarmupGrab.swift
//  Axii
//
//  Multipoint Bluetooth headsets (AirPods) deliver pure digital zeros to a
//  mic capture for as long as ANOTHER paired device owns them — and an input
//  stream never forces the ownership move; only an OUTPUT stream does.
//  Measured on real hardware: 4 fresh capture sessions over 14s stayed dead,
//  while a silent output stream warmed the mic in ~1s and a wedged session
//  recovered IN PLACE (poc/bt-warmup/FINDINGS.md).
//
//  This component holds a silent HAL output unit on the Bluetooth device's
//  output sibling for the duration of a capture: it forces the multipoint
//  handoff to this Mac and pins ownership so another device cannot steal
//  the headset mid-recording. While the mic is engaged the output side is
//  in voice mode anyway, so the held stream costs no audio quality.
//

#if os(macOS)
import AudioToolbox
import CoreAudio
import Foundation

/// Seam for tests: capture owners start/stop the grab; fakes record calls.
protocol BluetoothWarmupGrabbing: AnyObject {
    func start(for device: AudioDevice)
    func stop()
}

final class BluetoothWarmupGrab: BluetoothWarmupGrabbing, @unchecked Sendable {
    // All HAL-unit work is confined to this queue. AudioUnit calls against a
    // dying Bluetooth device can block; they must never run on the caller
    // (main actor). A hung teardown is a stuck queue, not a frozen app.
    private let queue = DispatchQueue(label: "audio.warmup.grab", qos: .userInitiated)
    private var unit: AudioUnit?
    private var grabbedUID: String?

    /// Start (or move) the silent output grab for the given Bluetooth input
    /// device. Best-effort: failure to resolve or start leaves the capture
    /// exactly as it was without the grab — the 20s warmup timeout remains
    /// the backstop.
    func start(for device: AudioDevice) {
        guard device.isBluetooth else { return }
        queue.async { [self] in
            guard grabbedUID != device.uid else { return }
            stopLocked()
            guard let outputID = Self.outputSibling(of: device) else { return }
            unit = Self.makeSilentOutputUnit(on: outputID)
            grabbedUID = unit != nil ? device.uid : nil
        }
    }

    func stop() {
        queue.async { [self] in stopLocked() }
    }

    /// Whether a grab is currently held (drains pending queue work first).
    /// For tests — production code never needs to ask.
    var isHoldingGrab: Bool {
        queue.sync { unit != nil }
    }

    private func stopLocked() {
        guard let au = unit else { return }
        AudioOutputUnitStop(au)
        AudioUnitUninitialize(au)
        AudioComponentInstanceDispose(au)
        unit = nil
        grabbedUID = nil
    }

    // MARK: - Output sibling resolution

    /// Bluetooth headsets expose separate CoreAudio devices per direction,
    /// UID-paired as "<address>:input" / "<address>:output".
    static func outputSiblingUID(of inputUID: String) -> String? {
        let inputSuffix = ":input"
        guard inputUID.hasSuffix(inputSuffix) else { return nil }
        return String(inputUID.dropLast(inputSuffix.count)) + ":output"
    }

    /// Resolve the output-side CoreAudio device for a Bluetooth input device:
    /// by sibling UID first, by (name + output streams + Bluetooth) fallback.
    private static func outputSibling(of device: AudioDevice) -> AudioDeviceID? {
        let ids = allDeviceIDs()
        if let siblingUID = outputSiblingUID(of: device.uid),
           let id = ids.first(where: { deviceUID($0) == siblingUID }) {
            return id
        }
        return ids.first { id in
            outputStreamCount(id) > 0
                && isBluetoothTransport(id)
                && deviceName(id) == device.name
        }
    }

    // MARK: - Silent HAL output unit

    private static func makeSilentOutputUnit(on deviceID: AudioDeviceID) -> AudioUnit? {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else { return nil }
        var instance: AudioUnit?
        guard AudioComponentInstanceNew(component, &instance) == noErr,
              let au = instance else { return nil }

        var device = deviceID
        var render = AURenderCallbackStruct(
            inputProc: { _, _, _, _, _, ioData -> OSStatus in
                if let ioData {
                    for buffer in UnsafeMutableAudioBufferListPointer(ioData) {
                        if let data = buffer.mData {
                            memset(data, 0, Int(buffer.mDataByteSize))
                        }
                    }
                }
                return noErr
            },
            inputProcRefCon: nil)

        let configured = AudioUnitSetProperty(
            au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
            0, &device, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
            && AudioUnitSetProperty(
                au, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input,
                0, &render, UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr
            && AudioUnitInitialize(au) == noErr
            && AudioOutputUnitStart(au) == noErr

        guard configured else {
            AudioComponentInstanceDispose(au)
            return nil
        }
        return au
    }

    // MARK: - CoreAudio queries

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = propertyAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }
        var ids = [AudioDeviceID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }
        return ids
    }

    private static func deviceUID(_ id: AudioDeviceID) -> String? {
        stringProperty(id, kAudioDevicePropertyDeviceUID)
    }

    private static func deviceName(_ id: AudioDeviceID) -> String? {
        stringProperty(id, kAudioDevicePropertyDeviceNameCFString)
    }

    private static func outputStreamCount(_ id: AudioDeviceID) -> Int {
        var address = propertyAddress(
            kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr
        else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    private static func isBluetoothTransport(_ id: AudioDeviceID) -> Bool {
        var address = propertyAddress(kAudioDevicePropertyTransportType)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport) == noErr
        else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func stringProperty(
        _ id: AudioDeviceID, _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = propertyAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let cf = value?.takeRetainedValue() else { return nil }
        return cf as String
    }

    private static func propertyAddress(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
    }
}
#endif
