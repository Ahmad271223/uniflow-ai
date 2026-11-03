import Foundation
import XCTest
import UniFlowCore
@testable import UniFlow

/// Geraete-Probe (03.11.2026): laeuft NUR auf einem Geraet oder Simulator mit angemeldetem Stud.IP-Container und nur mit
/// der Umgebungsvariable `UF_DEVICE_PROBE=1` (Xcode: Schema → Test → Arguments → Environment; xcodebuild:
/// `TEST_RUNNER_UF_DEVICE_PROBE=1`). Sonst wird sie uebersprungen, damit kein Testlauf je zur Hochschule geht.
///
/// Prueft gegen die echte LUH, ausschliesslich GET mit dem gespeicherten Sitzungs-Cookie (nichts wird markiert,
/// geschrieben oder gespeichert; die Datenbank des Containers bleibt unberuehrt):
/// 1. Schwarzes Brett: Themenliste des Plugins und je Thema der RSS-Feed – Themen, Anzahl, die ersten drei Titel.
/// 2. Forum der JSON:API: je Kurs `courses/{id}/forum-categories` (Status, Anzahl), je Kategorie `forum-categories/{id}/entries`,
///    je Thema `forum-entries/{id}/entries` – damit der Koordinator sieht, warum das Forum leer kam (404 = noch keine
///    Kategorie im Kurs, 403 = Forum im Kurs aus).
/// 3. Blubber (`testBlubberCountsOnTheDevice`): nur Zahlen – Threads je Kontext-Art, je Thread der gewaehlten Kurse die
///    Zahl der Beitraege. Nie `courses/{id}/blubber-threads` (legt in Stud.IP einen Thread an, wenn der Kurs keinen hat).
/// Ausgabe im Testprotokoll, jede Zeile mit "[Probe]". Keine Personennamen (Titel von Anzeigen und Kursen, Zahlen, Status).
final class StudIPDeviceProbeTests: XCTestCase {

    private func say(_ s: String) {
        print("[Probe] " + s)
        NSLog("[Probe] %@", s)
    }

    /// Sitzungs-Cookies des ersten LUH-Containers auf diesem Geraet (Schluesselbund der App, Ordner der Container)
    private func luhCookies() -> [HTTPCookie] { luhContainer()?.cookies ?? [] }

    /// Erster LUH-Container mit Sitzung: Cookies und sein Ordner (fuer die Datenbank, nur lesend)
    private func luhContainer() -> (cookies: [HTTPCookie], root: URL)? {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: ContainerPaths.base, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            guard let id = UUID(uuidString: dir.lastPathComponent) else { continue }
            let all = StudIPCookieStore(container: id).load()
            say("Container \(id.uuidString.prefix(8)): \(all.count) Cookies")
            let cookies = all.filter { $0.domain.contains("uni-hannover") }
            // LUH heisst das Sitzungs-Cookie Studip_Session (03.11.2026), andere Stud.IP-Fassungen Seminar_Session
            if cookies.contains(where: { $0.name == "Seminar_Session" || $0.name == "Studip_Session" }) { return (cookies, dir) }
        }
        return nil
    }

    private func client() throws -> StudIPClient {
        guard ProcessInfo.processInfo.environment["UF_DEVICE_PROBE"] == "1" else {
            throw XCTSkip("Geräte-Probe nur mit UF_DEVICE_PROBE=1 auf dem angemeldeten iPad (TEST_RUNNER_UF_DEVICE_PROBE=1 bei xcodebuild)")
        }
        let cookies = luhCookies()
        guard !cookies.isEmpty else { throw XCTSkip("Kein angemeldeter Stud.IP-Container (LUH) auf diesem Gerät") }
        return StudIPClient(base: StudIPSync.base, transport: URLSessionStudIPTransport(cookies: cookies, host: StudIPSync.base.host ?? ""))
    }

    private func status(_ error: Error) -> String {
        if case StudIPError.http(let s, _) = error { return "HTTP \(s)" }
        if case StudIPError.sessionExpired = error { return "Sitzung abgelaufen" }
        return "\(error)"
    }

    func testBulletinBoardAndForumOnTheDevice() async throws {
        let client = try client()

        // 0. Nachrichten (nur Liste, nie Einzelansicht; nur Anzahl und Absender-Art, kein Inhalt)
        do {
            let uid = try await client.currentUserID()
            let j = try await client.json("jsonapi.php/v1/users/\(uid)/inbox?page[limit]=100")
            let data = j["data"]?.array ?? []
            let unread = data.filter { $0["attributes"]?["is-read"]?.bool == false }.count
            let system = data.filter { ($0["relationships"]?["sender"]?["data"]?["id"]?.string ?? "").contains("system") }.count
            say("Nachrichten: \(data.count) in der Liste (Gesamt laut Stud.IP \(j["meta"]?["page"]?["total"]?.int ?? -1)), ungelesen \(unread), Systemnachrichten \(system)")
        } catch { say("Nachrichten: \(status(error))") }

        // 1. Schwarzes Brett
        let d = await StudIPBulletin.fetch(client: client, missing: [:], lastFetchedAt: nil, clock: .system)
        XCTAssertFalse(d.sessionExpired, "Stud.IP-Sitzung abgelaufen: in der App neu anmelden")
        say("Schwarzes Brett: \(d.topics.count) Themen, \(d.entries?.count ?? -1) Anzeigen gelesen"
            + (d.feedUnavailable ? " – RSS im Plugin abgeschaltet" : "") + (d.missing[StudIPBulletin.missingName] != nil ? " – Plugin nicht gefunden (404/keine Themenliste)" : ""))
        for t in d.topics {
            let titles = (d.entries ?? []).filter { $0.topic == t.title }
            say("Thema „\(t.title)“ – laut Stud.IP \(t.count), gelesen \(titles.count): "
                + titles.prefix(3).map { "„\($0.title)“ (\($0.postedAt))" }.joined(separator: ", "))
        }
        XCTAssertFalse(d.topics.isEmpty, "Themenliste nicht gefunden: plugins.php/schwarzesbrettplugin/category/list ohne <ul class=\"sb-categories\">")
        XCTAssertGreaterThan(d.entries?.count ?? 0, 0, "kein RSS-Eintrag gelesen")

        // 2. Forum (JSON:API), nur GET
        let uid = try await client.currentUserID()
        let courses = try await client.courses(userID: uid)
        say("Forum: \(courses.count) Kurse")
        var withCategories = 0, entriesTotal = 0
        for c in courses.prefix(40) {
            do {
                let cats = try await client.json("jsonapi.php/v1/courses/\(c.id)/forum-categories?page[limit]=50")["data"]?.array ?? []
                withCategories += 1
                var line = "Kurs „\(c.title)“: forum-categories 200 (\(cats.count))"
                for cat in cats.prefix(3) {
                    guard let catID = cat["id"]?.string else { continue }
                    do {
                        let entries = try await client.json("jsonapi.php/v1/forum-categories/\(catID)/entries?page[limit]=50")["data"]?.array ?? []
                        entriesTotal += entries.count
                        line += " · Kategorie: \(entries.count) Themen"
                        if let first = entries.first, let eid = first["id"]?.string {
                            do {
                                let posts = try await client.json("jsonapi.php/v1/forum-entries/\(eid)/entries?page[limit]=100")["data"]?.array ?? []
                                line += " (erstes Thema: \(posts.count) Antworten)"
                            } catch {
                                line += " (erstes Thema: Antworten \(status(error)))"
                            }
                        }
                    } catch {
                        line += " · Kategorie: entries \(status(error))"
                    }
                }
                say(line)
            } catch {
                say("Kurs „\(c.title)“: forum-categories \(status(error))")
            }
        }
        say("Forum: \(withCategories) Kurse mit Kategorien, \(entriesTotal) Themen insgesamt")
    }

    /// Blubber: nur Zahlen, nur die Routen, die die App nutzt (`blubber-threads`, `blubber-threads/{id}/comments`), ohne
    /// Text und ohne Namen. Danach einmal der Abruf der App (`StudIPBlubber.fetch`) ohne Speichern.
    func testBlubberCountsOnTheDevice() async throws {
        // GET blubber-threads raeumt in Stud.IP leere Threads auf: nur, wenn Blubber eingeschaltet ist
        guard StudIPBlubber.syncEnabled else { throw XCTSkip("Blubber ist aus (StudIPBlubber.syncEnabled)") }
        let client = try client()
        let uid = try await client.currentUserID()
        let courses = try await client.courses(userID: uid)
        let ids = Set(courses.map(\.id))
        do {
            let j = try await client.json("jsonapi.php/v1/blubber-threads?page[limit]=\(StudIPBlubber.maxThreads * 3)")
            let data = j["data"]?.array ?? []
            var kinds: [String: Int] = [:]
            for t in data { kinds[t["attributes"]?["context-type"]?.string ?? "?", default: 0] += 1 }
            say("Blubber: blubber-threads 200, \(data.count) Threads (" + kinds.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") + ")")
            var asked = 0
            for t in data {
                guard let tid = t["id"]?.string, asked < StudIPBlubber.maxThreads else { continue }
                let cid = t["relationships"]?["context"]?["data"]?["id"]?.string ?? ""
                guard tid == "global" || ids.contains(cid) else { continue }
                asked += 1
                let title = courses.first { $0.id == cid }?.title ?? "Stud.IP-weit"
                do {
                    let c = try await client.json("jsonapi.php/v1/blubber-threads/\(tid)/comments?page[limit]=100")
                    say("Blubber „\(title)“: \(c["data"]?.array?.count ?? -1) Beiträge (Seite), letzte Aktivität \(t["attributes"]?["latest-activity"]?.string ?? "?")")
                } catch {
                    say("Blubber „\(title)“: comments \(status(error))")
                }
            }
        } catch {
            say("Blubber: blubber-threads \(status(error))")
        }
        let d = await StudIPBlubber.fetch(client: client, userID: uid, courseIDs: Array(ids), missing: [:], known: [:], today: UniFlowClock.system.today)
        say("Blubber-Abruf der App: \(d.threads?.count ?? -1) Threads, \(d.posts.values.reduce(0) { $0 + $1.count }) Beiträge, \(d.requests) Anfragen"
            + (d.sessionExpired ? " – Sitzung abgelaufen" : "") + (d.missing[StudIPBlubber.missingName] != nil ? " – Route fehlt (404/403)" : ""))
        XCTAssertFalse(d.sessionExpired, "Stud.IP-Sitzung abgelaufen: in der App neu anmelden")
    }

    /// Alle JSON:API-Routen dieser Stud.IP-Installation (discovery) und je Route, ob sie fuer dieses Konto antwortet
    /// (nur GET mit page[limit]=1, nur Status und Anzahl, kein Inhalt). Keine HTML-Seiten: Kurs- und Startseiten
    /// koennten in Stud.IP "gesehen"-Marken setzen.
    func testStudIPSurveyOnTheDevice() async throws {
        let client = try client()
        let uid = try await client.currentUserID()
        let disco = try await client.json("jsonapi.php/v1/discovery")
        var routes: [(String, String)] = []
        for r in disco["data"]?.array ?? [] {
            let path = r["attributes"]?["pattern"]?.string ?? r["id"]?.string ?? ""
            let methods = r["attributes"]?["methods"]?.array?.compactMap(\.string).joined(separator: ",") ?? (r["attributes"]?["method"]?.string ?? "")
            routes.append((path, methods))
        }
        if routes.isEmpty { say("Discovery: Format unbekannt: \(String(describing: disco).prefix(400))") }
        let gets = routes.filter { $0.1.uppercased().contains("GET") || $0.1.isEmpty }.map(\.0)
        say("Discovery: \(routes.count) Routen, davon GET \(gets.count)")
        for g in gets.sorted() { say("Route GET \(g)") }
        // Kurse fuer Kurs-Routen: zwei aktuelle
        let courses = (try? await client.courses(userID: uid)) ?? []
        let sample = courses.prefix(2).map(\.id)
        var tried = 0
        for g in gets.sorted() {
            guard tried < 220 else { say("… Abbruch nach 220 Abrufen"); break }
            var path = g.hasPrefix("/") ? String(g.dropFirst()) : g
            if path.hasPrefix("v1/") { path = String(path.dropFirst(3)) }
            // courses/{id}/blubber-threads legt in Stud.IP den Standard-Thread des Kurses an, wenn es keinen gibt
            // (BlubberThread::findByContext): kein reiner Lesezugriff, darum nie
            if path.contains("blubber-threads"), path.hasPrefix("courses/") || path.hasPrefix("institutes/") { continue }
            if path.contains("{") || path.contains(":") || path.contains("(") {
                // nur Nutzer- und Kurs-Muster mit genau einem Platzhalter einsetzen
                let placeholders = path.components(separatedBy: "/").filter { $0.hasPrefix("{") || $0.hasPrefix(":") || $0.hasPrefix("(") }
                guard placeholders.count == 1 else { continue }
                if path.hasPrefix("users/") { path = path.replacingOccurrences(of: placeholders[0], with: uid) }
                else if path.hasPrefix("courses/"), let c = sample.first { path = path.replacingOccurrences(of: placeholders[0], with: c) }
                else { continue }
            }
            tried += 1
            let sep = path.contains("?") ? "&" : "?"
            do {
                let j = try await client.json("jsonapi.php/v1/\(path)\(sep)page[limit]=1")
                let total = j["meta"]?["page"]?["total"]?.int
                let n = j["data"]?.array?.count
                say("OK  \(g) → " + (total.map { "\($0) Einträge" } ?? n.map { "\($0) Einträge (Seite)" } ?? "Objekt"))
            } catch {
                say("--  \(g) → \(status(error))")
            }
        }
    }

    // MARK: - Aufzeichnungen (03.11.2026): wo liegen die Vorlesungsvideos der Kurse?

    /// Sitzungs- und Sicherheitswerte aus HTML fuers Protokoll entfernen (Cookies, CSRF-Token, Signaturen)
    private func scrub(_ html: String) -> String {
        var s = html
        for pattern in [#"((?:Seminar|Studip)_Session|security_token|_token|token|sig|signature|key)(["']?\s*[=:]\s*["']?)[^&"'\s<>]+"#,
                        #"([?&](?:token|sig|signature|key|t)=)[^&"'\s<>]+"#] {
            s = s.replacingOccurrences(of: pattern, with: "$1$2…", options: [.regularExpression, .caseInsensitive])
        }
        return s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    /// Wie oft ein Muster vorkommt (ohne Gross-/Kleinschreibung)
    private func count(_ pattern: String, in s: String) -> Int {
        (try? NSRegularExpression(pattern: pattern, options: .caseInsensitive))?.numberOfMatches(in: s, range: NSRange(s.startIndex..., in: s)) ?? 0
    }

    /// Rohe Hinweise auf Videos in einer Seite
    private func hints(_ html: String) -> [(String, Int)] {
        [("<video", #"<video\b"#), ("<source", #"<source\b"#), (".mp4", #"\.mp4"#), (".m3u8", #"\.m3u8"#), ("opencast", "opencast"),
         ("episode", "episode"), ("player", "player"), ("<iframe", #"<iframe\b"#), ("media-table-row", "media-table-row"),
         ("data-video*", #"data-[a-z-]*(video|episode|event|media)[a-z-]*="#), ("pagination", "pagination"),
         ("series", "series"), ("playlist", "playlist"), ("json-in-script", #"<script[^>]*>[^<]{0,200}[\[{]"#)]
            .map { ($0.0, count($0.1, in: html)) }
    }

    /// Links zu Videoplattformen in einem Text (nur Rechnernamen)
    private func platformHosts(_ text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        let re = try? NSRegularExpression(pattern: #"https?://[^\s"'<>)\]]+"#, options: .caseInsensitive)
        let urls = re?.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } } ?? []
        let platforms = ["youtube", "youtu.be", "vimeo", "panopto", "ilias", "tib.eu", "opencast", "bbb", "bigbluebutton", "zoom", "engage", ".mp4", "stream", "video"]
        return urls.compactMap { u -> String? in
            let l = u.lowercased()
            guard platforms.contains(where: { l.contains($0) }) else { return nil }
            return (URL(string: u)?.host ?? "?") + (l.contains("/rec/") || l.contains("playback") ? " (Aufzeichnung)" : "")
        }
    }

    private func host(_ s: String?) -> String { s.flatMap { URL(string: $0)?.host } ?? (s?.isEmpty == false ? "(relativ)" : "-") }

    /// Lesender Rundgang: je Kurs (a) Opencast-Seiten des LUH-Plugins und Kursueberblick (Status, Laenge, Videos laut Parser,
    /// rohe Hinweise; Anfang der bereinigten Seite, wenn der Parser weniger findet als die Hinweise), dazu die Routen des
    /// Opencast-Plugins V3 (`plugins.php/opencastv3/api/courses/{id}/videos`, GET), (b) Videodateien im Dateibaum (JSON:API),
    /// (c) Courseware-Bloecke der Art video/link/iframe/embed/audio/plugin-*, (d) Links zu Videoplattformen in Beschreibung
    /// und Sonstiges, (e) der Stand der lokalen Tabelle `opencast_videos` (nur SELECT). Keine Player-Seiten, keine Downloads,
    /// nie `blubber-threads`.
    func testRecordingsOnTheDevice() async throws {
        let client = try client()
        let container = luhContainer()
        let uid = try await client.currentUserID()
        let courses = try await client.courses(userID: uid)
        say("Aufzeichnungen: \(courses.count) Kurse (höchstens 40 geprüft)")
        var parserTotal = 0, hintCourses = 0, fileVideosTotal = 0, cwMediaTotal = 0, v3Total = 0, localTotal = 0
        let videoExt = [".mp4", ".m4v", ".mov", ".webm", ".mkv", ".avi", ".wmv", ".m3u8"]

        // (e) lokale Tabelle (nur lesen)
        var local: [String: [(String, Int, Int, Int)]] = [:]           // Kurs -> (source, Anzahl, gone, geladen)
        if let root = container?.root {
            let dbURL = DataContainerLayout.Folder.database.url(in: root).appendingPathComponent("uniflow.sqlite")
            do {
                let conn = try SQLiteConnection(path: dbURL.path)
                let cols = try conn.columnNames("opencast_videos")
                if cols.isEmpty {
                    say("Lokal: Tabelle opencast_videos gibt es noch nicht")
                } else {
                    let src = cols.contains("source") ? "COALESCE(source, 'opencast')" : "'opencast'"
                    for r in try conn.rows("SELECT course_id, \(src) AS source, COUNT(*) AS n, SUM(gone) AS gone, SUM(local_path IS NOT NULL) AS loaded FROM opencast_videos GROUP BY course_id, source") {
                        local[r["course_id"]?.string ?? "", default: []].append((r["source"]?.string ?? "?", r["n"]?.int ?? 0, r["gone"]?.int ?? 0, r["loaded"]?.int ?? 0))
                    }
                    let states = try conn.rows("SELECT status, COUNT(*) AS n FROM opencast_courses GROUP BY status")
                    say("Lokal: opencast_courses " + states.map { "\($0["status"]?.string ?? "?") \($0["n"]?.int ?? 0)" }.joined(separator: ", ")
                        + "; Spalten opencast_videos: \(cols.joined(separator: ","))")
                }
            } catch { say("Lokal: Datenbank nicht lesbar (\(error))") }
        } else {
            say("Lokal: kein Container-Ordner gefunden")
        }

        for c in courses.prefix(40) {
            say("— Kurs „\(c.title)“ (\(c.semesterTitle ?? "?"))")
            // (a) LUH-Plugin: Aufzeichnungsseite
            do {
                let r = try await client.htmlPage(OpencastParser.mediaIndexPath(courseID: c.id))
                let html = String(decoding: r.body, as: UTF8.self)
                let page = r.finalURL.flatMap { $0.host?.lowercased() == StudIPSync.base.host?.lowercased() ? $0 : nil } ?? StudIPSync.base
                let listing = OpencastParser.parse(html: html, status: r.status, pageURL: page)
                var found = -1
                switch listing {
                case .videos(let v): found = v.count; parserTotal += v.count
                case .noOpencast: found = -2
                case .unrecognized: found = -1
                }
                let h = hints(html)
                let more = OpencastParser.furtherPages(html: html, courseID: c.id, pageURL: page)
                say("  media/index: HTTP \(r.status), \(r.body.count) Bytes, Ziel \(r.finalURL?.path ?? "-"), Parser: "
                    + (found == -2 ? "kein Opencast" : found == -1 ? "unklar" : "\(found) Videos") + ", weitere Seiten/Reiter: \(more.count)"
                    + (more.isEmpty ? "" : " [" + more.prefix(5).map { scrub($0) }.joined(separator: " | ") + "]"))
                say("  Hinweise: " + h.filter { $0.1 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: ", "))
                let rows = h.first { $0.0 == "media-table-row" }?.1 ?? 0
                let strong = h.filter { ["<video", "<source", ".mp4", ".m3u8", "episode", "<iframe", "data-video*"].contains($0.0) }.reduce(0) { $0 + $1.1 }
                if max(found, 0) < rows || (found <= 0 && strong > 0) || (!more.isEmpty && found >= 0) {
                    hintCourses += 1
                    say("  Seite (bereinigt, 1500 Zeichen): " + String(scrub(html).prefix(1500)))
                }
            } catch { say("  media/index: \(status(error))") }
            // (a) Kursueberblick: Navigation
            do {
                let o = try await client.htmlPage(OpencastParser.overviewPath(courseID: c.id))
                let html = String(decoding: o.body, as: UTF8.self)
                let oc = OpencastParser.opencastLinks(overviewHTML: html)
                say("  overview: HTTP \(o.status), \(o.body.count) Bytes, Kursüberblick \(OpencastParser.isCourseOverview(html: html, finalURL: o.finalURL, courseID: c.id)), "
                    + "Reiter Aufzeichnungen \(OpencastParser.courseHasRecordings(overviewHTML: html)), V3-Plugin \(OpencastParser.courseHasOpencastV3(overviewHTML: html)); Links: "
                    + oc.prefix(6).map { "„\($0.label)“ → \(scrub($0.href.replacingOccurrences(of: c.id, with: "<cid>")))" }.joined(separator: " | "))
            } catch { say("  overview: \(status(error))") }
            // (a) Opencast-Plugin V3: JSON-Routen (nur GET)
            for prefix in OpencastV3.pluginPrefixes {
                do {
                    let r = try await client.jsonPage(OpencastV3.videosPath(prefix: prefix, courseID: c.id, offset: 0))
                    guard r.isJSON, let j = try? JSONValue.parse(r.body) else {
                        say("  \(prefix)/api/courses/{id}/videos: HTTP \(r.status), \(r.contentType.isEmpty ? "ohne Inhaltstyp" : r.contentType), \(r.body.count) Bytes")
                        continue
                    }
                    let videos = j["videos"]?.array ?? j.array ?? []
                    v3Total += videos.count
                    let first = videos.first
                    let keys = first?.object?.keys.sorted().joined(separator: ",") ?? "-"
                    let downloads = first?["publication"]?["downloads"]?.object?.map { "\($0.key): \(($0.value.object ?? [:]).map { "\($0.key)→\($0.value["info"]?.string ?? "?")" }.joined(separator: " "))" }.joined(separator: "; ") ?? "-"
                    say("  \(prefix)/api/courses/{id}/videos: \(videos.count) Videos (count \(j["count"]?.int ?? -1)); Felder: \(keys); downloads: \(downloads); "
                        + "preview: \(host(first?["preview"]?["player"]?.string ?? first?["preview"]?["search"]?.string)); track_link: \(host(first?["publication"]?["track_link"]?.string))")
                    let parsed = OpencastV3.videos(from: j, courseID: c.id, base: StudIPSync.base, prefix: prefix)
                    say("  V3-Leser: \(parsed.count) Videos, davon mit Datei \(parsed.filter { !$0.media.isEmpty }.count), mit Player \(parsed.filter { $0.playerURL != nil }.count)")
                    let p = try await client.jsonPage(OpencastV3.playlistsPath(prefix: prefix, courseID: c.id))
                    say("  \(prefix)/api/courses/{id}/playlists: HTTP \(p.status), " + (p.isJSON ? "\((try? JSONValue.parse(p.body))?.array?.count ?? (try? JSONValue.parse(p.body))?["playlists"]?.array?.count ?? -1) Playlists" : "kein JSON"))
                    break
                } catch { say("  \(prefix)/api: \(status(error))") }
            }
            // (b) Dateibaum
            do {
                let listing = try await client.fileListing(courseID: c.id)
                let videos = listing.files.filter { f in
                    let n = f.name.lowercased()
                    return videoExt.contains { n.hasSuffix($0) } || (f.mimeType ?? "").lowercased().hasPrefix("video/")
                }
                fileVideosTotal += videos.count
                say("  Dateien: \(listing.files.count) gesamt, \(videos.count) Videodateien" + (listing.unreadableFolders > 0 ? ", \(listing.unreadableFolders) Ordner nicht lesbar" : "")
                    + (videos.isEmpty ? "" : ": " + videos.prefix(8).map { "„\($0.name)“ \(RecordingFiles.megabytes(Int64($0.size))) \($0.mimeType ?? "?")\($0.isDownloadable ? "" : " (nicht ladbar)") [\($0.folderPath)]" }.joined(separator: " | ")))
                let links = listing.files.filter { $0.linkURL != nil }
                if !links.isEmpty { say("  Link-Dateien: " + links.prefix(6).map { "„\($0.name)“ → \(host($0.linkURL))" }.joined(separator: " | ")) }
            } catch { say("  Dateien: \(status(error))") }
            // (c) Courseware-Bloecke
            do {
                let units = try await client.json("jsonapi.php/v1/courses/\(c.id)/courseware-units?include=structural-element&page[limit]=50")
                var elements = (units["data"]?.array ?? []).compactMap { $0["relationships"]?["structural-element"]?["data"]?["id"]?.string }
                var seen = Set<String>(), kinds: [String: Int] = [:], media: [String] = []
                var i = 0
                while i < elements.count, seen.count < 25 {
                    let eid = elements[i]
                    i += 1
                    guard seen.insert(eid).inserted else { continue }
                    let cont = try await client.json("jsonapi.php/v1/courseware-structural-elements/\(eid)/containers?include=blocks&page[limit]=100")
                    for b in cont["included"]?.array ?? [] where b["type"]?.string == "courseware-blocks" {
                        let a = b["attributes"] ?? .null
                        let kind = a["block-type"]?.string ?? "?"
                        kinds[kind, default: 0] += 1
                        let p: [String: JSONValue] = a["payload"]?.object ?? (a["payload"]?.string.flatMap { try? JSONValue.parse(Data($0.utf8)) }?.object ?? [:])
                        if ["video", "link", "iframe", "embed", "audio"].contains(kind) || kind.hasPrefix("plugin") {
                            let url = ["url", "web_url", "target", "src", "href"].compactMap { p[$0]?.string }.first { !$0.isEmpty }
                            media.append("\(kind){\(p.keys.sorted().joined(separator: ","))} url→\(host(url)) file_id:\(p["file_id"]?.string?.isEmpty == false ? "ja" : "nein") source:\(p["source"]?.string ?? p["type"]?.string ?? "-")")
                        }
                    }
                    if seen.count < 25, let kids = try? await client.json("jsonapi.php/v1/courseware-structural-elements/\(eid)/children?page[limit]=100")["data"]?.array {
                        elements += kids.compactMap { $0["id"]?.string }
                    }
                }
                cwMediaTotal += media.count
                say("  Courseware: \(seen.count) Seiten, Blöcke: " + kinds.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
                    + (media.isEmpty ? "" : "; Medien: " + media.prefix(10).joined(separator: " | ")))
                let cw = CoursewareMedia.videos(blocks: (try? await client.json("jsonapi.php/v1/courseware-structural-elements/\(elements.first ?? "-")/containers?include=blocks&page[limit]=100"))?["included"]?.array?.filter { $0["type"]?.string == "courseware-blocks" } ?? [],
                                                courseID: c.id, elementID: elements.first ?? "-", elementTitle: "Seite", base: StudIPSync.base.absoluteString)
                if !cw.isEmpty { say("  Courseware-Leser (erste Seite): \(cw.count) Einträge: " + cw.prefix(5).map { "„\($0.title)“ \($0.source) media \($0.media.count) link \(host($0.linkURL?.absoluteString))" }.joined(separator: " | ")) }
            } catch { say("  Courseware: \(status(error))") }
            // (d) Beschreibung und Sonstiges
            let hosts = platformHosts(c.description) + platformHosts(c.miscellaneous)
            say("  Beschreibung: \(c.description?.count ?? 0) Zeichen, Sonstiges: \(c.miscellaneous?.count ?? 0) Zeichen, Video-Links: "
                + (hosts.isEmpty ? "keine" : hosts.joined(separator: ", ")) + "; Leser: \(VideoLinks.links(in: (c.description ?? "") + "\n" + (c.miscellaneous ?? "")).count)")
            // (e) lokal
            let l = local[c.id] ?? []
            localTotal += l.reduce(0) { $0 + $1.1 }
            say("  Lokal: " + (l.isEmpty ? "keine Einträge" : l.map { "\($0.0) \($0.1) (nicht mehr gelistet \($0.2), geladen \($0.3))" }.joined(separator: ", ")))
        }
        say("Zusammenfassung: Parser \(parserTotal) Opencast-Videos (LUH-Plugin), \(hintCourses) Kurse mit mehr Hinweisen als Videos, "
            + "V3-Plugin \(v3Total) Videos, \(fileVideosTotal) Videodateien im Dateibaum, \(cwMediaTotal) Medienblöcke in Courseware, lokal \(localTotal) Einträge")
    }
}
