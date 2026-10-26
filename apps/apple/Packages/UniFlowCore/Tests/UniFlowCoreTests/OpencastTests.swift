import Foundation
import XCTest
@testable import UniFlowCore

// Opencast-Aufzeichnungen: erfundene Seiten nach dem Aufbau der LUH-Seite media/index (docs/QIS-STUDIP-STRUKTUR.md,
// Abschnitt Opencast) aus packages/shared-contracts/fixtures/opencast, Rechner *.example.test, keine echten Namen,
// Titel oder Kennungen. Abruf mit festen Antworten, Ablage in einer Datenbank im Arbeitsspeicher, Ordnung nach Fach
// (Modul) und Lehrwoche wie im Moduldetail, Vorschlag zu Dokument und Lernpaket nur bei sicherem Treffer, Laden nur
// auf Wunsch. Uhr eingefroren: Dienstag, 10.11.2026 (Semesterbeginn der Daten: Montag, 12.10.2026).

private func fixture(_ name: String) throws -> String {
    // .../apps/apple/Packages/UniFlowCore/Tests/UniFlowCoreTests/OpencastTests.swift -> Repository-Wurzel
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return try String(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/opencast/\(name)"), encoding: .utf8)
}

private let clock = UniFlowClock.fixed(berlin: "2026-11-10T12:00:00")!
private let base = URL(string: "https://studip.example.test")!

/// Unix-Zeit eines Tages in Berlin (Mittag)
private func unix(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Int {
    BerlinClock.utcSeconds(day: BerlinClock.dayNumber(year: y, month: m, day: d), minutes: hour * 60)
}

private func page(_ html: String, status: Int = 200, path: String? = nil) -> HTTPReply {
    HTTPReply(status: status, contentType: "text/html; charset=UTF-8", finalURL: path.flatMap { URL(string: "https://studip.example.test/" + $0) },
              body: Data(html.utf8))
}

/// Feste Seiten je Pfad mit Abfrage (ohne Host); andere Pfade 404. Merkt sich jede angefragte Adresse.
private final class PageTransport: StudIPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let routes: [String: HTTPReply]
    private var log: [URL] = []

    init(_ routes: [String: HTTPReply]) { self.routes = routes }

    var requested: [URL] { lock.lock(); defer { lock.unlock() }; return log }

    func get(_ url: URL, accept: String?) async throws -> HTTPReply {
        record(url)
        var key = url.path
        if let q = url.query { key += "?" + q }
        return routes[key] ?? HTTPReply(status: 404, contentType: "text/html", body: Data("<html>Nicht gefunden</html>".utf8))
    }

    private func record(_ url: URL) { lock.lock(); log.append(url); lock.unlock() }   // synchron: Sperre nicht ueber await
}

private func mediaPath(_ course: String) -> String { "/" + OpencastParser.mediaIndexPath(courseID: course) }
private func overviewPath(_ course: String) -> String { "/" + OpencastParser.overviewPath(courseID: course) }

// MARK: - Seite lesen

final class OpencastParserTests: XCTestCase {

    func testVideosFixture() throws {
        guard case .videos(let v) = OpencastParser.parse(html: try fixture("media-index-videos.html"), status: 200,
                                                         pageURL: URL(string: "https://studip.example.test/plugins.php/opencastpluginluh/media/index?cid=x")) else {
            return XCTFail("keine Videos erkannt")
        }
        XCTAssertEqual(v.map(\.id), ["aaaaaaaa-0000-4000-8000-000000000001", "aaaaaaaa-0000-4000-8000-000000000002", "Xyzab-12345-6789"])

        let a = v[0]
        XCTAssertEqual(a.title, "3. Vorlesung vom 06.11.2026 – Grenzwerte & Folgen")         // &ndash; und &amp;
        XCTAssertNil(a.description)                                                          // leerer div
        XCTAssertEqual(a.duration, 1 * 3600 + 28 * 60 + 59)
        XCTAssertEqual(a.author, "Prof. Dr. Erika Beispiel")
        XCTAssertEqual(a.created, 1_793_955_600)                                             // data-sort-value
        XCTAssertEqual(BerlinClock.isoDate(BerlinClock.local(utc: a.created!).day), "2026-11-06")
        XCTAssertEqual(a.thumbnailURL?.absoluteString,
                       "https://oc.example.test/static/org/engage-player/aaaaaaaa-0000-4000-8000-000000000001/bbbbbbbb-0000-4000-8000-000000000001/vorschau_3.000s-player.jpg")
        XCTAssertEqual(a.playerURL?.absoluteString,                                          // ohne "#ts="
                       "https://studip.example.test/plugins.php/opencastpluginluh/media/player/aaaaaaaa-0000-4000-8000-000000000001?cid=0123456789abcdef0123456789abcdef")
        XCTAssertEqual(a.media.map(\.quality), ["1080p", "720p", "480p"])
        XCTAssertEqual(a.media.map(\.height), [1080, 720, 480])
        XCTAssertEqual(a.media("720p")?.url.lastPathComponent, "res0720.mp4")

        let b = v[1]
        XCTAssertEqual(b.title, "Zentralübung 02")
        XCTAssertEqual(b.description, "Besprechung von Übungsblatt 2: Induktion und Ungleichungen")
        XCTAssertNil(b.author)                                                               // "-"
        XCTAssertEqual(b.duration, 35 * 60 + 48)
        XCTAssertEqual(b.media.map(\.quality), ["720p", "480p"])                              // 1080p fehlt
        XCTAssertNil(b.media("1080p"))

        let c = v[2]
        XCTAssertEqual(c.id, "Xyzab-12345-6789")                                             // kurze Kennung
        XCTAssertEqual(c.title, "02. Vorlesungswoche - Ergänzung zu Teil 2 (Video aus SoSe 21)")
        XCTAssertEqual(c.description, "Korrektur eines Rechenfehlers bei der LR-Zerlegung")
        XCTAssertEqual(c.author, "Dr. Max Muster")
        XCTAssertEqual(c.created, 1_649_932_712)
        XCTAssertEqual(c.thumbnailURL?.pathExtension, "png")
        XCTAssertTrue(c.playerURL?.path.hasSuffix("/media/player/Xyzab-12345-6789") ?? false)
    }

    func testEmptyTableIsOpencastWithoutVideos() throws {
        XCTAssertEqual(OpencastParser.parse(html: try fixture("media-index-empty.html"), status: 200), .videos([]))
    }

    func testMissingNavigationIsNoOpencast() throws {
        let p = try fixture("media-index-no-plugin.html")
        XCTAssertEqual(OpencastParser.parse(html: p, status: 500), .noOpencast)
        XCTAssertEqual(OpencastParser.parse(html: p, status: 200), .noOpencast)
        XCTAssertEqual(OpencastParser.parse(html: "<html><body>Nicht gefunden</body></html>", status: 404), .noOpencast)
        // andere Fehlerseiten sagen nichts ueber den Kurs
        XCTAssertEqual(OpencastParser.parse(html: "<html><body>Wartungsarbeiten</body></html>", status: 503), .unrecognized)
        XCTAssertEqual(OpencastParser.parse(html: "<html><body>Fehler!</body></html>", status: 500), .unrecognized)
        XCTAssertEqual(OpencastParser.parse(html: "<html><body><p>Startseite</p></body></html>", status: 200), .unrecognized)
    }

    func testMalformedHTML() {
        // offene tr/td, Grossbuchstaben, Attribute ohne Anfuehrungszeichen, relative Links, Entities in Attributen,
        // Kommentar und Skript mit Tabellen-Text
        let p = """
        <TABLE class="default media-table"><TBODY>
        <!-- <tr class="media-table-row" id="kommentar"> -->
        <script>var s = '<tr class="media-table-row" id="skript">';</script>
        <TR CLASS=media-table-row ID=Abc-1>
          <TD><DIV class=thumb-container style="background-image:url(/thumb/a.jpg)"></DIV>
          <TD><div class="media-table-infos"><div><A HREF="/plugins.php/opencastpluginluh/media/player/Abc-1?cid=k1&amp;x=1">Vorlesung&nbsp;4 &#8211; Reihen &lt;Teil 1&gt;</A></div>
              <div>Zeile eins<br>Zeile &quot;zwei&quot;</div></div>
          <TD class="media-table-duration" data-sort-value="45:10">45:10
          <TD class=media-table-lecturer>  Dr.   Erika   Beispiel
          <TD class="media-table-created">13.11.2026
          <TD class=actions><a href="https://oc.example.test/v/a-720.mp4">Download: 720p</a><a href='https://oc.example.test/v/a-audio.m4a'>Download: Audio</a>
              <a href="mailto:hilfe@example.test">Problem melden</a>
        <TR class="media-table-row" id="Abc-2"><td><div class="media-table-infos"><div><a href="player/Abc-2">Zweites</a></div></div>
        </TBODY></TABLE>
        """
        guard case .videos(let v) = OpencastParser.parse(html: p, status: 200, pageURL: URL(string: "https://studip.example.test/plugins.php/opencastpluginluh/media/index?cid=k1")) else {
            return XCTFail("keine Videos")
        }
        XCTAssertEqual(v.map(\.id), ["Abc-1", "Abc-2"])
        XCTAssertEqual(v[0].title, "Vorlesung 4 – Reihen <Teil 1>")
        XCTAssertEqual(v[0].description, "Zeile eins\nZeile \"zwei\"")
        XCTAssertEqual(v[0].duration, 45 * 60 + 10)
        XCTAssertEqual(v[0].author, "Dr. Erika Beispiel")
        XCTAssertEqual(v[0].created, unix(2026, 11, 13))                                      // Text, ohne data-sort-value
        XCTAssertEqual(v[0].thumbnailURL?.absoluteString, "https://studip.example.test/thumb/a.jpg")
        XCTAssertEqual(v[0].playerURL?.absoluteString, "https://studip.example.test/plugins.php/opencastpluginluh/media/player/Abc-1?cid=k1&x=1")
        XCTAssertEqual(v[0].media.map(\.quality), ["720p"])                                   // Audio ist keine Videodatei
        XCTAssertNil(v[1].duration)
        XCTAssertEqual(v[1].playerURL?.absoluteString, "https://studip.example.test/plugins.php/opencastpluginluh/media/player/Abc-2")
        XCTAssertTrue(v[1].media.isEmpty)
    }

    func testForeignAndPlainHTTPHostsAreIgnored() {
        // Player fremder Hosts nie (Webansicht mit Stud.IP-Sitzung); Videodateien und Vorschau nur https vom Videoserver
        let p = """
        <table class="media-table"><tbody>
        <tr class="media-table-row" id="v1"><td><div class="thumb-container" style="background-image:url('https://oc.example.test/t1.jpg')"></div>
          <td><div class="media-table-infos"><div><a href="https://studip.example.test/plugins.php/opencastpluginluh/media/player/v1">Eins</a></div></div>
          <td class="actions"><a href="https://oc.example.test/v1-720.mp4">Download: 720p</a>
            <a href="http://oc.example.test/v1-480.mp4">Download: 480p</a>
            <a href="https://fremd.example.org/v1-1080.mp4">Download: 1080p</a>
        <tr class="media-table-row" id="v2"><td><div class="thumb-container" style="background-image:url('https://fremd.example.org/t2.jpg')"></div>
          <td><div class="media-table-infos"><div><a href="https://fremd.example.org/plugins.php/opencastpluginluh/media/player/v2">Zwei</a></div></div>
          <td class="actions"><a href="https://oc.example.test/v2-720.mp4">Download: 720p</a>
        <tr class="media-table-row" id="v3"><td><div class="thumb-container" style="background-image:url('http://oc.example.test/t3.jpg')"></div>
          <td><div class="media-table-infos"><div><a href="http://studip.example.test/plugins.php/opencastpluginluh/media/player/v3">Drei</a></div></div>
        </tbody></table>
        """
        guard case .videos(let v) = OpencastParser.parse(html: p, status: 200, pageURL: URL(string: "https://studip.example.test/plugins.php/opencastpluginluh/media/index?cid=k1")) else {
            return XCTFail("keine Videos")
        }
        XCTAssertEqual(v.map(\.id), ["v1", "v2", "v3"])
        XCTAssertEqual(v[0].media.map(\.url.absoluteString), ["https://oc.example.test/v1-720.mp4"])
        XCTAssertEqual(v[0].thumbnailURL?.absoluteString, "https://oc.example.test/t1.jpg")
        XCTAssertEqual(v[0].playerURL?.host, "studip.example.test")
        XCTAssertNil(v[1].playerURL)                                                        // fremder Host
        XCTAssertNil(v[1].thumbnailURL)
        XCTAssertEqual(v[1].media.map(\.quality), ["720p"])
        XCTAssertNil(v[2].playerURL)                                                        // http statt https
        XCTAssertNil(v[2].thumbnailURL)
    }

    func testOverviewNavigationAndLoginPage() throws {
        let withTab = """
        <ul id="tabs"><li><a href="/dispatch.php/course/overview?cid=k1">Übersicht</a></li>
        <li><a href="/plugins.php/opencastpluginluh/media/index?cid=k1"><span>Aufzeichnungen</span></a></li></ul>
        """
        XCTAssertTrue(OpencastParser.courseHasRecordings(overviewHTML: withTab))
        XCTAssertTrue(OpencastParser.courseHasRecordings(overviewHTML: #"<nav><a href="/x">Aufzeichnungen</a></nav>"#))
        XCTAssertFalse(OpencastParser.courseHasRecordings(overviewHTML: #"<ul><li><a href="/dispatch.php/course/files?cid=k1">Dateien</a></li></ul>"#))

        XCTAssertTrue(OpencastParser.looksLikeLoginPage(#"<form action="https://studip.example.test/dispatch.php/login" method=post><input type="text" name="loginname"><INPUT TYPE=PASSWORD name=password></form>"#))
        XCTAssertTrue(OpencastParser.looksLikeLoginPage(#"<form action="https://sso.example.test/idp/profile/SAML2/Redirect/SSO"></form>"#))
        XCTAssertFalse(OpencastParser.looksLikeLoginPage(try fixture("media-index-videos.html")))
        XCTAssertFalse(OpencastParser.looksLikeLoginPage(try fixture("media-index-no-plugin.html")))
    }

    func testDurationText() {
        XCTAssertEqual(OpencastParser.seconds("01:28:59"), 5339)
        XCTAssertEqual(OpencastParser.seconds("05:46"), 346)
        XCTAssertNil(OpencastParser.seconds("lang"))
        XCTAssertNil(OpencastParser.seconds("1:-2:3"))
        XCTAssertNil(OpencastParser.seconds("1::3"))
    }

    /// Derselbe Leser fuer QIS und Opencast: Rohtext von script/style/title, Kommentare weg, Entities dekodiert
    func testSharedTokenizer() {
        let t = HTMLTokenizer.tokens(#"<P CLASS=a>x &amp; y<!-- <b>nein</b> --><script>if (a<b) {}</script><title>A &amp; B</title></p><BR/>"#)
        XCTAssertEqual(t, [.start("p", ["class": "a"]), .text("x & y"), .raw("script", "if (a<b) {}"), .raw("title", "A &amp; B"),
                           .end("p"), .start("br", [:])])
        XCTAssertEqual(HTMLScanner.scan("<title>A &amp; B</title><table><tr><td>1</td></tr></table>").title, "A & B")
    }
}

// MARK: - Abruf im Stud.IP-Abgleich

private let courses = [
    StudIPCourse(id: "c-ana", title: "Testanalysis I", semesterTitle: "WiSe 2026/27"),
    StudIPCourse(id: "c-ana-ue", title: "Übung Testanalysis I", semesterTitle: "WiSe 2026/27"),
    StudIPCourse(id: "c-prog", title: "Testprogrammierung", semesterTitle: "WiSe 2026/27"),
    StudIPCourse(id: "c-erst", title: "Begrüßung der Erstsemester", semesterTitle: "WiSe 2026/27"),
]

/// Seiten der vier Kurse: Analysis mit Videos, Uebung ohne Videos, Programmierung ohne Opencast (500), Begruessung
/// unklar (Wartungsseite, Kursueberblick mit Reiter)
private func routes(_ replace: [String: HTTPReply] = [:]) throws -> [String: HTTPReply] {
    var r: [String: HTTPReply] = [
        mediaPath("c-ana"): page(try fixture("media-index-videos.html"), path: OpencastParser.mediaIndexPath(courseID: "c-ana")),
        mediaPath("c-ana-ue"): page(try fixture("media-index-empty.html")),
        mediaPath("c-prog"): page(try fixture("media-index-no-plugin.html"), status: 500),
        mediaPath("c-erst"): page("<html><body>Wartungsarbeiten</body></html>", status: 503),
        overviewPath("c-erst"): page(#"<ul><li><a href="/plugins.php/opencastpluginluh/media/index?cid=c-erst">Aufzeichnungen</a></li></ul>"#),
    ]
    for (k, v) in replace { r[k] = v }
    return r
}

private func fetch(_ replace: [String: HTTPReply] = [:], known: [String: OpencastCourseState] = [:],
                   transport: StudIPTransport? = nil) async throws -> (OpencastFetch, PageTransport?) {
    let t = try PageTransport(routes(replace))
    let client = StudIPClient(base: base, transport: transport ?? t, pauseMillis: 0)
    return (await OpencastStore.fetch(client: client, courses: courses, known: known, now: unix(2026, 11, 10)), transport == nil ? t : nil)
}

final class OpencastFetchTests: XCTestCase {

    func testFetchReadsEachCourseAndSkipsErrorsQuietly() async throws {
        let (f, t) = try await fetch()
        guard case .videos(let v)? = f.listings["c-ana"] else { return XCTFail("Analysis ohne Videos") }
        XCTAssertEqual(v.count, 3)
        XCTAssertNotNil(v[0].playerURL, "Player auf dem Stud.IP-Host bleibt")
        XCTAssertEqual(f.listings["c-ana-ue"], .videos([]))
        XCTAssertEqual(f.listings["c-prog"], .noOpencast, "HTTP 500 'navigation item not found' ist kein Fehler")
        XCTAssertNil(f.listings["c-erst"], "unklare Seite mit Reiter im Kursueberblick: alter Stand bleibt")
        XCTAssertEqual(f.failed, ["c-erst"])
        XCTAssertFalse(f.sessionExpired)
        XCTAssertFalse(f.unreachable)
        // nur die Listen: nie eine Videodatei, nie der Videoserver (Laden nur auf Wunsch)
        let urls = try XCTUnwrap(t).requested
        XCTAssertEqual(urls.map(\.path), ["/plugins.php/opencastpluginluh/media/index", "/plugins.php/opencastpluginluh/media/index",
                                          "/plugins.php/opencastpluginluh/media/index", "/plugins.php/opencastpluginluh/media/index",
                                          "/dispatch.php/course/overview"])
        XCTAssertTrue(urls.allSatisfy { $0.host == "studip.example.test" && $0.pathExtension != "mp4" })
    }

    func testCourseWithoutOpencastIsRecheckedOnlyAfterSevenDays() async throws {
        let now = unix(2026, 11, 10)
        let (f, t) = try await fetch(known: ["c-prog": OpencastCourseState(status: "none", checkedAt: now - 2 * 86400),
                                             "c-ana": OpencastCourseState(status: "available", checkedAt: now - 60)])
        XCTAssertEqual(f.skipped, ["c-prog"])
        XCTAssertFalse(try XCTUnwrap(t).requested.contains { $0.query?.contains("cid=c-prog") ?? false })
        XCTAssertNotNil(f.listings["c-ana"], "Kurs mit Reiter jedes Mal")
        XCTAssertTrue(OpencastStore.needsCheck(OpencastCourseState(status: "none", checkedAt: now - 7 * 86400), now: now))
        XCTAssertTrue(OpencastStore.needsCheck(OpencastCourseState(status: "none", checkedAt: now + 3600), now: now), "Uhr zurueckgestellt")
        XCTAssertTrue(OpencastStore.needsCheck(nil, now: now))
    }

    func testLoginPageMeansSessionExpired() async throws {
        let login = page(#"<form action="/dispatch.php/login" method="post"><input type="password" name="password"></form>"#)
        let (f, t) = try await fetch([mediaPath("c-ana-ue"): login])
        XCTAssertTrue(f.sessionExpired)
        XCTAssertNotNil(f.listings["c-ana"], "schon gelesene Kurse bleiben")
        XCTAssertEqual(try XCTUnwrap(t).requested.count, 2, "danach keine Anfrage mehr")
    }

    func testNetworkErrorStopsTheFetch() async throws {
        let failing = FailingTransport(URLError(.timedOut))
        let (f, _) = try await fetch(known: ["c-prog": OpencastCourseState(status: "none", checkedAt: unix(2026, 11, 9))], transport: failing)
        XCTAssertTrue(f.unreachable)
        XCTAssertEqual(f.failed, ["c-ana", "c-ana-ue", "c-erst"], "der Rest gilt als nicht gelesen, c-prog war nicht dran")
        XCTAssertEqual(failing.requested.count, 1, "nach dem Zeitlimit keine weitere Anfrage")
        XCTAssertTrue(f.listings.isEmpty)
    }

    /// Kursueberblick mit Kursnavigation (erfunden nach dem Aufbau der Stud.IP-Reiter)
    private func overview(_ course: String, tabs: [(String, String)] = []) -> HTTPReply {
        let links = ([("dispatch.php/course/overview", "Übersicht"), ("dispatch.php/course/files", "Dateien")] + tabs)
            .map { #"<li><a href="/\#($0.0)?cid=\#(course)">\#($0.1)</a></li>"# }.joined()
        return page(#"<html><body><nav><ul id="tabs">\#(links)</ul></nav><h1>Kursüberblick</h1></body></html>"#,
                    path: OpencastParser.overviewPath(courseID: course))
    }

    /// Ersatzweg Kursueberblick: nur der sichere Kursueberblick ohne Reiter heisst "kein Opencast"
    func testOnlyTheRealCourseOverviewMeansNoOpencast() async throws {
        let unclear = page("<html><body>Wartungsarbeiten</body></html>", status: 503)
        let (f, _) = try await fetch([mediaPath("c-erst"): unclear, overviewPath("c-erst"): overview("c-erst")])
        XCTAssertEqual(f.listings["c-erst"], .noOpencast, "Kursueberblick mit Navigation, ohne Reiter")

        let withTab = overview("c-erst", tabs: [("plugins.php/opencastpluginluh/media/index", "Aufzeichnungen")])
        let (g, _) = try await fetch([mediaPath("c-erst"): unclear, overviewPath("c-erst"): withTab])
        XCTAssertNil(g.listings["c-erst"])

        // Navigation eines anderen Kurses bzw. Adresse einer anderen Seite: nichts daraus schliessen
        let other = overview("c-ana")
        let moved = page(#"<ul><li><a href="/dispatch.php/course/files?cid=c-erst">Dateien</a></li></ul>"#, path: "dispatch.php/course/details?cid=c-erst")
        for reply in [other, moved] {
            let (h, _) = try await fetch([mediaPath("c-erst"): unclear, overviewPath("c-erst"): reply])
            XCTAssertNil(h.listings["c-erst"])
            XCTAssertTrue(h.failed.contains("c-erst"))
        }
    }

    /// Zwischenseite mit HTTP 200 (Nutzungsbedingungen, Wartung, Systemhinweis) statt Liste und Kursueberblick: der Kurs
    /// gilt als nicht gelesen, nie als "kein Opencast"; gespeicherte Videos und gemerkte Stellen bleiben
    func testIntermediatePageIsNoProofOfMissingOpencast() async throws {
        let terms = page(#"<html><body><h1>Nutzungsbedingungen</h1><form action="/dispatch.php/terms" method="post"><button>Akzeptieren</button></form></body></html>"#,
                         path: "dispatch.php/terms")
        let maintenance = page("<html><body><p>Das System befindet sich im Wartungsmodus.</p></body></html>")
        for reply in [terms, maintenance] {
            let client = StudIPClient(base: base, transport: PageTransport([mediaPath("k1"): reply, overviewPath("k1"): reply]), pauseMillis: 0)
            let listing = try await client.opencastListing(courseID: "k1")
            XCTAssertNil(listing)
        }

        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let db = backend.context.database
        try await db.transaction { try StudIPLibrary.storeCourses($0, courses, startedAt: clock.nowISO) }
        let (first, _) = try await fetch()
        _ = try await db.transaction { try OpencastStore.store(first, in: $0, clock: clock) }
        try await db.transaction { c in
            try OpencastStore.savePosition(c, courseID: "c-ana", videoID: "Xyzab-12345-6789", seconds: 300)
            try OpencastStore.setLocal(c, courseID: "c-ana", videoID: "aaaaaaaa-0000-4000-8000-000000000002", path: "StudIP/Aufzeichnungen/v2.mp4", quality: "480p")
        }
        let known = try await db.withConnection { try OpencastStore.courseStates($0) }
        var replies: [String: HTTPReply] = [:]
        for c in courses { replies[mediaPath(c.id)] = terms; replies[overviewPath(c.id)] = terms }
        let (second, t) = try await fetch(replies, known: known)
        XCTAssertTrue(second.listings.isEmpty, "\(second.listings)")
        XCTAssertEqual(second.skipped, ["c-prog"])
        XCTAssertEqual(second.failed, ["c-ana", "c-ana-ue", "c-erst"])
        XCTAssertFalse(try XCTUnwrap(t).requested.contains { $0.path.hasSuffix("/course/overview") && ($0.query ?? "").contains("cid=c-ana") },
                       "Kurse mit Reiter brauchen den Ersatzweg nie")
        _ = try await db.transaction { try OpencastStore.store(second, in: $0, clock: clock) }
        let rows = try await db.rows("SELECT id, gone, position FROM opencast_videos WHERE course_id='c-ana' ORDER BY id")
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { $0["gone"] == 0 })
        XCTAssertEqual(rows.first { $0["id"] == "Xyzab-12345-6789" }?["position"], 300)
        let states = try await db.withConnection { try OpencastStore.courseStates($0) }
        XCTAssertEqual(states["c-ana"]?.status, "available")
        XCTAssertTrue(OpencastStore.needsCheck(states["c-ana"], now: unix(2026, 11, 13)))
    }

    /// Ein Kurs mit Reiter wird nur durch die ausdrueckliche Meldung des Plugins zu "kein Opencast"
    func testCourseWithTabBecomesNoneOnlyByTheExplicitMessage() async throws {
        let known = ["c-ana": OpencastCourseState(status: "available", checkedAt: unix(2026, 11, 9))]
        let notFound = HTTPReply(status: 404, contentType: "text/html", body: Data("<html>Nicht gefunden</html>".utf8))
        let (f, t) = try await fetch([mediaPath("c-ana"): notFound, overviewPath("c-ana"): overview("c-ana")], known: known)
        XCTAssertNil(f.listings["c-ana"])
        XCTAssertTrue(f.failed.contains("c-ana"))
        XCTAssertFalse(try XCTUnwrap(t).requested.contains { $0.path.hasSuffix("/course/overview") && ($0.query ?? "").contains("cid=c-ana") })
        let (g, _) = try await fetch([mediaPath("c-ana"): page(try fixture("media-index-no-plugin.html"), status: 500)], known: known)
        XCTAssertEqual(g.listings["c-ana"], .noOpencast)
        // unbekannter Kurs: 404 heisst weiter "kein Opencast"
        let (h, _) = try await fetch([mediaPath("c-ana"): notFound])
        XCTAssertEqual(h.listings["c-ana"], .noOpencast)
    }
}

// MARK: - Ablage, Ordnung nach Fach und Lehrwoche, Vorschlag

/// Datenbank wie nach einem Stud.IP-Abgleich: vier Kurse (Analysis mit Uebung = ein Modul, Programmierung, Begruessung
/// ohne Modul) und Dateien ab dem 12.10.2026; dazu die Aufzeichnungen aus den erfundenen Seiten.
private func seededBackend(extraVideos: [String: [OpencastVideo]] = [:],
                           extraFiles: [(String, String, String, Int)] = []) async throws -> LocalBackend {
    let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
    let files: [(String, String, String, Int)] = [
        ("f-orga", "c-ana", "Organisatorisches.pdf", unix(2026, 10, 13)),
        ("f-ue-intro", "c-ana-ue", "Hinweise zur Übung.pdf", unix(2026, 10, 14)),
        ("f-prog-1", "c-prog", "Folien 01.pdf", unix(2026, 10, 14)),
        ("f-blatt2", "c-ana-ue", "Blatt02.pdf", unix(2026, 10, 23)),
        ("f-vl4", "c-ana", "VL04 Analysis.pdf", unix(2026, 11, 3)),
        ("f-blatt6", "c-ana-ue", "Uebungsblatt 6.pdf", unix(2026, 11, 9)),
        ("f-prog-4", "c-prog", "Folien 04.pdf", unix(2026, 11, 3)),
        ("f-erst", "c-erst", "Infos.pdf", unix(2026, 10, 12)),
    ] + extraFiles
    try await backend.context.database.transaction { c in
        try StudIPLibrary.storeCourses(c, courses, startedAt: clock.nowISO)
        for (id, course, name, chdate) in files {
            try c.execute("INSERT INTO files(id, course_id, name, chdate, kind) VALUES (?,?,?,?,'pdf')",
                          [.text(id), .text(course), .text(name), .integer(Int64(chdate))])
        }
        try LocalModules.ensureModules(c, clock: clock)
    }
    var (fetched, _) = try await fetch()
    for (course, list) in extraVideos { fetched.listings[course] = .videos(list) }
    let f = fetched
    _ = try await backend.context.database.transaction { try OpencastStore.store(f, in: $0, clock: clock) }
    return backend
}

private func moduleID(_ backend: LocalBackend, _ name: String) async throws -> Int {
    let id = try await backend.context.database.scalar("SELECT id FROM modules WHERE name=?", [.text(name)])?.int
    return try XCTUnwrap(id, name)
}

private func titles(_ blocks: [OpencastWeekBlock]) -> [String] {
    blocks.map { b in "\(b.week) \(b.label): " + b.entries.map(\.video.title).joined(separator: " | ") }
}

private func match(_ backend: LocalBackend, _ file: String, _ text: String = "") async throws -> OpencastMatch? {
    try await backend.context.database.withConnection { try OpencastStore.match($0, fileID: file, text: text, clock: clock) }
}

private func video(_ id: String, _ title: String, created: Int, media: [OpencastMedia] = []) -> OpencastVideo {
    OpencastVideo(id: id, title: title, created: created, media: media)
}

final class OpencastStoreTests: XCTestCase {

    func testStoreIsIdempotentAndKeepsUserState() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let db = backend.context.database
        try await db.transaction { try StudIPLibrary.storeCourses($0, courses, startedAt: clock.nowISO) }
        let (f, _) = try await fetch()
        let first = try await db.transaction { try OpencastStore.store(f, in: $0, clock: clock) }
        XCTAssertEqual(first, OpencastStoreResult(newVideos: 3, videos: 3))
        let states = try await db.withConnection { try OpencastStore.courseStates($0) }
        XCTAssertEqual(states["c-ana"]?.status, "available")
        XCTAssertEqual(states["c-ana-ue"]?.status, "available")
        XCTAssertEqual(states["c-prog"], OpencastCourseState(status: "none", checkedAt: unix(2026, 11, 10)))
        XCTAssertNil(states["c-erst"], "nicht gelesen")

        // gemerkte Stelle und geladene Datei bleiben beim naechsten Abgleich
        try await db.transaction { c in
            try OpencastStore.savePosition(c, courseID: "c-ana", videoID: "Xyzab-12345-6789", seconds: 120.5)
            try OpencastStore.setLocal(c, courseID: "c-ana", videoID: "aaaaaaaa-0000-4000-8000-000000000002",
                                       path: "StudIP/Aufzeichnungen/c-ana/aaaaaaaa-0000-4000-8000-000000000002-480p.mp4", quality: "480p")
        }
        let second = try await db.transaction { try OpencastStore.store(f, in: $0, clock: clock) }
        XCTAssertEqual(second, OpencastStoreResult(newVideos: 0, videos: 3))
        let e = try await db.withConnection { try OpencastStore.entry($0, courseID: "c-ana", videoID: "Xyzab-12345-6789", clock: clock) }
        XCTAssertEqual(e?.position, 120.5)
        let count = try await db.scalar("SELECT COUNT(*) FROM opencast_videos")?.int
        XCTAssertEqual(count, 3)

        // in Opencast entfernt: ohne geladene Datei weg, mit geladener Datei sichtbar als "nicht mehr vorhanden"
        var removed = f
        removed.listings = ["c-ana": .videos([])]
        let g = removed
        _ = try await db.transaction { try OpencastStore.store(g, in: $0, clock: clock) }
        let rows = try await db.rows("SELECT id, gone, local_quality FROM opencast_videos ORDER BY id")
        XCTAssertEqual(rows.map { $0["id"]?.string ?? "" }, ["aaaaaaaa-0000-4000-8000-000000000002"])
        XCTAssertEqual(rows.first?["gone"], 1)
        XCTAssertEqual(rows.first?["local_quality"], "480p")
        // entfernt der Nutzer die Datei, verschwindet auch der Eintrag
        try await db.transaction { try OpencastStore.setLocal($0, courseID: "c-ana", videoID: "aaaaaaaa-0000-4000-8000-000000000002", path: nil, quality: nil) }
        let left = try await db.scalar("SELECT COUNT(*) FROM opencast_videos")?.int
        XCTAssertEqual(left, 0)
    }

    func testForgetLocalFilesKeepsTheLists() async throws {
        let backend = try await seededBackend()
        let db = backend.context.database
        try await db.transaction { c in
            try OpencastStore.setLocal(c, courseID: "c-ana", videoID: "Xyzab-12345-6789", path: "StudIP/Aufzeichnungen/x.mp4", quality: "720p")
        }
        func paths() async throws -> [String] {
            try await db.rows("SELECT local_path FROM opencast_videos WHERE local_path IS NOT NULL").compactMap { $0["local_path"]?.string }
        }
        let before = try await paths()
        XCTAssertEqual(before, ["StudIP/Aufzeichnungen/x.mp4"])
        try await db.transaction { try OpencastStore.forgetLocalFiles($0) }
        let after = try await paths()
        XCTAssertEqual(after, [])
        let count = try await db.scalar("SELECT COUNT(*) FROM opencast_videos")?.int
        XCTAssertEqual(count, 3)
    }

    func testWithoutTablesEverythingIsEmpty() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let r = try await backend.context.database.withConnection { c in
            (try OpencastStore.moduleBlocks(c, moduleID: 1, clock: clock), try OpencastStore.unassigned(c, clock: clock),
             try OpencastStore.courseStates(c), try OpencastStore.match(c, fileID: "x", clock: clock),
             try OpencastStore.packageMatches(c, packageID: 1, clock: clock))
        }
        XCTAssertTrue(r.0.isEmpty && r.1.isEmpty && r.2.isEmpty && r.3 == nil && r.4.isEmpty)
    }

    /// Fach = Modul (Vorlesung und Uebung eines Fachs zusammen), Lehrwoche = derselbe Block wie im Moduldetail
    func testOrderedBySubjectAndLectureWeekLikeTheModuleDetail() async throws {
        let backend = try await seededBackend()
        let db = backend.context.database
        let ana = try await moduleID(backend, "Testanalysis I")
        let blocks = try await db.withConnection { try OpencastStore.moduleBlocks($0, moduleID: ana, clock: clock) }
        XCTAssertEqual(titles(blocks), [
            "2 Woche 2 · 19.10. – 25.10.: Zentralübung 02",                                     // "02" wie Blatt02
            "4 Woche 4 · 02.11. – 08.11.: 3. Vorlesung vom 06.11.2026 – Grenzwerte & Folgen",    // Datum ist keine Woche
            "-1 Ältere Unterlagen: 02. Vorlesungswoche - Ergänzung zu Teil 2 (Video aus SoSe 21)", // aus 2022
        ])
        XCTAssertEqual(blocks[0].entries[0].label, "Hörsaalübung")
        XCTAssertEqual(blocks[0].entries[0].kind, "uebung")
        XCTAssertEqual(blocks[1].entries[0].kind, "vorlesung")

        // dieselben Bloecke und Beschriftungen wie die Dateien im Moduldetail
        let detail = try await db.withConnection { try LocalModules.detail($0, moduleID: .integer(Int64(ana)), clock: clock) }
        let fileWeeks = Dictionary(uniqueKeysWithValues: (detail?["weeks"]?.array ?? []).compactMap { w -> (Int, String)? in
            guard let n = w["week"]?.int, let l = w["label"]?.string else { return nil }
            return (n, l)
        })
        XCTAssertEqual(fileWeeks[2], blocks[0].label, "Blatt02 und Zentralübung 02 in derselben Woche")
        XCTAssertEqual(fileWeeks[4], blocks[1].label, "VL04 und die Vorlesung vom 06.11. in derselben Woche")

        let counts = try await db.withConnection { try OpencastStore.weekCounts($0, moduleID: ana, clock: clock) }
        XCTAssertEqual(counts, [2: 1, 4: 1, -1: 1])
        let prog = try await moduleID(backend, "Testprogrammierung")
        let progBlocks = try await db.withConnection { try OpencastStore.moduleBlocks($0, moduleID: prog, clock: clock) }
        XCTAssertTrue(progBlocks.isEmpty)
    }

    func testCoursesWithoutModuleHaveTheirOwnSection() async throws {
        let backend = try await seededBackend(extraVideos: ["c-erst": [video("e1", "Begrüßung und Rundgang", created: unix(2026, 10, 12))]])
        let groups = try await backend.context.database.withConnection { try OpencastStore.unassigned($0, clock: clock) }
        XCTAssertEqual(groups.map(\.courseTitle), ["Begrüßung der Erstsemester"])
        XCTAssertEqual(groups.first.map { titles($0.blocks) }, ["1 Woche 1 · 12.10. – 18.10.: Begrüßung und Rundgang"])
        XCTAssertEqual(groups.first?.count, 1)
    }

    /// Datum und Uhrzeit im Titel sind keine Nummer: alle Videos vom 06.11. stehen in Woche 4 (Erstellt am), keines in
    /// Woche 6 oder 8, und Blatt 6 bekommt deshalb keine "Aufzeichnung derselben Lehrwoche"
    func testDatesAndTimesInTheTitleAreNoWeek() async throws {
        let titles = ["Vorlesung vom 06.11", "Vorlesung 06.11 – Reihen", "Vorlesung 06/11/2026", "Vorlesung 06-11-2026",
                      "Vorlesung 2026_11_06", "Vorlesung 2026-11-06", "Vorlesung 20261106", "Vorlesung 06.11.2026, 08.15 Uhr",
                      "Vorlesung 06.11.2026 08:15", "Vorlesung 08.15 – 09.45", "Vorlesung 8–10 Uhr", "Vorlesung 10 Uhr",
                      "Vorlesung 6. November 2026", "Vorlesung 06. Nov.", "VL 2026.11.06", "Vorlesung 06.11.26"]
        let created = unix(2026, 11, 6)
        let backend = try await seededBackend(extraVideos: ["c-ana-ue": titles.enumerated().map { video("d\($0.offset)", $0.element, created: created) }])
        let ana = try await moduleID(backend, "Testanalysis I")
        let entries = try await backend.context.database.withConnection { try OpencastStore.moduleBlocks($0, moduleID: ana, clock: clock) }
            .flatMap(\.entries).filter { $0.courseID == "c-ana-ue" }
        XCTAssertEqual(entries.count, titles.count)
        for e in entries { XCTAssertEqual(e.week, 4, e.video.title) }
        let sheet = try await match(backend, "f-blatt6")
        XCTAssertNil(sheet, "keine Aufzeichnung in Woche 6: \(sheet?.reasonText ?? "")")
        let slides = try await match(backend, "f-vl4")
        XCTAssertEqual(slides?.reason, .sameWeek(4), "die Woche des Videos bleibt die Woche nach Erstellt am")

        // Nummern neben dem Datum zaehlen weiter wie bei Dateien
        let numbered = try await seededBackend(extraVideos: ["c-ana-ue": [video("n1", "Übung 3 am 06.11.", created: created),
                                                                          video("n2", "Kapitel 3.1.4 (06.11.2026)", created: created)]])
        let weeks = try await numbered.context.database.withConnection { try OpencastStore.moduleBlocks($0, moduleID: ana, clock: clock) }
            .flatMap(\.entries).filter { $0.courseID == "c-ana-ue" }.map(\.week)
        XCTAssertEqual(weeks, [3, 3])
    }

    // MARK: Vorschlag nur bei sicherem Treffer

    func testSameSubjectAndSameWeekIsOffered() async throws {
        let backend = try await seededBackend()
        let sheet = try await match(backend, "f-blatt2")
        XCTAssertEqual(sheet?.reason, .sameWeek(2))
        XCTAssertEqual(sheet?.entries.map(\.video.title), ["Zentralübung 02"])
        XCTAssertEqual(sheet?.reasonText, "Aufzeichnung derselben Lehrwoche (Woche 2)")
        let slides = try await match(backend, "f-vl4")
        XCTAssertEqual(slides?.reason, .sameWeek(4))
        XCTAssertEqual(slides?.entries.map(\.video.id), ["aaaaaaaa-0000-4000-8000-000000000001"])
    }

    func testNothingWithoutWeekOrUniqueTopic() async throws {
        let backend = try await seededBackend()
        // Blatt 6: keine Aufzeichnung in Woche 6, kein Thema im Text
        let none = try await match(backend, "f-blatt6", "Aufgabe 1: Zeigen Sie die Aussage. Aufgabe 2: Berechnen Sie.")
        XCTAssertNil(none)
        // anderes Fach in derselben Woche: nie
        let prog = try await match(backend, "f-prog-4", "Grenzwerte und Folgen")
        XCTAssertNil(prog)
        // Kurs ohne Modul (Begruessung): nie
        let erst = try await match(backend, "f-erst", "Grenzwerte und Folgen")
        XCTAssertNil(erst)
        // unbekanntes Dokument
        let unknown = try await match(backend, "gibt-es-nicht")
        XCTAssertNil(unknown)
    }

    func testUniqueTopicIsOfferedAmbiguousIsNot() async throws {
        let backend = try await seededBackend()
        let topic = try await match(backend, "f-blatt6", "Übungsblatt 6\nAufgabe 1 (Grenzwerte): Untersuchen Sie die Folgen auf Konvergenz.")
        XCTAssertEqual(topic?.reason, .topic(["grenzwerte", "folgen"]))
        XCTAssertEqual(topic?.entries.map(\.video.id), ["aaaaaaaa-0000-4000-8000-000000000001"])
        XCTAssertEqual(topic?.reasonText, "Gleiches Thema: Grenzwerte, Folgen")
        // nur ein Teil des Themas steht im Blatt: kein Vorschlag
        let half = try await match(backend, "f-blatt6", "Aufgabe 1: Grenzwerte von Funktionen")
        XCTAssertNil(half)

        // zwei Videos mit demselben Thema: nicht eindeutig, kein Vorschlag
        let twice = try await seededBackend(extraVideos: ["c-ana-ue": [video("w1", "Grenzwerte und Folgen – Wiederholung", created: unix(2026, 11, 9))]])
        let ambiguous = try await match(twice, "f-blatt6", "Aufgabe 1 (Grenzwerte): Untersuchen Sie die Folgen auf Konvergenz.")
        XCTAssertNil(ambiguous)
    }

    /// Lehrwoche nur bei Arten mit Lehrwoche (wie `week_hint`): Organisatorisches und Sonstiges haben nur die Woche des
    /// Hochladens. Organisatorisches bekommt nie eine Aufzeichnung, Sonstiges nur bei eindeutigem Thema.
    func testOrganisationalAndOtherDocumentsGetNoSameWeekRecording() async throws {
        let backend = try await seededBackend(extraFiles: [("f-raum", "c-ana", "Raumverteilung Klausur.pdf", unix(2026, 11, 6)),
                                                           ("f-formel", "c-ana", "Formelsammlung.pdf", unix(2026, 11, 5))])
        let room = try await match(backend, "f-raum")
        XCTAssertNil(room, "Raumverteilung in Woche 4: \(room?.reasonText ?? "")")
        let roomTopic = try await match(backend, "f-raum", "Grenzwerte und Folgen")
        XCTAssertNil(roomTopic, "Organisatorisches nie")
        let formulas = try await match(backend, "f-formel")
        XCTAssertNil(formulas, "Formelsammlung in Woche 4: \(formulas?.reasonText ?? "")")
        let formulasTopic = try await match(backend, "f-formel", "Grenzwerte und Folgen")
        XCTAssertEqual(formulasTopic?.reason, .topic(["grenzwerte", "folgen"]), "Sonstiges nur mit eindeutigem Thema")

        // dasselbe ohne Datenbank: Woche 4 mit Video, Dokumentart entscheidet
        let e = OpencastEntry(courseID: "c", courseTitle: "Fach", moduleID: 1, video: video("v", "Vorlesung 1: Mengen", created: 0), week: 1)
        for kind in ["organisatorisch", "sonstiges", "klausur"] {
            XCTAssertNil(OpencastStore.best([e], documentWeek: 1, documentKind: kind, documentText: "Organisatorisches", names: []), kind)
        }
        XCTAssertNil(OpencastStore.best([e], documentWeek: 1, documentKind: "organisatorisch", documentText: "Mengen", names: []))
        XCTAssertEqual(OpencastStore.best([e], documentWeek: 1, documentKind: "sonstiges", documentText: "Mengen und Abbildungen", names: [])?.reason,
                       .topic(["mengen"]))
        for kind in StudyClassify.lectureWeekTypes {
            XCTAssertEqual(OpencastStore.best([e], documentWeek: 1, documentKind: kind, documentText: "", names: [])?.reason, .sameWeek(1), kind)
        }
    }

    /// Woerter, die die Einordnung als Art erkennt (auch englisch und zusammengesetzt), sind kein Thema
    func testKindWordsAreNoTopic() async throws {
        for t in ["Exercise 02", "Lecture 01", "Tutorial 2", "Großübung 02", "Rechenübung 2", "Übungsbesprechung 2",
                  "Lösungsbesprechung 3", "Slides Lecture 1", "Exercise Session 4", "Part 2", "Chapter 3", "Week 5",
                  "Introduction", "Recording 7", "Vorlesung", "Übungsblatt 4", "Musterlösung", "Klausurvorbereitung",
                  "Organisatorisches", "Folien", "Skript", "Hausübung", "Aufgabenblatt", "Hörsaalübung", "Tutorium"] {
            XCTAssertEqual(OpencastStore.topicWords(t, ignoring: []), [], t)
        }
        XCTAssertEqual(OpencastStore.topicWords("Exercise 3: Fourier Series", ignoring: []), ["fourier", "series"])

        // ein einzelnes Video "Exercise 02" (Woche 2) ist kein Thema fuer "Exercise_06.pdf" (Woche 6, ohne Video)
        let backend = try await seededBackend(extraVideos: ["c-ana-ue": [video("x2", "Exercise 02", created: unix(2026, 10, 20))]],
                                              extraFiles: [("f-ex6", "c-ana-ue", "Exercise_06.pdf", unix(2026, 11, 9))])
        let none = try await match(backend, "f-ex6")
        XCTAssertNil(none, none?.reasonText ?? "")
        let withText = try await match(backend, "f-ex6", "Exercise 6\nTask 1: exercise on limits")
        XCTAssertNil(withText, withText?.reasonText ?? "")
    }

    func testGenericAndCourseWordsAreNoTopic() {
        let e = OpencastEntry(courseID: "c", courseTitle: "Testanalysis I", moduleID: 1,
                              video: video("v", "Testanalysis I – Vorlesung 7 (Teil 2), Wiederholung", created: 0), week: 7)
        // Fach, "Vorlesung", "Teil", "Wiederholung" sagen nichts ueber das Thema
        XCTAssertNil(OpencastStore.best([e], documentWeek: 3, documentKind: "uebung",
                                        documentText: "Testanalysis I Vorlesung Teil Wiederholung", names: ["Testanalysis I"]))
        XCTAssertEqual(OpencastStore.topicWords("Zentralübung 02", ignoring: []), [])
        XCTAssertEqual(OpencastStore.topicWords("VL 05 – Fourier-Reihen", ignoring: []), ["fourier", "reihen"])
        XCTAssertTrue(OpencastStore.sameWord("reihen", "reihe"))
        XCTAssertTrue(OpencastStore.sameWord("grenzwert", "grenzwerte"))
        XCTAssertFalse(OpencastStore.sameWord("ring", "ringe"), "zu kurz fuer eine Endung")
        XCTAssertFalse(OpencastStore.sameWord("folgen", "folgerungen"))
        // zerlegte Umlaute aus PDF-Text
        XCTAssertEqual(OpencastStore.words("Gleichma\u{0308}ßige Stetigkeit"), ["gleichmäßige", "stetigkeit"])
    }

    func testSameWeekPrefersMatchingKindAndTopic() {
        func e(_ id: String, _ title: String, kind: String) -> OpencastEntry {
            OpencastEntry(courseID: "c", courseTitle: "Fach", moduleID: 1, video: video(id, title, created: 0), week: 5, kind: kind)
        }
        let list = [e("v1", "Vorlesung: Eigenwerte", kind: "vorlesung"), e("v2", "Vorlesung: Diagonalisierung", kind: "vorlesung"),
                    e("u1", "Zentralübung 05", kind: "uebung")]
        // Blatt: die Uebungsaufzeichnung der Woche
        XCTAssertEqual(OpencastStore.best(list, documentWeek: 5, documentKind: "uebung", documentText: "Blatt 5", names: [])?.entries.map(\.video.id), ["u1"])
        // Folien: die Vorlesungen der Woche, mit eindeutigem Thema nur diese
        XCTAssertEqual(OpencastStore.best(list, documentWeek: 5, documentKind: "vorlesung", documentText: "VL 5", names: [])?.entries.map(\.video.id), ["v1", "v2"])
        XCTAssertEqual(OpencastStore.best(list, documentWeek: 5, documentKind: "vorlesung", documentText: "Kapitel Diagonalisierung", names: [])?.entries.map(\.video.id), ["v2"])
        // Klausuren-Block (-2) und aeltere Unterlagen (-1) sind keine Lehrwochen
        XCTAssertNil(OpencastStore.best(list.map { _ in e("k", "Fragestunde", kind: "vorlesung") }, documentWeek: -2, documentKind: "klausur", documentText: "", names: []))
    }

    /// Loesungsbesprechungen gehoeren zur Uebungsseite (wie die Art des Dokuments), organisatorische Videos zu keiner
    /// Lehrwoche: vorher kam zu "VL05 Folien" auch "Lösungsbesprechung Blatt 5", zu "Lösung Blatt 5" fiel sie neben
    /// "Übung 5" weg, und "Organisatorisches" (Woche aus dem Erstelldatum) wurde zu den Folien der Woche vorgeschlagen
    func testSolutionVideosBelongToTheExerciseSideOrganisationalVideosToNone() {
        func e(_ id: String, _ title: String, kind: String, week: Int = 5) -> OpencastEntry {
            OpencastEntry(courseID: "c", courseTitle: "Fach", moduleID: 1, video: video(id, title, created: 0), week: week, kind: kind)
        }
        let list = [e("v5", "Vorlesung 5", kind: "vorlesung"), e("u5", "Übung 5", kind: "uebung"),
                    e("l5", "Lösungsbesprechung Blatt 5", kind: "loesung"), e("o5", "Organisatorisches", kind: "organisatorisch")]
        XCTAssertEqual(OpencastStore.best(list, documentWeek: 5, documentKind: "vorlesung", documentText: "VL05 Folien", names: [])?
            .entries.map(\.video.id), ["v5"])
        XCTAssertEqual(OpencastStore.best(list, documentWeek: 5, documentKind: "loesung", documentText: "Lösung Blatt 5", names: [])?
            .entries.map(\.video.id), ["u5", "l5"])
        XCTAssertEqual(OpencastStore.best(list, documentWeek: 5, documentKind: "uebung", documentText: "Blatt 5", names: [])?
            .entries.map(\.video.id), ["u5", "l5"])
        // nur ein organisatorisches Video in der Woche: kein Vorschlag
        XCTAssertNil(OpencastStore.best([e("o1", "Organisatorisches", kind: "organisatorisch", week: 1)], documentWeek: 1,
                                        documentKind: "vorlesung", documentText: "VL01 Einführung", names: []))
        // abgesetztes Trema aus PDF-Text (pypdf/PDFKit) wird wie in der Skriptsuche zum Umlaut
        XCTAssertEqual(OpencastStore.words("¨ Ubertragung und Unabh¨ angigkeit"), ["übertragung", "und", "unabhängigkeit"])
    }

    func testPackageShowsMatchesOfItsTasksOnce() async throws {
        let backend = try await seededBackend()
        let db = backend.context.database
        let ana = try await moduleID(backend, "Testanalysis I")
        let pid = try await db.transaction { c -> Int in
            try c.execute("INSERT INTO study_packages(date, module_id, subject, title) VALUES ('2026-11-11', ?, 'Testanalysis I', 'Übung bearbeiten')",
                          [.integer(Int64(ana))])
            let p = Int(c.lastInsertRowID)
            for (title, file) in [("Blatt 2 bearbeiten", "f-blatt2"), ("Blatt 2 nachbereiten", "f-blatt2"), ("Blatt 6", "f-blatt6"),
                                  ("Freies Lernen", nil)] as [(String, String?)] {
                try c.execute("INSERT INTO study_tasks(package_id, type, file_id, title) VALUES (?, 'uebung', ?, ?)",
                              [.integer(Int64(p)), SQLiteValue(file), .text(title)])
            }
            return p
        }
        let m = try await db.withConnection { try OpencastStore.packageMatches($0, packageID: pid, clock: clock) }
        XCTAssertEqual(m.map(\.taskTitle), ["Blatt 2 bearbeiten"], "dasselbe Video nur einmal, Blatt 6 ohne Treffer")
        XCTAssertEqual(m.first?.match.entries.map(\.video.title), ["Zentralübung 02"])
    }
}

// MARK: - Abspielen und Laden nur auf Wunsch

final class OpencastPlaybackTests: XCTestCase {
    private let v = OpencastVideo(id: "v1", title: "3. Vorlesung", playerURL: URL(string: "https://studip.example.test/plugins.php/opencastpluginluh/media/player/v1"),
                                  media: [OpencastMedia(quality: "1080p", height: 1080, url: URL(string: "https://oc.example.test/1080.mp4")!),
                                          OpencastMedia(quality: "720p", height: 720, url: URL(string: "https://oc.example.test/720.mp4")!),
                                          OpencastMedia(quality: "480p", height: 480, url: URL(string: "https://oc.example.test/480.mp4")!)])
    private let file = URL(fileURLWithPath: "/tmp/v1-480p.mp4")

    func testSource() {
        XCTAssertEqual(RecordingPlayback.source(for: v, local: nil), .stream(URL(string: "https://oc.example.test/720.mp4")!, quality: "720p"))
        XCTAssertEqual(RecordingPlayback.source(for: v, local: (file, "480p")), .local(file, quality: "480p"), "geladene Datei vor Stream")
        XCTAssertEqual(RecordingPlayback.source(for: v, local: (file, "480p"), preferred: "1080p"),
                       .stream(URL(string: "https://oc.example.test/1080.mp4")!, quality: "1080p"), "ausdruecklich andere Fassung")
        let bare = OpencastVideo(id: "v2", title: "Ohne Datei", playerURL: v.playerURL)
        XCTAssertEqual(RecordingPlayback.source(for: bare, local: nil), .webPlayer(v.playerURL!))
        XCTAssertEqual(RecordingPlayback.source(for: OpencastVideo(id: "v3", title: "Nichts"), local: nil), .unavailable)
        XCTAssertEqual(RecordingPlayback.source(for: OpencastVideo(id: "v4", title: "Weg"), local: (file, "480p")), .local(file, quality: "480p"))
        XCTAssertEqual(RecordingPlayback.quality(for: OpencastVideo(id: "x", title: "x", media: [v.media[0], v.media[2]]))?.quality, "480p")
    }

    func testResumePosition() {
        XCTAssertEqual(RecordingPlayback.resumePosition(saved: 1234.5, duration: 5339), 1234.5)
        XCTAssertNil(RecordingPlayback.resumePosition(saved: 5, duration: 5339), "erste 10 s: von vorn")
        XCTAssertNil(RecordingPlayback.resumePosition(saved: 5330, duration: 5339), "letzte 15 s: von vorn")
        XCTAssertNil(RecordingPlayback.resumePosition(saved: .infinity, duration: nil))
        XCTAssertEqual(RecordingPlayback.resumePosition(saved: 60, duration: .nan), 60)
    }

    /// Entscheidung 7: grosse Dateien nur auf ausdruecklichen Wunsch; der Abgleich laedt nie ein Video
    func testDownloadOnlyOnRequestLargeFilesNeedConfirmation() {
        let free: Int64 = 50_000_000_000
        XCTAssertEqual(RecordingDownloadPolicy.decide(title: "Kurz", quality: "480p", size: 80_000_000, freeBytes: free), .start)
        XCTAssertEqual(RecordingDownloadPolicy.decide(title: "Kurz", quality: "480p", size: 100_000_000, freeBytes: free), .start)
        guard case .confirm(let big) = RecordingDownloadPolicy.decide(title: "3. Vorlesung", quality: "720p", size: 412_000_000, freeBytes: free) else {
            return XCTFail("ueber 100 MB nur mit Bestaetigung")
        }
        XCTAssertTrue(big.contains("412 MB") && big.contains("„3. Vorlesung“") && big.contains("privat"), big)
        guard case .confirm(let unknown) = RecordingDownloadPolicy.decide(title: "x", quality: "720p", size: nil, freeBytes: free) else {
            return XCTFail("unbekannte Groesse nur mit Bestaetigung")
        }
        XCTAssertTrue(unknown.contains("unbekannt"), unknown)
        guard case .confirm(let low) = RecordingDownloadPolicy.decide(title: "x", quality: "480p", size: 50_000_000, freeBytes: 1_020_000_000) else {
            return XCTFail("wenig Platz: Warnung")
        }
        XCTAssertTrue(low.hasPrefix("Wenig Speicherplatz: Danach sind nur noch 970 MB frei."), low)
        guard case .refuse(let full) = RecordingDownloadPolicy.decide(title: "x", quality: "1080p", size: 2_400_000_000, freeBytes: 2_000_000_000) else {
            return XCTFail("passt nicht")
        }
        XCTAssertEqual(full, "Nicht genug Speicherplatz: Die Aufzeichnung braucht 2,4 GB, frei sind 2,0 GB.")
        XCTAssertEqual(RecordingDownloadPolicy.decide(title: "x", quality: "480p", size: 10_000_000, freeBytes: nil), .start)
    }

    func testFilesAndFormat() {
        XCTAssertEqual(RecordingFiles.relativePath(courseID: "c-ana", videoID: "Xyzab-12345-6789", quality: "720p"), "c-ana/Xyzab-12345-6789-720p.mp4")
        XCTAssertEqual(RecordingFiles.relativePath(courseID: "../c", videoID: "a/b", quality: "720p"), "_c/a_b-720p.mp4", "kein Pfad aus der Seite")
        XCTAssertEqual(RecordingFiles.megabytes(412_400_000), "412 MB")
        XCTAssertEqual(RecordingFiles.megabytes(1_250_000_000), "1,3 GB")
        XCTAssertEqual(RecordingFiles.megabytes(20_000), "1 MB")
    }

    /// veraltete Fortsetzungsdaten blockieren nichts: andere Adresse, aelter als 3 Tage oder ohne Angaben -> frisch laden
    func testStaleResumeDataIsNotUsed() {
        let url = URL(string: "https://oc.example.test/720.mp4")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(RecordingResume.usable(savedURL: url.absoluteString, savedAt: now.addingTimeInterval(-3600), currentURL: url, now: now))
        XCTAssertFalse(RecordingResume.usable(savedURL: "https://oc.example.test/neu.mp4", savedAt: now, currentURL: url, now: now))
        XCTAssertFalse(RecordingResume.usable(savedURL: url.absoluteString, savedAt: now.addingTimeInterval(-4 * 86400), currentURL: url, now: now))
        XCTAssertFalse(RecordingResume.usable(savedURL: url.absoluteString, savedAt: now.addingTimeInterval(3600), currentURL: url, now: now))
        XCTAssertFalse(RecordingResume.usable(savedURL: nil, savedAt: now, currentURL: url, now: now))
    }
}
