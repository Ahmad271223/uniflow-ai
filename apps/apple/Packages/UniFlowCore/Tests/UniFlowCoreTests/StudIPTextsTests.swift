import Foundation
import XCTest
@testable import UniFlowCore

// Lernstoff aus Stud.IP (Courseware-Fristen, Courseware, Wiki, Forum) gegen die Python-Referenz
// packages/shared-contracts/fixtures/studip-texts/texte.json (tools/gen-studip-texts-fixture.py, erfundene Antworten):
// dieselben Anfragen in derselben Reihenfolge, dieselben Texte, Fristen und Merker, dieselbe Modulansicht, Suche,
// Tutor-Quellen und Wochentest-Zeilen. Dazu: die Fristen erscheinen in "Abgaben & Prüfungen" mit Herkunft.

private func fixture() throws -> JSONValue {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return try JSONValue.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/studip-texts/texte.json")))
}

final class StudIPTextsTests: XCTestCase {

    private func transport(_ routes: JSONValue?, replace: JSONValue?) throws -> StubTransport {
        var r: [String: HTTPReply] = [:]
        for (k, v) in (routes?.object ?? [:]).merging(replace?.object ?? [:], uniquingKeysWith: { _, b in b }) {
            r[k] = HTTPReply(status: v["status"]?.int ?? 200, contentType: "application/vnd.api+json", body: try (v["body"] ?? .null).serialized())
        }
        return StubTransport(r)
    }

    private func courses(_ list: JSONValue?) -> [StudIPCourse] {
        (list?.array ?? []).map { StudIPCourse(id: $0["id"]?.string ?? "", title: $0["title"]?.string ?? "") }
    }

    private func open(_ clock: UniFlowClock) async throws -> (LocalBackend, SQLiteValue) {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let mid = try await backend.context.database.transaction { c -> SQLiteValue in
            try c.execute("INSERT INTO modules(name) VALUES ('Testanalysis')")
            let id = try c.scalar("SELECT last_insert_rowid()") ?? .null
            try c.execute("INSERT OR REPLACE INTO courses(id, title, module_id, active) VALUES ('c-ana', 'Testanalysis I', ?, 1)", [id])
            try c.execute("INSERT OR REPLACE INTO courses(id, title, module_id, active) VALUES ('c-prog', 'Testprogrammierung', NULL, 1)")
            return id
        }
        return (backend, mid)
    }

    /// Ein Lauf wie `run` im Generator: Stand lesen, abrufen, speichern; Anfragen und Tabellen wie in Python
    private func check(_ run: JSONValue, _ fx: JSONValue, _ backend: LocalBackend) async throws {
        let name = run["name"]?.string ?? ""
        let today = try XCTUnwrap(run["today"]?.string), now = try XCTUnwrap(run["now"]?.string)
        let t = try transport(fx["routes"].flatMap { run["courses"]?.string == "absent" ? .object([:]) : $0 }, replace: run["replace"])
        let client = StudIPClient(base: URL(string: "https://studip.test")!, transport: t, pauseMillis: 0)
        let db = backend.context.database
        let loaded: (known: StudIPTexts.Known, state: [String: String]) = try await db.withConnection { try StudIPTexts.load($0) }
        let known = loaded.known, state = loaded.state
        let list = courses(run["courses"]?.string == "absent" ? fx["absent_courses"] : fx["courses"])
        let d = try await StudIPTexts.fetch(client: client, courses: list, known: known, state: state, today: today, base: "https://studip.test",
                                            budget: run["budget"]?.int ?? StudIPTexts.maxRequests)
        let res = try await db.transaction { try StudIPTexts.store($0, d, now: now) }
        XCTAssertEqual(t.requested, (run["log"]?.array ?? []).compactMap(\.string), name)
        XCTAssertEqual(d.requests, run["requests"]?.int, name)
        XCTAssertEqual(d.stopped, run["stopped"]?.bool, name)
        XCTAssertEqual(res.texts, run["result"]?["texts"]?.int, name)
        XCTAssertEqual(res.deadlines, run["result"]?["deadlines"]?.int, name)
        let texts: JSONValue = .array(try await db.rows("SELECT id, course_id, kind, title, text, url, changed, fetched_at FROM studip_texts ORDER BY id").map(JSONValue.object))
        XCTAssertNil(jsonDiff(texts, run["texts"]), "\(name): " + (jsonDiff(texts, run["texts"]) ?? ""))
        let dls: JSONValue = .array(try await db.rows("""
            SELECT id, source, course_id, title, full_title, kind, module, due_at, url, overdue, fetched_at FROM deadlines WHERE source='studip' ORDER BY id
            """).map(JSONValue.object))
        XCTAssertNil(jsonDiff(dls, run["deadlines"]), "\(name): " + (jsonDiff(dls, run["deadlines"]) ?? ""))
        let st: JSONValue = .array(try await db.rows("SELECT key, value FROM studip_text_state ORDER BY key").map(JSONValue.object))
        XCTAssertNil(jsonDiff(st, run["state"]), "\(name): " + (jsonDiff(st, run["state"]) ?? ""))
    }

    func testRunsMatchPython() async throws {
        let fx = try fixture()
        let runs = fx["runs"]?.array ?? []
        XCTAssertEqual(runs.count, 6)
        let clock = UniFlowClock.fixed(berlin: "2026-11-02T09:00:00")!
        let (main, mid) = try await open(clock)
        for r in runs.prefix(2) { try await check(r, fx, main) }
        // nach dem zweiten Lauf wie im Generator: Modulansicht, Leser, Suche, KI-Quellen, Wochentest
        let db = main.context.database
        let overview = try await db.withConnection { try StudIPTexts.overview($0, moduleID: mid) }
        XCTAssertNil(jsonDiff(overview, fx["overview"]), jsonDiff(overview, fx["overview"]) ?? "")
        let item = try await db.withConnection { try StudIPTexts.item($0, id: "forum-f1") }
        XCTAssertNil(jsonDiff(item, fx["item"]), jsonDiff(item, fx["item"]) ?? "")
        for (q, expected) in fx["search"]?.object ?? [:] {
            let got: JSONValue = .array(try await db.withConnection { try StudIPTexts.search($0, moduleID: mid, query: q) })
            XCTAssertNil(jsonDiff(got, expected), "\(q): " + (jsonDiff(got, expected) ?? ""))
        }
        let tutor: JSONValue = .array(try await db.withConnection {
            try StudIPTexts.tutorSources($0, moduleID: mid, query: "Wie zeige ich die Konvergenz der Folge?", start: 3)
        })
        XCTAssertNil(jsonDiff(tutor, fx["tutor_sources"]), jsonDiff(tutor, fx["tutor_sources"]) ?? "")
        let weekly = try await db.withConnection { try StudIPTexts.weeklyLines($0, moduleID: mid, query: "Folgen und Grenzwert Konvergenz") }
        XCTAssertEqual(weekly, (fx["weekly_lines"]?.array ?? []).compactMap(\.string))
        try await check(runs[2], fx, main)
        let (knapp, _) = try await open(clock)
        try await check(runs[3], fx, knapp)
        let (absent, _) = try await open(clock)
        try await check(runs[4], fx, absent)
        try await check(runs[5], fx, absent)
    }

    func testTextHelpersMatchPython() throws {
        let cases = try XCTUnwrap(try fixture()["cases"])
        for (k, v) in cases["berlin_local"]?.object ?? [:] {
            XCTAssertEqual(StudIPTexts.berlinLocal(.string(k)), v.string, k)
        }
        for (k, v) in cases["markup"]?.object ?? [:] { XCTAssertEqual(StudIPTexts.markupToText(k), v.string, k) }
        for (k, v) in cases["anonymize"]?.object ?? [:] { XCTAssertEqual(StudIPTexts.anonymize(k), v.string, k) }
        for (k, v) in cases["cut"]?.object ?? [:] { XCTAssertEqual(StudIPTexts.cut(k, 12), v.string, k) }
        // gespeicherte Texte ganz, ohne "…" (Inhaber 03.11.2026)
        let full = cases["full"]?.object ?? [:]
        XCTAssertEqual(full.count, 2)
        for (k, v) in full {
            XCTAssertEqual(StudIPTexts.full(k), v.string, k)
            XCTAssertFalse(v.string?.contains("…") ?? true)
        }
        XCTAssertTrue(full.values.contains { ($0.string?.count ?? 0) > 1000 })
    }

    /// Courseware-Fristen stehen in "Abgaben & Prüfungen" des Moduls mit Herkunft und Link, im Lernkalender als Frist;
    /// der Bereich "Aus Stud.IP" antwortet ueber den lokalen Router, ein unbekannter Text mit 404
    func testDeadlinesAppearWhereDeadlinesAreAndEndpointsAnswer() async throws {
        let fx = try fixture()
        let clock = UniFlowClock.fixed(berlin: "2026-11-02T09:00:00")!
        let (backend, mid) = try await open(clock)
        try await check(try XCTUnwrap(fx["runs"]?.array?.first), fx, backend)
        let due = await backend.handle(LocalRequest(method: "GET", path: "/api/due", query: [.init("module_id", mid.int.map(String.init) ?? "")]))
        XCTAssertEqual(due.status, 200)
        let items = try JSONValue.parse(due.body)["items"]?.array ?? []
        let cw = items.filter { $0["source"]?.string == "studip" }
        XCTAssertEqual(cw.compactMap { $0["title"]?.string }, ["Übungsblatt 3", "Hausaufgabe Reihen", "Projekt"])
        XCTAssertEqual(cw.first?["origin"]?.string, "aus Stud.IP Courseware")
        XCTAssertEqual(cw.first?["kind_label"]?.string, "Abgabe")
        XCTAssertTrue(cw.first?["url"]?.string?.contains("courseware/tasks?cid=c-ana") ?? false)

        let o = await backend.handle(LocalRequest(method: "GET", path: "/api/modules/\(mid.int ?? 0)/studip"))
        XCTAssertEqual(o.status, 200)
        XCTAssertEqual(try JSONValue.parse(o.body)["total"]?.int, 5)
        let one = await backend.handle(LocalRequest(method: "GET", path: "/api/studip-texts/wiki-w1"))
        XCTAssertEqual(try JSONValue.parse(one.body)["title"]?.string, "Klausurinfos")
        let none = await backend.handle(LocalRequest(method: "GET", path: "/api/studip-texts/gibt-es-nicht"))
        XCTAssertEqual(none.status, 404)
        // Prompt der KI-Hilfe: Stud.IP-Quelle ohne Seitenzahl, mit Herkunft
        let src = try await backend.context.database.withConnection {
            try StudIPTexts.tutorSources($0, moduleID: mid, query: "Konvergenz der Folge", start: 2)
        }
        let prompt = AIPrompts.tutor(mode: "ask", pageText: "Seite", question: "Konvergenz?", sources: src.map(PyJSON.init))
        let title = try XCTUnwrap(src.first?["title"]?.string)
        XCTAssertTrue(prompt.contains("[2] \(title) (Stud.IP): "), prompt)
        XCTAssertFalse(prompt.contains("Seite null") || prompt.contains("Seite None"), prompt)
    }

    /// Abgelaufene Sitzung: sofort Schluss, nichts gespeichert
    func testSessionExpiryStops() async throws {
        let t = StubTransport(["/jsonapi.php/v1/courseware-tasks?filter[cid]=c1&include=task-group,structural-element&page[limit]=100":
                                HTTPReply(status: 401, contentType: "application/vnd.api+json")])
        let client = StudIPClient(base: URL(string: "https://studip.test")!, transport: t, pauseMillis: 0)
        do {
            _ = try await StudIPTexts.fetch(client: client, courses: [StudIPCourse(id: "c1", title: "A"), StudIPCourse(id: "c2", title: "B")],
                                            known: [:], state: [:], today: "2026-11-02", base: "https://studip.test")
            XCTFail("abgelaufene Sitzung erwartet")
        } catch StudIPError.sessionExpired {}
        XCTAssertEqual(t.requested.count, 1)
    }
}
