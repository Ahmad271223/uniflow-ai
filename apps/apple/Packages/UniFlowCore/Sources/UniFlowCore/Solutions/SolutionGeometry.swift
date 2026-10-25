import Foundation

/// Affine Abbildung in Seitenpunkten (Konvention wie CGAffineTransform):
/// x' = a*x + c*y + tx, y' = b*x + d*y + ty.
public struct SolutionAffine: Equatable, Sendable {
    public var a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double

    public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty
    }

    public static let identity = SolutionAffine(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    public var isIdentity: Bool { self == .identity }

    public func apply(x: Double, y: Double) -> (x: Double, y: Double) {
        (a * x + c * y + tx, b * x + d * y + ty)
    }

    /// Erst `self`, danach `then`.
    public func followed(by then: SolutionAffine) -> SolutionAffine {
        SolutionAffine(a: then.a * a + then.c * b, b: then.b * a + then.d * b,
                       c: then.a * c + then.c * d, d: then.b * c + then.d * d,
                       tx: then.a * tx + then.c * ty + then.tx, ty: then.b * tx + then.d * ty + then.ty)
    }

    /// Umkehrung (nur Drehungen um Vielfache von 90 Grad, Determinante +-1).
    public var inverted: SolutionAffine {
        let det = a * d - b * c
        guard det != 0 else { return .identity }
        let ia = d / det, ib = -b / det, ic = -c / det, id = a / det
        return SolutionAffine(a: ia, b: ib, c: ic, d: id, tx: -(ia * tx + ic * ty), ty: -(ib * tx + id * ty))
    }
}

/// Seitendrehung und Koordinaten fuer geteilte Loesungen.
///
/// Notizobjekte stehen in Punkten der *angezeigten* Seite: Ursprung oben links, inklusive Drehung (eigene `/Rotate`
/// der PDF plus zusaetzliche Drehung aus `pageOrder`), ohne Zoom (siehe `PageGeometry`). Hat der Empfaenger dieselbe
/// Seite anders gedreht als der Absender, bildet `transform(width:height:from:to:)` die Punkte des Absenders auf
/// seine Anzeige ab, damit die Loesung auf demselben Inhalt der Seite liegt. Die Objekte selbst werden dafuer nie
/// umgerechnet (sie bleiben 1:1 wie geteilt); umgerechnet wird nur die Anzeige.
public enum SolutionGeometry {
    /// 0, 90, 180 oder 270 (im Uhrzeigersinn, wie `/Rotate` in PDF und `rotation` in `pageOrder`).
    public static func normalized(_ degrees: Int) -> Int { ((degrees / 90 * 90) % 360 + 360) % 360 }

    /// Groesse der angezeigten Seite fuer eine Seitenbox ohne Drehung (`width` x `height`).
    public static func displaySize(width: Double, height: Double, rotation: Int) -> (width: Double, height: Double) {
        normalized(rotation) % 180 == 0 ? (width, height) : (height, width)
    }

    /// Seitenbox ohne Drehung (Ursprung oben links) -> angezeigte Seite mit `rotation` (im Uhrzeigersinn).
    public static func fromUnrotated(width W: Double, height H: Double, rotation: Int) -> SolutionAffine {
        switch normalized(rotation) {
        case 90: return SolutionAffine(a: 0, b: 1, c: -1, d: 0, tx: H, ty: 0)      // (x, y) -> (H - y, x)
        case 180: return SolutionAffine(a: -1, b: 0, c: 0, d: -1, tx: W, ty: H)    // (x, y) -> (W - x, H - y)
        case 270: return SolutionAffine(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: W)     // (x, y) -> (y, W - x)
        default: return .identity
        }
    }

    /// Angezeigte Seite mit Drehung `from` (Absender) -> angezeigte Seite mit Drehung `to` (Empfaenger), fuer dieselbe
    /// Seitenbox ohne Drehung (`width` x `height` in PDF-Punkten).
    public static func transform(width: Double, height: Double, from: Int, to: Int) -> SolutionAffine {
        let f = normalized(from), t = normalized(to)
        if f == t { return .identity }
        return fromUnrotated(width: width, height: height, rotation: f).inverted
            .followed(by: fromUnrotated(width: width, height: height, rotation: t))
    }
}
