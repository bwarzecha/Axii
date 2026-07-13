//
//  E2ESupport.swift
//  AxiiUITests
//
//  Shared drivers for the real-UI E2E suite: scratch app environment,
//  synthetic global hotkeys, virtual-device audio, and history assertions.
//
//  The suite runs against a REAL app instance with REAL audio and models —
//  it requires BlackHole 2ch installed and Accessibility granted to the
//  test runner. Tests self-skip with instructions when either is missing.
//

import AVFoundation
import AppKit
import Carbon.HIToolbox
import CoreAudio
import XCTest

// MARK: - Contract with the app

/// String constants mirrored from the app target (UI tests cannot import
/// it). Source of truth: AppLaunchOverrides.Key, DefaultModes,
/// HotkeyConfig.default, AccessibilityID.
enum E2EContract {
    static let bundleID = "com.warzechalabs.axii"
    static let historyDirKey = "AXII_HISTORY_DIR"
    static let modesDirKey = "AXII_MODES_DIR"
    static let recoveryDirKey = "AXII_RECOVERY_DIR"
    static let defaultsSuiteKey = "AXII_DEFAULTS_SUITE"
    /// Mirrors SimpleCaptureSpool.directoryName (E2E cannot import the app).
    static let dictationSpoolDirectory = "InProgressDictations"
    static let dictationModeID = "00000000-0000-0000-0000-000000000001"
    static let meetingModeID = "00000000-0000-0000-0000-000000000003"
    static let blackHoleUID = "BlackHole2ch_UID"
    /// Default dictation hotkey in a scratch environment: Control+Shift+Space.
    static let dictationKeyCode = CGKeyCode(kVK_Space)
    static let dictationFlags: CGEventFlags = [.maskControl, .maskShift]
    /// Default meeting hotkey in a scratch environment: Control+Option+M.
    static let meetingKeyCode = CGKeyCode(kVK_ANSI_M)
    static let meetingFlags: CGEventFlags = [.maskControl, .maskAlternate]
    static let panelPhaseID = "panel.phase"
    static let panelAudioLevelID = "panel.audioLevel"
    static let panelStopID = "panel.stop"
    static let panelActionID = "panel.action"
    static let panelCopyLiveID = "panel.copyLive"
    static let historyTrashToggleID = "history.trashToggle"
    static let historyRestoreID = "history.restore"
    static let panelMicPickerID = "panel.micPicker"
    static let panelCloseID = "panel.close"
}

// MARK: - Fixtures

/// Real recordings with known ground truth. Assert on ANCHOR words only —
/// exact transcripts do not survive the loopback + re-transcription.
struct Fixture {
    let filename: String
    let anchors: [String]
    let duration: TimeInterval

    static let testingOneTwoThree = Fixture(
        filename: "testing_one_two_three.wav",
        anchors: ["testing", "three", "four"],
        duration: 2.38
    )
    static let hopeItWorks = Fixture(
        filename: "hope_it_works.m4a",
        anchors: ["test", "hope"],
        duration: 3.92
    )

    var url: URL {
        let bundle = Bundle(for: E2ESession.self)
        let name = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        guard let url = bundle.url(forResource: name, withExtension: ext)
            ?? bundle.url(
                forResource: name, withExtension: ext, subdirectory: "Fixtures"
            )
        else { fatalError("fixture \(filename) missing from test bundle") }
        return url
    }
}

// MARK: - Scratch session

/// Isolated storage for one test: the app under test reads/writes ONLY
/// these directories, so a run can never touch real user data.
final class E2ESession {
    let root: URL
    let historyDir: URL
    let modesDir: URL
    let recoveryDir: URL
    /// Scratch UserDefaults suite for the app under test: suites are
    /// per-user domains shared across processes, so the runner seeds mic
    /// selections here and UI-driven writes (mic picker!) land here too —
    /// never in the real com.warzechalabs.axii plist.
    let defaultsSuite: String

    /// UI tests synthesize events; a locked/asleep display swallows them
    /// all and every scenario fails with confusing timeouts. Skip with the
    /// real reason instead (bitten by a 75-minute gate run ending after
    /// the display locked).
    static func skipIfScreenLocked() throws {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let locked = (session?["CGSSessionScreenIsLocked"] as? Int) == 1
        try XCTSkipIf(
            locked,
            "Screen is locked — UI event synthesis cannot reach the session"
        )
    }

    init() throws {
        let id = UUID().uuidString
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AxiiUITests-\(id)")
        historyDir = root.appendingPathComponent("history")
        modesDir = root.appendingPathComponent("modes")
        recoveryDir = root.appendingPathComponent("recovery")
        defaultsSuite = "com.warzechalabs.axii.e2e.\(id)"
        for dir in [historyDir, modesDir, recoveryDir] {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true
            )
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
        UserDefaults(suiteName: defaultsSuite)?
            .removePersistentDomain(forName: defaultsSuite)
    }

    /// Build the app pointed at scratch storage. The mic is seeded via
    /// LAUNCH ARGUMENTS (NSArgumentDomain — in-process to the launched app,
    /// reliable, no cross-process disk flush) which every UserDefaults
    /// instance consults first, INCLUDING the scratch suite the app routes
    /// through. WRITES still land in the isolated suite (via
    /// AXII_DEFAULTS_SUITE), so a UI-driven mic switch can never pollute
    /// real preferences. Pass micUID nil to leave selection unseeded
    /// (tests that drive the picker UI). A cross-process suite pre-write
    /// was tried and reverted: it hadn't flushed before the app read it,
    /// so capture fell back to the system-default mic and recorded silence.
    func makeApp(
        micUID: String? = E2EContract.blackHoleUID
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment[E2EContract.historyDirKey] = historyDir.path
        app.launchEnvironment[E2EContract.modesDirKey] = modesDir.path
        app.launchEnvironment[E2EContract.recoveryDirKey] = recoveryDir.path
        app.launchEnvironment[E2EContract.defaultsSuiteKey] = defaultsSuite
        app.launchArguments += ["-SUEnableAutomaticChecks", "NO"]
        if let micUID {
            app.launchArguments += [
                "-mode_\(E2EContract.dictationModeID)_selectedMic", micUID,
                "-mode_\(E2EContract.meetingModeID)_selectedMic", micUID,
            ]
        }
        return app
    }

    /// Click the panel's footer action button and verify the press TOOK
    /// (phase leaves idle); one retry covers a click eaten by transient
    /// focus/pointer contention.
    static func pressPanelStart(_ app: XCUIApplication) -> Bool {
        let action = app.descendants(matching: .any)
            .matching(identifier: E2EContract.panelActionID).firstMatch
        guard action.waitForExistence(timeout: 8) else { return false }
        for _ in 0..<2 {
            action.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
            ).click()
            if waitForPanelPhase(app, "recording", timeout: 20) { return true }
        }
        return false
    }

    /// A second instance of the same bundle id must not be running: it owns
    /// the global hotkeys and the shared recovery paths.
    static func terminateOtherAxiiInstances() {
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: E2EContract.bundleID
        )
        for app in running {
            app.terminate()
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let alive = NSRunningApplication.runningApplications(
                withBundleIdentifier: E2EContract.bundleID
            )
            if alive.isEmpty { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        NSRunningApplication.runningApplications(
            withBundleIdentifier: E2EContract.bundleID
        ).forEach { $0.forceTerminate() }
    }

    /// Open the History window via the status-item menu, with retries.
    /// Uses COORDINATE clicks on the status item: a plain .click() installs
    /// an internal "menu open notification" expectation that flakes on
    /// menu-bar items (stale AX frames until the mouse moves).
    static func openHistoryWindow(_ app: XCUIApplication) -> Bool {
        let statusItem = app.statusItems.firstMatch
        guard statusItem.waitForExistence(timeout: 15) else { return false }
        for _ in 0..<3 {
            statusItem.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
            ).click()
            let historyItem = app.menuItems["History"].firstMatch
            if historyItem.waitForExistence(timeout: 4) {
                // Select by KEYBOARD type-ahead: clicking the item would
                // move the cursor to its reported AX frame, which can be
                // stale/offscreen for menu-bar menus — the cursor move
                // dismisses the menu.
                app.typeText("History")
                app.typeKey(.return, modifierFlags: [])
                if app.windows.firstMatch.waitForExistence(timeout: 8) {
                    return true
                }
            }
            app.typeKey(.escape, modifierFlags: [])
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        return false
    }

    /// Wait until the panel's phase element reports the given value
    /// (accessibilityValue mirrors ModePhase via String(describing:)).
    static func waitForPanelPhase(
        _ app: XCUIApplication, _ phase: String, timeout: TimeInterval
    ) -> Bool {
        let element = app.descendants(matching: .any)
            .matching(identifier: E2EContract.panelPhaseID).firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists,
               let value = element.value as? String,
               value.hasPrefix(phase) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return false
    }

    // MARK: History assertions

    func historyEntryCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: historyDir.path))?
            .filter { !$0.hasPrefix(".") }.count ?? 0
    }

    /// Wait until the history gains an entry beyond `count`; newest entry URL.
    func waitForNewHistoryEntry(
        beyond count: Int, timeout: TimeInterval
    ) -> URL? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if historyEntryCount() > count { return newestEntry() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return nil
    }

    func newestEntry() -> URL? {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: historyDir, includingPropertiesForKeys: nil
        ))?.filter { !$0.lastPathComponent.hasPrefix(".") }
        return entries?.sorted { $0.lastPathComponent < $1.lastPathComponent }.last
    }

    /// Seed a DISCARDED meeting into the scratch history (schema mirrors
    /// HistoryService's on-disk format). Returns the entry directory.
    @discardableResult
    func seedDiscardedMeeting(
        id: String = UUID().uuidString,
        text: String = "Restore me please this is a seeded segment"
    ) throws -> URL {
        let formatter = ISO8601DateFormatter()
        let now = formatter.string(from: Date())
        // Directory format: 2026-02-14T140022_meeting_<8hex> — date keeps
        // dashes, time drops colons and the Z.
        let parts = now.split(separator: "T", maxSplits: 1)
        let time = parts[1]
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "Z", with: "")
        let stamp = "\(parts[0])T\(time)"
        let suffix = id.prefix(8).lowercased()
        let dir = historyDir.appendingPathComponent(
            "\(stamp)_meeting_\(suffix)"
        )
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let segment: [String: Any] = [
            "id": UUID().uuidString, "text": text, "speakerId": "You",
            "isFromMicrophone": true, "startTime": 0, "endTime": 3,
        ]
        let meeting: [String: Any] = [
            "id": id, "createdAt": now, "duration": 3.0,
            "segments": [segment], "discardedAt": now,
        ]
        let interaction: [String: Any] = ["type": "meeting", "data": meeting]
        let metadata: [String: Any] = [
            "id": id, "type": "meeting", "createdAt": now, "updatedAt": now,
            "preview": "You: \(text)",
            "details": [
                "type": "meeting",
                "data": [
                    "duration": 3.0, "segmentCount": 1, "wordCount": 8,
                    "hasMicAudio": false, "hasSystemAudio": false,
                    "discardedAt": now,
                ] as [String: Any],
            ] as [String: Any],
        ]
        try JSONSerialization.data(
            withJSONObject: interaction, options: [.sortedKeys]
        ).write(to: dir.appendingPathComponent("interaction.json"))
        try JSONSerialization.data(
            withJSONObject: metadata, options: [.sortedKeys]
        ).write(to: dir.appendingPathComponent("metadata.json"))
        return dir
    }

    func metadata(of entry: URL) -> [String: Any]? {
        guard let data = try? Data(
            contentsOf: entry.appendingPathComponent("metadata.json")
        ) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Decode the entry's stored audio: (rms, duration). The duration check
    /// is the machine-catch for channel-layout corruption (doubling).
    func storedAudioStats(of entry: URL) throws -> (rms: Float, duration: Double) {
        let audioDir = entry.appendingPathComponent("audio")
        guard let file = try FileManager.default
            .contentsOfDirectory(at: audioDir, includingPropertiesForKeys: nil)
            .first(where: { !$0.lastPathComponent.hasPrefix(".") })
        else { throw E2EError.noAudioFile }
        let audio = try AVAudioFile(forReading: file)
        let frames = AVAudioFrameCount(audio.length)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: audio.processingFormat, frameCapacity: frames
        ) else { throw E2EError.decodeFailed }
        try audio.read(into: buffer)
        guard let channel = buffer.floatChannelData else {
            throw E2EError.decodeFailed
        }
        let samples = UnsafeBufferPointer(
            start: channel[0], count: Int(buffer.frameLength)
        )
        let sumOfSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        let rms = samples.isEmpty
            ? 0 : (sumOfSquares / Float(samples.count)).squareRoot()
        let duration = Double(audio.length)
            / audio.processingFormat.sampleRate
        return (rms, duration)
    }
}

enum E2EError: Error {
    case noAudioFile
    case decodeFailed
    case playbackFailed(String)
}

// MARK: - Hotkey driver

enum HotkeyDriver {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Ask TCC to surface the runner in System Settings > Accessibility
    /// (added unchecked on first call) so the one-time grant targets the
    /// right identity. The grant is keyed to the runner's code signature —
    /// team-signed, so it survives rebuilds.
    @discardableResult
    static func requestTrustPrompt() -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Post a modifier+key press to the HID tap — reaches the WindowServer
    /// Carbon hotkey matcher regardless of app focus. Never use F-keys:
    /// hardware F-keys carry an implicit Fn flag and the match is exact.
    static func press(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(
                keyboardEventSource: source, virtualKey: keyCode, keyDown: down
            ) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
            usleep(60_000)
        }
    }
}

// MARK: - Audio driver

enum AudioDriver {
    /// CoreAudio device lookup by UID — no capture permission needed.
    static func deviceExists(uid: String) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return false }
        var deviceIDs = [AudioDeviceID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            &size, &deviceIDs
        ) == noErr else { return false }
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        for deviceID in deviceIDs {
            var deviceUID: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            let status = withUnsafeMutablePointer(to: &deviceUID) { pointer in
                AudioObjectGetPropertyData(
                    deviceID, &uidAddress, 0, nil, &uidSize, pointer
                )
            }
            if status == noErr, deviceUID as String == uid { return true }
        }
        return false
    }

    /// Play a file AUDIBLY through the default output — for fixtures whose
    /// only allowed path into the app is ScreenCaptureKit (playing them
    /// into BlackHole would loop them into the mic track).
    static func playToDefaultOutput(_ url: URL) throws {
        try run(AVPlayer(playerItem: AVPlayerItem(url: url)), url: url)
    }

    /// Play a file to a specific output device by UID and block until done.
    /// A missing device fails loudly on item.error (never falls back to the
    /// system default output).
    static func play(_ url: URL, toDeviceUID uid: String) throws {
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.audioOutputDeviceUniqueID = uid
        try run(player, url: url)
    }

    private static func run(_ player: AVPlayer, url: URL) throws {
        guard let item = player.currentItem else {
            throw E2EError.playbackFailed("no player item")
        }
        let duration = CMTimeGetSeconds(AVURLAsset(url: url).duration)
        player.play()
        let deadline = Date().addingTimeInterval(duration + 5)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            if let error = item.error {
                throw E2EError.playbackFailed(error.localizedDescription)
            }
            if CMTimeGetSeconds(player.currentTime()) >= duration - 0.05 {
                return
            }
        }
        throw E2EError.playbackFailed("playback timed out")
    }
}
