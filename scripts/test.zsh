#!/bin/zsh

set -euo pipefail

AIRTOUCH_ROOT=${0:A:h:h}
AIRTOUCH_APP="$AIRTOUCH_ROOT/.build/AirTouch.app"
AIRTOUCH_BINARY="$AIRTOUCH_APP/Contents/MacOS/AirTouch"

"$AIRTOUCH_ROOT/scripts/build.zsh" >/dev/null
"$AIRTOUCH_BINARY" --self-test
plutil -lint "$AIRTOUCH_APP/Contents/Info.plist"
codesign --verify --deep --strict "$AIRTOUCH_APP"
print "AirTouch build verification: OK"
