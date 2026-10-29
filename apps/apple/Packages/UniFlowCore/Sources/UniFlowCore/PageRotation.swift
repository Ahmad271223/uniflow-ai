import Foundation

/// Seite drehen ohne Verrutschen (P0-7), wie `rotateObjects` in app/static/pagerotate.js; gemeinsame Testfaelle:
/// packages/shared-contracts/fixtures/rotate/cases.json.
///
/// Notizobjekte stehen in Punkten der angezeigten Seite (siehe `SolutionGeometry`). Dreht man die Seite im
/// Uhrzeigersinn, drehen alle Objekte als Ganzes mit: je 90 Grad wird der Ursprung (x, y) einer Seite mit angezeigter
/// Groesse W x H zu (H - y, x) und die Drehung um 90 Grad groesser. Punkte, Breite, Hoehe, Massstab und alle anderen
/// Felder bleiben unveraendert.
public enum PageRotation {
    /// Objekte einer Seite mit angezeigter Groesse `width` x `height` um `degrees` (Vielfaches von 90) drehen.
    public static func rotate(_ objects: [JSONValue], width: Double, height: Double, degrees: Int = 90) -> [JSONValue] {
        let turns = ((jsRound(Double(degrees) / 90) % 4) + 4) % 4
        guard turns > 0 else { return objects }
        return objects.map { o in
            guard var obj = o.object else { return o }
            var x = finite(obj["x"]) ?? 0, y = finite(obj["y"]) ?? 0, w = width, h = height
            for _ in 0..<turns { (x, y) = (h - y, x); (w, h) = (h, w) }
            let rot = (finite(obj["rotation"]) ?? 0) + Double(90 * turns)
            obj["x"] = .number(round2(x))
            obj["y"] = .number(round2(y))
            obj["rotation"] = .number((rot.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360))
            return .object(obj)
        }
    }

    /// Abbildung der Seitenpunkte fuer dieselbe Drehung (fuer die native Zeichnung des iPads).
    public static func transform(width: Double, height: Double, degrees: Int = 90) -> SolutionAffine {
        let turns = ((jsRound(Double(degrees) / 90) % 4) + 4) % 4
        var t = SolutionAffine.identity, w = width, h = height
        for _ in 0..<turns {
            t = t.followed(by: SolutionAffine(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0))      // (x, y) -> (H - y, x)
            (w, h) = (h, w)
        }
        return t
    }

    private static func finite(_ v: JSONValue?) -> Double? {
        guard let d = v?.double, d.isFinite else { return nil }
        return d
    }

    /// `Math.round` wie im Browser: halbe Werte nach oben (auch bei negativen Zahlen)
    private static func jsRound(_ v: Double) -> Int {
        let f = v.rounded(.down)
        return Int(v - f >= 0.5 ? f + 1 : f)
    }

    static func round2(_ v: Double) -> Double {
        let t = v * 100, f = t.rounded(.down)
        return (t - f >= 0.5 ? f + 1 : f) / 100
    }
}
