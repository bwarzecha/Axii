# Phase 3A Execution Brief

This document is the authoritative contractor brief for Phase 3A.

If this document conflicts with older roadmap wording or stale references to
"dictation/conversation coordinators," follow this document and
[docs/refactor-execution-plan.md](/Users/bartosz/dev/Axii/docs/refactor-execution-plan.md).

## Phase Name

Phase 3A: Extract The Single-Shot Mode Turn Processor

## Starting Point

Start only after Phase 2 is merged to `main`.

Branching:

- branch from current `main`
- branch name: `refactor/phase-3a`
- we will review the branch directly
- keep commits clean and separated by workstream

## Purpose

Move the single-shot post-capture execution path out of
[ModeFeatureRecording.swift](/Users/bartosz/dev/Axii/Axii/Features/Mode/Runtime/ModeFeatureRecording.swift)
into a dedicated, testable mode-turn processor without weakening the mode
design or starting a generic recording framework.

This is the first architecture-heavy refactor phase. The bar is higher here
than in Phases 0-2.

## Why This Phase Exists

After Phase 2, the app shell is clean enough that the next real complexity
hotspot is obvious:

- [ModeFeature.swift](/Users/bartosz/dev/Axii/Axii/Features/Mode/Runtime/ModeFeature.swift)
  is now the clear runtime shell
- [ModeFeatureRecording.swift](/Users/bartosz/dev/Axii/Axii/Features/Mode/Runtime/ModeFeatureRecording.swift)
  still mixes:
  - capture start/stop wiring
  - focus/media handling
  - transcription
  - pipeline execution
  - output execution
  - manual-copy behavior
  - dismiss decisions
  - error mapping

The code works, but the strongest existing tests still cluster around one
adapter method:

- `stopSimpleRecording()`

That is the signal that the next cut should be the single-shot post-capture
execution family.

## Current Code Reality

These are the exact Phase 3A starting points:

- [ModeFeatureRecording.swift](/Users/bartosz/dev/Axii/Axii/Features/Mode/Runtime/ModeFeatureRecording.swift)
  - `startSimpleRecording()` should remain mostly adapter/capture logic
  - `stopSimpleRecording()` still owns the single-shot business flow
  - `stopAndProcessMultiTurn()` remains the multi-turn path and is out of
    scope for this phase
- [ModeFeature.swift](/Users/bartosz/dev/Axii/Axii/Features/Mode/Runtime/ModeFeature.swift)
  - owns runtime shell state, lifecycle, hotkey routing, activation, and
    deactivation
- [OutputHandler.swift](/Users/bartosz/dev/Axii/Axii/Features/Mode/Runtime/OutputHandler.swift)
  - already encapsulates output execution and has meaningful integration tests
- [PipelineRunner.swift](/Users/bartosz/dev/Axii/Axii/Services/Pipeline/PipelineRunner.swift)
  - already encapsulates processing-step execution and has meaningful
    integration tests
- [DictationOrchestrationTests.swift](/Users/bartosz/dev/Axii/AxiiIntegrationTests/DictationOrchestrationTests.swift)
  - currently carries most of the single-shot behavior matrix through
    `ModeFeature`
  - this suite is transitional and should shrink in this phase

## Goals

- introduce a dedicated processor for the single-shot post-capture execution
  family
- cut the first stable seam at the completed-capture boundary
- keep [ModeFeature.swift](/Users/bartosz/dev/Axii/Axii/Features/Mode/Runtime/ModeFeature.swift)
  as the runtime adapter for capture start/stop, panel integration, and
  feature lifecycle
- make single-shot behavior primarily testable through processor contract
  tests rather than `ModeFeature` internals
- remove the remaining need for `deactivationWorkItem` assertions from the
  primary single-shot test bed
- leave Phase 3B clearly easier without prematurely extracting a generic
  framework

## Tenets

These are the principles for decision-making inside Phase 3A.

1. Preserve the mode design.
   This phase is about mode execution families, not built-in-feature
   coordinators.

2. Cut at the completed-capture boundary.
   The first extraction point starts from:
   "we have audio samples and a sample rate."

3. Keep the runtime shell thin but real.
   `ModeFeature` must continue to own hotkeys, panel lifecycle, capture
   start/stop, activation/deactivation, and explicit cancel behavior.

4. Prefer execution processors over UI abstractions.
   The extracted type is a post-capture execution object, not a view model or
   panel coordinator.

5. Reuse existing good seams.
   `PipelineRunner` and `OutputHandler` already exist and already have
   coverage. Reuse them; do not redesign them broadly in this phase.

6. Add only the boundaries Phase 3A needs.
   No broad protocolization, no "future-proof" framework layer, no generic
   engine for every mode family.

7. Move the main behavior matrix into stable tests.
   The primary assertions for single-shot behavior should live in processor
   tests, not in `ModeFeature` integration tests pinned to implementation
   details.

8. Leave Phase 3B easier, not more abstract.
   The single-shot processor should establish the pattern for multi-turn
   extraction without forcing both families into one generic hierarchy now.

## Non-Goals

Do not:

- extract the multi-turn processor yet
- refactor [ConversationHandler.swift](/Users/bartosz/dev/Axii/Axii/Features/Mode/Runtime/ConversationHandler.swift)
  broadly
- refactor meeting mode
- build a generic recording/session framework
- redesign `ModeRuntimeState`
- redesign `OutputHandler` or `PipelineRunner` beyond narrow seam work
- invent a generic step engine for conversation/session behavior
- change persisted schemas
- change hotkey behavior
- change panel layouts or UI design
- add smoke automation
- do Phase 3B or Phase 4 work

## What Good Looks Like

At the end of a strong Phase 3A implementation:

- a new engineer can open
  [ModeFeatureRecording.swift](/Users/bartosz/dev/Axii/Axii/Features/Mode/Runtime/ModeFeatureRecording.swift)
  and immediately see that it is a runtime adapter, not the owner of the
  single-shot business flow
- the post-capture behavior for built-in Dictation and custom single-shot
  modes clearly lives in one processor
- the processor begins at a small boundary like `CompletedCapture`, not at
  hotkeys or panel lifecycle
- single-shot success, empty result, copy fallback, manual copy, dismiss
  policy, and error behavior are covered by focused processor tests
- `DictationOrchestrationTests` is no longer the main source of truth for
  single-shot behavior
- no tests reach into `DispatchWorkItem` or other adapter internals to verify
  dismiss behavior
- the diff reads as a coherent extraction, not code motion plus protocol
  scatter

## Likely Files

These are the most likely files for this phase. Exact final file names may
vary, but the responsibility boundaries should not.

Existing files likely to change:

- [ModeFeatureRecording.swift](/Users/bartosz/dev/Axii/Axii/Features/Mode/Runtime/ModeFeatureRecording.swift)
- [ModeFeature.swift](/Users/bartosz/dev/Axii/Axii/Features/Mode/Runtime/ModeFeature.swift)
- [OutputHandler.swift](/Users/bartosz/dev/Axii/Axii/Features/Mode/Runtime/OutputHandler.swift)
- [PipelineRunner.swift](/Users/bartosz/dev/Axii/Axii/Services/Pipeline/PipelineRunner.swift)
- [DictationOrchestrationTests.swift](/Users/bartosz/dev/Axii/AxiiIntegrationTests/DictationOrchestrationTests.swift)
- [OutputHandlerTests.swift](/Users/bartosz/dev/Axii/AxiiIntegrationTests/OutputHandlerTests.swift)

New files likely to be introduced:

- `Axii/Features/Mode/Runtime/CompletedCapture.swift`
- `Axii/Features/Mode/Runtime/SingleShotTurnConfig.swift`
- `Axii/Features/Mode/Runtime/SingleShotModeTurnProcessor.swift`
- `AxiiTests/SingleShotModeTurnProcessorTests.swift`

Guidance on location:

- keep runtime-execution-specific types near the mode runtime
- do not dump Phase 3A-specific abstractions into a generic cross-app
  "Protocols" folder unless they are truly shared outside the mode runtime

## Required Workstreams

### Workstream A: Define The Completed-Capture Seam And Narrow Boundaries

Required changes:

1. Introduce a small completed-capture value object.

Suggested shape:

```swift
struct CompletedCapture {
    let samples: [Float]
    let sampleRate: Double
    let focusSnapshot: FocusSnapshot?
}
```

The exact fields may vary slightly, but the seam must begin after capture has
completed, not before.

2. Introduce a narrow single-shot execution config snapshot.

Suggested contents:

- mode name
- processing steps
- output destinations
- panel persistence

Do not pass the full `ModeConfig` into the processor unless you can justify
why a narrower snapshot would be incorrect.

3. Add only the boundary interfaces Phase 3A actually needs.

Expected seams:

- existing `TranscriptionProviding`
- a narrow wrapper around `PipelineRunner`
- a narrow wrapper around `OutputHandler`
- a narrow dismiss-control seam

Suggested examples:

```swift
protocol PipelineExecuting {
    func run(
        steps: [ProcessingStep],
        context: PipelineContext
    ) async throws -> PipelineContext
}

protocol ModeOutputExecuting {
    func executeOutputs(
        destinations: [OutputDestination],
        context: PipelineContext,
        state: ModeRuntimeState
    ) async
}

protocol ModeDismissControlling: AnyObject {
    func cancelScheduledDismiss()
    func scheduleDismiss(after delay: TimeInterval)
}
```

Important:

- names can change
- responsibilities should not
- do not protocolize unrelated services in this phase

4. Reuse existing production types where possible.

Expected conformances:

- `PipelineRunner` should satisfy the pipeline seam
- `OutputHandler` should satisfy the output seam
- the dismiss seam should be implemented by the runtime adapter or by a very
  small adapter owned by it

### Workstream B: Extract The Single-Shot Processor With Tests First

Required changes:

1. Introduce a concrete processor for the single-shot execution family.

Suggested name:

- `SingleShotModeTurnProcessor`

2. Give the processor ownership of the single-shot post-capture behavior:

- transcription after capture stop
- empty-transcription handling
- `PipelineContext` construction
- filtering out multi-turn `llmTransform` steps
- pipeline execution
- output execution
- turn-completion phase ownership
- dismiss decision logic
- transcription/pipeline error mapping

3. Keep the processor mode-oriented.

This processor is for any mode that follows the single-shot execution family:

- built-in Dictation
- custom single-shot modes

It is not a dictation-only object.

4. Preserve the current state model.

Do not redesign `ModeRuntimeState` in this phase.

It is acceptable for the processor to work with the existing state object as
long as the processor contract is stable and well tested.

Important quality rule:

- the processor should own turn orchestration state
- if [OutputHandler.swift](/Users/bartosz/dev/Axii/Axii/Features/Mode/Runtime/OutputHandler.swift)
  currently sets `state.phase = .done`, move that responsibility into the
  processor if you can do so narrowly
- Phase 3A should make completion-state ownership clearer, not more implicit

5. Keep the processor concrete by default.

Do not introduce a new protocol for the processor itself unless it is needed
for a clear and narrow testing seam at the adapter boundary.

If you do introduce one:

- keep it local to the mode runtime
- do not generalize it across execution families prematurely

### Workstream C: Wire The Processor Into The Runtime Adapter

Required changes:

1. `startSimpleRecording()` should remain mostly adapter logic:

- focus capture
- media pause
- `RecordingSessionHelper` creation/start
- visualization wiring
- activation on successful start
- opportunistic transcriber warm-up

2. `stopSimpleRecording()` should become thin.

Expected flow:

1. guard recording state and helper
2. stop helper and obtain samples
3. clear recording-specific visualization state
4. set transcribing phase
5. build `CompletedCapture`
6. hand off to the single-shot processor
7. clear `focusSnapshot`
8. resume media in the existing adapter layer

The exact code shape may vary, but the post-capture business flow should no
longer live inline in `ModeFeatureRecording`.

3. Keep explicit cancel/deactivate behavior in `ModeFeature`.

Do not move:

- `cancelAndDeactivate()`
- hotkey routing
- panel actions
- copy-and-dismiss handling for the done/manual-copy case

4. Keep the multi-turn path unchanged except for truly trivial nearby cleanup.

`stopAndProcessMultiTurn()` is not the target in Phase 3A.

### Workstream D: Reshape The Test Bed Around The New Stable Contract

This is mandatory. Phase 3A is not complete if the new processor exists but
the main behavior matrix still lives in adapter-heavy integration tests.

Required changes:

1. Add a focused processor test suite.

Suggested file:

- [SingleShotModeTurnProcessorTests.swift](/Users/bartosz/dev/Axii/AxiiTests/SingleShotModeTurnProcessorTests.swift)

Required cases:

- transcription success with no pipeline steps
- transcription success with pipeline steps
- empty transcription
- copy fallback output
- manual copy required
- auto-dismiss when allowed
- stay-open when configured
- transcription error
- pipeline error
- multi-turn `llmTransform` steps are skipped in single-shot execution

At least one success-with-pipeline test must verify that the processor enters
`.processing` for the pipeline path rather than silently skipping the user-
visible processing phase.

Required assertions should focus on:

- `ModeRuntimeState.phase`
- `ModeRuntimeState.finalText`
- `ModeRuntimeState.needsManualCopy`
- `ModeRuntimeState.manualCopyText`
- output executor interactions
- dismiss controller interactions
- filtered pipeline-step input

Do not assert:

- `DispatchWorkItem`
- exact task decomposition
- exact property layout of `ModeFeature`

2. Shrink `DictationOrchestrationTests` to adapter/wiring coverage.

The existing integration suite should stop being the primary home of the
single-shot behavior matrix.

After Phase 3A:

- keep only the integration coverage that still matters at the adapter layer
- remove assertions that existed only because there was no stable processor
  seam
- specifically, `deactivationWorkItem` assertions should disappear from the
  primary single-shot test bed

3. Keep the full suite passing.

Required command:

```bash
xcodebuild -project Axii.xcodeproj -scheme Axii -destination 'platform=macOS,arch=arm64' test
```

## Testing Requirements

### Required primary tests

The processor test suite is the main deliverable in this phase.

It should use:

- fake transcriber
- fake pipeline executor
- fake output executor
- fake dismiss controller
- real `ModeRuntimeState`

That gives behavior coverage without pinning tests to runtime adapter
internals.

The fake output executor should not need to own turn completion state. The
processor should be testable as the orchestrator of the single-shot turn.

If phase ownership moves out of
[OutputHandler.swift](/Users/bartosz/dev/Axii/Axii/Features/Mode/Runtime/OutputHandler.swift),
update [OutputHandlerTests.swift](/Users/bartosz/dev/Axii/AxiiIntegrationTests/OutputHandlerTests.swift)
so they assert output effects only, not single-shot turn completion.

### Required adapter-level coverage

You do not need a large new adapter suite.

But the remaining adapter/integration tests must still prove the runtime shell
correctly delegates the single-shot path and preserves the adapter-specific
behavior that intentionally remains outside the processor.

Acceptable adapter-level concerns:

- guard behavior when not recording
- post-stop cleanup like clearing recording helper / visualization state
- focus snapshot cleanup after processing completes
- media resume remaining in the adapter layer if you can verify it cleanly

Do not keep duplicated full behavior matrices at the adapter level.

### Behavior-not-implementation rule

Tests in this phase must prefer stable contracts over object layout.

Acceptable:

- processor input/output behavior
- observable state
- dismiss-controller interactions
- filtered pipeline-step behavior
- adapter cleanup behavior that remains truly adapter-owned

Not acceptable:

- `DispatchWorkItem` assertions
- tests tied to the exact body of `stopSimpleRecording()`
- tests that overfit to helper boundaries just because they are easy to write
- a large new suite that duplicates the same assertions through both processor
  and adapter paths

## Quality Bar

We are looking for:

- a clear single-shot execution seam
- a thinner runtime adapter
- narrow and justified abstractions
- tests that protect the extracted behavior contract
- no new hacks
- no accidental framework project

We are not looking for:

- "dictation coordinator" architecture
- generic recording infrastructure
- protocol scatter
- a new reducer/state machine architecture
- broad cleanup of conversation or meeting logic
- duplicated test suites

## Success Criteria

Use these as the practical success test for the phase, beyond the literal
acceptance checklist.

Phase 3A is successful if:

- a new engineer can identify a single obvious home for single-shot
  post-capture behavior
- the mode runtime still clearly owns capture start/stop and lifecycle
  concerns
- the primary single-shot behavior matrix is covered without `ModeFeature`
  internals
- `ModeFeatureRecording` is materially simpler than before
- the result makes Phase 3B feel like "apply the same pattern to multi-turn,"
  not "undo the wrong abstraction first"

## Risks

### Risk 1: The extraction becomes feature-centric instead of mode-centric

Mitigation:

- keep the processor named and shaped around the single-shot mode family
- avoid dictation-only naming or built-in-mode assumptions

### Risk 2: The phase turns into generic infrastructure work

Mitigation:

- cut at completed capture
- keep start/capture/session infrastructure in the adapter layer
- add only the seams Phase 3A actually needs

### Risk 3: Tests remain implementation-heavy even after extraction

Mitigation:

- processor tests become the main behavior matrix
- adapter tests shrink
- remove `DispatchWorkItem`-style assertions from the primary single-shot test
  bed

### Risk 4: Behavior drifts while the code gets "cleaner"

Mitigation:

- preserve current state model
- preserve current dismiss semantics
- preserve output behavior through the existing output model
- rely on the existing integration coverage while moving the main matrix into
  processor tests

## Acceptance Criteria

Phase 3A is complete only when all are true:

- a completed-capture seam exists for the single-shot path
- a dedicated single-shot mode turn processor exists
- `stopSimpleRecording()` is materially thinner and no longer owns the
  single-shot post-capture business flow inline
- the processor owns single-shot transcription/pipeline/output/dismiss/error
  orchestration
- turn-completion phase ownership is explicit in the processor layer rather
  than hidden inside the output collaborator
- the processor is covered by focused contract tests
- `DictationOrchestrationTests` no longer serves as the primary single-shot
  behavior matrix
- `deactivationWorkItem` assertions are gone from the primary single-shot test
  bed
- multi-turn and meeting behavior are not broadly refactored in this branch
- full `xcodebuild test` passes

## Commit Expectations

Use separate commits for:

- introducing the completed-capture seam and narrow execution boundaries
- adding the single-shot processor plus its focused tests
- wiring the processor into `ModeFeature` / `ModeFeatureRecording`
- shrinking or replacing the implementation-heavy dictation integration
  assertions
- any small comments or docs that clarify the new boundary

Do not squash everything into one commit.

## Report Back Format

When done, report back with:

1. branch name
2. commit list
3. exact files changed
4. the final completed-capture type introduced
5. the final single-shot processor type introduced
6. exact boundary interfaces added
7. exact tests added
8. exact existing tests removed or reduced
9. confirmation that the single-shot behavior matrix now lives primarily in
   processor tests
10. final test command used
11. any follow-up items intentionally deferred to Phase 3B

## Review Guidance

When this branch comes back for review, prioritize:

- whether the cut is truly at completed capture
- whether the processor is mode-family oriented rather than dictation-specific
- whether the adapter remained thin but real
- whether new abstractions are narrow and justified
- whether the primary single-shot behavior matrix moved into stable processor
  tests
- whether old implementation-pinned tests were actually reduced
- whether Phase 3B was kept out of scope
