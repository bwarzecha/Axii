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

`Features/Dictation` and `Features/Meeting` also contain LEGACY feature
classes that are not part of the active execution path (marked in their
headers); the meeting audio/transcript managers there are still used.

### Key Runtime Components (Features/Mode/Runtime)

- **ModeFeature** - One instance per mode; owns panel lifecycle and hotkeys
- **ModeRuntimeState** - Pure observable state (@Observable)
- **SingleShot/MultiTurnModeTurnProcessor** - Post-capture turn execution
- **MeetingPipelineHandler** - Thin meeting coordinator delegating to:
  - **MeetingStartCoordinator** - permission checks and start flow
  - **MeetingCaptureSession** - active capture, chunk routing, autosave
  - **MeetingFinalizationService** - final transcription and segment assembly
  - **MeetingPersistenceService** - writes final meetings and audio

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

### After Each Feature
1. **Test manually** - Run the app and verify the feature works
2. **Check for regressions** - Ensure existing features still work
3. **Commit** - Use descriptive commit messages

### Commit Message Format
```
<type>: <short description>

<bullet points of changes>
```

Types: `feat`, `fix`, `refactor`, `docs`, `test`

### Test Checklist (Floating Panel)
- [ ] Menu bar icon visible
- [ ] Control+Shift+Space shows panel
- [ ] Panel stays on top when switching apps
- [ ] Same hotkey hides panel
- [ ] Escape key hides panel
- [ ] Panel can be dragged to reposition

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
- `AxiiTests` - Unit tests; `AxiiIntegrationTests` - integration tests
- Run: `xcodebuild test -project Axii.xcodeproj -scheme Axii -destination 'platform=macOS'`
- Refactor phase briefs and the execution plan live in `docs/`
