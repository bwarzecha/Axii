# Bluetooth (AirPods) mic warm-up — POC findings

**Date:** 2026-07-13 · **Machine:** Bartosz's MacBook Pro, macOS 26 (Tahoe)
**Hardware:** AirPods Pro, multipoint-connected to iPhone + two MacBooks
**Tool:** `btwarm.swift` (this directory) — compile: `swiftc -O -o btwarm btwarm.swift`

## Problem

Axii's "Warming up..." state sticks (sometimes across 4-5 retries) when
recording from AirPods. Root cause established here: when another multipoint
device owns the AirPods, opening a mic capture session on this Mac produces a
**dead pipe** — buffers arrive at full rate containing pure digital zeros,
indefinitely. All OS-level signals look successful (nominal rate drops to
24 kHz, `kAudioDevicePropertyDeviceIsRunningSomewhere` goes true, buffers
flow), so no property poll distinguishes "stuck" from "quiet room".

**Opening an input stream NEVER steals multipoint ownership.** Four fresh
capture sessions over 14 s from cold: all dead. Ownership is only stolen by
the **output** path.

## Experiments (each from a controlled state)

| # | State | Action | Result |
|---|-------|--------|--------|
| 1 | cold (owned elsewhere) | plain mic (Axii today) | 25 s, 1247 buffers, all 0.0 — stuck |
| 2 | after #1 | 3 s silent-output grab → fresh mic | signal 0.74 s after mic start |
| 3 | warm (owned by this Mac) | plain mic | signal 0.9 s |
| 4 | cold | mic rebuild ×4 (teardown+reopen, no grab) | all 4 dead — **rebuild alone does NOT fix** |
| 5 | cold | 3 s grab → fresh mic | signal 2.0 s after mic start |
| 6 | cold | mic first (wedges), grab 1 s later, same session | **signal 1.0 s after grab — session recovers IN PLACE** |

User-confirmed corroboration: selecting the AirPods as output and playing any
sound warms the mic immediately.

## Key facts for implementation

- AirPods expose **two CoreAudio devices**: `<MAC>:input` and `<MAC>:output`.
  Map input→output by swapping the UID suffix (verify output stream count).
- The grab = HAL output AudioUnit (`kAudioUnitSubType_HALOutput`) targeted at
  the `:output` device, render callback writes silence. While the mic is NOT
  engaged, the grab leaves output at 48 kHz A2DP — inaudible, no quality loss.
- Wispr's `nominalSampleRate < 44100` HFP-settle check does NOT translate to
  this setup: the `:input` device advertises 24 kHz permanently. The only
  reliable liveness signal is a non-zero sample (real mics have a noise floor,
  observed 3e-4 … 4e-3 max-amplitude).
- A wedged session recovers in place once ownership arrives → Axii needs no
  session rebuild, just a grab held alongside Bluetooth captures.

## Decision

In Axii: when capture starts on a Bluetooth mic, start a silent output grab
on the sibling `:output` device and hold it for the duration of the capture
(pins multipoint ownership; prevents mid-recording steal; no quality cost —
during capture the output is in 24 kHz voice mode anyway). Keep the existing
20 s timeout as a backstop. Release the grab on stop/cancel/device-switch.
