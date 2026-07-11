#!/bin/zsh
# E2E v2: pre-seed the mic BEFORE launching Axii (the real suite's semantics),
# restart the app, then drive the full chain via the synthetic hotkey.
set -u
POC=/Users/bartosz/dev/Axii/poc/ui-e2e
BUNDLE=com.warzechalabs.axii
MODE=00000000-0000-0000-0000-000000000001
KEY="mode_${MODE}_selectedMic"
FIXTURE=${1:-$POC/fixtures/testing_one_two_three.wav}
HIST=~/Library/Application\ Support/Axii/history
APP=/Users/bartosz/Library/Developer/Xcode/DerivedData/Axii-gedvrjanhopifselikkfjevzpiaj/Build/Products/Debug/Axii.app

ORIG=$(defaults read $BUNDLE $KEY 2>/dev/null || echo "__UNSET__")
echo "saved mic selection: $ORIG"
restore() {
  if [[ "$ORIG" == "__UNSET__" ]]; then defaults delete $BUNDLE $KEY 2>/dev/null
  else defaults write $BUNDLE $KEY -string "$ORIG"; fi
  echo "restored mic selection"
}
trap restore EXIT

defaults write $BUNDLE $KEY -string BlackHole2ch_UID
echo "mic -> BlackHole2ch_UID"

echo "restarting Axii..."
AXII_PID=$(pgrep -x Axii || true)
if [[ -n "$AXII_PID" ]]; then
  kill -TERM $AXII_PID
  for i in $(seq 1 10); do pgrep -x Axii > /dev/null || break; sleep 1; done
fi
open "$APP"
sleep 10   # launch + permissions gate + hotkey registration

: > /tmp/axii_e2e_paste_target.txt
open -a TextEdit /tmp/axii_e2e_paste_target.txt
sleep 2

BEFORE=$(ls "$HIST" | wc -l | tr -d ' ')
echo "history entries before: $BEFORE"

echo "fire hotkey (start)"
$POC/fire_hotkey 49 opt || exit 1
sleep 2

echo "play fixture: $FIXTURE"
$POC/play_to_device BlackHole2ch_UID "$FIXTURE" || exit 1
sleep 1

echo "fire hotkey (stop)"
$POC/fire_hotkey 49 opt || exit 1

echo "waiting for transcription + persistence..."
for i in $(seq 1 25); do
  sleep 1
  AFTER=$(ls "$HIST" | wc -l | tr -d ' ')
  [[ "$AFTER" -gt "$BEFORE" ]] && break
done

AFTER=$(ls "$HIST" | wc -l | tr -d ' ')
echo "history entries after: $AFTER"
if [[ "$AFTER" -le "$BEFORE" ]]; then
  echo "E2E_FAIL: no new history entry within 25s"
  exit 1
fi

NEWEST=$(ls -t "$HIST" | head -1)
echo "newest entry: $NEWEST"
python3 - "$HIST/$NEWEST" <<'EOF'
import json, sys, os
d = sys.argv[1]
meta = json.load(open(os.path.join(d, "metadata.json")))
print("PREVIEW:", meta.get("preview"))
audio = os.path.join(d, "audio")
print("AUDIO FILES:", os.listdir(audio) if os.path.isdir(audio) else [])
EOF
echo "E2E_PASS"
