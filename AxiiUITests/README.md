# AxiiUITests — real-UI end-to-end suite

Drives the REAL app: synthetic global hotkeys, real audio through a virtual
device, real Parakeet transcription, assertions on history data, panel
accessibility values, and stored-audio artifacts. Every test runs against
scratch storage (env overrides + NSArgumentDomain launch arguments) — a run
can never touch real user data, including crash-recovery artifacts.

## Run

```bash
xcodebuild test -project Axii.xcodeproj -scheme AxiiUITests \
  -destination 'platform=macOS'
```

Also runs as the E2E tier of `Scripts/reliability-suite.sh` (non-PR tiers).

## One-time machine setup

Tests that need a prerequisite SELF-SKIP with instructions; nothing fails
on a fresh machine.

1. **BlackHole 2ch** (virtual audio device the fixtures play through):
   `brew install --cask blackhole-2ch && sudo killall coreaudiod`
2. **Accessibility for the test runner** (synthetic hotkeys are CGEvents;
   the runner is spawned by testmanagerd, so it never auto-appears in the
   TCC pane): System Settings > Privacy & Security > Accessibility > "+" >
   add `DerivedData/.../Build/Products/Debug/AxiiUITests-Runner.app`.
   The grant keys to the code signature and survives rebuilds.
3. The app under test inherits the already-granted Microphone /
   Screen Recording / Accessibility permissions of the dev-signed Axii.

No other instance of Axii may be running (the suite terminates strays —
an Xcode-attached instance survives kill and must be stopped in Xcode).

**One xcodebuild consumer at a time.** Never run this suite while another
xcodebuild test run (or reliability-suite.sh) is active: they share
DerivedData and the Axii test host, and killing/rebuilding one corrupts
the other. The machine must also be input-idle — user mouse/keyboard
activity fights the synthetic pointer and is the #1 flake source.

The dual-source test plays one fixture AUDIBLY through the default
output (its only legal path into the app is ScreenCaptureKit).

## UI-driving rules (learned from real failures — keep following them)

- Click status items by COORDINATE (`coordinate(...).click()`); a plain
  `.click()` waits on a menu-open notification that flakes.
- Select menu items by KEYBOARD TYPE-AHEAD (`typeText` + return): menu-item
  AX frames can be stale/offscreen, and XCUITest moving the cursor to a
  bogus frame dismisses the menu.
- Waits are EXISTENCE-based, never `isHittable` (lies inside
  non-activating panels).
- Never use F-keys for synthetic hotkeys (implicit Fn modifier flag —
  Carbon matches exactly, the event never fires).
- Wait for `panel.phase == recording` before playing fixture audio:
  BlackHole drops audio played while no one captures.
- Assert transcripts on ANCHOR WORDS, never exact text.

## Fixtures

`Fixtures/` holds privacy-screened real recordings whose original
transcripts are the ground truth (see `Fixture` in E2ESupport.swift).
