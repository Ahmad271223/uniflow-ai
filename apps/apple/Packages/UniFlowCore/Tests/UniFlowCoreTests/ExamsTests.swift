import Foundation
import XCTest
@testable import UniFlowCore

// Kommende Klausuren gegen die Python-Referenz: exams.json (tools/gen-exams-fixture.py) mit eingefrorener Uhr
// (Mittwoch, 04.11.2026, 10:00 Europe/Berlin) und erfundenen Daten: Stud.IP-Termine mit Art "Klausur", Klausurtermin
// am Modul, QIS, Fristen, Ankuendigungen und Nachrichten, zusammengefuehrt je Modul und Tag; Klausurtermin am Modul
// gefuellt, nie ueberschrieben; Chips mit Pruefungen zuerst; Art der Stud.IP-Termine gelesen.

private func examsFixture() throws -> JSONValue {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return try JSONValue.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/exams/exams.json")))
}

final class ExamsTests: XCTestCase {
    private let clock = UniFlowClock.fixed(berlin: "2026-11-04T10:00:00")!

    private func seeded(_ fx: JSONValue) async throws -> LocalBackend {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        try await run(backend, fx["seed"]?.array ?? [])
        return backend
    }

    private func run(_ backend: LocalBackend, _ sql: [JSONValue]) async throws {
        try await backend.context.database.transaction { c in
            for s in sql {
                _ = try c.execute(s["sql"]?.string ?? "", (s["params"]?.array ?? []).map { SQLiteValue(json: $0) ?? .null })
            }
        }
    }

    private func request(_ s: JSONValue) -> LocalRequest {
        let url = URL(string: "uniflow-local://device" + (s["path"]?.string ?? ""))!
        let body = s["body"].map { $0.serialized() }
        return LocalRequest(method: s["method"]?.string ?? "GET", url: url, headers: body == nil ? [:] : ["Content-Type": "application/json"], body: body)
    }

    /// Dieselben Anfragen wie gegen app/server.py: Status und Antwort exakt gleich, danach dieselben Module und Merker
    func testStepsMatchPython() async throws {
        let fx = try examsFixture()
        let backend = try await seeded(fx)
        var problems: [String] = []
        for (i, s) in (fx["steps"]?.array ?? []).enumerated() {
            if let sql = s["sql"]?.array { try await run(backend, sql); continue }
            let label = "\(i) \(s["method"]?.string ?? "") \(s["path"]?.string ?? "")"
            let r = await backend.handle(request(s))
            if r.status != s["status"]?.int {
                problems.append("\(label): Status \(r.status) statt \(s["status"]?.int ?? 0)")
                continue
            }
            if let d = jsonDiff(r.json, s["response"]) { problems.append("\(label): \(d)") }
        }
        XCTAssertEqual(problems, [], problems.joined(separator: "\n"))
        let after = try await backend.context.database.withConnection { c -> JSONValue in
            ["modules": .array(try c.rows("SELECT id, name, exam_date FROM modules ORDER BY id").map(JSONValue.object)),
             "settings": .array(try c.rows("SELECT key, value FROM settings WHERE key='exam_dates_auto'").map(JSONValue.object))]
        }
        XCTAssertNil(jsonDiff(after, fx["tables_after"]), jsonDiff(after, fx["tables_after"]) ?? "")
    }

    /// Erkennung in Texten wie exams.exam_dates (Satzteil, Satz, Betreff; ohne Anmeldung, Einsicht, Probeklausur, Ausfall)
    func testExamDatesMatchPython() throws {
        let fx = try examsFixture()
        let cases = fx["exam_dates"]?.array ?? []
        XCTAssertGreaterThanOrEqual(cases.count, 12)
        for c in cases {
            let posted = BerlinClock.parseISODate(c["posted"]?.string ?? "") ?? 0
            let got = JSONValue.array(Exams.examDates(title: c["title"]?.string ?? "", text: c["text"]?.string ?? "", posted: posted).map(JSONValue.object))
            XCTAssertNil(jsonDiff(got, c["dates"]), "\(c["text"]?.string ?? ""): \(jsonDiff(got, c["dates"]) ?? "")")
        }
    }

    /// Chips einer Neuigkeit: Pruefungen immer zuerst und nie abgeschnitten, die Grenze von zwei gilt nur fuer die anderen
    func testChipsPutExamsFirst() throws {
        let fx = try examsFixture()
        for c in fx["chips"]?.array ?? [] {
            let got = JSONValue.array(StudIPExtras.chips(c["dates"], today: c["today"]?.string ?? ""))
            XCTAssertNil(jsonDiff(got, c["chips"]), jsonDiff(got, c["chips"]) ?? "")
        }
        let many: JSONValue = .array((1...5).map { ["date": .string("2026-11-1\($0)"), "kind": "frist"] } + [["date": "2027-02-12", "kind": "pruefung"]])
        XCTAssertEqual(StudIPExtras.chips(many, today: "2026-11-04").first?["label"]?.string, "Prüfung 12.02.", "Klausur vor fuenf Fristen")
    }

    /// Art der Stud.IP-Termine (`categories`) wird gelesen und gespeichert wie event_from_studip
    func testCourseEventCategoryIsRead() throws {
        let fx = try examsFixture()
        for c in fx["events"]?.array ?? [] {
            let e = try XCTUnwrap(StudIPCourseEvent.parse([c["event"] ?? .null], courseID: "c1").first)
            XCTAssertEqual(e.category, c["parsed"]?["category"]?.string, e.id)
        }
    }

    /// Ohne Daten: leere Liste, nichts gefuellt; falscher Modulfilter 422 wie FastAPI
    func testEmptyAndBadQuery() async throws {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        var r = await b.handle(LocalRequest(method: "GET", path: "/api/exams/upcoming"))
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.json?["items"]?.array?.count, 0)
        XCTAssertEqual(r.json?["filled"]?.int, 0)
        XCTAssertEqual(r.json?["today"]?.string, "2026-11-04")
        r = await b.handle(LocalRequest(method: "GET", path: "/api/exams/upcoming", query: [.init("module_id", "x")]))
        XCTAssertEqual(r.status, 422)
    }

    /// Nur auf dem Geraet: in Dokumenten erkannte Klausuren kommen dazu, fuellen aber keinen Klausurtermin
    func testDetectedExamsAreListedButDoNotFill() async throws {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        try await b.context.database.transaction { c in
            _ = try c.execute("INSERT INTO modules(id, name, color, created_at) VALUES (1, 'Mechanik', '#4f5bd5', '2026-10-01')")
            _ = try c.execute("INSERT INTO courses(id, title, kind, module_id, active, created_at) VALUES ('k1', 'Mechanik', 'vorlesung', 1, 1, '2026-10-01')")
            try DueStore.ensureTables(c)
            _ = try c.execute("""
                INSERT INTO due_hits(source, file_id, page, announcement_id, course_id, date, time, kind, label, snippet, name, url, detected_at)
                VALUES ('dateiname', NULL, NULL, NULL, 'k1', '2027-02-22', NULL, 'klausur', 'Klausur', NULL, 'Klausur_22.02.2027.pdf', NULL, '2026-11-04')
                """)
            _ = try c.execute("""
                INSERT INTO due_hits(source, file_id, page, announcement_id, course_id, date, time, kind, label, snippet, name, url, detected_at)
                VALUES ('dateiname', NULL, NULL, NULL, 'k1', '2026-11-20', NULL, 'klausur', 'Kurzklausur', NULL, 'Kurzklausur.pdf', NULL, '2026-11-04')
                """)
        }
        let r = await b.handle(LocalRequest(method: "GET", path: "/api/exams/upcoming"))
        let items = try XCTUnwrap(r.json?["items"]?.array)
        XCTAssertEqual(items.compactMap { $0["date"]?.string }, ["2027-02-22"], "Kurzklausur zaehlt nicht")
        XCTAssertEqual(items.first?["sources"]?.array?.first?["kind"]?.string, "erkannt")
        XCTAssertEqual(r.json?["filled"]?.int, 0)
    }
}
