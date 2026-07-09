# Meeting Recording Reliability Model

This document records the invariants that make meeting capture safe against
crashes and interleaved operations. Changes to the meeting runtime must
preserve them; the regression tests in `AxiiIntegrationTests/MeetingPhase4CTests.swift`
and `MeetingSaveRegressionTests.swift` freeze most of them.

## Lifecycle invariants (MeetingCaptureSession)

- **At most one capture is live at a time.** Enforced by UI phase gating and
  cancel-on-reentry in `start()`.
- **Epoch guard.** `start`/`stop`/`cancel` each bump an epoch counter. An
  operation that resumes from an `await` and finds the epoch changed must not
  publish or mutate session state. In particular, `start()` publishes nothing
  until the capture is fully live *and* the epoch still matches; a superseded
  start tears down the audio it started (audio teardown only works after
  `audio.start` returns — earlier stops are no-ops on a partial start).
- **Detach before await.** `stop()` moves the entire capture (managers, chunk
  tasks, duration, app name) into locals synchronously before its first
  `await`. A session started during the long finish can never be clobbered by
  the finishing one. Chunk tasks are cancelled *before* they are awaited.
- **Switches are serialized** (`MeetingSwitchSerializer`), and stop/cancel
  wait for the switch chain to settle before tearing audio down —
  interrupting `switchApp`'s stop-and-restart dance would orphan the
  restarted audio session.

## Stale-write guards (handler/adapter)

- `MeetingPipelineHandler` bumps a generation on start/stop/cancel. Post-await
  writes to `ModeRuntimeState` (final segments, finalization progress) are
  suppressed when the generation moved on. Finalization progress is a closure
  *parameter*, not shared service state.
- `ModeFeatureMeeting.stopMeeting` resolves phase to `.idle` only from
  `.processing`; a newer session's phase is never stomped. A persistence
  failure surfaces as `.error("Failed to save meeting")` — never silent.

## Crash recovery / artifact lifecycle

- **Commit-after-persist.** The autosave transcript and original-quality temp
  audio survive until the meeting is durably persisted (or persistence is
  disabled, or the user discards). They ride `MeetingPersistencePayload
  .recoveryArtifacts`; the persistence caller clears them after a successful
  save. On persist failure they are deliberately left on disk.
- **Discard clears immediately** (stop-without-save, cancel) so a discarded
  meeting cannot resurface as phantom "crash recovery".
- **Reads do not destroy.** `checkForCrashRecovery()` never deletes a
  readable autosave file; only corrupt or expired files are removed. Expiry
  is keyed to the file's modification time (last autosave write), not the
  recording start time.
- **A final flush** writes the freshest transcript to the autosave file at
  stop, before the (potentially minutes-long) finalize/persist window; the
  steady-state autosave cadence is 60 s.
- The autosave file carries a `sessionID`; the commit path clears it only if
  it still belongs to the committing session (`clearAutoSave(matching:)`).
- **Scope (honest limits):** recovery covers streamed transcript segments
  only. With streaming transcription disabled nothing is autosaved. Temp
  audio lives in the system temp directory and is not re-read by recovery;
  it does not survive reboots.

## Executor confinement

- `MicrophoneCapture`: delegate-facing state (`currentDevice`, `sampleRate`,
  `lastSignalState`) is confined to `captureQueue` (written via
  `captureQueue.async` from start/stop, read only in `captureOutput`).
  `startRunning`/`stopRunning` run on a separate serial `sessionQueue` —
  never on the caller thread (blocks) or the delegate queue (deadlock).
- `TranscriptionService` builds a **fresh `TdtDecoderState` per call**. The
  actor is reentrant at its awaits; shared decoder state was a use-after-free
  (copies share MLMultiArray buffers) and let independent streams (dictation,
  meeting mic, meeting system) pollute each other's context.
  `MeetingTranscriptManager.transcriptionChain` still serializes live meeting
  chunks.
