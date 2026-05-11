# Phase 4A Execution Brief

This document is the authoritative contractor brief for Phase 4A.

If this document conflicts with older roadmap wording, follow this document and
[docs/refactor-execution-plan.md](/Users/bartosz/dev/Axii/docs/refactor-execution-plan.md).

## Phase Name

Phase 4A: Extract The Meeting Persistence Service

## Starting Point

Start only after Phase 3B is merged to `main`.

Branching:

- branch from current `main`
- branch name: `refactor/phase-4a`
- we will review the branch directly
- keep commits clean and separated by workstream

## Purpose

Reduce meeting-runtime complexity by extracting persistence first.

This phase should move final meeting/audio persistence out of
`ModeFeatureMeeting.swift` and into a dedicated service, while keeping
`MeetingPipelineHandler` as the live capture/finalization coordinator.

This is the highest-value first cut in meeting decomposition because it reduces
real complexity without destabilizing live capture.

## Why This Phase Exists

Right now the active meeting path still spreads one user-visible contract
across the wrong layers:

- `MeetingPipelineHandler.stop(saveToHistory:)` prepares the finalized meeting
  result
- `ModeFeature.saveMeetingToHistory(_:)` performs detailed persistence and
  audio attachment

That persistence logic is already important enough to deserve its own owner.
It has already carried a real bug, and it should no longer live in a runtime
adapter.

## Current Code Reality

These are the exact Phase 4A starting points:

- [MeetingPipelineHandler.swift](/Users/bartosz/dev/Axii/Axii/Features/Mode/Runtime/MeetingPipelineHandler.swift)
  - still owns stop/finalize coordination and returns the final meeting result
- [ModeFeatureMeeting.swift](/Users/bartosz/dev/Axii/Axii/Features/Mode/Runtime/ModeFeatureMeeting.swift)
  - still owns detailed meeting persistence and audio attachment
- [MeetingTranscriptManager.swift](/Users/bartosz/dev/Axii/Axii/Features/Meeting/MeetingTranscriptManager.swift)
  - still owns autosave, crash recovery, real-time transcription, and final
    transcript merging
- [MeetingSaveRegressionTests.swift](/Users/bartosz/dev/Axii/AxiiIntegrationTests/MeetingSaveRegressionTests.swift)
  - currently points at the mode-feature save helper, not a dedicated service

Important codebase constraints:

- `HistoryService.saveAudioCompressed(...)` requires the interaction metadata
  cache entry to already exist
- that means meeting persistence still requires an initial save before audio
  writes, then a final re-save when recordings are attached
- the final re-save must preserve the original `Meeting.id` and
  `Meeting.createdAt`
- `MeetingPipelineHandler.stop(...)` still owns `clearAutoSave()` and temp-file
  cleanup; do not move those responsibilities in this phase
- current history-disabled behavior is explicit at the adapter layer via
  `historyService.isEnabled`; do not accidentally replace that with placeholder
  recordings or silent partial persistence

## Goals

- introduce a dedicated meeting persistence service
- make the persistence payload an explicit boundary type
- keep `ModeFeatureMeeting` as a thin runtime adapter
- preserve current outward stop/save behavior
- move the main save regression matrix to service tests

## Tenets

1. Extract persistence first, not capture.
   This phase should reduce complexity without touching the live recording hot
   path more than necessary.

2. Keep the service narrow.
   The new service should own final `Meeting` and audio writes only.

3. Keep outward failure behavior stable.
   Persistence failures should not leave the panel stuck in processing.

4. Keep settings ownership out of the service.
   Pass audio format in explicitly; do not inject all of `SettingsService`.

5. Keep the test suite layered.
   Persistence logic belongs in service tests. Adapter tests should stay thin.

## Non-Goals

Do not:

- split permission/start flow yet
- split live capture/session ownership yet
- redesign `MeetingTranscriptManager`
- change autosave/crash-recovery behavior
- redesign segment-merging behavior
- change persisted meeting/history schemas
- introduce speaker-profile enrichment work
- do Phase 4B or 4C work

## What Good Looks Like

At the end of a strong Phase 4A implementation:

- meeting persistence clearly lives in one service
- `ModeFeatureMeeting` no longer owns detailed save/audio-attach logic
- the stop-result payload is an explicit boundary, not a handler-local detail
- service tests are the main source of truth for persisted meeting behavior
- live capture and finalization behavior remain otherwise unchanged

## User-Visible Invariants To Preserve

These behaviors must remain true after Phase 4A:

- newly saved meetings still appear in history
- newly saved meetings still reload with attached recordings when audio exists
- configured audio format is preserved
- meeting app name and duration are preserved
- stop/save still returns the panel to idle
- persistence failure after stop does not leave the panel stuck
- history-disabled meeting mode does not silently write history
- autosave/crash-recovery behavior does not change

## Likely Files

Existing files likely to change:

- [ModeFeatureMeeting.swift](/Users/bartosz/dev/Axii/Axii/Features/Mode/Runtime/ModeFeatureMeeting.swift)
- [MeetingPipelineHandler.swift](/Users/bartosz/dev/Axii/Axii/Features/Mode/Runtime/MeetingPipelineHandler.swift)
- [ModeFeature.swift](/Users/bartosz/dev/Axii/Axii/Features/Mode/Runtime/ModeFeature.swift)
- [MeetingSaveRegressionTests.swift](/Users/bartosz/dev/Axii/AxiiIntegrationTests/MeetingSaveRegressionTests.swift)

New files likely to be introduced:

- `Axii/Features/Mode/Runtime/MeetingPersistenceService.swift`
- `Axii/Features/Mode/Runtime/MeetingPersistencePayload.swift`
  or an equivalent extracted boundary type
- `AxiiIntegrationTests/MeetingPersistenceServiceTests.swift`

Guidance on location:

- keep the new types near the mode runtime
- do not put them in a generic cross-app services folder
- this is still active mode-runtime work, not a shared platform layer

## Required Workstreams

### Workstream A: Make The Persistence Boundary Explicit

Required changes:

1. Extract the current stop-result type out of `MeetingPipelineHandler.swift`.

Preferred outcome:

- introduce `MeetingPersistencePayload`

Acceptable fallback:

- keep the existing name `MeetingStopResult`, but move it into its own file

Rule:

- once a dedicated persistence service depends on this payload, it must no
  longer live only inside the handler file

Expected payload fields:

- mic samples + sample rate
- system samples + sample rate
- segments
- duration
- app name

Do not broaden the payload beyond what persistence actually needs.

### Workstream B: Extract `MeetingPersistenceService`

Required changes:

1. Introduce `MeetingPersistenceService`.

Suggested API:

```swift
@MainActor
final class MeetingPersistenceService {
    init(historyService: HistoryService)

    func persist(
        payload: MeetingPersistencePayload,
        audioFormat: AudioStorageFormat
    ) async throws -> Meeting
}
```

Required responsibilities:

- create the base `Meeting`
- save it to history
- save compressed mic/system audio if present
- attach `AudioRecording` metadata back to the meeting
- re-save the final meeting when recordings exist
- return the final `Meeting`

Implementation rules:

- do not inject `SettingsService`; pass `audioFormat` explicitly
- preserve the required two-write flow
  - first save establishes folder/cache identity
  - audio writes use that meeting id
  - final save attaches recordings
- preserve the original `Meeting.id` and `Meeting.createdAt` on the final
  re-save
- do not swallow errors inside the service unless a specific persistence step
  is intentionally best-effort and documented
- keep the service focused on persistence only

### Workstream C: Rewire The Runtime Adapter

Required changes:

1. Update `ModeFeatureMeeting.stopMeeting(saveToHistory:)` to call the new
   service.

2. Remove the detailed persistence body from
   `ModeFeature.saveMeetingToHistory(_:)`.

Preferred outcome:

- delete `saveMeetingToHistory(_:)` entirely

Acceptable fallback:

- keep a tiny adapter helper that delegates directly into the service

Required outward behavior:

- when save succeeds, phase returns to `.idle`
- when save fails, the error is logged and phase still returns to `.idle`
- do not leave the panel stuck in `.processing`
- when history is disabled, do not call into a path that creates placeholder
  audio metadata or partial history state

Implementation rule:

- do not broaden this into start/capture/finalize decomposition
- keep `historyService.isEnabled` behavior explicit at the adapter boundary
  unless you can preserve the exact same outward contract just as clearly
- do not move autosave/temp-file cleanup out of
  `MeetingPipelineHandler.stop(...)` in this phase

### Workstream D: Move The Save Matrix To Service Tests

Add a new service-focused suite, for example:

- `AxiiIntegrationTests/MeetingPersistenceServiceTests.swift`

Required service coverage:

- persist with both tracks attaches both recordings
- configured compressed format is preserved
- recording references resolve to existing files
- no-audio payload still saves a meeting without recordings
- partial-audio payload saves only the present recording
- identity is preserved across the audio-attach re-save
  - same meeting id
  - same createdAt
  - one logical persisted meeting entry

Required adapter coverage:

- keep adapter tests thin
- add a narrow regression that persistence failure still returns to idle
- add a narrow regression that history-disabled meeting stop/save does not
  persist a meeting

Important:

- do not keep the full persistence matrix pinned to `ModeFeature`
- do not test private helper decomposition
- do not test exact internal write ordering beyond the required persisted
  contract
- if a failure-injection seam is needed, keep it narrow
  - acceptable: a small `MeetingPersisting` protocol or equivalent
    adapter-facing injection point for the new service
  - not acceptable: broad protocolization of `HistoryService` or
    redesigning `MeetingPipelineHandler` just for tests

## Design-For-Refactor Requirement

Implement this phase so later meeting decomposition does not require major test
rewrites.

Specifically:

- service tests must target persisted behavior, not internal file-write order
- adapter tests must target outward runtime behavior only
- do not pin tests to `MeetingPipelineHandler` internals more than necessary
- do not build a generic meeting framework to “future-proof” later phases

## Success Criteria

Phase 4A is successful when all of the following are true:

- meeting persistence is owned by a dedicated service
- the persistence payload is an explicit boundary type
- `ModeFeatureMeeting` no longer owns detailed save/audio-attach logic
- service tests are the main source of truth for meeting persistence behavior
- current outward stop/save behavior is preserved
- no capture/permission/autosave redesign leaked into this phase

## Acceptance Criteria

This phase is complete only when all are true:

- a dedicated meeting persistence service exists
- the stop-result payload no longer lives only inside `MeetingPipelineHandler.swift`
- `ModeFeatureMeeting` delegates persistence instead of owning the full logic
- service tests cover both-track, partial-track, no-audio, format,
  resolvable-reference, and stable-identity behavior
- the required initial-save -> audio-write -> final-save pattern is preserved
  or explicitly justified by a deliberate `HistoryService` change, which is not
  expected in this phase
- the final persisted meeting preserves its original `id` and `createdAt`
- persistence failure does not leave the runtime stuck
- history-disabled meeting stop/save does not persist history
- autosave/temp-file cleanup ownership remains in
  `MeetingPipelineHandler.stop(...)`
- no broader meeting-framework or capture decomposition was introduced
- full test suite passes

## Commit Expectations

Use separate commits for:

- boundary payload extraction
- persistence service extraction
- runtime adapter rewiring
- service tests
- any thin adapter regression updates

Do not squash everything into one commit.

## Report Back Format

When done, report back with:

1. branch name
2. commit list
3. exact files changed
4. exact new service/payload types introduced
5. whether `saveMeetingToHistory(_:)` was removed or reduced to a thin adapter
6. where outward persistence-failure behavior now lives
7. exact tests added or changed
8. final test command used
9. any remaining risks or intentionally deferred items

If you hit a blocker that would force capture/finalize decomposition in this
branch, stop and report it instead of broadening scope.
