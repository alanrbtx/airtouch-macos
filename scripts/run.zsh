#!/bin/zsh

set -euo pipefail

AIRTOUCH_ROOT=${0:A:h:h}
AIRTOUCH_APP="$AIRTOUCH_ROOT/.build/AirTouch.app"
AIRTOUCH_BINARY="$AIRTOUCH_APP/Contents/MacOS/AirTouch"
AIRTOUCH_LOG="${TMPDIR:-/tmp}/airtouch-native.log"

"$AIRTOUCH_ROOT/scripts/build.zsh" >/dev/null

pkill -x AirTouch >/dev/null 2>&1 || true
for _ in {1..30}; do
  pgrep -x AirTouch >/dev/null 2>&1 || break
  sleep 0.1
done

# Direct execution preserves the Accessibility responsibility chain of the
# trusted terminal while keeping the app bundle identity for camera privacy.
nohup "$AIRTOUCH_BINARY" >"$AIRTOUCH_LOG" 2>&1 &
disown

print "AirTouch is running. Log: $AIRTOUCH_LOG"
