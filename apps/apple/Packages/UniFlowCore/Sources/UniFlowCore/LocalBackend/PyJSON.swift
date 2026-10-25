import Foundation

/// JSON so, wie Pythons `json.loads` es liefert: Schluessel in Reihenfolge, ganze Zahlen (`int`) getrennt von
/// gebrochenen (`float`). Gebraucht, wo app/server.py Werte als Text speichert (`db.set_setting`: `str(value)` bzw.
/// `json.dumps(value)`) – dort muss derselbe Text entstehen wie auf dem PC. `JSONValue` kennt weder Reihenfolge
/// noch den Unterschied zwischen 4 und 4.0.
public indirect enum PyJSON: Equatable, Sendable {
    case null
    case bool(Bool)
    /// Ziffern wie in der Eingabe (beliebig gross wie Pythons int), "-0" als "0"
    case int(String)
    case float(Double)
    case string(String)
    case array([PyJSON])
    case object([Member])

    public struct Member: Equatable, Sendable {
        public let key: String
        public var value: PyJSON
        public init(_ key: String, _ value: PyJSON) { self.key = key; self.value = value }
    }

    // MARK: Lesen

    /// Wie `json.loads` (dazu NaN/Infinity wie Python); doppelte Schluessel: letzter Wert an der ersten Stelle.
    public static func parse(_ data: Data) throws -> PyJSON {
        var p = Parser(bytes: [UInt8](data))
        p.skipWhitespace()
        let v = try p.value(depth: 0)
        p.skipWhitespace()
        guard p.index == p.bytes.count else { throw p.error("Unerwartete Zeichen nach dem Wert") }
        return v
    }

    public static func parse(_ text: String) throws -> PyJSON { try parse(Data(text.utf8)) }

    /// Fuer Antworten und Vergleiche: dieselben Werte als `JSONValue` (Reihenfolge und int/float gehen verloren).
    public var json: JSONValue {
        switch self {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .int(let s): return .number(Double(s) ?? 0)
        case .float(let d): return .number(d)
        case .string(let s): return .string(s)
        case .array(let a): return .array(a.map(\.json))
        case .object(let m):
            var o: [String: JSONValue] = [:]
            for e in m { o[e.key] = e.value.json }
            return .object(o)
        }
    }

    // MARK: Schreiben wie Python

    /// `json.dumps(value)` mit den Standardwerten: `ensure_ascii=True`, Trenner ", " und ": ".
    public var dumps: String { dumps(ensureASCII: true) }

    /// `json.dumps(value, ensure_ascii=...)`: mit `false` bleiben Zeichen ausserhalb von ASCII stehen (so speichert
    /// app/server.py die Notizen, `PUT /api/files/{id}/annotations`).
    public func dumps(ensureASCII: Bool) -> String {
        var out = ""
        write(into: &out, ascii: ensureASCII)
        return out
    }

    private func write(into out: inout String, ascii: Bool) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let s): out += s
        case .float(let d):
            // json.dumps schreibt nicht endliche Werte als NaN/Infinity (allow_nan=True)
            if d.isNaN { out += "NaN" } else if d.isInfinite { out += d < 0 ? "-Infinity" : "Infinity" } else { out += PyJSON.repr(d) }
        case .string(let s): PyJSON.writeString(s, ascii: ascii, into: &out)
        case .array(let a):
            out += "["
            for (i, v) in a.enumerated() {
                if i > 0 { out += ", " }
                v.write(into: &out, ascii: ascii)
            }
            out += "]"
        case .object(let m):
            out += "{"
            for (i, e) in m.enumerated() {
                if i > 0 { out += ", " }
                PyJSON.writeString(e.key, ascii: ascii, into: &out)
                out += ": "
                e.value.write(into: &out, ascii: ascii)
            }
            out += "}"
        }
    }

    static func writeString(_ s: String, ascii: Bool, into out: inout String) {
        if ascii { writeASCII(s, into: &out) } else { writeUnicode(s, into: &out) }
    }

    /// Zeichenkette wie `json.dumps(..., ensure_ascii=False)`: nur `"`, `\` und Steuerzeichen unter 0x20 werden
    /// maskiert (\n, \r, \t, \b, \f, sonst \u00XX), alles andere bleibt stehen (auch DEL und Zeichen ausserhalb der BMP).
    static func writeUnicode(_ s: String, into out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x00..<0x20:
                out += "\\u00"
                out.append(hex[Int(u.value >> 4)])
                out.append(hex[Int(u.value & 0xF)])
            default: out.unicodeScalars.append(u)
            }
        }
        out += "\""
    }

    /// `repr(float)`: kuerzeste exakte Darstellung; wissenschaftlich ab 1e16 und unter 1e-4 ("1e+16", "1.5e-07"),
    /// sonst mit ".0" bei ganzen Werten. Swift verwendet dieselben Regeln (Tests mit Python-Werten).
    public static func repr(_ d: Double) -> String {
        if d.isNaN { return "nan" }
        if d.isInfinite { return d < 0 ? "-inf" : "inf" }
        return d.description
    }

    private static let hex: [Character] = Array("0123456789abcdef")

    /// Zeichenkette wie `json.dumps(..., ensure_ascii=True)`: alles ausserhalb von ASCII als \uXXXX
    /// (Zeichen ausserhalb der BMP als Ersatzpaar), Steuerzeichen als \n, \r, \t, \b, \f oder \u00XX.
    static func writeASCII(_ s: String, into out: inout String) {
        out += "\""
        for u in s.utf16 {
            switch u {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x20..<0x7F: out.unicodeScalars.append(Unicode.Scalar(UInt8(u)))
            default:
                out += "\\u"
                for shift in stride(from: 12, through: 0, by: -4) { out.append(hex[Int((u >> UInt16(shift)) & 0xF)]) }
            }
        }
        out += "\""
    }

    // MARK: Parser

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        func error(_ reason: String) -> JSONParseError { JSONParseError(offset: index, reason: reason) }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[index]) { index += 1 }
        }

        mutating func value(depth: Int) throws -> PyJSON {
            guard depth < 512 else { throw error("Zu tief verschachtelt") }
            guard index < bytes.count else { throw error("Unerwartetes Ende") }
            switch bytes[index] {
            case 0x7B: return try object(depth: depth)
            case 0x5B: return try array(depth: depth)
            case 0x22: return .string(try string())
            case 0x74: try word("true"); return .bool(true)
            case 0x66: try word("false"); return .bool(false)
            case 0x6E: try word("null"); return .null
            case 0x4E: try word("NaN"); return .float(.nan)
            case 0x49: try word("Infinity"); return .float(.infinity)
            default: return try number()
            }
        }

        mutating func word(_ w: String) throws {
            let u = Array(w.utf8)
            guard index + u.count <= bytes.count, Array(bytes[index..<index + u.count]) == u else { throw error("Unbekanntes Wort") }
            index += u.count
        }

        mutating func object(depth: Int) throws -> PyJSON {
            index += 1
            var members: [Member] = []
            var position: [String: Int] = [:]
            skipWhitespace()
            if index < bytes.count, bytes[index] == 0x7D { index += 1; return .object(members) }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == 0x22 else { throw error("Schlüssel erwartet") }
                let key = try string()
                skipWhitespace()
                guard index < bytes.count, bytes[index] == 0x3A else { throw error("':' erwartet") }
                index += 1
                skipWhitespace()
                let v = try value(depth: depth + 1)
                if let p = position[key] { members[p].value = v } else {
                    position[key] = members.count
                    members.append(Member(key, v))
                }
                skipWhitespace()
                guard index < bytes.count else { throw error("Unerwartetes Ende im Objekt") }
                if bytes[index] == 0x2C { index += 1; continue }
                if bytes[index] == 0x7D { index += 1; return .object(members) }
                throw error("',' oder '}' erwartet")
            }
        }

        mutating func array(depth: Int) throws -> PyJSON {
            index += 1
            var items: [PyJSON] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == 0x5D { index += 1; return .array(items) }
            while true {
                skipWhitespace()
                items.append(try value(depth: depth + 1))
                skipWhitespace()
                guard index < bytes.count else { throw error("Unerwartetes Ende in der Liste") }
                if bytes[index] == 0x2C { index += 1; continue }
                if bytes[index] == 0x5D { index += 1; return .array(items) }
                throw error("',' oder ']' erwartet")
            }
        }

        /// Zahl nach JSON-Grammatik; mit "." oder Exponent ein float, sonst ein int (wie Python)
        mutating func number() throws -> PyJSON {
            let start = index
            if index < bytes.count, bytes[index] == 0x2D {
                index += 1
                if index + 8 <= bytes.count, Array(bytes[index..<index + 8]) == Array("Infinity".utf8) {
                    index += 8
                    return .float(-.infinity)
                }
            }
            func digits() -> Int {
                let s = index
                while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
                return index - s
            }
            let intStart = index
            let n = digits()
            guard n > 0 else { throw error("Zahl erwartet") }
            if n > 1 && bytes[intStart] == 0x30 { index = intStart + 1 }      // fuehrende Null: Rest gilt als Folgezeichen
            var isFloat = false
            if index < bytes.count, bytes[index] == 0x2E {
                let save = index
                index += 1
                if digits() == 0 { index = save } else { isFloat = true }
            }
            if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
                let save = index
                index += 1
                if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D { index += 1 }
                if digits() == 0 { index = save } else { isFloat = true }
            }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
            if isFloat {
                guard let d = Double(text) else { throw error("Zahl nicht lesbar") }
                return .float(d)
            }
            return .int(text == "-0" ? "0" : text)
        }

        mutating func string() throws -> String {
            index += 1
            var units: [UInt16] = []
            var raw: [UInt8] = []
            func flush() {
                if !raw.isEmpty { units.append(contentsOf: String(decoding: raw, as: UTF8.self).utf16); raw = [] }
            }
            while index < bytes.count {
                let c = bytes[index]
                switch c {
                case 0x22:
                    index += 1
                    flush()
                    return String(decoding: units, as: UTF16.self)               // einzelne Ersatzzeichen -> U+FFFD
                case 0x5C:
                    flush()
                    guard index + 1 < bytes.count else { throw error("Unerwartetes Ende im Text") }
                    let e = bytes[index + 1]
                    index += 2
                    switch e {
                    case 0x22: units.append(0x22)
                    case 0x5C: units.append(0x5C)
                    case 0x2F: units.append(0x2F)
                    case 0x62: units.append(0x08)
                    case 0x66: units.append(0x0C)
                    case 0x6E: units.append(0x0A)
                    case 0x72: units.append(0x0D)
                    case 0x74: units.append(0x09)
                    case 0x75:
                        guard index + 4 <= bytes.count, let v = UInt16(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16) else {
                            throw error("Ungültige \\u-Folge")
                        }
                        units.append(v)
                        index += 4
                    default: throw error("Ungültige Escape-Folge")
                    }
                case 0x00..<0x20:
                    throw error("Steuerzeichen im Text")
                default:
                    raw.append(c)
                    index += 1
                }
            }
            throw error("Text nicht abgeschlossen")
        }
    }
}

// MARK: - Python-Umwandlungen fuer gespeicherte Texte

/// `int(text)`/`float(text)` wie Python: Leerraum aussen erlaubt, "_" zwischen Ziffern, bei float auch inf/nan.
enum PyConvert {
    static func int(_ text: String) -> Int? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var sign = 1
        if s.hasPrefix("+") || s.hasPrefix("-") {
            if s.hasPrefix("-") { sign = -1 }
            s.removeFirst()
        }
        guard let digits = stripUnderscores(s), !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let v = Int(digits) else { return nil }
        return sign * v
    }

    static func float(_ text: String) -> Double? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var body = s.lowercased()
        var sign = 1.0
        if body.hasPrefix("+") || body.hasPrefix("-") {
            if body.hasPrefix("-") { sign = -1 }
            body.removeFirst()
        }
        if body == "inf" || body == "infinity" { return sign * .infinity }
        if body == "nan" { return .nan }
        // nur Dezimalschreibweise (Swift liest sonst auch "0x1p3", Python nicht)
        guard let plain = stripUnderscores(body), !plain.isEmpty,
              plain.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "." || $0 == "e" || $0 == "+" || $0 == "-") }),
              plain.contains(where: { $0.isNumber }), let v = Double(plain) else { return nil }
        return sign * v
    }

    /// "1_000" -> "1000"; "_1", "1_", "1__0" sind wie in Python ungueltig (nil)
    private static func stripUnderscores(_ s: String) -> String? {
        guard s.contains("_") else { return s }
        let c = Array(s)
        for (i, ch) in c.enumerated() where ch == "_" {
            guard i > 0, i < c.count - 1, c[i - 1].isNumber, c[i + 1].isNumber else { return nil }
        }
        return s.replacingOccurrences(of: "_", with: "")
    }
}
