import Foundation

// Modulkatalog (docs/STUDIENVERLAUF-2026-11-04.md): Textbausteine wie app/study_catalog.py - Zeilen-Normalisierung des
// PDF-Texts (PDFKit hier, pypdf am PC: dieselben Zeilen), ids aus Titeln, Semester, Bibliotheksschluessel. Gleiche
// Faelle in packages/shared-contracts/fixtures/study-catalog/text-cases.json und registry-cases.json.

public enum StudyCatalogText {
    /// Zeichen, die als Zeilenumbruch gelten (wie `BREAKS` in Python), und Zeichen, die wegfallen (`DROP`)
    static let breaks: Set<UInt32> = [0x0D, 0x2028, 0x2029, 0x0B, 0x0C, 0x1C, 0x1D, 0x1E, 0x85, 0x0A]
    static let drops: Set<UInt32> = [0x00AD, 0x200B, 0x200C, 0x200D, 0xFEFF]

    /// Text einer Seite -> nichtleere Zeilen: NFKC, jeder Zeilenumbruch gleich, Tabulator zu Leerzeichen,
    /// Leerzeichenfolgen zu einem, Raender weg (`normalize_lines`)
    public static func normalizeLines(_ text: String) -> [String] {
        let nfkc = text.precomposedStringWithCompatibilityMapping
        var lines: [String] = []
        var current = String.UnicodeScalarView()
        var lastSpace = false
        func flush() {
            var s = String(current)
            while s.hasSuffix(" ") { s.removeLast() }
            if !s.isEmpty { lines.append(s) }
            current = String.UnicodeScalarView()
            lastSpace = false
        }
        for u in nfkc.unicodeScalars {
            let v = u.value
            if breaks.contains(v) { flush(); continue }
            if drops.contains(v) { continue }
            let scalar: Unicode.Scalar = v == 0x09 ? " " : u
            if scalar == " " {
                // Rand vorne weg, Folgen zu einem Leerzeichen
                if current.isEmpty || lastSpace { continue }
                lastSpace = true
            } else {
                lastSpace = false
            }
            current.append(scalar)
        }
        flush()
        return lines
    }

    // MARK: Namen

    static let roman: [String: String] = ["i": "1", "ii": "2", "iii": "3", "iv": "4", "v": "5", "vi": "6", "vii": "7",
                                          "viii": "8", "ix": "9", "x": "10"]

    /// klein, Umlaute ausgeschrieben, Akzente weg (`_fold`)
    static func fold(_ text: String) -> String {
        var s = text.lowercased()
        for (k, v) in [("ä", "ae"), ("ö", "oe"), ("ü", "ue"), ("ß", "ss")] { s = s.replacingOccurrences(of: k, with: v) }
        let decomposed = s.decomposedStringWithCompatibilityMapping
        var out = String.UnicodeScalarView()
        for u in decomposed.unicodeScalars where u.properties.generalCategory != .nonspacingMark { out.append(u) }
        return String(out)
    }

    /// Folgen aus a-z und 0-9 (`TOKEN_RE`)
    static func tokens(_ folded: String) -> [String] {
        var out: [String] = []
        var cur = ""
        for u in folded.unicodeScalars {
            if (u.value >= 0x61 && u.value <= 0x7A) || (u.value >= 0x30 && u.value <= 0x39) {
                cur.unicodeScalars.append(u)
            } else if !cur.isEmpty {
                out.append(cur)
                cur = ""
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// "Programmieren I" -> "programmieren-1"
    public static func slug(_ text: String) -> String {
        let t = tokens(fold(text)).map { roman[$0] ?? $0 }
        return t.isEmpty ? "modul" : t.joined(separator: "-")
    }

    /// Vergleichsform eines Studiengangsnamens (`name_key`)
    public static func nameKey(_ text: String) -> String { tokens(fold(text)).joined() }

    // MARK: Semester

    /// "WS 2025/26" -> 2025*2+1, "SS 2026" -> 2026*2
    public static func termNumber(_ term: String?) -> Int? {
        guard let term else { return nil }
        if let m = CatalogRx.match("^WS ([0-9]{4})/([0-9]{2})$", term), let y = Int(m[1] ?? "") { return y * 2 + 1 }
        if let m = CatalogRx.match("^SS ([0-9]{4})$", term), let y = Int(m[1] ?? "") { return y * 2 }
        return nil
    }

    static func winter(_ y: Int) -> String { "WS \(y)/" + String(format: "%02d", (y + 1) % 100) }

    /// "WS 2025/26" -> "WS_2025_26" (Dateiname der modkat-PDF)
    public static func termSlug(_ term: String) -> String {
        term.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "/", with: "_")
    }

    /// "im Wintersemester 2025/2026" -> "WS 2025/26"
    public static func termFromTitle(_ text: String) -> String? {
        guard let m = CatalogRx.search("(Wintersemester|Sommersemester) ([0-9]{4})(?:/([0-9]{4}))?", text), let y = Int(m[2] ?? "") else { return nil }
        return m[1] == "Wintersemester" ? winter(y) : "SS \(y)"
    }

    /// Laufendes Semester zum Tag "YYYY-MM-DD": Oktober bis Maerz WS, April bis September SS
    public static func currentTerm(today: String) -> String {
        let y = Int(today.prefix(4)) ?? 2026
        let mo = Int(today.dropFirst(5).prefix(2)) ?? 1
        if mo >= 10 { return winter(y) }
        if mo <= 3 { return winter(y - 1) }
        return "SS \(y)"
    }

    /// Bibliotheksschluessel sha256("luh|TIBSc22|WS 2025/26")
    public static func libraryKey(university: String, code: String, term: String) -> String {
        SolutionSHA256.hex(Data("\(university)|\(code)|\(term)".utf8))
    }

    // MARK: Hilfen wie Python

    /// Laenge in Codepunkten (wie `len` in Python)
    static func length(_ s: String) -> Int { s.unicodeScalars.count }

    /// Die ersten n Codepunkte (wie `s[:n]`)
    static func prefix(_ s: String, _ n: Int) -> String {
        length(s) <= n ? s : String(String.UnicodeScalarView(s.unicodeScalars.prefix(n)))
    }

    /// `str.strip(chars)`
    static func strip(_ s: String, _ chars: String = " ") -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: chars))
    }
}

/// Kleine Huelle um NSRegularExpression mit Pythons Bedeutung von `re.match` (am Anfang) und `re.search`; Gruppen als
/// Texte (nil = Gruppe nicht beteiligt), Index 0 = ganzer Treffer.
enum CatalogRx {
    private static let cache = NSCache<NSString, NSRegularExpression>()

    static func regex(_ pattern: String, ignoreCase: Bool = false) -> NSRegularExpression {
        let key = ((ignoreCase ? "i:" : "c:") + pattern) as NSString
        if let r = cache.object(forKey: key) { return r }
        // swiftlint:disable:next force_try
        let r = try! NSRegularExpression(pattern: pattern, options: ignoreCase ? [.caseInsensitive] : [])
        cache.setObject(r, forKey: key)
        return r
    }

    private static func groups(_ m: NSTextCheckingResult, in s: String) -> [String?] {
        (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            guard r.location != NSNotFound, let range = Range(r, in: s) else { return nil }
            return String(s[range])
        }
    }

    /// `re.search`
    static func search(_ pattern: String, _ s: String, ignoreCase: Bool = false) -> [String?]? {
        let ns = s as NSString
        guard let m = regex(pattern, ignoreCase: ignoreCase).firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return groups(m, in: s)
    }

    /// `re.match` (Muster beginnen ohnehin mit ^)
    static func match(_ pattern: String, _ s: String, ignoreCase: Bool = false) -> [String?]? {
        let ns = s as NSString
        guard let m = regex(pattern, ignoreCase: ignoreCase).firstMatch(in: s, options: [.anchored], range: NSRange(location: 0, length: ns.length))
        else { return nil }
        return groups(m, in: s)
    }

    static func matches(_ pattern: String, _ s: String) -> Bool { match(pattern, s) != nil }

    /// `re.sub` (alle Treffer); Ersetzung woertlich
    static func sub(_ pattern: String, _ replacement: String, _ s: String, ignoreCase: Bool = false) -> String {
        let ns = s as NSString
        return regex(pattern, ignoreCase: ignoreCase).stringByReplacingMatches(
            in: s, range: NSRange(location: 0, length: ns.length), withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }
}
