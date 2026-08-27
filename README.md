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
| Fist with thumb and index free, move the thumb | Move the cursor — other hand shapes never touch it |
| Pinch thumb and index finger | Press the mouse button: a quick pinch clicks, holding it while moving selects an area or drags |
| Pinch twice quickly | Right-click |
| Hold an open palm, inner side to the camera | Set the anchor the swipe is measured from — the back of the hand is ignored |
| Flick from the anchor, left | Switch to the Space or full-screen window on the right |
| Flick from the anchor, right | Switch to the Space or full-screen window on the left |
| Raise index and middle fingers | Joystick scroll: where the fingers enter the pose is neutral, the offset above or below sets the speed |

An open palm anchors the swipe — three raised fingers are enough when the whole palm
does not fit the frame. The anchor sits on the middle knuckle, which stays confidently
tracked even when the wrist is cropped, and tolerates camera jitter: holding the hand
roughly still for a fifth of a second earns the origin. While the hand rests the anchor trails it on a leash, so drifting
across the frame never accumulates into a gesture; a deliberate move outruns the leash,
the origin freezes, and the swipe is measured from there. The move must cover the distance
within ~0.6 s — anything slower is drift and quietly re-anchors. A hand also has to stay
in frame for a quarter of a second before it may drive anything, misread frames in the
middle of a flick are forgiven, and for a moment after an anchor frame the cursor,
pinch, and scroll stay muted so a flick never jerks the pointer or clicks on its way
through. With several hands in frame the app obeys exactly one owner: the largest hand — the
nearest to the camera — takes control, and from then on ownership follows that hand by
continuity. Other hands in the background are ignored entirely, and when the owner's
hand is away no stranger inherits the controls.
The armed anchor is also the ignition: until the palm has earned it once — and again
after the hand has been out of frame for a couple of seconds — the cursor, pinch, and
scroll stay off, so a hand merely passing through the frame touches nothing.
Every threshold scales with the visible palm width, so gestures ask for the same
physical motion at the desk and across the room, and the cursor is driven relatively —
one palm width of hand travel moves it about a fifth of the screen at any distance,
picking up from wherever the cursor already stands. While the anchor is armed,
a soft glow along the screen edges shows that a flick will be honoured; when the glow
fades, the hand has been lost and the palm needs to settle again.

## Diagnostics

Live diagnostics live under `/tmp`:

- `airtouch-status.txt` — the current menu-bar status line;
- `airtouch-joints.txt` — joint confidences of the last seen hand;
- `airtouch-pose.txt` — how the engine reads the hand right now (finger flags, pose, anchor);
- `airtouch-events.log` — appended, timestamped journal of the session: hand found and
  lost, poses, anchor armed and lost, swipe departures with the reason a move was
  honoured or rejected, pinches, Space switches, and blocked system events. The previous
  session is kept as `airtouch-events.prev.log`.

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
