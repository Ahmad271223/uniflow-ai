import Foundation

// E-Mails lesen (RFC 5322, MIME RFC 2045-2047, Dateinamen RFC 2231): Kopfzeilen, kodierte Woerter, Zeichensaetze,
// base64/quoted-printable, multipart (mixed, alternative, related), Anhaenge. Reine Funktionen, keine Fremdbausteine.

public enum MailMIME {
    // MARK: Kopfzeilen

    /// Kopf und Koerper trennen (an der ersten Leerzeile)
    public static func split(_ d: Data) -> (header: Data, body: Data) {
        let b = [UInt8](d)
        var i = 0
        while i < b.count {
            if b[i] == 0x0A {
                let end = i > 0 && b[i - 1] == 0x0D ? i - 1 : i                // Kopf ohne letztes CRLF
                if i + 1 < b.count, b[i + 1] == 0x0A { return (Data(b[0..<end]), Data(b[(i + 2)...])) }
                if i + 2 < b.count, b[i + 1] == 0x0D, b[i + 2] == 0x0A { return (Data(b[0..<end]), Data(b[(i + 3)...])) }
            }
            i += 1
        }
        return (d, Data())
    }

    /// Kopfzeilen (Name klein, Wert entfaltet, roh); Reihenfolge bleibt
    public static func headers(_ d: Data) -> [(name: String, value: String)] {
        // Kopfzeilen sind 7-Bit; 8-Bit (UTF-8 ohne Kodierung) wird als UTF-8 gelesen, sonst Latin-1
        let text = String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1) ?? ""
        var out: [(String, String)] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n") {
            if let f = raw.first, f == " " || f == "\t" {
                if !out.isEmpty { out[out.count - 1].1 += " " + raw.trimmingCharacters(in: .whitespaces) }
                continue
            }
            guard let colon = raw.firstIndex(of: ":") else { continue }
            let name = raw[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty, !name.contains(" ") else { continue }
            out.append((name, raw[raw.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        return out
    }

    public static func header(_ h: [(name: String, value: String)], _ name: String) -> String? {
        h.first { $0.name == name }?.value
    }

    // MARK: Kodierte Woerter (RFC 2047)

    private static let encodedWord = HText.regex(#"=\?([^?\s]+)\?([BbQq])\?([^?\s]*)\?="#)

    /// "=?UTF-8?Q?=C3=9Cbung?= 3" -> "Übung 3"; Leerraum zwischen zwei kodierten Woertern faellt weg
    public static func decodeWords(_ s: String) -> String {
        guard s.contains("=?") else { return s }
        let ns = s as NSString
        var out = "", last = 0, prevEncoded = false
        for m in encodedWord.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let gap = ns.substring(with: NSRange(location: last, length: m.range.location - last))
            if !(prevEncoded && gap.trimmingCharacters(in: .whitespaces).isEmpty) { out += gap }
            let cs = ns.substring(with: m.range(at: 1)), enc = ns.substring(with: m.range(at: 2)).uppercased()
            let payload = ns.substring(with: m.range(at: 3))
            let bytes: Data? = enc == "B" ? base64(Data(payload.utf8)) : qp(Data(payload.replacingOccurrences(of: "_", with: " ").utf8))
            if let bytes { out += decode(bytes, charset: cs) } else { out += ns.substring(with: m.range) }
            last = m.range.location + m.range.length
            prevEncoded = true
        }
        out += ns.substring(from: last)
        return out
    }

    // MARK: Adressen

    /// "Erika Muster <erika@x.de>, "Max, Dr." <max@x.de>" -> [{name, email}] (wie `SOGo.address`)
    public static func addresses(_ raw: String?) -> [JSONValue] {
        guard let raw, !raw.isEmpty else { return [] }
        var out: [JSONValue] = []
        for part in splitList(raw) {
            var p = part.trimmingCharacters(in: .whitespaces)
            // Gruppe "Liste: a@b, c@d;" -> nur die Adressen
            if let colon = p.firstIndex(of: ":"), !p.contains("<"), !p[..<colon].contains("@") { p = String(p[p.index(after: colon)...]) }
            p = p.trimmingCharacters(in: CharacterSet(charactersIn: " ;"))
            guard !p.isEmpty else { continue }
            var name = "", email = ""
            if let lt = p.lastIndex(of: "<"), let gt = p.lastIndex(of: ">"), lt < gt {
                email = String(p[p.index(after: lt)..<gt]).trimmingCharacters(in: .whitespaces)
                name = String(p[..<lt]).trimmingCharacters(in: .whitespaces)
            } else {
                email = p
            }
            if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 {
                name = String(name.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
            }
            name = HText.collapse(decodeWords(name))
            email = email.trimmingCharacters(in: .whitespaces)
            if name.isEmpty && email.isEmpty { continue }
            out.append(["name": .string(name), "email": .string(email)])
        }
        return out
    }

    /// Komma-Liste, Kommas in "…", <…> und (…) zaehlen nicht
    static func splitList(_ s: String) -> [String] {
        var parts: [String] = [], cur = "", quote = false, angle = false, paren = 0, escape = false
        for ch in s {
            if escape { cur.append(ch); escape = false; continue }
            if ch == "\\" && quote { cur.append(ch); escape = true; continue }
            if ch == "\"" && !angle { quote.toggle() } else if ch == "<" && !quote { angle = true } else if ch == ">" && !quote { angle = false }
            else if ch == "(" && !quote { paren += 1 } else if ch == ")" && !quote { paren = max(0, paren - 1) }
            if ch == "," && !quote && !angle && paren == 0 { parts.append(cur); cur = ""; continue }
            cur.append(ch)
        }
        parts.append(cur)
        return parts
    }

    // MARK: Inhalt kodiert

    /// base64 (Leerraum und Zeilenenden ueberspringen, fehlendes "=" ergaenzen); kaputt -> nil
    public static func base64(_ d: Data) -> Data? {
        var s = [UInt8]()
        s.reserveCapacity(d.count)
        for b in d where !(b == 0x20 || b == 0x0D || b == 0x0A || b == 0x09) { s.append(b) }
        while s.count % 4 != 0 { s.append(0x3D) }
        return Data(base64Encoded: Data(s))
    }

    /// quoted-printable ("=C3=BC", weiche Zeilenenden "=\r\n")
    public static func qp(_ d: Data) -> Data {
        let b = [UInt8](d)
        var out = [UInt8](), i = 0
        out.reserveCapacity(b.count)
        func hex(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: return c - 0x30
            case 0x41...0x46: return c - 0x41 + 10
            case 0x61...0x66: return c - 0x61 + 10
            default: return nil
            }
        }
        while i < b.count {
            if b[i] == 0x3D {
                if i + 1 < b.count, b[i + 1] == 0x0A { i += 2; continue }
                if i + 2 < b.count, b[i + 1] == 0x0D, b[i + 2] == 0x0A { i += 3; continue }
                if i + 2 < b.count, let h = hex(b[i + 1]), let l = hex(b[i + 2]) { out.append(h << 4 | l); i += 3; continue }
            }
            out.append(b[i])
            i += 1
        }
        return Data(out)
    }

    /// Text in einem Zeichensatz; Unbekanntes: UTF-8, sonst Windows-1252
    public static func decode(_ d: Data, charset: String?) -> String {
        let cs = (charset ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).lowercased()
        switch cs {
        case "utf-8", "utf8", "us-ascii", "ascii", "":
            if let s = String(data: d, encoding: .utf8) { return s }
        case "iso-8859-1", "latin1", "iso8859-1", "l1":
            return String(data: d, encoding: .isoLatin1) ?? String(decoding: d, as: UTF8.self)
        case "windows-1252", "cp1252", "x-cp1252":
            if let s = String(data: d, encoding: .windowsCP1252) { return s }
        case "iso-8859-15", "latin9", "latin-9":
            return latin9(d)
        case "iso-8859-2", "latin2":
            if let s = String(data: d, encoding: .isoLatin2) { return s }
        case "windows-1250", "cp1250":
            if let s = String(data: d, encoding: .windowsCP1250) { return s }
        case "utf-16", "utf-16be", "utf-16le":
            if let s = String(data: d, encoding: cs == "utf-16le" ? .utf16LittleEndian : (cs == "utf-16be" ? .utf16BigEndian : .utf16)) { return s }
        default: break
        }
        return String(data: d, encoding: .utf8) ?? String(data: d, encoding: .windowsCP1252) ?? String(decoding: d, as: UTF8.self)
    }

    /// ISO-8859-15 (wie Latin-1 bis auf acht Zeichen, u. a. €)
    static func latin9(_ d: Data) -> String {
        let diff: [UInt8: Character] = [0xA4: "€", 0xA6: "Š", 0xA8: "š", 0xB4: "Ž", 0xB8: "ž", 0xBC: "Œ", 0xBD: "œ", 0xBE: "Ÿ"]
        var s = ""
        for b in d { s.append(diff[b] ?? Character(Unicode.Scalar(b))) }
        return s
    }

    // MARK: Content-Type und Parameter

    public struct ContentType: Equatable, Sendable {
        public var type = "text/plain"
        public var params: [String: String] = [:]
        public var isMultipart: Bool { type.hasPrefix("multipart/") }
    }

    /// "text/plain; charset="utf-8"; name*=UTF-8''%C3%9C.pdf" -> Typ und Parameter (RFC 2231 samt Fortsetzungen)
    public static func parameters(_ raw: String?) -> (value: String, params: [String: String]) {
        guard let raw else { return ("", [:]) }
        var items: [String] = [], cur = "", quote = false, escape = false
        for ch in raw {
            if escape { cur.append(ch); escape = false; continue }
            if ch == "\\" && quote { escape = true; continue }
            if ch == "\"" { quote.toggle(); continue }
            if ch == ";" && !quote { items.append(cur); cur = ""; continue }
            cur.append(ch)
        }
        items.append(cur)
        let value = items.first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        var plain: [String: String] = [:]
        var continued: [String: [(Int, String, Bool)]] = [:]
        for it in items.dropFirst() {
            guard let eq = it.firstIndex(of: "=") else { continue }
            var key = it[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let val = it[it.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            var encoded = false
            if key.hasSuffix("*") { encoded = true; key.removeLast() }
            if let star = key.lastIndex(of: "*"), let n = Int(key[key.index(after: star)...]) {
                continued[String(key[..<star]), default: []].append((n, val, encoded))
            } else if encoded {
                let r = rfc2231(val, first: true)
                plain[key] = decode(r.bytes, charset: r.charset ?? "utf-8")
            } else {
                plain[key] = val
            }
        }
        for (k, parts) in continued {
            var charset: String?, bytes = Data()
            for (i, p) in parts.sorted(by: { $0.0 < $1.0 }).enumerated() {
                if p.2 {
                    let r = rfc2231(p.1, first: i == 0)
                    if i == 0 { charset = r.charset }
                    bytes.append(r.bytes)
                } else {
                    bytes.append(Data(p.1.utf8))
                }
            }
            plain[k] = decode(bytes, charset: charset ?? "utf-8")
        }
        return (value, plain)
    }

    /// "UTF-8'de'%C3%9C.pdf" -> Bytes und Zeichensatz (nur der erste Abschnitt nennt den Zeichensatz)
    static func rfc2231(_ v: String, first: Bool) -> (bytes: Data, charset: String?) {
        var s = Substring(v), charset: String?
        if first {
            let p = v.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
            if p.count == 3 { charset = String(p[0]); s = p[2] }
        }
        return (Data(percentDecode(String(s))), charset)
    }

    static func percentDecode(_ s: String) -> [UInt8] {
        let b = Array(s.utf8)
        var out: [UInt8] = [], i = 0
        while i < b.count {
            if b[i] == 0x25, i + 2 < b.count, let v = UInt8(String(decoding: b[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) {
                out.append(v)
                i += 3
            } else {
                out.append(b[i])
                i += 1
            }
        }
        return out
    }

    // MARK: Teile

    /// Ein Teil einer Nachricht (Blatt oder multipart)
    public struct Part: Sendable {
        public var headers: [(name: String, value: String)]
        public var contentType: ContentType
        /// dekodierter Inhalt (bei multipart leer)
        public var body: Data
        public var children: [Part]
        /// "1", "1.2" (wie IMAP-Teilnummern)
        public var id: String

        public var disposition: String { MailMIME.parameters(MailMIME.header(headers, "content-disposition")).value }
        public var filename: String? {
            let d = MailMIME.parameters(MailMIME.header(headers, "content-disposition")).params["filename"]
            let n = d ?? contentType.params["name"]
            return n.map { HText.collapse(MailMIME.decodeWords($0)) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        public var charset: String? { contentType.params["charset"] }
        public var text: String { MailMIME.decode(body, charset: charset) }
    }

    static let maxDepth = 12, maxParts = 300

    /// Nachricht zerlegen
    public static func parse(_ raw: Data) -> Part {
        var count = 0
        return parsePart(raw, id: "1", depth: 0, count: &count)
    }

    static func parsePart(_ raw: Data, id: String, depth: Int, count: inout Int, defaultType: String = "text/plain") -> Part {
        count += 1
        let s = split(raw)
        let h = headers(s.header)
        let ctRaw = parameters(header(h, "content-type"))
        var ct = ContentType(type: ctRaw.value.isEmpty || !ctRaw.value.contains("/") ? defaultType : ctRaw.value, params: ctRaw.params)
        if ct.isMultipart, ct.params["boundary"]?.isEmpty ?? true { ct.type = "text/plain" }
        if ct.isMultipart, depth < maxDepth, let boundary = ct.params["boundary"] {
            var children: [Part] = []
            for (i, chunk) in multipart(s.body, boundary: boundary).enumerated() where count < maxParts {
                children.append(parsePart(chunk, id: "\(id).\(i + 1)", depth: depth + 1, count: &count,
                                          defaultType: ct.type == "multipart/digest" ? "message/rfc822" : "text/plain"))
            }
            return Part(headers: h, contentType: ct, body: Data(), children: children, id: id)
        }
        let cte = (header(h, "content-transfer-encoding") ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let body: Data
        switch cte {
        case "base64": body = base64(s.body) ?? s.body
        case "quoted-printable": body = qp(s.body)
        default: body = s.body
        }
        return Part(headers: h, contentType: ct, body: body, children: [], id: id)
    }

    /// Abschnitte zwischen "--boundary" … "--boundary--"
    static func multipart(_ body: Data, boundary: String) -> [Data] {
        let b = [UInt8](body), marker = Array(("--" + boundary).utf8)
        var starts: [(start: Int, lineStart: Int, final: Bool)] = []
        var i = 0
        var lineStart = 0
        while i <= b.count - marker.count {
            if i == lineStart, b[i] == 0x2D, Array(b[i..<(i + marker.count)]) == marker {
                var j = i + marker.count
                let final = j + 1 < b.count && b[j] == 0x2D && b[j + 1] == 0x2D
                while j < b.count, b[j] != 0x0A { j += 1 }
                starts.append((j + 1, i, final))
                if final { break }
                i = j + 1
                lineStart = i
                continue
            }
            if b[i] == 0x0A { lineStart = i + 1 }
            i += 1
        }
        var out: [Data] = []
        for k in 0..<starts.count where !starts[k].final {
            let from = min(starts[k].start, b.count)
            var to = k + 1 < starts.count ? starts[k + 1].lineStart : b.count
            if to > from, b[to - 1] == 0x0A { to -= 1 }
            if to > from, b[to - 1] == 0x0D { to -= 1 }
            out.append(from < to ? Data(b[from..<to]) : Data())
        }
        return out
    }

    /// Text- und HTML-Koerper und Anhaenge (alternative: HTML bevorzugt wie SOGo; related: der Hauptteil)
    public static func contents(_ root: Part) -> (html: [String], text: [String], attachments: [Part]) {
        var html: [String] = [], text: [String] = [], files: [Part] = []
        func leaf(_ p: Part, inline: Bool) {
            let t = p.contentType.type, disp = p.disposition
            let isText = t == "text/plain" || t == "text/html" || t == "text/enriched"
            // Koerper: Text ohne "attachment" und ohne Dateinamen (oder ausdruecklich "inline")
            if inline, isText, disp != "attachment", p.filename == nil || disp == "inline" {
                if t == "text/html" {
                    html.append(p.text)
                } else {
                    text.append(p.text)
                    html.append(plainToHTML(p.text))
                }
                return
            }
            // eingebettetes Bild ohne Namen (cid:) zeigt die Anzeige nicht und ist kein Anhang
            if disp != "attachment", p.filename == nil, t.hasPrefix("image/"), p.headers.contains(where: { $0.name == "content-id" }) { return }
            files.append(p)
        }
        func walk(_ p: Part, inline: Bool) {
            guard p.contentType.isMultipart else { leaf(p, inline: inline); return }
            switch p.contentType.type {
            case "multipart/alternative":
                let pick = p.children.last { $0.contentType.type == "text/html" || $0.contentType.isMultipart } ?? p.children.last
                if let pick { walk(pick, inline: inline) }
                // Klartext-Fassung daneben: fuer Zitat und "Als reinen Text zeigen" (statt aus dem HTML abgeleitet)
                if inline, pick?.contentType.type != "text/plain",
                   let plain = p.children.first(where: { $0.contentType.type == "text/plain" && $0.disposition != "attachment" }) {
                    text.append(plain.text)
                }
                // Anhaenge in anderen Zweigen (selten) trotzdem zeigen
                for c in p.children where c.id != pick?.id { collectFiles(c, &files) }
            case "multipart/related":
                guard let first = p.children.first else { return }
                walk(first, inline: inline)
                for c in p.children.dropFirst() where c.filename != nil && c.disposition == "attachment" { files.append(c) }
            default:
                for (i, c) in p.children.enumerated() { walk(c, inline: inline && (i == 0 || c.disposition != "attachment")) }
            }
        }
        walk(root, inline: true)
        return (html, text, files)
    }

    private static func collectFiles(_ p: Part, _ files: inout [Part]) {
        if p.contentType.isMultipart { p.children.forEach { collectFiles($0, &files) }; return }
        if p.disposition == "attachment" { files.append(p) }
    }

    /// Klartext als einfaches HTML (fuer die gemeinsame Anzeige mit HTML-Teilen)
    static func plainToHTML(_ s: String) -> String {
        let e = s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        return "<div style=\"white-space:pre-wrap\">" + e.replacingOccurrences(of: "\r\n", with: "\n") + "</div>"
    }

    /// Ein Teil ueber seine Nummer
    public static func find(_ root: Part, id: String) -> Part? {
        if root.id == id { return root }
        for c in root.children { if let f = find(c, id: id) { return f } }
        return nil
    }

    // MARK: Datum

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    /// "Thu, 26 Nov 2026 10:42:00 +0100" (auch ohne Wochentag/Sekunden, mit "(CET)", "GMT") -> Zeitpunkt
    public static func date(_ raw: String?) -> Date? {
        guard var s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if let paren = s.firstIndex(of: "(") { s = String(s[..<paren]).trimmingCharacters(in: .whitespaces) }
        if let comma = s.firstIndex(of: ",") { s = String(s[s.index(after: comma)...]) }
        let p = s.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard p.count >= 4, let day = Int(p[0]), let m = months.firstIndex(of: String(p[1].prefix(3)).lowercased()), var year = Int(p[2]) else { return nil }
        if year < 100 { year += year < 50 ? 2000 : 1900 }
        let t = p[3].split(separator: ":").compactMap { Int($0) }
        guard t.count >= 2 else { return nil }
        var offset = 0
        if p.count >= 5 {
            let z = p[4]
            if let f = z.first, f == "+" || f == "-", z.count == 5, let v = Int(z.dropFirst()) {
                offset = (v / 100 * 3600 + v % 100 * 60) * (f == "-" ? -1 : 1)
            } else if ["cest", "mesz"].contains(z.lowercased()) {
                offset = 7200
            } else if ["cet", "mez"].contains(z.lowercased()) {
                offset = 3600
            }
        }
        let n = BerlinClock.dayNumber(year: year, month: m + 1, day: day)
        let secs = n * 86400 + t[0] * 3600 + t[1] * 60 + (t.count > 2 ? t[2] : 0) - offset
        return Date(timeIntervalSince1970: TimeInterval(secs))
    }

    /// IMAP INTERNALDATE "26-Nov-2026 10:42:00 +0100"
    public static func internalDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let p = raw.split(separator: " ")
        guard p.count == 3 else { return nil }
        let d = p[0].split(separator: "-")
        guard d.count == 3 else { return nil }
        return date("\(d[0]) \(d[1]) \(d[2]) \(p[1]) \(p[2])")
    }
}
