import PDFKit
import PencilKit
import SwiftUI
import UIKit
import UniFlowCore

// Bildschirm fixieren im Editor (Wunsch des Inhabers 05.11.2026, docs/FIXIEREN-ABPAUSEN-2026-11-05.md):
// "Ansicht fixieren" sperrt Zoom, Scrollen und Seitenwechsel (Stift schreibt weiter), "Zum Abpausen einfrieren" sperrt
// zusaetzlich jede Eingabe, damit Papier auf dem iPad nichts ausloest. Die Logik der Stufen liegt in
// `EditorFreeze` (UniFlowCore, auch fuer die spaetere iPhone-Fassung); hier nur iPad-Bildschirm, Editor und Sitzung.

/// Stelle der Ansicht beim Fixieren: Punkt der Seite an der linken oberen Ecke der PDF-Ansicht und Zoom
struct FreezeAnchor: Equatable {
    /// Seitenschluessel (bleibt bei einem Neuaufbau der Seiten gleich), sonst der Index
    let key: String?
    let index: Int
    let point: CGPoint
    let scale: CGFloat
}

/// Schwacher Verweis auf eine vom Fixieren abgeschaltete Geste
final class WeakGesture {
    weak var gesture: UIGestureRecognizer?
    init(_ g: UIGestureRecognizer) { gesture = g }
}

/// Stand vor dem Fixieren: Gesten des Systems und der Scroll-Ansicht von PDFKit
struct FreezeSystemGestures {
    /// Zurueck-Wischen vom linken Rand (Navigation)
    weak var pop: UIGestureRecognizer?
    /// Seitenleiste der geteilten Ansicht per Wischen vom Rand (NavigationSplitView)
    weak var split: UISplitViewController?
    weak var scroll: UIScrollView?
    var scrollsToTop = true
    var keyboardScrolling = true
}

// MARK: - Bildschirm des iPads

/// Ruhezustand und Helligkeit des iPads fuer `EditorFreeze`
final class SystemFreezeScreen: EditorFreezeScreen {
    var idleTimerDisabled: Bool {
        get { MainActor.assumeIsolated { UIApplication.shared.isIdleTimerDisabled } }
        set { MainActor.assumeIsolated { UIApplication.shared.isIdleTimerDisabled = newValue } }
    }

    /// Mac ("Designed for iPad"): keine Helligkeit
    var supportsBrightness: Bool { !ProcessInfo.processInfo.isiOSAppOnMac }

    var brightness: Double {
        get { MainActor.assumeIsolated { Double(Self.screen.brightness) } }
        set { MainActor.assumeIsolated { Self.screen.brightness = CGFloat(min(1, max(0, newValue))) } }
    }

    @MainActor private static var screen: UIScreen {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return (scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)?.screen ?? UIScreen.main
    }
}

// MARK: - Sitzung (je geoeffnetem Dokument)

/// Stufe des Fixierens fuer die SwiftUI-Ansicht des Dokuments; nichts davon wird gespeichert
@MainActor
final class EditorFreezeSession: ObservableObject {
    @Published private(set) var mode: EditorFreeze.Mode = .off
    /// Schloss wird gerade gehalten (Fortschrittsring laeuft)
    @Published private(set) var holding = false
    let model: EditorFreeze
    private var holdTask: Task<Void, Never>?

    init(screen: EditorFreezeScreen = SystemFreezeScreen()) {
        model = EditorFreeze(screen: screen)
    }

    var isTracing: Bool { mode == .trace }
    var locksView: Bool { mode != .off }

    private func sync() {
        if mode != model.mode { mode = model.mode }
        if holding != model.isHolding { holding = model.isHolding }
    }

    /// Cmd-L und Menue
    func toggleView() { model.toggleView(); sync() }
    func fixView() { model.fixView(); sync() }
    func startTracing(_ options: EditorFreeze.TraceOptions) { model.startTracing(options); sync() }
    /// "Lösen", Esc, VoiceOver-Aktion "Entsperren"
    func unlock() { holdTask?.cancel(); model.unlock(); sync() }
    /// Dokument geschlossen
    func end() { holdTask?.cancel(); model.end(); sync() }
    func suspend() { holdTask?.cancel(); model.suspend(); sync() }
    func resume() { model.resume(); sync() }

    /// Finger auf dem Schloss: nach `EditorFreeze.unlockHoldDuration` entsperrt es, falls noch gehalten
    func holdBegan(at now: Date = Date()) {
        guard mode == .trace, !holding else { return }
        model.holdBegan(at: now)
        sync()
        holdTask?.cancel()
        holdTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(EditorFreeze.unlockHoldDuration * 1_000_000_000) + 20_000_000)
            guard !Task.isCancelled else { return }
            self?.holdCheck()
        }
    }

    func holdCheck(at now: Date = Date()) {
        model.holdCheck(at: now)
        sync()
    }

    /// Losgelassen: lange genug gehalten -> entsperrt, sonst bleibt alles gesperrt
    func holdEnded(at now: Date = Date()) {
        holdTask?.cancel()
        model.holdEnded(at: now)
        sync()
    }
}

// MARK: - Editor

extension PDFEditorController {
    /// Stufe gewechselt (`freezeMode`)
    func freezeModeChanged(from old: EditorFreeze.Mode) {
        if old == .off { captureFreezeAnchor() }
        if freezeMode == .off { freezeAnchor = nil }
        // Abpausen: keine Eingabe, auch der Stift nicht (Papier auf dem Bildschirm); Auswahl und Tastatur weg
        let tracing = freezeMode == .trace
        pdfView.isUserInteractionEnabled = !tracing
        if tracing {
            pdfView.clearSelection()
            view.window?.endEditing(true)
        }
        applyFreezeGestures()
        if old == .trace || tracing { showToolPicker(pickerAllowed) }
        applyTraceLook()
    }

    /// Scrollen, Pinch, Doppeltippen, Tastatur-Scrollen und die Wischgesten des Systems je nach Stufe
    func applyFreezeGestures() {
        guard isViewLoaded else { return }
        let locked = freezeMode != .off
        if locked {
            acquireSystemGestures()
            for g in Self.zoomTapGestures(in: pdfView) where g.isEnabled {
                g.isEnabled = false
                freezeDisabledGestures.append(WeakGesture(g))
            }
        } else {
            freezeDisabledGestures.forEach { $0.gesture?.isEnabled = true }
            freezeDisabledGestures = []
            releaseSystemGestures()
        }
        if let scroll = firstScrollView(in: pdfView) {
            scroll.isScrollEnabled = !locked
            scroll.pinchGestureRecognizer?.isEnabled = !locked
            if locked {
                scroll.scrollsToTop = false                  // Tippen auf die Statusleiste
                if #available(iOS 17.0, *) { scroll.allowsKeyboardScrolling = false }
            }
        }
    }

    /// Doppeltippen zum Zoomen (PDFKit); eigene Objekte auf der Seite (Doppeltippen zum Bearbeiten) bleiben
    static func zoomTapGestures(in v: UIView) -> [UIGestureRecognizer] {
        if v is PageInkView { return [] }
        var out = (v.gestureRecognizers ?? []).filter { ($0 as? UITapGestureRecognizer)?.numberOfTapsRequired == 2 }
        for sub in v.subviews { out += zoomTapGestures(in: sub) }
        return out
    }

    /// Zurueck-Wischen und Seitenleiste per Wischen vom Rand aus, Tippen auf die Statusleiste aus (nur der Editor mit
    /// der Palette, in der geteilten Ansicht also einmal)
    private func acquireSystemGestures() {
        guard freezeSystemGestures == nil else { return }
        var s = FreezeSystemGestures()
        if ownsToolPicker {
            if let pop = navigationController?.interactivePopGestureRecognizer, pop.isEnabled {
                pop.isEnabled = false
                s.pop = pop
            }
            if let split = splitViewController, split.presentsWithGesture {
                split.presentsWithGesture = false
                s.split = split
            }
        }
        if let scroll = firstScrollView(in: pdfView) {
            s.scroll = scroll
            s.scrollsToTop = scroll.scrollsToTop
            if #available(iOS 17.0, *) { s.keyboardScrolling = scroll.allowsKeyboardScrolling }
        }
        freezeSystemGestures = s
    }

    /// Gesten wie vor dem Fixieren (auch wenn der Editor verschwindet)
    func releaseSystemGestures() {
        guard let s = freezeSystemGestures else { return }
        s.pop?.isEnabled = true
        s.split?.presentsWithGesture = true
        if let scroll = s.scroll {
            scroll.scrollsToTop = s.scrollsToTop
            if #available(iOS 17.0, *) { scroll.allowsKeyboardScrolling = s.keyboardScrolling }
        }
        freezeSystemGestures = nil
    }

    /// Kontrast fuer das Abpausen: weisser Hintergrund ohne Seitenschatten
    func applyTraceLook() {
        guard isViewLoaded else { return }
        let white = freezeMode == .trace && traceContrast
        let bg: UIColor = white ? .white : .secondarySystemBackground
        view.backgroundColor = bg
        pdfView.backgroundColor = bg
        pdfView.pageShadowsEnabled = !white
    }

    /// Stelle beim Fixieren merken: Seite unter der linken oberen Ecke und Zoom
    func captureFreezeAnchor() {
        guard isViewLoaded, let doc = pdfView.document, doc.pageCount > 0 else { freezeAnchor = nil; return }
        let corner = CGPoint(x: pdfView.bounds.minX, y: pdfView.bounds.minY)
        guard let page = pdfView.page(for: corner, nearest: true) ?? pdfView.currentPage else { freezeAnchor = nil; return }
        let index = doc.index(for: page)
        freezeAnchor = FreezeAnchor(key: shownLayout?.key(at: index), index: index, point: pdfView.convert(corner, to: page),
                                    scale: pdfView.scaleFactor)
    }

    /// Nach einem Layout (Leisten aus, Seitenleiste, Drehen): gleicher Zoom, gleiche Stelle
    func keepFrozenView() {
        guard let a = freezeAnchor else { return }
        if abs(pdfView.scaleFactor - a.scale) > 0.0001 {
            pdfView.minScaleFactor = min(pdfView.minScaleFactor, a.scale)
            pdfView.maxScaleFactor = max(pdfView.maxScaleFactor, a.scale)
            pdfView.scaleFactor = a.scale
        }
        restoreFreezeAnchor()
    }

    /// Sofort und nach dem naechsten Durchlauf (PDFKit legt seine Seiten teils erst danach an)
    func restoreFreezeAnchor() {
        alignToFreezeAnchor()
        DispatchQueue.main.async { [weak self] in self?.alignToFreezeAnchor() }
    }

    private func alignToFreezeAnchor() {
        guard let a = freezeAnchor, let doc = pdfView.document, doc.pageCount > 0, let scroll = firstScrollView(in: pdfView) else { return }
        let index = a.key.flatMap { shownLayout?.index(ofKey: $0) } ?? min(a.index, doc.pageCount - 1)
        guard let page = doc.page(at: index) else { return }
        pdfView.layoutIfNeeded()
        let now = pdfView.convert(a.point, from: page)
        let dx = now.x - pdfView.bounds.minX, dy = now.y - pdfView.bounds.minY
        guard abs(dx) > 0.25 || abs(dy) > 0.25 else { return }
        let inset = scroll.adjustedContentInset
        let maxX = max(-inset.left, scroll.contentSize.width - scroll.bounds.width + inset.right)
        let maxY = max(-inset.top, scroll.contentSize.height - scroll.bounds.height + inset.bottom)
        let x = min(max(-inset.left, scroll.contentOffset.x + dx), maxX)
        let y = min(max(-inset.top, scroll.contentOffset.y + dy), maxY)
        scroll.setContentOffset(CGPoint(x: x, y: y), animated: false)
    }

    /// Sichtbarer Ausschnitt der Seite unter der linken oberen Ecke, in Seitenpunkten (nur fuer Tests)
    func visiblePageRectForTesting() -> (index: Int, rect: CGRect)? {
        guard let doc = pdfView.document,
              let page = pdfView.page(for: CGPoint(x: pdfView.bounds.minX, y: pdfView.bounds.minY), nearest: true) else { return nil }
        return (doc.index(for: page), pdfView.convert(pdfView.bounds, to: page))
    }
}
