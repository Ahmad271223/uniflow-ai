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
}
