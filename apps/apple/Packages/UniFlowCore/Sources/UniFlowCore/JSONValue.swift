import Foundation

/// Beliebiger JSON-Wert. Das Notizmodell wird vollstaendig als `JSONValue` gehalten, damit Felder, die nur der
/// Web-Editor kennt (Text, Formen, Bilder, Lesezeichen ...), beim Speichern vom iPad unveraendert erhalten bleiben.
///
/// Eigener Leser und Schreiber statt `JSONSerialization`: gleiches Verhalten auf iOS und Linux (CI), Bool und Zahl
/// werden nie verwechselt, ganze Zahlen werden ohne `.0` geschrieben (wie im Browser), und mit `sortedKeys` ist die
/// Ausgabe deterministisch (Signaturen).
public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Zugriff

extension JSONValue {
    public subscript(key: String) -> JSONValue? {
        get {
            if case .object(let o) = self { return o[key] }
            return nil
        }
        set {
            guard case .object(var o) = self else { return }
            o[key] = newValue
            self = .object(o)
        }
    }

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var double: Double? { if case .number(let n) = self { return n }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var object: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    public var isNull: Bool { if case .null = self { return true }; return false }

    /// Ganzzahl, wenn der Wert eine endliche Zahl im Int-Bereich ist (Nachkommastellen werden abgeschnitten).
    public var int: Int? {
        guard let d = double, d.isFinite, abs(d) < 9.0e15 else { return nil }
        return Int(d)
    }
}

// MARK: - Lesen

public struct JSONParseError: Error, CustomStringConvertible, Equatable {
    public let offset: Int
    public let reason: String
    public var description: String { "JSON-Fehler bei Byte \(offset): \(reason)" }
}

extension JSONValue {
    public static func parse(_ data: Data) throws -> JSONValue {
        var parser = JSONByteParser(bytes: [UInt8](data))
        let value = try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw parser.error("Unerwartete Zeichen nach dem Ende") }
        return value
    }

    public static func parse(_ text: String) throws -> JSONValue {
        try parse(Data(text.utf8))
    }
}

struct JSONByteParser {
    let bytes: [UInt8]
    var index = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    func error(_ reason: String) -> JSONParseError { JSONParseError(offset: index, reason: reason) }

    mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x0A, 0x0D, 0x09: index += 1
            default: return
            }
        }
    }

    mutating func parseValue(depth: Int) throws -> JSONValue {
        guard depth < 512 else { throw error("Zu tief verschachtelt") }
        skipWhitespace()
        guard index < bytes.count else { throw error("Unerwartetes Ende") }
        switch bytes[index] {
        case 0x7B: return try parseObject(depth: depth)            // {
        case 0x5B: return try parseArray(depth: depth)             // [
        case 0x22: return .string(try parseString())               // "
        case 0x74: try expect([0x74, 0x72, 0x75, 0x65]); return .bool(true)          // true
        case 0x66: try expect([0x66, 0x61, 0x6C, 0x73, 0x65]); return .bool(false)   // false
        case 0x6E: try expect([0x6E, 0x75, 0x6C, 0x6C]); return .null                // null
        default: return .number(try parseNumber())
        }
    }

    mutating func expect(_ word: [UInt8]) throws {
        guard index + word.count <= bytes.count else { throw error("Unerwartetes Ende") }
        for (i, b) in word.enumerated() where bytes[index + i] != b {
            throw error("Unbekanntes Wort")
        }
        index += word.count
    }

    mutating func parseObject(depth: Int) throws -> JSONValue {
        index += 1
        var dict: [String: JSONValue] = [:]
        skipWhitespace()
        if index < bytes.count, bytes[index] == 0x7D { index += 1; return .object(dict) }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == 0x22 else { throw error("Schlüssel erwartet") }
            let key = try parseString()
            skipWhitespace()
            guard index < bytes.count, bytes[index] == 0x3A else { throw error("':' erwartet") }
            index += 1
            dict[key] = try parseValue(depth: depth + 1)
            skipWhitespace()
            guard index < bytes.count else { throw error("Unerwartetes Ende im Objekt") }
            if bytes[index] == 0x2C { index += 1; continue }
            if bytes[index] == 0x7D { index += 1; return .object(dict) }
            throw error("',' oder '}' erwartet")
        }
    }

    mutating func parseArray(depth: Int) throws -> JSONValue {
        index += 1
        var items: [JSONValue] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == 0x5D { index += 1; return .array(items) }
        while true {
            items.append(try parseValue(depth: depth + 1))
            skipWhitespace()
            guard index < bytes.count else { throw error("Unerwartetes Ende in der Liste") }
            if bytes[index] == 0x2C { index += 1; continue }
            if bytes[index] == 0x5D { index += 1; return .array(items) }
            throw error("',' oder ']' erwartet")
        }
    }

    mutating func parseString() throws -> String {
        index += 1                                                    // oeffnendes "
        var start = index
        var out: [UInt8] = []
        var escaped = false
        while index < bytes.count {
            let c = bytes[index]
            if c == 0x22 {
                let result: String
                if escaped {
                    out.append(contentsOf: bytes[start..<index])
                    result = String(decoding: out, as: UTF8.self)
                } else {
                    result = String(decoding: bytes[start..<index], as: UTF8.self)
                }
                index += 1
                return result
            }
            if c == 0x5C {
                escaped = true
                out.append(contentsOf: bytes[start..<index])
                index += 1
                guard index < bytes.count else { throw error("Unerwartetes Ende nach \\") }
                let e = bytes[index]
                index += 1
                switch e {
                case 0x22: out.append(0x22)
                case 0x5C: out.append(0x5C)
                case 0x2F: out.append(0x2F)
                case 0x62: out.append(0x08)
                case 0x66: out.append(0x0C)
                case 0x6E: out.append(0x0A)
                case 0x72: out.append(0x0D)
                case 0x74: out.append(0x09)
                case 0x75:
                    var scalar = try parseHex4()
                    if (0xD800...0xDBFF).contains(scalar) {
                        if index + 1 < bytes.count, bytes[index] == 0x5C, bytes[index + 1] == 0x75 {
                            let save = index
                            index += 2
                            let low = try parseHex4()
                            if (0xDC00...0xDFFF).contains(low) {
                                scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                            } else {
                                scalar = 0xFFFD
                                index = save
                            }
                        } else {
                            scalar = 0xFFFD
                        }
                    } else if (0xDC00...0xDFFF).contains(scalar) {
                        scalar = 0xFFFD
                    }
                    let u: Unicode.Scalar = Unicode.Scalar(scalar) ?? "\u{FFFD}"
                    UTF8.encode(u) { out.append($0) }
                default:
                    throw error("Ungültige Escape-Sequenz")
                }
                start = index
                continue
            }
            if c < 0x20 { throw error("Steuerzeichen in Zeichenkette") }
            index += 1
        }
        throw error("Zeichenkette nicht beendet")
    }

    mutating func parseHex4() throws -> UInt32 {
        guard index + 4 <= bytes.count else { throw error("Unvollständiges \\u") }
        var v: UInt32 = 0
        for _ in 0..<4 {
            let c = bytes[index]
            index += 1
            v <<= 4
            switch c {
            case 0x30...0x39: v |= UInt32(c - 0x30)
            case 0x41...0x46: v |= UInt32(c - 0x41 + 10)
            case 0x61...0x66: v |= UInt32(c - 0x61 + 10)
            default: throw error("Ungültige Hex-Ziffer")
            }
        }
        return v
    }

    mutating func parseNumber() throws -> Double {
        let start = index
        if index < bytes.count, bytes[index] == 0x2D { index += 1 }    // -
        var digits = 0
        while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 { index += 1; digits += 1 }
        guard digits > 0 else { throw error("Wert erwartet") }
        if index < bytes.count, bytes[index] == 0x2E {                  // .
            index += 1
            var frac = 0
            while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 { index += 1; frac += 1 }
            guard frac > 0 else { throw error("Nachkommastellen erwartet") }
        }
        if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {   // e E
            index += 1
            if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D { index += 1 }
            var exp = 0
            while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 { index += 1; exp += 1 }
            guard exp > 0 else { throw error("Exponent erwartet") }
        }
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        guard let d = Double(text) else { throw error("Ungültige Zahl") }
        return d
    }
}

// MARK: - Schreiben

extension JSONValue {
    /// JSON-Text. `sortedKeys` ergibt eine deterministische Ausgabe (fuer Signaturen und Tests).
    public func serialized(sortedKeys: Bool = false) -> Data {
        var out: [UInt8] = []
        out.reserveCapacity(256)
        write(into: &out, sorted: sortedKeys)
        return Data(out)
    }

    public func jsonString(sortedKeys: Bool = false) -> String {
        String(decoding: serialized(sortedKeys: sortedKeys), as: UTF8.self)
    }

    func write(into out: inout [UInt8], sorted: Bool) {
        switch self {
        case .null:
            out.append(contentsOf: [0x6E, 0x75, 0x6C, 0x6C])
        case .bool(let b):
            out.append(contentsOf: b ? [0x74, 0x72, 0x75, 0x65] : [0x66, 0x61, 0x6C, 0x73, 0x65])
        case .number(let d):
            out.append(contentsOf: JSONValue.format(d).utf8)
        case .string(let s):
            JSONValue.writeString(s, into: &out)
        case .array(let items):
            out.append(0x5B)
            var first = true
            for v in items {
                if !first { out.append(0x2C) }
                first = false
                v.write(into: &out, sorted: sorted)
            }
            out.append(0x5D)
        case .object(let dict):
            out.append(0x7B)
            var first = true
            if sorted {
                for k in dict.keys.sorted() {
                    if !first { out.append(0x2C) }
                    first = false
                    JSONValue.writeString(k, into: &out)
                    out.append(0x3A)
                    dict[k]!.write(into: &out, sorted: true)
                }
            } else {
                for (k, v) in dict {
                    if !first { out.append(0x2C) }
                    first = false
                    JSONValue.writeString(k, into: &out)
                    out.append(0x3A)
                    v.write(into: &out, sorted: false)
                }
            }
            out.append(0x7D)
        }
    }

    /// Zahlen wie im Browser: ganze Zahlen ohne Nachkommastellen, sonst kuerzeste exakte Darstellung.
    public static func format(_ d: Double) -> String {
        guard d.isFinite else { return "null" }
        if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        return "\(d)"
    }

    private static let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)

    static func writeString(_ s: String, into out: inout [UInt8]) {
        out.append(0x22)
        for b in s.utf8 {
            switch b {
            case 0x22: out.append(0x5C); out.append(0x22)
            case 0x5C: out.append(0x5C); out.append(0x5C)
            case 0x0A: out.append(0x5C); out.append(0x6E)
            case 0x0D: out.append(0x5C); out.append(0x72)
            case 0x09: out.append(0x5C); out.append(0x74)
            case 0x00..<0x20:
                out.append(contentsOf: [0x5C, 0x75, 0x30, 0x30, hexDigits[Int(b >> 4)], hexDigits[Int(b & 0x0F)]])
            default:
                out.append(b)
            }
        }
        out.append(0x22)
    }
}

// MARK: - Codable (fuer Stellen, die mit JSONEncoder/Decoder arbeiten)

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
                     ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        var d: [String: JSONValue] = [:]
        for (k, v) in elements { d[k] = v }
        self = .object(d)
    }
}
