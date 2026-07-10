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
- **Audio is the truth for duration; sleep is excluded.** Persisted duration
  is derived from captured samples ÷ rate at `stop()` — the wall clock keeps
  running through system sleep, the samples do not. The live ticker
  (`MeetingDurationTicker`) pauses on `NSWorkspace.willSleepNotification` and
  resumes at wake (`MeetingPowerMonitor`); willSleep also flushes the
  recovery autosave FIRST (the machine may never wake). Idle system sleep is
  suppressed while recording via `ProcessInfo.beginActivity`; lid-close sleep
  remains the user's call.

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
- **Recovered meetings are persisted to history at launch** (when history
  is enabled), including their audio: the autosave records the spool-file
  locations, and in-progress recordings live in Application Support
  (`Axii/InProgressRecordings`), not the purgeable system temp directory.
  Expired spool files are swept at launch, before any capture can start.
- **Recovery runs once per process** (`ModeFeature.crashRecoveryDidRun`) —
  a mode created/duplicated/rebuilt at runtime must never re-run launch
  recovery against a live session, and N recovery-enabled modes must not
  persist the same crashed meeting N times.
- **Live sessions are not crashes.** `MeetingTranscriptManager` keeps a
  process-wide registry of session IDs whose autosave is running;
  `checkForCrashRecovery()` refuses to hand out a file owned by a live
  writer (the shared autosave path makes that reachable).
- **Scope (honest limits):** with streaming transcription disabled nothing
  is autosaved, so neither transcript nor audio is recoverable for such
  sessions.

## UI / modal / run-loop invariants

- **Hotkeys are inert during modal alerts** (mode keys and Escape both):
  Carbon events deliver during modal sessions, and acting on them corrupts
  the question the dialog is asking — Escape would destroy the recording a
  quit/busy dialog is offering to save. Dialog verdicts re-validate
  `isDataBearing` after `runModal` returns.
- **Modal-blocking dialogs re-validate the world when they return.**
  `startMeeting` re-checks `isActive`/`hasLiveCapture`/phase after its
  confirm dialog; the busy-mode dialog applies its verdict only to data
  that still exists.
- **Timers that protect data run in `.common` run-loop mode** (autosave
  timer): `.default`-mode timers silently stop firing while any modal
  alert is open.
- **willSleep work is synchronous.** `MeetingPowerMonitor` delivers
  sleep/wake callbacks on the posting thread with no task hop — the
  autosave flush completes before the willSleep handler returns, because
  the machine may never wake.
- **Saves hold their own sleep assertion** through finalize + persist; the
  capture's assertion ends at detach.

## Test harness layers

- **Schedule fuzzer** (`MeetingConcurrencyFuzzTests`): every async dependency
  in the chaos fakes suspends on a `GateHub`, so the driver controls exactly
  which suspended call proceeds next. 500 seeded random schedules of
  start/stop/cancel/switch/chunk/error/start-failure operations are checked
  against conservation invariants at quiescence. A failing seed is a
  reproducible bug report.
- **Crash matrix** (`MeetingCrashRecoveryTests`): the real transcript manager
  against temp-dir autosave files, simulating crashes at each lifecycle point.
- **Commit-point tests** (`MeetingSaveRegressionTests`): recovery artifacts
  observed on disk across persist success/failure/history-disabled, plus
  stale-stop-vs-newer-stop phase contention.
- **Real-ASR quirks** (`RealTranscriptionQuirkTests`): opt-in tests against
  the actual Parakeet models with `say`-synthesized speech — long-audio
  chunking, concurrent inference, resampling, hang detection (every call is
  deadline-bounded). Run with:
  `TEST_RUNNER_AXII_REAL_ASR=1 xcodebuild test -project Axii.xcodeproj
  -scheme Axii -destination 'platform=macOS'
  -only-testing:AxiiIntegrationTests/RealTranscriptionQuirkTests`
- **TSan sweep**: run the suite with `-enableThreadSanitizer YES` to check
  the real-thread components (MicrophoneCapture queues, transcription actor).

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
