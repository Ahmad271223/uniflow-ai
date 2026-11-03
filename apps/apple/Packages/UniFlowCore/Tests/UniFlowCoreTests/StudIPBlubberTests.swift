import Foundation
import XCTest
@testable import UniFlowCore

// Blubber aus Stud.IP (03.11.2026, `StudIPBlubber`): eine Liste aller eigenen Threads (nie die Kurs-Route, die in
// Stud.IP einen Thread anlegen kann), nur gewaehlte Kurse und der Stud.IP-weite Thread, je geaendertem Thread die
// neuesten 20 Beitraege, Rolle statt Name, Erwaehnungen entfernt, 30-Tage-Merker, Endpunkte und Neuigkeiten.

private func api(_ json: String, status: Int = 200) -> HTTPReply {
    HTTPReply(status: status, contentType: "application/vnd.api+json", body: Data(json.utf8))
}

private let listPath = "/jsonapi.php/v1/blubber-threads?page[limit]=40&include=author"
private func commentsPath(_ id: String) -> String { "/jsonapi.php/v1/blubber-threads/\(id)/comments?sort=-mkdate&page[limit]=20&include=author" }

private let usersIncluded = """
    {"type": "users", "id": "doz", "attributes": {"formatted-name": "Prof. Erika Mustermann", "family-name": "Mustermann", "permission": "dozent"}},
    {"type": "users", "id": "tut", "attributes": {"formatted-name": "Max Tutor", "family-name": "Tutor", "permission": "tutor"}},
    {"type": "users", "id": "stu", "attributes": {"formatted-name": "Lena Beispiel", "family-name": "Beispiel", "permission": "autor"}},
    {"type": "users", "id": "me", "attributes": {"formatted-name": "Ich Selbst", "permission": "autor"}}
"""

/// t-ana: Standard-Thread von Analysis (ohne Text); t-ana2: Thread mit Eroeffnung; global; privat; anderer Kurs;
/// Einrichtung; fremder oeffentlicher Thread
private let threadsJSON = """
{"data": [
  {"type": "blubber-threads", "id": "t-ana", "attributes": {"name": "Analysis I", "context-type": "course", "content": null, "content-html": "",
     "latest-activity": "2026-11-02T09:30:00+01:00", "mkdate": "2026-10-12T08:00:00+02:00"},
   "relationships": {"author": {"data": {"type": "users", "id": "doz"}}, "context": {"data": {"type": "courses", "id": "c-ana"}}}},
  {"type": "blubber-threads", "id": "t-ana2", "attributes": {"name": "Analysis I", "context-type": "course",
     "content": "Fragen zur Klausur hier sammeln, @\\"Lena Beispiel\\" schaut mit.", "latest-activity": "2026-10-20T10:00:00+02:00", "mkdate": "2026-10-20T10:00:00+02:00"},
   "relationships": {"author": {"data": {"type": "users", "id": "tut"}}, "context": {"data": {"type": "courses", "id": "c-ana"}}}},
  {"type": "blubber-threads", "id": "global", "attributes": {"name": "Globaler Blubber", "context-type": "public", "content": "",
     "latest-activity": "2026-11-01T18:00:00+01:00", "mkdate": "2020-01-01T00:00:00+01:00"},
   "relationships": {"context": {"data": null}}},
  {"type": "blubber-threads", "id": "t-priv", "attributes": {"name": "Lena Beispiel", "context-type": "private", "content": "geheim",
     "latest-activity": "2026-11-02T08:00:00+01:00"}, "relationships": {"context": {"data": null}}},
  {"type": "blubber-threads", "id": "t-other", "attributes": {"context-type": "course", "latest-activity": "2026-11-02T08:00:00+01:00"},
   "relationships": {"context": {"data": {"type": "courses", "id": "c-alt"}}}},
  {"type": "blubber-threads", "id": "t-inst", "attributes": {"context-type": "institute", "latest-activity": "2026-11-02T08:00:00+01:00"},
   "relationships": {"context": {"data": {"type": "institutes", "id": "i1"}}}},
  {"type": "blubber-threads", "id": "t-pub", "attributes": {"name": "Blubber von Lena Beispiel", "context-type": "public", "content": "Hallo Welt",
     "latest-activity": "2026-11-02T08:00:00+01:00"}, "relationships": {"author": {"data": {"type": "users", "id": "stu"}}, "context": {"data": null}}}
],
"included": [\(usersIncluded)]}
"""

private func comment(_ id: String, _ author: String?, _ content: String, _ date: String) -> String {
    let rel = author.map { #""author": {"data": {"type": "users", "id": "\#($0)"}},"# } ?? ""
    return """
    {"type": "blubber-comments", "id": "\(id)", "attributes": {"content": \(String(data: try! JSONSerialization.data(withJSONObject: [content]), encoding: .utf8)!.dropFirst().dropLast()),
     "content-html": "<p>x</p>", "mkdate": "\(date)", "chdate": "\(date)"},
     "relationships": {\(rel) "thread": {"data": {"type": "blubber-threads", "id": "t"}}}}
    """
}

private func comments(_ items: [String]) -> HTTPReply {
    api(#"{"data": [\#(items.joined(separator: ","))], "included": [\#(usersIncluded)]}"#)
}

/// Analysis-Standard-Thread: 25 Beitraege (neueste zuerst), Rollen gemischt, mit Erwaehnung und Zitat
private func anaComments() -> HTTPReply {
    var items = [
        comment("k1", "doz", "Die Übung am [Lena Beispiel]https://studip.test/dispatch.php/profile?username=lbeispiel fällt aus.", "2026-11-02T09:30:00+01:00"),
        comment("k2", "stu", "[quote=Max Tutor]alter Text[/quote] Danke! Gibt es eine Ersatzübung?", "2026-11-01T20:15:00+01:00"),
        comment("k3", "me", "Ich bringe Kekse mit @mmuster", "2026-11-01T19:00:00+01:00"),
        comment("k4", nil, "Externer Gast fragt nach Skript", "2026-10-30T12:00:00+01:00"),
        comment("k5", "tut", "Siehe [Folien]https://example.org/folien.pdf und **wichtig**", "2026-10-20T08:00:00+02:00"),
        comment("k6", "stu", "   ", "2026-10-19T08:00:00+02:00"),
    ]
    for i in 7...25 { items.append(comment("k\(i)", "stu", "Alt \(i) " + String(repeating: "lang ", count: 120), "2026-10-0\(min(9, max(1, 30 - i)))T08:00:00+02:00")) }
    return comments(items)
}

final class StudIPBlubberTests: XCTestCase {

    private let base = "https://studip.test"
    private func client(_ t: StubTransport) -> StudIPClient { StudIPClient(base: URL(string: base)!, transport: t, pauseMillis: 0) }

    // MARK: Lesen

    func testThreadsOnlySelectedCoursesAndGlobalWithoutNames() throws {
        let j = try JSONValue.parse(Data(threadsJSON.utf8))
        let ts = StudIPBlubber.parseThreads(j, courseIDs: ["c-ana"], userID: "me", base: base + "/")
        XCTAssertEqual(ts.map(\.id), ["t-ana", "t-ana2", "global"], "nur gewaehlter Kurs und der Stud.IP-weite Thread, nie privat/Einrichtung/fremd")
        XCTAssertEqual(ts[0].courseID, "c-ana")
        XCTAssertNil(ts[2].courseID)
        XCTAssertNil(ts[0].opening, "Standard-Thread ohne eigenen Text")
        XCTAssertEqual(ts[0].url, "https://studip.test/dispatch.php/course/messenger/course/t-ana?cid=c-ana")
        XCTAssertEqual(ts[2].url, "https://studip.test/dispatch.php/blubber/index/global")
        let o = try XCTUnwrap(ts[1].opening)
        XCTAssertEqual(o.authorRole, "Tutor/in")
        XCTAssertEqual(o.text, "Fragen zur Klausur hier sammeln, @Person schaut mit.")
        XCTAssertEqual(o.postedAt, "2026-10-20T10:00:00")
        XCTAssertEqual(ts[0].latestActivity, "2026-11-02T09:30:00+01:00")
    }

    func testCommentsMapRolesStripMentionsAndCut() throws {
        let j = try JSONValue.parse(anaComments().body)
        let t = StudIPBlubber.Thread(id: "t-ana", courseID: "c-ana", latestActivity: "x", url: "u", opening: nil)
        let ps = StudIPBlubber.parseComments(j, thread: t, userID: "me")
        XCTAssertEqual(ps.count, 20, "hoechstens 20, leere Beitraege fallen weg")
        XCTAssertEqual(ps.prefix(5).map(\.authorRole), ["Lehrende", "Studierende", "du", "Teilnehmende", "Tutor/in"])
        XCTAssertEqual(ps[0].text, "Die Übung am @Person fällt aus.")
        XCTAssertEqual(ps[1].text, "Danke! Gibt es eine Ersatzübung?")
        XCTAssertEqual(ps[2].text, "Ich bringe Kekse mit @Person")
        XCTAssertEqual(ps[4].text, "Siehe Folien und wichtig")
        XCTAssertEqual(ps[0].postedAt, "2026-11-02T09:30:00")
        XCTAssertEqual(ps[0].id, "bc-k1")
        XCTAssertTrue(ps.allSatisfy { $0.text.unicodeScalars.count <= StudIPBlubber.maxText + 2 })
        for p in ps {
            for name in ["Mustermann", "Beispiel", "Tutor ", "Max", "Lena", "Erika", "lbeispiel", "mmuster", "Selbst"] {
                XCTAssertFalse(p.text.contains(name) || p.authorRole.contains(name), "Name \(name) in \(p)")
            }
        }
    }

    // MARK: Abruf, Speicher, Endpunkte

    private func routes(ana: HTTPReply = anaComments()) -> [String: HTTPReply] {
        [listPath: api(threadsJSON),
         commentsPath("t-ana"): ana,
         commentsPath("t-ana2"): comments([comment("m1", "stu", "Wann ist die Klausur?", "2026-10-21T10:00:00+02:00")]),
         commentsPath("global"): comments([comment("g1", "stu", "Mensa heute offen?", "2026-11-01T18:00:00+01:00")])]
    }

    private func seededBackend(_ clock: UniFlowClock) async throws -> LocalBackend {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        try await backend.context.database.withConnection { c in
            try c.execute("INSERT INTO modules(name, color) VALUES ('Analysis', '#ff0000')")
            let mid = try c.scalar("SELECT id FROM modules WHERE name='Analysis'")?.int ?? 0
            try c.execute("INSERT INTO courses(id, title, module_id, active) VALUES ('c-ana', 'Analysis I', ?, 1)", [.integer(Int64(mid))])
            try c.execute("INSERT INTO modules(name) VALUES ('Leer')")
        }
        return backend
    }

    func testFetchStoreEndpointsAndFeed() async throws {
        let clock = try XCTUnwrap(UniFlowClock.fixed(berlin: "2026-11-02T12:00:00"))
        let t = StubTransport(routes())
        let d = await StudIPBlubber.fetch(client: client(t), userID: "me", courseIDs: ["c-ana"], missing: [:], known: [:], today: clock.today)
        XCTAssertFalse(d.sessionExpired)
        XCTAssertEqual(t.requested, [listPath, commentsPath("t-ana"), commentsPath("t-ana2"), commentsPath("global")],
                       "eine Liste, dann je Thread die Kommentare; nie courses/{id}/blubber-threads, nie PATCH")
        XCTAssertFalse(t.requested.contains { $0.contains("/courses/") || $0.contains("t-priv") || $0.contains("t-pub") })
        XCTAssertEqual(d.posts["t-ana"]?.count, 20)
        XCTAssertEqual(d.posts["t-ana2"]?.count, 2, "Kommentar und Eroeffnung")

        let backend = try await seededBackend(clock)
        let db = backend.context.database
        try await db.transaction { try StudIPBlubber.store(d, in: $0, clock: clock) }
        let n = try await db.withConnection { try $0.scalar("SELECT count(*) FROM studip_blubber")?.int }
        XCTAssertEqual(n, 23)
        // keine Namen in der Tabelle
        let dump = try await db.withConnection { c in try c.rows("SELECT * FROM studip_blubber").map { "\($0)" }.joined() }
        for name in ["Mustermann", "Beispiel", "Lena", "Erika", "lbeispiel", "Selbst", "Max Tutor"] { XCTAssertFalse(dump.contains(name), name) }
        let globalCourse = try await db.withConnection { try $0.scalar("SELECT count(*) FROM studip_blubber WHERE course_id IS NULL")?.int }
        XCTAssertEqual(globalCourse, 1)

        // Uebersicht je Kurs und Modul
        let mid = try await db.withConnection { try $0.scalar("SELECT id FROM modules WHERE name='Analysis'")?.int } ?? 0
        let byModule = try JSONValue.parse(await backend.handle(LocalRequest(method: "GET", path: "/api/studip/blubber", query: [.init("module", "\(mid)")])).body)
        XCTAssertEqual(byModule["threads"]?.array?.map { $0["id"]?.string }, ["t-ana", "t-ana2"], "neuester Beitrag zuerst, ohne Stud.IP-weit")
        let ana = try XCTUnwrap(byModule["threads"]?.array?.first)
        XCTAssertEqual(ana["count"]?.int, 20)
        XCTAssertEqual(ana["new_count"]?.int, 3, "letzte 7 Tage, ohne eigene Beitraege: k1, k2, k4")
        XCTAssertEqual(ana["course_title"]?.string, "Analysis I")
        XCTAssertEqual(ana["preview"]?.string, "Lehrende: Die Übung am @Person fällt aus.")
        XCTAssertEqual(byModule["count"]?.int, 22)
        let byCourse = try JSONValue.parse(await backend.handle(LocalRequest(method: "GET", path: "/api/studip/blubber", query: [.init("course", "c-ana")])).body)
        XCTAssertEqual(byCourse["threads"]?.array?.count, 2)
        let all = try JSONValue.parse(await backend.handle(LocalRequest(method: "GET", path: "/api/studip/blubber")).body)
        XCTAssertEqual(all["threads"]?.array?.count, 3)
        XCTAssertEqual(all["fetched_at"]?.string, "2026-11-02T12:00:00")
        let empty = try JSONValue.parse(await backend.handle(LocalRequest(method: "GET", path: "/api/studip/blubber", query: [.init("module", "\(mid + 1)")])).body)
        XCTAssertEqual(empty["threads"]?.array?.count, 0)
        let bad = await backend.handle(LocalRequest(method: "GET", path: "/api/studip/blubber", query: [.init("module", "x")]))
        XCTAssertEqual(bad.status, 422)

        // Leser: aelteste zuerst, Rolle statt Name
        let th = await backend.handle(LocalRequest(method: "GET", path: "/api/studip/blubber/t-ana2"))
        XCTAssertEqual(th.status, 200)
        let tj = try JSONValue.parse(th.body)
        XCTAssertEqual(tj["comments"]?.array?.map { $0["role"]?.string }, ["Tutor/in", "Studierende"])
        XCTAssertEqual(tj["comments"]?.array?.first?["text"]?.string, "Fragen zur Klausur hier sammeln, @Person schaut mit.")
        XCTAssertEqual(tj["url"]?.string, "https://studip.test/dispatch.php/course/messenger/course/t-ana2?cid=c-ana")
        let missing = await backend.handle(LocalRequest(method: "GET", path: "/api/studip/blubber/nein"))
        XCTAssertEqual(missing.status, 404)

        // Neuigkeiten: eine Zeile je Thread mit neuen Beitraegen
        let news = try JSONValue.parse(await backend.handle(LocalRequest(method: "GET", path: "/api/news")).body)
        let lines = news["items"]?.array?.filter { $0["kind"]?.string == "blubber" } ?? []
        XCTAssertEqual(lines.map { $0["title"]?.string }, ["Blubber in Analysis I: 3 neue Beiträge", "Blubber Stud.IP-weit: 1 neuer Beitrag"])
        XCTAssertEqual(lines.first?["at"]?.string, "2026-11-02T09:30:00")
        XCTAssertEqual(lines.first?["color"]?.string, "#ff0000")
        XCTAssertEqual(StudIPBlubber.feedTitle(course: "X", global: false, count: 1), "Blubber in X: 1 neuer Beitrag")

        // zweiter Abruf: unveraenderte Threads werden nicht erneut gelesen; ein verschwundener Thread faellt weg
        let known = try await db.withConnection { try StudIPBlubber.known($0) }
        XCTAssertEqual(known.count, 3)
        let fewer = threadsJSON.replacingOccurrences(of: #""id": "t-ana2""#, with: #""id": "t-weg""#)
        var r2 = routes()
        r2[listPath] = api(fewer)
        let t2 = StubTransport(r2)
        let d2 = await StudIPBlubber.fetch(client: client(t2), userID: "me", courseIDs: ["c-ana"], missing: [:], known: known, today: clock.today)
        XCTAssertEqual(t2.requested, [listPath, commentsPath("t-weg")], "nur der neue Thread")
        try await db.transaction { try StudIPBlubber.store(d2, in: $0, clock: clock) }
        let ids = try await db.withConnection { try $0.rows("SELECT DISTINCT thread_id FROM studip_blubber ORDER BY thread_id").compactMap { $0["thread_id"]?.string } }
        XCTAssertEqual(ids, ["global", "t-ana"], "t-ana bleibt (unveraendert), t-ana2 weg, t-weg ohne Beitraege")
    }

    func testMissingEndpointRememberedThirtyDaysAndSessionKeepsStock() async throws {
        let t = StubTransport([:])                              // 404
        let d = await StudIPBlubber.fetch(client: client(t), userID: "me", courseIDs: ["c-ana"], missing: [:], known: [:], today: "2026-11-02")
        XCTAssertNil(d.threads)
        XCTAssertEqual(d.missing[StudIPBlubber.missingName]?.string, "2026-11-02")
        let t2 = StubTransport(routes())
        let soon = await StudIPBlubber.fetch(client: client(t2), userID: "me", courseIDs: ["c-ana"], missing: d.missing, known: [:], today: "2026-11-20")
        XCTAssertEqual(t2.requested, [], "innerhalb von 30 Tagen nicht gefragt")
        XCTAssertNil(soon.threads)
        let later = await StudIPBlubber.fetch(client: client(t2), userID: "me", courseIDs: ["c-ana"], missing: d.missing, known: [:], today: "2026-12-02")
        XCTAssertNotNil(later.threads)
        XCTAssertNil(later.missing[StudIPBlubber.missingName])

        // Sitzung abgelaufen (HTML statt JSON): nichts gelesen, Bestand bleibt
        let clock = try XCTUnwrap(UniFlowClock.fixed(berlin: "2026-11-02T12:00:00"))
        let backend = try await seededBackend(clock)
        try await backend.context.database.transaction { try StudIPBlubber.store(later, in: $0, clock: clock) }
        let html = StubTransport([listPath: HTTPReply(status: 200, contentType: "text/html", body: Data("<html>login</html>".utf8))])
        let e = await StudIPBlubber.fetch(client: client(html), userID: "me", courseIDs: ["c-ana"], missing: [:], known: [:], today: "2026-11-02")
        XCTAssertTrue(e.sessionExpired)
        try await backend.context.database.transaction { try StudIPBlubber.store(e, in: $0, clock: clock) }
        let n = try await backend.context.database.withConnection { try $0.scalar("SELECT count(*) FROM studip_blubber")?.int }
        XCTAssertEqual(n, 23)
    }

    /// Hoechstens `maxThreads` Kommentar-Listen je Lauf
    func testRequestBudget() async throws {
        var data: [String] = []
        for i in 0..<30 {
            data.append(#"{"type": "blubber-threads", "id": "t\#(i)", "attributes": {"context-type": "course", "latest-activity": "2026-11-02T08:00:00+01:00"}, "relationships": {"context": {"data": {"type": "courses", "id": "c\#(i % 3)"}}}}"#)
        }
        let t = StubTransport([listPath: api(#"{"data": [\#(data.joined(separator: ","))]}"#)])
        let d = await StudIPBlubber.fetch(client: client(t), userID: "me", courseIDs: ["c0", "c1", "c2"], missing: [:], known: [:], today: "2026-11-02")
        XCTAssertEqual(d.threads?.count, 30)
        XCTAssertEqual(t.requested.count, 1 + StudIPBlubber.maxThreads)
        XCTAssertEqual(d.requests, 1 + StudIPBlubber.maxThreads)
    }
}
