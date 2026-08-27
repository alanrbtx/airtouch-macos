#!/bin/zsh

set -euo pipefail

AIRTOUCH_ROOT=${0:A:h:h}
AIRTOUCH_SOURCE="$AIRTOUCH_ROOT/native/AirTouchNative.swift"
AIRTOUCH_PLIST="$AIRTOUCH_ROOT/native/Info.plist"
AIRTOUCH_APP="$AIRTOUCH_ROOT/.build/AirTouch.app"
AIRTOUCH_BINARY="$AIRTOUCH_APP/Contents/MacOS/AirTouch"

if ! command -v swiftc >/dev/null 2>&1; then
  print -u2 "AirTouch requires the Swift compiler from Xcode Command Line Tools."
  exit 1
fi

mkdir -p "$AIRTOUCH_APP/Contents/MacOS"
cp "$AIRTOUCH_PLIST" "$AIRTOUCH_APP/Contents/Info.plist"

swiftc -O \
  -parse-as-library \
  -framework AppKit \
  -framework ApplicationServices \
  -framework AVFoundation \
  -framework CoreGraphics \
  -framework Vision \
  "$AIRTOUCH_SOURCE" \
  -o "$AIRTOUCH_BINARY"

codesign --force --deep --sign - --identifier com.airtouch.native "$AIRTOUCH_APP" >/dev/null
print "$AIRTOUCH_APP"
