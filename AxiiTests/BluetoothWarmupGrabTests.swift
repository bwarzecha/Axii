//
//  BluetoothWarmupGrabTests.swift
//  AxiiTests
//
//  BluetoothWarmupGrab behavior:
//  1. Maps a Bluetooth input UID to its output sibling
//  2. Rejects UIDs that are not input-suffixed
//  3. Never grabs for non-Bluetooth devices
//  4. Fails safe (no grab, no crash) when the device does not exist
//
//  The grab's effect on real AirPods (ownership steal, mic un-wedge) needs
//  Bluetooth hardware and is verified live; poc/bt-warmup/FINDINGS.md holds
//  the measured evidence.
//

import XCTest
@testable import Axii

final class BluetoothWarmupGrabTests: XCTestCase {

    private func makeDevice(
        uid: String, transport: AudioDevice.TransportType
    ) -> AudioDevice {
        AudioDevice(id: 0, uid: uid, name: "Test Device", transportType: transport)
    }

    // MARK: - Output sibling UID mapping

    func testOutputSiblingUIDMapsInputSuffixToOutput() {
        XCTAssertEqual(
            BluetoothWarmupGrab.outputSiblingUID(of: "34-0E-22-27-B3-11:input"),
            "34-0E-22-27-B3-11:output")
    }

    func testOutputSiblingUIDRejectsUnsuffixedUID() {
        XCTAssertNil(BluetoothWarmupGrab.outputSiblingUID(of: "BuiltInMicrophoneDevice"))
    }

    func testOutputSiblingUIDRejectsOutputUID() {
        XCTAssertNil(BluetoothWarmupGrab.outputSiblingUID(of: "34-0E-22-27-B3-11:output"))
    }

    // MARK: - Grab lifecycle safety (headless: no Bluetooth hardware)

    func testStartIgnoresNonBluetoothDevice() {
        let grab = BluetoothWarmupGrab()
        grab.start(for: makeDevice(uid: "usb-mic:input", transport: .usb))
        XCTAssertFalse(grab.isHoldingGrab,
                       "Only Bluetooth mics need the ownership grab")
    }

    func testStartFailsSafeWhenDeviceAbsent() {
        let grab = BluetoothWarmupGrab()
        grab.start(for: makeDevice(uid: "no-such-device:input", transport: .bluetooth))
        XCTAssertFalse(grab.isHoldingGrab,
                       "An unresolvable device must leave the capture ungrabbed, not crash")
    }

    func testStopWithoutStartIsSafe() {
        let grab = BluetoothWarmupGrab()
        grab.stop()
        XCTAssertFalse(grab.isHoldingGrab)
    }
}
