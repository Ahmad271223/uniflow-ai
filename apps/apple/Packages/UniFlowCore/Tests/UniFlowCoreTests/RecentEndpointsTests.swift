import Foundation
import XCTest
@testable import UniFlowCore

// "Zuletzt benutzt" (Weitermachen wie zuvor, 04.11.2026, docs/WEITERMACHEN-2026-11-04.md): GET /api/recent liefert
// geoeffnete Dokumente (files.last_opened, last_page, opened_count) und begonnene oder abgegebene Wochentests in einer
// Liste nach Zeit, neuestes zuerst, hoechstens `limit`. Alle Daten sind erfunden.
private extension JSONValue {
    func s(_ k: String) -> String? { self[k]?.string }
    func i(_ k: String) -> Int? { self[k]?.int }
    func list(_ k: String) -> [JSONValue] { self[k]?.array ?? [] }
}

final class RecentEndpointsTests: XCTestCase {
    private func backend() async throws -> LocalBackend {
        try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: .fixed(berlin: "2026-11-04T10:00:00")!)
    }

    private func get(_ b: LocalBackend, _ path: String) async throws -> JSONValue {
        let r = await b.handle(LocalRequest(method: "GET", url: URL(string: "uniflow-local://device" + path)!))
        XCTAssertEqual(r.status, 200, path)
        return try XCTUnwrap(r.json)
    }

    private func seed(_ b: LocalBackend) async throws {
        try await b.context.database.transaction { c in
            try c.execute("INSERT INTO courses(id, title, kind, created_at, subject, active) VALUES ('k1', 'Analysis I', 'vorlesung', '2026-10-01', 'Analysis', 1)")
            let files: [(String, String, String?, Int)] = [
                ("f1", "vl01.pdf", "2026-11-01T09:00:00", 3),
                ("f2", "vl02.pdf", "2026-11-03T18:30:00", 7),
                ("f3", "nie.pdf", nil, 1),
            ]
            for (id, name, opened, page) in files {
                try c.execute("INSERT INTO files(id, course_id, name, chdate, kind, last_opened, last_page, opened_count) VALUES (?, 'k1', ?, 5, 'pdf', ?, ?, 2)",
                              [.text(id), .text(name), opened.map { .text($0) } ?? .null, .integer(Int64(page))])
            }
            // eigener Upload ohne Kurs in der Tabelle: erscheint trotzdem
            try c.execute("INSERT INTO files(id, course_id, name, chdate, kind, last_opened) VALUES ('u1', '__user__', 'eigen.pdf', 5, 'pdf', '2026-11-02T08:00:00')")
            try c.execute("INSERT INTO tests(subject, title, questions, started_at) VALUES ('Analysis', 'Woche 3', '[]', '2026-11-02T12:00:00')")
            try c.execute("INSERT INTO tests(subject, title, questions, started_at, submitted_at, score, max_score) VALUES ('Analysis', 'Woche 4', '[]', '2026-11-04T08:00:00', '2026-11-04T08:20:00', 7, 10)")
            try c.execute("INSERT INTO tests(subject, title, questions) VALUES ('Analysis', 'nie begonnen', '[]')")
        }
    }

    func testRecentListsDocumentsAndTestsNewestFirst() async throws {
        let b = try await backend()
        try await seed(b)
        let items = try await get(b, "/api/recent").list("items")
        XCTAssertEqual(items.map { $0.s("kind") ?? "" }, ["test", "document", "test", "document", "document"])
        XCTAssertEqual(items.map { $0.s("title") ?? "" }, ["Woche 4", "vl02.pdf", "Woche 3", "eigen.pdf", "vl01.pdf"])
        let doc = items[1]
        XCTAssertEqual(doc.s("id"), "f2")
        XCTAssertEqual(doc.i("page"), 7)
        XCTAssertEqual(doc.i("opened_count"), 2)
        XCTAssertEqual(doc.s("sub"), "Analysis")
        XCTAssertEqual(items[0].s("id"), "2", "Test-ID als Text wie die Datei-IDs")
        XCTAssertEqual(items[0]["done"]?.bool, true)
        XCTAssertEqual(items[2]["done"]?.bool, false)
        XCTAssertFalse(items.contains { $0.s("id") == "f3" }, "nie geoeffnet")
    }

    func testRecentLimitAndOpenedEndpointFeedsIt() async throws {
        let b = try await backend()
        try await seed(b)
        let two = try await get(b, "/api/recent?limit=2").list("items")
        XCTAssertEqual(two.count, 2)
        let clamped = try await get(b, "/api/recent?limit=0").list("items")
        XCTAssertEqual(clamped.count, 1, "mindestens 1")
        // Oeffnen (Bibliothek), dann Seite merken (Editor): f3 steht danach mit dieser Seite ganz vorn
        for body: JSONValue in [.object([:]), .object(["last_page": 4])] {
            let r = await b.handle(LocalRequest(method: "POST", url: URL(string: "uniflow-local://device/api/files/f3/opened")!,
                                                headers: ["Content-Type": "application/json"], body: body.serialized()))
            XCTAssertEqual(r.status, 200)
        }
        let first = try await get(b, "/api/recent?limit=15").list("items").first
        XCTAssertEqual(first?.s("id"), "f3")
        XCTAssertEqual(first?.i("page"), 4)
    }

    func testRecentEmpty() async throws {
        let b = try await backend()
        let items = try await get(b, "/api/recent?limit=15").list("items")
        XCTAssertTrue(items.isEmpty)
    }
}
