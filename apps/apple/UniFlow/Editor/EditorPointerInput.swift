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
    static func config(isMac: Bool, pencilOnly: Bool) -> Config {
        if isMac { return Config(drawingPolicy: .anyInput, panTouchTypes: [.direct], panMinimumTouches: 2) }
        return Config(drawingPolicy: pencilOnly ? .pencilOnly : .anyInput, panTouchTypes: [.direct], panMinimumTouches: pencilOnly ? 1 : 2)
    }

    /// Schalter in der Leiste: Titel und Symbol fuer den aktuellen Stand
    static func toggleLabel(isMac: Bool, pencilOnly: Bool) -> (title: String, icon: String) {
        pencilOnly ? ("Nur Stift", "applepencil") : ("Finger zeichnet", "hand.draw")
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

    static func step(_ command: Command, viewport: Viewport, page: Int, pageCount: Int, scale: CGFloat,
                     scaleRange: ClosedRange<CGFloat>) -> Step? {
        nil
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
