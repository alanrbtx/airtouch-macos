import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Vision

private enum AirTouchConstants {
    static let bundleName = "AirTouch"
    static let swipeWindow: TimeInterval = 0.55
    static let swipeCooldown: TimeInterval = 0.95
    static let swipeDistance: CGFloat = 0.105
    static let minimumSwipeDuration: TimeInterval = 0.08
    static let pinchRatio: CGFloat = 0.34
    static let releasePinchRatio: CGFloat = 0.48
    static let pointerFrameInterval: TimeInterval = 1.0 / 30.0
}

private enum SwipeDirection: String {
    case left
    case right
}

private struct SwipeSample {
    let point: CGPoint
    let time: TimeInterval
}

private final class SwipeDetector {
    private var samples: [SwipeSample] = []
    private var lastSwipeAt: TimeInterval = -.greatestFiniteMagnitude

    func reset() {
        samples.removeAll(keepingCapacity: true)
    }

    func update(point: CGPoint, time: TimeInterval) -> SwipeDirection? {
        samples.append(SwipeSample(point: point, time: time))
        samples.removeAll { time - $0.time > AirTouchConstants.swipeWindow }

        guard time - lastSwipeAt >= AirTouchConstants.swipeCooldown,
              let first = samples.first,
              let last = samples.last
        else { return nil }

        let duration = last.time - first.time
        let dx = last.point.x - first.point.x
        let dy = last.point.y - first.point.y
        guard duration >= AirTouchConstants.minimumSwipeDuration,
              abs(dx) >= AirTouchConstants.swipeDistance,
              abs(dx) > abs(dy) * 0.85
        else { return nil }

        lastSwipeAt = time
        samples.removeAll(keepingCapacity: true)
        return dx < 0 ? .left : .right
    }
}

private final class EventController {
    var isTrusted: Bool { AXIsProcessTrusted() }

    func requestAccessibility() {
        guard !isTrusted else { return }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    @discardableResult
    func moveCursor(normalized point: CGPoint) -> Bool {
        guard isTrusted else { return false }
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let x = bounds.minX + min(max(point.x, 0), 1) * bounds.width
        let y = bounds.minY + min(max(point.y, 0), 1) * bounds.height
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: CGPoint(x: x, y: y),
            mouseButton: .left
        ) else { return false }
        event.post(tap: .cghidEventTap)
        return true
    }

    @discardableResult
    func click(count: Int = 1) -> Bool {
        guard isTrusted, let location = CGEvent(source: nil)?.location else { return false }
        guard let down = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: location,
            mouseButton: .left
        ), let up = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: location,
            mouseButton: .left
        ) else { return false }
        let clickState = Int64(min(max(count, 1), 2))
        down.setIntegerValueField(.mouseEventClickState, value: clickState)
        up.setIntegerValueField(.mouseEventClickState, value: clickState)
        down.post(tap: .cghidEventTap)
        usleep(35_000)
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
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

private final class GestureEngine {
    private let events: EventController
    private let swipeDetector = SwipeDetector()
    private let onGesture: (String) -> Void
    private var pointer = CGPoint(x: 0.5, y: 0.5)
    private var pointerInitialized = false
    private var pinchActive = false
    private var lastPinchAt: TimeInterval = -.greatestFiniteMagnitude
    private var lastPointerAt: TimeInterval = 0
    private var lastPointerStatusAt: TimeInterval = 0
    private var lastDiagnosticsAt: TimeInterval = 0
    private var lastScrollY: CGFloat?

    init(events: EventController, onGesture: @escaping (String) -> Void) {
        self.events = events
        self.onGesture = onGesture
    }

    func handLost() {
        swipeDetector.reset()
        pinchActive = false
        lastScrollY = nil
    }

    func process(_ observation: VNHumanHandPoseObservation, at time: TimeInterval) {
        guard let joints = try? observation.recognizedPoints(.all) else {
            handLost()
            return
        }

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
        }

        func point(_ joint: VNHumanHandPoseObservation.JointName) -> CGPoint? {
            guard let recognized = joints[joint], recognized.confidence >= 0.08 else { return nil }
            return recognized.location
        }

        guard let wrist = point(.wrist),
              let indexTip = point(.indexTip) ?? point(.indexDIP) ?? point(.indexPIP)
        else {
            handLost()
            return
        }
        let indexPIP = point(.indexPIP) ?? point(.indexMCP) ?? indexTip

        let middleTip = point(.middleTip)
        let middlePIP = point(.middlePIP)
        let ringTip = point(.ringTip)
        let ringPIP = point(.ringPIP)
        let littleTip = point(.littleTip)
        let littlePIP = point(.littlePIP)
        let thumbTip = point(.thumbTip)
        let indexMCP = point(.indexMCP)
        let littleMCP = point(.littleMCP)

        func extended(tip: CGPoint?, pip: CGPoint?) -> Bool {
            guard let tip, let pip else { return false }
            let tipDistance = hypot(tip.x - wrist.x, tip.y - wrist.y)
            let pipDistance = hypot(pip.x - wrist.x, pip.y - wrist.y)
            return tipDistance > pipDistance * 1.06
        }
        let indexExtended = extended(tip: indexTip, pip: indexPIP)
        let middleExtended = extended(tip: middleTip, pip: middlePIP)
        let ringExtended = extended(tip: ringTip, pip: ringPIP)
        let littleExtended = extended(tip: littleTip, pip: littlePIP)
        let extendedCount = [indexExtended, middleExtended, ringExtended, littleExtended]
            .filter { $0 }.count
        let openPalm = indexExtended && middleExtended && extendedCount >= 3

        let palmPoints = [wrist, indexMCP, littleMCP].compactMap { $0 }
        let palmCenter = CGPoint(
            x: palmPoints.map(\.x).reduce(0, +) / CGFloat(palmPoints.count),
            y: palmPoints.map(\.y).reduce(0, +) / CGFloat(palmPoints.count)
        )

        if openPalm {
            lastScrollY = nil
            pinchActive = false
            if let direction = swipeDetector.update(point: palmCenter, time: time) {
                if events.switchWindow(for: direction) {
                    onGesture(direction == .left ? "Свайп влево · окно справа" : "Свайп вправо · окно слева")
                }
            }
            return
        }

        var pinchRatio: CGFloat?
        if let thumbTip, let indexMCP, let littleMCP {
            let palmWidth = hypot(indexMCP.x - littleMCP.x, indexMCP.y - littleMCP.y)
            let pinchDistance = hypot(indexTip.x - thumbTip.x, indexTip.y - thumbTip.y)
            pinchRatio = palmWidth > 0.02 ? pinchDistance / palmWidth : nil
        }

        let twoFingerScroll = indexExtended && middleExtended && !ringExtended && !littleExtended
        if twoFingerScroll, let middleTip {
            if let previousY = lastScrollY {
                let delta = (middleTip.y - previousY) * 950
                if abs(delta) >= 1.5, events.scroll(delta: delta) {
                    onGesture("Два пальца · прокрутка")
                }
            }
            lastScrollY = middleTip.y
            return
        }
        lastScrollY = nil

        // The thumb is the stable cursor anchor. The index finger is free to close
        // the pinch without dragging the cursor away from the intended target.
        if time - lastPointerAt >= AirTouchConstants.pointerFrameInterval {
            lastPointerAt = time
            let cursorAnchor = thumbTip ?? indexTip
            let target = CGPoint(
                x: min(max((cursorAnchor.x - 0.12) / 0.76, 0), 1),
                y: min(max((0.90 - cursorAnchor.y) / 0.74, 0), 1)
            )
            if !pointerInitialized {
                pointer = target
                pointerInitialized = true
            } else {
                let smoothing: CGFloat = 0.14
                pointer.x += (target.x - pointer.x) * smoothing
                pointer.y += (target.y - pointer.y) * smoothing
            }
            if events.moveCursor(normalized: pointer), time - lastPointerStatusAt >= 0.8 {
                lastPointerStatusAt = time
                onGesture("Большой палец · курсор")
            }
        }

        // Click only after the cursor has been updated from the thumb position.
        if let pinchRatio {
            if pinchRatio <= AirTouchConstants.pinchRatio && !pinchActive {
                pinchActive = true
                let isDoublePinch = time - lastPinchAt <= 0.55
                lastPinchAt = isDoublePinch ? -.greatestFiniteMagnitude : time
                if events.click(count: isDoublePinch ? 2 : 1) {
                    onGesture(isDoublePinch ? "Двойной щипок · открыть" : "Щипок · клик")
                }
            } else if pinchRatio >= AirTouchConstants.releasePinchRatio {
                pinchActive = false
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
        request.maximumHandCount = 1
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
        guard now - lastProcessedFrameAt >= 1.0 / 18.0 else { return }
        lastProcessedFrameAt = now
        let handler = VNImageRequestHandler(
            cmSampleBuffer: sampleBuffer,
            orientation: .upMirrored,
            options: [:]
        )
        do {
            try handler.perform([request])
            if let hand = request.results?.first {
                lastHandAt = now
                if !handWasVisible {
                    handWasVisible = true
                    onStatus("Рука найдена")
                }
                engine.process(hand, at: now)
            } else if now - lastHandAt > 0.15 {
                if handWasVisible {
                    handWasVisible = false
                    onStatus("Рука не найдена")
                }
                engine.handLost()
            }
        } catch {
            engine.handLost()
        }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let events = EventController()
    private var statusItem: NSStatusItem?
    private var statusLine: NSMenuItem?
    private var camera: CameraController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        events.requestAccessibility()

        let engine = GestureEngine(events: events) { [weak self] gesture in
            NSLog("[AirTouch] %@", gesture)
            DispatchQueue.main.async { self?.setStatus(gesture) }
        }
        camera = CameraController(engine: engine) { [weak self] status in
            NSLog("[AirTouch] %@", status)
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
        menu.addItem(NSMenuItem(title: "Большой палец — курсор", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Щипок — клик · двойной — открыть", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Ладонь влево — окно справа", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Ладонь вправо — окно слева", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Два пальца — прокрутка", action: nil, keyEquivalent: ""))
        for helpItem in menu.items.suffix(5) { helpItem.isEnabled = false }
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
    let detector = SwipeDetector()
    let left = detector.update(point: CGPoint(x: 0.70, y: 0.5), time: 0)
    let leftResult = detector.update(point: CGPoint(x: 0.42, y: 0.51), time: 0.24)
    let detector2 = SwipeDetector()
    let right = detector2.update(point: CGPoint(x: 0.25, y: 0.5), time: 0)
    let rightResult = detector2.update(point: CGPoint(x: 0.50, y: 0.49), time: 0.22)
    let ok = left == nil && leftResult == .left && right == nil && rightResult == .right
    print(ok ? "AirTouch self-test: OK" : "AirTouch self-test: FAILED")
    return ok ? 0 : 1
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
