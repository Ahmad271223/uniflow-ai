import Foundation

/// Notizzettel, die wie echte Klebezettel aussehen (Auftrag des Inhabers 25.11.2026: "bisschen coolere Notizzettel …
/// die sollen aussehen wie echte Notizzettel … mehrere coole Muster dazu und verschiedene Größen").
///
/// Speicherformat: ein Zettel bleibt die Haftnotiz des gemeinsamen Formats - Objekt `type: "text"` mit Hintergrund
/// `bg` (wie `createSticky` im Web) - mit zusaetzlichen Feldern:
/// - `note: {look, paper}` - Aussehen (Klebestreifen, Tesafilm, Pinnnadel, geknickte Ecke) und Papier (blanko,
///   liniert, kariert, gepunktet),
/// - `minHeight` - Mindesthoehe (Zettel sind etwa quadratisch, auch mit wenig Text),
/// - `block: 1` - der Text ist ein Textblock (`TextBlock`, formatierbar).
/// Aeltere Apps und das Web zeigen weiter das farbige Rechteck mit dem Text. Kein neuer Objekttyp (Community,
/// `SolutionValidator`).
public enum StickyNote {

    public struct Choice: Hashable, Sendable {
        public var color: String
        public var look: String
        public var paper: String
        public var size: String

        public init(color: String = StickyNote.colors[0].hex, look: String = "glue", paper: String = "plain", size: String = "m") {
            self.color = color; self.look = look; self.paper = paper; self.size = size
        }
    }

    /// Papierfarben (helle Toene echter Klebezettel)
    public static let colors: [(hex: String, title: String)] = [
        (PageObjectEdit.stickyColor, "Gelb"), ("#ffd3e0", "Rosa"), ("#d6f5c8", "Grün"), ("#cfe8ff", "Blau"),
        ("#ffe2b8", "Orange"), ("#e7dbff", "Lila"),
    ]
    /// Aussehen ("Muster" des Zettels)
    public static let looks: [(id: String, title: String)] = [
        ("glue", "Klebezettel"), ("tape", "Mit Klebestreifen"), ("pin", "Mit Pinnnadel"), ("fold", "Ecke geknickt"),
    ]
    /// Papier des Zettels
    public static let papers: [(id: String, title: String)] = [
        ("plain", "Blanko"), ("lined", "Liniert"), ("grid", "Kariert"), ("dots", "Gepunktet"),
    ]
    /// Groessen: Kantenlaenge in Seitenpunkten (Breite; Mindesthoehe = Breite) und Schriftgroesse
    public static let sizes: [(id: String, title: String, side: Double, fontSize: Double)] = [
        ("s", "Klein", 120, 13), ("m", "Mittel", 165, 15), ("l", "Groß", 230, 18),
    ]

    /// Zeilenabstand auf liniertem Zettelpapier, Rasterweite fuer kariert und gepunktet
    public static let lineStep = 22.0
    public static let gridStep = 11.0
    /// Innenabstand: oben mehr Platz (Klebestreifen, Tesafilm, Nadel)
    public static let padding = (top: 22.0, side: 12.0, bottom: 12.0)
    public static let font = "Noteworthy"

    public static func isNote(_ o: JSONValue) -> Bool {
        o["type"]?.string == "text" && o["note"]?.object != nil
    }

    /// Haftnotiz (auch die einfache gelbe aus 1.0.7): Text mit Hintergrund
    public static func isSticky(_ o: JSONValue) -> Bool {
        o["type"]?.string == "text" && !(o["bg"]?.string ?? "").isEmpty
    }

    public static func look(_ o: JSONValue) -> String {
        let v = o["note"]?["look"]?.string ?? ""
        return looks.contains { $0.id == v } ? v : "glue"
    }

    public static func paper(_ o: JSONValue) -> String {
        let v = o["note"]?["paper"]?.string ?? ""
        return papers.contains { $0.id == v } ? v : "plain"
    }

    /// Der Text sitzt auf den Linien des Zettels
    public static func isLined(_ o: JSONValue) -> Bool { isNote(o) && paper(o) == "lined" }

    /// Groesse, die zur Breite des Zettels passt (fuer die Anzeige in der Leiste), sonst die mittlere
    public static func size(_ o: JSONValue) -> String {
        let w = o["width"]?.double ?? 0
        return sizes.min { abs($0.side - w) < abs($1.side - w) }?.id ?? "m"
    }

    public static func choice(_ o: JSONValue) -> Choice {
        Choice(color: (o["bg"]?.string).flatMap { $0.isEmpty ? nil : $0 } ?? colors[0].hex, look: look(o), paper: paper(o), size: size(o))
    }

    private static func sizeEntry(_ id: String) -> (id: String, title: String, side: Double, fontSize: Double) {
        sizes.first { $0.id == id } ?? sizes[1]
    }

    /// Neuer Zettel: Mitte der Oberkante am Tippunkt (man "klebt" ihn hin), ganz auf der Seite, wenn `page` bekannt ist
    public static func note(id: String, x: Double, y: Double, choice: Choice = Choice(), text: String = "",
                            page: (width: Double, height: Double)? = nil) -> JSONValue {
        let s = sizeEntry(choice.size)
        var left = x - s.side / 2, top = y - 12
        if let page, page.width.isFinite, page.height.isFinite {
            left = min(max(0, left), max(0, page.width - s.side))
            top = min(max(0, top), max(0, page.height - s.side))
        }
        var o = PageObjectEdit.text(id: id, x: left, y: top, text: text).object ?? [:]
        o["block"] = 1
        // neue Zettel nur in den Papierfarben der Auswahl (eine gemerkte, unbekannte Farbe: Gelb)
        var c = choice
        if !colors.contains(where: { $0.hex == c.color }) { c.color = colors[0].hex }
        o["bg"] = .string(c.color)
        o["fontFamily"] = .string(font)
        o["fontSize"] = .number(s.fontSize)
        o["lineHeight"] = 1.25
        return styled(.object(o), c)
    }

    /// Aussehen, Papier, Farbe und Groesse eines Zettels setzen. Macht aus der einfachen gelben Haftnotiz einen Zettel.
    /// Die Groesse aendert Breite und Mindesthoehe; die Schriftgroesse bleibt, wie der Nutzer sie hat.
    public static func styled(_ o: JSONValue, _ choice: Choice) -> JSONValue {
        guard o["type"]?.string == "text", var obj = o.object else { return o }
        let s = sizeEntry(choice.size)
        let look = looks.contains { $0.id == choice.look } ? choice.look : "glue"
        let paper = papers.contains { $0.id == choice.paper } ? choice.paper : "plain"
        obj["note"] = .object(["look": .string(look), "paper": .string(paper)])
        if !choice.color.isEmpty { obj["bg"] = .string(choice.color) }
        obj["width"] = .number(s.side)
        obj["minHeight"] = .number(s.side)
        obj["block"] = 1
        // liniertes Zettelpapier: Zeilenabstand fuer aeltere Apps und das Web
        let fontSize = TextBlock.clampedSize(obj["fontSize"]?.double ?? s.fontSize)
        obj["lineHeight"] = paper == "lined" ? .number(((lineStep / fontSize) * 1000).rounded() / 1000) : 1.25
        return .object(obj)
    }

    /// Zettel mit diesen IDs umgestalten; `change` bekommt die jetzige Wahl. Objekte ohne Hintergrund (Textbloecke)
    /// bleiben, wie sie sind.
    public static func restyling(_ objects: [JSONValue], ids: Set<String>, _ change: (inout Choice) -> Void) -> [JSONValue] {
        objects.map { o in
            guard let id = o["id"]?.string, ids.contains(id), isSticky(o) else { return o }
            var c = choice(o)
            change(&c)
            return styled(o, c)
        }
    }

    /// Mindesthoehe (0 ohne), endlich und begrenzt
    public static func minHeight(_ o: JSONValue) -> Double {
        guard isNote(o), let h = o["minHeight"]?.double, h.isFinite else { return 0 }
        return min(2_000, max(0, h))
    }
}
