import Foundation
import XCTest
@testable import UniFlowCore

// Seite "Nachrichten" (04.11.2026): GET /api/studip/messages?q= liefert alle gespeicherten Stud.IP-Nachrichten,
// neueste zuerst (nach Zeitpunkt, auch ueber den Wechsel der Sommerzeit), mit ganzem Text und erkannten Tagen; die
// Suche findet Woerter in Absender, Betreff und Text ohne Gross-/Kleinschreibung und Akzente. Nur erfundene Daten.

final class StudIPMessagesEndpointTests: XCTestCase {

    private let clock = UniFlowClock.fixed(berlin: "2026-11-02T10:30:00")!
    private let base = "https://studip.example"

    private func seeded() async throws -> LocalBackend {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let inbox: JSONValue = ["data": [
            ["id": "m1", "type": "messages", "attributes": ["subject": "Tutorium entfällt",
                                                             "message": "<p>Das Tutorium am 12.11. fällt aus. Abgabe bis 19.11. um 12 Uhr.</p>",
                                                             "mkdate": "2026-11-02T08:15:00+01:00"],
             "relationships": ["sender": ["data": ["type": "users", "id": "u-doz"]]]],
            ["id": "m2", "type": "messages", "attributes": ["subject": "Ihre Bescheinigung", "message": "Bitte im Prüfungsamt abholen.",
                                                             "mkdate": "2026-10-30T12:00:00+01:00"],
             "relationships": ["sender": ["data": ["type": "users", "id": "____%system%____"]]]],
            // anderer Versatz: als Text "groesser" als m2, als Zeitpunkt aelter (12:30+02:00 = 10:30 UTC, m2 = 11:00 UTC)
            ["id": "m3", "type": "messages", "attributes": ["subject": "Raumänderung", "message": "Ab sofort in Raum 101.",
                                                             "mkdate": "2026-10-30T12:30:00+02:00"]],
        ], "included": [["id": "u-doz", "type": "users", "attributes": ["formatted-name": "Prof. Erika Test", "permission": "dozent"]]]]
        var d = StudIPExtras.Download()
        d.messages = StudIPExtras.parseMessages(inbox["data"], included: inbox["included"], base: base, today: 20759)
        try await backend.context.database.transaction { try StudIPExtras.store(d, in: $0, clock: self.clock) }
        return backend
    }

    private func get(_ b: LocalBackend, q: String? = nil) async throws -> JSONValue {
        let r = await b.handle(LocalRequest(method: "GET", path: "/api/studip/messages", query: q.map { [.init("q", $0)] } ?? []))
        XCTAssertEqual(r.status, 200)
        return try XCTUnwrap(r.json)
    }

    func testEmptyWithoutSync() async throws {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let r = try await get(b)
        XCTAssertEqual(r["messages"]?.array?.count, 0)
        XCTAssertEqual(r["total"]?.int, 0)
        XCTAssertEqual(r["fetched_at"], .null)
    }

    func testListsAllNewestFirstWithTextAndDates() async throws {
        let r = try await get(try await seeded())
        let ms = try XCTUnwrap(r["messages"]?.array)
        XCTAssertEqual(ms.compactMap { $0["id"]?.string }, ["sp-msg-m1", "sp-msg-m2", "sp-msg-m3"], "nach Zeitpunkt, nicht nach Text")
        XCTAssertEqual(r["total"]?.int, 3)
        XCTAssertEqual(r["fetched_at"]?.string, clock.nowISO)
        XCTAssertEqual(ms[0]["sender"]?.string, "Lehrende", "Rolle statt Name")
        XCTAssertEqual(ms[1]["sender"]?.string, "Stud.IP")
        XCTAssertEqual(ms[0]["text"]?.string, "Das Tutorium am 12.11. fällt aus. Abgabe bis 19.11. um 12 Uhr.")
        XCTAssertEqual(ms[0]["url"]?.string, "\(base)/dispatch.php/messages/overview")
        let kinds = Set(ms[0]["dates"]?.array?.compactMap { $0["kind"]?.string } ?? [])
        XCTAssertTrue(kinds.isSuperset(of: ["ausfall", "frist"]), "\(kinds)")
        XCTAssertFalse(ms.contains { ($0["sender"]?.string ?? "").contains("Erika") }, "kein Personenname")
    }

    func testSearchIgnoresCaseAndAccents() async throws {
        let b = try await seeded()
        var r = try await get(b, q: "prufungsamt")
        XCTAssertEqual(r["messages"]?.array?.compactMap { $0["id"]?.string }, ["sp-msg-m2"])
        XCTAssertEqual(r["total"]?.int, 3, "total zaehlt alle")
        XCTAssertEqual(r["q"]?.string, "prufungsamt")
        r = try await get(b, q: "  LEHRENDE  tutorium ")
        XCTAssertEqual(r["messages"]?.array?.compactMap { $0["id"]?.string }, ["sp-msg-m1"], "alle Woerter, auch im Absender")
        r = try await get(b, q: "raum")
        XCTAssertEqual(r["messages"]?.array?.compactMap { $0["id"]?.string }, ["sp-msg-m3"])
        r = try await get(b, q: "gibtsnicht")
        XCTAssertEqual(r["messages"]?.array?.count, 0)
        r = try await get(b, q: "   ")
        XCTAssertEqual(r["messages"]?.array?.count, 3, "leere Suche = alle")
    }

    func testInstantParsing() {
        XCTAssertNotNil(StudIPExtras.messageInstant("2026-11-02T08:15:00+01:00"))
        XCTAssertNotNil(StudIPExtras.messageInstant("2026-11-02T08:15:00.250+01:00"))
        XCTAssertNil(StudIPExtras.messageInstant(""))
        XCTAssertNil(StudIPExtras.messageInstant("gestern"))
        XCTAssertLessThan(StudIPExtras.messageInstant("2026-10-30T12:30:00+02:00")!, StudIPExtras.messageInstant("2026-10-30T12:00:00+01:00")!)
    }

    // MARK: Gelesen laut Stud.IP (26.11.2026, Widget "Nachrichten")

    func testReadStateFromStudIPIsStoredAndListed() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let inbox: JSONValue = ["data": [
            ["id": "r1", "type": "messages", "attributes": ["subject": "Gelesen", "message": "a", "mkdate": "2026-11-02T08:00:00+01:00", "is-read": true]],
            ["id": "r2", "type": "messages", "attributes": ["subject": "Ungelesen", "message": "b", "mkdate": "2026-11-02T09:00:00+01:00", "is-read": false]],
            ["id": "r3", "type": "messages", "attributes": ["subject": "Ohne Angabe", "message": "c", "mkdate": "2026-11-02T07:00:00+01:00"]],
        ]]
        let parsed = StudIPExtras.parseMessages(inbox["data"], included: nil, base: base, today: 20759)
        XCTAssertEqual(parsed.map(\.isRead), [true, false, nil])
        XCTAssertNil(parsed[0].json.object?["read"], "nicht im Vergleich mit der Python-Referenz")
        var d = StudIPExtras.Download()
        d.messages = parsed
        try await backend.context.database.transaction { try StudIPExtras.store(d, in: $0, clock: self.clock) }
        let listed = try await get(backend)
        let ms = try XCTUnwrap(listed["messages"]?.array)
        let read = Dictionary(uniqueKeysWithValues: ms.map { ($0["id"]?.string ?? "", $0["read"] ?? .null) })
        XCTAssertEqual(read["sp-msg-r1"], .bool(true))
        XCTAssertEqual(read["sp-msg-r2"], .bool(false))
        XCTAssertEqual(read["sp-msg-r3"], .null, "unbekannt bleibt unbekannt")
    }

    /// Tabellen von vor dem 26.11.2026 (ohne Spalte is_read): Liste geht weiter, der naechste Abgleich traegt die Spalte nach
    func testOldTableWithoutReadColumn() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        try await backend.context.database.transaction { c in
            try c.executeScript("""
                CREATE TABLE studip_messages (id TEXT PRIMARY KEY, sender TEXT, subject TEXT, preview TEXT, sent_at TEXT, url TEXT, dates TEXT, fetched_at TEXT);
                INSERT INTO studip_messages VALUES ('sp-msg-alt', 'Stud.IP', 'Alt', 'x', '2026-11-01T08:00:00+01:00', '', '[]', '2026-11-01T08:00:00');
                """)
        }
        let old = try await get(backend)
        let before = try XCTUnwrap(old["messages"]?.array)
        XCTAssertEqual(before.first?["read"], .null)
        var d = StudIPExtras.Download()
        let fresh: JSONValue = [["id": "n1", "type": "messages",
                                 "attributes": ["subject": "Neu", "message": "y", "mkdate": "2026-11-02T08:00:00+01:00", "is-read": false]]]
        d.messages = StudIPExtras.parseMessages(fresh, included: nil, base: base, today: 20759)
        XCTAssertEqual(d.messages?.count, 1)
        try await backend.context.database.transaction { try StudIPExtras.store(d, in: $0, clock: self.clock) }
        let new = try await get(backend)
        let after = try XCTUnwrap(new["messages"]?.array)
        XCTAssertEqual(after.map { $0["id"]?.string }, ["sp-msg-n1"])
        XCTAssertEqual(after.first?["read"], .bool(false))
    }
}
