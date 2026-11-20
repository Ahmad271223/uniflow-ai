import PencilKit
import QuartzCore
import UIKit
import XCTest

/// Echte Beruehrung im Test (16.11.2026, Meldung "wenn man was schreibt geht es kurz weg"): Die bisherigen Editor-Tests
/// setzten die Zeichnung selbst und riefen die Meldungen von PencilKit von Hand auf. Damit lief nie ein Strich durch
/// PencilKit, wie ihn Finger oder Stift ziehen. Hier entsteht eine Beruehrung wie vom Bildschirm (ein Finger: aufsetzen,
/// ziehen, absetzen) und geht ueber `UIApplication.sendEvent` an die App - PencilKit zeichnet den Strich selbst, meldet
/// ihn selbst und in seiner eigenen Reihenfolge.
///
/// Nur fuer Tests und nur im Simulator: nutzt nicht dokumentierte Aufrufe von UIKit (wie die verbreiteten
/// Test-Werkzeuge fuer iOS). Fehlt einer davon in einer neuen iOS-Version, meldet `TestFinger.verfuegbar` false und
/// der Test wird uebersprungen statt zu scheitern.
@MainActor
final class TestFinger {
    private let touch: UITouch
    private let window: UIWindow
    private var point: CGPoint

    private typealias SetObject = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
    private typealias SetInt = @convention(c) (AnyObject, Selector, Int) -> Void
    private typealias SetBool = @convention(c) (AnyObject, Selector, Bool) -> Void
    private typealias SetDouble = @convention(c) (AnyObject, Selector, Double) -> Void
    private typealias SetPoint = @convention(c) (AnyObject, Selector, CGPoint, Bool) -> Void
    private typealias SetPointer = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer?) -> Void
    private typealias AddTouch = @convention(c) (AnyObject, Selector, AnyObject, Bool) -> Void
    private typealias Plain = @convention(c) (AnyObject, Selector) -> Void
    private typealias GetObject = @convention(c) (AnyObject, Selector) -> AnyObject?

    private typealias CreateHand = @convention(c) (CFAllocator?, UInt64, UInt32, UInt32, UInt32, UInt32, UInt32, Double, Double, Double,
                                                    Double, Double, Bool, Bool, UInt32) -> UnsafeMutableRawPointer?
    private typealias CreateFinger = @convention(c) (CFAllocator?, UInt64, UInt32, UInt32, UInt32, Double, Double, Double, Double, Double,
                                                      Bool, Bool, UInt32) -> UnsafeMutableRawPointer?
    private typealias Append = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UInt32) -> Void
    private typealias SetField = @convention(c) (UnsafeMutableRawPointer?, UInt32, Int) -> Void

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(p, to: type)
    }

    private static func method<T>(_ object: AnyObject, _ name: String, as type: T.Type) -> T? {
        let sel = NSSelectorFromString(name)
        guard object.responds(to: sel), let cls = object_getClass(object), let m = class_getInstanceMethod(cls, sel) else { return nil }
        return unsafeBitCast(method_getImplementation(m), to: type)
    }

    private static let touchSelectors = ["setWindow:", "setView:", "setTapCount:", "_setLocationInWindow:resetPrevious:", "setPhase:",
                                         "setTimestamp:", "_setHidEvent:"]

    /// Gibt es alle noetigen Aufrufe in dieser iOS-Version?
    static var verfuegbar: Bool {
        let t = UITouch()
        guard touchSelectors.allSatisfy({ t.responds(to: NSSelectorFromString($0)) }) else { return false }
        guard UIApplication.shared.responds(to: NSSelectorFromString("_touchesEvent")) else { return false }
        return symbol("IOHIDEventCreateDigitizerEvent", as: CreateHand.self) != nil
            && symbol("IOHIDEventCreateDigitizerFingerEvent", as: CreateFinger.self) != nil
            && symbol("IOHIDEventAppendEvent", as: Append.self) != nil
            && symbol("IOHIDEventSetIntegerValue", as: SetField.self) != nil
    }

    /// Finger setzt bei `point` (Punkte des Fensters) auf. `ziel`: diese Ansicht bekommt die Beruehrung (z. B. die Flaeche
    /// des Lassos von PencilKit, `PKSelectionGestureView`); sonst wie vom Bildschirm getroffen.
    init(at point: CGPoint, in window: UIWindow, ziel: UIView? = nil) {
        self.window = window
        self.point = point
        touch = UITouch()
        // Treffer mit dem Beruehrungs-Ereignis der App suchen: PencilKit gibt seine Flaeche fuer den Strich nur dann zurueck
        let app = UIApplication.shared
        let event = Self.method(app, "_touchesEvent", as: GetObject.self)?(app, NSSelectorFromString("_touchesEvent")) as? UIEvent
        var view = window.hitTest(point, with: event)
        // faellt der Treffer in eine Zeichenflaeche von PencilKit, aber nicht auf ihre Flaeche fuer den Strich: diese nehmen
        if let canvas = Self.canvas(above: view), let drawing = Self.drawingView(in: canvas), view !== drawing,
           !(view?.isDescendant(of: drawing) ?? false) {
            view = drawing
        }
        if let ziel { view = ziel }
        Self.method(touch, "setWindow:", as: SetObject.self)?(touch, NSSelectorFromString("setWindow:"), window)
        Self.method(touch, "setTapCount:", as: SetInt.self)?(touch, NSSelectorFromString("setTapCount:"), 1)
        Self.method(touch, "_setLocationInWindow:resetPrevious:", as: SetPoint.self)?(touch, NSSelectorFromString("_setLocationInWindow:resetPrevious:"), point, true)
        Self.method(touch, "setView:", as: SetObject.self)?(touch, NSSelectorFromString("setView:"), view)
        Self.method(touch, "setPhase:", as: SetInt.self)?(touch, NSSelectorFromString("setPhase:"), UITouch.Phase.began.rawValue)
        Self.method(touch, "_setIsFirstTouchForView:", as: SetBool.self)?(touch, NSSelectorFromString("_setIsFirstTouchForView:"), true)
        Self.method(touch, "setGestureView:", as: SetObject.self)?(touch, NSSelectorFromString("setGestureView:"), view)
        send()
    }

    private static func canvas(above view: UIView?) -> PKCanvasView? {
        var v = view
        while let x = v { if let c = x as? PKCanvasView { return c }; v = x.superview }
        return nil
    }

    /// Flaeche von PencilKit, an der das Lasso haengt (Auswaehlen, Verschieben der Auswahl)
    static func selectionView(in view: UIView) -> UIView? {
        if String(describing: type(of: view)).contains("SelectionGestureView") { return view }
        for s in view.subviews { if let found = selectionView(in: s) { return found } }
        return nil
    }

    /// Flaeche von PencilKit, an der der Erkenner fuer den Strich haengt
    static func drawingView(in view: UIView) -> UIView? {
        if (view.gestureRecognizers ?? []).contains(where: { String(describing: type(of: $0)).contains("DrawingGestureRecognizer") }) { return view }
        for s in view.subviews { if let found = drawingView(in: s) { return found } }
        return nil
    }

    /// Ansicht, die die Beruehrung beim Aufsetzen getroffen hat
    var view: UIView? { touch.view }

    func move(to p: CGPoint) {
        point = p
        Self.method(touch, "_setLocationInWindow:resetPrevious:", as: SetPoint.self)?(touch, NSSelectorFromString("_setLocationInWindow:resetPrevious:"), p, false)
        Self.method(touch, "setPhase:", as: SetInt.self)?(touch, NSSelectorFromString("setPhase:"), UITouch.Phase.moved.rawValue)
        send()
    }

    /// Finger bleibt liegen, ohne sich zu bewegen
    func hold() {
        Self.method(touch, "setPhase:", as: SetInt.self)?(touch, NSSelectorFromString("setPhase:"), UITouch.Phase.stationary.rawValue)
        send()
    }

    func lift() {
        Self.method(touch, "setPhase:", as: SetInt.self)?(touch, NSSelectorFromString("setPhase:"), UITouch.Phase.ended.rawValue)
        send()
    }

    private func send() {
        Self.method(touch, "setTimestamp:", as: SetDouble.self)?(touch, NSSelectorFromString("setTimestamp:"), CACurrentMediaTime())
        let hid = hidEvent()
        Self.method(touch, "_setHidEvent:", as: SetPointer.self)?(touch, NSSelectorFromString("_setHidEvent:"), hid)
        let app = UIApplication.shared
        guard let event = Self.method(app, "_touchesEvent", as: GetObject.self)?(app, NSSelectorFromString("_touchesEvent")) as? UIEvent else { return }
        Self.method(event, "_clearTouches", as: Plain.self)?(event, NSSelectorFromString("_clearTouches"))
        Self.method(event, "_setHIDEvent:", as: SetPointer.self)?(event, NSSelectorFromString("_setHIDEvent:"), hid)
        Self.method(event, "_addTouch:forDelayedDelivery:", as: AddTouch.self)?(event, NSSelectorFromString("_addTouch:forDelayedDelivery:"), touch, false)
        app.sendEvent(event)
        if let hid { Unmanaged<AnyObject>.fromOpaque(hid).release() }
    }

    /// Ereignis des Bildschirms zu dieser Beruehrung (eine Hand mit einem Finger)
    private func hidEvent() -> UnsafeMutableRawPointer? {
        guard let hand = Self.symbol("IOHIDEventCreateDigitizerEvent", as: CreateHand.self),
              let finger = Self.symbol("IOHIDEventCreateDigitizerFingerEvent", as: CreateFinger.self),
              let append = Self.symbol("IOHIDEventAppendEvent", as: Append.self),
              let setField = Self.symbol("IOHIDEventSetIntegerValue", as: SetField.self) else { return nil }
        let time = mach_absolute_time()
        let displayIntegrated: UInt32 = 0xB0019
        let rangeBit: UInt32 = 1, touchBit: UInt32 = 2, positionBit: UInt32 = 4
        guard let event = hand(kCFAllocatorDefault, time, 3, 0, 0, touchBit, 0, 0, 0, 0, 0, 0, false, false, 0) else { return nil }
        setField(event, displayIntegrated, 1)
        let moved = touch.phase == .moved
        let down = touch.phase != .ended && touch.phase != .cancelled
        if let f = finger(kCFAllocatorDefault, time, 1, 2, moved ? positionBit : (rangeBit | touchBit), Double(point.x), Double(point.y), 0,
                          0, 0, down, down, 0) {
            setField(f, displayIntegrated, 1)
            append(event, f, 0)
            Unmanaged<AnyObject>.fromOpaque(f).release()
        }
        return event
    }

    /// Ein Strich mit dem Finger ueber `points` (Punkte des Fensters), je Punkt eine Pause von `step` Sekunden
    /// - Returns: Art der Ansicht, die die Beruehrung beim Aufsetzen getroffen hat (fuer die Fehlersuche)
    @discardableResult
    static func strich(_ points: [CGPoint], in window: UIWindow, step: Double = 0.012, haltenAmEnde: Double = 0,
                       ziel: UIView? = nil) async throws -> String {
        guard let first = points.first else { return "-" }
        let finger = TestFinger(at: first, in: window, ziel: ziel)
        let hit = finger.view.map { String(describing: type(of: $0)) } ?? "nichts"
        for p in points.dropFirst() {
            try await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
            finger.move(to: p)
        }
        if haltenAmEnde > 0 {
            let end = CACurrentMediaTime() + haltenAmEnde
            while CACurrentMediaTime() < end {
                try await Task.sleep(nanoseconds: 30_000_000)
                finger.hold()
            }
        }
        try await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
        finger.lift()
        return hit
    }
}

// MARK: - Zwei Finger (Pinchen)

extension TestFinger {
    /// Zwei Finger gleichzeitig wie vom Bildschirm (Rueckmeldung des Inhabers 21.11.2026: "beim Ranzoomen darf die Schrift
    /// nicht verrutschen"). Beide Beruehrungen gehen in EINEM Ereignis an die App, mit einem Ereignis des Bildschirms
    /// (eine Hand, zwei Finger): So erkennt die Pinch-Geste der Scroll-Ansicht von PDFKit ein echtes Zoomen, nicht
    /// `scaleFactor` von aussen gesetzt.
    @MainActor
    final class Zwei {
        private let touches: [UITouch]
        private var points: [CGPoint]
        private let window: UIWindow

        init(_ a: CGPoint, _ b: CGPoint, in window: UIWindow) {
            self.window = window
            points = [a, b]
            touches = [UITouch(), UITouch()]
            let app = UIApplication.shared
            let event = TestFinger.method(app, "_touchesEvent", as: GetObject.self)?(app, NSSelectorFromString("_touchesEvent")) as? UIEvent
            for (touch, p) in zip(touches, points) {
                let view = window.hitTest(p, with: event)
                TestFinger.method(touch, "setWindow:", as: SetObject.self)?(touch, NSSelectorFromString("setWindow:"), window)
                TestFinger.method(touch, "setTapCount:", as: SetInt.self)?(touch, NSSelectorFromString("setTapCount:"), 1)
                TestFinger.method(touch, "_setLocationInWindow:resetPrevious:", as: SetPoint.self)?(touch, NSSelectorFromString("_setLocationInWindow:resetPrevious:"), p, true)
                TestFinger.method(touch, "setView:", as: SetObject.self)?(touch, NSSelectorFromString("setView:"), view)
                TestFinger.method(touch, "setPhase:", as: SetInt.self)?(touch, NSSelectorFromString("setPhase:"), UITouch.Phase.began.rawValue)
                TestFinger.method(touch, "_setIsFirstTouchForView:", as: SetBool.self)?(touch, NSSelectorFromString("_setIsFirstTouchForView:"), true)
                TestFinger.method(touch, "setGestureView:", as: SetObject.self)?(touch, NSSelectorFromString("setGestureView:"), view)
            }
            send()
        }

        func move(_ a: CGPoint, _ b: CGPoint) {
            points = [a, b]
            for (touch, p) in zip(touches, points) {
                TestFinger.method(touch, "_setLocationInWindow:resetPrevious:", as: SetPoint.self)?(touch, NSSelectorFromString("_setLocationInWindow:resetPrevious:"), p, false)
                TestFinger.method(touch, "setPhase:", as: SetInt.self)?(touch, NSSelectorFromString("setPhase:"), UITouch.Phase.moved.rawValue)
            }
            send()
        }

        /// Beide Finger bleiben liegen
        func hold() {
            for touch in touches {
                TestFinger.method(touch, "setPhase:", as: SetInt.self)?(touch, NSSelectorFromString("setPhase:"), UITouch.Phase.stationary.rawValue)
            }
            send()
        }

        func lift() {
            for touch in touches {
                TestFinger.method(touch, "setPhase:", as: SetInt.self)?(touch, NSSelectorFromString("setPhase:"), UITouch.Phase.ended.rawValue)
            }
            send()
        }

        private func send() {
            let hid = hidEvent()
            for touch in touches {
                TestFinger.method(touch, "setTimestamp:", as: SetDouble.self)?(touch, NSSelectorFromString("setTimestamp:"), CACurrentMediaTime())
                TestFinger.method(touch, "_setHidEvent:", as: SetPointer.self)?(touch, NSSelectorFromString("_setHidEvent:"), hid)
            }
            let app = UIApplication.shared
            guard let event = TestFinger.method(app, "_touchesEvent", as: GetObject.self)?(app, NSSelectorFromString("_touchesEvent")) as? UIEvent else { return }
            TestFinger.method(event, "_clearTouches", as: Plain.self)?(event, NSSelectorFromString("_clearTouches"))
            TestFinger.method(event, "_setHIDEvent:", as: SetPointer.self)?(event, NSSelectorFromString("_setHIDEvent:"), hid)
            for touch in touches {
                TestFinger.method(event, "_addTouch:forDelayedDelivery:", as: AddTouch.self)?(event, NSSelectorFromString("_addTouch:forDelayedDelivery:"), touch, false)
            }
            app.sendEvent(event)
            if let hid { Unmanaged<AnyObject>.fromOpaque(hid).release() }
        }

        /// Eine Hand mit zwei Fingern
        private func hidEvent() -> UnsafeMutableRawPointer? {
            guard let hand = TestFinger.symbol("IOHIDEventCreateDigitizerEvent", as: CreateHand.self),
                  let finger = TestFinger.symbol("IOHIDEventCreateDigitizerFingerEvent", as: CreateFinger.self),
                  let append = TestFinger.symbol("IOHIDEventAppendEvent", as: Append.self),
                  let setField = TestFinger.symbol("IOHIDEventSetIntegerValue", as: SetField.self) else { return nil }
            let time = mach_absolute_time()
            let displayIntegrated: UInt32 = 0xB0019
            let rangeBit: UInt32 = 1, touchBit: UInt32 = 2, positionBit: UInt32 = 4
            guard let event = hand(kCFAllocatorDefault, time, 3, 0, 0, touchBit, 0, 0, 0, 0, 0, 0, false, false, 0) else { return nil }
            setField(event, displayIntegrated, 1)
            for (i, (touch, p)) in zip(touches, points).enumerated() {
                let moved = touch.phase == .moved
                let down = touch.phase != .ended && touch.phase != .cancelled
                if let f = finger(kCFAllocatorDefault, time, UInt32(i + 1), UInt32(i + 2), moved ? positionBit : (rangeBit | touchBit),
                                  Double(p.x), Double(p.y), 0, 0, 0, down, down, 0) {
                    setField(f, displayIntegrated, 1)
                    append(event, f, 0)
                    Unmanaged<AnyObject>.fromOpaque(f).release()
                }
            }
            return event
        }

        /// Pinchen um `center` (Fensterpunkte): Abstand der Finger von `from` auf `to` in `steps` Schritten je `step`
        /// Sekunden (ein Bild = 1/60 s); bei `holdAt` (Anteil 0...1) `holdSeconds` lang ruhig liegen lassen; am Ende loslassen
        static func pinch(center c: CGPoint, from: CGFloat, to: CGFloat, steps: Int, step: Double = 1.0 / 60, in window: UIWindow,
                          holdAt: Double? = nil, holdSeconds: Double = 0, eachFrame: (() -> Void)? = nil) async throws {
            func pts(_ d: CGFloat) -> (CGPoint, CGPoint) { (CGPoint(x: c.x - d / 2, y: c.y - d * 0.15), CGPoint(x: c.x + d / 2, y: c.y + d * 0.15)) }
            let (a0, b0) = pts(from)
            let fingers = Zwei(a0, b0, in: window)
            var held = false
            for i in 1...steps {
                try await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
                let t = CGFloat(i) / CGFloat(steps)
                let (a, b) = pts(from * pow(to / from, t))
                fingers.move(a, b)
                eachFrame?()
                if let h = holdAt, !held, Double(t) >= h {
                    held = true
                    let end = CACurrentMediaTime() + holdSeconds
                    while CACurrentMediaTime() < end {
                        try await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
                        fingers.hold()
                        eachFrame?()
                    }
                }
            }
            try await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
            fingers.lift()
        }
    }
}
