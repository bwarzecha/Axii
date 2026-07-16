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
- **Stop coalescing is scoped to the capture ERA** (`meetingCaptureEra`,
  bumped at every capture start). A second stop joins the in-flight stop
  ONLY when both belong to the same era: a stop task still persisting a
  PREVIOUS meeting must never swallow the stop of a newer capture it does
  not own — the new recording would keep running unowned behind a closed
  panel. (Deep interaction fuzzer, seed 34311: close a long meeting mid-
  persist, start a new one, stop it — the stop joined the stale task and
  audio was never detached.)
- **Stop-COMPLETION writes are era-scoped too.** Everything a save task
  publishes after its awaits — the `.processing → .idle` resolve, the
  persist-failure `.error`, and the history-off export offer's `.done` —
  requires `era == meetingCaptureEra` in addition to the stop-generation
  check. A cancel-then-restart bumps the era WITHOUT issuing a new stop,
  so generation alone lets the stale completion stamp its terminal phase
  onto the new live recording. The meeting's persistence contract
  (`meetingHistoryEnabledAtStart`) is likewise SNAPSHOT into the stop
  task: a new meeting re-freezes the instance var while the old save
  drains. (Sharded release fuzzer, seed 18718: cancel mid-save, start a
  new meeting — the old save's export offer published `.done` over the
  live recording, which sailed on unowned.)

## Crash recovery / artifact lifecycle

- **Commit-after-persist.** The autosave transcript and original-quality temp
  audio survive until the meeting is durably persisted (or persistence is
  disabled, or the user discards). They ride `MeetingPersistencePayload
  .recoveryArtifacts`; the persistence caller clears them after a successful
  save. On persist failure they are deliberately left on disk.
- **Discard keeps a recoverable copy** ("Recently Deleted"). Tearing down a
  LIVE meeting (Escape/close/takeover) persists it to history flagged
  `discardedAt` — audio and transcript intact — rather than destroying it,
  so a mistaken discard is recoverable. It is hidden from the main list,
  shown in the History window's Recently Deleted section with Restore /
  Delete Now, and swept for good only after `MeetingRecoveryPolicy
  .artifactLifetime` (same window as crash artifacts). The discard stop
  runs HEADLESS (`stop(saveToHistory:showsProgress:false)`) — its panel is
  gone, so it never publishes a `.processing` no one can resolve. An error
  teardown still SAVES (salvage), not discards. Quit-and-discard of a live
  meeting leaves the artifacts for next-launch recovery rather than a slow
  in-line finalize.
- **Dictation/conversation discards salvage too.** Simple-mode captures are
  memory-only, so every user-initiated teardown that would destroy one —
  Escape (a GLOBAL hotkey while any panel is up: pressing Escape in another
  app counts), panel close, takeover "Discard & Switch", mode deletion,
  cancel during `.transcribing`/`.processing`, an errored turn's dismiss,
  and Quit-and-Discard — routes ≥1 s of captured audio to "Recently
  Deleted" instead (`ModeFeatureDiscardSalvage` takes the capture;
  `DiscardedCaptureArchiver` persists entry → PAYLOAD → best-effort
  enrichment). The payload is what durability, the quit gate, and crash-
  spool custody all key on: the audio when the mode stores audio, else
  the TRANSCRIPT (Conversation ships `saveAudio: false` — releasing on
  the husk entry alone was a confirmed loss bug). The in-flight turn's
  capture is held on the feature until the turn DELIVERS (`.done`); an
  `.error` turn keeps it so the eventual teardown can still salvage.
  Quit-and-Discard holds termination (via `isDataBearing`/pending writes)
  until the payload lands; a failed or empty payload keeps the crash
  spool for next-launch retry (`DiscardArchiverPayloadTests` pins all
  four corners). Sub-second captures and history-off stay out of the
  trash.
  The interaction fuzzer enforces this as conservation: a cancel may
  over-deliver (salvage re-transcribes a mid-turn capture), never lose.
- **Simple captures are crash-spooled from second zero.** Every
  dictation/conversation capture streams to a disk spool as it records
  (`SimpleCaptureSpool`: 16 kHz raw float32 + JSON sidecar, headerless so
  death at any byte leaves a readable file; one spool per capture
  SESSION, surviving mic switches and the post-stop turn). The spool is
  discarded only at a terminal state — delivered, durably trashed, or
  sub-threshold; an orphan on disk means the process died, and
  `SimpleCaptureRecovery` at launch archives it into "Recently Deleted"
  under its ORIGINAL date via the same archiver as user discards. A
  failed archive leaves the spool for the next launch to retry. Tests
  and fuzzers get no spool by default (nil factory); production wires
  `SimpleCaptureSpool` at ModeFeature construction.
  Known residuals (tracked, not yet fixed): ASR false-empty releases the
  capture, and the quit drain's 60 s deadline edges.
- **Reads do not destroy.** `checkForCrashRecovery()` never deletes a
  readable autosave file; only corrupt or expired files are removed. Expiry
  is keyed to the file's modification time (last autosave write), not the
  recording start time.
- **The first minute is covered.** `startAutoSave` writes the recovery file
  immediately (indexing the spool audio from second zero), and the capture
  session re-flushes once when the first chunk's sample rates land — the
  60 s timer cadence is steady-state, not the start of coverage.
- **Artifacts live for days, not an hour** (`MeetingRecoveryPolicy
  .artifactLifetime`, currently 7 days, shared by the autosave expiry and
  the spool sweep): a machine dying overnight or over a weekend still
  recovers its meeting at the next launch. Recovered meetings carry their
  ORIGINAL start date into history (`AutoSaveData.startTime` →
  `MeetingCrashRecovery.startedAt` → `Meeting.createdAt`).
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
- **Length-scaling stop-path work never runs on the main actor.** Anything
  in the stop/persist/recovery chain whose cost grows with recording length
  is a beachball generator at hour scale: the audio encode (chunked AND
  detached in `HistoryService` — a single whole-track `AVAudioFile.write`
  WEDGES the AAC codec outright past 512MB ≈ 46.6 min @48kHz, the
  2026-07-15 incident), the stop path's full-track spool reads
  (`readSamplesFromFileOffMain`), and launch recovery's spool reads. New
  stop-path work must budget against `MeetingStopResponsivenessTests`'
  main-actor stall probe (<2s, the beachball threshold).

## Test harness layers

- **Capture schedule fuzzer** (`MeetingConcurrencyFuzzTests`): every async
  dependency in the chaos fakes suspends on a `GateHub`, so the driver
  controls exactly which suspended call proceeds next. 500 seeded random
  schedules of start/stop/cancel/switch/chunk/error/start-failure operations
  are checked against conservation invariants at quiescence. A failing seed
  is a reproducible bug report.
- **Fuzzers never touch real system surfaces.** A seeded schedule is only a
  reproducible bug report if nothing in it runs at machine speed: real
  ScreenCaptureKit lookups, pasteboard writes, run-loop timers, workspace
  observers, and power assertions all made CI-only failures that did not
  replay locally (release-fuzz meeting seed 5908, 2026-07-16). Seams:
  `appListProvider` (pipeline handler), `ClipboardProviding`,
  `MeetingDurationTicking`, `MeetingPowerMonitoring` — fuzz injects fakes
  for all of them. Error injection must never use `.permissionDenied`:
  its handler opens the REAL System Settings when the machine's mic TCC
  state is blocked.
- **Interaction fuzzer** (`ModeInteractionFuzzTests`): seeded schedules over
  the mode runtime's REAL UI entry points — hotkey, Escape, panel buttons,
  mic switches, device events, session errors, config edits, timer fires —
  with capture, transcription, and delayed work all gate-controlled via
  production seams (helper factory, dialog providers, delay scheduler).
  Two profiles: `noCancel` enforces STRICT audio conservation (every
  recorded sample reaches the transcriber — the silent-data-loss detector);
  `fullChaos` adds cancels and checks structural invariants (no unowned
  capture, no stuck phase, all audio accounted for). In-suite 300 seeds per
  profile; `AXII_FUZZ_ITERATIONS` scales the deep tiers. Found a real bug
  on its first run (stale error arming a dismiss timer that fired into the
  recording a resumed start later published) and the era-coalescing zombie
  at deep seed 34311. `AXII_FUZZ_SEED_START` is the ABSOLUTE first seed
  for every test in the class (it overrides the per-test seed base, same
  semantics as the capture fuzzer) — release shards use it for disjoint
  ranges, and `AXII_FUZZ_SEED_START=<seed>` + `AXII_FUZZ_ITERATIONS=1`
  replays exactly the seed a failure message printed, in any profile.
  Get a per-action state timeline with `AXII_FUZZ_TRACE_FILE=<path>`
  (sidecar file — xcodebuild logs swallow test-host stdout).
- **Convergence-based quiescence** (both fuzzers,
  `AxiiIntegrationTests/FuzzQuiescence.swift`): gate release removes a
  waiter at RESUME time, so a resumed-but-not-yet-run continuation is
  invisible to `GateHub.pendingCount` — on a slow host a fixed-round
  release/yield drain can check invariants against a mid-flight state
  (three CI-only false positives on GitHub macos-26 runners: seeds 45253,
  22605, 23311). The drains therefore converge instead: keep releasing
  until the invariant-relevant state fingerprint — including every chaos
  fake's liveness, not just feature-level state — is unchanged for 25
  consecutive rounds. A genuinely stuck state stays stuck forever, so
  convergence checks the product's eventual-teardown contract rather than
  assuming scheduler fairness Swift does not guarantee. Caveat: the
  "failing seed = reproducible bug report" contract holds only with
  convergence-based drains — under a fixed-round drain a red seed may be
  a scheduler artifact that no other shard, attempt, or local replay
  reproduces.
- **Memory soak** (`MeetingMemorySoakTests`, opt-in `AXII_SOAK=1`,
  minutes via `AXII_SOAK_MINUTES`): a long dual-track meeting through the
  REAL finalize + AAC persist path with a footprint sampler, plus a
  stop-chain wall-time tripwire. Tracks are built at 48kHz — capture-real
  rate; the original 16kHz soak (230MB/hour) structurally could not reach
  the 512MB AAC encode knee. Budget-guarded at 2 GB spike.
- **Encode-wedge regression** (`HistoryAudioEncodeRegressionTests`, fast
  tier, no models): `saveAudioCompressed` of an above-knee (>512MB) track
  must complete in bounded time for both AAC and ALAC — the wedge was
  20+ CPU-minutes; healthy is seconds.
- **Stop-chain responsiveness** (`MeetingStopResponsivenessTests`, opt-in
  `AXII_STOP_REPRO=1`, needs downloaded models): the full hour-scale stop
  chain (spool read → real-ASR finalize → persist) with a main-actor stall
  probe asserting <2s (beachball threshold) and bounded total time.
  Knobs: `_MINUTES`, `_FORMAT` (default aac), `_CLIP` (real recording).
- **Kill-during-persist recovery** (`MeetingKillDuringPersistRecoveryTests`):
  the exact on-disk state a force-kill during finalize/persist leaves
  (final autosave flushed with audio references, spools closed, nothing in
  history) recovers WITH audio at relaunch, and artifacts are released
  only after the durable persist.
- **Real-UI E2E suite** (`AxiiUITests`, scheme `AxiiUITests`): drives the
  REAL app — synthetic global hotkeys (CGEventPost to the HID tap), real
  capture from the BlackHole 2ch virtual device, real Parakeet, and
  assertions on all three planes: history data, panel accessibility
  values (`panel.phase`/`panel.duration`/`panel.audioLevel`), and stored-
  audio artifacts (RMS + duration-vs-capture-window — the channel-layout
  corruption detector). Scratch isolation via env overrides
  (`AXII_HISTORY_DIR`/`AXII_MODES_DIR`/`AXII_RECOVERY_DIR`; the recovery
  override keeps kill-9 tests from swallowing or leaking REAL recovery
  artifacts) plus NSArgumentDomain launch arguments for defaults reads.
  Machine prerequisites (dev Mac or self-hosted runner): BlackHole 2ch
  installed and a one-time Accessibility grant for AxiiUITests-Runner —
  tests self-skip with instructions otherwise. Hard-won UI-driving rules:
  status-item clicks by coordinate, menu selection by keyboard type-ahead
  (menu-item AX frames can be stale/offscreen and a cursor move dismisses
  the menu), existence-based waits only (isHittable lies for
  non-activating panels), and never F-keys for synthetic hotkeys.
- **Tiers** (`Scripts/reliability-suite.sh`): `--pr` = fast suite only;
  default (nightly) adds TSan + 10k-seed deep fuzzes; `--release` runs the
  deep fuzzes at 50k seeds. The E2E suite is its own opt-in tier, run
  where the two machine prerequisites exist.
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
