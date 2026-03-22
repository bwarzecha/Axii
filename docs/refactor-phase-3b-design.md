# Phase 3B Design: Multi-Turn Mode Turn Processor

## Status

Draft design for the second half of Phase 3.

This document exists to answer a narrower question than the overall roadmap:

How do we extract the multi-turn post-capture execution path out of the mode
runtime without weakening the mode design, papering over conversation-session
semantics, or turning the app into a framework project?

## Executive Summary

Phase 3B should reuse the same completed-capture seam introduced in Phase 3A,
but it should not treat multi-turn execution as "single-shot plus extra UI."

The right cut is to extract a dedicated `MultiTurnModeTurnProcessor` for the
multi-turn mode family, backed by a narrow `ConversationSessionStore`
collaborator.

That processor is not a conversation-panel abstraction and not a built-in
feature abstraction. It is a post-capture execution processor for a mode family
whose defining characteristics are:

- one completed capture per turn
- persistent session/history context when history is enabled
- LLM response generation using either the current user message or prior
  persisted messages
- conversation-state projection into `ModeRuntimeState`
- session-oriented completion behavior

The current `ConversationHandler` is too mixed to remain the primary
abstraction. It couples display-state mutation, persistence, session identity,
and LLM call shape. Phase 3B should replace that mixed object with a cleaner
split.

## Why Phase 3B Needs Design Work

The multi-turn path looks smaller than the meeting path, but it is easy to
extract badly.

The failure modes to avoid are:

- treating the problem as a UI/coordinator refactor instead of a mode-execution
  refactor
- forcing multi-turn behavior into the single-shot processor shape
- preserving `ConversationHandler` as a bag of unrelated responsibilities under
  a new name
- hiding session/history semantics inside tests or helper fakes instead of
  naming them explicitly
- "improving" behavior in ways that silently change the current runtime
  contract, especially around history-disabled mode and error handling

This design is intended to avoid those outcomes.

## Current Code Reality

### 1. The adapter still owns the multi-turn orchestration blob

`ModeFeatureRecording.stopAndProcessMultiTurn()` currently owns:

- stopping the recording helper
- clearing visualization state
- setting `state.phase = .processing`
- transcription
- empty-result handling
- live-transcript update
- selecting the first multi-turn `llmTransform`
- delegating into `ConversationHandler`
- non-LLM fallback behavior
- final phase / error mapping

That is still a large post-capture execution path living inside a runtime
adapter.

### 2. `ConversationHandler` is a mixed abstraction

`ConversationHandler` currently owns all of this:

- appending user/assistant display messages into `ModeRuntimeState`
- reading and writing `state.currentSessionId`
- deciding whether a session already exists
- creating or updating persisted conversation history
- loading persisted message history for the LLM call
- choosing between `llmService.send(message:)` and
  `llmService.send(messages:)`
- persisting the assistant response
- clearing session/runtime display state
- an unused playback-stop method

That is too much for one object, and the responsibilities are not cohesive.

### 3. The persisted conversation is the current LLM context source

The current runtime uses persisted `Conversation` history as the source of
multi-turn LLM context:

- first turn: send only the current user text
- continuation turn with persisted session: load saved messages and send the
  full message history

This is important because the panel message list is only a display projection,
not the source of truth for LLM context.

### 4. History-disabled behavior is currently odd but real

When `HistoryService.isEnabled == false`, the current runtime:

- still appends display messages to `state.messages`
- still shows a continuing conversation in the panel
- but does not create a persisted session
- so subsequent LLM calls fall back to `send(message:)`, not `send(messages:)`

That means history-disabled multi-turn mode is effectively stateless from the
LLM's perspective while remaining conversational in the UI.

This is not ideal product behavior, but it is the current runtime behavior and
should be preserved in Phase 3B unless explicitly changed in a later product
phase.

### 5. Success and failure semantics are asymmetric

Current behavior is:

- empty transcription:
  - no user message
  - `phase = .done`
  - auto-dismiss after 2 seconds
- successful response:
  - stay open
  - append user and assistant display messages
  - update `finalText` with the assistant response
  - `phase = .done`
- processing/provider failure:
  - `phase = .error(...)`
  - no dismiss scheduling in this path
- assistant-history persistence failure:
  - swallowed/logged inside `ConversationHandler`
  - successful turn still completes

Those semantics should not change accidentally during extraction.

### 6. Multi-turn execution is not currently driven by generic outputs

Unlike the single-shot path, the current multi-turn runtime does not execute
through `OutputHandler` or the generic output-destination model.

Instead, it directly owns:

- display-message projection
- persisted conversation/session behavior
- assistant response handling

That may or may not be the final product architecture, but it is the current
runtime contract. Phase 3B should not quietly broaden into "make multi-turn use
the single-shot output pipeline" unless that change is explicitly scoped later.

## The Core Architectural Insight

Multi-turn execution should be treated as a sibling execution family to
single-shot execution, not as a specialization of it and not as a UI flow.

The active runtime should again be understood in two layers:

### Layer 1: Runtime adapter

Owned by `ModeFeature`, `ModeFeatureRecording`, and related files.

Responsibilities:

- hotkeys
- panel lifecycle
- capture session lifecycle
- activation/deactivation
- live visualization
- session reset on cancel/deactivate

### Layer 2: Multi-turn turn execution

Owned by the multi-turn processor and its narrow collaborators.

Responsibilities:

- consume a completed capture
- transcribe the turn
- project user/assistant display state
- manage persisted session/history context
- choose the correct LLM request shape
- map execution outcomes into runtime state

Phase 3B should improve Layer 2 without destabilizing Layer 1.

## Problems To Solve In Phase 3B

1. Multi-turn post-capture execution still lives partly in the runtime adapter
   and partly in a mixed helper.
2. The current helper combines display projection, persistence, session
   identity, and LLM request policy.
3. Session reset currently depends on `ConversationHandler.clearSession()`,
   which is the wrong owner for runtime cleanup.
4. There is no stable contract test bed for the multi-turn behavior matrix.
5. The multi-turn runtime still carries an unused playback dependency through
   `ConversationHandler`.

Phase 3B should solve those problems and no more.

## Tenets

1. Preserve the mode design.

   This phase is about multi-turn mode execution, not about reviving the old
   `ConversationFeature` architecture under a new name.

2. Reuse the completed-capture seam.

   Phase 3A already proved the correct first cut. Phase 3B should begin from
   `CompletedCapture`, not from recording-session startup.

3. Name session semantics explicitly.

   Do not bury session/history behavior inside "helper" code. The design should
   make it obvious where session identity and persisted message context come
   from.

4. Keep the processor as the owner of execution policy.

   The processor should decide how a turn runs; narrow collaborators should
   provide persistence or response-generation capabilities, not hide the whole
   flow.

5. Do not broaden into generic conversation infrastructure.

   This phase is not the place to build a universal chat/session engine.

6. Preserve current runtime behavior before improving product semantics.

   If the current mode runtime has odd but real behavior, document it and keep
   it stable in this phase.

7. Do not force multi-turn through the single-shot output/pipeline model.

   Multi-turn execution has its own current behavior contract. This phase
   should extract it cleanly, not normalize it into a generic engine.

8. Remove dead dependencies when they are truly dead.

   If the extracted design no longer needs `AudioPlaybackService`, do not carry
   that dependency forward.

## User-Visible Invariants To Preserve

These behaviors must not change in Phase 3B unless explicitly documented as a
behavior correction:

- multi-turn modes still start/stop recording through the existing
  `ModeFeature` hotkey and panel flow
- after capture stop, the panel still shows "Thinking..." while the turn is
  being processed
- empty transcription still produces no conversation turn and still dismisses
  after 2 seconds
- successful multi-turn turns still keep the panel open
- the panel message list still shows the accumulated conversation for the
  current in-memory session
- `state.liveTranscript` still reflects the most recent user utterance
- `state.finalText` still reflects the most recent assistant response
- continuation turns still use persisted message history when history is
  enabled and a session exists
- when history is disabled, LLM calls remain per-turn single-message calls even
  though the panel keeps showing accumulated display messages
- multi-turn execution still remains display/session/history-driven rather than
  being rerouted through the single-shot generic output model
- provider/transcription errors in the post-capture path still show an error
  state instead of silently dismissing
- failure to persist the assistant reply after a successful response should not
  fail the visible turn

## Options Considered

### Option A: Keep `ConversationHandler` and only move transcription/error flow

Why rejected:

- it would leave the hardest part of the design unresolved
- tests would still need to trust a mixed helper that owns too many concerns
- the new processor would be thin in name only

### Option B: Make multi-turn a specialization of the single-shot processor

Why rejected:

- multi-turn execution has materially different semantics:
  - session identity
  - persisted context loading
  - assistant-turn persistence
  - stay-open completion policy
- forcing that into a single base abstraction would either create flags or
  optional hooks and make both families harder to reason about

### Option C: Extract a `MultiTurnModeTurnProcessor` plus a
`ConversationSessionStore`

Why recommended:

- it preserves the same seam as Phase 3A
- it keeps execution policy in one processor
- it narrows the persistence/session collaborator to one coherent job
- it lets tests cover the real turn behavior without constructing `ModeFeature`
  for every case
- it removes the need for `ConversationHandler` to also mutate runtime cleanup
  state

## Recommended Architecture

### 1. Reuse `CompletedCapture`

Do not introduce a second seam type for multi-turn.

`CompletedCapture` remains the boundary from runtime adapter to turn
processor.

### 2. Introduce a narrow `MultiTurnTurnConfig`

The processor should not take the full `ModeConfig`.

Suggested contents:

- the chosen multi-turn `LLMTransformConfig`

Optional additions only if truly needed:

- mode name for diagnostics

Do not widen this into a generic execution-config bucket.

### 3. Introduce `MultiTurnModeTurnProcessor`

The processor should own:

- transcription after capture stop
- empty-result handling
- updating `state.liveTranscript`
- appending display messages into `state.messages`
- interacting with the conversation session store
- deciding whether to call `send(message:)` or `send(messages:)`
- updating `state.currentSessionId`
- setting `state.finalText`
- mapping success/error outcomes into `state.phase`
- empty-turn dismiss behavior

The processor should not own:

- recording start/stop
- panel lifecycle
- activation/deactivation
- explicit cancel behavior
- microphone/device switching
- session reset on cancel/deactivate

### 4. Replace `ConversationHandler` with a narrower session store boundary

Recommended shape:

```swift
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

struct PreparedConversationTurn {
    let sessionId: UUID?
    let persistedMessages: [Message]?
}
```

Responsibilities of this store:

- create a new persisted conversation when needed
- append the user message to an existing persisted conversation
- return the persisted message list to use as LLM context when available
- preserve current history-disabled behavior by returning `sessionId == nil` and
  `persistedMessages == nil`
- swallow/log assistant-persistence failures the same way the current runtime
  does

Responsibilities it should not own:

- `ModeRuntimeState` mutation
- display message projection
- LLM request policy
- cancel/deactivate cleanup

### 5. Introduce a narrow response-generation boundary

Suggested shape:

```swift
protocol ConversationResponding {
    func send(message: String) async throws -> String
    func send(messages: [Message]) async throws -> String
}
```

`LLMService` can conform directly.

This keeps processor tests narrow without inventing a larger abstraction.

### 6. Return session cleanup to the runtime shell

After Phase 3B, session reset should no longer live on the session store.

The runtime shell should own clearing:

- `state.messages`
- `state.currentSessionId`
- `state.liveTranscript`
- `state.finalText`

This can live in:

- a tiny `ModeFeature` helper, or
- a small `ModeRuntimeState` helper if that keeps cleanup clearer

But the owner should be the runtime shell, not the turn processor/store.

### 7. Remove the unused playback dependency

`ConversationHandler.interruptPlayback()` is unused in the mode runtime.

If the extracted Phase 3B design no longer needs `AudioPlaybackService`, remove
that dependency from:

- `ModeFeature`
- `AppController`
- any new multi-turn collaborator construction path

This is a quality improvement, not scope creep.

## Testing Strategy

Phase 3B should use three layers of tests.

### 1. Processor contract tests

Primary source of truth for the multi-turn behavior matrix.

Suggested file:

- `AxiiTests/MultiTurnModeTurnProcessorTests.swift`

Required cases:

- first turn with history enabled uses `send(message:)`
- continuation turn with prior persisted context uses `send(messages:)`
- history-disabled mode stays stateless from the LLM's perspective
- empty transcription produces `.done` and schedules dismiss
- transcription failure produces `.error(...)` and does not schedule dismiss
- provider failure produces `.error(...)` and does not schedule dismiss
- assistant-persistence failure does not fail an otherwise successful turn
- `state.currentSessionId` updates correctly on first turn / continuation
- `state.messages` projection is correct for success and failure cases

### 2. Session-store tests

Primary source of truth for the persistence/session semantics.

Suggested file:

- `AxiiIntegrationTests/ConversationSessionStoreTests.swift`

Required cases:

- creating the first persisted turn creates a conversation and returns its
  messages
- continuing an existing session appends the user message and returns updated
  messages
- history-disabled mode returns no session id and no persisted messages
- non-conversation interaction mismatch falls back to a new conversation if
  that fallback remains in the implementation
- assistant append failure is swallowed/logged and does not throw outward

### 3. Adapter-level tests

Minimal tests for true runtime-adapter concerns only.

Suggested file:

- `AxiiIntegrationTests/MultiTurnOrchestrationTests.swift`

Required cases:

- `stopAndProcessMultiTurn()` delegates a completed capture into the processor
- recording helper / visualization cleanup still happens in the adapter
- cancel/deactivate clears multi-turn runtime session state
- guard behavior when not recording remains intact

The old mistake to avoid:

- do not duplicate the full behavior matrix at the adapter layer

## Design-For-Refactor Requirement

The Phase 3B test suite should survive later refactors.

That means:

- the processor tests should target stable turn behavior, not the exact
  decomposition of helpers
- the store tests should target persistence/session contracts, not private
  cache layout or exact file/folder naming beyond persisted public behavior
- adapter tests should target capture/runtime-shell concerns only
- do not pin tests to `DispatchWorkItem`, exact `Task` structure, or exact
  method decomposition

## Risks

- keeping `ConversationHandler` mostly intact under a new name would miss the
  real design improvement
- changing history-disabled semantics accidentally would change behavior under
  settings users may rely on
- folding session cleanup into the wrong owner would create future confusion
- silently changing LLM request policy would be hard to detect from casual
  manual testing

## Mitigations

- make `ConversationSessionStore` state-free with respect to `ModeRuntimeState`
- test `send(message:)` vs `send(messages:)` explicitly
- test history-disabled behavior explicitly
- keep the runtime-shell cleanup path in adapter-level tests
- do not broaden the phase into general conversation-framework work

## Migration Plan

1. Introduce the multi-turn config snapshot and new narrow boundaries.
2. Implement `ConversationSessionStore` and its tests.
3. Implement `MultiTurnModeTurnProcessor` and its tests.
4. Rewire `ModeFeatureRecording.stopAndProcessMultiTurn()` to delegate to the
   processor.
5. Pull session cleanup out of `ConversationHandler` into runtime-owned code.
6. Delete `ConversationHandler` or reduce/remove it entirely if superseded.
7. Remove dead playback dependency if no longer needed.
8. Add minimal adapter-level tests.

## Non-Goals

Do not:

- change the current history-disabled semantics
- route multi-turn execution through `OutputHandler` or the single-shot generic
  output pipeline
- redesign the multi-turn phase model unless a change is strictly necessary to
  preserve or clarify the current runtime contract
- normalize the full `LLMTransformConfig` surface for multi-turn modes
- refactor meeting mode
- merge single-shot and multi-turn into one generic base processor
- redesign `ModeRuntimeState` broadly
- redesign the conversation UI
- add TTS or resurrect the old playback flow
- change persisted schemas
- start Phase 4 work

## What Good Looks Like

At the end of a strong Phase 3B implementation:

- `ModeFeatureRecording.stopAndProcessMultiTurn()` is recognizably adapter code
  rather than the owner of conversation execution
- there is one clear multi-turn processor that owns the turn behavior
- persisted conversation/session behavior is explicit and tested in its own
  store layer
- runtime cleanup on cancel/deactivate is clearly owned by the runtime shell
- the code no longer carries the unused playback dependency through the mode
  runtime
- the test suite makes it obvious which layer owns:
  - turn behavior
  - session persistence/context
  - runtime adapter cleanup
