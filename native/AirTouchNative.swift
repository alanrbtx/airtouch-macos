import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Vision

private enum AirTouchConstants {
    static let bundleName = "AirTouch"
    static let swipeCooldown: TimeInterval = 0.95
    static let swipeDistance: CGFloat = 0.05
    static let minimumSwipeDuration: TimeInterval = 0.08
    /// How far the hand may wander and still count as sitting on the anchor.
    /// Sized to swallow Vision jitter after smoothing, not just a perfectly still hand.
    static let anchorHold: CGFloat = 0.030
    /// How long the open palm must sit still before it becomes a usable origin.
    static let anchorSettle: TimeInterval = 0.10
    /// The rest required after a swipe fires: the hand travelling back to centre kept
    /// re-arming in 0.2 s and the return stroke echoed a swipe the other way.
    static let anchorSettleAfterSwipe: TimeInterval = 0.45
    /// A misread frame mid-flick must not drop an anchor that was earned.
    static let anchorGrace: TimeInterval = 0.30
    /// A move that takes longer than this to cover the swipe distance is drift, not a flick.
    /// Sized for a slow deliberate slide, not just a snap of the wrist.
    static let maximumSwipeDuration: TimeInterval = 0.60
    /// The frame period the per-frame factors below are stated for; the detector
    /// rescales them to the actual frame spacing, so dynamics do not change with fps.
    static let referenceFrame: TimeInterval = 0.055
    /// EMA factor (per reference frame) that halves Vision jitter before the anchor
    /// logic sees it.
    static let anchorSmoothing: CGFloat = 0.5
    /// How fast the resting anchor trails the hand. The steady-state gap is
    /// speed / anchorFollow, so drift below ~0.15 frame-widths per second stays on the
    /// leash forever, while any deliberate move tears away within a few frames.
    static let anchorFollow: CGFloat = 0.28
    /// Joints below this confidence are noise, not a hand. Real joints at arm's length
    /// hover around 0.2-0.8; phantoms sit below ~0.1.
    static let jointConfidence: Float = 0.12
    /// A hand must stay visible this long before it is allowed to drive anything.
    static let engageDelay: TimeInterval = 0.25
    /// The armed anchor unlocks the cursor, pinch, and scroll; once the hand has been
    /// gone this long, the lock snaps shut and the palm must arm it again.
    static let disarmAfterLost: TimeInterval = 2.0
    /// How long the owner hand may vanish before another hand can take control.
    static let ownerGrace: TimeInterval = 1.2
    /// The pinch must hold for this long (two frames) before it clicks. Quick taps must
    /// survive, or a double pinch becomes impossible; phantom sources are gated by pose.
    static let pinchSettle: TimeInterval = 0.05
    /// A second pinch within this window after releasing a quick pinch is the double.
    /// Measured from the release; the journal put the user's natural pair cadence at
    /// 1.1-1.25 s.
    static let doublePinchWindow: TimeInterval = 1.25
    /// A press held longer than this was a hold, not a click. Drags are told apart by
    /// movement, so an unhurried tap may take its time.
    static let quickClickLimit: TimeInterval = 0.80
    /// A press that travelled further than this fraction of the screen was a drag,
    /// and releasing it never opens the double window.
    static let clickMoveLimit: CGFloat = 0.035
    /// The second pinch of a double must land within this fraction of the screen of
    /// the first — two clicks in different places are two clicks, not a double.
    static let doubleClickSlop: CGFloat = 0.05
    /// The thumb and index must genuinely close: in the mouse pose the idle index
    /// hovers near the thumb at ~0.3-0.5 of palm width, and the old 0.34 gate fired
    /// phantom clicks off that hover jitter all session long.
    static let pinchRatio: CGFloat = 0.26
    static let releasePinchRatio: CGFloat = 0.40
    static let pointerFrameInterval: TimeInterval = 1.0 / 60.0
    /// Cursor smoothing floor (per reference frame): tremor near the target stays
    /// damped this hard.
    static let pointerBaseSmoothing: CGFloat = 0.10
    /// How quickly smoothing lightens as the hand pulls away from the cursor.
    static let pointerSmoothingGain: CGFloat = 5.0
    /// Cursor smoothing ceiling (per reference frame) once the hand is on the move.
    static let pointerAgility: CGFloat = 0.50
    /// Palm width (index to little knuckle) of a hand at typical desk distance; the
    /// measured width against this reference is the distance proxy all thresholds scale by.
    static let referencePalm: CGFloat = 0.12
    /// Screens of cursor travel per palm width of hand travel, at any distance.
    static let pointerGain: CGFloat = 0.22
    /// Joystick scroll: offsets within this many palm widths of the neutral point rest.
    static let scrollDeadzone: CGFloat = 0.20
    /// Scroll speed per palm width of offset beyond the deadzone, in px/s.
    static let scrollGain: CGFloat = 1400
    /// Scroll speed ceiling, px/s.
    static let scrollMaxSpeed: CGFloat = 1600
}

private enum SwipeDirection: String {
    case left
    case right
}

/// Appended, timestamped journal of everything the engine sees and decides, so a failed
/// session can be replayed from /tmp/airtouch-events.log after the fact.
private final class EventLog {
    static let shared = EventLog()
    private let queue = DispatchQueue(label: "airtouch.log", qos: .utility)
    private let handle: FileHandle?
    private let formatter: DateFormatter
    private var lastThrottle: [String: TimeInterval] = [:]

    private init() {
        let path = "/tmp/airtouch-events.log"
        let previous = "/tmp/airtouch-events.prev.log"
        let manager = FileManager.default
        if manager.fileExists(atPath: path) {
            try? manager.removeItem(atPath: previous)
            try? manager.moveItem(atPath: path, toPath: previous)
        }
        manager.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)
        formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
    }

    /// Appends one line. With `every`, lines under the same tag are throttled to that
    /// interval so per-frame detail does not flood the journal.
    func log(_ tag: String, _ message: String, every interval: TimeInterval = 0) {
        queue.async { [self] in
            if interval > 0 {
                let now = ProcessInfo.processInfo.systemUptime
                if let last = lastThrottle[tag], now - last < interval { return }
                lastThrottle[tag] = now
            }
            let line = "\(formatter.string(from: Date())) [\(tag)] \(message)\n"
            if let data = line.data(using: .utf8) { handle?.write(data) }
        }
    }
}

/// Turns an open palm into a fixed origin and reads the swipe as displacement away
/// from it.
///
/// While the hand rests, the anchor follows it, so slow drift never accumulates. The moment
/// the hand leaves the anchor the origin freezes, and the swipe is measured from there —
/// so a short deliberate move counts, while creeping across the frame does not.
private final class SwipeDetector {
    private var smoothed: CGPoint?
    private var anchor: CGPoint?
    private var anchorAt: TimeInterval = 0
    private var departedAt: TimeInterval?
    private var ready = false
    private var lastSwipeAt: TimeInterval = -.greatestFiniteMagnitude
    private var lastUpdateAt: TimeInterval?

    /// Receives one line per notable decision, for the event journal.
    var debug: ((String) -> Void)?
    private var requiredSettle: TimeInterval = AirTouchConstants.anchorSettle

    func reset() {
        smoothed = nil
        anchor = nil
        departedAt = nil
        ready = false
        lastUpdateAt = nil
    }

    /// True once the palm has been held still long enough for the anchor to count.
    var isReady: Bool { ready }

    func update(point raw: CGPoint, time: TimeInterval, scale: CGFloat = 1.0) -> SwipeDirection? {
        // The per-frame factors are stated for the reference frame period; rescale them
        // to the actual spacing so the leash and the filter behave identically at any
        // frame rate.
        let dt = min(max(time - (lastUpdateAt ?? time - AirTouchConstants.referenceFrame), 0.01), 0.2)
        lastUpdateAt = time
        let frames = dt / AirTouchConstants.referenceFrame
        let smoothingFactor = 1 - CGFloat(pow(Double(1 - AirTouchConstants.anchorSmoothing), frames))
        let followFactor = 1 - CGFloat(pow(Double(1 - AirTouchConstants.anchorFollow), frames))

        // Halve the Vision jitter before the anchor logic sees it. A one-frame lag on
        // a flick is invisible; jitter breaking the settle timer was fatal.
        let point: CGPoint
        if let previous = smoothed {
            point = CGPoint(
                x: previous.x + (raw.x - previous.x) * smoothingFactor,
                y: previous.y + (raw.y - previous.y) * smoothingFactor
            )
        } else {
            point = raw
        }
        smoothed = point

        guard let origin = anchor else {
            place(point, at: time)
            return nil
        }

        let dx = point.x - origin.x
        let dy = point.y - origin.y

        // Resting: the anchor trails the hand instead of snapping to it. Slow drift never
        // outruns the leash, so it re-centres forever; a real flick outruns it in a frame
        // or two, and only then does the origin freeze and displacement start counting.
        if hypot(dx, dy) < AirTouchConstants.anchorHold * scale {
            anchor = CGPoint(
                x: origin.x + dx * followFactor,
                y: origin.y + dy * followFactor
            )
            departedAt = nil
            if time - anchorAt >= requiredSettle {
                ready = true
                requiredSettle = AirTouchConstants.anchorSettle
            }
            return nil
        }

        // The hand left an anchor it never earned. A wave, or a hand on its way somewhere
        // else, passes through here every frame and never gets to swipe.
        guard ready else {
            place(point, at: time)
            return nil
        }

        if departedAt == nil {
            debug?(String(format: "departed dx=%.3f dy=%.3f", dx, dy))
        }
        let departure = departedAt ?? time
        departedAt = departure

        // Away from the anchor for too long without covering the distance: not a flick.
        if time - departure > AirTouchConstants.maximumSwipeDuration {
            debug?(String(format: "rejected: %.2fs from anchor, dx=%.3f dy=%.3f — too slow",
                          time - departure, dx, dy))
            place(point, at: time)
            return nil
        }

        guard time - lastSwipeAt >= AirTouchConstants.swipeCooldown,
              time - departure >= AirTouchConstants.minimumSwipeDuration,
              abs(dx) >= AirTouchConstants.swipeDistance * scale,
              abs(dx) > abs(dy) * 1.2
        else { return nil }

        lastSwipeAt = time
        reset()
        // The hand now travels back to centre; that return stroke must not echo.
        requiredSettle = AirTouchConstants.anchorSettleAfterSwipe
        let direction: SwipeDirection = dx < 0 ? .left : .right
        debug?(String(format: "swipe %@ dx=%.3f dt=%.2f", direction.rawValue, dx, time - departure))
        return direction
    }

    private func place(_ point: CGPoint, at time: TimeInterval) {
        anchor = point
        anchorAt = time
        departedAt = nil
        ready = false
    }
}

private final class EventController {
    var isTrusted: Bool { AXIsProcessTrusted() }

    func requestAccessibility() {
        guard !isTrusted else { return }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private var buttonIsDown = false

    /// True while the pinch is holding the mouse button down.
    var isPressing: Bool { buttonIsDown }

    @discardableResult
    func moveCursor(normalized point: CGPoint) -> Bool {
        guard isTrusted else {
            EventLog.shared.log("events", "blocked: accessibility not granted", every: 3)
            return false
        }
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let x = bounds.minX + min(max(point.x, 0), 1) * bounds.width
        let y = bounds.minY + min(max(point.y, 0), 1) * bounds.height
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: buttonIsDown ? .leftMouseDragged : .mouseMoved,
            mouseCursorPosition: CGPoint(x: x, y: y),
            mouseButton: .left
        ) else { return false }
        if buttonIsDown {
            event.setIntegerValueField(.mouseEventClickState, value: 1)
        }
        event.post(tap: .cghidEventTap)
        return true
    }

    /// The current cursor position in normalized main-display coordinates.
    func cursorPosition() -> CGPoint? {
        guard let location = CGEvent(source: nil)?.location else { return nil }
        let bounds = CGDisplayBounds(CGMainDisplayID())
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        return CGPoint(
            x: (location.x - bounds.minX) / bounds.width,
            y: (location.y - bounds.minY) / bounds.height
        )
    }

    /// Presses the mouse button and keeps it down: a quick release is a click,
    /// moving the cursor first sweeps out a selection or drags.
    @discardableResult
    func beginPress() -> Bool {
        guard isTrusted, !buttonIsDown, let location = CGEvent(source: nil)?.location else { return false }
        guard let down = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: location,
            mouseButton: .left
        ) else { return false }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        down.post(tap: .cghidEventTap)
        buttonIsDown = true
        return true
    }

    /// A complete right-button click at the current cursor position.
    @discardableResult
    func rightClick() -> Bool {
        guard isTrusted, !buttonIsDown, let location = CGEvent(source: nil)?.location else { return false }
        guard let down = CGEvent(
            mouseEventSource: nil,
            mouseType: .rightMouseDown,
            mouseCursorPosition: location,
            mouseButton: .right
        ), let up = CGEvent(
            mouseEventSource: nil,
            mouseType: .rightMouseUp,
            mouseCursorPosition: location,
            mouseButton: .right
        ) else { return false }
        // Real clicks carry clickState 1. Finder forgives its absence; Qt apps such as
        // Telegram Desktop silently drop right clicks without it.
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        down.post(tap: .cghidEventTap)
        usleep(35_000)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// Releases the mouse button if it is down. Safe to call from any state.
    @discardableResult
    func endPress() -> Bool {
        guard buttonIsDown else { return false }
        buttonIsDown = false
        guard isTrusted, let location = CGEvent(source: nil)?.location,
              let up = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseUp,
                mouseCursorPosition: location,
                mouseButton: .left
              )
        else { return false }
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        up.post(tap: .cghidEventTap)
        return true
    }

    @discardableResult
    func scroll(delta: CGFloat) -> Bool {
        guard isTrusted else { return false }
        let clamped = Int32(min(max(delta, -90), 90).rounded())
        guard abs(clamped) >= 1,
              let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 1,
                wheel1: clamped,
                wheel2: 0,
                wheel3: 0
              )
        else { return false }
        event.post(tap: .cghidEventTap)
        return true
    }

    @discardableResult
    func switchWindow(for swipe: SwipeDirection) -> Bool {
        guard isTrusted else { return false }
        let keyCode = swipe == .left ? 124 : 123
        let script = "tell application \"System Events\" to key code \(keyCode) using control down"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        do {
            try process.run()
            process.waitUntilExit()
            EventLog.shared.log("events", "space switch \(swipe.rawValue): status \(process.terminationStatus)")
            return process.terminationStatus == 0
        } catch {
            EventLog.shared.log("events", "space switch \(swipe.rawValue) failed: \(error.localizedDescription)")
            return false
        }
    }
}

private final class GestureEngine {
    private let events: EventController
    private let swipeDetector = SwipeDetector()
    private let onGesture: (String) -> Void
    private let onAnchorState: (Bool) -> Void
    private var anchorShown = false
    private var controlsArmed = false
    private var lastProcessedAt: TimeInterval = -.greatestFiniteMagnitude
    private var pointerModeActive = false
    private var ownerPoint: CGPoint?
    private var ownerSeenAt: TimeInterval = -.greatestFiniteMagnitude
    private var pointer = CGPoint(x: 0.5, y: 0.5)
    private var pointerTarget = CGPoint(x: 0.5, y: 0.5)
    private var lastCursorAnchor: CGPoint?
    private var lastCursorAnchorAt: TimeInterval = 0
    private var handScale: CGFloat = -1
    private var pinchActive = false
    private var lastQuickClickAt: TimeInterval = -.greatestFiniteMagnitude
    private var lastQuickClickPointer: CGPoint?
    private var pressStartedAt: TimeInterval = 0
    private var pressStartPointer = CGPoint.zero
    private var lastPointerAt: TimeInterval = 0
    private var lastPointerStatusAt: TimeInterval = 0
    private var lastDiagnosticsAt: TimeInterval = 0
    private var lastPoseDiagnosticsAt: TimeInterval = 0
    private var scrollOriginY: CGFloat?
    private var scrollPoseSince: TimeInterval?
    private var lastScrollPoseAt: TimeInterval = -.greatestFiniteMagnitude
    private var lastScrollFrameAt: TimeInterval = 0
    private var lastScrollStatusAt: TimeInterval = 0
    private var lastAnchorPoseAt: TimeInterval = -.greatestFiniteMagnitude
    private var handVisibleSince: TimeInterval?
    private var pinchCandidateAt: TimeInterval?

    init(
        events: EventController,
        onGesture: @escaping (String) -> Void,
        onAnchorState: @escaping (Bool) -> Void
    ) {
        self.events = events
        self.onGesture = onGesture
        self.onAnchorState = onAnchorState
        swipeDetector.debug = { EventLog.shared.log("swipe", $0) }
    }

    /// Tells the app when the armed anchor appears or disappears, exactly once per change.
    private func announceAnchor() {
        let ready = swipeDetector.isReady
        if ready, !controlsArmed {
            controlsArmed = true
            EventLog.shared.log("gate", "controls armed by the anchor")
            onGesture("Ладонь взведена · управление включено")
        }
        guard ready != anchorShown else { return }
        anchorShown = ready
        EventLog.shared.log("anchor", ready ? "armed" : "lost")
        onAnchorState(ready)
    }

    func handLost(at time: TimeInterval) {
        pinchActive = false
        pinchCandidateAt = nil
        lastQuickClickAt = -.greatestFiniteMagnitude
        events.endPress()
        handVisibleSince = nil
        scrollOriginY = nil
        scrollPoseSince = nil
        // A blurred frame mid-flick loses the whole hand first. The anchor survives the
        // grace window so the flick can still finish when the hand is picked up again.
        if time - lastAnchorPoseAt > AirTouchConstants.anchorGrace {
            swipeDetector.reset()
            announceAnchor()
        }
    }

    /// Chooses the hand this engine obeys. The hand it was already following wins by
    /// proximity; with no current owner, the largest hand in frame — the nearest to
    /// the camera — takes control, so somebody else's hand in the background never
    /// seizes the cursor.
    func process(_ observations: [VNHumanHandPoseObservation], at time: TimeInterval) {
        struct Candidate {
            let joints: [VNHumanHandPoseObservation.JointName: VNRecognizedPoint]
            let chirality: VNChirality
            let centroid: CGPoint
            let size: CGFloat
        }
        var candidates: [Candidate] = []
        for observation in observations {
            guard let joints = try? observation.recognizedPoints(.all) else { continue }
            let good = joints.values.filter { $0.confidence >= AirTouchConstants.jointConfidence }
            guard good.count >= 4 else { continue }
            let xs = good.map(\.location.x)
            let ys = good.map(\.location.y)
            let centroid = CGPoint(
                x: xs.reduce(0, +) / CGFloat(xs.count),
                y: ys.reduce(0, +) / CGFloat(ys.count)
            )
            let size: CGFloat
            if let index = joints[.indexMCP], let little = joints[.littleMCP],
               index.confidence >= AirTouchConstants.jointConfidence,
               little.confidence >= AirTouchConstants.jointConfidence {
                size = hypot(
                    index.location.x - little.location.x,
                    index.location.y - little.location.y
                )
            } else {
                size = max(xs.max()! - xs.min()!, ys.max()! - ys.min()!) * 0.5
            }
            candidates.append(Candidate(
                joints: joints, chirality: observation.chirality,
                centroid: centroid, size: size
            ))
        }
        guard !candidates.isEmpty else {
            handLost(at: time)
            return
        }

        if time - ownerSeenAt > AirTouchConstants.ownerGrace { ownerPoint = nil }
        let chosen: Candidate
        if let owner = ownerPoint {
            let nearest = candidates.min {
                hypot($0.centroid.x - owner.x, $0.centroid.y - owner.y)
                    < hypot($1.centroid.x - owner.x, $1.centroid.y - owner.y)
            }!
            let jump = hypot(nearest.centroid.x - owner.x, nearest.centroid.y - owner.y)
            let allowedJump = 0.25 + CGFloat(time - ownerSeenAt) * 0.6
            guard jump <= allowedJump else {
                // Only strangers in the frame: the owner's hand is simply not here.
                EventLog.shared.log(
                    "owner",
                    String(format: "no hand near the owner (nearest %.2f away)", jump),
                    every: 1
                )
                handLost(at: time)
                return
            }
            chosen = nearest
        } else {
            chosen = candidates.max { $0.size < $1.size }!
            EventLog.shared.log(
                "owner",
                String(format: "adopted the largest of %d hands, size=%.2f",
                       candidates.count, chosen.size)
            )
        }
        ownerPoint = chosen.centroid
        ownerSeenAt = time
        processHand(
            joints: chosen.joints, chirality: chosen.chirality,
            handsInFrame: candidates.count, at: time
        )
    }

    private func processHand(
        joints: [VNHumanHandPoseObservation.JointName: VNRecognizedPoint],
        chirality: VNChirality,
        handsInFrame: Int,
        at time: TimeInterval
    ) {

        if time - lastDiagnosticsAt >= 0.25 {
            lastDiagnosticsAt = time
            let names: [(String, VNHumanHandPoseObservation.JointName)] = [
                ("wrist", .wrist),
                ("indexTip", .indexTip),
                ("indexDIP", .indexDIP),
                ("indexPIP", .indexPIP),
                ("indexMCP", .indexMCP),
                ("middleTip", .middleTip),
                ("ringTip", .ringTip),
                ("littleTip", .littleTip),
                ("thumbTip", .thumbTip),
            ]
            let line = names.map { name, joint in
                String(format: "%@=%.3f", name, joints[joint]?.confidence ?? 0)
            }.joined(separator: " ")
            try? line.write(
                to: URL(fileURLWithPath: "/tmp/airtouch-joints.txt"),
                atomically: true,
                encoding: .utf8
            )
            EventLog.shared.log("joints", line, every: 1)
        }

        func point(_ joint: VNHumanHandPoseObservation.JointName) -> CGPoint? {
            guard let recognized = joints[joint],
                  recognized.confidence >= AirTouchConstants.jointConfidence else { return nil }
            return recognized.location
        }

        guard let indexTip = point(.indexTip) ?? point(.indexDIP) ?? point(.indexPIP) else {
            EventLog.shared.log("hand", "index joints below confidence gate", every: 1)
            handLost(at: time)
            return
        }
        if handVisibleSince == nil { handVisibleSince = time }
        if time - lastProcessedAt > AirTouchConstants.disarmAfterLost {
            controlsArmed = false
        }
        lastProcessedAt = time
        let indexPIP = point(.indexPIP) ?? point(.indexMCP) ?? indexTip

        // The wrist is the first joint to slide out of the frame; never require it.
        let wrist = point(.wrist)
        let middleTip = point(.middleTip)
        let middlePIP = point(.middlePIP)
        let middleMCP = point(.middleMCP)
        let ringTip = point(.ringTip)
        let ringPIP = point(.ringPIP)
        let ringMCP = point(.ringMCP)
        let littleTip = point(.littleTip)
        let littlePIP = point(.littlePIP)
        let thumbTip = point(.thumbTip)
        let indexMCP = point(.indexMCP)
        let littleMCP = point(.littleMCP)

        // The palm width read off the knuckles is the distance proxy: every threshold
        // scales with it, so gestures ask for the same physical motion at the desk and
        // across the room.
        if let indexMCP, let littleMCP {
            let width = hypot(indexMCP.x - littleMCP.x, indexMCP.y - littleMCP.y)
            if width > 0.015 {
                handScale = handScale <= 0 ? width : handScale + (width - handScale) * 0.3
            }
        }
        let palm = handScale > 0 ? handScale : AirTouchConstants.referencePalm
        let scaleFactor = min(max(palm / AirTouchConstants.referencePalm, 0.35), 1.8)

        // Which side faces the camera. Vision reports the chirality of the physical
        // hand even in the mirrored frame (verified live: the first sign convention
        // came out inverted), so for a right hand shown palm-in the index knuckle sits
        // right of the little one, and a left hand mirrors it. The knuckle row of a
        // raised hand must only anchor when the inner side shows.
        let palmFacing: Bool
        var chiralityTag = "u"
        if let indexMCP, let littleMCP {
            switch chirality {
            case .right:
                chiralityTag = "r"
                palmFacing = indexMCP.x > littleMCP.x
            case .left:
                chiralityTag = "l"
                palmFacing = indexMCP.x < littleMCP.x
            default:
                palmFacing = true
            }
        } else {
            palmFacing = true
        }

        // A finger counts as raised when its tip stands far from its own knuckle and is
        // not below its middle joint. The knuckles stay confidently tracked even when
        // the palm and wrist slide out of frame — exactly when the old wrist-based test
        // went blind and the whole engine reported a lost hand.
        func extended(tip: CGPoint?, pip: CGPoint?, mcp: CGPoint?) -> Bool {
            guard let tip, let pip else { return false }
            if let mcp {
                let tipDistance = hypot(tip.x - mcp.x, tip.y - mcp.y)
                let pipDistance = hypot(pip.x - mcp.x, pip.y - mcp.y)
                return tipDistance > pipDistance * 1.35 && tip.y > pip.y - 0.005
            }
            guard let wrist else { return false }
            let tipDistance = hypot(tip.x - wrist.x, tip.y - wrist.y)
            let pipDistance = hypot(pip.x - wrist.x, pip.y - wrist.y)
            return tipDistance > pipDistance * 1.06
        }
        let indexExtended = extended(tip: indexTip, pip: indexPIP, mcp: indexMCP)
        let middleExtended = extended(tip: middleTip, pip: middlePIP, mcp: middleMCP)
        let ringExtended = extended(tip: ringTip, pip: ringPIP, mcp: ringMCP)
        let littleExtended = extended(tip: littleTip, pip: littlePIP, mcp: littleMCP)
        let extendedCount = [indexExtended, middleExtended, ringExtended, littleExtended]
            .filter { $0 }.count
        let openPalm = extendedCount >= 3 && palmFacing

        // The mouse is its own deliberate pose: middle, ring, and little fingers curled
        // into a fist, thumb and index free to point and pinch, knuckles facing the
        // camera. The back of a raised hand, or a hand folded up to the chin, matches
        // none of that and must never sweep the cursor around.
        let knucklesVisible = indexMCP != nil
            && (middleMCP != nil || ringMCP != nil || littleMCP != nil)
        // A plain fist also has those three fingers curled — what tells the mouse pose
        // apart is the thumb standing clear of the knuckle row. In a fist the thumb
        // lies folded across it, the thumb-to-index-knuckle distance collapses, and the
        // thumb resting next to the index fired phantom pinches all session long.
        var thumbClearance: CGFloat = -1
        if let thumbTip, let indexMCP, let littleMCP {
            let palmWidth = hypot(indexMCP.x - littleMCP.x, indexMCP.y - littleMCP.y)
            if palmWidth > 0.02 {
                thumbClearance = hypot(thumbTip.x - indexMCP.x, thumbTip.y - indexMCP.y) / palmWidth
            }
        }
        let pointerPose = !middleExtended && !ringExtended && !littleExtended
            && knucklesVisible && thumbClearance > 0.55

        if time - lastPoseDiagnosticsAt >= 0.25 {
            lastPoseDiagnosticsAt = time
            let flags = [
                "idx=\(indexExtended ? 1 : 0)",
                "mid=\(middleExtended ? 1 : 0)",
                "ring=\(ringExtended ? 1 : 0)",
                "lit=\(littleExtended ? 1 : 0)",
                "palm=\(openPalm ? 1 : 0)",
                "face=\(palmFacing ? 1 : 0)\(chiralityTag)",
                "ptr=\(pointerPose ? 1 : 0)",
                String(format: "thumbd=%.2f", thumbClearance),
                String(format: "scale=%.2f", scaleFactor),
                "hands=\(handsInFrame)",
                "ready=\(swipeDetector.isReady ? 1 : 0)",
                "wrist=\(wrist == nil ? 0 : 1)",
            ].joined(separator: " ")
            try? flags.write(
                to: URL(fileURLWithPath: "/tmp/airtouch-pose.txt"),
                atomically: true,
                encoding: .utf8
            )
            EventLog.shared.log("pose", flags, every: 1)
        }

        // The anchor wants the steadiest point on the hand. The middle knuckle is the
        // palm's centre of gravity and stays confidently tracked even when the wrist is
        // cropped out of the frame; nearby knuckles stand in when it drops, and only
        // then the fingertips.
        let anchorTips = [indexTip, middleTip, ringTip].compactMap { $0 }
        let tipsCenter = CGPoint(
            x: anchorTips.map(\.x).reduce(0, +) / CGFloat(anchorTips.count),
            y: anchorTips.map(\.y).reduce(0, +) / CGFloat(anchorTips.count)
        )
        let anchorPoint = middleMCP ?? indexMCP ?? ringMCP ?? tipsCenter

        if openPalm {
            scrollOriginY = nil
            scrollPoseSince = nil
            pinchActive = false
            pinchCandidateAt = nil
            lastQuickClickAt = -.greatestFiniteMagnitude
            lastQuickClickPointer = nil
            events.endPress()
            lastAnchorPoseAt = time
            let wasReady = swipeDetector.isReady
            if let direction = swipeDetector.update(point: anchorPoint, time: time, scale: scaleFactor) {
                if events.switchWindow(for: direction) {
                    onGesture(direction == .left ? "Свайп влево · окно справа" : "Свайп вправо · окно слева")
                }
            } else if swipeDetector.isReady, !wasReady {
                onGesture("Ладонь · точка отсчёта · можно вести")
            }
            announceAnchor()
            return
        }

        // Right after an anchor frame the pose is either a flick in progress or a misread.
        // Keep feeding the detector so the flick can finish, and keep the cursor, pinch,
        // and scroll out of it — mid-flick frames used to jerk the cursor and click.
        if time - lastAnchorPoseAt <= AirTouchConstants.anchorGrace {
            if swipeDetector.isReady,
               let direction = swipeDetector.update(point: anchorPoint, time: time, scale: scaleFactor),
               events.switchWindow(for: direction) {
                onGesture(direction == .left ? "Свайп влево · окно справа" : "Свайп вправо · окно слева")
            }
            announceAnchor()
            return
        }
        swipeDetector.reset()
        announceAnchor()

        // A hand that only just appeared does not get to drive anything: a passer-by in
        // the frame, or a one-off misdetection, vanishes before the delay runs out.
        guard time - (handVisibleSince ?? time) >= AirTouchConstants.engageDelay else { return }

        var pinchRatio: CGFloat?
        if let thumbTip, let indexMCP, let littleMCP {
            let palmWidth = hypot(indexMCP.x - littleMCP.x, indexMCP.y - littleMCP.y)
            let pinchDistance = hypot(indexTip.x - thumbTip.x, indexTip.y - thumbTip.y)
            pinchRatio = palmWidth > 0.02 ? pinchDistance / palmWidth : nil
        }

        // The anchor is the ignition: until the palm has armed it — and again after the
        // hand has been away — the cursor, pinch, and scroll stay off, so a hand merely
        // passing through the frame can not touch anything.
        guard controlsArmed else {
            pinchCandidateAt = nil
            EventLog.shared.log("gate", "hand seen but controls not armed — show the palm", every: 3)
            return
        }

        let twoFingerScroll = indexExtended && middleExtended && !ringExtended && !littleExtended
        if twoFingerScroll, let middleTip {
            if pinchActive {
                pinchActive = false
                pinchCandidateAt = nil
                lastQuickClickAt = -.greatestFiniteMagnitude
                lastQuickClickPointer = nil
                events.endPress()
            }
            lastScrollPoseAt = time
            let since = scrollPoseSince ?? time
            scrollPoseSince = since
            // The pose must stand for a moment: one misread frame used to flap the
            // hand between scroll and cursor mid-gesture.
            guard time - since >= 0.12 else { return }
            guard let originY = scrollOriginY else {
                // Joystick scrolling: where the fingers enter the pose becomes a
                // neutral point, and the vertical offset from it sets the scroll
                // speed. The old 1:1 glue meant every return stroke undid the
                // scroll and every pixel of jitter rattled the page.
                scrollOriginY = middleTip.y
                lastScrollFrameAt = time
                EventLog.shared.log("scroll", "engaged, neutral set")
                onGesture("Два пальца · скролл")
                return
            }
            let dt = min(max(time - lastScrollFrameAt, 0.01), 0.2)
            lastScrollFrameAt = time
            let offset = (middleTip.y - originY) / palm
            let magnitude = abs(offset)
            if magnitude > AirTouchConstants.scrollDeadzone {
                let speed = min(
                    (magnitude - AirTouchConstants.scrollDeadzone) * AirTouchConstants.scrollGain,
                    AirTouchConstants.scrollMaxSpeed
                )
                let delta = speed * CGFloat(dt) * (offset > 0 ? 1 : -1)
                if events.scroll(delta: delta), time - lastScrollStatusAt >= 0.8 {
                    lastScrollStatusAt = time
                    EventLog.shared.log(
                        "scroll",
                        String(format: "offset=%.2f palms, speed=%.0f px/s", offset, speed),
                        every: 1
                    )
                    onGesture("Два пальца · прокрутка")
                }
            }
            return
        }
        // A brief dropout of the scroll pose must not dump the hand into the cursor
        // mid-scroll; only a real pose change ends the session.
        if scrollOriginY != nil, time - lastScrollPoseAt <= 0.15 { return }
        scrollOriginY = nil
        scrollPoseSince = nil

        // Only the deliberate mouse pose may drive the cursor and pinch, and entering
        // it is strict: the index must be curled into the fist too, so a pointing,
        // gesturing hand never grabs the cursor. Once inside, the gate relaxes — the
        // index is free to rise toward the thumb for the pinch and the flags may
        // flicker — and an active press survives regardless, so drags never drop.
        if pointerModeActive {
            if !(pointerPose || events.isPressing) {
                pointerModeActive = false
                pinchCandidateAt = nil
                return
            }
        } else {
            guard pointerPose, !indexExtended else {
                pinchCandidateAt = nil
                return
            }
            pointerModeActive = true
            EventLog.shared.log("gate", "pointer mode entered (strict fist)")
        }

        // The thumb is the stable cursor anchor. The index finger is free to close
        // the pinch without dragging the cursor away from the intended target.
        // The drive is relative: hand motion is measured in palm widths, so the same
        // wrist sweep moves the cursor the same amount at the desk and across the room —
        // the old absolute frame-to-screen mapping demanded metre-long waves far away.
        if time - lastPointerAt >= AirTouchConstants.pointerFrameInterval {
            let pointerDt = min(max(time - lastPointerAt, 0.01), 0.2)
            lastPointerAt = time
            let cursorAnchor = thumbTip ?? indexTip
            if let previous = lastCursorAnchor, time - lastCursorAnchorAt <= 0.25 {
                var dx = cursorAnchor.x - previous.x
                var dy = -(cursorAnchor.y - previous.y)
                if hypot(dx, dy) > palm * 1.2 {
                    // A tracking glitch teleports the joint; a hand does not.
                    dx = 0
                    dy = 0
                }
                pointerTarget.x = min(max(pointerTarget.x + dx / palm * AirTouchConstants.pointerGain, 0), 1)
                pointerTarget.y = min(max(pointerTarget.y + dy / palm * AirTouchConstants.pointerGain, 0), 1)
            } else if let current = events.cursorPosition() {
                // A freshly engaged hand picks the cursor up where it stands.
                pointerTarget = current
                pointer = current
            }
            lastCursorAnchor = cursorAnchor
            lastCursorAnchorAt = time
            // Tremor stays heavily smoothed, but a real move frees the cursor: the
            // further the target has pulled ahead, the lighter the filter, so the
            // pointer snaps after the hand instead of oozing behind it.
            let distance = hypot(pointerTarget.x - pointer.x, pointerTarget.y - pointer.y)
            let perFrame = min(
                AirTouchConstants.pointerAgility,
                AirTouchConstants.pointerBaseSmoothing
                    + distance * AirTouchConstants.pointerSmoothingGain
            )
            // Stated per reference frame and rescaled to the real spacing, so the damping
            // does not thin out as the frame rate rises.
            let smoothing = 1 - CGFloat(pow(Double(1 - perFrame), pointerDt / AirTouchConstants.referenceFrame))
            pointer.x += (pointerTarget.x - pointer.x) * smoothing
            pointer.y += (pointerTarget.y - pointer.y) * smoothing
            if events.moveCursor(normalized: pointer), time - lastPointerStatusAt >= 0.8 {
                lastPointerStatusAt = time
                onGesture(events.isPressing ? "Щипок · выделение" : "Большой палец · курсор")
            }
        }

        // Press only after the cursor has been updated from the thumb position. The pinch
        // holds the button down: released at once it is a click, moved first it sweeps out
        // a selection or drags whatever it grabbed.
        if let pinchRatio {
            EventLog.shared.log(
                "pinch",
                String(format: "ratio=%.2f active=%d", pinchRatio, pinchActive ? 1 : 0),
                every: 1
            )
            if pinchRatio <= AirTouchConstants.pinchRatio {
                // One noisy frame is not a pinch; it has to survive into a second frame.
                let candidate = pinchCandidateAt ?? time
                pinchCandidateAt = candidate
                if !pinchActive, time - candidate >= AirTouchConstants.pinchSettle {
                    pinchActive = true
                    let sameSpot = lastQuickClickPointer.map {
                        hypot(pointerTarget.x - $0.x, pointerTarget.y - $0.y)
                            <= AirTouchConstants.doubleClickSlop
                    } ?? false
                    if time - lastQuickClickAt <= AirTouchConstants.doublePinchWindow, sameSpot {
                        lastQuickClickAt = -.greatestFiniteMagnitude
                        lastQuickClickPointer = nil
                        if events.rightClick() {
                            onGesture("Двойной щипок · правый клик")
                        }
                    } else if events.beginPress() {
                        pressStartedAt = time
                        pressStartPointer = pointerTarget
                        onGesture("Щипок · зажато")
                    }
                }
            } else {
                pinchCandidateAt = nil
                if pinchRatio >= AirTouchConstants.releasePinchRatio, pinchActive {
                    pinchActive = false
                    if events.endPress() {
                        // A click is told from a drag the way a mouse tells them: by
                        // how far the cursor travelled while the button was down.
                        let duration = time - pressStartedAt
                        let moved = hypot(
                            pointerTarget.x - pressStartPointer.x,
                            pointerTarget.y - pressStartPointer.y
                        )
                        let quick = duration <= AirTouchConstants.quickClickLimit
                            && moved <= AirTouchConstants.clickMoveLimit
                        lastQuickClickAt = quick ? time : -.greatestFiniteMagnitude
                        lastQuickClickPointer = quick ? pointerTarget : nil
                        EventLog.shared.log("pinch", String(
                            format: "released after %.2fs, moved %.3f — %@",
                            duration, moved, quick ? "double window armed" : "single"
                        ))
                        onGesture("Щипок отпущен")
                    }
                }
            }
        }
    }
}

private final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "airtouch.camera", qos: .userInteractive)
    private let request = VNDetectHumanHandPoseRequest()
    private let engine: GestureEngine
    private let onStatus: (String) -> Void
    private var lastHandAt: TimeInterval = 0
    private var lastProcessedFrameAt: TimeInterval = 0
    private var handWasVisible = false

    init(engine: GestureEngine, onStatus: @escaping (String) -> Void) {
        self.engine = engine
        self.onStatus = onStatus
        super.init()
        request.maximumHandCount = 4
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    self?.configureAndStart()
                } else {
                    self?.onStatus("Нет доступа к камере")
                }
            }
        default:
            onStatus("Разрешите камеру в настройках")
        }
    }

    func stop() {
        captureQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configureAndStart() {
        captureQueue.async { [self] in
            session.beginConfiguration()
            session.sessionPreset = .medium

            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                ?? AVCaptureDevice.default(for: .video)
            guard let device,
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input)
            else {
                session.commitConfiguration()
                onStatus("Камера не найдена")
                return
            }
            session.addInput(input)

            // Ask the camera for 60 fps: raise the rate on the active format, or switch
            // to the smallest 60-capable format at or above 480p when the active one
            // cannot. FaceTime cameras that top out at 30 keep 30 — the journal shows
            // what was actually granted.
            do {
                try device.lockForConfiguration()
                var chosen = device.activeFormat
                let supports60 = { (format: AVCaptureDevice.Format) in
                    format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 59 }
                }
                if !supports60(chosen) {
                    let candidates = device.formats.filter { format in
                        CMVideoFormatDescriptionGetDimensions(format.formatDescription).height >= 480
                            && supports60(format)
                    }
                    if let smallest = candidates.min(by: {
                        CMVideoFormatDescriptionGetDimensions($0.formatDescription).height
                            < CMVideoFormatDescriptionGetDimensions($1.formatDescription).height
                    }) {
                        device.activeFormat = smallest
                        chosen = smallest
                    }
                }
                let maxRate = chosen.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
                let rate = min(60, maxRate)
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(rate.rounded()))
                device.unlockForConfiguration()
                EventLog.shared.log("camera", String(format: "frame rate %.0f fps (device max %.0f)", rate, maxRate))
            } catch {
                EventLog.shared.log("camera", "frame rate config failed: \(error.localizedDescription)")
            }

            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ]
            output.setSampleBufferDelegate(self, queue: captureQueue)
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                onStatus("Не удалось запустить камеру")
                return
            }
            session.addOutput(output)
            session.commitConfiguration()
            session.startRunning()
            onStatus("Активен · покажите руку")
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        // Process every frame the camera grants, up to 60 fps: a fast pinch tap lasts
        // ~100 ms, and sparse sampling kept dropping its confirmation frames.
        guard now - lastProcessedFrameAt >= 1.0 / 60.0 else { return }
        lastProcessedFrameAt = now
        let handler = VNImageRequestHandler(
            cmSampleBuffer: sampleBuffer,
            orientation: .upMirrored,
            options: [:]
        )
        do {
            try handler.perform([request])
            let hands = request.results ?? []
            if !hands.isEmpty {
                lastHandAt = now
                if !handWasVisible {
                    handWasVisible = true
                    onStatus("Рука найдена")
                }
                engine.process(hands, at: now)
            } else if now - lastHandAt > 0.15 {
                if handWasVisible {
                    handWasVisible = false
                    onStatus("Рука не найдена")
                }
                engine.handLost(at: now)
            }
        } catch {
            engine.handLost(at: now)
        }
    }
}

/// Soft glow along the screen edges while the swipe anchor is armed.
private final class EdgeGlowView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let band: CGFloat = 28
        let color = NSColor.controlAccentColor.withAlphaComponent(0.5)
        guard let gradient = NSGradient(starting: color, ending: color.withAlphaComponent(0)) else { return }
        gradient.draw(in: NSRect(x: 0, y: 0, width: band, height: bounds.height), angle: 0)
        gradient.draw(in: NSRect(x: bounds.width - band, y: 0, width: band, height: bounds.height), angle: 180)
        gradient.draw(in: NSRect(x: 0, y: 0, width: bounds.width, height: band), angle: 90)
        gradient.draw(in: NSRect(x: 0, y: bounds.height - band, width: bounds.width, height: band), angle: 270)
    }
}

/// A click-through window over every Space that fades the edge glow in and out.
private final class AnchorOverlay {
    private let window: NSWindow

    init() {
        let frame = (NSScreen.main ?? NSScreen.screens.first)?.frame ?? .zero
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = EdgeGlowView(frame: NSRect(origin: .zero, size: frame.size))
        window.alphaValue = 0
        window.orderFrontRegardless()
    }

    func setVisible(_ visible: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = visible ? 0.15 : 0.35
            window.animator().alphaValue = visible ? 1 : 0
        }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let events = EventController()
    private var statusItem: NSStatusItem?
    private var statusLine: NSMenuItem?
    private var camera: CameraController?
    private var overlay: AnchorOverlay?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        events.requestAccessibility()
        EventLog.shared.log("app", "started, accessibility trusted=\(events.isTrusted)")

        overlay = AnchorOverlay()
        let engine = GestureEngine(
            events: events,
            onGesture: { [weak self] gesture in
                NSLog("[AirTouch] %@", gesture)
                EventLog.shared.log("gesture", gesture)
                DispatchQueue.main.async { self?.setStatus(gesture) }
            },
            onAnchorState: { [weak self] armed in
                DispatchQueue.main.async { self?.overlay?.setVisible(armed) }
            }
        )
        camera = CameraController(engine: engine) { [weak self] status in
            NSLog("[AirTouch] %@", status)
            EventLog.shared.log("status", status)
            DispatchQueue.main.async { self?.setStatus(status) }
        }
        camera?.start()

        if !events.isTrusted {
            setStatus("Нужен Универсальный доступ")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        camera?.stop()
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "hand.raised.fill", accessibilityDescription: "AirTouch")
        item.button?.toolTip = "AirTouch — управление жестами"

        let menu = NSMenu()
        let title = NSMenuItem(title: "AirTouch", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        let status = NSMenuItem(title: "Запуск…", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Сначала ладонь — включает управление", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Кулак, большой + указательный — курсор", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Щипок — клик · держать — выделение · двойной — правая кнопка", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Ладонь влево — окно справа", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Ладонь вправо — окно слева", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Два пальца — скролл: выше/ниже нейтрали — быстрее", action: nil, keyEquivalent: ""))
        for helpItem in menu.items.suffix(6) { helpItem.isEnabled = false }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Завершить AirTouch", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
        statusLine = status
    }

    private func setStatus(_ text: String) {
        statusLine?.title = text
        statusItem?.button?.toolTip = "AirTouch — \(text)"
        try? text.write(
            to: URL(fileURLWithPath: "/tmp/airtouch-status.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

private func runSelfTest() -> Int32 {
    let frame: TimeInterval = 0.055

    /// Holds the palm at `origin` (optionally jittering, as Vision does) long enough to
    /// earn the anchor, then walks it along `step` per frame and reports what the
    /// detector decided. Frames listed in `dropFrames` advance time without an update,
    /// the way a misread frame does.
    func replay(
        settleFrames: Int,
        origin: CGPoint,
        step: CGPoint,
        moveFrames: Int,
        holdFrames: Int = 0,
        settleJitter: CGFloat = 0,
        dropFrames: Set<Int> = [],
        scale: CGFloat = 1
    ) -> SwipeDirection? {
        let detector = SwipeDetector()
        var time: TimeInterval = 0
        var result: SwipeDirection?
        for index in 0..<settleFrames {
            let jitter = index.isMultiple(of: 2) ? settleJitter : -settleJitter
            let point = CGPoint(x: origin.x + jitter, y: origin.y)
            result = detector.update(point: point, time: time, scale: scale) ?? result
            time += frame
        }
        var point = origin
        for index in 0..<moveFrames {
            point = CGPoint(x: point.x + step.x, y: point.y + step.y)
            if !dropFrames.contains(index),
               let direction = detector.update(point: point, time: time, scale: scale) {
                return direction
            }
            time += frame
        }
        for _ in 0..<holdFrames {
            if let direction = detector.update(point: point, time: time, scale: scale) { return direction }
            time += frame
        }
        return result
    }

    var failures: [String] = []
    func check(_ name: String, _ condition: Bool) {
        if !condition { failures.append(name) }
    }

    // A settled palm followed by a short flick swipes, in both directions.
    check("flick left", replay(
        settleFrames: 9, origin: CGPoint(x: 0.70, y: 0.50),
        step: CGPoint(x: -0.030, y: 0.001), moveFrames: 6
    ) == .left)
    check("flick right", replay(
        settleFrames: 9, origin: CGPoint(x: 0.30, y: 0.50),
        step: CGPoint(x: 0.030, y: 0.001), moveFrames: 6
    ) == .right)

    // An unhurried flick — two thirds of full flick speed — still swipes.
    check("unhurried flick", replay(
        settleFrames: 9, origin: CGPoint(x: 0.70, y: 0.50),
        step: CGPoint(x: -0.020, y: 0.001), moveFrames: 8
    ) == .left)

    // Vision jitter during the hold must not keep the anchor from being earned — this is
    // what made real-world swipes impossible with the raw fingertip anchor.
    check("jittery hold still flicks", replay(
        settleFrames: 10, origin: CGPoint(x: 0.70, y: 0.50),
        step: CGPoint(x: -0.030, y: 0.001), moveFrames: 6,
        settleJitter: 0.010
    ) == .left)

    // Misread frames in the middle of the flick lose nothing: displacement is absolute.
    check("dropped frames mid-flick", replay(
        settleFrames: 9, origin: CGPoint(x: 0.70, y: 0.50),
        step: CGPoint(x: -0.030, y: 0.001), moveFrames: 6,
        dropFrames: [2, 3]
    ) == .left)

    // Waving a hand past the camera never settles, so it never earns an anchor.
    check("wave ignored", replay(
        settleFrames: 0, origin: CGPoint(x: 0.80, y: 0.50),
        step: CGPoint(x: -0.035, y: 0.0), moveFrames: 14
    ) == nil)

    // Neither does a hand on its way up to the face.
    check("hand to face ignored", replay(
        settleFrames: 0, origin: CGPoint(x: 0.60, y: 0.30),
        step: CGPoint(x: -0.020, y: 0.030), moveFrames: 14
    ) == nil)

    // A settled hand creeping across the frame stays on the anchor's leash, so the
    // distance never accumulates even though the hand covers far more than a swipe.
    check("slow drift ignored", replay(
        settleFrames: 9, origin: CGPoint(x: 0.70, y: 0.50),
        step: CGPoint(x: -0.008, y: 0.0), moveFrames: 25
    ) == nil)

    // A slow deliberate slide — barely a fifth of the frame per second — still swipes.
    check("slow deliberate slide swipes", replay(
        settleFrames: 9, origin: CGPoint(x: 0.80, y: 0.50),
        step: CGPoint(x: -0.012, y: 0.0), moveFrames: 10
    ) == .left)

    // A settled hand that shifts a little and stops never reaches the swipe distance,
    // and after a moment the anchor simply moves to where the hand now is.
    check("small shift ignored", replay(
        settleFrames: 9, origin: CGPoint(x: 0.50, y: 0.50),
        step: CGPoint(x: -0.022, y: 0.0), moveFrames: 1, holdFrames: 25
    ) == nil)

    // Vertical motion of swipe size is not a horizontal swipe.
    check("vertical flick ignored", replay(
        settleFrames: 9, origin: CGPoint(x: 0.50, y: 0.30),
        step: CGPoint(x: 0.001, y: 0.030), moveFrames: 4
    ) == nil)

    // A distant hand is small in frame: with thresholds scaled down, a proportionally
    // small flick still swipes — while the same tiny motion up close stays drift.
    check("distant flick honoured", replay(
        settleFrames: 9, origin: CGPoint(x: 0.70, y: 0.50),
        step: CGPoint(x: -0.007, y: 0.0), moveFrames: 8, scale: 0.4
    ) == .left)
    check("same tiny motion ignored up close", replay(
        settleFrames: 9, origin: CGPoint(x: 0.70, y: 0.50),
        step: CGPoint(x: -0.007, y: 0.0), moveFrames: 8, scale: 1.0
    ) == nil)

    // After a swipe fires, the hand travelling back must not echo a swipe the other
    // way off a short rest — only a proper rest re-arms the anchor.
    do {
        let detector = SwipeDetector()
        var time: TimeInterval = 0
        var point = CGPoint(x: 0.70, y: 0.50)
        func rest(_ frames: Int) {
            for _ in 0..<frames { _ = detector.update(point: point, time: time); time += frame }
        }
        func stroke(_ step: CGFloat) -> SwipeDirection? {
            var fired: SwipeDirection?
            for _ in 0..<6 {
                point = CGPoint(x: point.x + step, y: point.y)
                fired = detector.update(point: point, time: time) ?? fired
                time += frame
            }
            return fired
        }
        rest(9)
        check("swipe before echo test", stroke(-0.030) == .left)
        rest(5)
        check("return stroke ignored after short rest", stroke(0.030) == nil)
        rest(10)
        check("swipe after proper rest", stroke(0.030) == .right)
    }

    if failures.isEmpty {
        print("AirTouch self-test: OK")
        return 0
    }
    print("AirTouch self-test: FAILED (\(failures.joined(separator: ", ")))")
    return 1
}

private func verifySystemEvents() -> Int32 {
    guard AXIsProcessTrusted(), let original = CGEvent(source: nil)?.location else {
        print("AirTouch event verification: Accessibility is not available")
        return 2
    }
    let bounds = CGDisplayBounds(CGMainDisplayID())
    let target = CGPoint(
        x: min(max(original.x + 12, bounds.minX), bounds.maxX - 1),
        y: original.y
    )
    let controller = EventController()
    let normalizedTarget = CGPoint(
        x: (target.x - bounds.minX) / bounds.width,
        y: (target.y - bounds.minY) / bounds.height
    )
    guard controller.moveCursor(normalized: normalizedTarget) else {
        print("AirTouch event verification: event creation failed")
        return 3
    }
    usleep(90_000)
    let delivered = CGEvent(source: nil)?.location ?? original
    let normalizedOriginal = CGPoint(
        x: (original.x - bounds.minX) / bounds.width,
        y: (original.y - bounds.minY) / bounds.height
    )
    _ = controller.moveCursor(normalized: normalizedOriginal)
    let ok = hypot(delivered.x - target.x, delivered.y - target.y) <= 3
    print(ok ? "AirTouch event verification: OK" : "AirTouch event verification: FAILED")
    return ok ? 0 : 4
}

@main
private struct AirTouchMain {
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            exit(runSelfTest())
        }
        if CommandLine.arguments.contains("--check-accessibility") {
            print(AXIsProcessTrusted() ? "true" : "false")
            exit(0)
        }
        if CommandLine.arguments.contains("--verify-events") {
            exit(verifySystemEvents())
        }
        if CommandLine.arguments.contains("--switch-next") {
            exit(EventController().switchWindow(for: .left) ? 0 : 5)
        }
        if CommandLine.arguments.contains("--switch-previous") {
            exit(EventController().switchWindow(for: .right) ? 0 : 5)
        }

        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
