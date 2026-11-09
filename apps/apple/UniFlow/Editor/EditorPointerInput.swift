import PDFKit
import PencilKit
import UIKit

// Bedienung des Editors ohne Finger und Stift: Mac ("Designed for iPad", dieselbe App) mit Maus, Trackpad und Tastatur,
// iPad mit Tastatur (docs/paritaet/MAC-BEDIENUNG-2026-11-09.md). Die Logik steht hier ohne UIKit-Zustand, damit sie auf
// dem iPad-Simulator und auf dem Mac gleich getestet wird.

/// Wer im Editor schreibt und wer blaettert
enum EditorPointer {
    struct Config: Equatable {
        /// Zeichenflaechen (eigene Notizen und Korrektur)
        var drawingPolicy: PKCanvasViewDrawingPolicy
        /// Beruehrungsarten, mit denen die Rollflaeche der PDF-Ansicht verschoben und gezoomt wird
        var panTouchTypes: [UITouch.TouchType]
        /// so viele Finger (bzw. eine Maus) verschieben die Rollflaeche
        var panMinimumTouches: Int
    }

    /// `pencilOnly`: Schalter in der Leiste und in den Einstellungen ("Nur Stift schreibt, Finger navigiert").
    ///
    /// - iPad: "Nur Stift" (Standard) = der Stift schreibt, ein Finger blaettert; "Finger zeichnet" = jede Beruehrung
    ///   schreibt, zwei Finger blaettern. Der Stift blaettert nie.
    /// - Mac: keinen Stift; derselbe Schalter heisst "Maus blättert" (Standard: Ziehen mit der Maus verschiebt das
    ///   Dokument in alle Richtungen, wie der Finger am iPad, und schreibt nicht) bzw. "Maus schreibt" (Ziehen schreibt
    ///   mit dem Werkzeug der Palette). Vorher schrieb am Mac jedes Ziehen, das Dokument liess sich mit der Maus nicht
    ///   verschieben (Befund des Inhabers 09.11.2026). Klicks kommen in iPad-Apps am Mac als direkte Beruehrung; die
    ///   indirekte Zeigerart ist mit erlaubt, falls macOS sie liefert.
    /// - Beide: zwei Finger auf dem Trackpad, Mausrad und Trackpad-Pinch sind keine Beruehrungen (UIKit pruefte sie in
    ///   `shouldReceiveEvent:` nur gegen `allowedScrollTypesMask`): sie rollen und zoomen in jedem Stand.
    static func config(isMac: Bool, pencilOnly: Bool) -> Config {
        let types: [UITouch.TouchType] = isMac ? [.direct, .indirectPointer] : [.direct]
        return Config(drawingPolicy: pencilOnly ? .pencilOnly : .anyInput, panTouchTypes: types, panMinimumTouches: pencilOnly ? 1 : 2)
    }

    /// Schalter in der Leiste: Titel und Symbol fuer den aktuellen Stand
    static func toggleLabel(isMac: Bool, pencilOnly: Bool) -> (title: String, icon: String) {
        if isMac { return pencilOnly ? ("Maus blättert", "hand.point.up.left") : ("Maus schreibt", "pencil.tip") }
        return pencilOnly ? ("Nur Stift", "applepencil") : ("Finger zeichnet", "hand.draw")
    }

    /// Mac: Erklaerung beim Umschalten und als Hilfetext des Schalters
    static func macHint(pencilOnly: Bool) -> String {
        pencilOnly
            ? "Maus blättert: Ziehen verschiebt das Dokument. Rollen mit Trackpad oder Mausrad, Zoom mit Cmd + und Cmd −. Zum Schreiben „Maus blättert“ antippen."
            : "Maus schreibt mit dem Werkzeug der Palette. Blättern mit zwei Fingern auf dem Trackpad, dem Mausrad oder den Pfeiltasten."
    }

    /// Einstellungen ("Stift & Touch"): Titel der Zeile und Wahl, am Mac fuer Maus und Trackpad
    static func settingsTitle(isMac: Bool) -> String { isMac ? "Maus & Trackpad" : "Stift & Touch" }

    static func settingsOptions(isMac: Bool) -> [(String, String)] {
        if isMac {
            return [("all", "Maus schreibt (Blättern mit Trackpad, Mausrad oder Pfeiltasten)"),
                    ("pen_only", "Maus blättert, Schreiben über „Maus schreibt“ im Dokument")]
        }
        return [("all", "Finger darf schreiben (Handballen wird bei Stift ignoriert)"), ("pen_only", "Nur Stift schreibt, Finger navigiert")]
    }
}

/// Tastatur im Editor: Pfeile, Bild auf/ab, Leertaste, Pos1/Ende, Cmd +/-/0
enum EditorNavigation {
    enum Command: String, CaseIterable {
        case lineUp, lineDown, left, right, screenUp, screenDown, first, last, zoomIn, zoomOut, zoomFit
    }

    enum Step: Equatable {
        case scroll(CGPoint)
        case page(Int)
        case zoom(CGFloat)
        case fit
    }

    /// Rollflaeche der PDF-Ansicht
    struct Viewport: Equatable {
        var offset: CGPoint
        var contentSize: CGSize
        var boundsSize: CGSize
        var inset: UIEdgeInsets = .zero
    }

    /// Pfeil hoch/runter (pt der Rollflaeche)
    static let line: CGFloat = 56
    /// Pfeil links/rechts, wenn die Seite breiter ist als die Ansicht
    static let sideStep: CGFloat = 112
    /// Leertaste, Bild auf/ab: so viel der sichtbaren Hoehe (der Rest bleibt zur Orientierung stehen)
    static let screenFraction: CGFloat = 0.9
    /// Cmd + und Cmd -
    static let zoomFactor: CGFloat = 1.25

    /// Zwei Finger waagerecht auf dem Trackpad (Mac): ab dieser Strecke eine Seite
    static let swipeDistance: CGFloat = 60

    /// Seitenwechsel nach einem waagerechten Wischen mit zwei Fingern auf dem Trackpad: +1 naechste Seite (Finger nach
    /// links, das Blatt wandert nach links wie beim Umblaettern), -1 vorige; nil, wenn es eher senkrecht war (Rollen)
    /// oder die Seite breiter ist als die Ansicht (dann rollt das Wischen waagerecht, wie am iPad mit dem Finger).
    /// Die Richtung folgt der Einstellung "Natuerliches Scrollen" wie das Rollen selbst (UIKit rechnet sie ein).
    static func swipePages(translation t: CGPoint, horizontallyScrollable: Bool) -> Int? {
        guard !horizontallyScrollable, abs(t.x) >= swipeDistance, abs(t.x) > abs(t.y) * 1.5 else { return nil }
        return t.x < 0 ? 1 : -1
    }

    /// Was eine Taste bewirkt; nil = nichts (Rand, erste/letzte Seite, Zoomgrenze, kein Dokument)
    static func step(_ command: Command, viewport v: Viewport, page: Int, pageCount: Int, scale: CGFloat,
                     scaleRange: ClosedRange<CGFloat>) -> Step? {
        guard pageCount > 0 else { return nil }
        let minX = -v.inset.left, maxX = max(minX, v.contentSize.width - v.boundsSize.width + v.inset.right)
        let minY = -v.inset.top, maxY = max(minY, v.contentSize.height - v.boundsSize.height + v.inset.bottom)
        func scrollY(_ dy: CGFloat) -> Step? {
            let y = min(maxY, max(minY, v.offset.y + dy))
            return abs(y - v.offset.y) < 0.5 ? nil : .scroll(CGPoint(x: v.offset.x, y: y))
        }
        func turn(_ delta: Int) -> Step? {
            let next = page + delta
            return (0..<pageCount).contains(next) ? .page(next) : nil
        }
        func side(_ dir: CGFloat) -> Step? {
            // gezoomt (Seite breiter als die Ansicht): erst waagerecht bis zum Rand, dann die Seite wechseln
            if maxX - minX > 0.5 {
                let x = min(maxX, max(minX, v.offset.x + dir * sideStep))
                if abs(x - v.offset.x) >= 0.5 { return .scroll(CGPoint(x: x, y: v.offset.y)) }
            }
            return turn(dir > 0 ? 1 : -1)
        }
        func zoom(_ to: CGFloat) -> Step? {
            let z = min(scaleRange.upperBound, max(scaleRange.lowerBound, to))
            return abs(z - scale) < 0.0001 ? nil : .zoom(z)
        }
        switch command {
        case .lineUp: return scrollY(-line)
        case .lineDown: return scrollY(line)
        case .screenUp: return scrollY(-v.boundsSize.height * screenFraction)
        case .screenDown: return scrollY(v.boundsSize.height * screenFraction)
        case .left: return side(-1)
        case .right: return side(1)
        case .first: return .page(0)
        case .last: return .page(pageCount - 1)
        case .zoomIn: return zoom(scale * zoomFactor)
        case .zoomOut: return zoom(scale / zoomFactor)
        case .zoomFit: return .fit
        }
    }
}

// MARK: - Tasten im Editor

extension PDFEditorController {
    /// Taste, Umschalttasten, Befehl, Titel (Titel nur fuer die Uebersicht beim Halten von Cmd)
    static let editorKeys: [(input: String, modifiers: UIKeyModifierFlags, command: EditorNavigation.Command, title: String)] = [
        (UIKeyCommand.inputRightArrow, [], .right, "Nächste Seite"),
        (UIKeyCommand.inputLeftArrow, [], .left, "Vorherige Seite"),
        (UIKeyCommand.inputDownArrow, [], .lineDown, ""),
        (UIKeyCommand.inputUpArrow, [], .lineUp, ""),
        (UIKeyCommand.inputPageDown, [], .screenDown, ""),
        (UIKeyCommand.inputPageUp, [], .screenUp, ""),
        (" ", [], .screenDown, ""),
        (" ", [.shift], .screenUp, ""),
        (UIKeyCommand.inputHome, [], .first, ""),
        (UIKeyCommand.inputEnd, [], .last, ""),
        (UIKeyCommand.inputUpArrow, [.command], .first, "Erste Seite"),
        (UIKeyCommand.inputDownArrow, [.command], .last, "Letzte Seite"),
        ("+", [.command], .zoomIn, "Vergrößern"),
        ("=", [.command], .zoomIn, ""),
        ("-", [.command], .zoomOut, "Verkleinern"),
        ("0", [.command], .zoomFit, "Auf Seitenbreite"),
    ]

    var editorKeyCommands: [UIKeyCommand] {
        Self.editorKeys.map { k in
            UIKeyCommand(title: k.title, action: #selector(editorKey(_:)), input: k.input, modifierFlags: k.modifiers,
                         propertyList: k.command.rawValue)
        }
    }

    /// Nicht, waehrend getippt wird (Textobjekt, Feld der KI-Hilfe), ein Blatt darueber liegt oder die Ansicht fixiert ist
    var acceptsEditorKeys: Bool {
        freezeMode == .off && blockingPresentation() == nil && !Self.isTypingField(UIResponder.uf_current)
    }

    @objc func editorKey(_ key: UIKeyCommand) {
        guard let raw = key.propertyList as? String, let command = EditorNavigation.Command(rawValue: raw) else { return }
        perform(command)
    }

    /// Einen Tastenbefehl ausfuehren; false, wenn nichts zu tun ist (Rand, fixiert, kein Dokument)
    @discardableResult
    func perform(_ command: EditorNavigation.Command, animated: Bool = true) -> Bool {
        guard freezeMode == .off, let scroll = firstScrollView(in: pdfView), let count = pdfView.document?.pageCount, count > 0
        else { return false }
        let viewport = EditorNavigation.Viewport(offset: scroll.contentOffset, contentSize: scroll.contentSize,
                                                 boundsSize: scroll.bounds.size, inset: scroll.adjustedContentInset)
        let low = min(pdfView.minScaleFactor, pdfView.maxScaleFactor)
        guard let step = EditorNavigation.step(command, viewport: viewport, page: currentPageIndex, pageCount: count,
                                               scale: pdfView.scaleFactor, scaleRange: low...max(low, pdfView.maxScaleFactor))
        else { return false }
        switch step {
        case .scroll(let p): scroll.setContentOffset(p, animated: animated && !UIAccessibility.isReduceMotionEnabled)
        case .page(let i): goToPage(i)
        case .zoom(let z): pdfView.scaleFactor = z
        case .fit: fitWidth()
        }
        return true
    }
}

// MARK: - Mac: Trackpad waagerecht = Seite weiter/zurueck

/// Nur Rollereignisse des Trackpads (zwei Finger, `.continuous`; das Mausrad rollt nur senkrecht), keine Beruehrungen:
/// Klicken und Ziehen mit der Maus bleibt beim Editor (blaettern oder schreiben). Laeuft neben dem Rollen der PDF-Ansicht.
final class TrackpadPageSwipe: NSObject, UIGestureRecognizerDelegate {
    let recognizer = UIPanGestureRecognizer()
    private weak var controller: PDFEditorController?

    init(controller: PDFEditorController) {
        self.controller = controller
        super.init()
        recognizer.addTarget(self, action: #selector(panned(_:)))
        recognizer.allowedScrollTypesMask = .continuous
        recognizer.allowedTouchTypes = []
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = self
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        guard g.state == .ended, let c = controller, let scroll = c.firstScrollView(in: c.pdfView) else { return }
        let wide = scroll.contentSize.width + scroll.adjustedContentInset.left + scroll.adjustedContentInset.right
            > scroll.bounds.width + 0.5
        guard let delta = EditorNavigation.swipePages(translation: g.translation(in: g.view), horizontallyScrollable: wide)
        else { return }
        c.perform(delta > 0 ? .right : .left)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
