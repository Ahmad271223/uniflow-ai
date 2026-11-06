import Foundation

// Uni-Mail und Uni-Kalender (SOGo) der LUH (https://kalender.uni-hannover.de/SOGo/) und der Uni Hildesheim
// (https://webmail.uni-hildesheim.de/SOGo/, seit 06.11.2026), docs/UNI-MAIL-2026-11-05.md. Rechner je Hochschule in
// `SOGoSite`; alles, was eine Adresse prueft, nimmt die Hochschule (`site`, Vorgabe LUH wie in app/sogo.py).
// Gleiche Regeln und gleiche JSON-Antworten wie app/sogo.py (gemeinsame Faelle in packages/shared-contracts/fixtures/sogo,
// tools/gen-sogo-fixture.py, SOGoTests). Hier nur reine Funktionen (Pfade, Ablauf der Sitzung, Empfaenger, HTML,
// Antworten lesen, Entwuerfe, Termine); Abruf in SOGoClient.swift, Speichern und Stundenplan in SOGoCalendar.swift.
//
// Anmeldung nur auf der echten Seite in der Webansicht (App), gemerkt werden nur die Cookies; nie ein Passwort, keine
// stille Erneuerung. Senden nur auf ausdruecklichen Knopfdruck und genau einmal.

public enum SOGo {
    public static let pageSize = 50
    public static let maxAttachment = 20 * 1024 * 1024
    /// Quelle der Termine im Stundenplan
    public static let source = "uni-kalender"
    public static let color = "#0e7490"

    static let folderOrder = ["inbox", "draft", "sent", "trash", "junk", "templates"]
    public static let folderNames: [String: String] = ["inbox": "Posteingang", "draft": "Entwürfe", "sent": "Gesendet",
                                                       "trash": "Papierkorb", "junk": "Spam", "templates": "Vorlagen"]

    // MARK: Werte aus JSON

    /// `_text`: Text eines Werts (null, Liste, Objekt -> ""; true/false -> "1"/"0"; ganze Zahlen ohne ".0")
    public static func text(_ v: JSONValue?) -> String {
        guard let v else { return "" }
        switch v {
        case .null, .array, .object: return ""
        case .bool(let b): return b ? "1" : "0"
        case .string(let s): return s
        case .number(let d):
            if d.rounded() == d, abs(d) < 9.0e15 { return String(Int(d)) }
            return String(d)
        }
    }

    /// Wahrheitswert aus SOGo-JSON (true/false, 0/1, "1", "true", "yes")
    public static func truthy(_ v: JSONValue?) -> Bool {
        guard let v else { return false }
        switch v {
        case .bool(let b): return b
        case .number(let d): return d != 0
        case .string(let s): return ["1", "true", "yes"].contains(PyText.lower(PyText.strip(s)))
        default: return false
        }
    }

    static func isInt(_ v: JSONValue?) -> Int? {
        if case .number(let d)? = v, d.isFinite, abs(d) < 9.0e15 { return Int(d) }
        return nil
    }

    /// `" ".join(s.split())`
    static func squash(_ s: String) -> String { HText.collapse(s) }

    static func scalars(_ s: String, _ n: Int) -> String { String(String.UnicodeScalarView(s.unicodeScalars.prefix(n))) }

    // MARK: Pfade

    private static let css: [(String, String)] = [("_", "_U_"), (".", "_D_"), ("#", "_H_"), ("@", "_A_"), ("*", "_S_"), (":", "_C_"),
                                                  (",", "_CO_"), (" ", "_SP_"), ("'", "_SQ_"), ("&", "_AM_"), ("+", "_P_")]

    /// `asCSSIdentifier` der SOGo-Weboberflaeche
    public static func cssIdentifier(_ s: String) -> String {
        var out = s
        for (a, b) in css { out = out.replacingOccurrences(of: a, with: b) }
        out = String(String.UnicodeScalarView(out.unicodeScalars.filter { $0.value < 128 }))
        if let f = out.unicodeScalars.first, ("0"..."9").contains(f) { out = "_" + out }
        return out
    }

    /// "INBOX/Archiv" -> "folderINBOX/folderArchiv"
    public static func folderPath(_ path: String) -> String {
        (path.isEmpty ? "INBOX" : path).components(separatedBy: "/").map { "folder" + cssIdentifier($0) }.joined(separator: "/")
    }

    public static func mailboxID(_ path: String) -> String { "0/" + folderPath(path) }
    public static func moveTarget(_ path: String) -> String { "/0/" + folderPath(path) }

    /// Teile einer Adresse wie `urllib.parse.urlsplit` (nur was hier gebraucht wird)
    struct Split {
        var scheme = "", host = "", port: Int?? = .some(nil), path = "", query = ""
    }

    static func split(_ s: String) -> Split? {
        guard let r = s.range(of: "://") else { return nil }
        var out = Split()
        out.scheme = PyText.lower(String(s[..<r.lowerBound]))
        var rest = s[r.upperBound...]
        if let f = rest.firstIndex(of: "#") { rest = rest[..<f] }
        let cut = rest.firstIndex { $0 == "/" || $0 == "?" } ?? rest.endIndex
        var netloc = String(rest[..<cut])
        rest = rest[cut...]
        if let q = rest.firstIndex(of: "?") {
            out.query = String(rest[rest.index(after: q)...])
            rest = rest[..<q]
        }
        out.path = String(rest)
        if let at = netloc.lastIndex(of: "@") { netloc = String(netloc[netloc.index(after: at)...]) }
        if let colon = netloc.lastIndex(of: ":") {
            let p = String(netloc[netloc.index(after: colon)...])
            netloc = String(netloc[..<colon])
            if p.isEmpty { out.port = .some(nil) } else if p.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }), let n = Int(p), n <= 65535 {
                out.port = .some(n)
            } else {
                out.port = .none                                          // ungueltig (Python: ValueError)
            }
        }
        out.host = PyText.lower(netloc)
        return out
    }

    /// Konto aus https://<rechner der hochschule>/SOGo/so/<benutzer>/...; anderer Rechner oder sonst -> nil. Den
    /// Benutzernamen nimmt es, wie er in der Adresse steht (LUH: E-Mail-Adresse, Hildesheim: wie SOGo ihn fuehrt).
    public static func user(fromURL url: String?, site: SOGoSite = .luh) -> String? {
        guard let url, !url.isEmpty, let p = split(url), p.scheme == "https", p.host == site.host,
              case .some(let port) = p.port, port == nil || port == 443 else { return nil }
        let parts = p.path.components(separatedBy: "/")
        guard parts.count >= 5, parts[1] == "SOGo", parts[2] == "so" else { return nil }
        let user = parts[3].removingPercentEncoding ?? parts[3]
        guard !user.isEmpty, user != ".", user != "..", !user.contains("/"), !user.unicodeScalars.contains(where: { $0.value < 32 }),
              user.unicodeScalars.count <= 128 else { return nil }
        return user
    }

    public static func user(fromURL url: URL?, site: SOGoSite = .luh) -> String? { user(fromURL: url?.absoluteString, site: site) }

    public static func userBase(_ user: String, site: SOGoSite = .luh) -> String { "\(site.base)/so/\(PyText.quote(user, safe: "@"))" }

    /// Anmeldeseite von SOGo
    public static func looksLikeLogin(_ text: String?) -> Bool {
        let t = text ?? ""
        return t.contains("name=\"loginForm\"") || t.contains("app.creds.username") || t.contains("id=\"passwordField\"")
    }

    /// Sitzung abgelaufen? 401/403, Weiterleitung aus /SOGo/so/ heraus oder Anmeldeformular
    public static func expired(status: Int, finalURL: String?, body: String?, site: SOGoSite = .luh) -> Bool {
        if status == 401 || status == 403 { return true }
        if let f = finalURL, !f.isEmpty, user(fromURL: f, site: site) == nil { return true }
        return looksLikeLogin(body)
    }

    /// Pfad fuer eine Anfrage (Leerzeichen und Unsicheres prozentkodiert)
    public static func quotePath(_ path: String) -> String { PyText.quote(path, safe: "/@%?=&:+,;()!*'~$") }

    // MARK: Adressen

    public static func address(_ v: JSONValue?) -> JSONValue? {
        guard let v, v.object != nil else { return nil }
        let name = PyText.strip(text(v["name"])), email = PyText.strip(text(v["email"]))
        if name.isEmpty && email.isEmpty { return nil }
        return ["name": .string(name), "email": .string(email)]
    }

    public static func addresses(_ v: JSONValue?) -> [JSONValue] { (v?.array ?? []).compactMap(address) }

    public static func addressText(_ a: JSONValue?) -> String {
        guard let a else { return "" }
        let n = a["name"]?.string ?? "", e = a["email"]?.string ?? ""
        return n.isEmpty ? e : n
    }

    public static func addressLine(_ a: JSONValue) -> String {
        let n = a["name"]?.string ?? "", e = a["email"]?.string ?? ""
        if !n.isEmpty, !e.isEmpty, n != e { return "\(n) <\(e)>" }
        return e.isEmpty ? n : e
    }

    private static let email = HText.regex(#"^[^@ \t\r\n<>"(),;:]+@[^@ \t\r\n<>"(),;:]+\.[^@ \t\r\n<>"(),;:]+$"#)

    /// Adresse aus "Name <a@b.de>" oder "a@b.de"; nil, wenn keine gueltige
    public static func emailOf(_ entry: String) -> String? {
        var s = PyText.strip(entry)
        if let lt = s.range(of: "<", options: .backwards), let gt = s.range(of: ">", options: .backwards), lt.lowerBound < gt.lowerBound {
            s = PyText.strip(String(s[lt.upperBound..<gt.lowerBound]))
        }
        return HText.match(email, s) != nil ? s : nil
    }

    /// Empfaengerfeld -> gueltige und ungueltige Eintraege (Komma, Semikolon, Zeile; nicht in "..." oder <...>)
    public static func splitRecipients(_ text: String) -> (valid: [String], invalid: [String]) {
        var parts: [String] = [], cur = String.UnicodeScalarView(), quote = false, angle = false
        for ch in text.unicodeScalars {
            if ch == "\"" && !angle { quote.toggle() }
            else if ch == "<" && !quote { angle = true }
            else if ch == ">" && !quote { angle = false }
            if (ch == "," || ch == ";" || ch == "\n") && !quote && !angle {
                parts.append(String(cur))
                cur = String.UnicodeScalarView()
            } else {
                cur.append(ch)
            }
        }
        parts.append(String(cur))
        var valid: [String] = [], invalid: [String] = []
        for p in parts {
            let x = squash(p)
            if x.isEmpty { continue }
            if emailOf(x) != nil { valid.append(x) } else { invalid.append(x) }
        }
        return (valid, invalid)
    }

    static func recipientList(_ v: JSONValue?) -> [String] {
        if let s = v?.string {
            let r = splitRecipients(s)
            return r.valid + r.invalid
        }
        var out: [String] = []
        for x in v?.array ?? [] {
            if x.object != nil {
                if let a = address(x) { out.append(addressLine(a)) }
            } else if !PyText.strip(text(x)).isEmpty {
                out.append(squash(text(x)))
            }
        }
        return out
    }

    // MARK: HTML

    private static func re(_ p: String, dotAll: Bool = false, caseless: Bool = true) -> NSRegularExpression {
        var o: NSRegularExpression.Options = []
        if caseless { o.insert(.caseInsensitive) }
        if dotAll { o.insert(.dotMatchesLineSeparators) }
        return HText.regex(p, o)
    }

    private static let sp = "[ \\t\\r\\n\\f]"
    private static let comment = re("<!--.*?-->", dotAll: true, caseless: false)
    private static let blocks = re("<(script|style|iframe|object|embed|noscript|form|svg|math|template|head|title)\\b[^>]*>.*?</\\1\(sp)*>", dotAll: true)
    private static let single = re("</?(script|style|iframe|object|embed|noscript|form|svg|math|template|head|title|link|meta|base|frame|frameset|input|button|textarea|select|option|html|body)\\b[^>]*>")
    private static let event = re("\(sp)+on[A-Za-z]+\(sp)*=\(sp)*(\"[^\"]*\"|'[^']*'|[^ \\t\\r\\n\\f>]+)")
    private static let scriptURL = re("\\b(href|src|action|formaction|xlink:href)\(sp)*=\(sp)*([\"']?)\(sp)*(javascript|vbscript|data|livescript):[^\"'> \\t\\r\\n\\f]*\\2")
    private static let remote = re("\\b(src|srcset|background|poster)\(sp)*=\(sp)*([\"']?)\(sp)*(https?:)?//")
    private static let cssURL = re("url\(sp)*\\(")
    private static let unsafe = re("\(sp)+unsafe-[A-Za-z-]+\(sp)*=\(sp)*(\"[^\"]*\"|'[^']*'|[^ \\t\\r\\n\\f>]+)")

    /// `re.sub` mit Funktion: Treffer von hinten ersetzen
    static func sub(_ r: NSRegularExpression, _ s: String, _ f: ([String?]) -> String) -> String {
        let ns = s as NSString
        let out = NSMutableString(string: ns)
        for m in r.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
            var groups: [String?] = []
            for i in 0..<m.numberOfRanges {
                let g = m.range(at: i)
                groups.append(g.location == NSNotFound ? nil : ns.substring(with: g))
            }
            out.replaceCharacters(in: m.range, with: f(groups))
        }
        return out as String
    }

    static func found(_ r: NSRegularExpression, _ s: String) -> Bool {
        r.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    /// HTML einer Mail fuer die Anzeige: ohne Skripte, Formulare, Rahmen, Ereignis-Attribute, javascript:-Links; keine
    /// Bilder und Hintergruende aus dem Netz (`remote_blocked`). Die Anzeige laedt zusaetzlich ohne JavaScript und Netz.
    public static func sanitize(_ html: String?) -> (html: String, remoteBlocked: Bool) {
        var s = (html ?? "").replacingOccurrences(of: "\r\n", with: "\n")
        s = HText.replace(comment, in: s, with: "")
        s = HText.replace(blocks, in: s, with: "")
        s = HText.replace(single, in: s, with: "")
        s = HText.replace(event, in: s, with: "")
        s = HText.replace(unsafe, in: s, with: "")
        s = sub(scriptURL, s) { "\($0[1] ?? "")=\"#\"" }
        let blocked = found(remote, s) || found(cssURL, s)
        s = sub(remote, s) { "data-blocked-\(PyText.lower($0[1] ?? ""))=\($0[2] ?? "")\($0[3] ?? "")//" }
        s = HText.replace(cssURL, in: s, with: "blocked(")
        return (PyText.strip(s), blocked)
    }

    private static let br = re("<br\\b[^>]*>")
    private static let quoteOpen = re("<blockquote\\b[^>]*>")
    private static let quoteClose = re("</blockquote\(sp)*>")
    private static let blockEnd = re("</(p|div|tr|h[1-6]|table|pre|ul|ol)\(sp)*>")
    private static let li = re("<li\\b[^>]*>")
    private static let tag = re("<[^>]+>", caseless: false)
    private static let num = re("&#([0-9]{1,7});", caseless: false)
    private static let hex = re("&#[xX]([0-9a-fA-F]{1,6});", caseless: false)
    private static let named: [(String, String)] = [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'")]
    private static let many = re("\\n{3,}", caseless: false)
    static let qIn: Unicode.Scalar = "\u{1}", qOut: Unicode.Scalar = "\u{2}"

    private static func char(_ n: Int) -> String? {
        guard n > 0, n <= 0x10FFFF, !(0xD800...0xDFFF).contains(n), let u = Unicode.Scalar(n) else { return nil }
        return String(Character(u))
    }

    /// Zeichenreferenzen (Ziffern, feste Namen, zuletzt &amp;)
    public static func entities(_ s: String) -> String {
        var t = sub(num, s) { g in char(Int(g[1] ?? "") ?? 0) ?? (g[0] ?? "") }
        t = sub(hex, t) { g in char(Int(g[1] ?? "", radix: 16) ?? 0) ?? (g[0] ?? "") }
        for (a, b) in named { t = t.replacingOccurrences(of: a, with: b) }
        return t.replacingOccurrences(of: "&amp;", with: "&")
    }

    static func quoteLines(_ s: String) -> String {
        var out: [String] = [], depth = 0
        for line in s.components(separatedBy: "\n") {
            var text = String.UnicodeScalarView(), level: Int?, marker = false
            for ch in line.unicodeScalars {
                if ch == qIn { depth += 1; marker = true }
                else if ch == qOut { depth = max(0, depth - 1); marker = true }
                else {
                    if level == nil && ch != " " && ch != "\t" { level = depth }
                    text.append(ch)
                }
            }
            if level == nil {
                if marker { continue }
                level = depth
            }
            let l = level ?? 0
            out.append(l > 0 ? String(repeating: "> ", count: l) + String(text) : String(text))
        }
        return out.joined(separator: "\n")
    }

    private static func rstrip(_ s: String, _ chars: Set<Unicode.Scalar>) -> String {
        var u = Array(s.unicodeScalars)
        while let l = u.last, chars.contains(l) { u.removeLast() }
        return String(String.UnicodeScalarView(u))
    }

    private static func strip(_ s: String, _ chars: Set<Unicode.Scalar>) -> String {
        var u = Array(s.unicodeScalars)
        while let l = u.last, chars.contains(l) { u.removeLast() }
        var i = 0
        while i < u.count, chars.contains(u[i]) { i += 1 }
        return String(String.UnicodeScalarView(u[i...]))
    }

    /// Klartext aus HTML (Zeilen, Listen, Zitate mit "> ", Zeichenreferenzen; hoechstens eine Leerzeile)
    public static func htmlToText(_ html: String?) -> String {
        var s = (html ?? "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        s = HText.replace(comment, in: s, with: "")
        s = HText.replace(blocks, in: s, with: "")
        s = HText.replace(br, in: s, with: "\n")
        s = HText.replace(quoteOpen, in: s, with: "\n\u{1}")
        s = HText.replace(quoteClose, in: s, with: "\u{2}\n")
        s = HText.replace(li, in: s, with: "\n• ")
        s = HText.replace(blockEnd, in: s, with: "\n")
        s = HText.replace(tag, in: s, with: "")
        s = entities(s)
        s = quoteLines(s)
        s = s.components(separatedBy: "\n").map { rstrip($0, [" ", "\t"]) }.joined(separator: "\n")
        s = HText.replace(many, in: s, with: "\n\n")
        return strip(s, [" ", "\t", "\n"])
    }

    // MARK: Mail lesen

    /// Ordner aus Mail/0/view: feste zuerst, dann eigene in Baumreihenfolge; ohne \Noselect
    public static func mailboxes(_ data: JSONValue?) -> [JSONValue] {
        var found: [JSONValue] = []
        func walk(_ items: JSONValue?, _ level: Int) {
            for m in items?.array ?? [] {
                guard m.object != nil else { continue }
                let path = text(m["path"])
                let flags = (m["flags"]?.array ?? []).compactMap(\.string).map { PyText.lower($0) }
                if !path.isEmpty, !flags.contains(where: { String($0.drop { $0 == "\\" }) == "noselect" }) {
                    var typ = text(m["type"])
                    if typ.isEmpty || folderNames[typ] == nil { typ = "folder" }
                    let name = typ != "folder" ? (folderNames[typ] ?? "") : (text(m["name"]).isEmpty ? (path.components(separatedBy: "/").last ?? path) : text(m["name"]))
                    found.append(["path": .string(path), "name": .string(name), "type": .string(typ), "id": .string(mailboxID(path)), "level": .number(Double(level))])
                }
                walk(m["children"], level + 1)
            }
        }
        walk(data?.object != nil ? data?["mailboxes"] : nil, 0)
        var special: [JSONValue] = []
        for t in folderOrder {
            if var hit = found.first(where: { $0["type"]?.string == t }) {
                hit["level"] = 0
                special.append(hit)
            }
        }
        let taken = Set(special.compactMap { $0["path"]?.string })
        return special + found.filter { !taken.contains($0["path"]?.string ?? "") }
    }

    public static func folder(ofType typ: String, in boxes: [JSONValue], fallback: String) -> String {
        boxes.first { $0["type"]?.string == typ }?["path"]?.string ?? fallback
    }

    /// UIDs aus einer (verschachtelten) Liste: ganze Zahlen > 0, ohne Doppelte, Reihenfolge bleibt
    public static func flattenUIDs(_ v: JSONValue?) -> [Int] {
        var out: [Int] = []
        func walk(_ v: JSONValue?) {
            guard let v else { return }
            switch v {
            case .array(let a): a.forEach(walk)
            case .number(let d):
                guard d.isFinite, abs(d) < 9.0e15 else { return }
                let n = Int(d)
                if n > 0, !out.contains(n) { out.append(n) }
            case .string(let s):
                let t = PyText.strip(s)
                if !t.isEmpty, t.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }), let n = Int(t), n > 0, !out.contains(n) { out.append(n) }
            default: return
            }
        }
        walk(v)
        return out
    }

    /// Kopfzeilen-Tabelle (Zeile 0 Feldnamen) -> Nachrichten der Liste
    public static func headers(_ table: JSONValue?) -> [JSONValue] {
        guard let rows = table?.array, let first = rows.first?.array else { return [] }
        let names = first.map { text($0) }
        var out: [JSONValue] = []
        for row in rows.dropFirst() {
            guard let r = row.array else { continue }
            var d: [String: JSONValue] = [:]
            for (i, n) in names.enumerated() where i < r.count { if d[n] == nil { d[n] = r[i] } }
            let uid = flattenUIDs(.array([d["uid"] ?? .null]))
            guard let u = uid.first else { continue }
            let frm = addresses(d["From"]), to = addresses(d["To"])
            let labels: [JSONValue] = (d["Flags"]?.array ?? []).compactMap { $0.string.map(JSONValue.string) }
            out.append(["uid": .number(Double(u)), "subject": .string(PyText.strip(text(d["Subject"]))), "from": .array(frm), "to": .array(to),
                        "sender": .string(addressText(frm.first)), "date": .string(PyText.strip(text(d["RelativeDate"]))),
                        "size": .string(PyText.strip(text(d["Size"]))), "read": .bool(truthy(d["isRead"])), "flagged": .bool(truthy(d["isFlagged"])),
                        "answered": .bool(truthy(d["isAnswered"])), "forwarded": .bool(truthy(d["isForwarded"])),
                        "attachment": .bool(truthy(d["hasAttachment"])), "labels": .array(labels)])
        }
        return out
    }

    /// Nachrichten in der Reihenfolge der UIDs
    public static func ordered(_ messages: [JSONValue], _ uids: [Int]) -> [JSONValue] {
        var by: [Int: JSONValue] = [:]
        for m in messages { if let u = m["uid"]?.int, by[u] == nil { by[u] = m } }
        return uids.compactMap { by[$0] }
    }

    public static func pageUIDs(_ uids: [Int], page: Int, size: Int = pageSize) -> [Int] {
        let p = max(0, page)
        let lo = min(uids.count, p * size), hi = min(uids.count, (p + 1) * size)
        return Array(uids[lo..<hi])
    }

    /// Antwort von .../view: alle UIDs, erste Seite, ungelesene
    public static func folderListing(_ data: JSONValue?, folder: String, size: Int = pageSize) -> JSONValue {
        let d = data?.object != nil ? data! : JSONValue.object([:])
        let uids = flattenUIDs(d["uids"])
        let first = pageUIDs(uids, page: 0, size: size)
        let token = text(d["syncToken"])
        return ["folder": .string(folder), "uids": .array(uids.map { .number(Double($0)) }), "total": .number(Double(uids.count)), "page": 0,
                "pages": .number(Double((uids.count + size - 1) / size)), "messages": .array(ordered(headers(d["headers"]), first)),
                "unseen": isInt(d["unseenCount"]).map { .number(Double($0)) } ?? .null, "sync_token": token.isEmpty ? .null : .string(token)]
    }

    /// Koerper fuer .../view: neueste zuerst; mit Suchtext in Betreff ODER Absender
    public static func folderRequest(query: String = "") -> JSONValue {
        var sorting: [String: JSONValue] = ["sort": "arrival", "asc": 0]
        let q = scalars(squash(query), 200)
        guard !q.isEmpty else { return ["sortingAttributes": .object(sorting)] }
        sorting["match"] = "OR"
        return ["sortingAttributes": .object(sorting),
                "filters": [["searchBy": "subject", "searchInput": .string(q)], ["searchBy": "from", "searchInput": .string(q)]]]
    }

    /// Pfad eines Anhangs unter /SOGo/so/ dieses Rechners; sonst nil
    public static func attachmentPath(_ url: JSONValue?, site: SOGoSite = .luh) -> String? {
        var u = PyText.strip(text(url))
        guard !u.isEmpty else { return nil }
        if u.hasPrefix("/") { u = "https://\(site.host)" + u }
        guard user(fromURL: u, site: site) != nil, let p = split(u) else { return nil }
        return p.path + (p.query.isEmpty ? "" : "?\(p.query)")
    }

    static let bodyTypes: Set<String> = ["UIxMailPartHTMLViewer", "UIxMailPartTextViewer"]

    static func walkParts(_ node: JSONValue?, _ bodies: inout [String], _ files: inout [JSONValue], site: SOGoSite) {
        guard let node else { return }
        if let a = node.array {
            for x in a { walkParts(x, &bodies, &files, site: site) }
            return
        }
        guard node.object != nil else { return }
        let typ = text(node["type"])
        let content = node["content"]
        if typ == "UIxMailPartAlternativeViewer", let list = content?.array {
            let want = PyText.lower(text(node["preferredPart"]))
            let pick = list.first { $0.object != nil && PyText.lower(text($0["contentType"])) == want }
            walkParts(pick ?? list.first, &bodies, &files, site: site)
            return
        }
        if bodyTypes.contains(typ), let s = content?.string {
            bodies.append(s)
            if PyText.strip(text(node["filename"])).isEmpty { return }
        } else if content?.array != nil || content?.object != nil, typ != "UIxMailPartImageViewer", typ != "UIxMailPartLinkViewer" {
            walkParts(content, &bodies, &files, site: site)
            return
        }
        if let path = attachmentPath(node["downloadURL"], site: site) {
            let name = PyText.strip(text(node["filename"]))
            files.append(["index": .number(Double(files.count)), "name": .string(name.isEmpty ? "Anhang" : name),
                          "size": .string(PyText.strip(text(node["size"]))), "type": .string(PyText.lower(PyText.strip(text(node["contentType"])))),
                          "path": .string(path)])
        }
    }

    /// Antwort von .../<uid>/view -> Nachricht (HTML bereinigt, Klartext, Anhaenge)
    public static func message(_ data: JSONValue?, folder: String, uid: Int, site: SOGoSite = .luh) -> JSONValue {
        let d = data?.object != nil ? data! : JSONValue.object([:])
        var bodies: [String] = [], files: [JSONValue] = []
        walkParts(d["parts"], &bodies, &files, site: site)
        let raw = bodies.joined(separator: "\n")
        let clean = sanitize(raw)
        return ["folder": .string(folder), "uid": .number(Double(uid)), "subject": .string(PyText.strip(text(d["subject"]))),
                "date": .string(PyText.strip(text(d["date"]))), "from": .array(addresses(d["from"])), "to": .array(addresses(d["to"])),
                "cc": .array(addresses(d["cc"])), "reply_to": .array(addresses(d["reply-to"])), "read": .bool(truthy(d["isRead"])),
                "draft": .bool(truthy(d["isDraft"])), "html": .string(clean.html), "remote_blocked": .bool(clean.remoteBlocked),
                "text": .string(htmlToText(raw)), "attachments": .array(files)]
    }

    // MARK: Schreiben

    /// Antwort von compose/reply/replyall/forward
    public static func created(_ data: JSONValue?) throws -> JSONValue {
        let box = PyText.strip(text(data?["mailboxPath"])), draft = PyText.strip(text(data?["draftId"]))
        guard !box.isEmpty, !draft.isEmpty, !draft.contains("/"), !draft.contains("..") else { throw SOGoError.bad("Entwurf nicht angelegt") }
        let acc = text(data?["accountId"])
        return ["account": .string(acc.isEmpty ? "0" : acc), "mailbox_path": .string(box), "draft_id": .string(draft)]
    }

    /// Entwurf zum Bearbeiten (Text immer Klartext; HTML-Antworten mit "> " zitiert)
    public static func draft(created: JSONValue, edit: JSONValue?, action: String = "compose", source: JSONValue = .null) -> JSONValue {
        let e = edit?.object != nil ? edit! : JSONValue.object([:])
        let isHTML = truthy(e["isHTML"])
        let t = text(e["text"])
        var atts: [JSONValue] = []
        for a in e["attachmentAttrs"]?.array ?? [] where a.object != nil && !PyText.strip(text(a["filename"])).isEmpty {
            atts.append(["name": .string(PyText.strip(text(a["filename"]))), "size": .string(PyText.strip(text(a["size"])))])
        }
        var out = created.object ?? [:]
        let more: [String: JSONValue] = [
            "action": .string(action), "source": source, "from": .string(PyText.strip(text(e["from"]))),
            "reply_to": .string(PyText.strip(text(e["replyTo"]))),
            "to": .array(recipientList(e["to"]).map(JSONValue.string)), "cc": .array(recipientList(e["cc"]).map(JSONValue.string)),
            "bcc": .array(recipientList(e["bcc"]).map(JSONValue.string)), "subject": .string(text(e["subject"])),
            "text": .string(isHTML ? htmlToText(t) : t.replacingOccurrences(of: "\r\n", with: "\n")), "was_html": .bool(isHTML),
            "attachments": .array(atts)]
        for (k, v) in more { out[k] = v }
        return .object(out)
    }

    /// Empfaenger: Text (Feld) oder Liste
    public enum Recipients { case text(String), list([String]) }

    static func list(_ r: Recipients) -> [String] {
        switch r {
        case .text(let s):
            let x = splitRecipients(s)
            return x.valid + x.invalid
        case .list(let l): return l.filter { !PyText.strip($0).isEmpty }.map(squash)
        }
    }

    /// Koerper fuer save/send (Klartext)
    public static func payload(_ d: JSONValue, to: Recipients, cc: Recipients, bcc: Recipients, subject: String, text body: String) -> JSONValue {
        var out: [String: JSONValue] = ["from": .string(d["from"]?.string ?? ""), "to": .array(list(to).map(JSONValue.string)),
                                        "cc": .array(list(cc).map(JSONValue.string)), "bcc": .array(list(bcc).map(JSONValue.string)),
                                        "subject": .string(subject), "text": .string(body.replacingOccurrences(of: "\r\n", with: "\n")),
                                        "isHTML": false]
        if let r = d["reply_to"]?.string, !r.isEmpty { out["replyTo"] = .string(r) }
        return .object(out)
    }

    /// Vor dem Senden: Fehlertext oder nil
    public static func checkSend(_ body: JSONValue) -> String? {
        let rec = ["to", "cc", "bcc"].flatMap { (body[$0]?.array ?? []).compactMap(\.string) }
        if rec.isEmpty { return "Bitte mindestens einen Empfänger angeben." }
        let bad = rec.filter { emailOf($0) == nil }
        if !bad.isEmpty { return "Diese Empfänger sind keine gültige E-Mail-Adresse: " + bad.prefix(3).joined(separator: ", ") }
        if (body["from"]?.string ?? "").isEmpty { return "Absender fehlt (Entwurf neu öffnen)." }
        return nil
    }

    /// Antwort von send
    public static func sendResult(status: Int, _ data: JSONValue?) -> (ok: Bool, message: String) {
        if status == 200, data?["status"]?.string == "success" { return (true, "Gesendet.") }
        let m = data?.object != nil ? PyText.strip(text(data?["message"])) : ""
        return (false, m.isEmpty ? "SOGo hat das Senden abgelehnt (HTTP \(status))." : m)
    }

    public static func unseen(_ data: JSONValue?, folder: String = "INBOX") -> Int? {
        guard data?.object != nil else { return nil }
        return isInt(data?[mailboxID(folder)])
    }

    /// UIDs neuer als die zuletzt gesehene; beim ersten Mal keine
    public static func newSince(_ uids: [Int], last: Int?) -> [Int] {
        guard let last else { return [] }
        return uids.filter { $0 > last }
    }

    /// multipart/form-data mit dem Feld "attachments"
    public static func cleanFilename(_ name: String) -> String {
        let n = scalars(squash(name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "\"", with: "'")), 120)
        return n.isEmpty ? "Anhang" : n
    }

    public static let boundary = "----StudiNowSOGo7d1f"

    public static func multipart(name: String, data: Data, mime: String) -> (body: Data, contentType: String) {
        var b = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"attachments\"; filename=\"\(cleanFilename(name))\"\r\nContent-Type: \(mime.isEmpty ? "application/octet-stream" : mime)\r\n\r\n".utf8)
        b.append(data)
        b.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return (b, "multipart/form-data; boundary=\(boundary)")
    }

    // MARK: Kalender

    /// Ortszeit Berlin eines Zeitpunkts (Tag, Minute); nil ausserhalb 2000…2100
    static func local(_ v: JSONValue?) -> (epoch: Int, day: Int, minutes: Int)? {
        var n: Int?
        switch v {
        case .number(let d)?: n = d.isFinite && abs(d) < 9.0e15 ? Int(d) : nil
        case .string(let s)?: n = Double(s).flatMap { $0.isFinite && abs($0) < 9.0e15 ? Int($0) : nil }
        default: n = nil
        }
        guard let n, n >= 946_684_800, n <= 4_102_444_800 else { return nil }
        let l = BerlinClock.local(utc: n)
        return (n, l.day, l.minutes)
    }

    static func iso(_ t: (epoch: Int, day: Int, minutes: Int)) -> String { "\(BerlinClock.isoDate(t.day))T\(LocalFreeWindows.mh(t.minutes))" }

    /// heutiger Tag (Tage seit 1970, Berlin) und sein ISO-Datum (fuer die App)
    public static func berlinDay(_ clock: UniFlowClock) -> Int { BerlinClock.local(utc: Int(clock.now.timeIntervalSince1970)).day }
    public static func isoDate(_ day: Int) -> String { BerlinClock.isoDate(day) }

    public static func eventKey(_ uid: String) -> String { "sogo-" + String(SolutionSHA256.hex(Data(uid.utf8)).prefix(16)) }

    /// eventslist -> Termine (Ortszeit, "YYYY-MM-DDTHH:MM"); ganztaegige mit Endtag einschliesslich
    public static func events(_ data: JSONValue?) -> [JSONValue] {
        guard let fields = data?["fields"]?.array, let rows = data?["events"]?.array, data?.object != nil else { return [] }
        let names = fields.map { text($0) }
        var out: [JSONValue] = [], seen = Set<String>()
        for row in rows {
            guard let r = row.array else { continue }
            var d: [String: JSONValue] = [:]
            for (i, n) in names.enumerated() where i < r.count { if d[n] == nil { d[n] = r[i] } }
            guard let st = local(d["c_startdate"]) else { continue }
            let allDay = truthy(d["c_isallday"])
            var en = local(d["c_enddate"]) ?? st
            if (en.day, en.minutes) < (st.day, st.minutes) { en = st }
            if allDay {
                if (en.day, en.minutes) > (st.day, st.minutes), let endEpoch = local(d["c_enddate"])?.epoch, let last = local(.number(Double(endEpoch - 1))),
                   (last.day, last.minutes) >= (st.day, st.minutes) {
                    en = last
                } else {
                    en = st
                }
            }
            let name = PyText.strip(text(d["c_name"])), folder = PyText.strip(text(d["c_folder"]))
            let rid = PyText.strip(text(d["c_recurrence_id"]))
            let uid = "\(folder)/\(name)" + (!rid.isEmpty ? "@\(rid)" : (truthy(d["c_iscycle"]) ? "@\(st.epoch)" : ""))
            if name.isEmpty || seen.contains(uid) { continue }
            seen.insert(uid)
            let title = squash(text(d["c_title"]))
            out.append(["uid": .string(uid), "id": .string(eventKey(uid)), "calendar": .string(PyText.strip(text(d["calendarName"]))),
                        "title": .string(title.isEmpty ? "Termin" : title), "location": .string(squash(text(d["c_location"]))),
                        "start": .string(iso(st)), "end": .string(iso(en)), "all_day": .bool(allDay),
                        "cancelled": .bool(isInt(d["c_status"]) == 0)])
        }
        return out.enumerated().sorted { a, b in
            for k in ["start", "title", "uid"] {
                let x = a.element[k]?.string ?? "", y = b.element[k]?.string ?? ""
                if x != y { return PyText.less(x, y) }
            }
            return a.offset < b.offset
        }.map(\.element)
    }

    public static func calendars(_ data: JSONValue?) -> [JSONValue] {
        let items = data?.object != nil ? data?["calendars"] : data
        var out: [JSONValue] = []
        for c in items?.array ?? [] where c.object != nil && !PyText.strip(text(c["id"])).isEmpty {
            let id = PyText.strip(text(c["id"])), name = PyText.strip(text(c["name"]))
            out.append(["id": .string(id), "name": .string(name.isEmpty ? id : name), "color": .string(PyText.strip(text(c["color"]))),
                        "active": .bool(truthy(c["active"] ?? 1))])
        }
        return out
    }

    /// Abfrage fuer eventslist (Reihenfolge wie urlencode in Python)
    public static func eventsQuery(day: Int, days: Int) -> [(String, String)] {
        let popup = days <= 7 ? "view_next7" : (days <= 14 ? "view_next14" : "view_next31")
        let ymd = BerlinClock.isoDate(day).replacingOccurrences(of: "-", with: "")
        return [("asc", "1"), ("day", ymd), ("filterpopup", popup), ("search", "title_Category_Location"), ("sort", "start"), ("value", "")]
    }
}

/// Fehler beim Abruf: Anmeldung noetig, offline, HTTP, unerwartete Antwort, Eingabe pruefen
public enum SOGoError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case needsLogin
    case offline
    case http(Int)
    case bad(String)
    case input(String)

    public var description: String {
        switch self {
        case .needsLogin: return "Die Anmeldung bei Uni-Mail ist abgelaufen. Bitte neu anmelden."
        case .offline: return "Keine Verbindung zu Uni-Mail (SOGo)."
        case .http(let s): return "Uni-Mail antwortet mit Fehler \(s)."
        case .bad(let s): return "Unerwartete Antwort von Uni-Mail: \(s)"
        case .input(let s): return s
        }
    }

    public var errorDescription: String? { description }
}

extension BackgroundNotice {
    /// Neue Uni-Mails im Posteingang (nur mit dem Schalter "Bei neuen Uni-Mails benachrichtigen"): nie Absender oder
    /// Betreff, nur die Zahl
    public static func newUniMail(_ count: Int) -> Content? {
        guard count > 0 else { return nil }
        return Content(title: "Neue Uni-Mail", body: count == 1 ? "1 neue E-Mail im Uni-Postfach" : "\(count) neue E-Mails im Uni-Postfach")
    }
}
