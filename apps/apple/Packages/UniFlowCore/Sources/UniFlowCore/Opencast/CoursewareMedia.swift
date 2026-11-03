import Foundation

// Aufzeichnungen ausserhalb des Opencast-Plugins (03.11.2026): Vorlesungsvideos liegen an der LUH auch als Dateien im
// Dateibaum eines Kurses (JSON:API), als Video-, Link-, iframe- oder Embed-Block in der Courseware und als Link auf eine
// Videoplattform in der Kursbeschreibung. Alle werden wie Opencast-Videos in `opencast_videos` gefuehrt (`source`) und
// im Bereich "Aufzeichnungen" gezeigt; Videodateien aus Stud.IP laufen ueber die JSON:API mit der Stud.IP-Sitzung
// (Abspielen als Stream, Laden nur auf Wunsch wie Opencast), Courseware-Bloecke oeffnen ihre Seite in Stud.IP, Links
// den Browser. Nur lesend; nichts davon kostet eine zusaetzliche Anfrage (Dateiliste und Courseware liest der
// Abgleich ohnehin).

/// Videodateien im Dateibaum eines Kurses
public enum OpencastFileVideos {
    public static let extensions = ["mp4", "m4v", "mov", "webm", "mkv"]

    public static func isVideo(name: String, mime: String?) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        if extensions.contains(ext) { return true }
        let m = (mime ?? "").lowercased()
        return m.hasPrefix("video/") && !m.contains("mp2t")
    }

    /// Videodatei, die sich abspielen und laden laesst (nicht herunterladbare Dateien kann auch die App nicht holen)
    public static func isVideo(_ f: StudIPFile) -> Bool { f.isDownloadable && isVideo(name: f.name, mime: f.mimeType) }

    public static func id(fileID: String) -> String { "file:" + fileID }

    /// Eintrag fuer die Aufzeichnungen: Titel = Dateiname (mit Endung, fuer die Einordnung wie bei Dateien),
    /// Beschreibung = Ordner, Datum = Aenderungszeit, eine Fassung "Original" ueber die JSON:API
    public static func video(_ f: StudIPFile, base: URL) -> OpencastVideo {
        let url = URL(string: StudIPLibrary.downloadURL(base: base, fileID: f.id))
        return OpencastVideo(id: id(fileID: f.id), title: f.name, description: f.folderPath.isEmpty ? nil : f.folderPath,
                             created: StudIPLibrary.unixTime(f.changed).flatMap { $0 > 0 ? $0 : nil },
                             media: url.map { [OpencastMedia(quality: "Original", height: 0, url: $0)] } ?? [],
                             source: OpencastVideo.sourceFile, size: f.size > 0 ? Int64(f.size) : nil)
    }
}

/// Links auf Videoplattformen in Texten (Kursbeschreibung, Sonstiges, Bloecke)
public enum VideoLinks {
    /// Rechnernamen (Teilwort) von Videoplattformen und Aufzeichnungsdiensten
    static let platforms = ["youtube.com", "youtu.be", "vimeo.com", "panopto", "ilias", "tib.eu", "opencast", "engage", "bigbluebutton",
                            "bbb", "zoom.us", "mediathek", "lecture2go", "twitch.tv", "dailymotion.com", "video.", "stream.", "media.",
                            "mediasite", "kaltura", "wistia", "loom.com", "peertube", "tube."]
    private static let urlPattern = PyRegex(#"https?://[^\s"'<>()\[\]]+"#, ignoreCase: true)

    /// Adresse einer Videoplattform, einer Aufzeichnung (BBB-Wiedergabe, Zoom-Aufzeichnung) oder Videodatei
    public static func isVideoPlatform(_ u: URL) -> Bool {
        guard let host = u.host?.lowercased() else { return false }
        if OpencastParser.isVideoFileURL(u) { return true }
        let path = u.path.lowercased()
        if host.contains("zoom.us") { return path.contains("/rec/") || path.contains("/play/") || path.contains("/share/") }
        if path.contains("/playback/") || path.contains("/recording") { return true }
        return platforms.contains { host == $0 || host.hasSuffix("." + $0) || host.contains($0) }
    }

    /// http(s)-Adressen eines Texts (auch aus `href="…"`), nur Videoplattformen, jede einmal, in Reihenfolge
    public static func links(in text: String) -> [URL] {
        var out: [URL] = []
        var seen = Set<String>()
        for raw in urlPattern.findAll(text) {
            var s = raw
            while let last = s.last, ".,;:!?".contains(last) { s.removeLast() }
            s = QISParser.decodeEntities(s)
            guard let u = URL(string: s), let scheme = u.scheme?.lowercased(), scheme == "https" || scheme == "http",
                  isVideoPlatform(u), seen.insert(u.absoluteString).inserted else { continue }
            out.append(u)
        }
        return out
    }

    /// Eintraege fuer die Aufzeichnungen: Titel aus Rechnername und Pfad ("youtube.com · watch"), Kennung "link:<n>"
    public static func videos(in text: String, idPrefix: String = "link") -> [OpencastVideo] {
        links(in: text).enumerated().map { i, u in
            OpencastVideo(id: "\(idPrefix):\(i + 1)", title: title(u), description: "Link aus der Kursbeschreibung",
                          source: OpencastVideo.sourceLink, linkURL: u)
        }
    }

    static func title(_ u: URL) -> String {
        let host = (u.host ?? "Link").lowercased().replacingOccurrences(of: "www.", with: "")
        let part = u.lastPathComponent
        guard !part.isEmpty, part != "/", part.count <= 40 else { return host }
        return "\(host) · \(part.removingPercentEncoding ?? part)"
    }
}

/// Video-, Audio-, Link-, iframe- und Embed-Bloecke der Courseware (Stud.IP 5/6) und der Opencast-Block des Plugins V3
public enum CoursewareMedia {
    /// Block-Arten mit Medien; dazu alles mit "video" oder "opencast" im Namen (Plugin-Bloecke wie plugin-opencast-video)
    static let types: Set<String> = ["video", "audio", "link", "iframe", "embed"]

    static func isMediaBlock(_ kind: String) -> Bool {
        types.contains(kind) || kind.contains("video") || kind.contains("opencast") || kind.contains("media")
    }

    /// Eintraege einer Courseware-Seite (`elementID`, `elementTitle`) aus ihren Bloecken (JSON:API `courseware-blocks`,
    /// Payload als Objekt oder JSON-Text). `base`: Stud.IP-Adresse fuer Seite und Dateien. Was kein Video ist (Textlinks
    /// auf andere Seiten, Audio ohne Datei), faellt weg.
    public static func videos(blocks: [JSONValue], courseID: String, elementID: String, elementTitle: String, base: String) -> [OpencastVideo] {
        var out: [OpencastVideo] = []
        var seen = Set<String>()
        var baseString = base
        while baseString.hasSuffix("/") { baseString.removeLast() }
        let studipHost = URL(string: baseString)?.host?.lowercased()
        let page = URL(string: StudIPTexts.coursewareURL(base, courseID, elementID))
        for (n, b) in blocks.enumerated() {
            let a = StudIPTexts.attrs(b)
            let kind = PyText.lower(StudIPTexts.text(a["block-type"]))
            guard isMediaBlock(kind) else { continue }
            let p = StudIPTexts.payload(a)
            let blockID = b["id"]?.string ?? b["id"]?.int.map(String.init) ?? "\(n + 1)"
            let id = "cw:\(elementID):\(blockID)"
            guard seen.insert(id).inserted else { continue }
            let own = StudIPTexts.squash(StudIPTexts.first(p, "title", "name", "label"))
            let title = own.isEmpty ? elementTitle : own
            let description = own.isEmpty || own == elementTitle ? nil : elementTitle
            let rawURL = ["url", "web_url", "target", "src", "href", "link"].compactMap { p[$0]?.string }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { $0.lowercased().hasPrefix("http") }
            let url = rawURL.flatMap { URL(string: $0) }
            let fileID = ["file_id", "file", "fileref_id"].compactMap { p[$0]?.string }.first { !$0.isEmpty }
            let token = p["token"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            var media: [OpencastMedia] = []
            var link: URL?
            if let fileID, kind != "link" {
                // Datei aus Stud.IP: Stream und Download ueber die JSON:API mit der Stud.IP-Sitzung
                if let u = URL(string: StudIPLibrary.downloadURL(base: URL(string: baseString) ?? URL(fileURLWithPath: "/"), fileID: fileID)) {
                    media = [OpencastMedia(quality: "Original", height: 0, url: u)]
                }
            }
            if let url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", let host = url.host?.lowercased() {
                if host == studipHost {
                    // Datei oder Seite in Stud.IP: die Courseware-Seite zeigt sie
                } else if media.isEmpty, scheme == "https", OpencastParser.isVideoFileURL(url) {
                    media = [OpencastMedia(quality: "Original", height: 0, url: url)]
                } else if kind == "video" || kind == "iframe" || kind == "embed" || VideoLinks.isVideoPlatform(url) {
                    link = url
                }
            }
            // Link-Block nur mit Videoplattform; Audio nur mit Datei; Opencast-Block des Plugins V3 (token) ueber die Seite
            if kind == "link", link == nil, media.isEmpty { continue }
            if kind == "audio", media.isEmpty { continue }
            if kind == "iframe" || kind == "embed", link == nil, media.isEmpty { continue }
            if kind.contains("opencast") || kind.contains("plugin") { guard token != nil || link != nil || !media.isEmpty else { continue } }
            if kind == "video", link == nil, media.isEmpty, token == nil, fileID == nil, url == nil { continue }
            out.append(OpencastVideo(id: id, title: title, description: description, playerURL: page, media: media,
                                     source: OpencastVideo.sourceCourseware, linkURL: link))
        }
        return out
    }
}
