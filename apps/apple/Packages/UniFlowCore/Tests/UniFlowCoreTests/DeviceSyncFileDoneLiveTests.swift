import Foundation
import XCTest
@testable import UniFlowCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Haken "erledigt" je Datei zwischen zwei Geraeten eines Kontos gegen den echten Dienst (tools/g2-testdienst.py),
// Auftrag 13.11.2026. Ohne G2_TEST_SERVICE uebersprungen. Gleiche Faelle am PC: tests/test_file_done_sync.py.

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

final class DeviceSyncFileDoneLiveTests: XCTestCase {
    private static let file = "studip-datei-0001"
    private let clock = UniFlowClock.fixed(berlin: "2026-11-13T10:00:00")!

    private struct Device {
        let db: SQLiteDatabase
        let sync: DeviceSync
    }

    private func base() throws -> String {
        guard let b = ProcessInfo.processInfo.environment["G2_TEST_SERVICE"] else { throw XCTSkip("G2_TEST_SERVICE fehlt") }
        return b
    }

    private func newAccount() async throws -> (String, String) {
        let r = try await LiveHTTP().send(AIHTTPRequest(method: "POST", url: try base() + "/__test/account",
                                                        headers: ["Content-Type": "application/json"], body: JSONValue.object(["plan": "plus"]).serialized()))
        XCTAssertEqual(r.status, 200, String(decoding: r.body, as: UTF8.self))
        let j = try JSONValue.parse(r.body)
        return (try XCTUnwrap(j["token"]?.string), try XCTUnwrap(j["id"]?.string))
    }

    /// Geraet mit Modul, Kurs, Datei und einer offenen Lernaufgabe zur Datei
    private func device(_ name: String, token: String) async throws -> Device {
        let db = try SQLiteDatabase(path: SQLiteDatabase.inMemory)
        try await db.withConnection { c in
            try Migrations.migrate(c)
            try c.execute("INSERT INTO modules(name, semester) VALUES ('Mathematik I', 'WiSe 26/27')")
            let mid = c.lastInsertRowID
            try c.execute("INSERT INTO courses(id, title, semester, module_id) VALUES ('kurs-1', 'Mathematik I', 'WiSe 26/27', ?)", [.integer(mid)])
            try c.execute("INSERT INTO files(id, course_id, name, mime, status, download_url) VALUES (?, 'kurs-1', 'Blatt1.pdf', 'application/pdf', 'neu', 'https://x.example/1')", [.text(Self.file)])
        }
        let acc = StudoraAccount(base: try base(), http: LiveHTTP(), tokens: MemoryTokenStore(token), deviceID: name, deviceName: name)
        return Device(db: db, sync: DeviceSync(database: db, transport: acc, device: name, clock: clock))
    }

    private func run(_ d: Device, _ id: String, file: StaticString = #filePath, line: UInt = #line) async {
        let r = await d.sync.run(account: id)
        XCTAssertTrue(r.ok, r.error ?? "", file: file, line: line)
        XCTAssertEqual(r.errors, [], file: file, line: line)
    }

    private func tick(_ d: Device, _ done: Bool, stamp: String? = nil) async throws {
        let clock = self.clock
        try await d.db.transaction { c in
            _ = try ModuleDone.set(c, fileIDs: [Self.file], done: done, clock: clock)
            if let stamp { try c.execute("UPDATE settings SET sync_updated_at=? WHERE key=?", [.text(stamp), .text("file_done:" + Self.file)]) }
        }
    }

    private func status(_ d: Device) async throws -> String? {
        try await d.db.rows("SELECT status FROM files WHERE id=?", [.text(Self.file)]).first?["status"]?.string
    }

    func testTickAndUntickReachTheOtherDeviceAndCloseItsTask() async throws {
        let (token, id) = try await newAccount()
        let ipad = try await device("ipad-1", token: token), mac = try await device("mac-1", token: token)
        await run(ipad, id)
        await run(mac, id)
        // offene Lernaufgabe zur Datei auf dem Mac (Paket aus seinem Lernkalender)
        try await mac.db.withConnection { c in
            let mid = try XCTUnwrap(c.queryOne("SELECT id FROM modules")?["id"]?.int64)
            try c.execute("INSERT INTO study_packages(date, module_id, title, planned_minutes) VALUES ('2026-11-13', ?, 'Mathe', 60)", [.integer(mid)])
            try c.execute("INSERT INTO study_tasks(package_id, type, file_id, title, status) VALUES (?, 'uebung', ?, 'Blatt 1', 'geplant')",
                          [.integer(c.lastInsertRowID), .text(Self.file)])
        }
        // iPad hakt ab -> Mac hat den Haken und die Aufgabe ist erledigt
        try await tick(ipad, true)
        await run(ipad, id)
        await run(mac, id)
        let onMac = try await status(mac)
        XCTAssertEqual(onMac, "erledigt")
        let task = try await mac.db.rows("SELECT status FROM study_tasks WHERE file_id=? AND type='uebung'", [.text(Self.file)]).first?["status"]?.string
        XCTAssertEqual(task, "erledigt", "Heute für dich geplant: durchgestrichen")
        // Mac nimmt den Haken weg -> auf dem iPad auch weg
        try await tick(mac, false)
        await run(mac, id)
        await run(ipad, id)
        let onIPad = try await status(ipad)
        XCTAssertEqual(onIPad, "gelesen")
        // ein weiterer Lauf aendert nichts
        let again = await ipad.sync.run(account: id)
        XCTAssertEqual([again.pushed, again.applied], [0, 0])
    }

    func testNewerStateWins() async throws {
        let (token, id) = try await newAccount()
        let ipad = try await device("ipad-1", token: token), mac = try await device("mac-1", token: token)
        try await tick(ipad, true)
        await run(ipad, id)
        await run(mac, id)
        // beide aendern vor dem Abgleich: das iPad hin und zurueck frueher, der Mac nimmt den Haken spaeter weg
        try await tick(ipad, false, stamp: "2020-01-01T00:00:00.000Z")
        try await tick(ipad, true, stamp: "2020-01-01T00:00:01.000Z")
        try await tick(mac, false, stamp: "2100-01-01T00:00:00.000Z")
        await run(ipad, id)
        await run(mac, id)
        await run(ipad, id)
        let a = try await status(ipad), m = try await status(mac)
        XCTAssertEqual([a, m], ["gelesen", "gelesen"], "der neuere Stand (Mac) gewinnt auf beiden Geraeten")
    }
}
