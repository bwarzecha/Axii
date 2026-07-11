# POC: Real-UI End-to-End Testing (2026-07-11)

**Goal:** prove every link of an automated E2E chain for Axii — synthetic
global hotkey → real app → real audio through a virtual device → real
Parakeet → history assertion — before designing the actual suite.

**Verdict: every link works.** Full chain validated on macOS 26.5.1:
`e2e_dictation_v2.sh` fires ⌥Space via CGEventPost, a fresh Axii instance
captures a real fixture recording played into BlackHole 2ch, and the exact
expected transcript lands in history. **PASS.**

## Results per link

| Link | Result | Key facts |
|---|---|---|
| Carbon hotkey via CGEventPost | PASS | `.cghidEventTap`, flags on the key event (Maccy pattern). Works even AD-HOC signed. ⚠️ F-keys carry an implicit Fn flag — synthetic F13 never matches; use plain keys. |
| Accessibility (TCC) | PASS | Grant attaches to the RESPONSIBLE process — for this harness the **claude CLI app bundle**, not the Claude desktop app. `AXIsProcessTrustedWithOptions(prompt)` reveals the right identity. |
| BlackHole loopback | PASS | Play side: `AVPlayer.audioOutputDeviceUniqueID = "BlackHole2ch_UID"` — system default untouched; missing device fails loudly on `item.error`. Capture: 48 kHz **planar stereo** float32. |
| Mic pre-seeding | PASS | `defaults write com.warzechalabs.axii mode_<uuid>_selectedMic BlackHole2ch_UID` **before app launch** (running app's device list may be stale; restart semantics are the suite's default anyway). |
| Real ASR on looped audio | PASS | Real human fixture → near-exact transcript. `say`-voice → ~85% (assert 2–3 anchor phrases, never exact match). |
| History assertion | PASS | Poll `~/Library/Application Support/Axii/history` entry count, then read newest `metadata.json` preview. |

## Bug found and fixed (the POC paying for itself)

`MicrophoneCapture.captureOutput` assumed mono float32; BlackHole delivers
2-channel planar, so each buffer's content was emitted twice back-to-back —
garbled transcription, spiky level display. Real-world impact: any stereo
USB audio interface used as a mic. Fixed via shared `AudioSampleExtraction`
(format + channel-layout aware, used by MicrophoneCapture AND
SystemAudioCapture) + `AxiiTests/AudioSampleExtractionTests`.

## Gotchas for the real suite

- Xcode-launched Axii holds SIGTERM under lldb — the harness must refuse to
  run against a debugger-attached instance (`kill -TERM` + timeout + fail).
- `defaults` writes land only reliably when the app launches AFTER them.
- The mode's mic-selection key gets cleared by device reconciliation if the
  selected device vanishes — save/restore around every run.
- BlackHole install: `brew install --cask blackhole-2ch && sudo killall
  coreaudiod` (no reboot needed). Device UID is the stable constant
  `BlackHole2ch_UID`.
- Paste-at-cursor output means the harness must park focus (TextEdit
  scratch doc) before firing.
- Fixtures: real recordings from history (screened for privacy) in
  `fixtures/`. Ground truth = their original stored transcripts.

## Assets

- `hotkey_listener/poster.swift` — Carbon-hotkey synthesis probe pair
- `fire_hotkey.swift` — parameterized hotkey firing (keycode + modifiers)
- `play_to_device.swift` — UID-pinned playback (AVPlayer)
- `record_from_device.swift` — UID-pinned capture + peak/RMS report
- `e2e_dictation_v2.sh` — the full-chain driver (restart + seed + assert)
- `fixtures/` — 3 privacy-screened real recordings with known transcripts
- `AxiiIntegrationTests/POCTranscribeWavTests.swift` — transcribe any WAV
  via `AXII_POC_WAV` (kept: useful for suite assertions)

## Decision

Skip XCUITest for the core chain — the script harness is simpler, faster,
and already proven. Reserve XCUITest/AX for panel-button coverage later
(needs `.accessibilityIdentifier` + `.accessibilityAction` instrumentation).
Next: productize this harness as an opt-in E2E tier in
`Scripts/reliability-suite.sh` with scenarios: dictation happy path,
Escape-cancel → Recently Deleted, meeting mic-only happy path, kill -9
mid-meeting → crash recovery, device switch mid-capture.
