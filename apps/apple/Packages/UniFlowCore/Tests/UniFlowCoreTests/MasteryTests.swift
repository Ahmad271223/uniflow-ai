import Foundation
import XCTest
@testable import UniFlowCore

/// Lernstand je Modul (Mastery.swift, docs/LERNSTAND-2026-11-04.md): die gemeinsamen Faelle aus
/// packages/shared-contracts/fixtures/mastery/cases.json (dieselben prueft tests/test_mastery.py) und das Feld
/// `mastery` in GET /api/modules und GET /api/modules/{id} auf einer erfundenen Datenbank.
final class MasteryTests: XCTestCase {

    private func fixture() throws -> JSONValue {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url.deleteLastPathComponent() }
        return try JSONValue.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/mastery/cases.json")))
    }

    func testFixtureCasesLikePython() throws {
        let cases = try fixture()["cases"]?.array ?? []
        XCTAssertGreaterThanOrEqual(cases.count, 12)
        for c in cases {
            let i = c["input"] ?? .null
            let tests = (i["tests"]?.array ?? []).map { (score: $0.array?[0].double ?? 0, max: $0.array?[1].double ?? 0) }
            let got = Mastery.compute(tests: tests, cardsRight: i["cards_right"]?.int ?? 0, cardsWrong: i["cards_wrong"]?.int ?? 0,
                                      tasksDone: i["tasks_done"]?.int ?? 0, tasksTotal: i["tasks_total"]?.int ?? 0)
            XCTAssertEqual(got, c["expected"] ?? .null, c["name"]?.string ?? "")
        }
    }

    func testRulesHold() {
        let up = Mastery.compute(tests: [(5, 10), (9, 10)], cardsRight: 0, cardsWrong: 0, tasksDone: 0, tasksTotal: 0)
        let down = Mastery.compute(tests: [(9, 10), (5, 10)], cardsRight: 0, cardsWrong: 0, tasksDone: 0, tasksTotal: 0)
        XCTAssertGreaterThan(up["score"]?.int ?? 0, down["score"]?.int ?? 0, "der neueste Test wiegt mehr")
        XCTAssertEqual(Mastery.compute(tests: [], cardsRight: 0, cardsWrong: 0, tasksDone: 0, tasksTotal: 0), .null)
        XCTAssertEqual(Mastery.compute(tests: [(.nan, 10)], cardsRight: 0, cardsWrong: 0, tasksDone: 0, tasksTotal: 0), .null)
        XCTAssertEqual(Mastery.compute(tests: [(10, 10)], cardsRight: 9, cardsWrong: 0, tasksDone: 3, tasksTotal: 3)["score"], 100)
        XCTAssertEqual(Mastery.reason(tests: 1, cards: 1, tasksDone: 1, tasksTotal: 1), "1 Wochentest, 1 Karte, 1 von 1 Aufgabe")
        XCTAssertEqual(Mastery.reason(tests: 0, cards: 0, tasksDone: 0, tasksTotal: 0), "")
    }

    /// Wie tests/test_mastery.py::test_module_endpoints_carry_mastery: dieselbe Datenbank, dieselben Zahlen
    func testModuleEndpointsCarryMastery() async throws {
        let clock = UniFlowClock.fixed(berlin: "2026-11-04T10:00:00")!
        let db = try SQLiteDatabase(path: SQLiteDatabase.inMemory)
        try await db.migrate(clock: clock)
        let backend = try LocalBackend(database: db, clock: clock)
        let created = await backend.handle(LocalRequest(method: "POST", path: "/api/modules", body: Data(#"{"name": "Lernstandmodul Test"}"#.utf8)))
        let mid = try XCTUnwrap(created.json?["id"]?.int)
        let name = SQLiteValue.text("Lernstandmodul Test"), id = SQLiteValue.integer(Int64(mid))
        try await db.transaction { c in
            try c.execute("INSERT INTO courses(id, title, subject, kind, active, module_id, created_at) VALUES ('ls-vl', 'Vorlesung Lernstand', ?, 'vorlesung', 1, ?, '2026-11-01')", [name, id])
            try c.execute("INSERT INTO files(id, course_id, name, chdate, status) VALUES ('ls-f1', 'ls-vl', 'V1.pdf', 1761900000, 'neu')")
            // Wochentests: der aeltere 50 %, der neuere 90 % (zaehlt doppelt); ohne Abgabe und von einem anderen Nutzer zaehlen nicht
            try c.execute("INSERT INTO tests(subject, questions, module_id, submitted_at, score, max_score) VALUES (?, '[]', ?, '2026-10-20T13:00:00', 5, 10)", [name, id])
            try c.execute("INSERT INTO tests(subject, questions, module_id, submitted_at, score, max_score) VALUES (?, '[]', ?, '2026-10-27T13:00:00', 9, 10)", [name, id])
            try c.execute("INSERT INTO tests(subject, questions, module_id) VALUES (?, '[]', ?)", [name, id])
            try c.execute("INSERT INTO tests(subject, questions, module_id, user_id, submitted_at, score, max_score) VALUES (?, '[]', ?, 'fremd', '2026-10-28T13:00:00', 0, 10)", [name, id])
            // Karten: 3 richtig, 1 falsch, 1 ohne Urteil, 1 versteckt, 1 nur ueber das Fach zugeordnet (richtig)
            let cards: [(SQLiteValue, SQLiteValue, SQLiteValue, SQLiteValue)] = [
                (.text("right"), .integer(0), .text("ls-f1"), .null), (.text("right"), .integer(0), .text("ls-f1"), .null),
                (.text("wrong"), .integer(0), .text("ls-f1"), .null), (.null, .integer(0), .text("ls-f1"), .null),
                (.text("wrong"), .integer(1), .text("ls-f1"), .null), (.text("right"), .integer(0), .null, name)]
            for (res, hidden, fid, subj) in cards {
                try c.execute("INSERT INTO flashcards(file_id, subject, question, answer, created_at, box, due, last_result, hidden) VALUES (?,?,'F','A','2026-11-01',1,'2026-11-02',?,?)",
                              [fid, subj, res, hidden])
            }
            try c.execute("INSERT INTO study_packages(id, date, module_id, subject, title, created_at) VALUES (900, '2026-11-02', ?, ?, 'Woche 3', '2026-10-27')", [id, name])
            for st in ["erledigt", "erledigt", "geplant", "verschoben"] {
                try c.execute("INSERT INTO study_tasks(package_id, type, file_id, title, status, created_at) VALUES (900, 'vorlesung', 'ls-f1', 'Lesen', ?, '2026-10-27')", [.text(st)])
            }
        }
        // T = (1*50 + 2*90) / 3 = 76.67; K = 3 von 4 = 75; A = 2 von 4 = 50 -> 70.83 -> 71
        let want: JSONValue = ["score": 71, "reason": "2 Wochentests, 4 Karten, 2 von 4 Aufgaben", "tests": 2, "cards": 4, "tasks_done": 2, "tasks_total": 4]
        let detail = await backend.handle(LocalRequest(method: "GET", path: "/api/modules/\(mid)"))
        XCTAssertEqual(detail.json?["mastery"], want)
        XCTAssertEqual(detail.json?["progress"], 100, "'bearbeitet' bleibt die alte Zahl")
        let list = await backend.handle(LocalRequest(method: "GET", path: "/api/modules"))
        XCTAssertEqual(list.json?.array?.first?["mastery"], want)

        try await db.transaction { c in
            try c.execute("UPDATE study_tasks SET status='erledigt' WHERE package_id=900")
            try c.execute("DELETE FROM tests WHERE module_id=?", [id])
            try c.execute("UPDATE flashcards SET last_result=NULL")
        }
        let later = await backend.handle(LocalRequest(method: "GET", path: "/api/modules/\(mid)"))
        XCTAssertEqual(later.json?["mastery"], ["score": 100, "reason": "4 von 4 Aufgaben", "tests": 0, "cards": 0, "tasks_done": 4, "tasks_total": 4])
        try await db.transaction { try $0.execute("DELETE FROM study_tasks WHERE package_id=900") }
        let none = await backend.handle(LocalRequest(method: "GET", path: "/api/modules/\(mid)"))
        XCTAssertEqual(none.json?["mastery"], .null, "ohne Signal: noch kein Lernstand")
    }
}
