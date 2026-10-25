import Foundation

/// Kleine Text-Helfer fuer die Hildesheim-Parser: dieselben regulaeren Ausdruecke wie in Python (ICU statt `re`).
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

    /// `re.sub(r"\s+", " ", s).strip()`
    static func collapse(_ s: String) -> String {
        replace(whitespace, in: s, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let whitespace = regex("\\s+")

    /// Python `str.strip(chars)`: entfernt die Zeichen aus `chars` an beiden Enden.
    static func strip(_ s: String, _ chars: String) -> String {
        let set = Set(chars)
        var sub = Substring(s)
        while let f = sub.first, set.contains(f) { sub = sub.dropFirst() }
        while let l = sub.last, set.contains(l) { sub = sub.dropLast() }
        return String(sub)
    }

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
}
