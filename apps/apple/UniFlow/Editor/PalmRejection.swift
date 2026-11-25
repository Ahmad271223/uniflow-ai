import PDFKit
import UIKit

/// Handballen-Abwehr beim Scrollen und Zoomen (Meldung des Inhabers 25.11.2026: "Zoomen, Handballenerkennung nicht
/// ganz gut"; sein Okay "Ja, bauen").
///
/// Bis dahin: Mit "Nur Stift" scrollt EIN Finger und zoomen zwei Beruehrungen - der aufgelegte Handballen ist fuer die
/// Rollflaeche der PDF-Ansicht ein Finger wie jeder andere. Beim Schreiben konnte die Seite wegrutschen oder zoomen;
/// die App verliess sich allein auf iOS. Jetzt drei Regeln (nur iPad, am Mac gibt es keinen Stift):
///
/// 1. Solange der Stift aufliegt und `quietAfterPencil` danach, scrollt und zoomt keine Beruehrung der Hand.
/// 2. Eine Beruehrung mit sehr grosser Auflageflaeche (`palmRadius`) ist nie ein Finger: solange sie aufliegt, ebenso.
///    ABGESCHALTET seit dem ersten Test am Geraet (`PencilTuning.palmByRadius`): Die Auflage trennt Finger und
///    Handballen auf dem iPad A16 nicht, Zoomen mit zwei Fingern wurde gesperrt.
/// 3. Hat die Hand die Seite kurz vorher (`slipWindow`) schon bewegt - die Hand liegt meist einen Moment vor dem Stift
///    auf -, geht die Seite an die Stelle und in den Zoom zurueck, die sie beim Auflegen der Hand hatte.
///
/// Gesperrt werden die Scroll- und Zoom-Geste der Rollflaeche (`isEnabled`); eine laufende Geste bricht dabei ab. Eine
/// Hand, die beim Aufheben der Sperre noch aufliegt, scrollt danach nicht: UIKit gibt einer Geste nur Beruehrungen,
/// die aufsetzen, waehrend sie an ist. Die Logik steht hier ohne UIKit-Zustand (`State`), damit sie ohne Stift
/// getestet wird (im Simulator gibt es keinen).
enum PalmRejection {
    /// So lange nach dem Absetzen des Stifts bleiben Scrollen und Zoomen mit der Hand gesperrt (zwischen zwei
    /// Strichen liegt der Stift oft nur 0,1-0,3 s nicht auf, die Hand bleibt liegen)
    static let quietAfterPencil: CFTimeInterval = 0.5
    /// Ab diesem Radius der Auflageflaeche (pt, `UITouch.majorRadius`) waere eine Beruehrung kein Finger (Regel 2, aus:
    /// `PencilTuning.palmByRadius`). Die Schaetzung 45 pt war am Geraet falsch (Finger bis 63 pt gemessen). Auflagen ab
    /// `radiusWorthLogging` stehen im Ablauf-Protokoll (`StiftSpur`).
    static let palmRadius: CGFloat = 45
    static let radiusWorthLogging: CGFloat = 30
    /// Hat die Hand hoechstens so lange vor der Sperre aufgesetzt, geht die Seite zurueck (Regel 3). Laenger: Die Geste
    /// bricht nur ab - wer mit einem Finger der anderen Hand blaettert und dabei den Stift aufsetzt, verliert nichts.
    static let slipWindow: CFTimeInterval = 0.8
    /// Nachpruefung, solange eine Beruehrung die Sperre haelt (falls ein Ende nie gemeldet wird)
    static let recheck: CFTimeInterval = 2

    /// Was gerade aufliegt
    struct State: Equatable {
        private(set) var pencilsDown = 0
        private(set) var palmsDown = 0
        /// Zeitpunkt, zu dem der letzte Stift abgesetzt hat (nil: seit dem Start lag keiner auf)
        private(set) var lastPencilUp: CFTimeInterval?

        mutating func update(pencils: Int, palms: Int, at now: CFTimeInterval) {
            if pencils == 0, pencilsDown > 0 { lastPencilUp = now }
            pencilsDown = max(0, pencils)
            palmsDown = max(0, palms)
        }

        /// Scrollen und Zoomen mit der Hand gesperrt?
        func locked(at now: CFTimeInterval) -> Bool {
            if pencilsDown > 0 || palmsDown > 0 { return true }
            guard let up = lastPencilUp else { return false }
            return now - up < PalmRejection.quietAfterPencil
        }

        /// Gesperrt: in so vielen Sekunden neu pruefen (Ende der Ruhezeit bzw. Nachpruefung). nil: offen.
        func nextCheck(at now: CFTimeInterval) -> CFTimeInterval? {
            guard locked(at: now) else { return nil }
            if pencilsDown > 0 || palmsDown > 0 { return PalmRejection.recheck }
            guard let up = lastPencilUp else { return nil }
            return max(0, PalmRejection.quietAfterPencil - (now - up))
        }
    }

    static func isPalm(radius: CGFloat) -> Bool { radius >= palmRadius }
    /// Regel 2 nur, wenn sie eingeschaltet ist (`PencilTuning.palmByRadius`)
    static func countsAsPalm(radius: CGFloat) -> Bool { PencilTuning.palmByRadius && isPalm(radius: radius) }

    /// Regel 3: Seite zurueck an die Stelle beim Auflegen der Hand?
    static func restoresSlip(handDownAt: CFTimeInterval?, lockedAt now: CFTimeInterval) -> Bool {
        guard let t = handDownAt else { return false }
        return now >= t && now - t <= slipWindow
    }

    /// Alle offenen Editoren (geteilte Ansicht: Uebung und Skript nebeneinander). Der Stift in EINEM Dokument sperrt
    /// die Hand in allen: Wer links am rechten Rand schreibt, liegt mit dem Handballen auf dem Dokument daneben.
    @MainActor static let editors = NSHashTable<PDFEditorController>.weakObjects()

    /// Messung (Tests): so oft gesperrt bzw. die Seite zurueckgesetzt
    private(set) static var locksMade = 0
    private(set) static var slipsRestored = 0
    fileprivate static func countLock() { locksMade += 1 }
    fileprivate static func countRestore() { slipsRestored += 1 }
}

/// Sieht jede Beruehrung der PDF-Ansicht (Stift und Hand) in dem Moment, in dem sie aufsetzt. Erkennt nie etwas, haelt
/// keine Beruehrung zurueck und laesst sich nicht verdraengen (wie `InkTouchTracker`).
final class HandWatcher: UIGestureRecognizer {
    private var touches: Set<UITouch> = []
    /// Beruehrungen der Hand, deren Auflageflaeche einmal zu gross war (bleiben es, bis sie enden)
    private var palms: Set<UITouch> = []
    /// Stift oder Handballen aufgesetzt bzw. weg
    var onChange: (() -> Void)?
    /// Die erste Beruehrung der Hand setzt auf (vorher lag keine auf)
    var onFirstHandDown: (() -> Void)?
    /// Groesste Auflageflaeche der Hand in dieser Folge von Beruehrungen (Ablauf-Protokoll)
    private var largestRadius: CGFloat = 0

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        allowedTouchTypes = [UITouch.TouchType.direct, .pencil].map { NSNumber(value: $0.rawValue) }
    }

    convenience init() { self.init(target: nil, action: nil) }

    private func isDown(_ t: UITouch) -> Bool { t.phase != .ended && t.phase != .cancelled }
    var pencilsDown: Int { touches.filter { $0.type == .pencil && isDown($0) }.count + pencilsForTesting }
    /// Nur Tests: so viele Stifte gelten zusaetzlich als aufliegend (im Simulator gibt es keinen Pencil)
    var pencilsForTesting = 0
    var palmsDown: Int { palms.filter(isDown).count }
    private var handsDown: Int { touches.filter { $0.type != .pencil && isDown($0) }.count }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        let handsBefore = handsDown
        self.touches.formUnion(touches)
        var changed = false
        for t in touches {
            if t.type == .pencil { changed = true } else if note(t) { changed = true }
        }
        if handsBefore == 0, handsDown > 0 { onFirstHandDown?() }
        if changed { onChange?() }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        // der Stift meldet sich bis zu 240-mal je Sekunde: nur die Hand ansehen, und nur, was noch kein Handballen ist
        var changed = false
        for t in touches where t.type != .pencil && !palms.contains(t) {
            if note(t) { changed = true }
        }
        if changed { onChange?() }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches) }

    /// Auflageflaeche merken; true, wenn die Beruehrung damit zum Handballen wird
    private func note(_ t: UITouch) -> Bool {
        let r = t.majorRadius
        if r > largestRadius { largestRadius = r }
        guard PalmRejection.countsAsPalm(radius: r), !palms.contains(t) else { return false }
        palms.insert(t)
        return true
    }

    private func finish(_ ended: Set<UITouch>) {
        let relevant = ended.contains { $0.type == .pencil || palms.contains($0) }
        touches.subtract(ended)
        palms.subtract(ended)
        if relevant { onChange?() }
        guard touches.isEmpty else { return }
        if largestRadius >= PalmRejection.radiusWorthLogging {
            StiftSpur.log(String(format: "Hand: groesste Auflage %.0f pt, gesperrt %@", largestRadius,
                                 PalmRejection.countsAsPalm(radius: largestRadius) ? "ja" : "nein"))
        }
        largestRadius = 0
        state = .failed
    }

    override func reset() {
        super.reset()
        let had = !touches.isEmpty
        touches = []
        palms = []
        largestRadius = 0
        if had { onChange?() }
    }
}

// MARK: - Editor

extension PDFEditorController {
    /// Beobachter einsetzen (einmal; am Mac nicht: dort gibt es keinen Stift, und die Maus ist kein Handballen)
    func installPalmRejection() {
        guard !Self.isMac, handWatcher.view == nil else { return }
        handWatcher.onChange = { [weak self] in self?.handTouchesChanged() }
        handWatcher.onFirstHandDown = { [weak self] in self?.rememberHandStart() }
        pdfView.addGestureRecognizer(handWatcher)
        PalmRejection.editors.add(self)
    }

    /// Stelle und Zoom in dem Moment, in dem die Hand aufsetzt (Regel 3)
    func rememberHandStart(at now: CFTimeInterval = CACurrentMediaTime()) {
        guard let scroll = firstScrollView(in: pdfView) else { return }
        handStart = HandStart(time: now, offset: scroll.contentOffset, scale: pdfView.scaleFactor)
    }

    /// Der Beobachter meldet: Stift oder Handballen aufgesetzt bzw. weg. Der Stift zaehlt fuer alle offenen Editoren
    /// (`PalmRejection.editors`), der Handballen nur fuer das Dokument, auf dem er liegt.
    func handTouchesChanged(at now: CFTimeInterval = CACurrentMediaTime()) {
        var all = PalmRejection.editors.allObjects
        if !all.contains(where: { $0 === self }) { all.append(self) }
        let pencils = all.reduce(0) { $0 + $1.handWatcher.pencilsDown }
        for e in all { e.setHandTouches(pencils: pencils, palms: e.handWatcher.palmsDown, at: now) }
    }

    /// Was aufliegt (vom Beobachter; Tests setzen es direkt, im Simulator gibt es weder Stift noch Handballen)
    func setHandTouches(pencils: Int, palms: Int, at now: CFTimeInterval = CACurrentMediaTime(), gestureRunning: Bool? = nil) {
        palmState.update(pencils: pencils, palms: palms, at: now)
        applyHandLock(at: now, gestureRunning: gestureRunning)
    }

    /// Sperre nach dem Stand von `palmState` setzen oder loesen. `gestureRunning` nur Tests (sonst aus den Gesten gelesen).
    func applyHandLock(at now: CFTimeInterval = CACurrentMediaTime(), gestureRunning: Bool? = nil) {
        let lock = PencilTuning.palmRejection && !Self.isMac && palmState.locked(at: now)
        handUnlockCheck?.cancel()
        handUnlockCheck = nil
        if lock, let delay = palmState.nextCheck(at: now) {
            // haelt eine Beruehrung die Sperre, liest die Nachpruefung neu, was noch aufliegt
            let held = palmState.pencilsDown > 0 || palmState.palmsDown > 0
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if held, self.handWatcher.view != nil { self.handTouchesChanged() } else { self.applyHandLock() }
            }
            handUnlockCheck = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.01, execute: work)
        }
        guard lock != handGesturesLocked else { return }
        handGesturesLocked = lock
        guard let scroll = firstScrollView(in: pdfView) else { return }
        guard lock else { return applyHandGestureLock(to: scroll) }
        PalmRejection.countLock()
        StiftZaehler.bump(.handGesperrt)
        let pan = scroll.panGestureRecognizer.state, pinch = scroll.pinchGestureRecognizer?.state
        let running = gestureRunning ?? (pan == .began || pan == .changed || pinch == .began || pinch == .changed)
        applyHandGestureLock(to: scroll)                 // eine laufende Geste bricht hier ab
        if running {
            if PalmRejection.restoresSlip(handDownAt: handStart?.time, lockedAt: now), let start = handStart {
                if abs(pdfView.scaleFactor - start.scale) > 0.0005 { pdfView.scaleFactor = start.scale }
                scroll.setContentOffset(start.offset, animated: false)
                PalmRejection.countRestore()
                StiftZaehler.bump(.handRutscherZurueck)
                StiftSpur.log(String(format: "Hand: Seite zurueckgesetzt (Hand lag %.2f s vor der Sperre auf)", now - start.time))
            }
        } else if scroll.isDecelerating {
            // die Seite rollt noch von einem Wischen: unter dem Stift bleibt sie stehen
            scroll.setContentOffset(scroll.contentOffset, animated: false)
        }
    }

    /// Scroll- und Zoom-Geste der Rollflaeche: aus, solange die Ansicht fixiert ist (`applyFreezeGestures`) oder die
    /// Handballen-Abwehr sperrt. Rollen mit Trackpad und Mausrad geht ueber dieselbe Geste und ruht solange mit.
    func applyHandGestureLock(to scroll: UIScrollView) {
        let on = freezeMode == .off && !handGesturesLocked
        scroll.panGestureRecognizer.isEnabled = on
        scroll.pinchGestureRecognizer?.isEnabled = on
    }
}

/// Stelle und Zoom beim Auflegen der Hand
struct HandStart: Equatable {
    let time: CFTimeInterval
    let offset: CGPoint
    let scale: CGFloat
}
