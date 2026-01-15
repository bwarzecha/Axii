# Dictaitor Development Guidelines

## Project Overview
Dictaitor is a macOS menu bar app for quick voice-to-text dictation. It uses a floating panel that stays on top of all windows, triggered by a global hotkey.

## Architecture
- **SwiftUI** for UI components
- **AppKit (NSPanel)** for floating window behavior
- **HotKey package** for global keyboard shortcuts
- **FluidAudio** (future) for speech-to-text

## Key Files
- `dictaitorApp.swift` - App entry point, AppState, hotkey registration
- `FloatingPanel.swift` - Non-activating floating panel
- `RecordingPanelView.swift` - SwiftUI panel content

## Build & Run
```bash
# Open in Xcode
open dictaitor.xcodeproj

# Build from command line
xcodebuild -project dictaitor.xcodeproj -scheme dictaitor -configuration Debug build
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
- [ ] Shift+Option+Space shows panel
- [ ] Panel stays on top when switching apps
- [ ] Same hotkey hides panel
- [ ] Escape key hides panel
- [ ] Panel can be dragged to reposition

## Code Style
- Max 300 lines per file
- Use `@MainActor` for UI-related classes
- Prefer `@Observable` (iOS 17+) or `@ObservableObject` for state
- No magic strings - use constants

## Hotkey
Current: **Shift + Option + Space**
- Modifier: `.shift` + `.option`
- Key: `.space`
