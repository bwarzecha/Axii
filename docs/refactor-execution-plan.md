# Axii Refactor Execution Plan

## Purpose

This document is the operational companion to [refactor-design.md](/Users/bartosz/dev/Axii/docs/refactor-design.md).

The design document explains the repository and recommends direction.

This execution plan answers a different question:

How do we change the codebase without breaking a currently working app that already has users and persisted state?

This plan is written to be executable by an engineer with no prior repository context.

## Executive Summary

The correct sequence is:

1. protect current behavior with migration fixtures and integration tests
2. fix active defects in the current runtime
3. consolidate the active runtime to the mode system without changing persisted user data formats unnecessarily
4. extract testable mode execution processors around the post-capture paths
5. decompose meeting orchestration carefully
6. only after the codebase is stable, add black-box smoke coverage for the real app behavior on a dedicated macOS environment

The first phase should not be architecture cleanup.

The first phase should be building a safety net around:

- persisted mode JSON
- persisted history JSON
- transcription/output/history pipelines
- the active runtime paths that already ship to users

## Non-Negotiable Constraints

These constraints should govern all implementation work.

### 1. Preserve existing user data

User data currently lives outside the repo in:

- `~/Library/Application Support/Axii/Modes`
- `~/Library/Application Support/Axii/history`
- `~/Library/Application Support/Axii/Models`
- `~/Library/Application Support/Axii/meeting_autosave.json`

No phase may casually rewrite or migrate user data on startup without explicit tests and rollback logic.

### 2. No schema changes without fixture coverage first

Before changing any persisted schema:

- collect fixture examples from the current format
- lock them into tests
- ensure the new code reads them successfully

### 3. No “big bang” refactor

Every phase must leave the app shippable.

Do not combine:

- test infrastructure
- schema changes
- runtime consolidation
- meeting pipeline rewrite

in a single change stream.

### 4. Prefer characterization before improvement

Where the current behavior is messy but working:

- capture it in tests
- then change the code

### 5. Hardware-dependent smoke tests are late-stage validation, not the first safety net

The first protection layer must be integration and fixture tests inside the repository.

## Default Assumptions

These assumptions are made so work can start without further decisions.

### Test framework

Use `XCTest` first.

Rationale:

- already aligned with Xcode
- best compatibility with app targets and future UI/smoke layering
- lowest setup friction

`Swift Testing` can be adopted later if desired, but should not block Phase 0.

### Test target structure

Create:

- `AxiiTests`
  Fast tests, fixtures, migrations, pure logic, and light integrations.
- `AxiiIntegrationTests`
  Temp-filesystem integration tests with real persistence and service wiring.

Do not create UI or smoke test targets yet unless a later phase requires them.

### Persistence strategy during refactor

Default strategy:

- maintain backward-compatible reads
- delay write-format changes unless there is a compelling reason
- if a write-format change becomes necessary, introduce explicit version-aware migration tests first

### Runtime direction

The long-term target remains the mode runtime:

- `ModeService`
- `ModeConfig`
- `ModeFeature`

The legacy feature runtime is considered transitional and should not receive major new behavior unless required for parity or emergency bug fixes.

## Delivery Model

Each phase below includes:

- goal
- why now
- entry criteria
- workstreams
- proof-of-concept tasks
- PR breakdown
- risks
- mitigations
- exit criteria

Progression rule:

- do not start the next phase until the previous phase exit criteria are met or consciously waived

## Phase 0: Safety Net And Characterization

## Goal

Build a trustworthy automated safety net around the current app behavior and persisted data before any structural refactor begins.

## Why this phase comes first

Without this phase:

- refactors can silently break user data compatibility
- current bugs and current intended behavior are indistinguishable
- every future phase becomes guesswork

## Entry Criteria

- repository builds locally on a machine with required dependencies
- contractor has access to the local `../AxiiDiarization` package

## Workstreams

### Workstream A: Make tests real in the project

#### Tasks

1. Add a real `AxiiTests` target to the Xcode project.
2. Add a real `AxiiIntegrationTests` target to the Xcode project.
3. Update the shared scheme so it references actual test targets.
4. Verify `xcodebuild test` works on the local development machine.

#### Files likely affected

- `Axii.xcodeproj/project.pbxproj`
- `Axii.xcodeproj/xcshareddata/xcschemes/Axii.xcscheme`
- new `AxiiTests/`
- new `AxiiIntegrationTests/`

#### Risks

- project file churn
- local dependency resolution issues
- scheme drift

#### Mitigations

- make this the first isolated PR
- do not mix code refactors into this PR

### Workstream B: Capture persisted-data fixtures

#### Tasks

1. Create fixture directories for:
   - built-in mode JSON
   - custom mode JSON
   - transcription history records
   - conversation history records
   - meeting history records
2. Source fixtures from:
   - current defaults
   - local development data
   - if possible, redacted real-world user data examples
3. Add README notes inside fixtures describing origin and expectations.

#### Recommended fixture layout

```text
AxiiTests/
  Fixtures/
    Modes/
      builtin-dictation-vcurrent.json
      builtin-conversation-vcurrent.json
      builtin-meeting-vcurrent.json
      custom-sample-vcurrent.json
    History/
      Transcription/
        metadata.json
        interaction.json
      Conversation/
        metadata.json
        interaction.json
      Meeting/
        metadata.json
        interaction.json
```

#### Risks

- fixtures may accidentally contain sensitive data
- fixtures may reflect only one machine’s state

#### Mitigations

- redact aggressively
- include both “generated from defaults” and “generated from saved app data” fixtures

### Workstream C: Add migration and decoding coverage

#### Tasks

1. Add tests that decode current `ModeConfig` fixtures.
2. Add tests that round-trip current `ModeConfig` fixtures.
3. Add tests that decode current history metadata fixtures.
4. Add tests that decode current history interaction fixtures.
5. Add tests that verify `Interaction.toMetadata()` still produces expected shapes.

#### Test cases

- `ModeService` can decode built-in dictation fixture
- `ModeService` can decode built-in conversation fixture
- `ModeService` can decode built-in meeting fixture
- `ModeService` can decode a sample custom mode fixture
- `HistoryService` model layer can decode transcription metadata fixture
- `HistoryService` model layer can decode transcription interaction fixture
- same for conversation
- same for meeting

#### Risks

- fixtures drift as code evolves

#### Mitigations

- treat fixture updates as deliberate changes that require review

### Workstream D: Add strong integration tests for active pipeline paths

#### Objective

Cover the most important working behavior in-process with real temp filesystem effects and minimal fakes only at hardware/network boundaries.

#### Priority targets

1. `PipelineRunner`
2. `OutputHandler`
3. `HistoryService`
4. `ModeService`
5. dictation result orchestration

#### Concrete test matrix

##### `PipelineRunner`

- no steps returns original context unchanged
- `segmentMerge` merges consecutive same-speaker segments
- `llmTransform` updates traveling text
- `llmTransform` stores labeled result when configured
- reserved label handling is validated if implemented later

##### `OutputHandler`

- display output writes `state.finalText`
- clipboard output executes without mutating unrelated state
- file output writes to the resolved temp path
- paste output handles:
  - pasted
  - pastedAndCopied
  - copiedOnly
  - copiedFallback
  - needsManualCopy
  - skipped
- history output writes transcription and optional audio metadata correctly

##### `HistoryService`

- save transcription creates folder, metadata, interaction JSON
- load transcription round-trips accurately
- save conversation round-trips accurately
- save meeting round-trips accurately
- save compressed audio creates audio file and metadata
- delete removes folder and cache entry
- list metadata sorts newest first

##### `ModeService`

- built-in modes are created if absent
- custom mode save/load/delete works
- reset-to-default restores built-in mode content
- migration strips unknown processing steps as intended

##### Dictation orchestration

Test the active mode dictation path, but replace only the outer hardware boundaries:

- fake recorder output samples
- fake transcriber result text
- fake paste service outcomes

Everything else should be real enough to assert state transitions and history/output effects.

Recommended cases:

- transcription success -> file/history output success
- empty transcription -> done/no speech path
- paste needs manual copy -> manual copy state set, no auto-dismiss
- paste copied fallback -> expected user-visible text and state
- transcription error -> error state and deactivation scheduling

#### Risks

- too much mocking lowers confidence
- too little isolation makes tests flaky

#### Mitigations

- fake only microphone/audio-model boundaries first
- use real temp directories for filesystem outputs
- avoid timing-sensitive assertions where possible

### Workstream E: Add minimal testability enablers for real integration tests

These are not debug-only switches. They are constructor-level seams required to make integration testing safe and deterministic.

#### Objective

Allow tests to run against isolated temp storage and controlled dependencies without touching real user data.

#### Required enablers

1. `HistoryService` should support an injected base directory or storage root.
2. `ModeService` should support an injected modes directory or storage root.
3. `SettingsService` already supports injected `UserDefaults`; tests should use a temporary suite.
4. `FileOutputService` tests should always write into temp paths.
5. If dictation orchestration is tested before processor extraction, fake transcriber/paste boundaries should be injected through production-safe protocols or closures, not global flags.

#### Rule

Prefer dependency injection over launch flags in this phase.

These changes should improve production code quality as well. They should not create alternate debug-only business logic.

#### Risks

- enabler work can accidentally turn into a broad architecture rewrite

#### Mitigations

- keep enablers narrow and constructor-based
- do not redesign service APIs beyond what tests require right now

### Workstream F: Record current defects as tests

This is important. Not all failing current behavior should be treated as future “unknown regressions”.

#### Known current issue to codify

Active meeting save path bug:

- `ModeFeatureMeeting.saveMeetingToHistory` saves audio files but discards the returned `AudioRecording` values instead of attaching them back to the `Meeting`.

#### Task

Add a failing or quarantined regression test that captures the intended correct behavior before fixing the bug.

## Proof-of-Concept Tasks

These are small spikes to validate the plan before wider implementation.

### POC 0.1: Can tests use temp persistence safely?

Goal:

- prove that `HistoryService` can be adapted or wrapped for temp-directory testing without global side effects

Success condition:

- an integration test writes and loads a transcription entirely in a temporary root

Additional success signal:

- the same pattern is clearly reusable for `ModeService`

### POC 0.2: Can the active dictation flow be integration-tested with only hardware boundaries faked?

Goal:

- prove that orchestration can be exercised without a real microphone or model load

Success condition:

- one integration test drives dictation success from fake samples/transcript to real history/file output

### POC 0.3: Can fixture decoding catch a real compatibility break?

Goal:

- intentionally alter a local branch of a fixture shape and confirm tests fail

Success condition:

- demonstrates the fixture suite provides real compatibility protection

## PR Breakdown

Recommended PR sequence:

### PR 0A

- add real test targets
- fix scheme
- add test folder structure

### PR 0B

- add fixtures
- add decoding and migration tests

### PR 0C

- add `HistoryService`, `ModeService`, `PipelineRunner`, `OutputHandler` integration tests

### PR 0D

- add dictation orchestration integration tests
- add meeting save regression test

No architecture refactor should begin until PR 0C is merged. Prefer PR 0D as well.

## Exit Criteria

Phase 0 is complete only when all are true:

- real test targets exist and run in Xcode/CLI
- current persisted data formats are captured in fixtures
- migration/decode tests are passing
- integration tests cover the active transcription/output/history paths
- known active bug behavior is either tested and fixed or explicitly quarantined

## Phase 1: Fix Current Runtime Hazards Without Major Structural Change

## Goal

Address the highest-risk current runtime issues while keeping the architecture largely intact.

## Why this phase exists

There are problems that should be fixed before broader runtime consolidation:

- UI reading inactive state
- meeting history save bug
- project confusion around live vs legacy paths

Fixing these early reduces noise in later phases.

## Entry Criteria

- Phase 0 exit criteria met

## Workstreams

### Workstream A: Fix active meeting history save bug

#### Tasks

1. Update `ModeFeatureMeeting.saveMeetingToHistory` so saved audio metadata is reattached to the final `Meeting`.
2. Ensure the final `Meeting` is saved with `micRecording` and `systemRecording`.
3. Verify history detail playback works for newly recorded meetings.

#### Risks

- meeting persistence assumptions may differ between legacy and mode paths

#### Mitigations

- compare saved outputs between old `MeetingFeature` and active `ModeFeatureMeeting`
- rely on the Phase 0 regression test

### Workstream B: Remove UI dependence on inactive runtime state

#### Tasks

1. Replace menu bar state sourcing from legacy dictation state.
2. Define a current-app status source aligned with the active mode system.
3. Keep menu bar status behavior minimal and reliable.

#### Risks

- menu bar status semantics may be ambiguous across multiple modes

#### Mitigations

- choose a narrow rule:
  - show generic “Ready/Recording/Processing/Error” for the active mode
  - do not attempt rich per-mode state in this phase

### Workstream C: Improve runtime-path clarity

#### Tasks

1. Add comments or documentation pointers in:
   - `AppController`
   - `AxiiApp`
   - `ModeFeature`
2. Mark legacy feature classes as transitional.
3. Avoid new behavior additions in legacy classes unless required.

## Proof-of-Concept Tasks

### POC 1.1: Confirm active mode path is the only shipping path used in practice

Goal:

- verify there is no shipping user-visible surface still functionally dependent on legacy runtimes after the menu bar fix

Success condition:

- legacy classes can be left untouched during normal user operation without changing app behavior

## PR Breakdown

### PR 1A

- meeting history bug fix
- tests

### PR 1B

- menu bar status source fix
- tests and small docs/comments

## Exit Criteria

- active meeting save bug fixed
- menu bar no longer depends on legacy dictation state
- live runtime path is clearly documented in code

## Phase 2: Consolidate The App Shell To The Mode Runtime

Authoritative contractor brief:

- [docs/refactor-phase-2-brief.md](/Users/bartosz/dev/Axii/docs/refactor-phase-2-brief.md)

## Goal

Remove split runtime ownership in app startup and registration while preserving existing user behavior.

## Why not earlier

This phase is structural. It should happen only after current behavior is protected and current defects are fixed.

## Entry Criteria

- Phase 1 complete

## Workstreams

### Workstream A: Stop constructing unnecessary legacy runtime objects

#### Tasks

1. Identify where legacy feature instances are still created.
2. Remove construction of unused legacy runtimes from `AppController`.
3. Ensure feature registration only occurs via the mode runtime.

### Workstream B: Validate mode runtime parity for built-in modes

#### Tasks

1. Characterize built-in Dictation behavior under mode runtime.
2. Characterize built-in Conversation behavior under mode runtime.
3. Characterize built-in Meeting behavior under mode runtime.
4. Compare against legacy implementations only where needed to confirm parity.

#### Deliverable

A small parity checklist in the repo or PR description covering:

- hotkey behavior
- panel behavior
- output behavior
- history behavior

### Workstream C: Quarantine legacy code

#### Tasks

1. Mark legacy runtime files as deprecated/transitional.
2. Ensure no new references are introduced.
3. Optionally gate deletion until later phases.

## Risks

- hidden behavior parity gaps between legacy and mode paths
- menu/status/settings references that still assume legacy state types

## Mitigations

- rely on parity checklist
- merge this phase in narrow PRs
- do not delete legacy code yet if parity is not proven

## Proof-of-Concept Tasks

### POC 2.1: Build-in mode parity spot checks

Goal:

- verify that dictation and conversation are already close enough in mode runtime to consolidate safely

Success condition:

- no blocker-level behavior mismatch found for daily usage flows

## PR Breakdown

### PR 2A

- app shell uses mode runtime only
- no deletions yet

### PR 2B

- quarantine legacy code
- remove dead references

## Exit Criteria

- app shell and feature registration depend only on the mode runtime
- legacy classes are no longer part of the live execution path

## Phase 3: Extract Testable Mode Turn Processors

Authoritative execution brief:

- [docs/refactor-phase-3a-brief.md](/Users/bartosz/dev/Axii/docs/refactor-phase-3a-brief.md)

Architectural design reference:

- [docs/refactor-phase-3a-design.md](/Users/bartosz/dev/Axii/docs/refactor-phase-3a-design.md)

## Goal

Move the single-shot and multi-turn post-capture execution logic out of
`ModeFeatureRecording` and related runtime glue into explicit, testable mode
turn processors.

## Why this phase matters

This is where testability materially improves.

Without this phase:

- single-shot and multi-turn mode execution remain `@MainActor`
  orchestration blobs with side effects mixed into state changes

## Entry Criteria

- Phase 2 complete

## Target outcome

Introduce execution-path abstractions such as:

- `SingleShotModeTurnProcessor`
- `MultiTurnModeTurnProcessor`

These names are suggestions, not mandatory final API.

The important design rule is that these abstractions represent mode execution
families, not built-in-feature UI coordinators.

## Workstreams

### Workstream A: Define boundary interfaces and the completed-capture seam

#### Tasks

Define narrow interfaces for the boundaries actually needed by the post-capture
execution path:

- transcriber
- output executor
- scheduler/deactivation
- pipeline executor
- conversation/history store for multi-turn execution
- a small `CompletedCapture` boundary object

#### Rule

Do not protocolize the whole app. Only abstract the edges this phase needs.

### Workstream B: Extract single-shot execution flow first

#### Tasks

1. Extract the single-shot post-capture path into a dedicated processor.
2. Move success/failure/manual-copy/dismiss handling out of `ModeFeatureRecording`.
3. Keep `ModeFeature` as the runtime adapter that owns capture start/stop,
   panel wiring, and feature lifecycle.

#### Test coverage

- success flow
- empty transcription
- paste failure copy fallback
- manual copy required
- transcription error
- cancel during active recording

### Workstream C: Extract multi-turn execution flow

#### Tasks

1. Move transcription-to-LLM/session orchestration into its own processor.
2. Keep `ConversationHandler` only if it remains a narrow collaborator;
   otherwise absorb it into the processor.
3. Preserve multi-turn history behavior.

#### Test coverage

- first turn
- continuation turn with prior history
- history-disabled behavior
- provider failure

## Risks

- too much abstraction can slow delivery
- processor extraction may accidentally change panel behavior
- the code may drift back toward feature-specific abstractions instead of
  mode-family execution paths

## Mitigations

- preserve current state model at first
- keep adapters thin
- assert state transition sequences in tests before changing UI representations
- keep the architectural cut at the completed-capture seam, not the generic
  capture/session layer

## Proof-of-Concept Tasks

### POC 3.1: Extract only the single-shot execution family first

Goal:

- validate the mode-turn processor pattern on the smallest high-value runtime
  path

Success condition:

- single-shot mode processor exists with meaningful coverage
- `ModeFeatureRecording` becomes thinner without functional regressions

## PR Breakdown

### PR 3A

- boundary interfaces
- single-shot mode processor
- tests

### PR 3B

- multi-turn mode processor
- tests

## Exit Criteria

- single-shot and multi-turn post-capture execution are processor-based
- integration and state-transition tests cover the main behavior matrix
- `ModeFeatureRecording` is materially simpler

## Phase 4: Decompose Meeting Orchestration

## Goal

Reduce the meeting pipeline from a large orchestration hotspot into smaller collaborators that can be reasoned about and tested independently.

## Why this phase is late

Meeting mode is the highest complexity path and carries the most platform risk.

It should be approached only after the test strategy and simpler runtime patterns are established.

## Entry Criteria

- Phase 3 complete

## Target decomposition

The exact split can vary, but the responsibilities should no longer be concentrated in one handler.

Suggested collaborators:

- `MeetingStartCoordinator`
  permission checks and start flow
- `MeetingCaptureSession`
  owns active capture and chunk routing
- `MeetingFinalizeService`
  stop/finalize/segment assembly/diarization orchestration
- `MeetingPersistenceService`
  writes final meetings and audio
- `SpeakerProfileUpdateService`
  enrichment and profile creation

## Workstreams

### Workstream A: Freeze current behavior with tests

Before decomposition, add or strengthen tests for:

- start permission gating
- stop/save flow
- autosave recovery
- speaker merge logic
- history persistence

### Workstream B: Split finalization and persistence first

This is the highest-value first cut because it reduces complexity without destabilizing live capture immediately.

#### Tasks

1. Move meeting save logic into dedicated persistence service.
2. Move diarization finalization and segment assembly into dedicated finalize service.
3. Keep `MeetingPipelineHandler` as a coordinator temporarily.

### Workstream C: Split start/capture flow

#### Tasks

1. Isolate permission/start concerns.
2. Isolate session lifecycle and chunk routing.
3. Preserve autosave and crash recovery behavior.

## Risks

- hidden coupling between capture, transcript manager, and state object
- timing/race issues during stop and finalize
- regressions in autosave/crash recovery

## Mitigations

- split by responsibility, not by arbitrary file size
- land decomposition in multiple PRs
- keep existing data contracts until coverage is strong

## Proof-of-Concept Tasks

### POC 4.1: Extract persistence first

Goal:

- verify that one part of meeting logic can be moved without destabilizing capture

Success condition:

- meeting persistence is owned by a dedicated service with passing regression tests

## PR Breakdown

### PR 4A

- meeting persistence extraction
- tests

### PR 4B

- finalize service extraction
- tests

### PR 4C

- start/capture coordinator split
- tests

## Exit Criteria

- meeting orchestration is split across narrow collaborators
- stop/finalize/persist behavior has reliable integration coverage
- crash recovery still works

## Phase 5: Move Behavior Out Of Heavy Views

## Goal

Reduce logic embedded directly in SwiftUI views, starting with the heaviest views.

## Entry Criteria

- runtime refactor phases are complete enough that UI changes are not fighting core orchestration changes

## Workstreams

### Workstream A: History detail presentation extraction

#### Tasks

1. Move loading/deletion/copy/playback orchestration out of `HistoryDetailView`.
2. Introduce a view model or action handler.
3. Keep the SwiftUI view mostly declarative.

### Workstream B: Evaluate other heavy views

Candidates:

- `HistoryView`
- settings mode editor flows if save logic remains too embedded

## Risks

- accidental UI regressions
- too much churn for modest value

## Mitigations

- only extract where logic materially complicates maintenance or testing
- do not refactor “average” views just for consistency

## Exit Criteria

- `HistoryDetailView` and other chosen heavy views are thinner and easier to test

## Phase 6: Delete Legacy Runtime And Finalize Tooling

## Goal

Remove no-longer-needed legacy code and align project documentation/tooling with the final architecture.

## Entry Criteria

- mode runtime is the sole live runtime
- parity is proven

## Workstreams

### Workstream A: Delete legacy runtime code

Delete only after:

- no remaining live references
- parity checklist complete
- integration coverage protects current behavior

### Workstream B: Rewrite docs to match reality

Update:

- `TESTING.md`
- architecture notes
- contractor handoff docs as needed

### Workstream C: Optional black-box smoke foundation

This is the right phase to begin real-machine smoke infrastructure if desired.

Scope:

- dedicated test machine or dedicated macOS user
- isolated environment
- virtual audio device
- real app launch
- real hotkey trigger
- output file/history assertions

## Risks

- deleting legacy code too early removes a useful reference implementation

## Mitigations

- defer deletion until after all major runtime extraction is complete

## Exit Criteria

- one runtime architecture remains
- docs and tooling reflect the actual system

## Cross-Phase Risk Register

## Risk 1: Breaking persisted user data

### Impact

Very high.

### Mitigation

- fixture coverage before schema changes
- backward-compatible reads first
- no automatic rewrites without tests

## Risk 2: Regressing currently working dictation flow

### Impact

High.

### Mitigation

- dictation integration tests before processor extraction
- narrow PRs

## Risk 3: Meeting regressions are hard to notice until late

### Impact

Very high.

### Mitigation

- regression tests around save/finalize
- dedicated meeting decomposition phase
- preserve crash recovery coverage

## Risk 4: Test effort drifts into too much mocking

### Impact

Medium.

### Mitigation

- use real temp filesystems
- fake only hardware/model/network edges

## Risk 5: App shell consolidation reveals hidden parity gaps

### Impact

Medium to high.

### Mitigation

- parity checklist
- menu/status fixes before deletions

## Rollback Strategy

Every phase should be mergeable and reversible independently.

### Rules

- keep PRs narrow
- avoid combining data-format changes with architecture changes
- if a phase reveals major regression risk, stop and restore the previous stable runtime path

### Specific rollback guidance

- Phase 0 failures:
  revert test-infra PRs independently from any runtime PR
- Phase 1 failures:
  revert bugfixes or menu status changes independently
- Phase 2/3 failures:
  keep adapter layers so old orchestration can be reinstated temporarily

## Recommended Timeline Shape

These are not exact duration commitments, but realistic sequencing guidance.

### Phase 0

Largest uncertainty reduction. Should be completed before architecture work.

### Phase 1

Short, high-value stabilizing phase.

### Phase 2

Moderate complexity. Good first “real refactor” phase.

### Phase 3

Moderate to high complexity. Dictation first, then conversation.

### Phase 4

Highest complexity phase. Should be broken into several PRs and possibly sub-milestones.

### Phase 5 and 6

Cleanup, polish, and finalization once the hard runtime work is done.

## Immediate Next Actions

If work starts now, the first concrete steps should be:

1. Create `AxiiTests` and `AxiiIntegrationTests` targets.
2. Add fixture folders and sample mode/history fixtures.
3. Write fixture decode tests.
4. Write `HistoryService` integration tests with temp storage.
5. Write `PipelineRunner` and `OutputHandler` integration tests.
6. Add the meeting-save regression test.

Do not start with:

- schema rewrites
- mode runtime deletion of legacy code
- UI testing
- hardware smoke testing

## Definition Of “Executable Plan”

This plan should be considered executable when an engineer can do all of the following without extra product interpretation:

- identify which phase they are working in
- know the entry criteria for that phase
- know which workstreams and PRs belong to that phase
- know which tests must exist before proceeding
- know the main risks and mitigations

This document is intended to meet that standard.
