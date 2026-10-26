import Foundation

// Opencast-Aufzeichnungen aus Stud.IP (LUH-Plugin "opencastpluginluh"). Die Videos liegen nicht in den Datei-Ordnern
// der JSON:API, sondern auf der serverseitig gerenderten Seite plugins.php/opencastpluginluh/media/index?cid=<Kurs>
// (Aufbau in docs/QIS-STUDIP-STRUKTUR.md, Abschnitt Opencast). Gelesen wird nur die Tabelle table.media-table:
// je Zeile tr.media-table-row Vorschau, Titel, Beschreibung, Laufzeit, Autor, Erstelldatum, Player- und
// Download-Links. Kurse ohne den Reiter antworten mit HTTP 500 ("navigation item ... not found") – das heisst
// "kein Opencast", nicht Fehler. Die Seite zerlegt `HTMLTokenizer` (derselbe Leser wie fuer QIS).

/// Eine Videodatei eines Videos, z. B. 720p (direkter MP4-Link auf dem Opencast-Host).
public struct OpencastMedia: Sendable, Equatable, Codable {
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
    /// Erstellt am, Unix-Zeit (wie `files.chdate`)
    public let created: Int?
    public let thumbnailURL: URL?
    /// Stud.IP-Player-Seite (Ersatzweg zum Abspielen in der Webansicht)
    public let playerURL: URL?
    /// nach Bildhoehe absteigend (1080p, 720p, 480p)
    public let media: [OpencastMedia]

    public init(id: String, title: String, description: String? = nil, duration: Int? = nil, author: String? = nil,
                created: Int? = nil, thumbnailURL: URL? = nil, playerURL: URL? = nil, media: [OpencastMedia] = []) {
        self.id = id
        self.title = title
        self.description = description
        self.duration = duration
        self.author = author
        self.created = created
        self.thumbnailURL = thumbnailURL
        self.playerURL = playerURL
        self.media = media
    }

    public func media(_ quality: String) -> OpencastMedia? { media.first { $0.quality == quality } }
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
        HTMLScanner.scan(overviewHTML).anchors.contains { a in
            let href = a.href.lowercased()
            return a.label.caseInsensitiveCompare("Aufzeichnungen") == .orderedSame
                || href.contains("opencastpluginluh") || href.contains("/course/opencast")
        }
    }

    /// Anmeldeseite statt Inhalt: Passwortfeld oder Formular zur Anmeldung (Stud.IP-Login, WebSSO).
    public static func looksLikeLoginPage(_ html: String) -> Bool {
        let scan = HTMLScanner.scan(html)
        return scan.hasPassword || scan.formActions.contains { a in
            let l = a.lowercased()
            return l.contains("dispatch.php/login") || l.contains("/idp/")
        }
    }

    /// "01:28:59" bzw. "35:48" -> Sekunden
    public static func seconds(_ s: String) -> Int? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
        guard (2...3).contains(parts.count), !parts.contains(where: { $0 == nil || $0! < 0 }) else { return nil }
        return parts.reduce(0) { $0 * 60 + $1! }
    }

    // MARK: Tabelle

    static func hasClass(_ attrs: [String: String], _ cls: String) -> Bool {
        (attrs["class"] ?? "").split(whereSeparator: \.isWhitespace).contains { $0 == cls }
    }

    /// Videos der Tabelle. Player-Links nur auf dem Stud.IP-Host der Seite; Videodateien und Vorschaubilder nur ueber
    /// https und nur von einem Videoserver (der Host der meisten Download-Links), Vorschaubilder auch vom
    /// Stud.IP-Host. Fremde Hosts aus der Seite bekommen so weder Anfragen noch die Stud.IP-Webansicht.
    static func videos(in tokens: [HTMLToken], pageURL: URL?) -> [OpencastVideo] {
        let raw = rawVideos(in: tokens, pageURL: pageURL)
        let pageHost = pageURL?.host?.lowercased()
        let mediaHost = mainHost(raw.flatMap(\.media).map(\.url).filter(isHTTPS))
        func onMedia(_ u: URL) -> Bool { isHTTPS(u) && u.host?.lowercased() == mediaHost }
        return raw.map { v in
            let thumb = v.thumbnailURL.flatMap { u in onMedia(u) || (isHTTPS(u) && u.host?.lowercased() == pageHost) ? u : nil }
            return OpencastVideo(id: v.id, title: v.title, description: v.description, duration: v.duration, author: v.author,
                                 created: v.created, thumbnailURL: thumb, playerURL: v.playerURL,
                                 media: v.media.filter { onMedia($0.url) })
        }
    }

    static func isHTTPS(_ u: URL) -> Bool { u.scheme?.lowercased() == "https" }

    /// haeufigster Host; bei Gleichstand der zuerst genannte
    static func mainHost(_ urls: [URL]) -> String? {
        var count: [String: Int] = [:], order: [String] = []
        for h in urls.compactMap({ $0.host?.lowercased() }) {
            if count[h] == nil { order.append(h) }
            count[h, default: 0] += 1
        }
        var best: String?
        for h in order where best == nil || (count[h] ?? 0) > (count[best!] ?? 0) { best = h }
        return best
    }

    /// Player-Link der Seite: derselbe Host und dasselbe Schema wie die Stud.IP-Seite (ohne Seite nur https)
    static func isPlayerLink(_ u: URL, pageURL: URL?) -> Bool {
        guard u.path.contains("/media/player/") else { return false }
        guard let page = pageURL, let host = page.host?.lowercased() else { return isHTTPS(u) }
        return u.host?.lowercased() == host && u.scheme?.lowercased() == page.scheme?.lowercased()
    }

    static func rawVideos(in tokens: [HTMLToken], pageURL: URL?) -> [OpencastVideo] {
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
        var created: Int?
        var player: URL?
        var media: [OpencastMedia] = []

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
                // Vorschau-Link traegt "#ts="; Player fremder Hosts nie (Webansicht mit Stud.IP-Sitzung)
                if player == nil, isPlayerLink(url, pageURL: pageURL) { player = stripFragment(url) }
            } else if let q = mediaQuality(text) {
                if !media.contains(where: { $0.quality == q.label }) { media.append(OpencastMedia(quality: q.label, height: q.height, url: url)) }
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
                    if cell == "media-table-created", let v = a["data-sort-value"], let unix = Int(v.trimmingCharacters(in: .whitespaces)), unix > 0 {
                        created = unix
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
            case .raw: break
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
                             media: media.sorted { ($0.height, $0.quality) > ($1.height, $1.quality) })
    }

    /// "Download: 720p" -> ("720p", 720); andere Eintraege (Audio, Folien) zaehlen nicht als Videodatei
    static func mediaQuality(_ text: String) -> (label: String, height: Int)? {
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

    /// "06.11.2026" (Text der Spalte, falls data-sort-value fehlt) als Mittag in Berlin, Unix-Zeit
    static func germanDate(_ s: String) -> Int? {
        let p = s.split(separator: ".").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard p.count == 3, let d = p[0], let m = p[1], let y = p[2], (1...12).contains(m), y > 1990,
              d >= 1, d <= BerlinClock.daysInMonth(year: y, month: m) else { return nil }
        return BerlinClock.utcSeconds(day: BerlinClock.dayNumber(year: y, month: m, day: d), minutes: 12 * 60)
    }
}
