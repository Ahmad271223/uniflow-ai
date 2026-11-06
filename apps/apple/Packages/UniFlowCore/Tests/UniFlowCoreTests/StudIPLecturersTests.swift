import Foundation
import XCTest
@testable import UniFlowCore

// Lehrende und Kontakte (LUH, Stud.IP, 06.11.2026) gegen die Python-Referenz
// packages/shared-contracts/fixtures/studip-lecturers/lecturers.json (tools/gen-studip-lecturers-fixture.py, erfundene
// JSON:API-Antworten, nur example.org): Lesen nur von Dozent/innen und Tutor/innen, E-Mail nur wenn plausibel,
// Sprechzeiten, Abruf in derselben Reihenfolge wie Python, 7 Tage Ruhe je Kurs, fehlende Route 30 Tage, GET /api/lecturers.

private func fixture() throws -> JSONValue {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return try JSONValue.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/studip-lecturers/lecturers.json")))
}

private func same(_ got: JSONValue, _ want: JSONValue?, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertNil(jsonDiff(got, want), "\(what): \(jsonDiff(got, want) ?? "")", file: file, line: line)
}

final class StudIPLecturersTests: XCTestCase {

    func testRulesMatchPython() throws {
        let fx = try fixture()
        for c in fx["display_name"]?.array ?? [] {
            XCTAssertEqual(StudIPLecturers.displayName(c["attrs"]), c["name"]?.string, "\(c)")
        }
        for c in fx["clean_email"]?.array ?? [] {
            XCTAssertEqual(StudIPLecturers.cleanEmail(c["value"]), c["email"]?.string, "\(c)")
        }
        let base = try XCTUnwrap(fx["base"]?.string)
        for c in fx["message_url"]?.array ?? [] {
            XCTAssertEqual(StudIPLecturers.messageURL(base: base, username: c["username"]?.string ?? ""), c["url"]?.string)
        }
        XCTAssertEqual(StudIPLecturers.roleLabel(["tutor", "dozent"]), "Dozent/in, Tutor/in")
        XCTAssertNil(StudIPLecturers.mailto(""))
    }

    func testMembersAndProfilesMatchPython() throws {
        let fx = try fixture()
        for m in fx["members"]?.array ?? [] {
            same(.array(StudIPLecturers.parseMembers(m["response"]).map(\.json)), m["items"], m["path"]?.string ?? "")
        }
        let mu = fx["merge_user"] ?? .null
        let member = try XCTUnwrap(StudIPLecturers.parseMembers(
            fx["sync"]?["routes"]?["courses/k-ana/memberships?filter[permission]=tutor&page[limit]=100"]?["body"]).first)
        same(member.json, mu["member"], "ohne include")
        same(StudIPLecturers.mergeUser(member, mu["response"]).json, mu["merged"], "users/{id}")
        for p in fx["profiles"]?.array ?? [] {
            same(StudIPLecturers.parseProfile(p["response"]).json, p["parsed"], p["path"]?.string ?? "")
        }
        // nie Studierende
        let all = (fx["members"]?.array ?? []).flatMap { StudIPLecturers.parseMembers($0["response"]) }
        XCTAssertFalse(all.contains { $0.userID == "u-stud" })
    }

    private func seededBackend(_ fx: JSONValue, clock: UniFlowClock) async throws -> LocalBackend {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let db = fx["db"] ?? .null
        try await backend.context.database.transaction { c in
            for m in db["modules"]?.array ?? [] {
                try c.execute("INSERT INTO modules(id, name) VALUES (?, ?)", [.integer(Int64(m.array?[0].int ?? 0)), .text(m.array?[1].string ?? "")])
            }
            for k in db["courses"]?.array ?? [] {
                let a = k.array ?? []
                try c.execute("INSERT INTO courses(id, title, module_id, active, created_at) VALUES (?,?,?,?, 't')",
                              [.text(a[0].string ?? ""), .text(a[1].string ?? ""), a[2].int.map { .integer(Int64($0)) } ?? .null,
                               .integer(Int64(a[3].int ?? 0))])
            }
            try StudIPLecturers.ensure(c)
            for p in db["preset"]?.array ?? [] {
                let a = p.array ?? []
                try c.execute("INSERT INTO studip_lecturers VALUES (?,?,?,?,?,?,?,?,?,?,?,?)", a.enumerated().map { i, v in
                    i == 3 ? .integer(Int64(v.int ?? 0)) : .text(v.string ?? "")
                })
            }
            for p in db["preset_courses"]?.array ?? [] {
                try c.execute("INSERT INTO studip_lecturer_courses VALUES (?,?)", [.text(p.array?[0].string ?? ""), .text(p.array?[1].string ?? "")])
            }
        }
        return backend
    }

    private func transport(_ fx: JSONValue) throws -> StubTransport {
        var routes: [String: HTTPReply] = [:]
        for (path, r) in fx["sync"]?["routes"]?.object ?? [:] {
            let status = r["status"]?.int ?? 404
            let body = (r["body"] ?? .null).isNull ? Data(#"{"errors":[]}"#.utf8) : (r["body"] ?? .null).serialized()
            routes["/jsonapi.php/v1/" + path] = HTTPReply(status: status, contentType: "application/vnd.api+json", body: body)
        }
        return StubTransport(routes)
    }

    func testSyncMatchesPythonRequestsAndTables() async throws {
        let fx = try fixture()
        let clock = try XCTUnwrap(UniFlowClock.fixed(berlin: "2026-11-06T10:00:00"))
        let backend = try await seededBackend(fx, clock: clock)
        let t = try transport(fx)
        let client = StudIPClient(base: URL(string: "https://studip.test")!, transport: t, pauseMillis: 0)
        let ids = (fx["sync"]?["course_ids"]?.array ?? []).compactMap(\.string)
        let today = try XCTUnwrap(BerlinClock.parseISODate("2026-11-06"))
        let (due, missing) = try await backend.context.database.withConnection {
            (try StudIPLecturers.due($0, courseIDs: ids, today: today), try StudIPExtras.loadMissing($0))
        }
        let d = await StudIPLecturers.fetch(client: client, due: due, missing: missing, today: today)
        XCTAssertFalse(d.sessionExpired)
        XCTAssertEqual(d.requests, (fx["sync"]?["requests"]?.array ?? []).compactMap(\.string))
        XCTAssertEqual(t.requested, d.requests.map { "/jsonapi.php/v1/" + $0 })
        same(d.summary, fx["sync"]?["result"], "Ergebnis")
        let now = try XCTUnwrap(fx["now"]?.string)
        try await backend.context.database.transaction { try StudIPLecturers.store(d, in: $0, fetchedAt: now) }
        let after = fx["sync"]?["after"] ?? .null
        let (lect, done, settings) = try await backend.context.database.withConnection { c in
            (try c.rows("SELECT * FROM studip_lecturers ORDER BY 1, 2"), try c.rows("SELECT * FROM studip_lecturer_courses ORDER BY 1, 2"),
             try c.rows("SELECT key, value FROM settings WHERE key='studip_missing_endpoints'"))
        }
        let cols = ["course_id", "user_id", "role", "position", "label", "name", "username", "email", "office_hours", "location", "institute", "fetched_at"]
        same(.array(lect.map { r in .array(cols.map { r[$0] ?? .null }) }), after["studip_lecturers"], "Tabelle studip_lecturers")
        same(.array(done.map { r in .array([r["course_id"] ?? .null, r["fetched_at"] ?? .null]) }), after["studip_lecturer_courses"], "gelesene Kurse")
        XCTAssertEqual(settings.first?["value"]?.string, after["settings"]?.array?.first?.array?[1].string)

        // am selben Tag: nur der Kurs, der noch nie gelesen wurde (Python: second)
        let due2 = try await backend.context.database.withConnection { try StudIPLecturers.due($0, courseIDs: ids, today: today) }
        let t2 = try transport(fx)
        let d2 = await StudIPLecturers.fetch(client: StudIPClient(base: URL(string: "https://studip.test")!, transport: t2, pauseMillis: 0),
                                             due: due2, missing: [:], today: today)
        XCTAssertEqual(d2.requests, (fx["sync"]?["second"]?["requests"]?.array ?? []).compactMap(\.string))

        // GET /api/lecturers fuer alle Abfragen der Fixture
        let base = try XCTUnwrap(fx["base"]?.string)
        for o in fx["overview"]?.array ?? [] {
            let q = o["query"] ?? .null
            let got = try await backend.context.database.withConnection { c in
                try StudIPLecturers.overview(c, university: q["university"]?.string ?? "", base: base, courseID: q["course_id"]?.string,
                                             moduleID: q["module_id"]?.int, q: q["q"]?.string, allowed: q["allowed"]?.bool ?? true)
            }
            same(got, o["result"], "overview \(q)")
        }
        // Endpunkt des lokalen Backends (Hochschule aus den Einstellungen, Vorgabe LUH)
        let r = await backend.handle(LocalRequest(method: "GET", path: "/api/lecturers", query: [.init("module_id", "1")]))
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.json?["people"]?.array?.first?["email"]?.string, "erika.beispiel@example.org")
        let prof = try await backend.context.database.withConnection { try StudIPLecturers.knownPerson($0, userID: "u-prof") }
        XCTAssertEqual(prof?.name, "Prof. Dr. Erika Beispiel")
        let unknown = try await backend.context.database.withConnection { try StudIPLecturers.knownPerson($0, userID: "u-stud") }
        XCTAssertNil(unknown, "Studierende stehen nie in der Tabelle")
    }

    func testMissingRouteRestsAndEmptyOverview() async throws {
        let fx = try fixture()
        let clock = try XCTUnwrap(UniFlowClock.fixed(berlin: "2026-11-06T10:00:00"))
        let today = try XCTUnwrap(BerlinClock.parseISODate("2026-11-06"))
        let t = StubTransport([:])
        let client = StudIPClient(base: URL(string: "https://studip.test")!, transport: t, pauseMillis: 0)
        let d = await StudIPLecturers.fetch(client: client, due: ["k-ana", "k-ue"], missing: [:], today: today)
        XCTAssertEqual(d.requests, (fx["sync_missing"]?["requests"]?.array ?? []).compactMap(\.string))
        same(d.summary, fx["sync_missing"]?["result"], "404 ueberall")
        same(.object(d.missing), try JSONValue.parse(fx["sync_missing"]?["settings"]?.array?.first?.array?[1].string ?? "{}"), "gemerkt")
        let again = await StudIPLecturers.fetch(client: client, due: ["k-ana"], missing: d.missing, today: today)
        XCTAssertEqual(again.requests, [], "30 Tage Ruhe")

        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        try await backend.context.database.transaction { c in
            for k in fx["db"]?["courses"]?.array ?? [] {
                let a = k.array ?? []
                try c.execute("INSERT INTO courses(id, title, active, created_at) VALUES (?,?,?, 't')",
                              [.text(a[0].string ?? ""), .text(a[1].string ?? ""), .integer(Int64(a[3].int ?? 0))])
            }
        }
        let empty = try await backend.context.database.withConnection { try StudIPLecturers.overview($0, university: "luh", base: fx["base"]?.string ?? "") }
        same(empty, fx["overview_empty"], "ohne Abgleich")
        for (i, c) in (fx["due"]?.array ?? []).enumerated() {
            let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
            let got = try await b.context.database.transaction { conn -> [String] in
                try StudIPLecturers.ensure(conn)
                for (k, v) in c["known"]?.object ?? [:] {
                    try conn.execute("INSERT INTO studip_lecturer_courses VALUES (?,?)", [.text(k), .text(v.string ?? "")])
                }
                return try StudIPLecturers.due(conn, courseIDs: (c["courses"]?.array ?? []).compactMap(\.string), today: today)
            }
            XCTAssertEqual(got, (c["due"]?.array ?? []).compactMap(\.string), "due \(i)")
        }
    }

    func testRunOnlyAtLUHAndSessionExpiryStops() async throws {
        let clock = try XCTUnwrap(UniFlowClock.fixed(berlin: "2026-11-06T10:00:00"))
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let t = StubTransport([:])
        let client = StudIPClient(base: URL(string: "https://studip.test")!, transport: t, pauseMillis: 0)
        let none = await StudIPLecturers.run(client: client, database: backend.context.database, courseIDs: ["k1"], clock: clock, university: "hsh")
        XCTAssertEqual(none.requests, [])
        XCTAssertEqual(t.requested, [], "HsH: keine Anfrage")
        let expired = StubTransport(["/jsonapi.php/v1/courses/k1/memberships?filter[permission]=dozent&page[limit]=100&include=user":
                                        HTTPReply(status: 401, contentType: "text/html")])
        let d = await StudIPLecturers.run(client: StudIPClient(base: URL(string: "https://studip.test")!, transport: expired, pauseMillis: 0),
                                          database: backend.context.database, courseIDs: ["k1", "k2"], clock: clock)
        XCTAssertTrue(d.sessionExpired)
        XCTAssertEqual(d.requests.count, 1, "nach abgelaufener Sitzung keine weitere Anfrage")
    }
}
