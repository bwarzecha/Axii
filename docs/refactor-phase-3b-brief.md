# Phase 3B Execution Brief

This document is the authoritative contractor brief for Phase 3B.

If this document conflicts with older roadmap wording or stale references to
"conversation coordinators," follow this document and
[docs/refactor-execution-plan.md](/Users/bartosz/dev/Axii/docs/refactor-execution-plan.md).

## Phase Name

Phase 3B: Extract The Multi-Turn Mode Turn Processor

## Starting Point

Start only after Phase 3A is merged to `main`.

Branching:

- branch from current `main`
- branch name: `refactor/phase-3b`
- we will review the branch directly
- keep commits clean and separated by workstream

## Purpose

Move the multi-turn post-capture execution path out of
[ModeFeatureRecording.swift](/Users/bartosz/dev/Axii/Axii/Features/Mode/Runtime/ModeFeatureRecording.swift)
and the mixed
[ConversationHandler.swift](/Users/bartosz/dev/Axii/Axii/Features/Mode/Runtime/ConversationHandler.swift)
helper into an explicit, testable multi-turn mode processor plus a narrow
conversation-session persistence collaborator.

This is the second architecture-heavy refactor phase. The bar remains high.

## Why This Phase Exists

After Phase 3A:

- single-shot mode execution has a clear processor seam
- `CompletedCapture` already exists as the correct adapter-to-processor boundary
- the remaining post-capture complexity hotspot is the multi-turn path

Right now, the multi-turn path is still split awkwardly:

- `ModeFeatureRecording.stopAndProcessMultiTurn()` owns transcription,
  empty-result handling, live-transcript update, phase changes, and
  conversation-flow branching
- `ConversationHandler` owns display-message projection, persisted-session
  identity, history writes, message-history loading, and LLM call-shape choice

That split is not the final architecture.

One important constraint:

- the current multi-turn path is not driven by `OutputHandler` or the generic
  single-shot output model
- Phase 3B should not broaden into "make conversation use the generic output
  pipeline"

## Current Code Reality

These are the exact Phase 3B starting points:

- [ModeFeatureRecording.swift](/Users/bartosz/dev/Axii/Axii/Features/Mode/Runtime/ModeFeatureRecording.swift)
  - `stopAndProcessMultiTurn()` still owns the multi-turn post-capture path
- [ConversationHandler.swift](/Users/bartosz/dev/Axii/Axii/Features/Mode/Runtime/ConversationHandler.swift)
  - currently mixes state mutation, persistence, and LLM policy
- [ModeFeature.swift](/Users/bartosz/dev/Axii/Axii/Features/Mode/Runtime/ModeFeature.swift)
  - still routes hotkeys and owns cancel/deactivate state cleanup
- [CompletedCapture.swift](/Users/bartosz/dev/Axii/Axii/Features/Mode/Runtime/CompletedCapture.swift)
  - already exists and should be reused
- [ModeExecutionBoundaries.swift](/Users/bartosz/dev/Axii/Axii/Features/Mode/Runtime/ModeExecutionBoundaries.swift)
  - Phase 3A seams exist and may be extended narrowly if needed

## Goals

- introduce a dedicated processor for the multi-turn post-capture execution
  family
- replace the current mixed `ConversationHandler` abstraction with a narrower
  conversation-session store or equivalent narrow collaborator
- keep `ModeFeature` / `ModeFeatureRecording` as the runtime adapter
- make multi-turn behavior primarily testable through processor contract tests
- make session persistence/context behavior primarily testable through store
  tests
- return session cleanup on cancel/deactivate to the runtime shell
- remove the dead playback dependency from the mode runtime if it is no longer
  needed

## Tenets

These are the principles for decision-making inside Phase 3B.

1. Preserve the mode design.
   This phase is about multi-turn mode execution, not about reintroducing a
   conversation-specific feature architecture.

2. Reuse the completed-capture seam.
   Do not invent a second cut point for multi-turn execution.

3. Keep execution policy in the processor.
   The processor should own the turn flow. Narrow collaborators should support
   it, not hide it.

4. Make session persistence explicit.
   Persisted-session identity and LLM context loading must be obvious in the
   design and in the tests.

5. Preserve current runtime behavior first.
   Do not silently change history-disabled behavior, error behavior, or panel
   completion behavior during this extraction.

6. Do not force multi-turn into the single-shot execution model.
   Extract it cleanly, but do not normalize it into the single-shot generic
   output/pipeline architecture in this phase.

7. Remove dead dependencies rather than carrying them forward.
   If `AudioPlaybackService` is no longer used, remove it from the mode runtime
   path.

8. Keep the test suite layered.
   Processor behavior, session-store behavior, and runtime-adapter behavior
   should not be collapsed into one giant integration suite.

## Non-Goals

Do not:

- change the current history-disabled semantics
- route multi-turn execution through `OutputHandler` or the single-shot generic
  output path
- redesign the multi-turn phase model unless strictly necessary to preserve the
  current runtime contract
- normalize the full `LLMTransformConfig` feature set for multi-turn modes
- redesign the conversation panel UI
- merge single-shot and multi-turn into a generic base processor
- refactor meeting mode
- redesign `ModeRuntimeState` broadly
- introduce TTS or conversation playback work
- build a generic chat/session framework
- change persisted schemas
- do Phase 4 work

## What Good Looks Like

At the end of a strong Phase 3B implementation:

- `stopAndProcessMultiTurn()` is obviously adapter code
- multi-turn turn execution clearly lives in one processor
- session persistence/context loading clearly lives in one narrow collaborator
- runtime session cleanup on cancel/deactivate is no longer hidden inside a
  helper that also owns persistence and LLM behavior
- the runtime no longer carries an unused playback dependency
- processor tests are the main source of truth for multi-turn turn behavior
- store tests are the main source of truth for persisted-session semantics
- adapter tests are limited to real adapter concerns

## User-Visible Invariants To Preserve

These behaviors must remain true after Phase 3B:

- empty transcription produces no visible turn and dismisses after 2 seconds
- successful conversation turns keep the panel open
- the panel still accumulates messages for the active in-memory session
- `state.liveTranscript` still reflects the current user utterance
- `state.finalText` still reflects the latest assistant response
- continuation turns use persisted message history when history is enabled
- when history is disabled, the UI still accumulates messages but LLM requests
  remain per-turn `send(message:)` calls
- multi-turn execution remains display/session/history-driven in this phase
  rather than being rerouted through the single-shot generic output model
- provider/transcription errors still surface as `.error(...)` in the panel
- failure to persist the assistant reply after a successful response does not
  fail the visible turn

## Likely Files

Existing files likely to change:

- [ModeFeatureRecording.swift](/Users/bartosz/dev/Axii/Axii/Features/Mode/Runtime/ModeFeatureRecording.swift)
- [ModeFeature.swift](/Users/bartosz/dev/Axii/Axii/Features/Mode/Runtime/ModeFeature.swift)
- [ConversationHandler.swift](/Users/bartosz/dev/Axii/Axii/Features/Mode/Runtime/ConversationHandler.swift)
- [ModeRuntimeState.swift](/Users/bartosz/dev/Axii/Axii/Features/Mode/Runtime/ModeRuntimeState.swift)
- [AppController.swift](/Users/bartosz/dev/Axii/Axii/Core/AppController.swift)

New files likely to be introduced:

- `Axii/Features/Mode/Runtime/MultiTurnTurnConfig.swift`
- `Axii/Features/Mode/Runtime/MultiTurnModeTurnProcessor.swift`
- `Axii/Features/Mode/Runtime/ConversationSessionStore.swift`
- `AxiiTests/MultiTurnModeTurnProcessorTests.swift`
- `AxiiIntegrationTests/ConversationSessionStoreTests.swift`
- `AxiiIntegrationTests/MultiTurnOrchestrationTests.swift`

Guidance on location:

- keep multi-turn runtime types near the mode runtime
- do not dump Phase 3B-specific abstractions into a generic cross-app folder
  unless they are truly shared outside the mode runtime

## Required Workstreams

### Workstream A: Define The Multi-Turn Boundaries

Required changes:

1. Reuse `CompletedCapture` as the input seam.

2. Introduce a narrow `MultiTurnTurnConfig`.

Expected scope:

- the chosen multi-turn `LLMTransformConfig`

Do not pass the full `ModeConfig` unless you can justify why the narrower
snapshot would be incorrect.

3. Add only the narrow boundaries Phase 3B actually needs.

Expected seams:

- existing `TranscriptionProviding`
- a narrow response-generation boundary around `LLMService`
- a narrow conversation-session persistence boundary
- existing `ModeDismissControlling` if needed for empty-turn dismiss behavior

Suggested examples:

```swift
protocol ConversationResponding {
    func send(message: String) async throws -> String
    func send(messages: [Message]) async throws -> String
}

protocol ConversationSessionStoring {
    func beginTurn(
        userText: String,
        currentSessionId: UUID?
    ) async throws -> PreparedConversationTurn

    func appendAssistantReply(
        sessionId: UUID,
        text: String
    ) async
}
```

Do not add broad "future-proof" abstractions for chat tools, playback, or
generic session engines.

### Workstream B: Extract The Multi-Turn Processor

Required changes:

1. Introduce `MultiTurnModeTurnProcessor`.

2. Move the multi-turn post-capture business flow into that processor.

That includes:

- transcription after capture stop
- empty transcription handling
- updating `state.liveTranscript`
- appending user/assistant display messages
- calling into the session store
- choosing between `send(message:)` and `send(messages:)`
- updating `state.currentSessionId`
- setting `state.finalText`
- mapping success/error outcomes into `state.phase`
- scheduling dismiss only for the empty-turn path

3. Keep `ModeFeatureRecording` as the runtime adapter.

It should still own:

- recording helper stop/cleanup
- visualization cleanup
- capture start/stop wiring
- runtime activation/deactivation semantics

4. Do not leave the real turn policy hidden in a collaborator.

The processor should remain the clear owner of execution policy.

### Workstream C: Replace The Mixed `ConversationHandler`

Required changes:

1. Do not keep `ConversationHandler` in its current mixed form.

Acceptable outcomes:

- replace it with a narrow `ConversationSessionStore`
- or absorb its useful pieces into new processor/store types and delete it

Not acceptable:

- keeping a renamed `ConversationHandler` that still mutates runtime state,
  owns session cleanup, and chooses LLM policy

2. Return session cleanup to the runtime shell.

After extraction, cancel/deactivate should clear:

- `state.messages`
- `state.currentSessionId`
- `state.liveTranscript`
- `state.finalText`

This may live in a small `ModeFeature` helper or a tiny `ModeRuntimeState`
helper, but it should not stay hidden on the session collaborator.

3. Remove dead playback dependency if possible.

If `AudioPlaybackService` is no longer used anywhere in the mode runtime path,
remove it from the construction chain rather than carrying it forward unused.

### Workstream D: Add The Right Tests

Required processor tests:

- first turn with history enabled uses `send(message:)`
- continuation turn with prior persisted messages uses `send(messages:)`
- history-disabled mode remains stateless from the LLM's perspective
- empty transcription produces `.done` and schedules dismiss
- transcription failure produces `.error(...)` and does not schedule dismiss
- provider failure produces `.error(...)` and does not schedule dismiss
- assistant-persistence failure does not fail an otherwise successful turn
- `state.messages` projection is correct
- `state.currentSessionId` updates correctly

Required store tests:

- first turn creates a persisted conversation and returns messages
- continuation turn appends the user message and returns updated messages
- history-disabled mode returns no session id and no persisted messages
- assistant append failure is swallowed/logged and does not throw outward

Required adapter tests:

- `stopAndProcessMultiTurn()` delegates a completed capture into the processor
- recording-helper / visualization cleanup remains adapter-owned
- cancel/deactivate clears multi-turn runtime session state
- guard behavior when not recording remains intact

Important:

- do not duplicate the full multi-turn behavior matrix at the adapter layer
- do not pin tests to private task structure or helper decomposition

## Design-For-Refactor Requirement

Implement this phase so later refactors do not require major test rewrites.

Specifically:

- processor tests must target stable turn behavior, not the exact helper
  decomposition
- store tests must target persistence/session contracts, not internal
  implementation storage details
- adapter tests must target runtime-shell concerns only
- avoid tests that pin exact callback ordering or task structure unless that is
  the user-visible contract

## Success Criteria

Phase 3B is successful when all of the following are true:

- multi-turn post-capture execution is owned by a dedicated processor
- persisted-session behavior is owned by a narrow collaborator, not a mixed
  helper
- the runtime shell owns conversation session cleanup on cancel/deactivate
- the main multi-turn behavior matrix lives in processor tests
- persisted-session semantics live in store tests
- `ModeFeatureRecording` is materially thinner
- dead playback dependency is removed if it is no longer used

## Acceptance Criteria

This phase is complete only when all are true:

- `stopAndProcessMultiTurn()` is reduced to adapter concerns plus delegation
- `ConversationHandler` no longer exists in its current mixed form
- there is a dedicated multi-turn processor
- there is a dedicated session-store collaborator or equivalent narrow
  persistence abstraction
- processor tests cover first turn, continuation turn, history-disabled
  behavior, empty transcription, and provider/transcription failure
- store tests cover create/append/history-disabled behavior
- adapter tests cover cleanup/delegation only
- runtime cleanup on cancel/deactivate no longer depends on the old handler
- no broad framework or generic chat engine was introduced
- full test suite passes

## Commit Expectations

Use separate commits for:

- boundary definitions / config snapshot
- session-store extraction
- multi-turn processor extraction
- runtime adapter rewiring / cleanup ownership
- processor tests
- store tests
- adapter test updates
- dead dependency removal if applicable

Do not squash everything into one commit.

## Report Back Format

When done, report back with:

1. branch name
2. commit list
3. exact files changed
4. exact new processor/store types introduced
5. whether `ConversationHandler` was removed or fully replaced
6. how session cleanup is now owned
7. whether `AudioPlaybackService` was removed from the mode runtime path
8. exact tests added or changed
9. final test command used
10. any remaining risks or intentionally deferred items

If you hit a blocker that would force a broader conversation-framework refactor,
stop and report it instead of broadening scope.
