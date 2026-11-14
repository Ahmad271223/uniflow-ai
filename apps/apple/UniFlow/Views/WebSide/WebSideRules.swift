import CryptoKit
import Foundation
import UniFlowCore

// Video und Lernseiten neben dem Dokument (Wunsch des Inhabers 14.11.2026, docs/VIDEO-LERNSEITEN-2026-11-14.md).
// Entscheidung des Inhabers: nur Lernseiten, KEIN freier Browser ("Uneingeschraenkter Webzugang" bleibt nein).
// Hier nur reine Regeln (ohne WebKit), damit sie sich vollstaendig testen lassen: welcher Link ein Video ist, welche
// Navigation in der Spalte bleiben darf, welche Lernseiten es gibt.

// MARK: - Video-Link

/// Ein einzelnes YouTube-Video aus einem eingefuegten Link. Andere Seiten, Playlists, Kanaele und Suchlinks werden
/// abgelehnt.
struct VideoLink: Equatable, Hashable, Codable, Sendable {
    /// YouTube-Kennung (11 Zeichen)
    let videoID: String
    /// Startzeit in Sekunden (aus `t=` bzw. `start=`), 0 = Anfang
    var start: Int = 0

    /// Hinweis bei einem Link, der kein Video ist
    static let rejectedText = "Nur YouTube-Links zu einem einzelnen Video oder Aufzeichnungen deiner Kurse."

    /// Absender der Player-Seite: YouTube verlangt fuer eingebettete Player einen erkennbaren Absender (Referer)
    static let playerOrigin = URL(string: "https://studinow.app")!
    /// Adresse der eigenen kleinen Player-Seite (Hauptrahmen); nur sie darf im Hauptrahmen laden
    static let playerPage = URL(string: "https://studinow.app/video-daneben")!

    private static let youTubeHosts: Set<String> = ["youtube.com", "www.youtube.com", "m.youtube.com",
                                                    "youtube-nocookie.com", "www.youtube-nocookie.com"]

    /// Link erkennen; Leerzeichen und fehlendes "https://" sind erlaubt
    static func parse(_ text: String) -> VideoLink? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count < 2_000 else { return nil }
        if !s.lowercased().hasPrefix("http://"), !s.lowercased().hasPrefix("https://") { s = "https://" + s }
        guard let c = URLComponents(string: s), let host = c.host?.lowercased(),
              ["http", "https"].contains(c.scheme?.lowercased() ?? "") else { return nil }
        let items = c.queryItems ?? []
        func q(_ name: String) -> String? { items.first { $0.name == name }?.value }
        let parts = c.path.split(separator: "/").map(String.init)
        var id: String?
        if host == "youtu.be" {
            id = parts.first
        } else if youTubeHosts.contains(host) {
            if parts.first == "watch" { id = q("v") }
            else if parts.count >= 2, ["embed", "shorts", "live", "v"].contains(parts[0]) { id = parts[1] }
        }
        guard let id, isVideoID(id) else { return nil }
        let start = (q("t") ?? q("start")).flatMap(seconds) ?? 0
        return VideoLink(videoID: id, start: start)
    }

    static func isVideoID(_ s: String) -> Bool {
        s.count == 11 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// "90", "90s", "1m30s", "1h2m3s" -> Sekunden; Unsinn -> nil
    static func seconds(_ s: String) -> Int? {
        if let n = Int(s), n >= 0 { return n }
        var total = 0, number = ""
        for ch in s.lowercased() {
            if ch.isNumber { number.append(ch); continue }
            guard let n = Int(number) else { return nil }
            switch ch {
            case "h": total += n * 3600
            case "m": total += n * 60
            case "s": total += n
            default: return nil
            }
            number = ""
        }
        guard number.isEmpty else { return nil }
        return total
    }

    /// Offizieller eingebetteter Player im datenschutzfreundlichen Modus (nur dieses Video, keine Vorschlaege anderer
    /// Kanaele am Ende)
    var embedURL: URL {
        var c = URLComponents(string: "https://www.youtube-nocookie.com/embed/\(videoID)")!
        var items = [URLQueryItem(name: "playsinline", value: "1"), URLQueryItem(name: "rel", value: "0"),
                     URLQueryItem(name: "enablejsapi", value: "1"),
                     URLQueryItem(name: "origin", value: Self.playerOrigin.absoluteString)]
        if start > 0 { items.append(URLQueryItem(name: "start", value: String(start))) }
        c.queryItems = items
        return c.url!
    }

    /// Dasselbe Video bei YouTube (zum Oeffnen ausserhalb der App)
    var watchURL: URL {
        URL(string: "https://www.youtube.com/watch?v=\(videoID)" + (start > 0 ? "&t=\(start)s" : ""))!
    }

    /// Kleine Player-Seite: nur das iframe des offiziellen Players, sonst nichts (kein Skript der App in der Seite)
    var playerHTML: String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
        <meta name="referrer" content="strict-origin-when-cross-origin">
        <style>html,body{margin:0;height:100%;background:#000}iframe{position:absolute;inset:0;width:100%;height:100%;border:0}</style>
        </head><body>
        <iframe src="\(embedURL.absoluteString)" title="YouTube-Video"
          allow="autoplay; encrypted-media; picture-in-picture; fullscreen" allowfullscreen
          referrerpolicy="strict-origin-when-cross-origin"></iframe>
        </body></html>
        """
    }
}

// MARK: - Entscheidung je Navigation

/// Was mit einer Navigation in der Spalte geschieht
enum WebSideDecision: Equatable {
    /// in der Spalte laden
    case allow
    /// nicht laden, ausserhalb der App oeffnen (Safari bzw. die App des Anbieters)
    case openOutside(URL)
    /// nicht laden, nichts tun (z. B. javascript:, Dateien, eingebettete fremde Rahmen)
    case cancel
}

enum WebSideHosts {
    /// Host passt zu einem Eintrag: genau gleich oder Unterdomain ("www.uni-hannover.de" passt zu "uni-hannover.de")
    static func matches(_ host: String?, _ allowed: [String]) -> Bool {
        guard let h = host?.lowercased(), !h.isEmpty else { return false }
        return allowed.contains { a in h == a || h.hasSuffix("." + a) }
    }

    /// Ausserhalb oeffnen, was ein Mensch oeffnen wuerde (Webseiten, Mail, Telefon); alles andere verwerfen
    static func outside(_ url: URL) -> WebSideDecision {
        ["http", "https", "mailto", "tel"].contains(url.scheme?.lowercased() ?? "") ? .openOutside(url) : .cancel
    }
}

/// Video-Spalte: im Hauptrahmen nur die eigene Player-Seite; im Rahmen des Players nur die Adressen des offiziellen
/// YouTube-Players (dazu Einwilligung und Werbung von Google, die nicht ausgeblendet werden duerfen). Jeder andere Weg
/// (YouTube-Logo, "Auf YouTube ansehen", Links) oeffnet ausserhalb der App.
enum VideoSidePolicy {
    static let playerFrameHosts = ["youtube-nocookie.com", "youtube.com", "google.com", "googlevideo.com", "ytimg.com",
                                   "doubleclick.net", "googlesyndication.com", "googleadservices.com", "gstatic.com"]

    static func decide(_ url: URL?, mainFrame: Bool) -> WebSideDecision {
        guard let url else { return .cancel }
        if url.absoluteString == "about:blank" || url.scheme == "about" { return .allow }
        if mainFrame {
            if url.scheme == "https", url.host == VideoLink.playerPage.host, url.path == VideoLink.playerPage.path { return .allow }
            return WebSideHosts.outside(url)
        }
        // im Rahmen des Players: Seiten des Players ja; die normale YouTube-Seite eines Videos nicht (das waere
        // YouTube mit Vorschlaegen und Suche)
        guard url.scheme == "https", WebSideHosts.matches(url.host, playerFrameHosts) else { return .cancel }
        if WebSideHosts.matches(url.host, ["youtube.com"]), !url.path.hasPrefix("/embed/") {
            return url.host == "consent.youtube.com" ? .allow : .openOutside(url)
        }
        return .allow
    }
}

// MARK: - Lernseiten

/// Eine erlaubte Lernseite (`packages/shared-contracts/learning-sites.json`)
struct LearningSite: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    /// university | library | reference | dictionary | tool | learning
    let kind: String
    /// nur fuer diese Hochschule (luh, hildesheim, hsh); nil = fuer alle
    var university: String?
    let start: URL
    let hosts: [String]

    /// Symbol der App (`UFIcon`) bzw. SF Symbol je Art
    var symbol: String {
        switch kind {
        case "university": return "building.columns"
        case "library": return "books.vertical"
        case "dictionary": return "character.book.closed"
        case "tool": return "function"
        case "learning": return "lightbulb"
        default: return "book"
        }
    }

    /// Eintrag brauchbar: Kennung, Name, nur https, Hosts ohne Platzhalter, Start auf einem eigenen Host
    var isValid: Bool {
        !id.isEmpty && !name.trimmingCharacters(in: .whitespaces).isEmpty && start.scheme == "https"
            && !hosts.isEmpty && hosts.allSatisfy(LearningSites.isPlainHost) && WebSideHosts.matches(start.host, hosts)
    }
}

/// Lernseite: im Hauptrahmen und in eingebetteten Rahmen nur die Hosts dieser Seite, nur https. Andere Seiten
/// oeffnen ausserhalb der App (Hauptrahmen) bzw. werden nicht geladen (eingebettete Rahmen).
enum LearningSitePolicy {
    static func decide(_ url: URL?, mainFrame: Bool, site: LearningSite) -> WebSideDecision {
        guard let url else { return .cancel }
        if url.scheme == "about" { return .allow }
        if url.scheme == "https", WebSideHosts.matches(url.host, site.hosts) { return .allow }
        if !mainFrame { return .cancel }
        // http auf einem erlaubten Host: in der Spalte nur ueber https (dieselbe Adresse)
        if url.scheme == "http", WebSideHosts.matches(url.host, site.hosts),
           var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            c.scheme = "https"
            return c.url.map(WebSideDecision.openOutside) ?? .cancel
        }
        return WebSideHosts.outside(url)
    }
}

enum LearningSites {
    /// Grundstock in der App (dieselbe Datei wie `packages/shared-contracts/learning-sites.json`, im Bundle)
    static let resourceName = "learning-sites"

    struct File: Codable { let version: Int; let sites: [LearningSite] }

    /// Host ohne Schema, Pfad, Platzhalter oder Leerzeichen, mit mindestens einem Punkt, klein geschrieben
    static func isPlainHost(_ h: String) -> Bool {
        !h.isEmpty && h == h.lowercased() && h.contains(".") && !h.hasPrefix(".") && !h.hasSuffix(".")
            && h.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }

    /// Liste lesen; ungueltige Eintraege fallen weg, doppelte Kennungen auch (erste gilt). nil = Datei unbrauchbar
    static func decode(_ data: Data) -> [LearningSite]? {
        guard let f = try? JSONDecoder().decode(File.self, from: data), f.version == 1 else { return nil }
        var seen = Set<String>()
        let sites = f.sites.filter { $0.isValid && seen.insert($0.id).inserted }
        return sites.isEmpty ? nil : sites
    }

    /// Grundstock aus dem Bundle der App
    static let builtIn: [LearningSite] = {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return decode(data) ?? []
    }()

    /// Seiten fuer eine Hochschule: allgemeine und die der gewaehlten Hochschule, Hochschule zuerst
    static func sites(for university: UniversityKey?, from all: [LearningSite] = builtIn) -> [LearningSite] {
        let own = all.filter { $0.university != nil && $0.university == university?.rawValue }
        return own + all.filter { $0.university == nil }
    }
}

// MARK: - Datenspeicher

/// Eigener Datenspeicher der Video- und Lernseiten-Spalten je Container, getrennt von den Hochschul-Anmeldungen
/// (`ContainerManager.websiteDataStore`): keine Uni-Cookies, kein Autologin, keine Zugangsdaten. Kennung aus der UUID
/// des Containers abgeleitet (feste Zuordnung, beim Loeschen des Containers mit entfernt).
enum WebSideStore {
    static func identifier(forContainer id: UUID) -> UUID {
        let d = Array(SHA256.hash(data: Data((id.uuidString + "|lernseiten").utf8)))
        var b = Array(d.prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50          // Version 5 (namensbasiert)
        b[8] = (b[8] & 0x3F) | 0x80          // Variante RFC 4122
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

// MARK: - Video-Link je Dokument (nur auf dem Geraet)

/// Zuletzt neben einem Dokument geoeffnetes Video, je Dokument in den Einstellungen des Containers (nie an den Dienst)
enum DocumentVideoLinks {
    static func key(_ fileID: String) -> String { "uniflow.videoDaneben." + fileID }

    static func load(_ fileID: String, defaults: UserDefaults?) -> VideoLink? {
        guard let d = defaults?.data(forKey: key(fileID)) else { return nil }
        return try? JSONDecoder().decode(VideoLink.self, from: d)
    }

    static func save(_ link: VideoLink?, for fileID: String, defaults: UserDefaults?) {
        guard let defaults else { return }
        if let link, let d = try? JSONEncoder().encode(link) { defaults.set(d, forKey: key(fileID)) } else { defaults.removeObject(forKey: key(fileID)) }
    }
}
