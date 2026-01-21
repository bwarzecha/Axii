//
//  DeviceMonitor.swift
//  Axii
//
//  Monitors audio device changes via CoreAudio.
//  Enumerates devices with transport type and detects disconnection.
//

#if os(macOS)
import CoreAudio
import Foundation

/// Monitors audio input devices and notifies of changes.
/// Uses CoreAudio's kAudioHardwarePropertyDevices listener.
final class DeviceMonitor: @unchecked Sendable {
    private var selectedDeviceUID: String?
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private let notifyQueue = DispatchQueue(label: "audio.device.monitor", qos: .utility)

    /// Called when selected device is disconnected.
    var onDeviceDisconnected: ((AudioDevice) -> Void)?

    /// Called when device list changes (for UI refresh).
    var onDeviceListChanged: (() -> Void)?

    init() {
        setupDeviceListListener()
    }

    deinit {
        removeDeviceListListener()
    }

    // MARK: - Public API

    /// Set the device to monitor for disconnection.
    func monitorDevice(_ device: AudioDevice?) {
        selectedDeviceUID = device?.uid
    }

    /// List all available microphone devices with transport type.
    nonisolated static func availableMicrophones() -> [AudioDevice] {
        enumerateInputDevices()
    }

    /// Get the system default input device.
    nonisolated static func systemDefaultDevice() -> AudioDevice? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr, deviceID != 0 else { return nil }
        return createAudioDevice(from: deviceID)
    }

    // MARK: - Device List Listener

    private func setupDeviceListListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDeviceListChange()
        }

        listenerBlock = block

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            notifyQueue,
            block
        )
    }

    private func removeDeviceListListener() {
        guard let block = listenerBlock else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            notifyQueue,
            block
        )
    }

    private func handleDeviceListChange() {
        // Notify of general device list change
        onDeviceListChanged?()

        // Check if monitored device is still present
        guard let monitoredUID = selectedDeviceUID else { return }

        let currentDevices = Self.enumerateInputDevices()
        let deviceStillPresent = currentDevices.contains { $0.uid == monitoredUID }

        if !deviceStillPresent {
            // Find the disconnected device info (we may have cached it)
            // For now, create a placeholder with the UID
            let disconnectedDevice = AudioDevice(
                id: 0,
                uid: monitoredUID,
                name: "Disconnected Device",
                transportType: .unknown
            )
            onDeviceDisconnected?(disconnectedDevice)
        }
    }

    // MARK: - Device Enumeration

    nonisolated private static func enumerateInputDevices() -> [AudioDevice] {
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

        return deviceIDs.compactMap { deviceID -> AudioDevice? in
            guard hasInputChannels(deviceID) else { return nil }
            return createAudioDevice(from: deviceID)
        }
    }

    nonisolated private static func createAudioDevice(from deviceID: AudioDeviceID) -> AudioDevice? {
        guard let name = getDeviceName(deviceID),
              let uid = getDeviceUID(deviceID) else {
            return nil
        }

        let transportType = getTransportType(deviceID)

        return AudioDevice(
            id: deviceID,
            uid: uid,
            name: name,
            transportType: transportType
        )
    }

    nonisolated private static func hasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
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

        return bufferListPointer.pointee.mNumberBuffers > 0
    }

    nonisolated private static func getDeviceName(_ deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var name: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &name)
        guard status == noErr, let unmanagedName = name else { return nil }

        return unmanagedName.takeUnretainedValue() as String
    }

    nonisolated private static func getDeviceUID(_ deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var uid: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &uid)
        guard status == noErr, let unmanagedUID = uid else { return nil }

        return unmanagedUID.takeUnretainedValue() as String
    }

    nonisolated private static func getTransportType(_ deviceID: AudioDeviceID) -> AudioDevice.TransportType {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(AudioObjectID(deviceID), &propertyAddress) else {
            return .unknown
        }

        var transportType: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(deviceID),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &transportType
        )

        guard status == noErr else { return .unknown }

        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:
            return .builtIn
        case kAudioDeviceTransportTypeUSB:
            return .usb
        case kAudioDeviceTransportTypeBluetooth:
            return .bluetooth
        case kAudioDeviceTransportTypeBluetoothLE:
            return .bluetoothLE
        case kAudioDeviceTransportTypeAggregate:
            return .aggregate
        case kAudioDeviceTransportTypeVirtual:
            return .virtual
        default:
            return .unknown
        }
    }
}
#endif
