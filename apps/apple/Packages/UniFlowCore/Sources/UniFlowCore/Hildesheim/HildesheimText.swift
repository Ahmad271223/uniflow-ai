import Foundation

/// Kleine Text-Helfer fuer die Parser (Hildesheim, Kalenderdateien im Stundenplan-Import): dieselben regulaeren
/// Ausdruecke wie in Python, mit ICU statt `re`. Wo es auf Pythons Bedeutung von `\b`, `\w`, `\s` und re.I ankommt
/// (Titel, Dateinamen), gilt `PyRegex`.
enum HText {
    static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // Muster sind fest im Code; ein Fehler ist ein Programmierfehler
        try! NSRegularExpression(pattern: pattern, options: options)  // swiftlint:disable:this force_try
    }

    /// Erster Treffer mit allen Gruppen (fehlende Gruppen = nil) und dem Bereich des Treffers.
    static func match(_ re: NSRegularExpression, _ s: String) -> (groups: [String?], range: Range<String.Index>)? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              let whole = Range(m.range, in: s) else { return nil }
        var groups: [String?] = []
        for i in 0..<m.numberOfRanges {
            let r = m.range(at: i)
            groups.append(r.location == NSNotFound ? nil : ns.substring(with: r))
        }
        return (groups, whole)
    }

    static func allMatches(_ re: NSRegularExpression, _ s: String, group: Int = 1) -> [String] {
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let r = m.range(at: group)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }

    static func replace(_ re: NSRegularExpression, in s: String, with template: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: template)
    }

    /// `re.sub(r"\s+", " ", s).strip()` mit Pythons Leerraum (`PyRegex`, `PyText.strip`)
    static func collapse(_ s: String) -> String { PyText.strip(whitespace.sub(s, " ")) }

    private static let whitespace = PyRegex(#"\s+"#)

    /// NFC-Normalform (Dateinamen aus Moodle kommen teils zerlegt: "u" + U+0308)
    static func nfc(_ s: String) -> String { s.precomposedStringWithCanonicalMapping }

    /// Python `urllib.parse.quote(s, safe="")`: alles ausser A-Z a-z 0-9 _ . - ~ prozentkodiert (UTF-8).
    static func quoteAll(_ s: String) -> String {
        var out = ""
        for b in s.utf8 {
            switch b {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x5F, 0x2E, 0x2D, 0x7E: out.append(Character(UnicodeScalar(b)))
            default: out += String(format: "%%%02X", b)
            }
        }
        return out
    }

    static func sha256Hex(_ s: String) -> String { SolutionSHA256.hex(Data(s.utf8)) }

    /// Python `urllib.parse.unquote`: gueltige %XX-Folgen dekodieren, alles andere bleibt; ungueltiges UTF-8 wird
    /// U+FFFD (nie ein Absturz bei kaputten Adressen).
    static func unquote(_ s: String) -> String {
        guard s.contains("%") else { return s }
        func hex(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: return c - 0x30
            case 0x41...0x46: return c - 0x41 + 10
            case 0x61...0x66: return c - 0x61 + 10
            default: return nil
            }
        }
        let b = Array(s.utf8)
        var out: [UInt8] = []
        var i = 0
        while i < b.count {
            if b[i] == 0x25, i + 2 < b.count, let h = hex(b[i + 1]), let l = hex(b[i + 2]) {
                out.append(h << 4 | l)
                i += 3
            } else {
                out.append(b[i])
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Pfad wie `urllib.parse.urlparse(url).path` (prozentkodiert, ohne Abfrage und Anker); auch fuer Adressen, die
    /// `URLComponents` ablehnt (Leerzeichen, kaputte Prozent-Folgen).
    static func urlPath(_ url: String) -> String {
        var s = Substring(url)
        if let r = s.range(of: "://") {
            s = s[r.upperBound...]
            guard let slash = s.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) else { return "" }
            s = s[slash...]
        }
        if let cut = s.firstIndex(where: { $0 == "?" || $0 == "#" }) { s = s[..<cut] }
        return String(s)
    }

    /// Adresse ohne Abfrage und Anker fuer Meldungen: kein sesskey, keine Kennungen aus der Abfrage
    static func withoutQuery(_ address: String) -> String {
        let noQuery = address.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? address
        return noQuery.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? noQuery
    }

    /// `application/x-www-form-urlencoded` wie `urllib.parse.urlencode` (quote_plus: Leerzeichen als "+"), Reihenfolge
    /// wie uebergeben
    static func form(_ pairs: [(String, String)]) -> Data {
        func enc(_ s: String) -> String {
            var out = ""
            for byte in s.utf8 {
                switch byte {
                case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x5F, 0x2E, 0x2D, 0x7E: out.append(Character(Unicode.Scalar(byte)))
                case 0x20: out.append("+")
                default: out += String(format: "%%%02X", byte)
                }
            }
            return out
        }
        return Data(pairs.map { "\(enc($0.0))=\(enc($0.1))" }.joined(separator: "&").utf8)
    }
}
