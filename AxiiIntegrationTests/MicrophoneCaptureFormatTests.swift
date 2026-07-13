//
//  MicrophoneCaptureFormatTests.swift
//  AxiiIntegrationTests
//
//  Regression pin for the capture delivery format. Unpinned,
//  AVCaptureAudioDataOutput delivers whatever the environment negotiates —
//  an arm-time race against coreaudiod client teardown was observed to
//  yield a misconverted stream that turned entire recordings into
//  constant-power noise. These settings are load-bearing; changing them
//  must be a deliberate act.
//

import AVFoundation
import XCTest
@testable import Axii

final class MicrophoneCaptureFormatTests: XCTestCase {

    func testDeliveryFormatIsPinnedToFloat32InterleavedLPCM() {
        let settings = MicrophoneCapture.pinnedOutputSettings

        XCTAssertEqual(
            settings[AVFormatIDKey] as? UInt32, kAudioFormatLinearPCM
        )
        XCTAssertEqual(settings[AVLinearPCMBitDepthKey] as? Int, 32)
        XCTAssertEqual(settings[AVLinearPCMIsFloatKey] as? Bool, true)
        XCTAssertEqual(settings[AVLinearPCMIsNonInterleaved] as? Bool, false)
        XCTAssertEqual(settings[AVLinearPCMIsBigEndianKey] as? Bool, false)
    }
}
