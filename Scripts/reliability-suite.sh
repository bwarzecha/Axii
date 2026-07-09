#!/bin/bash
#
# Full reliability gate for Axii — run before releases and nightly.
# Layers (see docs/meeting-reliability-model.md):
#   1. fast suite (unit + integration, includes the 500-seed schedule fuzzer)
#   2. Thread Sanitizer sweep (real-thread races in audio capture/ASR actor)
#   3. deep schedule fuzz (10,000 seeds)
#   4. real-transcription quirk suite (requires downloaded Parakeet models)
#
# Usage: Scripts/reliability-suite.sh [--fast]
#   --fast  skips the TSan rebuild and deep fuzz (pre-commit sized run)
#
set -euo pipefail
cd "$(dirname "$0")/.."

DEST='platform=macOS'
PROJ=Axii.xcodeproj
SCHEME=Axii
FAST=${1:-}

run() {
    echo "== $1 =="
    shift
    "$@" 2>&1 | tail -3
}

run "Fast suite (includes 500-seed fuzzer)" \
    xcodebuild test -project "$PROJ" -scheme "$SCHEME" -destination "$DEST"

if [[ "$FAST" != "--fast" ]]; then
    run "Thread Sanitizer sweep" \
        xcodebuild test -project "$PROJ" -scheme "$SCHEME" -destination "$DEST" \
        -enableThreadSanitizer YES

    run "Deep schedule fuzz (10,000 seeds)" \
        env TEST_RUNNER_AXII_FUZZ_SEEDS=10000 \
        xcodebuild test -project "$PROJ" -scheme "$SCHEME" -destination "$DEST" \
        -only-testing:AxiiIntegrationTests/MeetingConcurrencyFuzzTests
fi

run "Real-transcription quirks (skips if models absent)" \
    env TEST_RUNNER_AXII_REAL_ASR=1 \
    xcodebuild test -project "$PROJ" -scheme "$SCHEME" -destination "$DEST" \
    -only-testing:AxiiIntegrationTests/RealTranscriptionQuirkTests

echo "ALL RELIABILITY GATES PASSED"
