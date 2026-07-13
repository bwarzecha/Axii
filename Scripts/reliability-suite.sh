#!/bin/bash
#
# Tiered reliability gate for Axii (see docs/meeting-reliability-model.md).
#
# Layers:
#   1. fast suite — unit + integration, includes BOTH schedule fuzzers at
#      their in-suite sizes (500-seed capture fuzzer, 2x300-seed interaction
#      fuzzer over the UI entry points)
#   2. Thread Sanitizer sweep — real-thread races in audio capture/ASR
#   3. deep capture fuzz — 10,000 seeds against MeetingCaptureSession
#   4. deep interaction fuzz — 10,000 seeds per profile against the mode
#      runtime's real UI entry points (hotkey/Escape/buttons/mic-switch/
#      device events/errors/config edits/timer fires); the no-cancel
#      profile enforces strict audio conservation
#   5. real-transcription quirk suite (requires downloaded Parakeet models)
#   6. real-UI E2E suite (AxiiUITests) — real app + synthetic hotkeys +
#      BlackHole audio + real ASR; self-skips when the machine lacks
#      BlackHole, the runner Accessibility grant, or an unlocked screen
#      (see AxiiUITests/README.md)
#
# Tiers:
#   Scripts/reliability-suite.sh --pr        layer 1 only (pre-commit sized)
#   Scripts/reliability-suite.sh --fast      same as --pr
#   Scripts/reliability-suite.sh             all layers (nightly)
#   Scripts/reliability-suite.sh --release   all layers, 50,000-seed fuzzes
#
# CI knobs (GitHub macOS runners run every layer except E2E):
#   AXII_SUITE_SKIP_E2E=1    skip layer 6 (needs BlackHole/Accessibility/
#                            unlocked screen — local machines only)
#   AXII_SUITE_UNSIGNED=1    ad-hoc/unsigned test builds (runners have no
#                            signing identity)
#
# Run exclusively: no other xcodebuild may touch this DerivedData during a
# tier, and the E2E layer additionally needs an input-idle, unlocked machine.
#
set -euo pipefail
cd "$(dirname "$0")/.."

DEST='platform=macOS'
PROJ=Axii.xcodeproj
SCHEME=Axii
TIER=${1:-}

# The suites assume EXCLUSIVE state: one test host, one defaults suite
# (AXII_DEFAULTS_SUITE), one DerivedData. CI runners default to parallel
# host clones, which collide on all three — force serial everywhere.
XCFLAGS=(-parallel-testing-enabled NO)
if [[ "${AXII_SUITE_UNSIGNED:-0}" == "1" ]]; then
    XCFLAGS+=(CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO)
fi

# Runtime writes from tests (fuzz-created mode mic selections) land in an
# ISOLATED defaults suite (AXII_DEFAULTS_SUITE, set by the Axii scheme's
# TestAction) — purge it so it never grows unboundedly.
defaults delete com.warzechalabs.axii.tests 2>/dev/null || true

CAPTURE_SEEDS=10000
INTERACTION_SEEDS=10000
if [[ "$TIER" == "--release" ]]; then
    CAPTURE_SEEDS=50000
    INTERACTION_SEEDS=50000
fi

run() {
    echo "== $1 =="
    shift
    local output
    if output=$("$@" 2>&1); then
        echo "$output" | tail -3
    else
        local status=$?
        # On failure, keep enough context to diagnose without a rerun.
        echo "$output" | grep -E "error:|failed" | tail -20
        echo "$output" | tail -20
        return "$status"
    fi
}

run "Fast suite (both fuzzers at in-suite size)" \
    xcodebuild test -project "$PROJ" -scheme "$SCHEME" -destination "$DEST" \
    "${XCFLAGS[@]:-}"

if [[ "$TIER" != "--pr" && "$TIER" != "--fast" ]]; then
    run "Thread Sanitizer sweep" \
        xcodebuild test -project "$PROJ" -scheme "$SCHEME" -destination "$DEST" \
        -enableThreadSanitizer YES "${XCFLAGS[@]:-}"

    run "Deep capture fuzz ($CAPTURE_SEEDS seeds)" \
        env TEST_RUNNER_AXII_FUZZ_SEEDS=$CAPTURE_SEEDS \
        xcodebuild test -project "$PROJ" -scheme "$SCHEME" -destination "$DEST" \
        -only-testing:AxiiIntegrationTests/MeetingConcurrencyFuzzTests \
        "${XCFLAGS[@]:-}"

    run "Deep interaction fuzz ($INTERACTION_SEEDS seeds x 2 profiles)" \
        env TEST_RUNNER_AXII_FUZZ_ITERATIONS=$INTERACTION_SEEDS \
        xcodebuild test -project "$PROJ" -scheme "$SCHEME" -destination "$DEST" \
        -only-testing:AxiiIntegrationTests/ModeInteractionFuzzTests \
        "${XCFLAGS[@]:-}"
fi

if [[ "$TIER" != "--pr" && "$TIER" != "--fast" ]]; then
    run "Real-transcription quirks (skips if models absent)" \
        env TEST_RUNNER_AXII_REAL_ASR=1 \
        xcodebuild test -project "$PROJ" -scheme "$SCHEME" -destination "$DEST" \
        -only-testing:AxiiIntegrationTests/RealTranscriptionQuirkTests \
        "${XCFLAGS[@]:-}"

    # Real-UI E2E: real app + synthetic hotkeys + BlackHole + real Parakeet.
    # Individual tests self-skip (not fail) when the machine lacks BlackHole
    # or the runner's Accessibility grant — see AxiiUITests/README.md.
    # CI runners skip the whole layer: they have no audio loopback, no
    # Accessibility grant, and no interactive session.
    if [[ "${AXII_SUITE_SKIP_E2E:-0}" != "1" ]]; then
        run "Real-UI E2E suite (self-skips without BlackHole/Accessibility)" \
            xcodebuild test -project "$PROJ" -scheme AxiiUITests -destination "$DEST"
    else
        echo "== Real-UI E2E suite SKIPPED (AXII_SUITE_SKIP_E2E=1) =="
    fi
fi

echo "ALL RELIABILITY GATES PASSED"
