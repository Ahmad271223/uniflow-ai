import Foundation

/// Klappkarten zum Abfragen (Auftrag des Inhabers 25.11.2026: "interaktive Karten, die man antippen kann, dann kommt
/// das Geschriebene, wenn man wieder antippt, wird das verdeckt … eine Schicht über der Schrift … bei Community wird
/// das automatisch mitgeschickt wie beim Original … mehrere coole Muster und verschiedene Größen").
///
/// Eine Klappkarte ist eine Abdeckung UEBER allem auf der Seite (PDF, getippter Text, Handschrift). Antippen deckt auf,
/// noch einmal antippen verdeckt wieder; der Zustand wird nicht gespeichert (beim Oeffnen ist alles verdeckt).
///
/// Speicherformat: Objekt `type: "shape"`, `shape: "rect"` mit deckender Fuellung (`fill`) und dem zusaetzlichen Feld
/// `cover: {pattern}`. Kein neuer Objekttyp: aeltere Apps, das Web und die Community (`SolutionValidator`) kennen
/// `shape`. Aeltere Apps zeigen ein farbiges Rechteck - es deckt dort getippten Text und die PDF ab, liegt aber unter
/// der Handschrift und laesst sich nicht aufklappen.
public enum FlipCover {

    public struct Choice: Hashable, Sendable {
        public var color: String
        public var pattern: String
        public var size: String

        public init(color: String = FlipCover.colors[0].hex, pattern: String = "stripes", size: String = "m") {
            self.color = color; self.pattern = pattern; self.size = size
        }
    }

    public static let colors: [(hex: String, title: String)] = [
        ("#3d4a6b", "Nachtblau"), ("#2f7fd1", "Blau"), ("#2e9e5b", "Grün"), ("#f08c1f", "Orange"), ("#e0568a", "Pink"),
        ("#7a4fd6", "Lila"),
    ]
    public static let patterns: [(id: String, title: String)] = [
        ("plain", "Einfarbig"), ("stripes", "Gestreift"), ("dots", "Gepunktet"), ("grid", "Kariert"), ("question", "Fragezeichen"),
    ]
    /// Groessen beim Antippen (Breite x Hoehe in Seitenpunkten): ein Wort, eine Zeile bzw. ein Absatz. Gezogen wird
    /// jede Groesse.
    public static let sizes: [(id: String, title: String, width: Double, height: Double)] = [
        ("s", "Wort", 110, 28), ("m", "Zeile", 260, 34), ("l", "Absatz", 380, 120),
    ]
    /// Kleinste Karte (bleibt antippbar)
    public static let minimum = (width: 28.0, height: 18.0)

    public static func isCover(_ o: JSONValue) -> Bool {
        o["type"]?.string == "shape" && o["cover"]?.object != nil
    }

    public static func pattern(_ o: JSONValue) -> String {
        let v = o["cover"]?["pattern"]?.string ?? ""
        return patterns.contains { $0.id == v } ? v : "plain"
    }

    public static func choice(_ o: JSONValue) -> Choice {
        let w = o["width"]?.double ?? 0
        let size = sizes.min { abs($0.width - w) < abs($1.width - w) }?.id ?? "m"
        return Choice(color: (o["fill"]?.string).flatMap { $0.isEmpty ? nil : $0 } ?? colors[0].hex, pattern: pattern(o), size: size)
    }

    /// Karte ueber einem Rechteck (gezogen). Zu kleine Rechtecke werden auf die kleinste Karte vergroessert.
    public static func cover(id: String, x: Double, y: Double, width: Double, height: Double, choice: Choice = Choice()) -> JSONValue {
        let r2 = PageObjectEdit.r2
        let pattern = patterns.contains { $0.id == choice.pattern } ? choice.pattern : "plain"
        return .object([
            "id": .string(id), "type": "shape", "shape": "rect",
            "x": .number(r2(x)), "y": .number(r2(y)),
            "width": .number(r2(max(minimum.width, width))), "height": .number(r2(max(minimum.height, height))),
            "fill": .string(choice.color.isEmpty ? colors[0].hex : choice.color), "stroke": "", "strokeWidth": 0, "opacity": 1,
            "rotation": 0, "scaleX": 1, "scaleY": 1, "source": "ipad",
            "cover": .object(["pattern": .string(pattern)]),
        ])
    }

    /// Karte in der gewaehlten Groesse, Mitte am Tippunkt, ganz auf der Seite (wenn `page` bekannt ist)
    public static func cover(id: String, centerX: Double, centerY: Double, choice: Choice = Choice(),
                             page: (width: Double, height: Double)? = nil) -> JSONValue {
        let s = sizes.first { $0.id == choice.size } ?? sizes[1]
        var x = centerX - s.width / 2, y = centerY - s.height / 2
        if let page, page.width.isFinite, page.height.isFinite {
            x = min(max(0, x), max(0, page.width - s.width))
            y = min(max(0, y), max(0, page.height - s.height))
        }
        return cover(id: id, x: x, y: y, width: s.width, height: s.height, choice: choice)
    }

    /// Farbe, Muster und Groesse der Karten mit diesen IDs aendern. Eine neue Groesse behaelt die linke obere Ecke.
    public static func restyling(_ objects: [JSONValue], ids: Set<String>, _ change: (inout Choice) -> Void) -> [JSONValue] {
        objects.map { o in
            guard let id = o["id"]?.string, ids.contains(id), isCover(o), var obj = o.object else { return o }
            let before = choice(o)
            var c = before
            change(&c)
            obj["fill"] = .string(c.color)
            obj["cover"] = .object(["pattern": .string(patterns.contains { $0.id == c.pattern } ? c.pattern : "plain")])
            if c.size != before.size, let s = sizes.first(where: { $0.id == c.size }) {
                obj["width"] = .number(s.width)
                obj["height"] = .number(s.height)
            }
            return .object(obj)
        }
    }

    /// Reihenfolge fuer Anzeige und Export: Karten zuletzt (ueber allem), sonst die gespeicherte Reihenfolge
    public static func coversLast(_ objects: [JSONValue]) -> [JSONValue] {
        guard objects.contains(where: isCover) else { return objects }
        return objects.filter { !isCover($0) } + objects.filter(isCover)
    }

    /// Oberste Karte unter einem Punkt (Seitenpunkte), ohne Spielraum
    public static func hit(_ objects: [JSONValue], x: Double, y: Double) -> String? {
        for o in objects.reversed() where isCover(o) {
            guard let id = o["id"]?.string, let b = PageObjectEdit.bounds(o, textHeight: { _ in 0 }) else { continue }
            if x >= b.minX, x <= b.maxX, y >= b.minY, y <= b.maxY { return id }
        }
        return nil
    }
}
