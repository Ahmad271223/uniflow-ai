import Foundation

// Opencast-Aufzeichnungen aus Stud.IP (LUH-Plugin "opencastpluginluh"). Die Videos liegen nicht in den Datei-Ordnern
// der JSON:API, sondern auf der serverseitig gerenderten Seite plugins.php/opencastpluginluh/media/index?cid=<Kurs>
// (Aufbau in docs/QIS-STUDIP-STRUKTUR.md, Abschnitt Opencast). Gelesen wird nur die Tabelle table.media-table:
// je Zeile tr.media-table-row Vorschau, Titel, Beschreibung, Laufzeit, Autor, Erstelldatum, Player- und
// Download-Links. Kurse ohne den Reiter antworten mit HTTP 500 ("navigation item ... not found") – das heisst
// "kein Opencast", nicht Fehler.

/// Eine Download-Fassung eines Videos, z. B. 720p.
public struct OpencastDownload: Sendable, Equatable, Codable {
    /// Bezeichnung wie auf der Seite, z. B. "720p"
    public let quality: String
    /// Bildhoehe aus der Bezeichnung (720), 0 wenn unbekannt
    public let height: Int
    public let url: URL

    public init(quality: String, height: Int, url: URL) {
        self.quality = quality
        self.height = height
        self.url = url
    }
}

/// Eine Aufzeichnung aus der Opencast-Tabelle eines Kurses.
public struct OpencastVideo: Sendable, Equatable, Codable, Identifiable {
    /// Kennung der Zeile (UUID oder kurze Kennung wie "Xyzab-12345-6789")
    public let id: String
    public let title: String
    public let description: String?
    /// Laufzeit in Sekunden
    public let duration: Int?
    /// nil, wenn die Seite "-" zeigt
    public let author: String?
    public let created: Date?
    public let thumbnailURL: URL?
    /// Stud.IP-Player-Seite (Ersatzweg zum Abspielen in der Webansicht)
    public let playerURL: URL?
    /// nach Bildhoehe absteigend (1080p, 720p, 480p)
    public let downloads: [OpencastDownload]

    public init(id: String, title: String, description: String? = nil, duration: Int? = nil, author: String? = nil,
                created: Date? = nil, thumbnailURL: URL? = nil, playerURL: URL? = nil, downloads: [OpencastDownload] = []) {
        self.id = id
        self.title = title
        self.description = description
        self.duration = duration
        self.author = author
        self.created = created
        self.thumbnailURL = thumbnailURL
        self.playerURL = playerURL
        self.downloads = downloads
    }

    public func download(_ quality: String) -> OpencastDownload? { downloads.first { $0.quality == quality } }
}

/// Ergebnis der Seite media/index eines Kurses.
public enum OpencastListing: Sendable, Equatable {
    /// Reiter vorhanden; leere Liste = noch keine Videos
    case videos([OpencastVideo])
    /// Kurs ohne Opencast-Reiter (HTTP 500 "navigation item ... not found" bzw. 404)
    case noOpencast
    /// weder Tabelle noch die bekannte Fehlerseite (z. B. Wartungsseite): nichts daraus schliessen
    case unrecognized
}

public enum OpencastParser {
    /// Pfad der Aufzeichnungsseite eines Kurses
    public static func mediaIndexPath(courseID: String) -> String {
        "plugins.php/opencastpluginluh/media/index?cid=\(courseID)"
    }

    /// Kursueberblick (Navigation mit dem Reiter "Aufzeichnungen")
    public static func overviewPath(courseID: String) -> String {
        "dispatch.php/course/overview?cid=\(courseID)"
    }

    /// Seite media/index lesen. `pageURL` loest relative Links auf.
    public static func parse(html: String, status: Int, pageURL: URL? = nil) -> OpencastListing {
        let tokens = HTMLTokenizer.tokens(html)
        let hasTable = tokens.contains { if case .start("table", let a) = $0 { return hasClass(a, "media-table") }; return false }
        if hasTable, (200..<300).contains(status) { return .videos(videos(in: tokens, pageURL: pageURL)) }
        let lower = html.lowercased()
        let missingNavigation = lower.contains("navigation item") && lower.contains("not found")
        if missingNavigation || status == 404 { return .noOpencast }
        return .unrecognized
    }

    /// Kursueberblick: gibt es in der Navigation einen Link "Aufzeichnungen" bzw. zum Opencast-Plugin?
    public static func courseHasRecordings(overviewHTML: String) -> Bool {
        anchors(HTMLTokenizer.tokens(overviewHTML)).contains { a in
            let href = a.href.lowercased()
            return a.text.caseInsensitiveCompare("Aufzeichnungen") == .orderedSame
                || href.contains("opencastpluginluh") || href.contains("/course/opencast")
        }
    }

    /// Anmeldeseite statt Inhalt: Passwortfeld oder Formular zur Anmeldung (Stud.IP-Login, WebSSO).
    public static func looksLikeLoginPage(_ html: String) -> Bool {
        for t in HTMLTokenizer.tokens(html) {
            guard case .start(let name, let a) = t else { continue }
            if name == "input", (a["type"] ?? "").lowercased() == "password" { return true }
            if name == "form", let action = a["action"]?.lowercased(),
               action.contains("dispatch.php/login") || action.contains("/idp/") { return true }
        }
        return false
    }

    /// "01:28:59" bzw. "35:48" -> Sekunden
    public static func seconds(_ s: String) -> Int? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ":").map { Int($0) }
        guard (2...3).contains(parts.count), !parts.contains(where: { $0 == nil || $0! < 0 }) else { return nil }
        return parts.reduce(0) { $0 * 60 + $1! }
    }

    // MARK: Tabelle

    static func hasClass(_ attrs: [String: String], _ cls: String) -> Bool {
        (attrs["class"] ?? "").split(whereSeparator: \.isWhitespace).contains { $0 == cls }
    }

    static func videos(in tokens: [HTMLToken], pageURL: URL?) -> [OpencastVideo] {
        var out: [OpencastVideo] = []
        var seen = Set<String>()
        var i = 0
        while i < tokens.count {
            guard case .start("tr", let a) = tokens[i], hasClass(a, "media-table-row") else { i += 1; continue }
            // Zeile endet bei </tr>, beim naechsten <tr> oder am Tabellenende (offene Zeilen)
            var j = i + 1
            while j < tokens.count {
                if case .end(let n) = tokens[j], n == "tr" || n == "tbody" || n == "table" { break }
                if case .start("tr", _) = tokens[j] { break }
                j += 1
            }
            if let v = video(id: a["id"], tokens: Array(tokens[(i + 1)..<j]), pageURL: pageURL), !seen.contains(v.id) {
                seen.insert(v.id)
                out.append(v)
            }
            i = j
        }
        return out
    }

    static func video(id rowID: String?, tokens: [HTMLToken], pageURL: URL?) -> OpencastVideo? {
        var thumbnail: URL?
        var titleParts: [String] = [], descriptionParts: [String] = []
        var duration: Int?, durationText: [String] = []
        var author: [String] = [], createdText: [String] = []
        var created: Date?
        var player: URL?
        var downloads: [OpencastDownload] = []

        // offene Zelle (Klasse) und Stand in div.media-table-infos (Tiefe, Nummer des Kind-Blocks)
        var cell: String?
        var infosDepth: Int?, divDepth = 0, infoChild = 0
        var anchor: (href: String, parts: [String])?

        func finishAnchor() {
            guard let a = anchor else { return }
            anchor = nil
            let text = QISParser.clean(a.parts.joined())
            guard let url = resolve(a.href, pageURL) else { return }
            if url.path.contains("/media/player/") {
                if player == nil { player = stripFragment(url) }             // Vorschau-Link traegt "#ts="
            } else if let q = downloadQuality(text) {
                if !downloads.contains(where: { $0.quality == q.label }) { downloads.append(OpencastDownload(quality: q.label, height: q.height, url: url)) }
            }
        }

        for t in tokens {
            switch t {
            case .start(let name, let a):
                switch name {
                case "td", "th":
                    finishAnchor()
                    cell = (a["class"] ?? "").split(whereSeparator: \.isWhitespace).first { $0.hasPrefix("media-table-") }.map(String.init) ?? ""
                    infosDepth = nil
                    if cell == "media-table-duration", let v = a["data-sort-value"] { duration = seconds(v) }
                    if cell == "media-table-created", let v = a["data-sort-value"], let unix = Double(v.trimmingCharacters(in: .whitespaces)), unix > 0 {
                        created = Date(timeIntervalSince1970: unix)
                    }
                case "div":
                    divDepth += 1
                    if hasClass(a, "thumb-container"), thumbnail == nil { thumbnail = backgroundImage(a["style"] ?? "").flatMap { resolve($0, pageURL) } }
                    if infosDepth == nil, hasClass(a, "media-table-infos") { infosDepth = divDepth; infoChild = 0 }
                    else if let d = infosDepth, divDepth == d + 1 { infoChild += 1 }
                case "a":
                    finishAnchor()
                    if let h = a["href"] { anchor = (h, []) }
                case "br":
                    if infosDepth != nil, infoChild == 2 { descriptionParts.append("\n") }
                default: break
                }
            case .end(let name):
                switch name {
                case "a": finishAnchor()
                case "div":
                    if let d = infosDepth, divDepth == d { infosDepth = nil }
                    divDepth = max(0, divDepth - 1)
                case "td", "th":
                    finishAnchor()
                    cell = nil
                    infosDepth = nil
                default: break
                }
            case .text(let s):
                anchor?.parts.append(s)
                if infosDepth != nil {
                    if infoChild == 1 { titleParts.append(s) } else if infoChild == 2 { descriptionParts.append(s) }
                }
                switch cell {
                case "media-table-duration": durationText.append(s)
                case "media-table-lecturer": author.append(s)
                case "media-table-created": createdText.append(s)
                default: break
                }
            }
        }
        finishAnchor()

        let title = QISParser.clean(titleParts.joined())
        let id = (rowID?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? player.map { $0.lastPathComponent }
        guard let id, !id.isEmpty, !title.isEmpty else { return nil }
        let desc = descriptionParts.joined().split(separator: "\n").map { QISParser.clean(String($0)) }.filter { !$0.isEmpty }.joined(separator: "\n")
        let who = QISParser.clean(author.joined())
        if duration == nil { duration = seconds(QISParser.clean(durationText.joined())) }
        if created == nil { created = germanDate(QISParser.clean(createdText.joined())) }
        return OpencastVideo(id: id, title: title, description: desc.isEmpty ? nil : desc, duration: duration,
                             author: who.isEmpty || who == "-" || who == "–" ? nil : who, created: created,
                             thumbnailURL: thumbnail, playerURL: player,
                             downloads: downloads.sorted { ($0.height, $0.quality) > ($1.height, $1.quality) })
    }

    /// "Download: 720p" -> ("720p", 720); andere Eintraege (Audio, Folien) zaehlen nicht als Videofassung
    static func downloadQuality(_ text: String) -> (label: String, height: Int)? {
        guard text.lowercased().hasPrefix("download") else { return nil }
        let rest = text.drop { $0 != ":" }.dropFirst().trimmingCharacters(in: .whitespaces)
        guard let r = rest.range(of: "^[0-9]{3,4}p$", options: [.regularExpression, .caseInsensitive]) else { return nil }
        let label = String(rest[r]).lowercased()
        return (label, Int(label.dropLast()) ?? 0)
    }

    /// background-image:url('…') bzw. url("…") bzw. url(…)
    static func backgroundImage(_ style: String) -> String? {
        guard let start = style.range(of: "url(", options: .caseInsensitive) else { return nil }
        var rest = style[start.upperBound...]
        guard let close = rest.firstIndex(of: ")") else { return nil }
        rest = rest[..<close]
        let v = rest.trimmingCharacters(in: CharacterSet(charactersIn: "'\" \t"))
        return v.isEmpty ? nil : v
    }

    /// nur http(s); relative Links gegen die Seite
    static func resolve(_ href: String, _ base: URL?) -> URL? {
        let h = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, !h.lowercased().hasPrefix("mailto:"), !h.lowercased().hasPrefix("javascript:") else { return nil }
        let u = URL(string: h, relativeTo: base)?.absoluteURL ?? URL(string: h.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "")
        guard let u, let s = u.scheme?.lowercased(), s == "https" || s == "http", u.host != nil else { return nil }
        return u
    }

    static func stripFragment(_ u: URL) -> URL {
        guard var c = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return u }
        c.fragment = nil
        return c.url ?? u
    }

    /// "06.11.2026" (Text der Spalte, falls data-sort-value fehlt) als Mittag in Deutschland
    static func germanDate(_ s: String) -> Date? {
        let p = s.split(separator: ".").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard p.count == 3, let d = p[0], let m = p[1], let y = p[2], (1...31).contains(d), (1...12).contains(m), y > 1990 else { return nil }
        return LectureWeek.calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))
    }

    static func anchors(_ tokens: [HTMLToken]) -> [(href: String, text: String)] {
        var out: [(String, String)] = []
        var open: (String, [String])?
        for t in tokens {
            switch t {
            case .start("a", let a):
                if let o = open { out.append((o.0, QISParser.clean(o.1.joined()))) }
                open = a["href"].map { ($0, []) }
            case .end("a"):
                if let o = open { out.append((o.0, QISParser.clean(o.1.joined()))) }
                open = nil
            case .text(let s): open?.1.append(s)
            default: break
            }
        }
        if let o = open { out.append((o.0, QISParser.clean(o.1.joined()))) }
        return out
    }
}

// MARK: - HTML in Bausteine

/// Start-Tag (Name klein, Attribute dekodiert), End-Tag oder Text (Entities dekodiert).
enum HTMLToken: Equatable {
    case start(String, [String: String])
    case end(String)
    case text(String)
}

/// Durchlauf ueber die Bytes ohne Annahmen ueber wohlgeformtes HTML (offene Tags, Gross-/Kleinschreibung,
/// Attribute ohne Anfuehrungszeichen); Kommentare, Doctype und Inhalt von script/style werden uebersprungen.
enum HTMLTokenizer {
    static func tokens(_ html: String) -> [HTMLToken] {
        let b = Array(html.utf8)
        let n = b.count
        var out: [HTMLToken] = []
        var i = 0
        var textStart = 0

        func isAlpha(_ c: UInt8) -> Bool { (c | 0x20) >= 0x61 && (c | 0x20) <= 0x7A }
        func isNameChar(_ c: UInt8) -> Bool { isAlpha(c) || (c >= 0x30 && c <= 0x39) || c == UInt8(ascii: "-") || c == UInt8(ascii: ":") }
        func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0C }
        func lower(_ s: ArraySlice<UInt8>) -> String { String(decoding: s.map { isAlpha($0) ? $0 | 0x20 : $0 }, as: UTF8.self) }
        func find(_ needle: [UInt8], from: Int, caseless: Bool = false) -> Int? {
            var k = from
            while k + needle.count <= n {
                var hit = true
                for (o, c) in needle.enumerated() {
                    let x = b[k + o]
                    if (caseless && isAlpha(x) ? x | 0x20 : x) != c { hit = false; break }
                }
                if hit { return k }
                k += 1
            }
            return nil
        }
        func flush(_ end: Int) {
            if end > textStart { out.append(.text(QISParser.decodeEntities(String(decoding: b[textStart..<end], as: UTF8.self)))) }
        }

        while i < n {
            guard b[i] == UInt8(ascii: "<"), i + 1 < n else { i += 1; continue }
            let c = b[i + 1]
            if c == UInt8(ascii: "!") || c == UInt8(ascii: "?") {
                flush(i)
                if c == UInt8(ascii: "!"), i + 3 < n, b[i + 2] == UInt8(ascii: "-"), b[i + 3] == UInt8(ascii: "-") {
                    i = find(Array("-->".utf8), from: i + 4).map { $0 + 3 } ?? n
                } else {
                    i = find([UInt8(ascii: ">")], from: i + 2).map { $0 + 1 } ?? n
                }
                textStart = i
                continue
            }
            if c == UInt8(ascii: "/"), i + 2 < n, isAlpha(b[i + 2]) {
                flush(i)
                var j = i + 2
                while j < n, isNameChar(b[j]) { j += 1 }
                out.append(.end(lower(b[(i + 2)..<j])))
                i = find([UInt8(ascii: ">")], from: j).map { $0 + 1 } ?? n
                textStart = i
                continue
            }
            guard isAlpha(c) else { i += 1; continue }
            flush(i)
            var j = i + 1
            while j < n, isNameChar(b[j]) { j += 1 }
            let name = lower(b[(i + 1)..<j])
            var attrs: [String: String] = [:]
            while j < n {
                while j < n, isSpace(b[j]) { j += 1 }
                guard j < n else { break }
                if b[j] == UInt8(ascii: ">") { j += 1; break }
                if b[j] == UInt8(ascii: "/") { j += 1; continue }
                let ns = j
                while j < n, !isSpace(b[j]), b[j] != UInt8(ascii: "="), b[j] != UInt8(ascii: ">"),
                      !(b[j] == UInt8(ascii: "/") && j + 1 < n && b[j + 1] == UInt8(ascii: ">")) { j += 1 }
                if j == ns { j += 1; continue }
                let attr = lower(b[ns..<j])
                while j < n, isSpace(b[j]) { j += 1 }
                var value = ""
                if j < n, b[j] == UInt8(ascii: "=") {
                    j += 1
                    while j < n, isSpace(b[j]) { j += 1 }
                    if j < n, b[j] == UInt8(ascii: "\"") || b[j] == UInt8(ascii: "'") {
                        let q = b[j]
                        j += 1
                        let vs = j
                        while j < n, b[j] != q { j += 1 }
                        value = String(decoding: b[vs..<j], as: UTF8.self)
                        if j < n { j += 1 }
                    } else {
                        let vs = j
                        while j < n, !isSpace(b[j]), b[j] != UInt8(ascii: ">") { j += 1 }
                        value = String(decoding: b[vs..<j], as: UTF8.self)
                    }
                }
                if attrs[attr] == nil { attrs[attr] = QISParser.decodeEntities(value) }
            }
            i = j
            textStart = i
            if name == "script" || name == "style" || name == "textarea" || name == "title" {
                // Rohtext bis zum passenden End-Tag; nur der Titel bleibt als Text erhalten
                let close = find(Array("</\(name)".utf8), from: i, caseless: true) ?? n
                out.append(.start(name, attrs))
                if name == "title", close > i { out.append(.text(QISParser.decodeEntities(String(decoding: b[i..<close], as: UTF8.self)))) }
                out.append(.end(name))
                i = close < n ? (find([UInt8(ascii: ">")], from: close).map { $0 + 1 } ?? n) : n
                textStart = i
                continue
            }
            out.append(.start(name, attrs))
        }
        flush(n)
        return out
    }
}
