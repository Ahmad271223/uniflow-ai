import Foundation

/// Objekt-Werkzeuge (Editor-Schritt 6, P1-4 bis P1-7, P2-7): Text, Haftnotiz, Formen, Auswahl und Textmarker an
/// PDF-Zeilen in den Feldern des Web-Editors (app/static/editor.js: `DEFAULT_TEXT`, `createText`, `createSticky`,
/// `shapeObj`, `addMarkup`, Transformer). Reine Funktionen auf der Objektliste einer Seite; Koordinaten in Punkten der
/// angezeigten Seite (Ursprung oben links). Striche bearbeitet weiter PencilKit, sie werden hier nie ausgewaehlt.
public enum PageObjectEdit {

    /// `DEFAULT_TEXT` im Web-Editor
    public static let defaultText: [String: JSONValue] = [
        "fontFamily": "Arial", "fontSize": 14, "fill": "#1d2130", "bold": false, "italic": false, "underline": false,
        "align": "left", "bg": "", "opacity": 1, "width": 220, "lineHeight": 1.25,
    ]
    /// Farbe einer neuen Haftnotiz (`stickyColor`)
    public static let stickyColor = "#fff7a8"
    /// Farben des Textmarkers (Auswahl im Web)
    public static let markerColors = ["#f5d90a", "#7ee081", "#7cc4ff", "#ff9ecb"]

    static func r2(_ v: Double) -> Double { PageRotation.round2(v) }

    // MARK: Anlegen

    /// Textfeld wie `createText` (Ursprung oben links an `x`, `y`), mit `source: "ipad"`
    public static func text(id: String, x: Double, y: Double, text: String = "") -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "type": "text", "x": .number(r2(x)), "y": .number(r2(y)),
                                      "text": .string(text), "rotation": 0, "scaleX": 1, "scaleY": 1, "source": "ipad"]
        for (k, v) in defaultText { o[k] = v }
        return .object(o)
    }

    /// Haftnotiz wie `createSticky`: Textfeld 10 pt links oberhalb des Tippunkts, gelb, 170 breit, Schrift 13
    public static func sticky(id: String, x: Double, y: Double, text: String = "", color: String = stickyColor) -> JSONValue {
        var o = PageObjectEdit.text(id: id, x: x - 10, y: y - 10, text: text).object ?? [:]
        o["bg"] = .string(color)
        o["width"] = 170
        o["fontSize"] = 13
        return .object(o)
    }

    /// Formarten wie im Web (`shapeKind`)
    public static let shapeKinds = ["rect", "ellipse", "triangle", "line", "arrow"]

    /// Form wie `shapeObj(kind, x0, y0, x1, y1)`: Linie und Pfeil mit Punkten, sonst Rechteck aus den Ecken
    public static func shape(id: String, kind: String, from a: (x: Double, y: Double), to b: (x: Double, y: Double),
                             color: String, width: Double, fill: String = "", opacity: Double = 1) -> JSONValue? {
        guard shapeKinds.contains(kind) else { return nil }
        var o: [String: JSONValue] = ["id": .string(id), "type": "shape", "shape": .string(kind), "stroke": .string(color),
                                      "strokeWidth": .number(r2(width)), "fill": .string(fill), "opacity": .number(opacity),
                                      "rotation": 0, "scaleX": 1, "scaleY": 1, "source": "ipad"]
        if kind == "line" || kind == "arrow" {
            o["x"] = 0; o["y"] = 0
            o["points"] = .array([a.x, a.y, b.x, b.y].map { .number(r2($0)) })
            o["width"] = .number(r2(abs(b.x - a.x) + abs(b.y - a.y)))
        } else {
            o["x"] = .number(r2(min(a.x, b.x))); o["y"] = .number(r2(min(a.y, b.y)))
            o["width"] = .number(r2(abs(b.x - a.x))); o["height"] = .number(r2(abs(b.y - a.y)))
        }
        return .object(o)
    }

    // MARK: Textmarker an PDF-Zeilen (`addMarkup`)

    /// Eine Zeile markierten PDF-Texts in Seitenpunkten; `up` zeigt zur Oberkante der Schrift (waagerechter Text:
    /// (0, -1))
    public struct Line: Equatable, Sendable {
        public var text: String
        public var x0: Double, y0: Double, x1: Double, y1: Double
        public var up: (x: Double, y: Double)
        public init(text: String, x0: Double, y0: Double, x1: Double, y1: Double, up: (x: Double, y: Double) = (0, -1)) {
            self.text = text; self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1; self.up = up
        }
        public static func == (l: Line, r: Line) -> Bool {
            l.text == r.text && l.x0 == r.x0 && l.y0 == r.y0 && l.x1 == r.x1 && l.y1 == r.y1 && l.up == r.up
        }
    }

    public enum Markup: String, CaseIterable, Sendable { case highlight, underline, strike }

    /// Objekte wie `addMarkup(pg, lines, kind, color)`: Markieren als halbdurchsichtiges Rechteck, Unterstreichen und
    /// Durchstreichen als Linie quer zur Schreibrichtung (Gelb wird bei Linien zu Rot)
    public static func markup(_ kind: Markup, lines: [Line], color: String, newID: () -> String) -> [JSONValue] {
        lines.map { l in
            if kind == .highlight {
                return .object(["id": .string(newID()), "type": "shape", "shape": "rect", "markup": "highlight", "text": .string(l.text),
                                "x": .number(r2(l.x0)), "y": .number(r2(l.y0)), "width": .number(r2(l.x1 - l.x0)),
                                "height": .number(r2(l.y1 - l.y0)), "fill": .string(color), "stroke": "", "strokeWidth": 0,
                                "opacity": 0.35, "rotation": 0, "scaleX": 1, "scaleY": 1])
            }
            let (ux, uy) = l.up
            let vertical = abs(ux) > abs(uy)
            let t = vertical ? l.x1 - l.x0 : l.y1 - l.y0
            let lo = vertical ? (ux > 0 ? l.x0 : l.x1) : (uy < 0 ? l.y1 : l.y0)
            let dir = vertical ? -(sign(ux) == 0 ? 1 : sign(ux)) : -(sign(uy) == 0 ? -1 : sign(uy))
            let pos = r2(kind == .underline ? lo + dir * t * 0.08 : (vertical ? l.x0 + t * 0.45 : l.y0 + t * 0.55))
            let pts: [Double] = vertical ? [pos, r2(l.y0), pos, r2(l.y1)] : [r2(l.x0), pos, r2(l.x1), pos]
            return .object(["id": .string(newID()), "type": "shape", "shape": "line", "markup": .string(kind.rawValue), "text": .string(l.text),
                            "x": 0, "y": 0, "points": .array(pts.map { .number($0) }),
                            "stroke": .string(color == "#f5d90a" ? "#e5322d" : color), "strokeWidth": .number(r2(max(1, t * 0.08))),
                            "fill": "", "opacity": 1, "rotation": 0, "scaleX": 1, "scaleY": 1, "width": 1, "height": 1])
        }
    }

    private static func sign(_ v: Double) -> Double { v > 0 ? 1 : (v < 0 ? -1 : 0) }

    // MARK: Aendern

    /// Objekte mit diesen IDs verschieben (`x`, `y` + Abstand, gerundet wie im Web)
    public static func move(_ objects: [JSONValue], ids: Set<String>, dx: Double, dy: Double) -> [JSONValue] {
        objects.map { o in
            guard let id = o["id"]?.string, ids.contains(id), var obj = o.object else { return o }
            obj["x"] = .number(r2((o["x"]?.double ?? 0) + dx))
            obj["y"] = .number(r2((o["y"]?.double ?? 0) + dy))
            return .object(obj)
        }
    }

    /// Groesse aendern wie der Transformer: Massstab mal `factor` (bei Text die Breite, die Schrift bleibt lesbar)
    public static func scale(_ objects: [JSONValue], ids: Set<String>, factorX: Double, factorY: Double) -> [JSONValue] {
        guard factorX.isFinite, factorY.isFinite, factorX > 0, factorY > 0 else { return objects }
        return objects.map { o in
            guard let id = o["id"]?.string, ids.contains(id), var obj = o.object else { return o }
            if o["type"]?.string == "text" {
                obj["width"] = .number(r2(max(20, (o["width"]?.double ?? 220) * factorX)))
            } else {
                obj["scaleX"] = .number(((o["scaleX"]?.double ?? 1) * factorX * 1000).rounded() / 1000)
                obj["scaleY"] = .number(((o["scaleY"]?.double ?? 1) * factorY * 1000).rounded() / 1000)
            }
            return .object(obj)
        }
    }

    public static func delete(_ objects: [JSONValue], ids: Set<String>) -> [JSONValue] {
        objects.filter { o in !(o["id"]?.string.map(ids.contains) ?? false) }
    }

    /// Feld setzen (Text, Farbe, Schriftgroesse ...) fuer die Objekte mit diesen IDs
    public static func set(_ objects: [JSONValue], ids: Set<String>, _ key: String, _ value: JSONValue) -> [JSONValue] {
        objects.map { o in
            guard let id = o["id"]?.string, ids.contains(id), var obj = o.object else { return o }
            obj[key] = value
            return .object(obj)
        }
    }

    // MARK: Auswahl

    /// Achsenparalleles Rechteck um ein Objekt in Seitenpunkten (nach Drehung und Massstab); `textHeight` misst die
    /// Hoehe eines Textfelds (UIKit in der App). Striche: nil (die waehlt PencilKit aus).
    public static func bounds(_ o: JSONValue, textHeight: (JSONValue) -> Double) -> (minX: Double, minY: Double, maxX: Double, maxY: Double)? {
        let type = o["type"]?.string ?? ""
        guard type != "stroke" else { return nil }
        var local: [(Double, Double)]
        let w = o["width"]?.double ?? 0, h = o["height"]?.double ?? 0
        if type == "text" {
            local = [(0, 0), (w, 0), (w, textHeight(o)), (0, textHeight(o))]
        } else if let pts = o["points"]?.array?.compactMap({ $0.double }), pts.count >= 4 {
            local = stride(from: 0, to: pts.count - 1, by: 2).map { (pts[$0], pts[$0 + 1]) }
        } else {
            local = [(0, 0), (w, 0), (w, h), (0, h)]
        }
        let x = o["x"]?.double ?? 0, y = o["y"]?.double ?? 0
        let rot = (o["rotation"]?.double ?? 0) * .pi / 180
        let sx = o["scaleX"]?.double ?? 1, sy = o["scaleY"]?.double ?? 1
        let c = cos(rot), s = sin(rot)
        let pts = local.map { p -> (Double, Double) in
            let px = p.0 * sx, py = p.1 * sy
            return (x + px * c - py * s, y + px * s + py * c)
        }
        guard pts.allSatisfy({ $0.0.isFinite && $0.1.isFinite }) else { return nil }
        return (pts.map(\.0).min()!, pts.map(\.1).min()!, pts.map(\.0).max()!, pts.map(\.1).max()!)
    }

    /// Oberstes Objekt (zuletzt gezeichnet) unter dem Punkt, mit `slop` Punkten Spielraum (duenne Linien)
    public static func hit(_ objects: [JSONValue], x: Double, y: Double, slop: Double = 6,
                           textHeight: (JSONValue) -> Double) -> String? {
        for o in objects.reversed() {
            guard let id = o["id"]?.string, let b = bounds(o, textHeight: textHeight) else { continue }
            if x >= b.minX - slop, x <= b.maxX + slop, y >= b.minY - slop, y <= b.maxY + slop { return id }
        }
        return nil
    }

    /// Objekt-Lasso: alle Objekte, deren Mittelpunkt im Polygon (Seitenpunkte) liegt
    public static func inLasso(_ objects: [JSONValue], polygon: [(x: Double, y: Double)], textHeight: (JSONValue) -> Double) -> [String] {
        guard polygon.count >= 3 else { return [] }
        return objects.compactMap { o in
            guard let id = o["id"]?.string, let b = bounds(o, textHeight: textHeight) else { return nil }
            return contains(polygon, x: (b.minX + b.maxX) / 2, y: (b.minY + b.maxY) / 2) ? id : nil
        }
    }

    /// Punkt im Polygon (gerade/ungerade Regel)
    static func contains(_ poly: [(x: Double, y: Double)], x: Double, y: Double) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i], b = poly[j]
            if (a.y > y) != (b.y > y), x < (b.x - a.x) * (y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }
}
