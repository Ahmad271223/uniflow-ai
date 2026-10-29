import Foundation
import XCTest
@testable import UniFlowCore

// Wochentests mit der KI des Nutzers im lokalen Backend wie app/planner.py und app/server.py, Regel vom 29.10.2026:
// genau 15 Aufgaben (4 leicht, 6 mittel, 5 schwer), Altklausur, falsche Form einmal neu anfordern.

/// Schein-KI mit einer Folge von Antworten (die letzte wiederholt sich)
final class ScriptedAI: AIProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [String]
    private(set) var prompts: [String] = []
    init(_ replies: [String]) { self.replies = replies }
    func answer(system: String, prompt: String) async throws -> String {
        lock.withLock {
            prompts.append(prompt)
            return replies.count > 1 ? replies.removeFirst() : replies[0]
        }
    }
    var calls: Int { lock.withLock { prompts.count } }
}

final class TestEndpointsTests: XCTestCase {
    /// Wochentest in der Form vom 29.10.2026
    static func validTest(examStyle: Bool = false, title: String = "Wochentest Testmathe – Reihen") -> String {
        let diffs = Array(repeating: "leicht", count: 4) + Array(repeating: "mittel", count: 6) + Array(repeating: "schwer", count: 5)
        let qs: [JSONValue] = diffs.enumerated().map { i, d in
            ["nr": .number(Double(i + 1)), "type": i == 0 ? "mc" : "calc", "difficulty": .string(d), "question": .string("Aufgabe \(i + 1)"),
             "options": i == 0 ? ["A 1", "B 2"] : .null, "answer": i == 0 ? "B" : "1", "points": .number(i < 10 ? 6 : 8),
             "exam_style": .bool(examStyle && i == 14)]
        }
        return JSONValue.object(["title": .string(title), "questions": .array(qs)]).jsonString()
    }

    private func backend() async throws -> LocalBackend {
        try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: .fixed(berlin: "2026-11-04T10:00:00")!)
    }

    private func call(_ b: LocalBackend, _ method: String, _ path: String, _ body: JSONValue? = nil) async -> LocalResponse {
        await b.handle(LocalRequest(method: method, url: URL(string: "uniflow-local://device" + path)!,
                                    headers: body == nil ? [:] : ["Content-Type": "application/json"], body: body?.serialized()))
    }

    /// Hintergrundauftrag abwarten wie die Oberflaeche (`pollBackground`)
    private func waitForJob(_ b: LocalBackend) async throws -> String {
        for _ in 0..<200 {
            let bg = await call(b, "GET", "/api/bg").json
            if bg?["running"] == false { return bg?["message"]?.string ?? "" }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Hintergrundauftrag endet nicht")
        return ""
    }

    /// Modul mit Kurs, Vorlesung und Uebung derselben Woche (chdate in der ersten Semesterwoche), Texte als Auszug
    private func seed(_ b: LocalBackend, exam: Bool = false) async throws {
        let monday = 1_793_052_000.0      // Mo 2026-10-26 (Berlin), erste Woche mit Dateien
        try await b.context.database.transaction { c in
            _ = try c.execute("UPDATE settings SET value='45' WHERE key='test_minutes'")
            _ = try c.execute("INSERT INTO modules(id, name, color, created_at, active, weekly_test) VALUES (7, 'Testmathe', '#123456', '2026-10-01', 1, 1)")
            _ = try c.execute("INSERT INTO courses(id, title, kind, created_at, module_id, active, subject) VALUES ('k1', 'Testmathe I', 'vorlesung', '2026-10-01', 7, 1, 'Testmathe')")
            var files: [(String, String, String, String)] = [("f1", "vl01.pdf", "vorlesung", "Folgen und Reihen, Konvergenz"),
                                                             ("f2", "blatt01.pdf", "uebung", "Aufgabe 1: Konvergenz der Reihe")]
            if exam { files.append(("f9", "klausur-ws25.pdf", "klausur", "Klausur: Aufgabe 1 Bestimmen Sie den Grenzwert")) }
            for (i, f) in files.enumerated() {
                _ = try c.execute("INSERT INTO files(id, course_id, name, chdate, kind, local_path, text_excerpt, content_sha256) VALUES (?, 'k1', ?, ?, 'pdf', ?, ?, ?)",
                                  [.text(f.0), .text(f.1), .integer(Int64(monday) + Int64(i * 3600)), .text("k1/\(f.1)"), .text(f.3),
                                   .text(String(repeating: String(i), count: 64))])
                _ = try c.execute("INSERT INTO analysis(file_id, doc_type, title, raw) VALUES (?, ?, ?, '{}')", [.text(f.0), .text(f.2), .text("Titel \(f.1)")])
            }
        }
    }

    func testWithoutAIListViewAndDeleteWorkButNothingIsGenerated() async throws {
        let b = try await backend()
        let list = await call(b, "GET", "/api/tests")
        XCTAssertEqual(list.json, [])
        for (m, p) in [("POST", "/api/tests/generate"), ("POST", "/api/tests/generate-week"), ("POST", "/api/tests/1/submit"), ("POST", "/api/tasks/1/start-test")] {
            let r = await call(b, m, p, ["module_id": 7])
            XCTAssertEqual(r.status, 404, p)
            XCTAssertEqual(r.json?["detail"]?.string, DroppedEndpoints.noTests, p)
        }
        let del = await call(b, "DELETE", "/api/tests/99")
        XCTAssertEqual(del.status, 404)
        let v1 = await call(b, "GET", "/api/bg").json
        XCTAssertEqual(v1, ["running": false, "task": .null, "message": ""])
    }

    func testExtraTestRunsInTheBackgroundAndKeepsTheRule() async throws {
        let b = try await backend()
        try await seed(b)
        let ai = ScriptedAI([Self.validTest()])
        b.context.ai.set(ai)
        let r = await call(b, "POST", "/api/tests/generate", ["module_id": 7, "duration_min": 30])
        XCTAssertEqual(r.json, ["started": "Test"])
        let message = try await waitForJob(b)
        XCTAssertTrue(message.hasPrefix("Test: fertig"), message)
        let v2 = await call(b, "GET", "/api/tests").json?.array
        let list = try XCTUnwrap(v2)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0]["question_count"], 15)
        XCTAssertEqual(list[0]["duration_min"], 30)
        XCTAssertEqual(list[0]["auto"], 0)
        XCTAssertEqual(list[0]["title"], "Wochentest Testmathe – Reihen")
        let prompt = try XCTUnwrap(ai.prompts.first)
        XCTAssertTrue(prompt.contains("Genau 15 Aufgaben: genau 4 leicht, genau 6 mittel und genau 5 schwer"))
        XCTAssertTrue(prompt.contains("Folgen und Reihen, Konvergenz") && prompt.contains("Aufgabe 1: Konvergenz der Reihe"), "alle Unterlagen")
        XCTAssertFalse(prompt.contains("Altklausur"))
    }

    func testWrongFormTwiceIsAnErrorAndNoTest() async throws {
        let b = try await backend()
        try await seed(b)
        let short = JSONValue.object(["title": "kurz", "questions": [["nr": 1, "type": "calc", "difficulty": "leicht", "question": "x", "answer": "1", "points": 100]]]).jsonString()
        let ai = ScriptedAI([short])
        b.context.ai.set(ai)
        _ = await call(b, "POST", "/api/tests/generate", ["module_id": 7])
        let message = try await waitForJob(b)
        XCTAssertTrue(message.contains("FEHLER") && message.contains("zweimal nicht in der geforderten Form") && message.contains("1 statt 15"), message)
        XCTAssertEqual(ai.calls, 2, "einmal neu angefordert")
        let v3 = await call(b, "GET", "/api/tests").json
        XCTAssertEqual(v3, [])
    }

    func testWeeklyTestsPerModuleWeekWithExamAndDismissal() async throws {
        let b = try await backend()
        try await seed(b, exam: true)
        // erste Antwort ohne Klausuraufgabe -> neu anfordern; danach mit genau einer schweren im Klausurstil
        let ai = ScriptedAI([Self.validTest(), Self.validTest(examStyle: true)])
        b.context.ai.set(ai)
        let v4 = await call(b, "POST", "/api/tests/generate-week").json
        XCTAssertEqual(v4, ["started": "Wochentests"])
        let message = try await waitForJob(b)
        XCTAssertEqual(message, "Wochentests: fertig (1)")
        XCTAssertEqual(ai.calls, 2)
        XCTAssertTrue(ai.prompts[0].contains("Genau EINE der 5 schweren Aufgaben ist im Stil dieser Klausur"))
        XCTAssertTrue(ai.prompts[0].contains("Bestimmen Sie den Grenzwert"))
        let v5 = await call(b, "GET", "/api/tests").json?.array
        let list = try XCTUnwrap(v5)
        XCTAssertEqual(list.count, 1)
        let t = list[0]
        XCTAssertEqual(t["auto"], 1)
        XCTAssertEqual(t["week_no"], 1)
        XCTAssertEqual(t["title"], "Lehrwoche 1: Reihen")
        XCTAssertEqual(t["duration_min"], 45)
        // noch einmal: gibt es schon, keine neue Anfrage
        _ = await call(b, "POST", "/api/tests/generate-week")
        let v6 = try await waitForJob(b)
        XCTAssertEqual(v6, "Wochentests: fertig")
        XCTAssertEqual(ai.calls, 2)
        // geloescht: kommt nicht wieder
        let id = Int(t["id"]?.double ?? 0)
        let v7 = await call(b, "DELETE", "/api/tests/\(id)").status
        XCTAssertEqual(v7, 200)
        let v8 = try await b.context.database.queryOne("SELECT 1 FROM dismissed_tests WHERE module_id=7 AND week_no=1")
        XCTAssertNotNil(v8)
        _ = await call(b, "POST", "/api/tests/generate-week")
        _ = try await waitForJob(b)
        let v9 = await call(b, "GET", "/api/tests").json
        XCTAssertEqual(v9, [], "vom Nutzer geloescht")
        XCTAssertEqual(ai.calls, 2)
    }

    func testAnswersHiddenUntilSubmitAndGradingIsStored() async throws {
        let b = try await backend()
        try await seed(b)
        let grading = #"{"total": 70, "max": 100, "per_question": [{"nr": 1, "points": 6, "max": 6, "feedback": "richtig"}], "summary": "Gut", "weak_topics": ["Reihen"]}"#
        let ai = ScriptedAI([Self.validTest(), grading])
        b.context.ai.set(ai)
        _ = await call(b, "POST", "/api/tests/generate", ["module_id": 7])
        _ = try await waitForJob(b)
        let v10 = await call(b, "GET", "/api/tests").json?.array?.first?["id"]?.double
        let id = Int(try XCTUnwrap(v10))
        let v11 = await call(b, "GET", "/api/tests/\(id)").json
        let open = try XCTUnwrap(v11)
        XCTAssertNotEqual(open["started_at"], .null)
        XCTAssertTrue(open["questions"]?.array?.allSatisfy { $0["answer"] == nil } ?? false, "Loesung erst nach Abgabe")
        XCTAssertEqual(open["questions"]?.array?.first?["difficulty"], "leicht")
        let r = await call(b, "POST", "/api/tests/\(id)/submit", ["answers": ["1": "B", "2": "7"]])
        XCTAssertEqual(r.status, 200, String(decoding: r.body, as: UTF8.self))
        XCTAssertEqual(r.json?["total"], 70)
        XCTAssertTrue(ai.prompts.last?.contains("Aufgabe 1 (6 P., mc): Aufgabe 1\n  Musterloesung: B\n  Antwort des Studierenden: B") ?? false, ai.prompts.last ?? "")
        XCTAssertTrue(ai.prompts.last?.contains("Antwort des Studierenden: [keine Antwort]") ?? false)
        let v12 = await call(b, "GET", "/api/tests/\(id)").json
        let done = try XCTUnwrap(v12)
        XCTAssertEqual(done["score"], 70)
        XCTAssertEqual(done["max_score"], 100)
        XCTAssertEqual(done["answers"], ["1": "B", "2": "7"])
        XCTAssertEqual(done["feedback"]?["summary"], "Gut")
        XCTAssertEqual(done["questions"]?.array?.first?["answer"], "B", "nach der Abgabe sichtbar")
    }

    func testSecondJobWhileOneRunsIs409() async throws {
        let b = try await backend()
        try await seed(b)
        final class SlowAI: AIProvider, @unchecked Sendable {
            func answer(system: String, prompt: String) async throws -> String {
                try await Task.sleep(nanoseconds: 300_000_000)
                return TestEndpointsTests.validTest()
            }
        }
        b.context.ai.set(SlowAI())
        _ = await call(b, "POST", "/api/tests/generate", ["module_id": 7])
        let second = await call(b, "POST", "/api/tests/generate-week")
        XCTAssertEqual(second.status, 409)
        XCTAssertEqual(second.json?["detail"], "Es laeuft bereits: Test")
        _ = try await waitForJob(b)
    }
}
