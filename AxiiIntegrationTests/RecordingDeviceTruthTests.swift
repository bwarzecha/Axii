//
//  RecordingDeviceTruthTests.swift
//  AxiiIntegrationTests
//
//  A device fallback mid-recording must surface the mic that is ACTUALLY
//  capturing — the UI can never keep claiming the device the user picked
//  and lost. Events are injected directly (the AudioSession that produces
//  them needs real hardware).
//

import XCTest
@testable import Axii

@MainActor
final class RecordingDeviceTruthTests: XCTestCase {

    private func makeDevice(
        uid: String,
        transport: AudioDevice.TransportType = .usb
    ) -> AudioDevice {
        AudioDevice(id: 0, uid: uid, name: "Mic \(uid)", transportType: transport)
    }

    func testDeviceChangedEventUpdatesCurrentDeviceAndNotifies() {
        let helper = RecordingSessionHelper()
        var reported: [AudioDevice] = []
        helper.onDeviceChanged = { reported.append($0) }

        let fallback = makeDevice(uid: "built-in", transport: .builtIn)
        helper.handleEvent(.deviceChanged(to: fallback))

        XCTAssertEqual(helper.currentDevice?.uid, "built-in")
        XCTAssertEqual(reported.map(\.uid), ["built-in"],
                       "The UI must learn which mic is actually recording")
    }

    /// The existing warmup re-arm behavior must survive the new callback:
    /// falling back to a Bluetooth device re-enters waiting-for-signal.
    func testFallbackToBluetoothStillReArmsWarmup() {
        let helper = RecordingSessionHelper()
        var waiting: [Bool] = []
        helper.onSignalStateChanged = { waiting.append($0) }
        var reported: [AudioDevice] = []
        helper.onDeviceChanged = { reported.append($0) }

        let bluetooth = makeDevice(uid: "airpods", transport: .bluetooth)
        helper.handleEvent(.deviceChanged(to: bluetooth))

        XCTAssertEqual(reported.map(\.uid), ["airpods"])
        XCTAssertEqual(waiting, [true],
                       "A Bluetooth fallback re-enters the warmup state")
    }
}
