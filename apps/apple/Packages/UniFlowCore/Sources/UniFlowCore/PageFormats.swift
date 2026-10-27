import Foundation

/// Seitenformate eigener Notizseiten in PDF-Punkten (1 pt = 1/72 Zoll) wie app/static/formats.js: A6 ... A2 hoch und
/// quer, dazu Whiteboards (immer quer) bis A0. Eine Notizseite traegt ihr Format nur als `w`/`h` im
/// `pageOrder`-Eintrag; Objekte und Striche behalten ihre Lage in Punkten. Der Server (app/server.py `PAGE_MIN_PT`,
/// `PAGE_MAX_PT`, lokal `LibraryEndpoints.pageMinPT`) prueft dieselben Grenzen.
public enum PageFormats {
    public struct Format: Sendable, Equatable {
        /// Schluessel wie in formats.js ("a4", "wb_a0")
        public let key: String
        public let name: String
        public let width: Int
        public let height: Int
        /// Hinweis zur Auswahl (nur "Riesig")
        public let hint: String?
    }

    public enum Orientation: String, Sendable, CaseIterable {
        case portrait, landscape
    }

    /// `FORMATS` (ISO 216 gerundet), Reihenfolge wie in formats.js
    public static let paper: [Format] = [
        Format(key: "a6", name: "A6", width: 298, height: 420, hint: nil),
        Format(key: "a5", name: "A5", width: 420, height: 595, hint: nil),
        Format(key: "a4", name: "A4", width: 595, height: 842, hint: nil),
        Format(key: "a3", name: "A3", width: 842, height: 1191, hint: nil),
        Format(key: "a2", name: "A2", width: 1191, height: 1684, hint: nil),
    ]

    /// `WHITEBOARDS` (quer, groesser)
    public static let whiteboards: [Format] = [
        Format(key: "wb_a4", name: "Klein (A4 quer)", width: 842, height: 595, hint: nil),
        Format(key: "wb_a3", name: "Mittel (A3 quer)", width: 1191, height: 842, hint: nil),
        Format(key: "wb_a1", name: "Groß (A1 quer)", width: 2384, height: 1684, hint: nil),
        Format(key: "wb_a0", name: "Riesig (A0 quer)", width: 3370, height: 2384,
               hint: "braucht viel Arbeitsspeicher, auf Tablets lieber „Groß“"),
    ]

    /// `MIN_SIDE`, `MAX_SIDE`
    public static let minSide = 100, maxSide = 3400

    /// Vorgaben wie im Web (Bibliothek: Notizbuch A4 hoch, Whiteboard "Mittel")
    public static let defaultNotebook = "a4", defaultWhiteboard = "wb_a3"

    /// `validSize(w, h)`: ganze Zahlen im Bereich `minSide`...`maxSide`
    public static func validSize(_ w: Double, _ h: Double) -> Bool {
        w.isFinite && h.isFinite && w.rounded() == w && h.rounded() == h
            && w >= Double(minSide) && h >= Double(minSide) && w <= Double(maxSide) && h <= Double(maxSide)
    }

    /// `formatSize(key, orientation)`: Breite/Hoehe eines Formats; Whiteboards sind immer quer, unbekannt nil
    public static func size(_ key: String, _ orientation: Orientation = .portrait) -> (width: Int, height: Int)? {
        if let f = paper.first(where: { $0.key == key }) {
            return orientation == .landscape ? (f.height, f.width) : (f.width, f.height)
        }
        return whiteboards.first { $0.key == key }.map { ($0.width, $0.height) }
    }

    /// `formatOf(w, h)`: Format und Ausrichtung zu einer Seitengroesse (+- 2 pt), sonst nil (PDF-Seite, eigenes Mass)
    public static func format(width w: Double, height h: Double) -> (key: String, orientation: Orientation, name: String)? {
        func near(_ a: Double, _ b: Int) -> Bool { abs(a - Double(b)) <= 2 }
        for f in paper {
            if near(w, f.width), near(h, f.height) { return (f.key, .portrait, f.name) }
            if near(w, f.height), near(h, f.width) { return (f.key, .landscape, f.name + " quer") }
        }
        for f in whiteboards where near(w, f.width) && near(h, f.height) { return (f.key, .landscape, f.name) }
        return nil
    }

    /// `sizeLabel(w, h)`: Name des Formats, sonst Breite x Hoehe in cm (gerundet wie `Math.round`)
    public static func label(width w: Double, height h: Double) -> String {
        if let f = format(width: w, height: h) { return f.name }
        func cm(_ v: Double) -> Int { Int((v / 72 * 2.54 + 0.5).rounded(.down)) }
        return "\(cm(w)) × \(cm(h)) cm"
    }
}
