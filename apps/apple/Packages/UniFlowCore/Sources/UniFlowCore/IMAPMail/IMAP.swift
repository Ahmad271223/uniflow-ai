import Foundation

// IMAP4rev1 (RFC 3501) als reine Funktionen: Antworten zerlegen (Atome, Zeichenketten, Literale, Listen, NIL),
// Argumente sicher schreiben (Zeichenkette in Anfuehrungszeichen oder Literal), Ordnernamen (modifiziertes UTF-7,
// RFC 3501 5.1.3), UID-Mengen, LIST/STATUS/SEARCH/FETCH lesen. Kein Netz; Ablauf in IMAPSession.swift.

/// Ein Wert einer IMAP-Antwort
public indirect enum IMAPValue: Equatable, Sendable {
    case atom(String)
    case string(Data)
    case list([IMAPValue])
    case nil_

    public var text: String? {
        switch self {
        case .atom(let s): return s
        case .string(let d): return String(decoding: d, as: UTF8.self)
        default: return nil
        }
    }

    public var data: Data? {
        switch self {
        case .string(let d): return d
        case .atom(let s): return Data(s.utf8)
        default: return nil
        }
    }

    public var list: [IMAPValue]? { if case .list(let l) = self { return l }; return nil }
    public var int: Int? { if case .atom(let s) = self { return Int(s) }; return nil }
    public var isNil: Bool { self == .nil_ }
}

/// Argument eines Befehls
public enum IMAPArg: Equatable, Sendable {
    /// unveraendert (Befehlswort, Zahl, UID-Menge, Klammerliste)
    case raw(String)
    /// Zeichenkette: in Anfuehrungszeichen, wo moeglich, sonst Literal
    case string(String)
    /// immer als Literal (Nachricht fuer APPEND)
    case literal(Data)
}

public enum IMAPError: Error, Equatable, CustomStringConvertible {
    /// Server lehnt die Anmeldung ab (falsches Passwort, gesperrt)
    case authenticationFailed(String)
    /// NO/BAD auf einen Befehl
    case rejected(String)
    /// Server beendet (BYE) oder unverstaendliche Antwort
    case protocolError(String)
    /// verlangte Faehigkeit fehlt (z. B. kein UIDPLUS: dann nie EXPUNGE)
    case unsupported(String)

    public var description: String {
        switch self {
        case .authenticationFailed(let s): return "Anmeldung abgelehnt" + (s.isEmpty ? "" : ": \(s)")
        case .rejected(let s): return "Der Mail-Rechner hat abgelehnt" + (s.isEmpty ? "" : ": \(s)")
        case .protocolError(let s): return "Unerwartete Antwort des Mail-Rechners" + (s.isEmpty ? "" : ": \(s)")
        case .unsupported(let s): return "Der Mail-Rechner kann das nicht (\(s))."
        }
    }
}

public enum IMAP {
    // MARK: Schreiben

    /// Zeichenkette in Anfuehrungszeichen, wenn sie nur aus druckbarem ASCII besteht; sonst nil (dann Literal)
    public static func quoted(_ s: String) -> String? {
        var out = "\""
        for u in s.unicodeScalars {
            guard u.value >= 0x20, u.value < 0x7F else { return nil }
            if u == "\"" || u == "\\" { out.append("\\") }
            out.unicodeScalars.append(u)
        }
        return out + "\""
    }

    /// UID-Menge "5,7,9" (aufsteigend, zusammenhaengende als Bereich "1:4")
    public static func uidSet(_ uids: [Int]) -> String {
        let s = Array(Set(uids.filter { $0 > 0 })).sorted()
        var parts: [String] = []
        var i = 0
        while i < s.count {
            var j = i
            while j + 1 < s.count, s[j + 1] == s[j] + 1 { j += 1 }
            parts.append(j > i ? "\(s[i]):\(s[j])" : "\(s[i])")
            i = j + 1
        }
        return parts.joined(separator: ",")
    }

    // MARK: Modifiziertes UTF-7 (Ordnernamen)

    private static let b64 = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+,".utf8)

    /// "Gel&APY-schte Elemente" -> "Gelöschte Elemente"; ungueltig -> unveraendert
    public static func decodeMailbox(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = "", i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            guard c == "&", let dash = s[s.index(after: i)...].firstIndex(of: "-") else {
                out.append(c)
                i = s.index(after: i)
                continue
            }
            let chunk = s[s.index(after: i)..<dash]
            if chunk.isEmpty {
                out.append("&")
            } else {
                var bits = 0, acc = 0, bytes: [UInt8] = []
                for ch in chunk.utf8 {
                    guard let v = b64.firstIndex(of: ch) else { return s }
                    acc = (acc << 6) | v
                    bits += 6
                    if bits >= 8 {
                        bits -= 8
                        bytes.append(UInt8((acc >> bits) & 0xFF))
                    }
                }
                guard bytes.count % 2 == 0 else { return s }
                var units: [UInt16] = []
                for k in stride(from: 0, to: bytes.count, by: 2) { units.append(UInt16(bytes[k]) << 8 | UInt16(bytes[k + 1])) }
                out += String(decoding: units, as: UTF16.self)
            }
            i = s.index(after: dash)
        }
        return out
    }

    /// Umkehrung von `decodeMailbox`
    public static func encodeMailbox(_ s: String) -> String {
        var out = "", pending: [UInt16] = []
        func flush() {
            guard !pending.isEmpty else { return }
            var bytes: [UInt8] = []
            for u in pending { bytes += [UInt8(u >> 8), UInt8(u & 0xFF)] }
            var acc = 0, bits = 0
            out.append("&")
            for b in bytes {
                acc = (acc << 8) | Int(b)
                bits += 8
                while bits >= 6 {
                    bits -= 6
                    out.unicodeScalars.append(Unicode.Scalar(b64[(acc >> bits) & 0x3F]))
                }
            }
            if bits > 0 { out.unicodeScalars.append(Unicode.Scalar(b64[(acc << (6 - bits)) & 0x3F])) }
            out.append("-")
            pending = []
        }
        for u in s.unicodeScalars {
            if u.value >= 0x20, u.value <= 0x7E {
                flush()
                out += u == "&" ? "&-" : String(u)
            } else {
                pending += Array(String(u).utf16)
            }
        }
        flush()
        return out
    }

    // MARK: Lesen

    /// Zerlegt eine Antwort (Zeile samt eingebetteter Literale "{n}\r\n<n Bytes>") in Werte. Eckige Klammern gehoeren
    /// zum Atom (`BODY[HEADER.FIELDS (FROM)]`, `[UIDVALIDITY 3]`).
    public static func tokens(_ d: Data) throws -> [IMAPValue] {
        let b = [UInt8](d)
        var i = 0
        func parse(_ close: UInt8?) throws -> [IMAPValue] {
            var out: [IMAPValue] = []
            while i < b.count {
                let c = b[i]
                if c == 0x20 || c == 0x0D || c == 0x0A { i += 1; continue }
                if let close, c == close { i += 1; return out }
                switch c {
                case 0x28:                                                     // (
                    i += 1
                    out.append(.list(try parse(0x29)))
                case 0x29:                                                     // ) ohne Gegenstueck
                    throw IMAPError.protocolError("Klammer")
                case 0x22:                                                     // "
                    i += 1
                    var s: [UInt8] = []
                    while i < b.count, b[i] != 0x22 {
                        if b[i] == 0x5C, i + 1 < b.count { i += 1 }
                        s.append(b[i])
                        i += 1
                    }
                    guard i < b.count else { throw IMAPError.protocolError("Anführungszeichen") }
                    i += 1
                    out.append(.string(Data(s)))
                case 0x7B:                                                     // {n}
                    var j = i + 1, n = 0
                    while j < b.count, (0x30...0x39).contains(b[j]) { n = n * 10 + Int(b[j] - 0x30); j += 1; if n > 1 << 30 { throw IMAPError.protocolError("Literal") } }
                    if j < b.count, b[j] == 0x2B { j += 1 }
                    guard j < b.count, b[j] == 0x7D else {                    // kein Literal: Atom
                        out.append(.atom(atom(&i, b)))
                        continue
                    }
                    j += 1
                    if j < b.count, b[j] == 0x0D { j += 1 }
                    if j < b.count, b[j] == 0x0A { j += 1 }
                    guard j + n <= b.count else { throw IMAPError.protocolError("Literal zu kurz") }
                    out.append(.string(Data(b[j..<(j + n)])))
                    i = j + n
                default:
                    let a = atom(&i, b)
                    out.append(a.uppercased() == "NIL" ? .nil_ : .atom(a))
                }
            }
            if close != nil { throw IMAPError.protocolError("Klammer fehlt") }
            return out
        }
        return try parse(nil)
    }

    private static func atom(_ i: inout Int, _ b: [UInt8]) -> String {
        var s: [UInt8] = [], depth = 0
        while i < b.count {
            let c = b[i]
            if depth == 0, c == 0x20 || c == 0x28 || c == 0x29 || c == 0x0D || c == 0x0A { break }
            if c == 0x5B { depth += 1 }
            if c == 0x5D { depth = max(0, depth - 1) }
            s.append(c)
            i += 1
        }
        if s.isEmpty { i += 1 }                                                 // nie stehen bleiben
        return String(decoding: s, as: UTF8.self)
    }

    /// Statuszeile ("OK [CODE …] Text") -> Status, Code, Text
    public static func status(_ line: String) -> (status: String, code: String?, text: String) {
        var rest = Substring(line)
        let word = rest.prefix { $0 != " " }
        rest = rest.dropFirst(word.count).drop { $0 == " " }
        var code: String?
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            code = String(rest[rest.index(after: rest.startIndex)..<close])
            rest = rest[rest.index(after: close)...].drop { $0 == " " }
        }
        return (word.uppercased(), code, String(rest))
    }

    /// Faehigkeiten aus "CAPABILITY IMAP4rev1 AUTH=PLAIN …" (gross geschrieben)
    public static func capabilities(_ words: [String]) -> Set<String> {
        Set(words.drop { $0.uppercased() == "CAPABILITY" }.map { $0.uppercased() })
    }

    /// Ein Ordner aus LIST
    public struct Mailbox: Equatable, Sendable {
        public let raw: String
        public let flags: [String]
        public let delimiter: String?
        public var name: String { IMAP.decodeMailbox(raw) }
        public var selectable: Bool { !flags.contains { ["\\noselect", "\\nonexistent"].contains($0.lowercased()) } }
    }

    /// "* LIST (\HasNoChildren) "/" "INBOX"" (Werte nach "*")
    public static func listEntry(_ t: [IMAPValue]) -> Mailbox? {
        guard t.count >= 4, t[0].text?.uppercased() == "LIST" || t[0].text?.uppercased() == "LSUB", let flags = t[1].list,
              let raw = t[3].text else { return nil }
        return Mailbox(raw: raw, flags: flags.compactMap(\.text), delimiter: t[2].text)
    }

    /// "* STATUS "INBOX" (MESSAGES 3 UNSEEN 1)" -> Werte
    public static func statusEntry(_ t: [IMAPValue]) -> [String: Int] {
        guard t.count >= 3, t[0].text?.uppercased() == "STATUS", let l = t[2].list else { return [:] }
        var out: [String: Int] = [:]
        var k = 0
        while k + 1 < l.count {
            if let n = l[k].text?.uppercased(), let v = l[k + 1].int { out[n] = v }
            k += 2
        }
        return out
    }

    /// "* SEARCH 4 9 12" -> Zahlen
    public static func searchEntry(_ t: [IMAPValue]) -> [Int]? {
        guard t.first?.text?.uppercased() == "SEARCH" else { return nil }
        return t.dropFirst().compactMap(\.int).filter { $0 > 0 }
    }

    /// "* 3 FETCH (UID 9 FLAGS (\Seen) …)" -> Felder (Namen gross; BODY[…] wie geschickt)
    public static func fetchEntry(_ t: [IMAPValue]) -> [String: IMAPValue]? {
        guard t.count >= 3, t[1].text?.uppercased() == "FETCH", let l = t[2].list else { return nil }
        var out: [String: IMAPValue] = [:]
        var k = 0
        while k + 1 < l.count {
            if let n = l[k].text { out[normalizedFetchKey(n)] = l[k + 1] }
            k += 2
        }
        return out
    }

    /// "BODY[HEADER.FIELDS (FROM TO)]" -> "BODY[HEADER]", "BODY[]<0>" -> "BODY[]"; andere gross
    static func normalizedFetchKey(_ n: String) -> String {
        let u = n.uppercased()
        if u.hasPrefix("BODY[HEADER.FIELDS") { return "BODY[HEADER]" }
        if let lt = u.firstIndex(of: "<"), u.hasPrefix("BODY[") { return String(u[..<lt]) }
        return u
    }

    /// "[APPENDUID 1 42]" bzw. "[COPYUID 1 3 7]" -> letzte Zahl(en)
    public static func appendUID(_ code: String?) -> Int? {
        guard let code else { return nil }
        let p = code.split(separator: " ")
        guard p.count == 3, p[0].uppercased() == "APPENDUID" else { return nil }
        return Int(p[2])
    }
}
