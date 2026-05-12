# Phase 4B Contractor Brief

This document is the authoritative contractor brief for Phase 4B.

If this document conflicts with older roadmap wording, follow this document and
[docs/refactor-execution-plan.md](/Users/bartosz/dev/Axii/docs/refactor-execution-plan.md).

## Phase Name

Phase 4B: Extract The Meeting Finalization Service

## Starting Point

Start only after Phase 4A is merged to `main`.

Current expected base commit at the time this brief was written:

- `88ca5ce test: exercise real meeting stop adapter path`

Branching:

- branch from current `main`
- branch name: `refactor/phase-4b`
- review the branch directly
- keep commits separated by workstream
- do not include Phase 4C start/capture work in this branch

## Purpose

Reduce `MeetingPipelineHandler.stop(saveToHistory:)` and
`MeetingTranscriptManager` complexity by extracting final meeting transcription
and segment assembly into a dedicated service.

Phase 4A moved persisted meeting/audio writes out of the runtime adapter.
Phase 4B should now move final full-track transcription, final source-labelled
segment creation, final sort/merge, and progress reporting out of the active
handler/transcript-manager hotspot.

This is still not the capture split. Keep the live recording hot path stable.

## Current Code Reality

These are the exact Phase 4B starting points:

- [MeetingPipelineHandler.swift](/Users/bartosz/dev/Axii/Axii/Features/Mode/Runtime/MeetingPipelineHandler.swift)
  - owns start/permission checks
  - owns active `MeetingAudioManager` and `MeetingTranscriptManager`
  - owns stop coordination
  - cancels pending chunk transcription tasks
  - stops audio capture
  - reads original-quality temp audio files
  - calls `MeetingTranscriptManager.transcribeFullAudio(...)`
  - clears autosave and temp files
  - returns `MeetingPersistencePayload`
- [MeetingTranscriptManager.swift](/Users/bartosz/dev/Axii/Axii/Features/Meeting/MeetingTranscriptManager.swift)
  - owns autosave and crash recovery
  - owns real-time chunk transcription
  - owns final full-track transcription
  - owns final resampling, 30-second chunking, silence skipping, source labels,
    segment sorting, and consecutive-speaker merge
- [MeetingPersistenceService.swift](/Users/bartosz/dev/Axii/Axii/Features/Mode/Runtime/MeetingPersistenceService.swift)
  - already owns final history and audio persistence from Phase 4A
- [MeetingSaveRegressionTests.swift](/Users/bartosz/dev/Axii/AxiiIntegrationTests/MeetingSaveRegressionTests.swift)
  - now exercises the real `ModeFeature.stopMeeting(saveToHistory:)` adapter
    path through `MeetingPipelineHandling`
- [MeetingPersistenceServiceTests.swift](/Users/bartosz/dev/Axii/AxiiIntegrationTests/MeetingPersistenceServiceTests.swift)
  - owns the persistence behavior matrix

Important codebase observations:

- `DiarizationService` is injected into meeting runtime, but the current final
  meeting path does not use speaker-model diarization.
- Current final meeting behavior uses source labels:
  - microphone: `speakerId == "You"`, `isFromMicrophone == true`
  - system audio: `speakerId == "Remote"`, `isFromMicrophone == false`
- Current final transcription resamples both tracks to 16 kHz before calling
  `TranscriptionProviding.transcribe(...)`.
- Current final transcription chunks each track into 30-second chunks.
- Current final transcription skips silent chunks where max amplitude is below
  `0.001`.
- Current final transcription catches per-chunk transcription failures and
  continues finalization.
- Current finalization sorts by `startTime` and merges consecutive segments
  with the same `speakerId`.

## Goals

- introduce a dedicated meeting finalization service
- make finalization input/output contracts explicit
- move final full-track transcription out of `MeetingTranscriptManager`
- keep `MeetingPipelineHandler` as the stop/capture coordinator for now
- preserve current outward stop/save behavior
- add service-level tests for finalization behavior
- keep Phase 4A persistence tests passing unchanged

## Tenets

1. Extract finalization, not capture.
   This phase should not redesign permissions, start flow, app switching, audio
   session ownership, or chunk routing.

2. Keep autosave ownership stable.
   `MeetingTranscriptManager` should still own autosave and crash recovery in
   this phase.

3. Keep cleanup ownership stable.
   `MeetingPipelineHandler.stop(...)` should still own pending task
   cancellation, `audio.stop()`, temp-file cleanup, and successful autosave
   clearing in this phase.

4. Preserve final transcript semantics exactly.
   Source labels, 16 kHz transcription input, 30-second chunks, silence
   skipping, per-chunk error tolerance, sort order, merge behavior, duration,
   app name, mic/system samples, and sample rates must remain stable.

5. Keep tests layered.
   Finalization logic belongs in `MeetingFinalizeServiceTests`. Adapter tests
   should remain thin.

## Non-Goals

Do not:

- split permission/start flow yet
- split live capture/session ownership yet
- redesign `MeetingAudioManager`
- redesign autosave or crash recovery
- move autosave persistence to the new finalization service
- move temp-file cleanup to the new finalization service
- change meeting/history schemas
- change Phase 4A persistence behavior
- add speaker-profile enrichment
- enable new speaker-model diarization behavior
- do Phase 4C work

## Recommended Design

### 1. Introduce finalization boundary types

Preferred new file:

- `Axii/Features/Mode/Runtime/MeetingFinalizationService.swift`

Acceptable split:

- `MeetingFinalizationInput.swift`
- `MeetingFinalizationService.swift`

Suggested input type:

```swift
struct MeetingFinalizationInput {
    let micSamples: [Float]
    let micSampleRate: Double
    let systemSamples: [Float]
    let systemSampleRate: Double
    let duration: TimeInterval
    let appName: String?
}
```

Suggested service API:

```swift
@MainActor
final class MeetingFinalizationService {
    var onProgressUpdated: ((Double, String) -> Void)?

    init(transcriptionService: any TranscriptionProviding)

    func finalize(
        input: MeetingFinalizationInput
    ) async -> MeetingPersistencePayload
}
```

The service may return a dedicated `MeetingFinalizationResult` if that keeps the
code clearer, but the handler must still ultimately produce
`MeetingPersistencePayload` for persistence.

### 2. Move final transcription behavior out of `MeetingTranscriptManager`

Move these responsibilities into the new service:

- final resampling to 16 kHz
- 30-second full-track chunking
- silent chunk skipping
- per-chunk transcription calls
- source-labelled `MeetingSegment` creation
- final progress updates
- final sort and consecutive-speaker merge

After Phase 4B, `MeetingTranscriptManager` should still own:

- real-time chunk transcription
- real-time segment updates
- autosave timer and file IO
- crash recovery read/clear behavior
- selected app name used by autosave

### 3. Rewire `MeetingPipelineHandler.stop(...)`

`MeetingPipelineHandler.stop(saveToHistory:)` should remain the coordinator:

1. invalidate duration timer
2. stop autosave timer
3. cancel pending real-time chunk tasks
4. stop `MeetingAudioManager`
5. preserve `state.duration`
6. if saving:
   - set `state.phase = .processing`
   - await cancelled chunk tasks
   - read original-quality mic/system samples from temp files
   - call `MeetingFinalizationService.finalize(...)`
   - clear autosave after successful finalization
   - clean temp files
   - return the final `MeetingPersistencePayload`
7. if not saving:
   - clean temp files
   - return `nil`

Do not move audio stop/read/cleanup into the finalization service.

### 4. Preserve progress behavior

Current progress text is user-visible enough to preserve unless there is a
documented reason to change it:

- `Transcribing your audio...`
- `Transcribing remote audio...`
- `Merging transcript...`
- `Done`

The service can expose `onProgressUpdated`, and the handler can wire that to
`ModeRuntimeState.processingProgress` and `processingStatus`.

### 5. Keep `DiarizationService` behavior stable

Do not introduce new speaker-model diarization in Phase 4B.

If `DiarizationService` remains unused by final meeting finalization, leave that
alone and call it out in the report. This branch is about extracting current
behavior, not changing speaker attribution quality.

## Required Workstreams

### Workstream A: Freeze Finalization Behavior With Service Tests

Add a service-focused test suite, for example:

- `AxiiIntegrationTests/MeetingFinalizeServiceTests.swift`

Required coverage:

- mic-only finalization produces source-labelled `You` segments
- system-only finalization produces source-labelled `Remote` segments
- both-track finalization preserves source labels and track attribution
- empty audio returns a payload with no segments but preserves duration, app
  name, samples, and sample rates
- non-16 kHz input is resampled before transcription
- 16 kHz input is passed through without changing the transcription sample rate
- 30-second chunking is preserved
- silent chunks are skipped
- per-chunk transcription failure does not fail the entire finalization
- consecutive same-speaker final segments are merged after sorting
- progress callbacks reach the expected terminal state

Use fake `TranscriptionProviding` implementations. Do not require real audio
hardware or real transcription models.

### Workstream B: Extract `MeetingFinalizationService`

Required changes:

1. Introduce the service and input contract.
2. Move final full-track transcription behavior into the service.
3. Keep service dependencies narrow.
4. Do not inject `SettingsService`, `HistoryService`, or `MeetingAudioManager`.
5. Do not swallow whole-finalization failures unless current behavior already
   does. Current per-chunk transcription failures are best-effort and should
   remain best-effort.

Expected dependencies:

- `TranscriptionProviding`
- optionally a small local helper for segment merge

Avoid broad protocolization unless a narrow test seam is necessary.

### Workstream C: Rewire `MeetingPipelineHandler`

Required changes:

1. Add a finalization collaborator to `MeetingPipelineHandler`.
2. Wire progress updates from finalization into `ModeRuntimeState`.
3. Replace the direct call to
   `MeetingTranscriptManager.transcribeFullAudio(...)`.
4. Keep `MeetingPipelineHandler` as the owner of stop coordination.

Preferred constructor shape:

```swift
init(
    state: ModeRuntimeState,
    transcriptionService: any TranscriptionProviding,
    diarizationService: DiarizationService?,
    screenPermission: ScreenRecordingPermissionService,
    micPermission: MicrophonePermissionService,
    settings: SettingsService,
    finalizationService: MeetingFinalizationService? = nil
)
```

If a protocol is introduced for testing, keep it narrow, for example:

```swift
@MainActor
protocol MeetingFinalizing {
    var onProgressUpdated: ((Double, String) -> Void)? { get set }
    func finalize(input: MeetingFinalizationInput) async -> MeetingPersistencePayload
}
```

### Workstream D: Keep Adapter And Persistence Tests Stable

Existing tests should continue to pass:

- `MeetingSaveRegressionTests`
- `MeetingPersistenceServiceTests`
- full `Axii` test suite

Adapter tests should not grow into detailed finalization tests. Keep the
finalization matrix at the service layer.

## User-Visible Invariants To Preserve

These behaviors must remain true after Phase 4B:

- stop/save still returns the panel to idle
- final meetings still appear in history through Phase 4A persistence
- final meetings still include attached recordings when audio exists
- final transcript source labels remain `You` and `Remote`
- final segments remain sorted by time
- consecutive same-speaker final segments are still merged
- empty/silent chunks do not create transcript segments
- configured audio persistence format is unaffected
- meeting app name and duration are preserved
- history-disabled meeting mode does not persist history
- autosave/crash-recovery behavior does not change
- temp audio files are still cleaned up on stop

## Acceptance Criteria

Phase 4B is complete only when all are true:

- a dedicated meeting finalization service exists
- finalization input/output contracts are explicit
- `MeetingPipelineHandler.stop(...)` delegates final full-track transcription
  and final segment assembly to the new service
- `MeetingTranscriptManager` no longer owns final full-track transcription,
  final resampling, final chunking, or final merge behavior
- `MeetingTranscriptManager` still owns real-time transcription, autosave, and
  crash recovery
- `MeetingPipelineHandler.stop(...)` still owns stop coordination, cancelled
  chunk-task waiting, audio stop/read, autosave clearing, and temp cleanup
- source-label behavior is unchanged
- per-chunk transcription error tolerance is unchanged
- new service tests cover the required finalization behavior matrix
- existing Phase 4A adapter and persistence tests pass
- full test suite passes
- no Phase 4C permission/start/capture/session split is introduced

## Likely Files

Existing files likely to change:

- [MeetingPipelineHandler.swift](/Users/bartosz/dev/Axii/Axii/Features/Mode/Runtime/MeetingPipelineHandler.swift)
- [MeetingTranscriptManager.swift](/Users/bartosz/dev/Axii/Axii/Features/Meeting/MeetingTranscriptManager.swift)
- [ModeFeature.swift](/Users/bartosz/dev/Axii/Axii/Features/Mode/Runtime/ModeFeature.swift)

New files likely to be introduced:

- `Axii/Features/Mode/Runtime/MeetingFinalizationService.swift`
- `AxiiIntegrationTests/MeetingFinalizeServiceTests.swift`

Possibly introduced if useful:

- `Axii/Features/Mode/Runtime/MeetingFinalizationInput.swift`

## Required Test Commands

Run focused tests first:

```sh
xcodebuild test -project Axii.xcodeproj -scheme Axii -destination 'platform=macOS' -only-testing:AxiiIntegrationTests/MeetingFinalizeServiceTests -only-testing:AxiiIntegrationTests/MeetingSaveRegressionTests -only-testing:AxiiIntegrationTests/MeetingPersistenceServiceTests
```

Then run the full suite:

```sh
xcodebuild test -project Axii.xcodeproj -scheme Axii -destination 'platform=macOS'
```

## Commit Expectations

Use separate commits for:

- finalization behavior tests
- finalization service and boundary types
- handler/manager rewiring
- any thin adapter or project cleanup needed to compile

Do not squash everything into one commit.

## Report Back Format

When done, report back with:

1. branch name
2. commit list
3. exact files changed
4. exact finalization service and boundary types introduced
5. what finalization behavior moved out of `MeetingTranscriptManager`
6. what stop coordination remains in `MeetingPipelineHandler`
7. exact tests added or changed
8. final focused and full test commands used
9. any remaining risks or intentionally deferred items

If the work starts to require permission/start/capture decomposition, stop and
report that blocker instead of broadening the branch.
