# Axii Development Guidelines

## Project Overview
Axii is a macOS menu bar app for quick voice-to-text dictation. It uses a floating panel that stays on top of all windows, triggered by a global hotkey.

## Architecture

```
Axii/
├── AxiiApp.swift             # App entry point, MenuBarView
├── Core/
│   ├── AppState.swift        # Pure observable state (@Observable)
│   └── AppController.swift   # Central orchestrator
├── Services/
│   └── HotkeyService.swift   # Centralized hotkey management
└── UI/
    ├── FloatingPanel.swift   # NSPanel window controller
    └── RecordingPanelView.swift  # SwiftUI panel content
```

### Key Components

- **AppState** - Pure state with @Observable, no business logic
- **AppController** - Coordinates services and state, handles actions
- **HotkeyService** - Registers/unregisters global hotkeys by ID
- **FloatingPanelController** - Manages NSPanel lifecycle

### Data Flow
```
User Action → AppController → Updates AppState → SwiftUI auto-updates
                ↓
         HotkeyService (register/unregister)
                ↓
         FloatingPanel (show/hide)
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
Current: **Control+Shift+Space** (defined in `AppController.HotkeyConfig`)

### Adding New Hotkeys
1. Add case to `HotkeyID` enum in `HotkeyService.swift`
2. Register in `AppController.setupHotkeys()`
3. Unregister when no longer needed

## Future Services (planned)
- `AudioService` - Microphone capture
- `TranscriptionService` - Speech-to-text
- `TextOutputService` - Clipboard/insertion
