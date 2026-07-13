# Axii Development Guidelines

## Project Overview
Axii is a macOS menu bar app for quick voice-to-text dictation. It uses a floating panel that stays on top of all windows, triggered by a global hotkey.

## Architecture

```
Axii/
├── AxiiApp.swift             # App entry point, MenuBarView
├── Core/
│   ├── AppController.swift   # Central orchestrator, registers ModeFeatures
│   └── FeatureManager.swift  # Feature registry and hotkey routing
├── Features/
│   └── Mode/
│       ├── Config/           # Mode definitions (built-in + custom)
│       ├── Runtime/          # Active execution path (see below)
│       └── UI/               # Mode panel views
├── Models/                   # Data types (History, Meeting, ...)
├── Services/                 # Audio, Transcription, LLM, Pipeline,
│                             # History, Output, Permissions, Settings, ...
└── UI/                       # FloatingPanel, History, Settings views
```

`Features/Meeting` contains only the LIVE `MeetingAudioManager` and
`MeetingTranscriptManager` (used by `MeetingCaptureSession`); the legacy
per-feature classes that once lived beside them were removed.

### Key Runtime Components (Features/Mode/Runtime)

- **ModeFeature** - One instance per mode; owns panel lifecycle and hotkeys
- **ModeRuntimeState** - Pure observable state (@Observable)
- **SingleShot/MultiTurnModeTurnProcessor** - Post-capture turn execution
- **MeetingPipelineHandler** - Thin meeting coordinator delegating to:
  - **MeetingStartCoordinator** - permission checks and start flow
  - **MeetingCaptureSession** - active capture, chunk routing, autosave
  - **MeetingFinalizationService** - final transcription and segment assembly
  - **MeetingPersistenceService** - writes final meetings and audio

Meeting capture has hard concurrency/crash-safety invariants (epoch guards,
detach-before-await, commit-after-persist recovery artifacts) — read
`docs/meeting-reliability-model.md` before changing the meeting runtime.

### Data Flow
```
Hotkey → AppController/FeatureManager → ModeFeature → capture (AudioSession)
       → stop → TurnProcessor → TranscriptionService → pipeline → output
       → ModeRuntimeState updates → SwiftUI auto-updates
```

## Build & Run
```bash
# Open in Xcode
open Axii.xcodeproj

# Build from command line
xcodebuild -project Axii.xcodeproj -scheme Axii -configuration Debug build
```

## Development Workflow

The reliability bar for this app is: a meeting recorded with Axii survives
crashes, kills, mistaken discards, device switches, and long durations —
and the test tiers below PROVE it on every change. Regression testing is
not optional and not manual.

### After Each Change
1. **Real-UI E2E before every push — and FIRST when a change touches UI,
   capture, hotkeys, or the meeting runtime**:
   `xcodebuild test -project Axii.xcodeproj -scheme AxiiUITests -destination 'platform=macOS'`
   This is the ONLY mandatory local tier — everything else runs in CI.
   Drives the REAL app: synthetic hotkeys, real BlackHole audio, real
   Parakeet, history/artifact assertions. Machine prerequisites and the
   UI-driving rules live in `AxiiUITests/README.md` — read it before
   touching or running the suite. Requirements in one line: BlackHole 2ch
   installed, runner Accessibility granted, screen UNLOCKED, machine
   input-idle, no other xcodebuild running.
2. **Commit** with a descriptive message (format below) and push — every
   push runs the fast gate in CI (`.github/workflows/ci.yml`: unit +
   integration + in-suite fuzzers on a GitHub macOS runner) and a
   scheduled nightly runs the deep tiers
   (`.github/workflows/nightly-reliability.yml`: TSan + 10k-seed fuzzes).
   Watch the push's CI run to green before calling the change done.
   Run `Scripts/reliability-suite.sh --pr` locally only when iterating
   and CI round-trips are too slow.

### Commit Message Format
```
<type>: <short description>

<bullet points of changes>
```

Types: `feat`, `fix`, `refactor`, `docs`, `test`

## Code Style
- Max 300 lines per file
- Use `@MainActor` for UI-related classes
- Use `@Observable` for state (not ObservableObject)
- No magic strings - use constants/enums

## Hotkey Configuration
Hotkeys are per-mode, defined in each mode's `ModeConfig` (defaults in
`Features/Mode/Config/DefaultModes.swift`, user-editable in Settings).
Registration is handled by `HotkeyService`/`AdvancedHotkeyService` via
`FeatureManager` — modes do not register hotkeys directly.

## Core Services
- `Services/Audio/` - Microphone and system-audio capture (AudioSession)
- `TranscriptionService` - Speech-to-text (FluidAudio / Parakeet, actor)
- `DiarizationService` - Speaker separation for meetings
- `Services/Pipeline/` - Post-transcription processing steps
- `Services/Output/` - Paste/clipboard/notification outputs
- `Services/History/` - Persisted dictations, conversations, meetings

## Testing

Layered suites — each catches what the previous can't. The full map of
harness layers and invariants is in `docs/meeting-reliability-model.md`.

| Tier | What / catches | Where / command |
|---|---|---|
| Fast gate | unit + integration + 500-seed capture fuzz + 2×300-seed interaction fuzz | CI on every push/PR (`ci.yml`); locally: `Scripts/reliability-suite.sh --pr` |
| Real-UI E2E (pre-push; FIRST for UI/capture changes) | real app, real hotkeys, real audio, real ASR — 11 scenarios incl. kill -9 recovery (meeting AND dictation), dual-source attribution, Escape-discard recovery | LOCAL ONLY: `xcodebuild test -project Axii.xcodeproj -scheme AxiiUITests -destination 'platform=macOS'` |
| Nightly | TSan sweep + 10k-seed deep fuzzes (+ quirks/E2E only where hardware exists) | CI scheduled (`nightly-reliability.yml`); locally: `Scripts/reliability-suite.sh` |
| Release | deep fuzzes at 50k seeds | local before tagging: `Scripts/reliability-suite.sh --release` |
| Memory soak (opt-in) | 60-min meeting stop-time spike (budget 2 GB, measured 0.28 GB) | `TEST_RUNNER_AXII_SOAK=1 xcodebuild test … -only-testing:AxiiIntegrationTests/MeetingMemorySoakTests` |
| Real ASR (opt-in) | actual Parakeet models, hang detection | `TEST_RUNNER_AXII_REAL_ASR=1 … -only-testing:AxiiIntegrationTests/RealTranscriptionQuirkTests` |

Operational rules (violating these produces confusing failures, not errors):
- **One xcodebuild at a time** — runs share DerivedData and the test host.
- Plain `xcodebuild build` strips the .xctest plugins from Axii.app;
  after it, `test-without-building` fails — rerun `build-for-testing`.
- Env vars reach tests via the shell as `TEST_RUNNER_<NAME>=...` (never as
  xcodebuild arguments).
- A failing fuzz seed is a reproducible bug report — replay exactly one
  with `TEST_RUNNER_AXII_FUZZ_SEED_START=<seed> TEST_RUNNER_AXII_FUZZ_ITERATIONS=1`,
  and get a per-action state timeline with `TEST_RUNNER_AXII_FUZZ_TRACE_FILE=<path>`.
- E2E fixtures are real recordings with known transcripts
  (`AxiiUITests/Fixtures/`); assert ANCHOR WORDS, never exact text.
- Refactor phase briefs and the execution plan live in `docs/`
