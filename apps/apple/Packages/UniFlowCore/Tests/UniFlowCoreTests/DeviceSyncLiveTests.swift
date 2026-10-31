import Foundation
import XCTest
@testable import UniFlowCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Zwei Geraete eines Kontos gegen den echten Dienst (tools/g2-testdienst.py), nach tests/test_sync_client.py. Ohne
// G2_TEST_SERVICE uebersprungen.

private struct LiveHTTP: ServiceHTTPTransport {
    func send(_ r: AIHTTPRequest) async throws -> ServiceHTTPResponse {
        var q = URLRequest(url: URL(string: r.url)!)
        q.httpMethod = r.method
        q.httpBody = r.body
        for (k, v) in r.headers { q.setValue(v, forHTTPHeaderField: k) }
        let (d, resp) = try await URLSession.shared.data(for: q)
        return ServiceHTTPResponse(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, body: d)
    }
}

final class DeviceSyncLiveTests: XCTestCase {
    private static let file = "studip-datei-0001"

    private struct Device {
        let db: SQLiteDatabase
        let sync: DeviceSync
        let account: StudoraAccount
    }

    private func base() throws -> String {
        guard let b = ProcessInfo.processInfo.environment["G2_TEST_SERVICE"] else { throw XCTSkip("G2_TEST_SERVICE fehlt") }
        return b
    }

    /// (Token, Konto-ID) eines neuen, bestaetigten Kontos nach der Probe
    private func newAccount(plan: String = "plus") async throws -> (String, String) {
        let r = try await LiveHTTP().send(AIHTTPRequest(method: "POST", url: try base() + "/__test/account",
                                                        headers: ["Content-Type": "application/json"], body: JSONValue.object(["plan": .string(plan)]).serialized()))
        XCTAssertEqual(r.status, 200, String(decoding: r.body, as: UTF8.self))
        let j = try JSONValue.parse(r.body)
        return (try XCTUnwrap(j["token"]?.string), try XCTUnwrap(j["id"]?.string))
    }

    private func device(_ name: String, token: String) async throws -> Device {
        let db = try SQLiteDatabase(path: SQLiteDatabase.inMemory)
        try await db.withConnection { c in
            try Migrations.migrate(c)
            try c.execute("INSERT INTO courses(id, title, semester) VALUES ('kurs-1', 'Mathematik I', 'WiSe 26/27')")
            try c.execute("INSERT INTO files(id, course_id, name, mime, status, download_url) VALUES (?, 'kurs-1', 'Blatt1.pdf', 'application/pdf', 'neu', 'https://x.example/1')", [.text(Self.file)])
        }
        let acc = StudoraAccount(base: try base(), http: LiveHTTP(), tokens: MemoryTokenStore(token), deviceID: name, deviceName: name)
        return Device(db: db, sync: DeviceSync(database: db, transport: acc, device: name), account: acc)
    }

    private func page(_ ids: String...) -> String {
        JSONValue.object(["version": .number(2), "pages": .object(["p1": .object(["objects": .array(ids.map {
            .object(["id": .string($0), "type": .string("stroke"), "points": .array([.number(1), .number(2), .number(3), .number(4)])])
        })])]), "pageOrder": .array([.object(["key": .string("p1"), "type": .string("pdf"), "index": .number(1)])]),
                          "deletedPages": .array([]), "note": .string(""), "bookmarks": .array([]), "outline": .array([])]).jsonString()
    }

    private func strokes(_ d: Device) async throws -> [String] {
        let text = try await d.db.rows("SELECT data FROM annotations WHERE file_id=?", [.text(Self.file)]).first?["data"]?.string
        let doc = try JSONValue.parse(XCTUnwrap(text))
        return (doc["pages"]?["p1"]?["objects"]?.array ?? []).compactMap { $0["id"]?.string }.sorted()
    }

    private func names(_ d: Device) async throws -> [String] {
        try await d.db.rows("SELECT name FROM modules ORDER BY name").compactMap { $0["name"]?.string }
    }

    private func run(_ d: Device, _ id: String, file: StaticString = #filePath, line: UInt = #line) async -> DeviceSyncResult {
        let r = await d.sync.run(account: id)
        XCTAssertTrue(r.ok, r.error ?? "", file: file, line: line)
        XCTAssertEqual(r.errors, [], file: file, line: line)
        return r
    }

    func testFirstLinkWithoutDuplicatesAndNotesFromBothDevicesStay() async throws {
        let (token, id) = try await newAccount()
        let a = try await device("win-1", token: token), b = try await device("ipad-1", token: token)
        let doc = page("win-a"), other = page("ipad-b"), file = Self.file
        try await a.db.withConnection { c in
            try c.execute("INSERT INTO modules(name, semester) VALUES ('Mathe I', 'WiSe 26/27')")
            let mid = c.lastInsertRowID
            try c.execute("INSERT INTO study_packages(date, module_id, title, planned_minutes) VALUES ('2026-11-02', ?, 'Blatt 1', 90)", [.integer(mid)])
            let pid = c.lastInsertRowID
            try c.execute("INSERT INTO study_tasks(package_id, type, title) VALUES (?, 'uebung', 'Aufgabe 1')", [.integer(pid)])
            try c.execute("INSERT INTO annotations(file_id, data, version) VALUES (?, ?, 1)", [.text(file), .text(doc)])
            try c.execute("UPDATE settings SET value='5' WHERE key='hours_per_day'")
            try c.execute("INSERT OR REPLACE INTO settings(key, value) VALUES ('lan_pin', '4711')")
        }
        try await b.db.withConnection { c in
            try c.execute("INSERT INTO modules(name, semester) VALUES ('Mathe I', 'WiSe 26/27')")
            try c.execute("INSERT INTO modules(name, semester) VALUES ('Physik', 'WiSe 26/27')")
            try c.execute("INSERT INTO annotations(file_id, data, version) VALUES (?, ?, 1)", [.text(file), .text(other)])
        }
        _ = await run(b, id)
        _ = await run(a, id)
        _ = await run(b, id)
        let namesA = try await names(a), namesB = try await names(b)
        XCTAssertEqual(namesA, ["Mathe I", "Physik"], "keine Doppelten")
        XCTAssertEqual(namesB, ["Mathe I", "Physik"])
        let sa = try await strokes(a), sb = try await strokes(b)
        XCTAssertEqual(sa, ["ipad-b", "win-a"], "Striche beider Geraete bleiben")
        XCTAssertEqual(sb, ["ipad-b", "win-a"])
        let pkg = try await b.db.rows("SELECT p.title, m.name, (SELECT title FROM study_tasks t WHERE t.package_id=p.id) task FROM study_packages p JOIN modules m ON m.id=p.module_id")
        XCTAssertEqual(pkg.first?["name"]?.string, "Mathe I", "Fremdschluessel auf die lokale ID umgesetzt")
        XCTAssertEqual(pkg.first?["task"]?.string, "Aufgabe 1")
        let hours = try await b.db.rows("SELECT value FROM settings WHERE key='hours_per_day'").first?["value"]?.string
        XCTAssertEqual(hours, "5")
        let pin = try await b.db.rows("SELECT value FROM settings WHERE key='lan_pin'").first?["value"]?.string
        XCTAssertNotEqual(pin, "4711", "private Einstellung bleibt auf dem Geraet")
        let againA = await run(a, id), againB = await run(b, id)
        XCTAssertEqual([againA.pushed, againA.applied, againB.pushed, againB.applied], [0, 0, 0, 0], "ein weiterer Lauf aendert nichts")
    }

    func testEditsDeletesAndConcurrentNotes() async throws {
        let (token, id) = try await newAccount()
        let a = try await device("win-1", token: token), b = try await device("ipad-1", token: token)
        let doc = page("a"), file = Self.file
        try await a.db.withConnection { c in
            try c.execute("INSERT INTO modules(name, semester) VALUES ('Physik', 'WiSe 26/27')")
            try c.execute("INSERT INTO modules(name, semester) VALUES ('Chemie', 'WiSe 26/27')")
            try c.execute("INSERT INTO annotations(file_id, data, version) VALUES (?, ?, 1)", [.text(file), .text(doc)])
        }
        _ = await run(a, id)
        _ = await run(b, id)
        let withB = page("a", "ipad"), withA = page("a", "win")
        try await b.db.withConnection { c in
            try c.execute("UPDATE modules SET name='Physik II' WHERE name='Physik'")
            try c.execute("UPDATE annotations SET data=?, version=version+1 WHERE file_id=?", [.text(withB), .text(file)])
        }
        try await a.db.withConnection { c in
            try c.execute("DELETE FROM modules WHERE name='Chemie'")
            try c.execute("UPDATE annotations SET data=?, version=version+1 WHERE file_id=?", [.text(withA), .text(file)])
        }
        _ = await run(b, id)
        _ = await run(a, id)
        _ = await run(b, id)
        let namesA = try await names(a), namesB = try await names(b)
        XCTAssertEqual(namesA, ["Physik II"])
        XCTAssertEqual(namesB, ["Physik II"], "Loeschen kommt an")
        let sa = try await strokes(a), sb = try await strokes(b)
        XCTAssertEqual(sa, ["a", "ipad", "win"])
        XCTAssertEqual(sb, ["a", "ipad", "win"])
    }

    func testNotesForAFileNotYetHereWait() async throws {
        let (token, id) = try await newAccount()
        let a = try await device("win-1", token: token), b = try await device("ipad-1", token: token)
        let doc = page("x")
        try await b.db.withConnection { c in
            try c.execute("INSERT INTO files(id, course_id, name, mime, status, download_url) VALUES ('studip-neu-9', 'kurs-1', 'Neu.pdf', 'application/pdf', 'neu', 'https://x.example/9')")
            try c.execute("INSERT INTO annotations(file_id, data, version) VALUES ('studip-neu-9', ?, 1)", [.text(doc)])
        }
        _ = await run(b, id)
        let first = await run(a, id)
        XCTAssertEqual(first.pending, 1)
        try await a.db.withConnection { c in
            try c.execute("INSERT INTO files(id, course_id, name, mime, status, download_url) VALUES ('studip-neu-9', 'kurs-1', 'Neu.pdf', 'application/pdf', 'neu', 'https://x.example/9')")
        }
        let second = await run(a, id)
        XCTAssertEqual(second.pending, 0)
        let n = try await a.db.rows("SELECT COUNT(*) n FROM annotations WHERE file_id='studip-neu-9'").first?["n"]?.int
        XCTAssertEqual(n, 1)
    }

    func testFreePlanKeepsNotesLocalButSyncsPlans() async throws {
        let (token, id) = try await newAccount(plan: "free")
        let a = try await device("win-1", token: token), b = try await device("ipad-1", token: token)
        let doc = page("lokal"), file = Self.file
        try await a.db.withConnection { c in
            try c.execute("INSERT INTO modules(name) VALUES ('Nur Plan')")
            try c.execute("INSERT INTO annotations(file_id, data, version) VALUES (?, ?, 1)", [.text(file), .text(doc)])
        }
        let r = await run(a, id)
        XCTAssertTrue(r.planRequired)
        _ = await run(b, id)
        let namesB = try await names(b)
        XCTAssertEqual(namesB, ["Nur Plan"])
        let n = try await b.db.rows("SELECT COUNT(*) n FROM annotations").first?["n"]?.int
        XCTAssertEqual(n, 0)
    }

    func testFirstLinkKeepsChangedSettingsAgainstFreshDefaults() async throws {
        let (token, id) = try await newAccount()
        let a = try await device("win-1", token: token)
        try await a.db.withConnection { c in
            try DeviceSyncSchema.ensure(c)
            try c.execute("UPDATE settings SET value='6', sync_updated_at='2020-01-01T00:00:00.000Z' WHERE key='hours_per_day'")
        }
        _ = try await a.account.syncChanges(query: "limit=1")           // Dienst-Datenbank mit Standardwerten anlegen
        _ = await run(a, id)
        let v = try await a.db.rows("SELECT value FROM settings WHERE key='hours_per_day'").first?["value"]?.string
        XCTAssertEqual(v, "6")
    }
}
