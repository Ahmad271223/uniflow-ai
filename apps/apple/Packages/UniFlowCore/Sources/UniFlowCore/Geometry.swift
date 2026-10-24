import Foundation

/// Seitenkoordinaten: Punkte der angezeigten Seite (inklusive Drehung), Ursprung oben links, ohne Zoom.
/// So speichert auch der Web-Editor (pdf.js-Viewport mit Massstab 1).
public struct PageGeometry: Equatable, Sendable {
    /// Groesse der angezeigten Seite in Punkten.
    public var pageSize: CGSize

    /// - Parameters:
    ///   - boxSize: Groesse der Seitenbox (CropBox) ohne Drehung.
    ///   - rotation: Seitendrehung in Grad (0, 90, 180, 270; andere Werte werden auf Vielfache von 90 gerundet).
    public init(boxSize: CGSize, rotation: Int) {
        let r = ((Int((Double(rotation) / 90).rounded()) * 90) % 360 + 360) % 360
        pageSize = (r == 90 || r == 270) ? CGSize(width: boxSize.height, height: boxSize.width) : boxSize
    }

    public init(pageSize: CGSize) { self.pageSize = pageSize }

    /// Massstab einer Ansicht, die die ganze Seite zeigt (Ansichtsbreite / Seitenbreite).
    public func scale(forViewSize view: CGSize) -> CGFloat {
        guard pageSize.width > 0, view.width > 0 else { return 1 }
        return view.width / pageSize.width
    }

    public func toPage(_ p: CGPoint, viewSize: CGSize) -> CGPoint {
        let s = scale(forViewSize: viewSize)
        return CGPoint(x: p.x / s, y: p.y / s)
    }

    public func toView(_ p: CGPoint, viewSize: CGSize) -> CGPoint {
        let s = scale(forViewSize: viewSize)
        return CGPoint(x: p.x * s, y: p.y * s)
    }
}

/// Zoomregeln der Dokumentansicht. Ziel: kein Zuruecksetzen des Zooms, wenn sich nur die Flaeche aendert
/// (Werkzeugleiste, Drehung, Split View), und kein Springen nach dem Abheben des Stifts.
public enum ZoomPolicy {
    public static let minFactor: CGFloat = 0.5
    public static let maxFactor: CGFloat = 6

    public static func limits(fitScale: CGFloat) -> ClosedRange<CGFloat> {
        let fit = max(fitScale, 0.01)
        return (fit * minFactor)...(fit * maxFactor)
    }

    /// Neuer Zoom nach einer Groessenaenderung der Ansicht.
    /// - Hat der Nutzer nicht selbst gezoomt, bleibt die Seite eingepasst.
    /// - Sonst bleibt der Zoom relativ zur Einpassung gleich (z. B. beim Drehen des iPads).
    public static func scaleAfterResize(current: CGFloat, oldFit: CGFloat, newFit: CGFloat, userZoomed: Bool) -> CGFloat {
        guard oldFit > 0, newFit > 0 else { return current }
        let next = userZoomed ? current * newFit / oldFit : newFit
        let range = limits(fitScale: newFit)
        return min(max(next, range.lowerBound), range.upperBound)
    }

    /// Ob eine gemeldete Zoomaenderung vom Nutzer kommt (und nicht nur Rundung beim Einpassen ist).
    public static func isUserZoom(scale: CGFloat, fitScale: CGFloat) -> Bool {
        guard fitScale > 0 else { return false }
        return abs(scale / fitScale - 1) > 0.01
    }
}
