import Foundation

// E-Mail schreiben (RFC 5322 + MIME): Kopfzeilen sicher (keine Zeilenumbrueche aus Eingaben, Nicht-ASCII als kodierte
// Woerter), Text als UTF-8 quoted-printable, Anhaenge base64 in multipart/mixed. Bcc steht nie im Kopf.

public enum MailCompose {
    public struct Attachment: Sendable, Equatable {
        public let name: String
        public let mime: String
        public let data: Data
        public init(name: String, mime: String, data: Data) {
            self.name = name
            self.mime = mime
            self.data = data
        }
    }

    public struct Message: Sendable {
        public var from: String
        public var to: [String] = []
        public var cc: [String] = []
        public var bcc: [String] = []
        public var subject = ""
        public var text = ""
        public var inReplyTo: String?
        public var references: String?
        public var attachments: [Attachment] = []
        public var date = Date()
        public var messageID: String
        public init(from: String, messageID: String) {
            self.from = from
            self.messageID = messageID
        }

        /// Alle Empfaenger-Adressen (An, Cc, Bcc), ohne Doppelte
        public var recipients: [String] {
            var seen = Set<String>(), out: [String] = []
            for r in to + cc + bcc {
                guard let e = SOGo.emailOf(r) else { continue }
                if seen.insert(e.lowercased()).inserted { out.append(e) }
            }
            return out
        }
    }

    /// Keine Steuerzeichen (vor allem kein CR/LF) in Kopfzeilen
    static func clean(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7F ? " " : $0 }))
    }

    static func isASCII(_ s: String) -> Bool { s.unicodeScalars.allSatisfy { $0.value < 0x80 } }

    /// Nicht-ASCII als "=?UTF-8?B?…?=" (Stuecke zu hoechstens 45 Bytes, ohne ein Zeichen zu teilen)
    public static func encodeWords(_ s: String) -> String {
        let c = clean(s)
        guard !isASCII(c) else { return c }
        var words: [String] = [], cur = Data()
        for ch in c {
            let b = Data(String(ch).utf8)
            if cur.count + b.count > 45 {
                words.append("=?UTF-8?B?\(cur.base64EncodedString())?=")
                cur = Data()
            }
            cur.append(b)
        }
        if !cur.isEmpty { words.append("=?UTF-8?B?\(cur.base64EncodedString())?=") }
        return words.joined(separator: "\r\n ")
    }

    /// "Erika Muster <e@x.de>" -> Kopfzeilen-Form; nil ohne gueltige Adresse
    public static func addressHeader(_ entry: String) -> String? {
        guard let email = SOGo.emailOf(entry) else { return nil }
        var name = entry
        if let lt = entry.range(of: "<", options: .backwards) { name = String(entry[..<lt.lowerBound]) } else { name = "" }
        name = HText.collapse(clean(name)).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        guard !name.isEmpty, name != email else { return email }
        if !isASCII(name) { return "\(encodeWords(name)) <\(email)>" }
        let special = name.contains { "()<>[]:;@\\,.\"".contains($0) }
        return special ? "\"\(name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" <\(email)>" : "\(name) <\(email)>"
    }

    /// quoted-printable fuer UTF-8-Text (Zeilen hoechstens 76 Zeichen, CRLF)
    public static func qpEncode(_ s: String) -> String {
        var out: [String] = []
        for line in s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n") {
            var cur = ""
            let bytes = Array(line.utf8)
            for (i, b) in bytes.enumerated() {
                let last = i == bytes.count - 1
                var piece: String
                if (b >= 33 && b <= 126 && b != 61) || (b == 32 && !last) || (b == 9 && !last) {
                    piece = String(UnicodeScalar(b))
                } else {
                    piece = String(format: "=%02X", b)
                }
                if piece == "." && cur.isEmpty { piece = "=2E" }                 // nie ein Punkt am Zeilenanfang
                if cur.count + piece.count > 75 {
                    out.append(cur + "=")
                    cur = piece == "." ? "=2E" : piece
                } else {
                    cur += piece
                }
            }
            out.append(cur)
        }
        return out.joined(separator: "\r\n")
    }

    static func base64Lines(_ d: Data) -> String {
        let s = d.base64EncodedString()
        var out: [Substring] = [], i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 76, limitedBy: s.endIndex) ?? s.endIndex
            out.append(s[i..<j])
            i = j
        }
        return out.joined(separator: "\r\n")
    }

    /// Dateiname als Parameter (RFC 2231 fuer Nicht-ASCII, dazu eine ASCII-Form fuer alte Programme)
    static func filenameParams(_ name: String) -> (type: String, disposition: String) {
        let n = SOGo.cleanFilename(name)
        if isASCII(n) {
            let q = n.replacingOccurrences(of: "\\", with: "_").replacingOccurrences(of: "\"", with: "'")
            return ("name=\"\(q)\"", "filename=\"\(q)\"")
        }
        let star = PyText.quote(n, safe: "")
        let ascii = String(String.UnicodeScalarView(n.unicodeScalars.map { $0.value < 0x80 ? $0 : "_" }))
        return ("name=\"\(ascii)\"", "filename*=UTF-8''\(star)")
    }

    /// RFC-5322-Datum ("Fri, 27 Nov 2026 10:42:00 +0100", Ortszeit Berlin)
    public static func dateHeader(_ d: Date) -> String {
        let utc = Int(d.timeIntervalSince1970)
        let offset = BerlinClock.isSummerTime(utc: utc) ? 7200 : 3600
        let local = utc + offset
        let day = BerlinClock.floorDiv(local, 86400), sec = local - day * 86400
        let c = BerlinClock.civil(day)
        let wd = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"][BerlinClock.weekday(day)]
        let mon = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][c.month - 1]
        return String(format: "%@, %02d %@ %04d %02d:%02d:%02d +%02d00", wd, c.day, mon, c.year, sec / 3600, sec % 3600 / 60, sec % 60, offset / 3600)
    }

    /// Fertige Nachricht (CRLF); `includeBcc` nur fuer den Entwurf im eigenen Postfach
    public static func render(_ m: Message, boundary: String = "StudiNow-" + UUID().uuidString, includeBcc: Bool = false) -> Data {
        var h: [String] = []
        h.append("Date: \(dateHeader(m.date))")
        h.append("From: \(addressHeader(m.from) ?? clean(m.from))")
        let to = m.to.compactMap(addressHeader), cc = m.cc.compactMap(addressHeader), bcc = m.bcc.compactMap(addressHeader)
        if !to.isEmpty { h.append("To: " + to.joined(separator: ",\r\n ")) }
        if !cc.isEmpty { h.append("Cc: " + cc.joined(separator: ",\r\n ")) }
        if includeBcc, !bcc.isEmpty { h.append("Bcc: " + bcc.joined(separator: ",\r\n ")) }
        h.append("Subject: \(encodeWords(m.subject))")
        h.append("Message-ID: <\(clean(m.messageID))>")
        if let r = m.inReplyTo.map(clean), !r.isEmpty { h.append("In-Reply-To: \(r)") }
        if let r = m.references.map(clean), !r.isEmpty { h.append("References: \(r)") }
        h.append("MIME-Version: 1.0")
        h.append("User-Agent: StudiNow")
        let textPart = "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n" + qpEncode(m.text)
        var out = h.joined(separator: "\r\n") + "\r\n"
        if m.attachments.isEmpty {
            out += textPart + "\r\n"
            return Data(out.utf8)
        }
        out += "Content-Type: multipart/mixed; boundary=\"\(boundary)\"\r\n\r\nThis is a multi-part message in MIME format.\r\n"
        out += "--\(boundary)\r\n" + textPart + "\r\n"
        for a in m.attachments {
            let p = filenameParams(a.name)
            let mime = clean(a.mime.isEmpty ? "application/octet-stream" : a.mime).lowercased()
            out += "--\(boundary)\r\nContent-Type: \(mime); \(p.type)\r\nContent-Disposition: attachment; \(p.disposition)\r\n"
            out += "Content-Transfer-Encoding: base64\r\n\r\n" + base64Lines(a.data) + "\r\n"
        }
        out += "--\(boundary)--\r\n"
        return Data(out.utf8)
    }

    // MARK: Antworten, Weiterleiten

    /// "Re: " bzw. "Fwd: " vorn, nicht doppelt
    public static func subject(_ s: String, prefix: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        let low = t.lowercased()
        let known = prefix == "Re: " ? ["re:", "aw:", "antw:"] : ["fwd:", "fw:", "wg:"]
        if known.contains(where: { low.hasPrefix($0) }) { return t }
        return prefix + t
    }

    /// Text mit "> " zitiert, darueber "Am … schrieb …:"
    public static func quote(_ text: String, intro: String) -> String {
        let body = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
        return "\n\n\(intro)\n\(body)"
    }
}
