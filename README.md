# AirTouch for macOS

AirTouch controls macOS with hand gestures captured by the built-in camera. It is a native menu-bar application written in Swift and built directly with `swiftc`—no browser, frontend, server, Docker, or network connection is involved.

All hand-pose inference runs locally with Apple Vision. Camera frames are neither stored nor transmitted.

## Requirements

- macOS 14 or newer;
- Apple Silicon or Intel Mac with a camera;
- Xcode Command Line Tools (`xcode-select --install`).

## Build and run

```bash
make run
```

The command builds `.build/AirTouch.app` with `swiftc` and starts it as a background menu-bar application. Russian-speaking users can also double-click `Запустить AirTouch.command` in Finder.

On first launch, allow:

1. Camera access for AirTouch.
2. **System Settings → Privacy & Security → Accessibility → Terminal** (and AirTouch when shown).
3. Automation access to System Events if macOS asks when switching Spaces.

The direct terminal launch is intentional: it keeps a stable Accessibility responsibility chain for local ad-hoc builds. A public binary release should instead use a Developer ID signature and Apple notarization.

## Gestures

| Gesture | Action |
| --- | --- |
| Move the thumb tip | Move the cursor with strong smoothing |
| Pinch thumb and index finger | Click |
| Pinch twice quickly | Double-click / open |
| Swipe an open palm left | Switch to the Space or full-screen window on the right |
| Swipe an open palm right | Switch to the Space or full-screen window on the left |
| Raise index and middle fingers | Scroll |

## Commands

```bash
make build   # build .build/AirTouch.app
make run     # build and launch
make test    # self-test, plist validation, and signature verification
```

## Architecture

- `CameraController` captures frames with AVFoundation.
- Vision detects one human hand pose locally.
- `GestureEngine` classifies pointing, pinch, double pinch, scroll, and palm swipes.
- `EventController` emits macOS mouse events and switches Spaces through System Events.
- `AppDelegate` exposes status and shutdown controls in the menu bar.

## Privacy

AirTouch does not use analytics, cloud inference, telemetry, or network APIs. Temporary diagnostic status is written only to `/tmp` while the app runs.
