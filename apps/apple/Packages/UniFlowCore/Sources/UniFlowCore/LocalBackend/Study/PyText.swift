import Foundation

/// Regulaerer Ausdruck mit der Bedeutung von Pythons `re` fuer Text-Muster, in Python-Schreibweise geschrieben.
///
/// NSRegularExpression (ICU) weicht sonst in Kleinigkeiten ab, die bei Datei- und Kursnamen vorkommen koennen:
/// - `\w` und `\b`: Python zaehlt Buchstaben, Ziffern und "_" (`[\p{L}\p{N}_]`), ICU auch kombinierende Zeichen
///   (Dateinamen vom Mac sind oft zerlegt: "U" + U+0308). Beide werden darum ersetzt.
/// - `\s`: Python kennt auch \v, U+001C–U+001F und U+0085 (`str.isspace`).
/// - `.` und `$`: Zeilenende ist nur "\n" (`useUnixLineSeparators`), `$` passt am Ende oder vor einem letzten "\n".
/// - Gross-/Kleinschreibung (`re.I`): ICU faltet voll ("ß" passt auf "ss", "st" auf die Ligatur "ﬆ"), kennt aber
///   "İ" und "ı" nicht als "i". Python vergleicht Zeichen fuer Zeichen den Kleinbuchstaben (`_sre.unicode_tolower`)
///   und kennt wenige Sonderfaelle (`sre_compile._equivalences`: i/ı, s/ſ). Darum laeuft ICU ohne
///   `caseInsensitive`, und jeder Buchstabe des Musters wird zu einer Zeichenklasse mit genau den Zeichen, die
///   Python gelten laesst (`caseVariants`).
/// Gilt fuer die Muster dieser Datei-Gruppe (kein `\b`/`\w`/`\s` innerhalb von Zeichenklassen, kein `\\`; mit
/// `ignoreCase` keine Buchstaben in Zeichenklassen und keine Schalter wie `(?i)`).
public struct PyRegex: @unchecked Sendable {
    /// NSRegularExpression ist unveraenderlich und threadsicher (Apple-Dokumentation)
    let regex: NSRegularExpression

    static let word = #"[\p{L}\p{N}_]"#
    static let space = #"[\t\n\x{0B}\f\r\x{1C}-\x{1F}\x{20}\x{85}\x{A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}]"#
    static let boundary = "(?:(?<=\(word))(?!\(word))|(?<!\(word))(?=\(word)))"

    /// Zeichen, auf die ein Buchstabe des Musters mit `re.I` passt (Python 3.13, je Kleinbuchstabe; geprueft gegen
    /// `ignorecase` in study-modules.json). Nur die Buchstaben, die in den Mustern vorkommen koennen.
    static let caseVariants: [Unicode.Scalar: String] = {
        var v: [Unicode.Scalar: String] = [:]
        for c in "abcdefghijklmnopqrstuvwxyz".unicodeScalars { v[c] = String(c) + String(c).uppercased() }
        v["i"]! += "\u{130}\u{131}"                     // İ (Kleinbuchstabe i) und ı (_equivalences)
        v["k"]! += "\u{212A}"                           // Kelvin-Zeichen
        v["s"]! += "\u{17F}"                            // langes s (_equivalences)
        v["ä"] = "äÄ"
        v["ö"] = "öÖ"
        v["ü"] = "üÜ"
        v["ß"] = "ß\u{1E9E}"                            // ẞ, aber nie "ss"
        return v
    }()

    /// Muster in Python-Schreibweise; `ignoreCase` wie `re.I`
    public init(_ pattern: String, ignoreCase: Bool = false) {
        let p = (ignoreCase ? PyRegex.caseless(pattern) : pattern)
            .replacingOccurrences(of: #"\b"#, with: PyRegex.boundary)
            .replacingOccurrences(of: #"\w"#, with: PyRegex.word)
            .replacingOccurrences(of: #"\s"#, with: PyRegex.space)
        do {
            regex = try NSRegularExpression(pattern: p, options: [.useUnixLineSeparators])
        } catch {
            preconditionFailure("Ungueltiges Muster \(pattern): \(error)")
        }
    }

    /// Muster fuer `re.I`: jeder Buchstabe ausserhalb von Escapes und Zeichenklassen wird `[…]` aus `caseVariants`.
    /// Ein Buchstabe ohne Eintrag dort bricht ab (Muster erweitern heisst Tabelle erweitern).
    static func caseless(_ pattern: String) -> String {
        let u = Array(pattern.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        func copy() { out.append(u[i]); i += 1 }
        while i < u.count {
            let c = u[i]
            switch c {
            case "\\":
                copy()
                if i < u.count { copy() }
                if i < u.count, u[i] == "{" {                    // \x{0B}, \p{L}
                    while i < u.count, u[i] != "}" { copy() }
                    if i < u.count { copy() }
                }
            case "[":
                copy()
                while i < u.count, u[i] != "]" {
                    precondition(!u[i].properties.isCased, "Buchstabe in Zeichenklasse mit ignoreCase: \(pattern)")
                    if u[i] == "\\" { copy() }
                    if i < u.count { copy() }
                }
                if i < u.count { copy() }
            case "(" where i + 1 < u.count && u[i + 1] == "?":
                copy(); copy()
                precondition(i < u.count && ":=!<".unicodeScalars.contains(u[i]), "Schalter im Muster mit ignoreCase: \(pattern)")
                if u[i] == "<" { copy() }
                if i < u.count { copy() }
            default:
                guard c.properties.isCased else { copy(); continue }
                let lower = c.properties.lowercaseMapping.unicodeScalars
                guard lower.count == 1, let variants = caseVariants[lower.first!] else {
                    preconditionFailure("Buchstabe \(c) fehlt in PyRegex.caseVariants: \(pattern)")
                }
                out.append("[")
                out.append(contentsOf: variants.unicodeScalars)
                out.append("]")
                i += 1
            }
        }
        return String(out)
    }

    private static func range(_ s: String) -> NSRange { NSRange(s.startIndex..<s.endIndex, in: s) }

    /// `re.search(p, s)`: erster Treffer irgendwo
    public func search(_ s: String) -> PyMatch? {
        regex.firstMatch(in: s, options: [], range: Self.range(s)).map { PyMatch(result: $0, text: s) }
    }

    /// `bool(re.search(p, s))`
    public func found(in s: String) -> Bool { search(s) != nil }

    /// `re.match(p, s)`: Treffer nur am Anfang
    public func match(_ s: String) -> PyMatch? {
        regex.firstMatch(in: s, options: [.anchored], range: Self.range(s)).map { PyMatch(result: $0, text: s) }
    }

    /// `re.sub(p, repl, s)` mit festem Ersatztext (alle Treffer)
    public func sub(_ s: String, _ replacement: String = "") -> String {
        regex.stringByReplacingMatches(in: s, options: [], range: Self.range(s),
                                       withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }

    /// `re.findall(p, s)` fuer Muster ohne Gruppe
    public func findAll(_ s: String) -> [String] {
        regex.matches(in: s, options: [], range: Self.range(s)).compactMap { m in Range(m.range, in: s).map { String(s[$0]) } }
    }
}

/// Ein Treffer von `PyRegex`
public struct PyMatch {
    let result: NSTextCheckingResult
    let text: String

    /// `m.group(i)`; nil, wenn die Gruppe nicht beteiligt war
    public func group(_ i: Int = 0) -> String? {
        let r = result.range(at: i)
        guard r.location != NSNotFound, let range = Range(r, in: text) else { return nil }
        return String(text[range])
    }
}

/// Zeichenketten wie Python (`str` arbeitet mit Codepunkten, Swift mit Graphemen).
public enum PyText {
    /// `str.isspace()` je Codepunkt
    static func isSpace(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: return true
        default: return false
        }
    }

    private static func strip(_ s: String, where drop: (Unicode.Scalar) -> Bool) -> String {
        let u = Array(s.unicodeScalars)
        var lo = 0, hi = u.count
        while lo < hi, drop(u[lo]) { lo += 1 }
        while hi > lo, drop(u[hi - 1]) { hi -= 1 }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: u[lo..<hi])
        return String(out)
    }

    /// `s.strip()`
    public static func strip(_ s: String) -> String { strip(s, where: isSpace) }

    /// `s.strip(chars)`
    public static func strip(_ s: String, chars: String) -> String {
        let set = Set(chars.unicodeScalars)
        return strip(s, where: { set.contains($0) })
    }

    /// `s.lower()`: volle Kleinschreibung je Codepunkt (wie `str.lower`, ohne Normalisierung), "Σ" am Wortende wird
    /// "ς" (Final_Sigma wie Python: davor ein Buchstabe mit Gross-/Kleinschreibung, danach keiner, dazwischen nur
    /// Zeichen, die dafuer nicht zaehlen)
    public static func lower(_ s: String) -> String {
        let u = Array(s.unicodeScalars)
        var out = String.UnicodeScalarView()
        for (i, c) in u.enumerated() {
            if c.value == 0x3A3 {
                out.append(isFinalSigma(u, at: i) ? "\u{3C2}" : "\u{3C3}")
            } else {
                out.append(contentsOf: c.properties.lowercaseMapping.unicodeScalars)
            }
        }
        return String(out)
    }

    /// `handle_capital_sigma` in CPython (unicodeobject.c)
    private static func isFinalSigma(_ u: [Unicode.Scalar], at i: Int) -> Bool {
        var j = i - 1
        while j >= 0, u[j].properties.isCaseIgnorable { j -= 1 }
        guard j >= 0, u[j].properties.isCased else { return false }
        j = i + 1
        while j < u.count, u[j].properties.isCaseIgnorable { j += 1 }
        return j == u.count || !u[j].properties.isCased
    }

    /// `s.split(sep)` mit einem Trennzeichen
    public static func split(_ s: String, _ sep: Unicode.Scalar) -> [String] {
        s.unicodeScalars.split(separator: sep, omittingEmptySubsequences: false).map { slice in
            var v = String.UnicodeScalarView()
            v.append(contentsOf: slice)
            return String(v)
        }
    }

    /// `needle in hay` (Teilfolge von Codepunkten)
    public static func contains(_ hay: String, _ needle: String) -> Bool {
        find(Array(hay.unicodeScalars), Array(needle.unicodeScalars)) != nil
    }

    /// `hay.find(needle)` nach Codepunkten; nil statt -1
    static func find(_ hay: [Unicode.Scalar], _ needle: [Unicode.Scalar]) -> Int? {
        if needle.isEmpty { return 0 }
        guard needle.count <= hay.count else { return nil }
        for i in 0...(hay.count - needle.count) where hay[i] == needle[0] {
            if hay[i..<(i + needle.count)].elementsEqual(needle) { return i }
        }
        return nil
    }

    /// `s[from:to]` nach Codepunkten wie Pythons Slicing (nicht negative Grenzen, zu grosse werden gekappt)
    static func slice(_ s: String, _ from: Int, _ to: Int) -> String {
        let u = Array(s.unicodeScalars)
        let lo = min(max(0, from), u.count), hi = min(max(lo, to), u.count)
        var out = String.UnicodeScalarView()
        out.append(contentsOf: u[lo..<hi])
        return String(out)
    }

    /// `a < b` fuer `str`: Codepunkte der Reihe nach (Swift vergleicht kanonisch aequivalent)
    public static func less(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars) { $0.value < $1.value }
    }

    /// `len(s)`
    public static func length(_ s: String) -> Int { s.unicodeScalars.count }

    /// `int(digits)` fuer Treffer von `\d+` (auch andere Unicode-Ziffern wie in Python)
    public static func int(digits s: String) -> Int? {
        var n = 0
        for u in s.unicodeScalars {
            guard u.properties.numericType == .decimal, let v = u.properties.numericValue else { return nil }
            n = n * 10 + Int(v)
        }
        return s.unicodeScalars.isEmpty ? nil : n
    }

    /// `str(v)` eines Werts aus `json.loads`
    public static func str(_ v: PyJSON) -> String {
        if case .string(let s) = v { return s }
        return repr(v)
    }

    /// `repr(v)` eines Werts aus `json.loads` (Listen und Objekte wie Python sie ausgibt)
    public static func repr(_ v: PyJSON) -> String {
        switch v {
        case .null: return "None"
        case .bool(let b): return b ? "True" : "False"
        case .int(let digits): return digits
        case .float(let d):
            if d.isNaN { return "nan" }
            if d.isInfinite { return d < 0 ? "-inf" : "inf" }
            return PyJSON.repr(d)
        case .string(let s): return reprString(s)
        case .array(let a): return "[" + a.map(repr).joined(separator: ", ") + "]"
        case .object(let m): return "{" + m.map { reprString($0.key) + ": " + repr($0.value) }.joined(separator: ", ") + "}"
        }
    }

    /// `repr(str)`: einfache Anfuehrungszeichen, doppelte nur, wenn der Text ' enthaelt und " nicht
    static func reprString(_ s: String) -> String {
        let quote: Character = s.contains("'") && !s.contains("\"") ? "\"" : "'"
        var out = String(quote)
        for u in s.unicodeScalars {
            switch u {
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if Character(u) == quote {
                    out += "\\" + String(quote)
                } else if u.value < 0x20 || u.value == 0x7F || (0x80..<0xA0).contains(u.value) {
                    out += "\\x" + hex(u.value, 2)
                } else if !isPrintable(u) {
                    out += u.value <= 0xFFFF ? "\\u" + hex(u.value, 4) : "\\U" + hex(u.value, 8)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        out.append(quote)
        return out
    }

    /// `str.isprintable()` je Codepunkt (ohne Steuer-, Format-, Trenn- und nicht zugewiesene Zeichen; Leerzeichen ja)
    private static func isPrintable(_ u: Unicode.Scalar) -> Bool {
        if u == " " { return true }
        switch u.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator, .spaceSeparator: return false
        default: return true
        }
    }

    private static func hex(_ v: UInt32, _ width: Int) -> String {
        let s = String(v, radix: 16)
        return String(repeating: "0", count: max(0, width - s.count)) + s
    }
}

/// Rechnen wie Python, wo das Ergebnis bitgenau gleich sein muss
enum PyMath {
    /// `sum(values)` fuer Gleitkommazahlen wie CPython ab 3.12 (bltinmodule.c): kompensierte Summe nach Neumaier in
    /// der gegebenen Reihenfolge, der Ausgleich kommt am Ende dazu, wenn er endlich und nicht 0 ist
    static func sum(_ values: [Double]) -> Double {
        var total = 0.0, c = 0.0
        for x in values {
            let t = total + x
            if abs(total) >= abs(x) { c += (total - t) + x } else { c += (x - t) + total }
            total = t
        }
        if c != 0, c.isFinite { total += c }
        return total
    }
}
