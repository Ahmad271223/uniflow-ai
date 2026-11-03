import Foundation
import XCTest
@testable import UniFlowCore

// Schwarzes Brett aus Stud.IP (03.11.2026, `StudIPBulletin`): Themenliste aus der Plugin-Seite, Anzeigen aus den
// RSS-Feeds je Thema (ohne Autoren, Text gekuerzt, Zeit als Ortszeit), hoechstens 20 je Thema, fehlendes Plugin 30 Tage
// gemerkt, Mindestabstand zwischen Abrufen, abgelaufene Sitzung, Endpunkte /api/studip/bulletin. Dazu das Forum des
// Lernstoffs: 404 der Kategorienliste ist "noch keine Kategorie", nie "an der Hochschule nicht vorhanden".

private let listHTML = """
<!DOCTYPE html><html><head><title>Schwarzes Brett</title></head><body>
<div id="content"><h2>Themenübersicht</h2>
<ul class="sb-categories">
    <li><a href="https://studip.test/plugins.php/schwarzesbrettplugin/category/view/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" class="category seen">
        Biete
        (1.234)
        <img src="x.svg" title="Dinge, die du loswerden willst" alt="">
    </a><div class="options"><a href="https://studip.test/plugins.php/schwarzesbrettplugin/rss/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"><img src="rss.svg"></a></div></li>
    <li><a href="https://studip.test/plugins.php/schwarzesbrettplugin/category/view/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" class="category unseen">Jobs an der Uni (7)</a></li>
    <li><a href="/plugins.php/schwarzesbrettplugin/category/view/cccccccccccccccccccccccccccccccc" class="category seen">Wohnliches</a>
        <ul><li><a href="/plugins.php/schwarzesbrettplugin/category/view/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa">doppelt</a></li></ul></li>
</ul>
<h2>Die 20 neuesten Anzeigen</h2>
<ul class="sb-articles">
    <li data-article-id="dddddddddddddddddddddddddddddddd" class="article seen"><a href="/plugins.php/schwarzesbrettplugin/article/view/dddddddddddddddddddddddddddddddd" data-dialog>Suche WG-Zimmer</a>
        <a href="/plugins.php/schwarzesbrettplugin/category/view/cccccccccccccccccccccccccccccccc">Wohnliches</a></li>
</ul></div></body></html>
"""

private func feedXML(_ items: [(title: String, guid: String?, link: String, desc: String, date: String)]) -> String {
    var s = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0"><channel><title>Stud.IP Schwarzes Brett - Biete</title><link>https://studip.test/plugins.php/schwarzesbrettplugin/category</link>
    <description><![CDATA[]]></description><lastBuildDate>Mon, 02 Nov 2026 10:00:00 +0100</lastBuildDate>

    """
    for i in items {
        s += "<item><title>\(i.title)</title><link>\(i.link)</link><description><![CDATA[\(i.desc)]]></description><pubDate>\(i.date)</pubDate>"
        if let g = i.guid { s += "<guid isPermaLink=\"false\">\(g)</guid>" }
        s += "</item>\n"
    }
    return s + "</channel></rss>"
}

private func page(_ html: String, status: Int = 200) -> HTTPReply {
    HTTPReply(status: status, contentType: "text/html; charset=UTF-8", body: Data(html.utf8))
}

private func feed(_ xml: String) -> HTTPReply {
    HTTPReply(status: 200, contentType: "application/rss+xml;charset=utf-8", body: Data(xml.utf8))
}

private let plugin = "/plugins.php/schwarzesbrettplugin"

final class StudIPBulletinTests: XCTestCase {

    private func client(_ t: StubTransport) -> StudIPClient { StudIPClient(base: URL(string: "https://studip.test")!, transport: t, pauseMillis: 0) }

    private func day(_ s: String) throws -> Int { try XCTUnwrap(BerlinClock.parseISODate(s)) }

    // MARK: Lesen

    func testParsesTopicsFromTheListPage() {
        let topics = StudIPBulletin.parseTopics(html: listHTML)
        XCTAssertEqual(topics.map(\.title), ["Biete", "Jobs an der Uni", "Wohnliches"], "nur die Themenliste, keine Anzeigen, keine Doppelten")
        XCTAssertEqual(topics.map(\.count), [1234, 7, 0])
        XCTAssertEqual(topics[0].id, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        XCTAssertEqual(StudIPBulletin.parseTopics(html: "<html><body><ul class=\"sb-articles\"><li><a href=\"/x/category/view/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\">x</a></li></ul></body></html>"), [])
        XCTAssertEqual(StudIPBulletin.boardURL(base: "https://studip.test/"), "https://studip.test/plugins.php/schwarzesbrettplugin/category/list")
    }

    func testParsesFeedIntoEntriesWithoutAuthorsAndCutText() throws {
        let long = (1...120).map { "Wort\($0)" }.joined(separator: " ")
        let xml = feedXML([
            ("Fahrrad &amp; Helm zu verkaufen", "e1", "https://studip.test/plugins.php/schwarzesbrettplugin/article/view/e1",
             "<p>Gut erhaltenes <b>Rad</b>,<br>28 Zoll.&nbsp;Preis VB.</p><p>Nur Abholung.</p>", "Mon, 02 Nov 2026 10:15:00 +0100"),
            ("Sehr lang", nil, "https://studip.test/plugins.php/schwarzesbrettplugin/article/view/e2", long, "Sun, 12 Jul 2026 10:00:00 +0200"),
            ("", "e3", "https://studip.test/x", "ohne Titel", "Mon, 02 Nov 2026 10:15:00 +0100"),
            ("Doppelt", "e1", "https://studip.test/y", "doppelte guid", "Mon, 02 Nov 2026 10:15:00 +0100"),
            ("GMT-Zeit", "e4", "javascript:alert(1)", "<script>x</script>Text", "Tue, 03 Nov 2026 09:00:00 GMT"),
        ])
        let e = StudIPBulletin.parseFeed(xml: xml, topic: "Biete")
        XCTAssertEqual(e.map(\.id), ["sb-e1", "sb-e2", "sb-e4"], "ohne Titel oder doppelt: weg")
        XCTAssertEqual(e[0].title, "Fahrrad & Helm zu verkaufen")
        XCTAssertEqual(e[0].text, "Gut erhaltenes Rad, 28 Zoll. Preis VB. Nur Abholung.")
        XCTAssertEqual(e[0].postedAt, "2026-11-02T10:15:00")
        XCTAssertEqual(e[0].url, "https://studip.test/plugins.php/schwarzesbrettplugin/article/view/e1")
        XCTAssertEqual(e[0].topic, "Biete")
        XCTAssertEqual(e[1].postedAt, "2026-07-12T10:00:00", "Sommerzeit")
        XCTAssertLessThanOrEqual(e[1].text.unicodeScalars.count, StudIPBulletin.maxText + 2)
        XCTAssertTrue(e[1].text.hasSuffix(" …"), e[1].text)
        XCTAssertFalse(e[1].text.contains("Wort120"))
        XCTAssertEqual(e[2].postedAt, "2026-11-03T10:00:00", "GMT -> Berlin")
        XCTAssertEqual(e[2].url, "", "nur http(s)")
        XCTAssertEqual(e[2].text, "xText")
        XCTAssertNil(StudIPBulletin.localTime(rfc2822: "irgendwann"))
        XCTAssertEqual(StudIPBulletin.localTime(rfc2822: "2 Nov 2026 23:30:00 -0500"), "2026-11-03T05:30:00")
    }

    // MARK: Abruf und Speichern

    private func routes(perTopic n: Int) -> [String: HTTPReply] {
        var r: [String: HTTPReply] = [plugin + "/category/list": page(listHTML)]
        for (id, topic) in [("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "Biete"), ("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "Jobs"), ("cccccccccccccccccccccccccccccccc", "Wohnen")] {
            let items = (1...n).map { i in
                (title: "\(topic) \(i)", guid: Optional("\(id.prefix(1))\(i)"), link: "https://studip.test/plugins.php/schwarzesbrettplugin/article/view/\(id.prefix(1))\(i)",
                 desc: "<p>Text \(i)</p>", date: "Mon, 02 Nov 2026 \(BerlinClock.pad(10 - min(i, 9), 2)):\(BerlinClock.pad(i % 60, 2)):00 +0100")
            }
            r[plugin + "/rss/\(id)/20"] = feed(feedXML(items))
        }
        return r
    }

    func testFetchStoresTwentyPerTopicAndAnswersTheEndpoints() async throws {
        let t = StubTransport(routes(perTopic: 25))
        let clock = try XCTUnwrap(UniFlowClock.fixed(berlin: "2026-11-02T12:00:00"))
        let d = await StudIPBulletin.fetch(client: client(t), missing: [:], lastFetchedAt: nil, clock: clock)
        XCTAssertFalse(d.skipped)
        XCTAssertFalse(d.sessionExpired)
        XCTAssertEqual(d.topics.map(\.title), ["Biete", "Jobs an der Uni", "Wohnliches"])
        XCTAssertEqual(d.entries?.count, 60, "hoechstens 20 je Thema")
        XCTAssertEqual(d.missing, [:])
        XCTAssertEqual(t.requested.count, 4, "eine Anfrage fuer die Themen, eine je Thema")
        XCTAssertTrue(t.requested.allSatisfy { $0.hasPrefix(plugin + "/") }, "nur das Plugin, nur GET")

        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        try await backend.context.database.transaction { try StudIPBulletin.store(d, in: $0, clock: clock) }
        let n = try await backend.context.database.withConnection { try $0.scalar("SELECT count(*) FROM studip_bulletin")?.int }
        XCTAssertEqual(n, 60)
        let fetched = try await backend.context.database.withConnection { try StudIPBulletin.lastFetchedAt($0) }
        XCTAssertEqual(fetched, "2026-11-02T12:00:00")

        // Uebersicht: Themen in Stud.IP-Reihenfolge mit Anzahl, Anzeigen neueste zuerst, "neu" innerhalb von 7 Tagen
        let all = await backend.handle(LocalRequest(method: "GET", path: "/api/studip/bulletin"))
        XCTAssertEqual(all.status, 200)
        let o = try JSONValue.parse(all.body)
        XCTAssertEqual(o["available"]?.bool, true)
        XCTAssertEqual(o["topics"]?.array?.map { $0["title"]?.string }, ["Biete", "Jobs an der Uni", "Wohnliches"])
        XCTAssertEqual(o["topics"]?.array?.map { $0["count"]?.int }, [20, 20, 20])
        XCTAssertEqual(o["topics"]?.array?.first?["total"]?.int, 1234)
        XCTAssertEqual(o["entries"]?.array?.count, 60)
        XCTAssertEqual(o["entries"]?.array?.first?["title"]?.string, "Biete 1", "neueste zuerst")
        XCTAssertEqual(o["new_count"]?.int, 60)
        XCTAssertEqual(o["url"]?.string, "https://studip.test/plugins.php/schwarzesbrettplugin/category/list".replacingOccurrences(of: "studip.test", with: "studip.uni-hannover.de"))
        let one = await backend.handle(LocalRequest(method: "GET", path: "/api/studip/bulletin", query: [.init("topic", "Jobs an der Uni")]))
        let oj = try JSONValue.parse(one.body)
        XCTAssertEqual(oj["entries"]?.array?.count, 20)
        XCTAssertTrue(oj["entries"]?.array?.allSatisfy { $0["topic"]?.string == "Jobs an der Uni" } ?? false)
        let item = await backend.handle(LocalRequest(method: "GET", path: "/api/studip/bulletin/sb-a3"))
        XCTAssertEqual(item.status, 200)
        XCTAssertEqual(try JSONValue.parse(item.body)["text"]?.string, "Text 3")
        let gone = await backend.handle(LocalRequest(method: "GET", path: "/api/studip/bulletin/sb-nein"))
        XCTAssertEqual(gone.status, 404)

        // zweiter Abruf: innerhalb von 6 Stunden nichts gefragt; danach ersetzt der Bestand (Verschwundenes weg)
        let t2 = StubTransport(routes(perTopic: 3))
        let soon = try XCTUnwrap(UniFlowClock.fixed(berlin: "2026-11-02T17:00:00"))
        let d2 = await StudIPBulletin.fetch(client: client(t2), missing: [:], lastFetchedAt: fetched, clock: soon)
        XCTAssertTrue(d2.skipped)
        XCTAssertEqual(t2.requested, [])
        let later = try XCTUnwrap(UniFlowClock.fixed(berlin: "2026-11-02T18:30:00"))
        let d3 = await StudIPBulletin.fetch(client: client(t2), missing: [:], lastFetchedAt: fetched, clock: later)
        XCTAssertEqual(d3.entries?.count, 9)
        try await backend.context.database.transaction { try StudIPBulletin.store(d3, in: $0, clock: later) }
        let n3 = try await backend.context.database.withConnection { try $0.scalar("SELECT count(*) FROM studip_bulletin")?.int }
        XCTAssertEqual(n3, 9)
    }

    func testMissingPluginIsRememberedForThirtyDays() async throws {
        let clock = try XCTUnwrap(UniFlowClock.fixed(berlin: "2026-11-02T12:00:00"))
        // 404 (kein Plugin)
        let t = StubTransport([:])
        let d = await StudIPBulletin.fetch(client: client(t), missing: [:], lastFetchedAt: nil, clock: clock)
        XCTAssertNil(d.entries)
        XCTAssertEqual(d.missing, ["bulletin": "2026-11-02"])
        XCTAssertEqual(t.requested, [plugin + "/category/list"])
        // Seite ohne Themenliste (andere Fassung): ebenso
        let t2 = StubTransport([plugin + "/category/list": page("<html><body><h1>Fehler</h1></body></html>")])
        let d2 = await StudIPBulletin.fetch(client: client(t2), missing: [:], lastFetchedAt: nil, clock: clock)
        XCTAssertEqual(d2.missing, ["bulletin": "2026-11-02"])
        // gemerkt: nicht gefragt, auch nicht nach 29 Tagen; nach 30 wieder
        let t3 = StubTransport(routes(perTopic: 1))
        let d3 = await StudIPBulletin.fetch(client: client(t3), missing: d.missing, lastFetchedAt: nil, clock: clock)
        XCTAssertTrue(d3.skipped)
        XCTAssertEqual(t3.requested, [])
        let d4 = await StudIPBulletin.fetch(client: client(t3), missing: d.missing, lastFetchedAt: nil,
                                            clock: try XCTUnwrap(UniFlowClock.fixed(berlin: "2026-12-01T12:00:00")))
        XCTAssertTrue(d4.skipped)
        let d5 = await StudIPBulletin.fetch(client: client(t3), missing: d.missing, lastFetchedAt: nil,
                                            clock: try XCTUnwrap(UniFlowClock.fixed(berlin: "2026-12-02T12:00:00")))
        XCTAssertEqual(d5.entries?.count, 3)
        XCTAssertEqual(d5.missing, [:], "wieder da: Merker weg")

        // gespeichert wird der Merker auch ohne Anzeigen; die Tabelle bleibt unberuehrt
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        try await backend.context.database.transaction { try StudIPBulletin.store(d, in: $0, clock: clock) }
        let missing = try await backend.context.database.withConnection { try StudIPExtras.loadMissing($0) }
        XCTAssertEqual(missing, ["bulletin": "2026-11-02"])
        let r = await backend.handle(LocalRequest(method: "GET", path: "/api/studip/bulletin"))
        let o = try JSONValue.parse(r.body)
        XCTAssertEqual(o["available"]?.bool, true)
        XCTAssertEqual(o["entries"]?.array?.count, 0)
    }

    func testSessionExpiryAndFeedSwitchedOffKeepTheStock() async throws {
        let clock = try XCTUnwrap(UniFlowClock.fixed(berlin: "2026-11-02T12:00:00"))
        let login = HTTPReply(status: 200, contentType: "text/html", finalURL: URL(string: "https://studip.test/dispatch.php/login"), body: Data("<html>".utf8))
        let d = await StudIPBulletin.fetch(client: client(StubTransport([plugin + "/category/list": login])), missing: [:], lastFetchedAt: nil, clock: clock)
        XCTAssertTrue(d.sessionExpired)
        XCTAssertNil(d.entries)
        XCTAssertEqual(d.missing, [:], "abgelaufene Sitzung ist kein fehlendes Plugin")
        // RSS in Stud.IP abgeschaltet: Themen da, der Feed antwortet mit einer Fehlerseite
        var r = routes(perTopic: 2)
        r[plugin + "/rss/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/20"] = page("<html><body>RSS-Exporte sind nicht aktiviert.</body></html>", status: 500)
        let d2 = await StudIPBulletin.fetch(client: client(StubTransport(r)), missing: [:], lastFetchedAt: nil, clock: clock)
        XCTAssertTrue(d2.feedUnavailable)
        XCTAssertNil(d2.entries, "nichts Halbes speichern")
        XCTAssertEqual(d2.missing, [:])
    }

    func testHildesheimHasNoBoard() async throws {
        XCTAssertTrue(UniversityProfile.luh.hasBulletinBoard)
        XCTAssertFalse(UniversityProfile.hildesheim.hasBulletinBoard)
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, university: "hildesheim")
        let r = await backend.handle(LocalRequest(method: "GET", path: "/api/studip/bulletin"))
        XCTAssertEqual(r.status, 200)
        let o = try JSONValue.parse(r.body)
        XCTAssertEqual(o["available"]?.bool, false)
        XCTAssertEqual(o["entries"]?.array?.count, 0)
        XCTAssertEqual(o["url"], .null)
    }

    // MARK: Forum des Lernstoffs

    func testForumWithoutCategoriesIsRememberedPerCourseOnly() async throws {
        let p = "/jsonapi.php/v1/"
        let api = "application/vnd.api+json"
        func json(_ s: String, status: Int = 200) -> HTTPReply { HTTPReply(status: status, contentType: api, body: Data(s.utf8)) }
        var routes: [String: HTTPReply] = [:]
        for c in ["c-1", "c-2", "c-3"] {
            // Aufgaben, Courseware, Wiki: an der Hochschule nicht vorhanden (403), damit nur das Forum zaehlt
            routes[p + "courseware-tasks?filter[cid]=\(c)&include=task-group,structural-element&page[limit]=100"] = json("{}", status: 403)
            routes[p + "courses/\(c)/courseware-task-groups?page[limit]=100"] = json("{}", status: 403)
            routes[p + "courses/\(c)/courseware-units?include=structural-element&page[limit]=50"] = json("{}", status: 403)
            routes[p + "courses/\(c)/wiki-pages?page[limit]=100"] = json("{}", status: 403)
        }
        // c-1, c-2: noch keine Kategorie (404); c-3: Forum im Kurs abgeschaltet (403)
        routes[p + "courses/c-3/forum-categories?page[limit]=50"] = json("{}", status: 403)
        let t = StubTransport(routes)
        let courses = ["c-1", "c-2", "c-3"].map { StudIPCourse(id: $0, title: $0) }
        let d = try await StudIPTexts.fetch(client: client(t), courses: courses, known: [:], state: [:], today: "2026-11-02", base: "https://studip.test")
        XCTAssertEqual(d.stateSet["absent|forum|c-1"], "2026-11-16")
        XCTAssertEqual(d.stateSet["absent|forum|c-2"], "2026-11-16")
        XCTAssertEqual(d.stateSet["absent|forum|c-3"], "2026-11-16")
        XCTAssertNil(d.stateSet["absent|forum"], "zwei leere Foren schalten das Forum nicht fuer die Hochschule ab")
        XCTAssertEqual(d.stateSet["absent|wiki"], "2026-11-16", "403 ueberall: wie bisher an der Hochschule gemerkt")
        XCTAssertEqual(t.requested.filter { $0.contains("forum-categories") }.count, 3)

        // zwei Kurse mit 403 beim Forum und keiner mit Erfolg: weiterhin an der Hochschule gemerkt
        routes[p + "courses/c-1/forum-categories?page[limit]=50"] = json("{}", status: 403)
        routes[p + "courses/c-2/forum-categories?page[limit]=50"] = json("{}", status: 403)
        let d2 = try await StudIPTexts.fetch(client: client(StubTransport(routes)), courses: courses, known: [:], state: [:], today: "2026-11-02", base: "https://studip.test")
        XCTAssertEqual(d2.stateSet["absent|forum"], "2026-11-16")
    }

    /// LUH: Hinweistext im Link hinter der Anzahl (Info-Symbol) gehoert nicht zum Titel
    func testTopicWithTooltipTextAfterCount() {
        let html = """
        <ul class="sb-categories"><li><a href="plugins.php/schwarzesbrettplugin/category/view/0123456789abcdef0123456789abcdef">Umfragen (5) <span class="tooltip">Umfragen und Befragungen</span></a></li>
        <li><a href="plugins.php/schwarzesbrettplugin/category/view/fedcba9876543210fedcba9876543210">Studentische Arbeiten (43) Hier können Angebote eingestellt werden.</a></li></ul>
        """
        let t = StudIPBulletin.parseTopics(html: html)
        XCTAssertEqual(t.map(\.title), ["Umfragen", "Studentische Arbeiten"])
        XCTAssertEqual(t.map(\.count), [5, 43])
    }
}
