import CryptoKit
import Foundation
import UniFlowCore

// Video und Lernseiten neben dem Dokument (Wunsch des Inhabers 14.11.2026, docs/VIDEO-LERNSEITEN-2026-11-14.md).
// Entscheidung des Inhabers: nur Lernseiten, KEIN freier Browser ("Uneingeschraenkter Webzugang" bleibt nein).
// Auftrag 17.11.2026: YouTube selbst in der Spalte oeffnen (suchen, ansehen), weiter ohne Adresszeile und nur YouTube
// (`YouTubeSidePolicy`); der eingefuegte Link bleibt als zweiter Weg.
// 18.11.2026: "YouTube öffnen" in 1.0.6 ausgeschaltet (Schalter `YouTubeBrowse`, Entscheidung des Inhabers).
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

    /// Dasselbe Video auf der mobilen YouTube-Seite (Spalte "YouTube", `YouTubeSidePolicy`)
    var mobileWatchURL: URL {
        URL(string: "https://m.youtube.com/watch?v=\(videoID)" + (start > 0 ? "&t=\(start)s" : ""))!
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
    /// nicht laden, Hinweis zeigen: Anmelden (Google-Konto) geht in der Spalte nicht - die App sieht nie ein Passwort
    case signIn
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

// MARK: - YouTube direkt (Auftrag 17.11.2026)

/// "YouTube öffnen" (die YouTube-Seite selbst in der Spalte bzw. ueber dem Dokument am iPhone) ein oder aus.
///
/// Entscheidung des Inhabers 18.11.2026: kommt NOCH NICHT in Version 1.0.6 ("Noch nicht"), weil sonst Altersfreigabe,
/// Werbe-Angabe und Datenschutztext bei Apple geaendert werden muessten.
///
/// `false` (Standard): kein Knopf "YouTube öffnen" (iPad/Mac in der Auswahl der Spalte, iPhone im Blatt "Video oder
/// Lernseite"), kein Hinweis "YouTube ist ein Dienst von Google …", nie die Spalte mit der mobilen YouTube-Seite - auch
/// nicht ueber "Zuletzt hier" (ein dort angesehenes Video oeffnet im eingebetteten Player) oder einen gespeicherten
/// Stand aus der Testfassung. "YouTube-Link einfügen" ist wieder der Haupteinstieg wie in 1.0.5; Aufzeichnungen,
/// "Auf YouTube öffnen (außerhalb)" und die Lernseiten bleiben. Der Code bleibt, damit es spaeter wieder eingeschaltet
/// werden kann. `true`: wie am 17.11.2026 (Build 45).
enum YouTubeBrowse {
    static var enabled = false

    /// Nur Debug-Builds: `-UFYouTubeBrowse YES` schaltet "YouTube öffnen" fuer UI-Tests ein (`UniFlowApp.init`, wie
    /// `LearnCalendar.applyDebugLaunch`); ohne das Argument gilt der ausgelieferte Standard
    static func applyDebugLaunch(defaults d: UserDefaults = .standard) {
        #if DEBUG
        if d.object(forKey: "UFYouTubeBrowse") != nil { enabled = d.bool(forKey: "UFYouTubeBrowse") }
        #endif
    }
}

/// Spalte "YouTube": die mobile YouTube-Seite selbst (Start, Suche, Video, Kanal), ohne Adresszeile. Im Hauptrahmen nur
/// YouTube und dessen Einwilligungsseite; jede andere Seite oeffnet ausserhalb der App. Anmelden (Google-Konto) wird in
/// der Spalte nie geladen. Eingebettete Rahmen nur von YouTube/Google (Player, Einwilligung, Werbung - sie duerfen nicht
/// ausgeblendet werden). Bilder, Skripte und Videodaten (ytimg, googlevideo, gstatic) laedt die Seite als
/// Unterressourcen selbst; dazu fragt WebKit die App nicht.
enum YouTubeSidePolicy {
    /// Startseite der Spalte (mobile Seite: passt in eine schmale Spalte)
    static let start = URL(string: "https://m.youtube.com/")!

    /// Seiten im Hauptrahmen: genau diese Hosts. Andere Unterdomains (music., studio., kids., tv.) sind eigene Dienste
    /// und oeffnen ausserhalb.
    static let pageHosts: Set<String> = ["m.youtube.com", "www.youtube.com", "youtube.com", "youtu.be", "consent.youtube.com"]

    /// Eingebettete Rahmen und Unterressourcen von YouTube/Google (Host oder Unterdomain)
    static let resourceHosts = ["youtube.com", "youtube-nocookie.com", "google.com", "googlevideo.com", "ytimg.com", "ggpht.com",
                                "gstatic.com", "googleusercontent.com", "doubleclick.net", "googlesyndication.com",
                                "googleadservices.com"]

    /// Anmeldung bei Google bzw. Kontoverwaltung: Host "accounts.google.*", "accounts.youtube.com", "myaccount.google.com"
    /// oder der YouTube-Pfad "/signin…"
    static func isSignIn(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        if host.hasPrefix("accounts.google.") || host == "accounts.youtube.com" || host == "myaccount.google.com" { return true }
        guard pageHosts.contains(host) else { return false }
        let first = url.path.split(separator: "/").first.map { $0.lowercased() } ?? ""
        return first.hasPrefix("signin")
    }

    static func decide(_ url: URL?, mainFrame: Bool) -> WebSideDecision {
        guard let url else { return .cancel }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "about" { return .allow }
        // javascript:, data:, file:, blob:, App-Schemata: nie laden; Mail und Telefon ausserhalb
        guard scheme == "https" || scheme == "http" else { return mainFrame ? WebSideHosts.outside(url) : .cancel }
        if isSignIn(url) { return mainFrame ? .signIn : .cancel }
        let host = url.host?.lowercased() ?? ""
        guard mainFrame else {
            return scheme == "https" && WebSideHosts.matches(host, resourceHosts) ? .allow : .cancel
        }
        guard pageHosts.contains(host) else { return .openOutside(url) }
        // http auf YouTube: in der Spalte nur ueber https (dieselbe Adresse, ausserhalb - wie bei den Lernseiten)
        if scheme == "http" {
            guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return .cancel }
            c.scheme = "https"
            return c.url.map(WebSideDecision.openOutside) ?? .cancel
        }
        // "/redirect?q=…": YouTubes Weiterleitung zu einer fremden Seite (Links in Beschreibungen) - ausserhalb
        if url.path.split(separator: "/").first?.lowercased() == "redirect" { return .openOutside(url) }
        return .allow
    }

    /// Unterressource (Bild, Skript, Videodaten) von YouTube/Google? Nur zur Einordnung und fuer Tests: WebKit laedt
    /// Unterressourcen ohne Rueckfrage, die App blendet nichts aus (auch keine Werbung).
    static func isResource(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https" else { return false }
        return WebSideHosts.matches(url.host, resourceHosts)
    }

    /// Video, das gerade auf der YouTube-Seite offen ist ("/watch?v=…"), zum Merken am Dokument. Kurzvideos (Shorts),
    /// Kanaele und Suchseiten werden nicht gemerkt.
    static func watchedVideo(_ url: URL?) -> VideoLink? {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), pageHosts.contains(host),
              host != "consent.youtube.com", url.path == "/watch" else { return nil }
        return VideoLink.parse(url.absoluteString)
    }
}

/// Ein Besuch der Spalte "YouTube" neben einem Dokument: Startseite oder das zuletzt dort angesehene Video
struct YouTubeVisit: Equatable, Hashable, Sendable {
    /// Dokument, an dem das zuletzt angesehene Video gemerkt wird
    let documentID: String
    /// zuletzt angesehenes Video ("Zuletzt hier"); nil = Startseite
    var video: VideoLink?

    var startURL: URL { video?.mobileWatchURL ?? YouTubeSidePolicy.start }
}

/// Hinweis vor dem ersten "YouTube öffnen" (Daten gehen an Google). Die Entscheidung wird je Container gemerkt, nur auf
/// dem Geraet. Solange sie fehlt, entsteht keine Web-Ansicht - es geht also vorher nichts an YouTube.
enum YouTubeNotice {
    static let key = "uniflow.youtubeDaneben.hinweisOK"
    static let title = "YouTube öffnen?"
    static let text = "YouTube ist ein Dienst von Google. Wenn du YouTube öffnest, werden Daten an Google übertragen, "
        + "zum Beispiel deine IP-Adresse, Angaben zu deinem Gerät und was du suchst und ansiehst. "
        + "Über Cookies und Einwilligung entscheidest du auf der Seite von YouTube selbst."
    static let detail = "StudiNow erfährt nicht, was du suchst oder ansiehst. Anmelden mit einem Google-Konto geht hier nicht."

    static func accepted(defaults: UserDefaults?) -> Bool { defaults?.bool(forKey: key) ?? false }
    static func accept(defaults: UserDefaults?) { defaults?.set(true, forKey: key) }
    static func reset(defaults: UserDefaults?) { defaults?.removeObject(forKey: key) }
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
    /// Gespeicherte Daten von YouTube/Google in diesem Speicher (Name eines Eintrags = Domain, z. B. "youtube.com") -
    /// fuer "YouTube-Daten löschen" in der Spalte
    static func isYouTubeData(_ domain: String) -> Bool {
        WebSideHosts.matches(domain.lowercased(), YouTubeSidePolicy.resourceHosts + ["youtu.be"])
    }

    static func identifier(forContainer id: UUID) -> UUID {
        let d = Array(SHA256.hash(data: Data((id.uuidString + "|lernseiten").utf8)))
        var b = Array(d.prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50          // Version 5 (namensbasiert)
        b[8] = (b[8] & 0x3F) | 0x80          // Variante RFC 4122
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

// MARK: - Video je Dokument (nur auf dem Geraet)

/// Gemerktes Video zu einem Dokument. `marks` bereitet "Zeit merken" vor (Stelle im Video je Notizseite, zweiter Schritt
/// laut Entscheidung des Inhabers 14.11.2026): heute leer, das Format traegt es schon, damit spaeter nichts umgebaut
/// werden muss.
struct DocumentVideoRecord: Codable, Equatable, Sendable {
    /// Stelle im Video zu einer Seite (Seitenschluessel des Dokuments bzw. Blatts daneben)
    struct Mark: Codable, Equatable, Sendable {
        var pageKey: String
        var seconds: Int
    }

    var version = 1
    var link: VideoLink
    var marks: [Mark] = []
    /// auf der YouTube-Seite in der Spalte gefunden (17.11.2026): "Zuletzt hier" oeffnet es wieder dort; nil/false = aus
    /// einem eingefuegten Link (eingebetteter Player)
    var onYouTube: Bool?
}

/// Zuletzt neben einem Dokument geoeffnetes Video, je Dokument in den Einstellungen des Containers (nie an den Dienst,
/// kein Abgleich zwischen Geraeten - Entscheidung des Inhabers 14.11.2026)
enum DocumentVideoLinks {
    static func key(_ fileID: String) -> String { "uniflow.videoDaneben." + fileID }

    static func record(_ fileID: String, defaults: UserDefaults?) -> DocumentVideoRecord? {
        guard let d = defaults?.data(forKey: key(fileID)) else { return nil }
        if let r = try? JSONDecoder().decode(DocumentVideoRecord.self, from: d), r.version == 1 { return r }
        // erste Fassung (nur der Link)
        return (try? JSONDecoder().decode(VideoLink.self, from: d)).map { DocumentVideoRecord(link: $0) }
    }

    static func load(_ fileID: String, defaults: UserDefaults?) -> VideoLink? { record(fileID, defaults: defaults)?.link }

    /// Neues Video: Zeitmarken eines anderen Videos fallen weg; dasselbe Video behaelt sie. `onYouTube`: auf der
    /// YouTube-Seite in der Spalte angesehen (sonst eingefuegter Link)
    static func save(_ link: VideoLink?, for fileID: String, defaults: UserDefaults?, onYouTube: Bool = false) {
        guard let defaults else { return }
        guard let link else { defaults.removeObject(forKey: key(fileID)); return }
        var r = record(fileID, defaults: defaults) ?? DocumentVideoRecord(link: link)
        if r.link.videoID != link.videoID { r.marks = [] }
        r.link = link
        r.onYouTube = onYouTube ? true : nil
        if let d = try? JSONEncoder().encode(r) { defaults.set(d, forKey: key(fileID)) }
    }
}
