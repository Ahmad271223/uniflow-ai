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

/// Eine Aufzeichnung eines Kurses: aus der Opencast-Tabelle (LUH-Plugin), dem Opencast-Plugin V3, einer Videodatei im
/// Dateibaum, einem Courseware-Block oder einem Link in der Kursbeschreibung (`source`).
public struct OpencastVideo: Sendable, Equatable, Codable, Identifiable {
    /// Kennung der Zeile (UUID oder kurze Kennung wie "Xyzab-12345-6789"); bei anderen Quellen mit Vorsatz
    /// ("file:<FileRef>", "cw:<Element>:<Block>", "link:<n>")
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
    /// Stud.IP-Seite zum Abspielen in der Webansicht mit der Stud.IP-Sitzung (Player des Plugins, Courseware-Seite)
    public let playerURL: URL?
    /// nach Bildhoehe absteigend (1080p, 720p, 480p); Videodateien aus Stud.IP als "Original"
    public let media: [OpencastMedia]
    /// Quelle: opencast (LUH-Plugin und Plugin V3), file (Dateibaum), courseware (Block), link (Kursbeschreibung)
    public let source: String
    /// Adresse ausserhalb von Stud.IP (Videoplattform), zum Oeffnen im Browser
    public let linkURL: URL?
    /// Groesse der Videodatei in Byte, wenn die Liste sie nennt (Dateibaum); sonst fragt die App den Server
    public let size: Int64?

    public static let sourceOpencast = "opencast", sourceFile = "file", sourceCourseware = "courseware", sourceLink = "link"

    public init(id: String, title: String, description: String? = nil, duration: Int? = nil, author: String? = nil,
                created: Int? = nil, thumbnailURL: URL? = nil, playerURL: URL? = nil, media: [OpencastMedia] = [],
                source: String = OpencastVideo.sourceOpencast, linkURL: URL? = nil, size: Int64? = nil) {
        self.id = id
        self.title = title
        self.description = description
        self.duration = duration
        self.author = author
        self.created = created
        self.thumbnailURL = thumbnailURL
        self.playerURL = playerURL
        self.media = media
        self.source = source
        self.linkURL = linkURL
        self.size = size
    }

    public func media(_ quality: String) -> OpencastMedia? { media.first { $0.quality == quality } }

    /// Videodatei aus Stud.IP (Dateibaum oder Courseware-Datei ueber die JSON:API): Abspielen und Laden brauchen die
    /// Stud.IP-Sitzung; Dateien eines Videoservers nicht
    public var needsStudIPSession: Bool { source == Self.sourceFile || media.contains { $0.url.path.lowercased().contains("/jsonapi.php/") } }

    /// Dateiendung einer geladenen Fassung: bei Dateien aus Stud.IP die des Dateinamens (Titel), sonst mp4
    public var fileExtension: String {
        guard source == Self.sourceFile else { return "mp4" }
        let ext = (title as NSString).pathExtension.lowercased()
        return ext.isEmpty || ext.count > 5 ? "mp4" : ext
    }
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

    /// Seite media/index lesen. `pageURL` loest relative Links auf. Neben der Tabelle `table.media-table` zaehlen auch
    /// Videos ausserhalb der Tabelle (`<video>`/`<source>`, Player-`<iframe>`) und eine Videoliste als JSON in einem
    /// `<script>` (Aufbau wie die API des Opencast-Plugins V3): Seiten ohne Tabelle, aber mit solchen Videos, sind eine
    /// Liste, keine unklare Seite.
    public static func parse(html: String, status: Int, pageURL: URL? = nil) -> OpencastListing {
        let tokens = HTMLTokenizer.tokens(html)
        let hasTable = tokens.contains { if case .start("table", let a) = $0 { return hasClass(a, "media-table") }; return false }
        if (200..<300).contains(status) {
            var list = hasTable ? videos(in: tokens, pageURL: pageURL) : []
            var seen = Set(list.map(\.id))
            for v in embeddedVideos(in: tokens, pageURL: pageURL) + looseVideos(in: tokens, pageURL: pageURL) where seen.insert(v.id).inserted {
                list.append(v)
            }
            if hasTable || !list.isEmpty { return .videos(list) }
        }
        if saysNavigationMissing(html) || status == 404 { return .noOpencast }
        return .unrecognized
    }

    /// Weitere Listenseiten desselben Kurses im LUH-Plugin (Seitenzahlen, Reiter fuer Serien/Playlists): Links auf dem
    /// Stud.IP-Host unter `plugins.php/opencastpluginluh/` mit demselben `cid`, ohne Player, Download und die Seite selbst.
    /// Rueckgabe: Pfade mit Abfrage (hoechstens `maxFurtherPages`), in der Reihenfolge der Seite.
    public static let maxFurtherPages = 8

    public static func furtherPages(html: String, courseID: String, pageURL: URL?) -> [String] {
        let pageHost = pageURL?.host?.lowercased()
        var own = pageURL.map { stripFragment($0).absoluteString } ?? ""
        if own.hasSuffix("/") { own.removeLast() }
        var out: [String] = [], seen = Set<String>()
        for a in HTMLScanner.scan(html).anchors {
            guard let u = resolve(a.href, pageURL), let host = u.host?.lowercased(), pageHost == nil || host == pageHost,
                  let c = URLComponents(url: u, resolvingAgainstBaseURL: false) else { continue }
            let p = c.path.lowercased()
            guard p.contains("/plugins.php/opencastpluginluh/"), !p.contains("/media/player/"), !p.contains("/download"),
                  !p.contains("/upload"), !p.contains("/delete"), !p.contains("/edit"),
                  c.queryItems?.first(where: { $0.name == "cid" })?.value == courseID else { continue }
            var key = stripFragment(u).absoluteString
            if key.hasSuffix("/") { key.removeLast() }
            guard key != own, seen.insert(key).inserted else { continue }
            let path = String(c.path.drop { $0 == "/" }) + (c.query.map { "?" + $0 } ?? "")
            out.append(path)
            if out.count >= maxFurtherPages { break }
        }
        return out
    }

    /// Kursueberblick: Link auf das Opencast-Plugin V3 (`plugins.php/opencastv3/…` bzw. aeltere Fassung `plugins.php/opencast/…`)
    public static func courseHasOpencastV3(overviewHTML: String) -> Bool {
        HTMLScanner.scan(overviewHTML).anchors.contains { a in OpencastV3.isPluginLink(a.href) }
    }

    /// Links im Kursueberblick, die mit Opencast oder Aufzeichnungen zu tun haben (Beschriftung und Adresse; Geraete-Probe)
    public static func opencastLinks(overviewHTML: String) -> [(label: String, href: String)] {
        HTMLScanner.scan(overviewHTML).anchors.compactMap { a in
            let h = a.href.lowercased(), l = a.label.lowercased()
            guard h.contains("opencast") || l.contains("aufzeichnung") || l.contains("video") else { return nil }
            return (a.label, a.href)
        }
    }

    // MARK: Videos ausserhalb der Tabelle

    /// `<video src>`/`<video><source src>` mit Videodatei (mp4, m3u8, webm, mov; https) und Player-`<iframe>` (Opencast-
    /// oder Engage-Player) ausserhalb von `tr.media-table-row`. Titel aus `title`, `aria-label`, `data-title`, sonst der
    /// Dateiname. Kennung: `id`/`data-id` des Elements, sonst der Dateiname der Adresse.
    static func looseVideos(in tokens: [HTMLToken], pageURL: URL?) -> [OpencastVideo] {
        var out: [OpencastVideo] = []
        var seen = Set<String>()
        var inRow = 0, inVideo: (attrs: [String: String], sources: [URL])?
        func finishVideo() {
            guard let v = inVideo else { return }
            inVideo = nil
            let urls = (v.attrs["src"].flatMap { resolve($0, pageURL) }.map { [$0] } ?? []) + v.sources
            guard let first = urls.first(where: { isHTTPS($0) && isVideoFileURL($0) }) else { return }
            let name = first.lastPathComponent
            let id = [v.attrs["id"], v.attrs["data-id"], v.attrs["data-episode"], v.attrs["data-video-id"]].compactMap { $0 }
                .first { !$0.isEmpty } ?? name
            let title = [v.attrs["title"], v.attrs["aria-label"], v.attrs["data-title"]].compactMap { $0.map(QISParser.clean) }
                .first { !$0.isEmpty } ?? name
            guard seen.insert(id).inserted else { return }
            let media = urls.filter { isHTTPS($0) && isVideoFileURL($0) }.enumerated().map { i, u in
                OpencastMedia(quality: i == 0 ? "Original" : "Original \(i + 1)", height: 0, url: u)
            }
            out.append(OpencastVideo(id: id, title: title, thumbnailURL: v.attrs["poster"].flatMap { resolve($0, pageURL) }.flatMap { isHTTPS($0) ? $0 : nil },
                                     media: media))
        }
        for t in tokens {
            switch t {
            case .start("tr", let a) where hasClass(a, "media-table-row"): inRow += 1
            case .end("tr") where inRow > 0: inRow -= 1
            case .start("video", let a) where inRow == 0:
                finishVideo()
                inVideo = (a, [])
            case .start("source", let a):
                if inVideo != nil, let u = a["src"].flatMap({ resolve($0, pageURL) }) { inVideo?.sources.append(u) }
            case .end("video"): finishVideo()
            case .start("iframe", let a) where inRow == 0:
                guard let u = a["src"].flatMap({ resolve($0, pageURL) }), isHTTPS(u) else { continue }
                let s = u.absoluteString.lowercased()
                guard s.contains("opencast") || s.contains("engage") || s.contains("/play/") || s.contains("/player/") || s.contains("watch") else { continue }
                let id = [a["id"], a["data-id"]].compactMap { $0 }.first { !$0.isEmpty } ?? u.lastPathComponent
                guard seen.insert(id).inserted else { continue }
                let title = [a["title"], a["aria-label"]].compactMap { $0.map(QISParser.clean) }.first { !$0.isEmpty } ?? "Video"
                let own = pageURL?.host?.lowercased() == u.host?.lowercased()
                out.append(OpencastVideo(id: id, title: title, playerURL: own ? stripFragment(u) : nil, linkURL: own ? nil : u))
            default: break
            }
        }
        finishVideo()
        return out
    }

    /// Videodatei nach der Adresse (ohne Abfrage): mp4, m4v, webm, mov, m3u8
    static func isVideoFileURL(_ u: URL) -> Bool {
        ["mp4", "m4v", "webm", "mov", "m3u8"].contains(u.pathExtension.lowercased())
    }

    /// Videoliste als JSON in einem `<script>` der Seite: eine Liste von Objekten mit `title` und `token`/`episode`/
    /// `publication` (Aufbau der API des Opencast-Plugins V3), auch als Wert eines Schluessels `videos`. Hoechstens
    /// `maxEmbeddedCandidates` Fundstellen je Seite, jede hoechstens 2 MB.
    static let maxEmbeddedCandidates = 20

    static func embeddedVideos(in tokens: [HTMLToken], pageURL: URL?) -> [OpencastVideo] {
        var out: [OpencastVideo] = []
        var seen = Set<String>()
        var tried = 0
        for case .raw("script", let text) in tokens {
            let b = Array(text.utf8)
            var i = 0
            while i + 1 < b.count, tried < maxEmbeddedCandidates {
                guard b[i] == UInt8(ascii: "["), b[i + 1] == UInt8(ascii: "{") else { i += 1; continue }
                tried += 1
                guard let end = balancedEnd(b, from: i) else { i += 1; continue }
                let slice = Data(b[i...end])
                i = end + 1
                guard let json = try? JSONValue.parse(slice), let list = json.array,
                      list.contains(where: { OpencastV3.looksLikeVideo($0) }) else { continue }
                for v in OpencastV3.videos(from: json, courseID: cidOf(pageURL) ?? "", base: pageURL, prefix: nil) where seen.insert(v.id).inserted {
                    out.append(v)
                }
            }
        }
        return out
    }

    /// Ende einer in `[` beginnenden JSON-Liste (Klammern ausserhalb von Zeichenketten gezaehlt), nil ohne Ende oder
    /// ab 2 MB
    static func balancedEnd(_ b: [UInt8], from start: Int) -> Int? {
        var depth = 0, inString = false, escaped = false
        var i = start
        let limit = min(b.count, start + 2_000_000)
        while i < limit {
            let c = b[i]
            if inString {
                if escaped { escaped = false } else if c == UInt8(ascii: "\\") { escaped = true } else if c == UInt8(ascii: "\"") { inString = false }
            } else {
                switch c {
                case UInt8(ascii: "\""): inString = true
                case UInt8(ascii: "["), UInt8(ascii: "{"): depth += 1
                case UInt8(ascii: "]"), UInt8(ascii: "}"):
                    depth -= 1
                    if depth == 0 { return i }
                default: break
                }
            }
            i += 1
        }
        return nil
    }

    static func cidOf(_ u: URL?) -> String? {
        u.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "cid" }?.value }
    }

    /// Die ausdrueckliche Meldung des Plugins in Kursen ohne Reiter ("navigation item ... not found")
    public static func saysNavigationMissing(_ html: String) -> Bool {
        let lower = html.lowercased()
        return lower.contains("navigation item") && lower.contains("not found")
    }

    /// Ist die Antwort sicher der Kursueberblick dieses Kurses? Adresse (falls bekannt) dispatch.php/course/overview
    /// dieses Kurses und in der Seite die Kursnavigation (Link auf Ueberblick oder Dateien dieses Kurses). Eine
    /// Zwischenseite mit HTTP 200 (Nutzungsbedingungen, Wartung, Systemhinweis) ist es nicht.
    public static func isCourseOverview(html: String, finalURL: URL?, courseID: String) -> Bool {
        func cid(_ c: URLComponents) -> String? { c.queryItems?.first { $0.name == "cid" }?.value }
        if let u = finalURL {
            guard let c = URLComponents(url: u, resolvingAgainstBaseURL: false),
                  c.path.lowercased().hasSuffix("/dispatch.php/course/overview"), cid(c) == nil || cid(c) == courseID else { return false }
        }
        return HTMLScanner.scan(html).anchors.contains { a in
            guard let c = URLComponents(string: a.href.trimmingCharacters(in: .whitespacesAndNewlines)), cid(c) == courseID else { return false }
            let p = c.path.lowercased()
            return p.hasSuffix("dispatch.php/course/overview") || p.hasSuffix("dispatch.php/course/files")
        }
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
