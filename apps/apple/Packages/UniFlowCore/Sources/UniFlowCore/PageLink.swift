import Foundation

/// Verweise auf Dokument + Seite (Auftrag des Inhabers 25.11.2026: "Dokument + Seiten Link … wenn man ein Wort
/// anklickt oder einen Punkt … dann direkt die Seite daneben geöffnet wird, wenn nicht schon offen, und wenn offen,
/// wird automatisch auf die Seite geschickt, wo der Verweis hinzeigt").
///
/// Ein Verweis sitzt als Punkt an einer Stelle oder als Bereich ueber einem Wort (getippt oder geschrieben) und zeigt
/// auf eine genaue Stelle: Dokument, Seite, Punkt auf der Seite. Antippen oeffnet das Dokument daneben auf dieser
/// Seite bzw. springt dorthin; im selben Dokument blaettert er zur Seite.
///
/// Speicherformat: Objekt `type: "shape"`, `shape: "rect"` (blauer Rahmen, keine Fuellung) mit dem Zusatzfeld
/// `link: {file, title, page, pdfPage?, pageNumber, x, y}`. Kein neuer Objekttyp (aeltere Apps, Web, Community).
public enum PageLink {

    public struct Target: Hashable, Sendable {
        /// Datei-ID des Ziels (Bibliothek)
        public var file: String
        public var title: String
        /// Seitenschluessel im Ziel (`pageOrder`), dazu die PDF-Seite (1-basiert), falls es eine ist
        public var pageKey: String
        public var pdfPage: Int?
        /// Seitenzahl beim Anlegen (1-basiert, wie angezeigt) - fuer die Beschriftung und als Ersatz, wenn die Seite fehlt
        public var pageNumber: Int
        /// Stelle auf der Zielseite (Seitenpunkte)
        public var x: Double
        public var y: Double

        public init(file: String, title: String, pageKey: String, pdfPage: Int?, pageNumber: Int, x: Double, y: Double) {
            self.file = file; self.title = title; self.pageKey = pageKey; self.pdfPage = pdfPage
            self.pageNumber = pageNumber; self.x = x; self.y = y
        }

        /// "Skript Kapitel 3, Seite 12"
        public var label: String {
            let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
            return (t.isEmpty ? "Dokument" : t) + ", Seite \(max(1, pageNumber))"
        }

        var json: JSONValue {
            var o: [String: JSONValue] = [
                "file": .string(file), "title": .string(title), "page": .string(pageKey), "pageNumber": .number(Double(pageNumber)),
                "x": .number(PageObjectEdit.r2(x)), "y": .number(PageObjectEdit.r2(y)),
            ]
            if let pdfPage { o["pdfPage"] = .number(Double(pdfPage)) }
            return .object(o)
        }
    }

    public static let color = "#2f7fd1"
    /// Kantenlaenge des Punkts (Seitenpunkte)
    public static let pointSide = 22.0
    public static let minimum = (width: 14.0, height: 12.0)
    static let titleLimit = 200

    public static func isLink(_ o: JSONValue) -> Bool {
        o["type"]?.string == "shape" && target(o) != nil
    }

    /// Ziel des Verweises; nil, wenn das Feld fehlt oder unbrauchbar ist (kein Dokument, keine endliche Stelle)
    public static func target(_ o: JSONValue) -> Target? {
        guard o["type"]?.string == "shape", let l = o["link"], l.object != nil, let file = l["file"]?.string, !file.isEmpty,
              file.utf8.count <= 200 else { return nil }
        let x = l["x"]?.double ?? 0, y = l["y"]?.double ?? 0
        guard x.isFinite, y.isFinite else { return nil }
        let limit = 100_000.0
        return Target(file: file, title: String((l["title"]?.string ?? "").prefix(titleLimit)), pageKey: l["page"]?.string ?? "",
                      pdfPage: l["pdfPage"]?.int.flatMap { $0 >= 1 ? $0 : nil }, pageNumber: max(1, l["pageNumber"]?.int ?? 1),
                      x: min(limit, max(-limit, x)), y: min(limit, max(-limit, y)))
    }

    /// Punkt-Verweis (klein, rund gezeichnet) oder Bereich ueber einem Wort?
    public static func isPoint(_ o: JSONValue) -> Bool { o["link"]?["shape"]?.string != "area" }

    private static func make(id: String, x: Double, y: Double, width: Double, height: Double, area: Bool, target: Target) -> JSONValue {
        let r2 = PageObjectEdit.r2
        var link = target.json.object ?? [:]
        link["title"] = .string(String(target.title.prefix(titleLimit)))
        link["shape"] = area ? "area" : "point"
        return .object([
            "id": .string(id), "type": "shape", "shape": "rect",
            "x": .number(r2(x)), "y": .number(r2(y)), "width": .number(r2(width)), "height": .number(r2(height)),
            "fill": "", "stroke": .string(color), "strokeWidth": 1, "opacity": 1, "rotation": 0, "scaleX": 1, "scaleY": 1,
            "source": "ipad", "link": .object(link),
        ])
    }

    /// Verweis als Punkt, Mitte bei (x, y)
    public static func point(id: String, x: Double, y: Double, target: Target) -> JSONValue {
        make(id: id, x: x - pointSide / 2, y: y - pointSide / 2, width: pointSide, height: pointSide, area: false, target: target)
    }

    /// Verweis als Bereich ueber einem Wort oder einer Stelle
    public static func area(id: String, x: Double, y: Double, width: Double, height: Double, target: Target) -> JSONValue {
        make(id: id, x: x, y: y, width: max(minimum.width, width), height: max(minimum.height, height), area: true, target: target)
    }

    /// Ziel eines vorhandenen Verweises aendern
    public static func retargeting(_ objects: [JSONValue], id: String, to target: Target) -> [JSONValue] {
        objects.map { o in
            guard o["id"]?.string == id, isLink(o), var obj = o.object else { return o }
            var link = target.json.object ?? [:]
            link["shape"] = o["link"]?["shape"] ?? "point"
            obj["link"] = .object(link)
            return .object(obj)
        }
    }
}

/// Objekte der Schicht UEBER der Handschrift: Klappkarten und Verweise. Sie nehmen das Antippen an (aufklappen bzw.
/// dem Verweis folgen) und werden zuletzt gezeichnet.
public enum TopObjects {
    public static func isTop(_ o: JSONValue) -> Bool { FlipCover.isCover(o) || PageLink.isLink(o) }

    /// Reihenfolge fuer Anzeige und Export: diese Objekte zuletzt, sonst die gespeicherte Reihenfolge
    public static func last(_ objects: [JSONValue]) -> [JSONValue] {
        guard objects.contains(where: isTop) else { return objects }
        return objects.filter { !isTop($0) } + objects.filter(isTop)
    }

    /// Oberstes dieser Objekte unter einem Punkt (Seitenpunkte). Verweise mit etwas Spielraum (sie sind klein), Karten
    /// ohne.
    public static func hit(_ objects: [JSONValue], x: Double, y: Double) -> JSONValue? {
        for o in objects.reversed() where isTop(o) {
            guard let b = PageObjectEdit.bounds(o, textHeight: { _ in 0 }) else { continue }
            let slop = PageLink.isLink(o) ? 5.0 : 0
            if x >= b.minX - slop, x <= b.maxX + slop, y >= b.minY - slop, y <= b.maxY + slop { return o }
        }
        return nil
    }
}
