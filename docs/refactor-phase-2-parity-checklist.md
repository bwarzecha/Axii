# Phase 2 Built-In Mode Parity Checklist

This documents parity spot checks for the three built-in modes under the
mode runtime after removing legacy feature construction from AppController.

## Context

Before Phase 2, `AppController` constructed both legacy feature instances
(`DictationFeature`, `ConversationFeature`, `MeetingFeature`) and mode
runtime instances (`ModeFeature` via `ModeService`). Only the mode runtime
path was active (`useModeSystem = true`), so removing the legacy
construction has no intended user-visible behavior impact.

The checks below confirm that the mode runtime handles each built-in mode
correctly.

## Method

- Code-level verification: traced the registration path from
  `registerFeatures()` through `makeModeFeature(from:)` to confirm the
  same dependency set is injected as before Phase 2
- Reviewed `DefaultModes.swift` to confirm built-in mode configs are
  unchanged
- Reviewed existing Phase 0/1 test coverage for each behavior area
- Manual run of the app after the Phase 2 changes (see Manual Spot Checks below)

## Dictation (DefaultModes.dictation)

| Behavior | Status | Evidence |
|----------|--------|----------|
| Hotkey starts/stops recording | OK | ModeFeature registers hotkey from ModeConfig.hotkey; same HotkeyService path as before |
| Panel shows during recording | OK | FeatureManager.activateFeature shows panel; unchanged |
| Transcription produces output | OK | ModeFeatureRecording uses TranscriptionService; Phase 0 dictation orchestration tests cover success/error/empty paths |
| Paste/clipboard output works | OK | OutputHandler uses PasteService; Phase 0 integration tests cover pasted/copied/fallback outcomes |
| History save works | OK | OutputHandler saves via HistoryService; Phase 0 integration tests cover transcription history round-trips |
| No user-visible behavior change from Phase 2 | OK | `useModeSystem` was already `true` — legacy DictationFeature was constructed but never registered in the active path |

## Conversation (DefaultModes.conversation)

| Behavior | Status | Evidence |
|----------|--------|----------|
| Hotkey starts/stops recording | OK | Same hotkey registration path as dictation |
| Panel shows conversation session | OK | ModeFeature provides ConversationHandler-driven panel content |
| Transcription + LLM processing | OK | PipelineRunner handles LLM transform steps; OutputHandler delivers results |
| Multi-turn conversation state | OK | ConversationHandler manages session history within ModeFeature |
| History save works | OK | Phase 0 integration tests cover conversation history round-trips |
| No user-visible behavior change from Phase 2 | OK | Legacy ConversationFeature was constructed but never registered in the active path |

## Meeting (DefaultModes.meeting)

| Behavior | Status | Evidence |
|----------|--------|----------|
| Hotkey starts/stops meeting capture | OK | ModeFeature registers meeting hotkey; MeetingPipelineHandler manages capture |
| Dual audio capture (mic + system) | OK | `screenPermission` injected when `config.audioCapture.isDual`; same conditional as before |
| Diarization service injected | OK | `diarizationService` injected when `config.audioCapture.isDual`; same conditional as before |
| Save to history with audio recordings | OK | Phase 1 fix ensures micRecording and systemRecording are attached; Phase 1 regression tests verify |
| Panel shows meeting transcript | OK | MeetingPipelineHandler drives MeetingTranscriptManager for live display |
| No user-visible behavior change from Phase 2 | OK | Legacy MeetingFeature was constructed but never registered in the active path |

## Construction Parity

The `makeModeFeature(from:)` helper injects exactly the same dependency
set as the previous inline construction in both `registerFeatures()` and
`registerNewMode(_:)`:

- `transcriptionService`
- `micPermission`
- `screenPermission` (conditional on `isDual`)
- `pasteService`
- `clipboardService`
- `settings`
- `historyService`
- `mediaControlService`
- `llmService`
- `playbackService`
- `diarizationService` (conditional on `isDual`)

Verified by diffing the old inline construction against `makeModeFeature`.

## Custom Mode Registration Parity

`registerNewMode(_:)` now calls `makeModeFeature(from:)` — the same
helper used by startup registration. Before Phase 2, both paths had
duplicated identical construction code. The consolidation is
behavior-preserving.

## Manual Spot Checks

Performed after the Phase 2 changes on the development machine.

### Dictation
- Launched app; menu bar icon appeared, status showed "Ready"
- Triggered built-in dictation hotkey; panel appeared, recording started
- Spoke test phrase; recording stopped, transcription produced output
- Confirmed output was pasted to the focused text field
- Confirmed history entry appeared with correct transcription text

### Conversation
- Triggered conversation hotkey; panel appeared with conversation session
- Spoke test input; transcription completed, LLM response displayed in panel
- Confirmed multi-turn session state persisted across turns
- Confirmed history entry saved after session

### Meeting
- Triggered meeting hotkey; panel appeared with live transcript view
- Confirmed dual audio capture started (mic + system)
- Stopped meeting; confirmed save-to-history completed
- Confirmed saved meeting had attached mic and system audio recordings

## User-Visible Mismatches Found

None. No intended user-visible behavior change was observed.

## Non-User-Visible Side Effects

Removing legacy feature construction also removes init-time side effects
from the old feature objects. Specifically, `DictationFeature` and
`MeetingFeature` each created a `DeviceMonitor` (via `AudioSession`) in
their initializers, which registered a CoreAudio listener for audio
device changes. These listeners were inactive — they served the legacy
runtime which was not part of the active registration path.

This is acceptable and preferable: the mode runtime creates its own
`AudioSession` (and therefore its own `DeviceMonitor`) when a recording
actually starts. The removed listeners were redundant startup overhead
with no user-visible effect.

## Remaining Risk

The primary risk would be if any code path outside `AppController` was
accessing the legacy feature properties (`controller.dictationFeature`,
etc.). A codebase search confirmed no such references exist outside of
`AppController.swift` itself.
