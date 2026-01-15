//
//  MicrophoneSelectionService.swift
//  dictaitor
//
//  Enumerates available microphones and manages selection.
//  Uses CoreAudio for device enumeration.
//

#if os(macOS)
import CoreAudio
import AVFoundation

/// Represents an audio input device.
struct AudioInputDevice: Identifiable, Equatable, Hashable {
    let id: AudioDeviceID
    let name: String
    let uid: String

    static let systemDefault = AudioInputDevice(
        id: 0,
        name: "System Default",
        uid: "system_default"
    )
}

/// Manages microphone enumeration and selection.
@MainActor
@Observable
final class MicrophoneSelectionService {
    private(set) var availableDevices: [AudioInputDevice] = []
    private(set) var selectedDevice: AudioInputDevice = .systemDefault

    private let userDefaultsKey = "selectedMicrophoneUID"

    init() {
        refreshDevices()
        loadSavedSelection()
    }

    func refreshDevices() {
        var devices = [AudioInputDevice.systemDefault]
        devices.append(contentsOf: enumerateInputDevices())
        availableDevices = devices

        // Verify saved selection still exists
        if selectedDevice != .systemDefault {
            let stillExists = devices.contains { $0.uid == selectedDevice.uid }
            if !stillExists {
                selectDevice(.systemDefault)
            }
        }
    }

    func selectDevice(_ device: AudioInputDevice) {
        selectedDevice = device
        UserDefaults.standard.set(device.uid, forKey: userDefaultsKey)

        if device == .systemDefault {
            clearAggregateDevice()
        } else {
            setInputDevice(device.id)
        }
    }

    private func loadSavedSelection() {
        guard let savedUID = UserDefaults.standard.string(forKey: userDefaultsKey) else {
            return
        }

        if let device = availableDevices.first(where: { $0.uid == savedUID }) {
            selectedDevice = device
            if device != .systemDefault {
                setInputDevice(device.id)
            }
        }
    }

    private func enumerateInputDevices() -> [AudioInputDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )

        guard status == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )

        guard status == noErr else { return [] }

        return deviceIDs.compactMap { deviceID -> AudioInputDevice? in
            guard hasInputChannels(deviceID) else { return nil }
            guard let name = getDeviceName(deviceID) else { return nil }
            guard let uid = getDeviceUID(deviceID) else { return nil }
            return AudioInputDevice(id: deviceID, name: name, uid: uid)
        }
    }

    private func hasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return false }

        let bufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        defer { bufferListPointer.deallocate() }

        let result = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, bufferListPointer)
        guard result == noErr else { return false }

        let bufferList = bufferListPointer.pointee
        return bufferList.mNumberBuffers > 0
    }

    private func getDeviceName(_ deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var name: CFString?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)

        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &name)
        guard status == noErr, let deviceName = name else { return nil }

        return deviceName as String
    }

    private func getDeviceUID(_ deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var uid: CFString?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)

        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &uid)
        guard status == noErr, let deviceUID = uid else { return nil }

        return deviceUID as String
    }

    private func setInputDevice(_ deviceID: AudioDeviceID) {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var mutableDeviceID = deviceID
        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &mutableDeviceID
        )
    }

    private func clearAggregateDevice() {
        // When using system default, we don't override
        // AVAudioEngine will use whatever the system default is
    }
}
#endif
