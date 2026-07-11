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
#
# Tiers:
#   Scripts/reliability-suite.sh --pr        layer 1 only (pre-commit sized)
#   Scripts/reliability-suite.sh             all layers (nightly)
#   Scripts/reliability-suite.sh --release   all layers, 50,000-seed fuzzes
#
set -euo pipefail
cd "$(dirname "$0")/.."

DEST='platform=macOS'
PROJ=Axii.xcodeproj
SCHEME=Axii
TIER=${1:-}

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
    xcodebuild test -project "$PROJ" -scheme "$SCHEME" -destination "$DEST"

if [[ "$TIER" != "--pr" && "$TIER" != "--fast" ]]; then
    run "Thread Sanitizer sweep" \
        xcodebuild test -project "$PROJ" -scheme "$SCHEME" -destination "$DEST" \
        -enableThreadSanitizer YES

    run "Deep capture fuzz ($CAPTURE_SEEDS seeds)" \
        env TEST_RUNNER_AXII_FUZZ_SEEDS=$CAPTURE_SEEDS \
        xcodebuild test -project "$PROJ" -scheme "$SCHEME" -destination "$DEST" \
        -only-testing:AxiiIntegrationTests/MeetingConcurrencyFuzzTests

    run "Deep interaction fuzz ($INTERACTION_SEEDS seeds x 2 profiles)" \
        env TEST_RUNNER_AXII_FUZZ_ITERATIONS=$INTERACTION_SEEDS \
        xcodebuild test -project "$PROJ" -scheme "$SCHEME" -destination "$DEST" \
        -only-testing:AxiiIntegrationTests/ModeInteractionFuzzTests
fi

run "Real-transcription quirks (skips if models absent)" \
    env TEST_RUNNER_AXII_REAL_ASR=1 \
    xcodebuild test -project "$PROJ" -scheme "$SCHEME" -destination "$DEST" \
    -only-testing:AxiiIntegrationTests/RealTranscriptionQuirkTests

if [[ "$TIER" != "--pr" && "$TIER" != "--fast" ]]; then
    # Real-UI E2E: real app + synthetic hotkeys + BlackHole + real Parakeet.
    # Individual tests self-skip (not fail) when the machine lacks BlackHole
    # or the runner's Accessibility grant — see AxiiUITests/README.md.
    run "Real-UI E2E suite (self-skips without BlackHole/Accessibility)" \
        xcodebuild test -project "$PROJ" -scheme AxiiUITests -destination "$DEST"
fi

echo "ALL RELIABILITY GATES PASSED"
