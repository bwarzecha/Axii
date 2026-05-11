# Phase 4A Design: Meeting Persistence Service

## Status

Draft design for the first slice of Phase 4.

This document answers a narrower question than the overall meeting roadmap:

How do we reduce meeting-runtime complexity now, without destabilizing live
capture, autosave, or permission timing?

## Executive Summary

Phase 4A should extract meeting persistence first.

The current active meeting path already has a natural seam:

- `MeetingPipelineHandler.stop(saveToHistory:)` produces the finalized meeting
  result
- `ModeFeatureMeeting.saveMeetingToHistory(_:)` persists that result

That persistence logic is real product behavior, it has already carried a bug,
and it is currently owned by the wrong layer.

The right first cut is:

- keep `MeetingPipelineHandler` as the coordinator for live capture and
  finalization
- extract a dedicated `MeetingPersistenceService`
- move the stop-result payload out of `MeetingPipelineHandler.swift` so it
  becomes an explicit boundary type
- make persistence behavior primarily testable through service tests

This is the highest-value, lowest-risk meeting extraction.

## Why Phase 4A Comes First

Meeting mode is still the riskiest runtime path in the app.

If we try to split capture, permissions, chunk routing, autosave, and
finalization all at once, we increase the chance of:

- broken live recording
- race conditions during stop/finalize
- crash-recovery regressions
- permission-state regressions

Persistence is a better first cut because:

- it already has a clear downstream seam after stop/finalize
- it is product-critical and user-visible
- it can be tested on temp directories with real persisted outputs
- it reduces real complexity without touching the capture hot path first

## Current Code Reality

### 1. Persistence is split across the wrong layers

Today the active meeting path is split like this:

- `MeetingPipelineHandler.stop(saveToHistory:)` owns:
  - timer invalidation
  - chunk-task cancellation
  - audio stop
  - full transcription
  - transcript-manager cleanup
  - temp-file cleanup
  - returning the finalized meeting data
- `ModeFeature.saveMeetingToHistory(_:)` owns:
  - creating the `Meeting`
  - first history save
  - compressed audio persistence
  - re-saving the `Meeting` with attached recordings
  - swallowing/logging persistence failures

That means a runtime adapter currently owns detailed history-writing behavior.

### 2. The persistence payload is named as a handler-local result

`MeetingStopResult` currently lives inside
`MeetingPipelineHandler.swift`.

Once a dedicated persistence service consumes that value, it is no longer a
handler-private detail. The seam needs to become explicit.

### 3. The persistence contract is already important enough to deserve its own owner

We already had a real bug in this area:

- audio files were saved
- the returned `AudioRecording` values were not attached back to the `Meeting`

That bug was fixed, but it demonstrated the real issue:

- persistence is not incidental plumbing
- it is a product contract and should have a dedicated owner

### 4. `MeetingTranscriptManager` is still doing more than we want eventually, but that is not this cut

`MeetingTranscriptManager` still owns:

- autosave
- crash recovery
- real-time chunk transcription
- final full-track transcription
- speaker-merge behavior

That is still a hotspot, but splitting it now would broaden the phase too far.

### 5. Existing tests are pointed at the wrong long-term seam

Current save tests exercise `ModeFeature.saveMeetingToHistory(_:)`.

That was the right temporary seam for regression protection, but it is not the
right long-term contract surface.

Phase 4A should move the persistence matrix to a dedicated service test suite.

## Core Design Choice

Treat meeting persistence as its own collaborator now, while leaving live
capture/finalization where it is for one more phase.

The active meeting path after Phase 4A should look like this:

1. `ModeFeatureMeeting.stopMeeting(saveToHistory:)`
2. `MeetingPipelineHandler.stop(saveToHistory:)`
3. `MeetingPersistenceService.persist(...)`
4. `HistoryService`

That means:

- the handler still owns meeting capture/finalization
- the service owns the persisted meeting/audio write contract
- the mode feature stays a thin runtime adapter

## Recommended Architecture

### 1. Introduce an explicit persistence payload

Move the current stop-result value out of `MeetingPipelineHandler.swift` into a
dedicated file.

Preferred name:

- `MeetingPersistencePayload`

Acceptable name if you want to preserve existing churn:

- `MeetingStopResult`

Either way, it should no longer live only inside the handler file.

Expected payload fields:

- `micSamples: [Float]`
- `micSampleRate: Double`
- `systemSamples: [Float]`
- `systemSampleRate: Double`
- `segments: [MeetingSegment]`
- `duration: TimeInterval`
- `appName: String?`

Do not broaden this payload beyond what persistence actually needs.

### 2. Introduce `MeetingPersistenceService`

This service should own:

- creating the base `Meeting`
- initial history save
- compressed audio writes for mic/system tracks
- re-saving the final `Meeting` with attached recordings
- returning the final persisted `Meeting`

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

Important design choice:

- pass `AudioStorageFormat` in explicitly
- do not inject `SettingsService` into the persistence service

That keeps the service focused on persistence, not settings ownership.

### 3. Preserve the required two-write pattern explicitly

`HistoryService.saveAudioCompressed(...)` depends on an existing metadata cache
entry for the interaction id.

That means the persistence service must still:

1. create the base `Meeting`
2. save it once to establish the history folder / cache entry
3. save compressed mic/system audio against that meeting id
4. re-save the `Meeting` with attached `AudioRecording` values if audio exists

This is not accidental duplication and should not be “cleaned up” away in Phase
4A unless `HistoryService` itself is deliberately redesigned, which is out of
scope here.

Also important:

- when re-saving, preserve the original `meeting.id`
- preserve the original `meeting.createdAt`

If either changes, the persisted folder identity and metadata continuity can
break because folder naming derives from `createdAt` and `id`.

### 4. Keep outward failure semantics in the adapter

Current user-visible behavior should remain:

- if persistence fails after stop, the panel should not get stuck
- the app should log and continue back to idle

So:

- `MeetingPersistenceService.persist(...)` should throw on real persistence
  failure
- `ModeFeatureMeeting.stopMeeting(...)` should catch/log and preserve current
  outward behavior

This keeps the persistence service testable without hiding failures inside it.

### 5. Keep history-disabled behavior explicit at the adapter boundary

Current outward behavior is:

- if history is disabled, meeting stop/save performs no history write
- we do not rely on placeholder `AudioRecording` values from
  `HistoryService.saveAudioCompressed(...)`

Phase 4A should preserve that explicitly.

Recommended approach:

- keep the `historyService.isEnabled` guard in `ModeFeatureMeeting`
  or an equivalently thin adapter boundary
- let `MeetingPersistenceService` assume persistence is actually enabled

That keeps the service contract clean and avoids mixing “real persist” with
“disabled no-op” semantics inside the same method.

### 6. Keep `MeetingPipelineHandler` unchanged as much as possible in this phase

This phase should not try to redesign:

- permission gating
- chunk routing
- app switching
- autosave
- crash recovery
- final transcription sequencing
- autosave/temp-file cleanup ownership

The handler may need a small type rename if the persistence payload moves out,
but it should remain the live coordinator for now.

Important:

- `transcriptManager?.clearAutoSave()`
- `audio.cleanupTempFiles()`

should remain in `MeetingPipelineHandler.stop(...)` for this phase. Do not move
that cleanup into the new persistence service.

### 7. Move the main persistence regression matrix to service tests

After Phase 4A:

- the main save behavior matrix should live in `MeetingPersistenceServiceTests`
- adapter tests should stay thin

That is the same testing shape we used successfully in Phase 3A/3B:

- logic in narrow service/processor tests
- adapter concerns in minimal integration tests

## User-Visible Invariants To Preserve

These must remain true in Phase 4A:

- newly saved meetings still appear in history
- newly saved meetings still reload with attached recordings when audio exists
- configured audio format is preserved for saved recordings
- meeting app name and duration are preserved
- stop/save still returns the panel to idle
- persistence failure after stop does not leave the panel stuck in processing
- history-disabled behavior does not suddenly start writing meetings
- autosave/crash-recovery behavior does not change in this phase

## What This Phase Must Not Do

Do not:

- split permission/start flow yet
- split live capture/session ownership yet
- redesign `MeetingTranscriptManager`
- change autosave file format
- change persisted meeting/history schemas
- add speaker-profile enrichment work
- move meeting execution into the generic single-shot pipeline model
- introduce a broad “meeting framework”

## Tests For Phase 4A

### Service tests should become the main source of truth

Add a new suite like:

- `AxiiIntegrationTests/MeetingPersistenceServiceTests.swift`

Required service coverage:

- both recordings attached after persist
- configured compressed format is preserved
- saved recording references resolve to existing files
- no-audio payload still saves a meeting without recordings
- partial-audio payload saves only the present recording
- identity is preserved across the audio-attach re-save
  - same meeting id
  - same createdAt
  - one logical persisted meeting entry

### Adapter tests should stay thin

Existing save tests around `ModeFeature.saveMeetingToHistory(_:)` should be
rewritten or replaced.

Preferred end state:

- main persistence matrix moves to service tests
- only thin adapter behavior remains at the mode-feature layer

Required adapter regressions:

- history-disabled meeting stop/save does not persist a meeting
- persistence failure still returns the runtime to idle

Only add a new seam for that if truly necessary. Do not broaden the app for a
single test.

Acceptable seam if needed:

- a narrow `MeetingPersisting` protocol or equivalent adapter-facing injection
  point for the new persistence service

Not acceptable:

- protocolizing `HistoryService` broadly just for this regression
- redesigning `MeetingPipelineHandler` purely for failure injection

## Risks

### Risk 1: Persistence extraction broadens into finalization extraction

Mitigation:

- keep the service downstream of the current stop/finalize seam
- do not change how final segments are produced in this phase

### Risk 2: Error semantics change accidentally

Mitigation:

- keep throwing behavior inside the service
- keep log-and-continue behavior in the adapter
- add a regression around not getting stuck after persistence failure

### Risk 3: “Cleanup” attempts break the required two-write flow

Mitigation:

- call out the `HistoryService` metadata-cache dependency explicitly
- preserve the initial save -> audio writes -> final save pattern
- preserve `meeting.id` and `meeting.createdAt` on the final re-save

### Risk 4: Payload churn creates more renaming than value

Mitigation:

- keep the payload fields identical to current behavior
- only rename the type if it materially improves ownership clarity

### Risk 5: Tests stay pinned to `ModeFeature` helper methods

Mitigation:

- move the save matrix to the new service tests
- keep adapter tests narrow

## Success Criteria

Phase 4A is successful when:

- meeting persistence is owned by a dedicated service
- the persistence payload is an explicit boundary, not a handler-private detail
- `ModeFeatureMeeting` no longer owns detailed save/audio-attach logic
- the main save behavior matrix lives in service tests
- current outward stop/save behavior is preserved
- no capture, permission, or autosave redesign leaked into this phase

## Recommendation

Do this phase before any meeting capture/start decomposition.

It is the best next cut because it meaningfully reduces meeting complexity
while leaving the riskiest real-time behavior untouched for now.
