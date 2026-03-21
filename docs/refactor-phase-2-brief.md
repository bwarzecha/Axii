# Phase 2 Execution Brief

This document is the authoritative contractor brief for Phase 2.

If this document conflicts with older phase numbering or stale current-state notes in other docs, follow this document and [docs/refactor-execution-plan.md](/Users/bartosz/dev/Axii/docs/refactor-execution-plan.md).

## Phase Name

Phase 2: Consolidate The App Shell To The Mode Runtime

## Starting Point

Start only after Phase 1 is merged to `main`.

As of the Phase 1 merge, the current `main` head is `fceabce`.

Branching:

- branch from current `main`
- branch name: `refactor/phase-2`
- we will review the branch directly
- keep commits clean and separated by workstream

## Purpose

Remove the remaining split runtime ownership in app startup and feature registration without changing user-visible behavior.

This is a structural consolidation phase, not a coordinator-extraction phase.

## Why This Phase Exists

The app shell now correctly treats the mode runtime as the active shipping path, but [AppController.swift](/Users/bartosz/dev/Axii/Axii/Core/AppController.swift) still carries legacy runtime construction and a dead branch:

- it still constructs:
  - `DictationFeature`
  - `ConversationFeature`
  - `MeetingFeature`
- it still has `useModeSystem` hardcoded to `true`
- it still carries a fallback registration branch for the legacy runtime
- it duplicates `ModeFeature` construction logic between:
  - `registerFeatures()`
  - `registerNewMode(_:)`

That leaves unnecessary complexity in the app shell and makes later refactors riskier than they need to be.

## Current Code Reality

These are the exact Phase 2 starting points:

- [AppController.swift](/Users/bartosz/dev/Axii/Axii/Core/AppController.swift)
  - legacy feature properties still exist at the top of the type
  - legacy features are still constructed in `init()`
  - `useModeSystem` is still present and hardcoded to `true`
  - `registerFeatures()` still has a legacy `else` branch
  - `registerNewMode(_:)` duplicates the `ModeFeature` construction path
- [AxiiApp.swift](/Users/bartosz/dev/Axii/Axii/AxiiApp.swift)
  - already uses the active mode runtime for menu bar status after Phase 1
  - should not need meaningful changes in this phase
- [FeatureManager.swift](/Users/bartosz/dev/Axii/Axii/Core/FeatureManager.swift)
  - already has the active-runtime status bridge after Phase 1
  - should not need broad changes in this phase
- Legacy runtime files still exist under:
  - [DictationFeature.swift](/Users/bartosz/dev/Axii/Axii/Features/Dictation/DictationFeature.swift)
  - [ConversationFeature.swift](/Users/bartosz/dev/Axii/Axii/Features/Conversation/ConversationFeature.swift)
  - [MeetingFeature.swift](/Users/bartosz/dev/Axii/Axii/Features/Meeting/MeetingFeature.swift)

## Goals

- remove legacy feature construction from the app shell
- remove the split registration path from the app shell
- make startup and runtime registration mode-only
- keep built-in Dictation, Conversation, and Meeting behavior unchanged
- make custom mode registration use the same construction path as startup registration

## Tenets

These are the principles for decision-making inside Phase 2.

1. Preserve behavior before improving structure.
   If a cleanup risks changing user-visible behavior, keep the existing behavior and defer the deeper refactor to a later phase.

2. One live app-shell runtime path.
   After this phase, startup and feature registration should clearly express that the mode runtime is the only live app-shell path.

3. Simplify, do not redesign.
   This phase should remove dead branching and duplicated wiring, not introduce a new runtime architecture.

4. One construction seam for `ModeFeature`.
   Startup registration and runtime custom-mode creation must share the same construction path.

5. Quarantine before deletion.
   Legacy runtime code should be clearly marked as inactive in the app shell before later phases delete it.

6. Evidence over assumption.
   Do not claim parity just because the code looks similar. Record explicit parity checks for built-in modes.

7. Leave Phase 3 easier, not harder.
   The result should make later coordinator extraction simpler by reducing app-shell ambiguity, not by pushing Phase 3 work forward early.

## Non-Goals

Do not:

- delete legacy runtime source files yet
- refactor dictation or conversation orchestration
- start coordinator extraction
- refactor `FeatureManager` broadly
- change `AppStatus`, `AppStatusSource`, or `PhaseStatusBridge` except for truly trivial cleanup
- change persisted schemas
- change mode runtime behavior
- add smoke automation
- redesign UI
- do Phase 3 work

## What Good Looks Like

At the end of a strong Phase 2 implementation:

- [AppController.swift](/Users/bartosz/dev/Axii/Axii/Core/AppController.swift) is visibly simpler and easier to explain.
- a reader can follow one clear path:
  - readiness checks pass
  - modes load from `ModeService`
  - `ModeFeature` instances are created
  - `FeatureManager` registers them
- there is no dead `useModeSystem` branch and no app-shell construction of legacy feature classes
- startup registration and `registerNewMode(_:)` obviously share the same `ModeFeature` construction logic
- [AxiiApp.swift](/Users/bartosz/dev/Axii/Axii/AxiiApp.swift) and [FeatureManager.swift](/Users/bartosz/dev/Axii/Axii/Core/FeatureManager.swift) need little or no change because the active runtime path is already correct there
- legacy runtime files are still present, but clearly marked as transitional and no longer part of the live app-shell path
- the parity checklist is concrete enough that another engineer can see what was checked and what was not
- the diff reads as disciplined removal of ambiguity, not broad cleanup churn

## Required Workstreams

### Workstream A: Remove Legacy Runtime Construction From AppController

Files:

- [AppController.swift](/Users/bartosz/dev/Axii/Axii/Core/AppController.swift)

Required changes:

1. Remove these legacy feature properties from `AppController`:
   - `dictationFeature`
   - `conversationFeature`
   - `meetingFeature`

2. Remove their construction from `init()`.

3. Remove `useModeSystem`.

4. Remove the dead legacy registration branch from `registerFeatures()`.

5. Make `registerFeatures()` unconditionally register mode-driven `ModeFeature` instances loaded from `ModeService`.

Important quality rule:

- this should be a simplification, not a redesign
- do not invent a new app-shell architecture here

### Workstream B: Centralize ModeFeature Construction

Files:

- [AppController.swift](/Users/bartosz/dev/Axii/Axii/Core/AppController.swift)

Problem:

`registerFeatures()` and `registerNewMode(_:)` currently duplicate `ModeFeature` construction and dependency wiring.

Required change:

- extract one small private helper that builds a `ModeFeature` from a `ModeConfig`

Suggested shape:

- `private func makeModeFeature(from config: ModeConfig) -> ModeFeature`

Required behavior:

- startup registration and runtime custom-mode registration must both use the same helper
- the dependency set must remain behaviorally identical to Phase 1
- do not move runtime logic out of `ModeFeature` in this phase

Why this matters:

- later phases need a single construction seam
- duplicating runtime construction in the app shell is avoidable risk

### Workstream C: Quarantine Legacy Runtime Code

Files:

- [DictationFeature.swift](/Users/bartosz/dev/Axii/Axii/Features/Dictation/DictationFeature.swift)
- [ConversationFeature.swift](/Users/bartosz/dev/Axii/Axii/Features/Conversation/ConversationFeature.swift)
- [MeetingFeature.swift](/Users/bartosz/dev/Axii/Axii/Features/Meeting/MeetingFeature.swift)

Required changes:

1. Add short file-header comments making clear:
   - these files are legacy/transitional
   - they are not part of the active app-shell execution path
   - they remain only for rollback safety and later deletion work

2. Do not restructure their internals in this phase.

3. Ensure no new references from app-shell/core files point back to these classes.

Important:

- quarantine, do not delete
- comment clarity is enough here; this is not the deletion phase

### Workstream D: Record Built-In Mode Parity Evidence

Required deliverable:

- add a small checked-in checklist file documenting parity spot checks for the built-in modes under the mode runtime

Suggested file:

- [docs/refactor-phase-2-parity-checklist.md](/Users/bartosz/dev/Axii/docs/refactor-phase-2-parity-checklist.md)

Required checklist coverage:

- Dictation
  - hotkey starts/stops correctly
  - panel behavior remains expected
  - output behavior remains expected
  - history behavior remains expected
- Conversation
  - hotkey behavior remains expected
  - conversation panel/session behavior remains expected
  - history behavior remains expected
- Meeting
  - hotkey/panel flow remains expected
  - save-to-history remains expected
  - attached audio recordings remain expected

What this is for:

- to prove the app shell can stop carrying legacy runtime ownership without behavior regressions

What this is not:

- not a new smoke harness
- not a full QA plan
- not a substitute for automated tests

## Testing Requirements

This phase is mostly structural simplification. Do not add brittle tests that pin private construction order or the exact internal shape of `AppController`.

### Required automated testing

1. Full suite must pass:

```bash
xcodebuild -project Axii.xcodeproj -scheme Axii -destination 'platform=macOS,arch=arm64' test
```

2. If you extract any new helper with stable behavior, add focused tests for that helper.

Examples of acceptable helper-level tests:

- a small pure helper used in Phase 2
- a narrow construction-plan helper if one is introduced

Examples of unacceptable tests:

- tests asserting the exact order of service construction in `AppController`
- tests asserting exact private property layout just because it is easy
- tests that pin later refactors to today’s object graph

### Required manual/parity evidence

The checked-in parity checklist is mandatory for this phase.

It should document what was checked and whether any mismatch was found.

If a blocker-level mismatch is found:

- stop
- document it clearly
- do not hide it by silently broadening scope

## Quality Bar

We are looking for:

- less app-shell complexity
- one live runtime path in startup and registration
- one construction path for `ModeFeature`
- no accidental behavior changes
- no new hacks
- no “temporary” logic that becomes permanent debt

We are not looking for:

- broad cleanup of unrelated code
- architecture exploration
- early coordinator extraction
- test suites that overfit implementation details

## Success Criteria

Use these as the practical success test for the phase, beyond the literal acceptance checklist.

Phase 2 is successful if:

- a new engineer can open [AppController.swift](/Users/bartosz/dev/Axii/Axii/Core/AppController.swift) and correctly conclude that the mode runtime is the only app-shell execution path
- there is only one obvious way `ModeFeature` instances get built in the app shell
- built-in Dictation, Conversation, and Meeting behavior still matches user expectations after consolidation
- no new test debt is introduced just to support the simplification
- Phase 3 can begin from a cleaner shell without first undoing Phase 2 shortcuts

## Risks

### Risk 1: Hidden behavior depends on legacy construction still occurring

This is the main Phase 2 risk.

Mitigation:

- keep the code diff narrow
- rely on the existing Phase 0/1 safety net
- complete the parity checklist

### Risk 2: Startup registration and runtime custom-mode registration drift apart

Mitigation:

- both paths must call the same helper

### Risk 3: Contractor broadens scope into Phase 3

Mitigation:

- no coordinator extraction
- no service abstraction expansion
- no runtime behavior redesign

## Acceptance Criteria

Phase 2 is complete only when all are true:

- `AppController` no longer constructs `DictationFeature`, `ConversationFeature`, or `MeetingFeature`
- `useModeSystem` is removed
- `registerFeatures()` has no legacy registration branch
- startup registration is mode-runtime-only
- runtime custom-mode registration uses the same `ModeFeature` construction path as startup registration
- legacy runtime files remain in repo but are clearly marked transitional
- no new app-shell/core references point to legacy feature classes
- full `xcodebuild test` passes
- the checked-in parity checklist exists and is complete

## Commit Expectations

Use separate commits for:

- removing legacy runtime construction and dead branching from `AppController`
- centralizing `ModeFeature` construction
- quarantining legacy runtime files with comments
- adding parity checklist documentation
- any tests for new stable helper logic

Do not squash everything into one commit.

## Report Back Format

When done, report back with:

1. branch name
2. commit list
3. exact files changed
4. whether `AppController` still constructs any legacy features
5. how `ModeFeature` construction is now centralized
6. exact checked-in parity checklist file added
7. whether any behavior mismatch was found during parity checks
8. final test command used
9. any remaining follow-up items for Phase 3

## Review Guidance

When this branch comes back for review, prioritize:

- any remaining app-shell references to legacy runtime
- any hidden behavior changes in startup/registration
- whether the construction helper is truly shared
- whether tests remain behavior-oriented rather than implementation-pinned
- whether the parity checklist is concrete enough to trust
