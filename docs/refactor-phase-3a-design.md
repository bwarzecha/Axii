# Phase 3A Design: Single-Shot Mode Turn Processor

## Status

Draft design for the first architecture-heavy refactor after Phase 2.

This document exists to answer a narrower question than the overall roadmap:

How do we make the active mode runtime materially more testable without
breaking the mode-centric architecture or introducing a premature framework?

## Executive Summary

Phase 3A should not start by extracting a generic recording runtime, and it
should not be framed as a dictation-specific coordinator.

The right first cut is to extract the post-capture execution path for
single-shot modes out of `ModeFeatureRecording` into a dedicated
`SingleShotModeTurnProcessor`.

That processor is not a UI abstraction and not a built-in-feature abstraction.
It is an execution-path abstraction for a specific mode family:

- simple capture
- batch transcription
- optional processing steps
- output execution
- panel-persistence decision

That family includes built-in dictation, but it also includes custom
single-shot modes. That is why this is the correct mode-aligned cut.

## Why Phase 3 Needs Design Work

The current code works, but Phase 3 is the first point where a refactor can
easily look cleaner while actually making the system less coherent.

The failure modes to avoid are:

- feature-specific wrappers that weaken the mode model
- broad protocolization with little real testability value
- a generic recording framework extracted before the execution pattern is
  proven
- tests rewritten around new object names while still pinning the same hidden
  behavior

This design is intended to avoid those outcomes.

## Current Code Reality

### 1. `ModeFeature` is the active runtime shell

`ModeFeature.swift` currently owns:

- hotkey routing
- panel lifecycle hooks
- device-list refresh
- settings callback wiring
- cancellation/deactivation behavior
- the active `ModeRuntimeState`
- selection of the runtime path:
  - single-shot
  - multi-turn
  - meeting/long-running

That is acceptable for a shell/adapter. It should not remain the owner of the
single-shot execution flow.

### 2. `ModeFeatureRecording` currently mixes capture and execution

`ModeFeatureRecording.swift` handles all of this:

- focus capture
- media pause/resume
- `RecordingSessionHelper` lifecycle
- visualization updates
- audio-session error handling
- transcription
- pipeline execution
- output execution
- manual-copy behavior
- auto-dismiss scheduling
- microphone-switch restart behavior

This is too much responsibility for one file and one runtime adapter.

### 3. The real complexity begins after capture stops

The strongest existing characterization tests cluster around
`stopSimpleRecording()` behavior:

- transcription success
- empty transcription
- copied fallback
- manual copy required
- transcription error
- stay-open vs auto-dismiss behavior

That is the strongest signal about where the first seam should go.

### 4. The runtime already contains execution families

The current runtime split is not primarily about UI. It is about execution
semantics:

- single-shot mode execution
- multi-turn conversation execution
- long-running meeting execution

The hotkey/UI layer routes into one of these execution families. The current
problem is that the single-shot family is still embedded inside the adapter.

### 5. `OutputHandler` and `PipelineRunner` are already usable seams

They are not perfect, but they already have meaningful integration coverage.
Phase 3A should reuse them rather than redesign them.

## The Core Architectural Insight

The active runtime should be understood in two layers:

### Layer 1: Runtime adapter

Owned by `ModeFeature` and related files.

Responsibilities:

- hotkeys
- panel lifecycle
- device selection
- capture session lifecycle
- activation/deactivation
- live visualization

### Layer 2: Turn execution

Owned by mode-family-specific execution processors.

Responsibilities:

- consume a completed capture
- execute the correct post-capture behavior
- write resulting state
- decide dismiss policy

Phase 3A should improve Layer 2 without destabilizing Layer 1.

## Problems To Solve In Phase 3A

1. Single-shot execution behavior lives in a runtime adapter instead of a
   stable execution object.
2. Tests currently need `ModeFeature` construction and, in a few places,
   internal scheduling assertions.
3. The dismiss policy is currently implicit and coupled to
   `DispatchWorkItem` ownership in `ModeFeature`.
4. The logic that filters out multi-turn LLM steps from the single-shot path is
   embedded inline in `ModeFeatureRecording`.
5. There is no stable contract for the single-shot execution family that
   later refactors can preserve.

Phase 3A should solve those problems and no more.

## Tenets

1. Preserve the mode model.

   This phase should extract mode execution behavior, not drift back toward
   built-in-feature architecture.

2. Cut at the completed-capture boundary.

   The first extraction point should start from:
   "we have `samples` and `sampleRate`."

3. Keep the runtime shell thin but real.

   `ModeFeature` should remain responsible for hotkeys, panel lifecycle,
   capture wiring, and feature activation semantics.

4. Start with the single-shot execution family.

   Do not force a generic shared abstraction for every mode family before the
   first processor is proven.

5. Prefer narrow boundary interfaces over broad protocolization.

   Only abstract the edges Phase 3A needs for stable tests.

6. Preserve user-visible behavior first.

   Internal cleanup is not success if visible behavior changes.

7. Make Phase 3B easier, not more abstract.

   The single-shot processor should clarify how to extract the multi-turn
   processor next, not commit the codebase to a framework shape that may be
   wrong.

## User-Visible Invariants To Preserve

These behaviors must not change in Phase 3A:

- recording activates the feature only after audio session start succeeds
- if `captureFocus` is enabled, focus is captured before recording begins
- if `pauseMedia` is enabled, media pause happens at start and resume happens
  after post-capture execution ends
- empty transcription shows `No speech detected`
- single-shot execution ignores multi-turn `llmTransform` steps
- outputs still run through the existing output model
- manual-copy output still prevents auto-dismiss
- `PanelPersistence.autoDismiss` still dismisses only when manual copy is not
  required
- transcription and processing errors still map to the same user-facing phase
  behavior
- explicit cancel/escape still deactivates through the existing `ModeFeature`
  path

## Execution Families

The runtime should be treated as three execution families:

### 1. Single-shot mode family

Characteristics:

- one completed capture
- one text result
- optional processing pipeline
- output destinations
- optional auto-dismiss

This is the Phase 3A target.

### 2. Multi-turn mode family

Characteristics:

- one completed capture per turn
- persistent session/history context
- LLM turn execution with prior messages
- session-oriented completion behavior

This is the Phase 3B target.

### 3. Long-running meeting family

Characteristics:

- active live capture session
- streaming/meeting-specific state
- finalize/save behavior rather than one completed turn

This stays out of scope until Phase 4.

## Options Considered

### Option A: Keep the current shape and just extract helper methods

Why rejected:

- no stable test seam
- `ModeFeatureRecording` would still own business logic
- Phase 3B would gain little reusable structure

### Option B: Extract a dictation-specific coordinator

Why rejected:

- weakens the mode design
- encourages feature-centric thinking
- makes custom single-shot modes feel secondary

### Option C: Extract a full generic recording/session framework first

Why rejected:

- too early
- the shared capture path is not the current pain point
- risks creating framework code before execution semantics are proven

### Option D: Extract the single-shot post-capture processor

Why chosen:

- aligns with the mode design
- targets the real complexity hotspot
- creates a stable contract for the single-shot execution family
- leaves Phase 3B room to mirror the pattern for multi-turn execution

## Recommended Phase 3A Architecture

### Core New Type

Introduce:

- `SingleShotModeTurnProcessor`

Suggested responsibility:

- execute the post-capture behavior for any single-shot mode

Suggested public API:

```swift
@MainActor
final class SingleShotModeTurnProcessor {
    func process(
        capture: CompletedCapture,
        config: SingleShotTurnConfig
    ) async
}
```

The exact names can change, but the responsibility should not.

## Core Data Boundary

Introduce a completed-capture value object:

```swift
struct CompletedCapture {
    let samples: [Float]
    let sampleRate: Double
    let focusSnapshot: FocusSnapshot?
}
```

Why:

- it is the natural seam between capture lifecycle and execution logic
- it keeps Phase 3A honest about where the cut is
- it is reusable for Phase 3B

## Single-Shot Config Snapshot

Introduce a narrow execution config snapshot:

```swift
struct SingleShotTurnConfig {
    let modeName: String
    let processing: [ProcessingStep]
    let outputs: [OutputDestination]
    let panelPersistence: PanelPersistence
}
```

Why:

- the processor should not depend on the full `ModeConfig`
- it only needs the post-capture execution pieces
- this keeps tests tighter and the seam clearer

## Boundary Interfaces

Phase 3A should add only the edges needed for stable processor tests.

### 1. Transcriber

Reuse existing:

- `TranscriptionProviding`

### 2. Pipeline executor

Add a narrow protocol around `PipelineRunner`:

```swift
protocol PipelineExecuting {
    func run(
        steps: [ProcessingStep],
        context: PipelineContext
    ) async throws -> PipelineContext
}
```

### 3. Output executor

Add a narrow protocol around `OutputHandler`:

```swift
protocol ModeOutputExecuting {
    func executeOutputs(
        destinations: [OutputDestination],
        context: PipelineContext,
        state: ModeRuntimeState
    ) async
}
```

### 4. Dismiss control

Add a tiny boundary for dismiss decisions:

```swift
protocol ModeDismissControlling: AnyObject {
    func cancelScheduledDismiss()
    func scheduleDismiss(after delay: TimeInterval)
}
```

Why:

- this replaces tests reaching into `deactivationWorkItem`
- `ModeFeature` can implement it using existing scheduling behavior
- processor tests can assert behavior through a fake implementation

## What Stays In The Runtime Adapter

These concerns should stay in `ModeFeature` / `ModeFeatureRecording` in
Phase 3A:

- hotkey routing
- panel creation
- `FeatureContext` integration
- selected microphone resolution and persistence
- `RecordingSessionHelper` creation/start
- visualization callbacks
- audio-session start errors
- `context?.onActivate?(self)` after successful capture start
- explicit cancel/escape/deactivate behavior
- copy-and-dismiss behavior for the "press hotkey again after manual copy"
  case

## What Moves Out

These concerns should move into `SingleShotModeTurnProcessor`:

- transcription after capture stop
- empty-transcription handling
- `PipelineContext` construction
- filtering out multi-turn LLM steps
- pipeline execution
- output execution
- dismiss decision logic
- transcription/processing error mapping

## Target Flow After Phase 3A

### Start path

`startSimpleRecording()` remains in the runtime adapter:

- capture focus if enabled
- pause media if enabled
- create/start `RecordingSessionHelper`
- wire visualization updates
- set recording phase and activate feature
- opportunistically warm the transcriber

### Stop path

`stopSimpleRecording()` becomes thin:

1. guard recording state
2. stop helper and obtain `(samples, sampleRate)`
3. clear recording-specific visualization state
4. set `state.phase = .transcribing`
5. build `CompletedCapture`
6. call `singleShotTurnProcessor.process(...)`
7. clear `focusSnapshot`
8. resume media in the existing adapter layer

The business flow after step 6 no longer belongs to `ModeFeatureRecording`.

## Testing Strategy

### New primary tests

Phase 3A should add a focused unit test suite for
`SingleShotModeTurnProcessor`.

Required cases:

- transcription success with no pipeline steps
- transcription success with pipeline steps
- empty transcription
- output requires manual copy
- auto-dismiss when allowed
- stay-open when configured
- transcription error
- pipeline error
- multi-turn LLM steps are skipped for single-shot execution

These tests should assert:

- `ModeRuntimeState.phase`
- `ModeRuntimeState.finalText`
- `ModeRuntimeState.needsManualCopy`
- `ModeRuntimeState.manualCopyText`
- dismiss-controller interactions
- output executor interactions

They should not assert:

- `DispatchWorkItem`
- `ModeFeature` property layout
- exact task/callback decomposition

### Existing integration tests

The current `DictationOrchestrationTests` should become transitional.

After Phase 3A:

- keep only the integration value that still matters at the adapter level
- move primary single-shot behavior assertions to processor tests
- remove or shrink assertions that existed only because there was no stable
  seam

In practice, the `deactivationWorkItem` assertions should disappear from the
primary test bed once the dismiss-control seam exists.

## Migration Plan

### Step 1

Introduce:

- `CompletedCapture`
- `SingleShotTurnConfig`
- `PipelineExecuting`
- `ModeOutputExecuting`
- `ModeDismissControlling`

Add production conformances:

- `PipelineRunner: PipelineExecuting`
- `OutputHandler: ModeOutputExecuting`

### Step 2

Implement `SingleShotModeTurnProcessor` with unit tests first.

Do not wire it into `ModeFeature` yet.

### Step 3

Wire `ModeFeature` to own one processor instance for single-shot modes.

### Step 4

Replace the body of `stopSimpleRecording()` with a thin adapter that delegates
post-capture work.

### Step 5

Update or remove the now-unnecessary integration assertions that inspect
implementation details.

## Why This Is Meaningfully Better

After Phase 3A:

- the single-shot execution family has a stable home
- the main tests target a real execution contract instead of `ModeFeature`
  internals
- `ModeFeatureRecording` stops owning post-capture single-shot logic
- Phase 3B can reuse the same completed-capture seam for multi-turn execution

That is a real architectural improvement, not just code motion.

## What Phase 3A Explicitly Does Not Do

Do not:

- redesign `OutputHandler`
- move all capture mechanics out of `ModeFeatureRecording`
- introduce a generic recording framework
- extract a full reducer/effect runtime
- refactor meeting logic
- change UI view structure
- change persisted schemas

## Phase 3B Implication

If Phase 3A works well, Phase 3B should mirror the same cut:

- keep capture/lifecycle in the runtime adapter
- extract `MultiTurnModeTurnProcessor` for the multi-turn post-capture path

Only after both single-shot and multi-turn execution families are represented
cleanly should the project decide whether a shared capture abstraction is
actually worth introducing.

## Open Questions

These are execution-brief questions, not blockers for the architecture:

1. Should `SingleShotModeTurnProcessor` own a tiny `Clock` abstraction for
   duration/date determinism, or is `Date()` acceptable in Phase 3A?
2. Should no-speech and generic failure messages stay inline at first, or move
   to constants?
3. Should the processor write directly to `ModeRuntimeState`, or should a thin
   state sink be introduced only if the implementation starts to sprawl?

Current recommendation:

- keep `Date()` inline for Phase 3A
- keep user-visible strings unchanged
- write directly to `ModeRuntimeState` unless a sink becomes clearly necessary

## Success Criteria

Phase 3A is successful if:

- `stopSimpleRecording()` becomes a thin adapter
- single-shot execution behavior is owned by `SingleShotModeTurnProcessor`
- processor tests replace the need for `deactivationWorkItem` assertions
- no broad new abstraction layer is introduced
- user-visible single-shot mode behavior stays the same
- the resulting pattern is clean enough to reuse for Phase 3B
