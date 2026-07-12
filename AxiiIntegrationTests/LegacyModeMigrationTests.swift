//
//  LegacyModeMigrationTests.swift
//  AxiiIntegrationTests
//
//  Upgrade path from the pre-mode-runtime app (v1.8.2 and earlier): the
//  first 2.0 launch creates the built-in mode JSONs, and every legacy
//  preference that maps onto them must carry over — custom hotkeys, mic
//  selections, pause-media, insertion-failure behavior, panel style.
//  Fresh installs (no legacy keys) must get untouched defaults.
//

import XCTest
@testable import Axii

@MainActor
final class LegacyModeMigrationTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        suiteName = "axii-migration-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    private func store(_ hotkey: HotkeyConfig, key: String) throws {
        defaults.set(try JSONEncoder().encode(hotkey), forKey: key)
    }

    // MARK: - Hotkeys

    func testCustomDictationHotkeyCarriesOver() throws {
        let custom = HotkeyConfig(keyCode: 3, modifiers: 256, usesFnKey: false)
        try store(custom, key: LegacyModeMigration.LegacyKey.dictationHotkey)

        let seeded = LegacyModeMigration.seeded(
            DefaultModes.dictation(), defaults: defaults
        )
        XCTAssertEqual(seeded.hotkey, custom)
    }

    func testCustomConversationAndMeetingHotkeysCarryOver() throws {
        let conv = HotkeyConfig(keyCode: 11, modifiers: 512, usesFnKey: false)
        let meet = HotkeyConfig(keyCode: 46, modifiers: 4_096, usesFnKey: true)
        try store(conv, key: LegacyModeMigration.LegacyKey.conversationHotkey)
        try store(meet, key: LegacyModeMigration.LegacyKey.meetingHotkey)

        XCTAssertEqual(
            LegacyModeMigration.seeded(
                DefaultModes.conversation(), defaults: defaults
            ).hotkey,
            conv
        )
        XCTAssertEqual(
            LegacyModeMigration.seeded(
                DefaultModes.meeting(), defaults: defaults
            ).hotkey,
            meet
        )
    }

    // MARK: - Microphones

    func testLegacyMicSelectionsMigrateToPerModeKeys() {
        defaults.set(
            "USB-Mic-UID", forKey: LegacyModeMigration.LegacyKey.dictationMic
        )
        defaults.set(
            "Meeting-Mic-UID", forKey: LegacyModeMigration.LegacyKey.meetingMic
        )

        _ = LegacyModeMigration.seeded(
            DefaultModes.dictation(), defaults: defaults
        )
        _ = LegacyModeMigration.seeded(
            DefaultModes.meeting(), defaults: defaults
        )

        XCTAssertEqual(
            defaults.string(
                forKey: "mode_\(DefaultModes.dictationId)_selectedMic"
            ),
            "USB-Mic-UID"
        )
        XCTAssertEqual(
            defaults.string(
                forKey: "mode_\(DefaultModes.meetingId)_selectedMic"
            ),
            "Meeting-Mic-UID"
        )
    }

    func testExistingPerModeMicKeyIsNeverOverwritten() {
        let modeKey = "mode_\(DefaultModes.dictationId)_selectedMic"
        defaults.set("Already-Chosen", forKey: modeKey)
        defaults.set(
            "Old-Legacy", forKey: LegacyModeMigration.LegacyKey.dictationMic
        )

        _ = LegacyModeMigration.seeded(
            DefaultModes.dictation(), defaults: defaults
        )
        XCTAssertEqual(defaults.string(forKey: modeKey), "Already-Chosen")
    }

    // MARK: - Behavior toggles

    func testPauseMediaOffCarriesOverDespiteNewDefaultOn() {
        defaults.set(false, forKey: LegacyModeMigration.LegacyKey.pauseMedia)
        let seeded = LegacyModeMigration.seeded(
            DefaultModes.dictation(), defaults: defaults
        )
        XCTAssertFalse(
            seeded.lifecycle.pauseMedia,
            "the 1.8.2 default (off) must not silently flip to on"
        )
    }

    func testInsertionFailureBehaviorCarriesOver() {
        defaults.set(
            InsertionFailureBehavior.copyFallback.rawValue,
            forKey: LegacyModeMigration.LegacyKey.insertionFailure
        )
        let seeded = LegacyModeMigration.seeded(
            DefaultModes.dictation(), defaults: defaults
        )
        let pasteConfigs = seeded.outputs.compactMap { output -> PasteConfig? in
            guard case .pasteAtCursor(let config) = output else { return nil }
            return config
        }
        XCTAssertEqual(pasteConfigs.first?.failureBehavior, .copyFallback)
    }

    func testMeetingAnimationAndPanelModeCarryOver() {
        defaults.set(
            "waveform", forKey: LegacyModeMigration.LegacyKey.meetingAnimation
        )
        defaults.set(
            "expanded", forKey: LegacyModeMigration.LegacyKey.meetingPanelMode
        )
        let seeded = LegacyModeMigration.seeded(
            DefaultModes.meeting(), defaults: defaults
        )
        XCTAssertEqual(
            seeded.panel.preferences.recordingIndicatorStyle, .waveform
        )
        XCTAssertFalse(seeded.panel.preferences.compactModeEnabled)
    }

    // MARK: - Fresh install

    func testFreshInstallGetsUntouchedDefaults() {
        for mode in [
            DefaultModes.dictation(), DefaultModes.conversation(),
            DefaultModes.meeting(),
        ] {
            let seeded = LegacyModeMigration.seeded(mode, defaults: defaults)
            XCTAssertEqual(seeded.hotkey, mode.hotkey)
            XCTAssertEqual(
                seeded.lifecycle.pauseMedia, mode.lifecycle.pauseMedia
            )
            XCTAssertNil(
                defaults.string(forKey: "mode_\(mode.id)_selectedMic")
            )
        }
    }

    // MARK: - Corrupt legacy data

    func testCorruptHotkeyDataFallsBackToDefault() {
        defaults.set(
            Data("not json".utf8),
            forKey: LegacyModeMigration.LegacyKey.dictationHotkey
        )
        let seeded = LegacyModeMigration.seeded(
            DefaultModes.dictation(), defaults: defaults
        )
        XCTAssertEqual(seeded.hotkey, DefaultModes.dictation().hotkey)
    }
}
