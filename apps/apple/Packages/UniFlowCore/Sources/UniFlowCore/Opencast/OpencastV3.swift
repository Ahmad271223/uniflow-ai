import Foundation

// Opencast-Plugin V3 fuer Stud.IP (elan-ev/studip-opencast-plugin, https://github.com/elan-ev/studip-opencast-plugin):
// anders als das LUH-Plugin (`opencastpluginluh`, serverseitig gerenderte Tabelle) ist die Kursseite eine Vue-App
// (`plugins.php/opencastv3/course/index?cid=…`), die ihre Videos per JSON holt. Routen (lib/RouteMap.php,
// https://elan-ev.github.io/studip-opencast-plugin/studip_opencast_routes.html): GET `api/courses/{course_id}/videos`
// (Videos aller mit dem Kurs verknuepften Playlists, `{videos: [...], count}`, `offset`/`limit` hoechstens 100,
// Standard 20), GET `api/courses/{course_id}/playlists`, GET `api/playlists/{token}/videos`. Ein Video
// (lib/Models/Videos.php, `toSanitizedArray`): token, episode, title, description, duration (Millisekunden),
// presenters, created, mkdate/chdate (Unix), preview {search, player}, publication {downloads {presenter|presentation|
// audio: {<Groesse>: {url, info "1280 * 720 px"}}}, track_link}. Abspielen in Stud.IP: `redirect/perform/video/{token}`
// (so bindet der Courseware-Block des Plugins das Video als iframe ein). Der Pfad des Plugins folgt aus seiner Klasse:
// `opencastv3` (3.x), in aelteren Fassungen `opencast`. Nur lesend (GET).

public enum OpencastV3 {
    /// Plugin-Pfade unter plugins.php, in der Reihenfolge der Pruefung
    public static let pluginPrefixes = ["opencastv3", "opencast"]
    /// groesste erlaubte Seite der API
    public static let pageSize = 100
    /// hoechstens so viele Seiten je Kurs
    public static let maxPages = 5

    public static func coursePagePath(prefix: String, courseID: String) -> String { "plugins.php/\(prefix)/course/index?cid=\(courseID)" }

    public static func videosPath(prefix: String, courseID: String, offset: Int) -> String {
        "plugins.php/\(prefix)/api/courses/\(courseID)/videos?offset=\(offset)&limit=\(pageSize)&cid=\(courseID)"
    }

    public static func playlistsPath(prefix: String, courseID: String) -> String { "plugins.php/\(prefix)/api/courses/\(courseID)/playlists" }

    /// Link auf das Plugin V3 (Kursnavigation)
    public static func isPluginLink(_ href: String) -> Bool {
        let h = href.lowercased()
        return pluginPrefixes.contains { h.contains("plugins.php/\($0)/") }
    }

    /// Plugin-Pfad eines Links (fuer die Wahl zwischen `opencastv3` und `opencast`)
    public static func prefix(of href: String) -> String? {
        let h = href.lowercased()
        return pluginPrefixes.first { h.contains("plugins.php/\($0)/") }
    }

    /// Sieht ein JSON-Objekt wie ein Video des Plugins aus? (`title` und token/episode/publication)
    public static func looksLikeVideo(_ v: JSONValue) -> Bool {
        guard v.object != nil, v["title"]?.string != nil else { return false }
        return v["token"]?.string != nil || v["episode"]?.string != nil || v["publication"]?.object != nil
    }

    /// Videos einer Antwort (`{videos: [...]}` oder eine Liste). `base`/`prefix`: Stud.IP-Adresse und Plugin-Pfad fuer die
    /// Player-Seite; ohne sie gibt es keinen Player-Link. Videodateien nur ueber https.
    public static func videos(from json: JSONValue, courseID: String, base: URL?, prefix: String?) -> [OpencastVideo] {
        let list = json["videos"]?.array ?? json.array ?? []
        var out: [OpencastVideo] = []
        var seen = Set<String>()
        for v in list where looksLikeVideo(v) {
            let token = v["token"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            let id = token ?? v["episode"]?.string ?? v["id"]?.string ?? v["id"]?.int.map(String.init) ?? ""
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            // Papierkorb und nicht verfuegbare Videos nicht
            if v["trashed"] == .bool(true) || v["available"] == .bool(false) { continue }
            let title = QISParser.clean(v["title"]?.string ?? "")
            let description = v["description"]?.string.map(QISParser.clean).flatMap { $0.isEmpty ? nil : $0 }
            var duration: Int?
            if let d = v["duration"]?.double, d > 0 { duration = Int((d / 1000).rounded()) }
            let author = (v["presenters"]?.string ?? v["presenters"]?.array?.compactMap(\.string).joined(separator: ", "))
                .map(QISParser.clean).flatMap { $0.isEmpty || $0 == "-" ? nil : $0 }
            var created: Int?
            if let s = v["created"]?.string, let t = StudIPLibrary.unixTime(s), t > 0 { created = t }
            else if let n = v["mkdate"]?.int, n > 0 { created = n }
            else if let s = v["mkdate"]?.string, let t = StudIPLibrary.unixTime(s), t > 0 { created = t }
            let thumb = [v["preview"]?["player"]?.string, v["preview"]?["search"]?.string, v["preview"]?.string]
                .compactMap { $0 }.compactMap { URL(string: $0) }.first { OpencastParser.isHTTPS($0) }
            var player: URL?
            if let base, let prefix, let token {
                var b = base.absoluteString
                while b.hasSuffix("/") { b.removeLast() }
                player = URL(string: "\(b)/plugins.php/\(prefix)/redirect/perform/video/\(token)?cid=\(courseID)")
            }
            out.append(OpencastVideo(id: id, title: title.isEmpty ? "Video" : title, description: description, duration: duration,
                                     author: author, created: created, thumbnailURL: thumb, playerURL: player,
                                     media: media(v["publication"]?["downloads"])))
        }
        return out
    }

    /// Videodateien aus `publication.downloads`: Kamera (`presenter`) als "720p", Folien (`presentation`) als "720p Folien",
    /// Audio zaehlt nicht; je Gruppe nach Bildhoehe absteigend, Kamera vor Folien
    static func media(_ downloads: JSONValue?) -> [OpencastMedia] {
        var out: [OpencastMedia] = []
        for (group, suffix) in [("presenter", ""), ("presentation", " Folien")] {
            var tracks: [OpencastMedia] = []
            for (_, t) in downloads?[group]?.object ?? [:] {
                guard let s = t["url"]?.string, let u = URL(string: s), OpencastParser.isHTTPS(u) else { continue }
                let h = height(t["info"]?.string ?? "")
                let label = (h > 0 ? "\(h)p" : "Original") + suffix
                guard !tracks.contains(where: { $0.quality == label }) else { continue }
                tracks.append(OpencastMedia(quality: label, height: h, url: u))
            }
            out += tracks.sorted { ($0.height, $0.quality) > ($1.height, $1.quality) }
        }
        return out
    }

    /// "1280 * 720 px" bzw. "1280x720" -> 720
    static func height(_ info: String) -> Int {
        let parts = info.lowercased().replacingOccurrences(of: "px", with: "")
            .split(whereSeparator: { $0 == "*" || $0 == "x" || $0 == "×" })
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return parts.count >= 2 ? parts[1] : 0
    }
}

extension StudIPClient {
    /// Videos eines Kurses ueber das Opencast-Plugin V3 (GET `api/courses/{id}/videos`, alle Seiten). nil, wenn das Plugin
    /// nicht antwortet (404 oder HTML statt JSON unter beiden Pfaden): dann gibt es dieses Plugin nicht. Wirft
    /// `sessionExpired` (Weiterleitung auf die Anmeldung), `requestLimit` und Transportfehler.
    public func opencastV3Listing(courseID: String, preferredPrefix: String? = nil) async throws -> OpencastListing? {
        var prefixes = OpencastV3.pluginPrefixes
        if let p = preferredPrefix, let i = prefixes.firstIndex(of: p) { prefixes.remove(at: i); prefixes.insert(p, at: 0) }
        for prefix in prefixes {
            let r = try await jsonPage(OpencastV3.videosPath(prefix: prefix, courseID: courseID, offset: 0))
            guard r.isJSON, let json = try? JSONValue.parse(r.body), json["videos"]?.array != nil || json.array != nil else { continue }
            var videos = OpencastV3.videos(from: json, courseID: courseID, base: base, prefix: prefix)
            let total = json["count"]?.int ?? videos.count
            var offset = json["videos"]?.array?.count ?? videos.count, pages = 1
            while offset < total, offset > 0, pages < OpencastV3.maxPages {
                let more = try await jsonPage(OpencastV3.videosPath(prefix: prefix, courseID: courseID, offset: offset))
                guard more.isJSON, let j = try? JSONValue.parse(more.body), let page = j["videos"]?.array, !page.isEmpty else { break }
                let known = Set(videos.map(\.id))
                videos += OpencastV3.videos(from: j, courseID: courseID, base: base, prefix: prefix).filter { !known.contains($0.id) }
                offset += page.count
                pages += 1
            }
            return .videos(videos)
        }
        return nil
    }
}
