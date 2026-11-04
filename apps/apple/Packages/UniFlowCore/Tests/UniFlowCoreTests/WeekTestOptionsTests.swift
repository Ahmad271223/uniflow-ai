import Foundation
import XCTest
@testable import UniFlowCore

// Dialog "Wochentest erstellen" (04.11.2026): Zahl, Schwierigkeit, Aufgabenarten (mit Wahr/Falsch und Lueckentext),
// Thema. Pruefung, Verteilung und die Entscheidung "gemeinsam oder eigener Test" wie am PC (contract.json,
// Abschnitt week_test_options); der Endpunkt legt nur in der Standardeinstellung einen Schluessel an.

private func contract() throws -> PyJSON {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return try PyJSON.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/ai/contract.json")))
}

private func g(_ v: PyJSON?, _ key: String) -> PyJSON? { AIPrompts.get(v, key) }
private func s(_ v: PyJSON?, _ key: String) -> String { if case .string(let t)? = g(v, key) { return t }; return "" }
private func list(_ v: PyJSON?, _ key: String) -> [PyJSON] { if case .array(let a)? = g(v, key) { return a }; return [] }

final class WeekTestOptionsTests: XCTestCase {

    /// Vertrag: Pruefung und Fehlertexte, Standardeinstellung, Verteilung der Schwierigkeiten byte-gleich mit Python
    func testOptionsMatchPython() throws {
        let section = g(try contract(), "week_test_options")
        XCTAssertEqual(try WeekTestOptions.parse(g(section, "standard")), .standard)
        let cases = list(section, "parse")
        XCTAssertGreaterThanOrEqual(cases.count, 15)
        for c in cases {
            let input = g(c, "in")
            if let out = g(c, "out") {
                let got = try WeekTestOptions.parse(input)
                XCTAssertEqual(JSONValue.object(got.json), out.json, PyText.str(input ?? .null))
                XCTAssertEqual(got.isStandard, g(c, "standard") == .bool(true), PyText.str(input ?? .null))
            } else {
                XCTAssertThrowsError(try WeekTestOptions.parse(input), PyText.str(input ?? .null)) { e in
                    XCTAssertEqual((e as? AIError)?.message, s(c, "error"), PyText.str(input ?? .null))
                    XCTAssertEqual((e as? AIError)?.code, "week_test_options")
                }
            }
        }
        let dist = list(section, "distribution")
        XCTAssertEqual(dist.count, 16, "4 Zahlen x 4 Stufen")
        for d in dist {
            guard case .int(let n)? = g(d, "count") else { return XCTFail("count") }
            let got = WeekTestOptions.distribution(count: Int(n)!, difficulty: s(d, "difficulty"))
            var expected: [String: Int] = [:]
            if case .object(let m)? = g(d, "out") { for x in m { expected[x.key] = Int(PyText.str(x.value)) ?? -1 } }
            XCTAssertEqual(Dictionary(uniqueKeysWithValues: got.map { ($0.level, $0.count) }), expected, "\(n) \(s(d, "difficulty"))")
            XCTAssertEqual(got.map(\.level), ["leicht", "mittel", "schwer"], "Reihenfolge wie Python")
        }
    }

    /// Nur die Standardeinstellung wird geteilt: jede Abweichung (Zahl, Stufe, eine Art weniger, Thema) ist ein eigener Test
    func testOnlyTheStandardSettingIsShared() throws {
        XCTAssertTrue(WeekTestOptions.standard.isStandard)
        XCTAssertTrue(try WeekTestOptions.parse(nil).isStandard)
        XCTAssertTrue(try WeekTestOptions.parse(.object([.init("module_id", .int("7")), .init("count", .string("15")), .init("topic", .string("  "))])).isStandard)
        var o = WeekTestOptions.standard; o.count = 10; XCTAssertFalse(o.isStandard)
        o = .standard; o.difficulty = "schwer"; XCTAssertFalse(o.isStandard)
        o = .standard; o.types = ["mc", "tf", "cloze", "short"]; XCTAssertFalse(o.isStandard)
        o = .standard; o.topic = "nur Kapitel 3"; XCTAssertFalse(o.isStandard)
        XCTAssertEqual(WeekTestOptions.distribution(count: 5, difficulty: "beliebig").map(\.count), [1, 2, 2])
        XCTAssertEqual(WeekTestOptions.distribution(count: 10, difficulty: "beliebig").map(\.count), [3, 4, 3])
        XCTAssertEqual(WeekTestOptions.distribution(count: 20, difficulty: "beliebig").map(\.count), [5, 8, 7])
        XCTAssertEqual(WeekTestOptions.distribution(count: 20, difficulty: "leicht").map(\.count), [20, 0, 0])
    }

    /// Pruefung der Antwort: Wahr/Falsch nur mit genau den Optionen Wahr und Falsch, Lueckentext nur mit `blank`,
    /// jede Aufgabe mit Erklaerung, nur gewaehlte Aufgabenarten, Verteilung je Zahl
    func testValidatorChecksTrueFalseClozeAndExplanation() throws {
        func q(_ i: Int, _ type: String, _ level: String, extra: [PyJSON.Member] = []) -> PyJSON {
            .object([.init("nr", .int(String(i))), .init("type", .string(type)), .init("difficulty", .string(level)),
                     .init("question", .string("Frage \(i)")), .init("answer", .string(type == "tf" ? "Wahr" : "x")),
                     .init("explanation", .string("Weil.")), .init("points", .int("20"))] + extra)
        }
        let tfOK: [PyJSON.Member] = [.init("options", .array([.string("Wahr"), .string("Falsch")]))]
        let five = try WeekTestOptions.parse(.object([.init("count", .int("5")), .init("difficulty", .string("leicht")), .init("types", .array([.string("tf"), .string("cloze")]))]))
        let good = PyJSON.object([.init("questions", .array([q(1, "tf", "leicht", extra: tfOK), q(2, "tf", "leicht", extra: tfOK),
                                                           q(3, "cloze", "leicht", extra: [.init("blank", .string("Grenzwert"))]),
                                                           q(4, "tf", "leicht", extra: tfOK), q(5, "tf", "leicht", extra: tfOK)]))])
        XCTAssertNil(AIAnswers.checkWeekTest(good, options: five))
        XCTAssertNil(AIAnswers.checkWeekTest(good, exam: true, options: five), "ohne schwere Aufgaben keine Klausuraufgabe verlangt")
        XCTAssertEqual(AIAnswers.checkWeekTest(good), "5 statt 15 Aufgaben", "Standard verlangt 15")
        var bad = PyJSON.object([.init("questions", .array([q(1, "tf", "leicht", extra: [.init("options", .array([.string("Ja"), .string("Nein")]))]),
                                                          q(2, "tf", "leicht", extra: tfOK), q(3, "cloze", "leicht", extra: [.init("blank", .string("x"))]),
                                                          q(4, "tf", "leicht", extra: tfOK), q(5, "tf", "leicht", extra: tfOK)]))])
        XCTAssertEqual(AIAnswers.checkWeekTest(bad, options: five), "Aufgabe 1 (Wahr/Falsch) ohne die Optionen Wahr und Falsch")
        bad = .object([.init("questions", .array([q(1, "tf", "leicht", extra: tfOK), q(2, "tf", "leicht", extra: tfOK), q(3, "cloze", "leicht"),
                                                  q(4, "tf", "leicht", extra: tfOK), q(5, "tf", "leicht", extra: tfOK)]))])
        XCTAssertEqual(AIAnswers.checkWeekTest(bad, options: five), "Aufgabe 3 (Lueckentext) ohne Luecke")
        bad = .object([.init("questions", .array([q(1, "tf", "leicht", extra: tfOK), q(2, "mc", "leicht", extra: [.init("options", .array([.string("A"), .string("B")]))]),
                                                  q(3, "cloze", "leicht", extra: [.init("blank", .string("x"))]), q(4, "tf", "leicht", extra: tfOK), q(5, "tf", "leicht", extra: tfOK)]))])
        XCTAssertEqual(AIAnswers.checkWeekTest(bad, options: five), "Aufgabe 2 mit nicht gewaehlter Aufgabenart")
        bad = .object([.init("questions", .array([q(1, "tf", "leicht", extra: tfOK), q(2, "tf", "mittel", extra: tfOK),
                                                  q(3, "cloze", "leicht", extra: [.init("blank", .string("x"))]), q(4, "tf", "leicht", extra: tfOK), q(5, "tf", "leicht", extra: tfOK)]))])
        XCTAssertEqual(AIAnswers.checkWeekTest(bad, options: five), "Verteilung 4 leicht, 1 mittel, 0 schwer statt 5 leicht, 0 mittel, 0 schwer")
        var noExpl = try PyJSON.parse(Data(TestEndpointsTests.validTest().utf8))
        // "questions" ueber den Schluessel suchen: die Reihenfolge der Schluessel aus validTest() ist je Prozess anders
        // (Swift-Dictionary), fest "m[1]" traf im vollen Lauf den Titel und entfernte nichts
        if case .object(var m) = noExpl, let qi = m.firstIndex(where: { $0.key == "questions" }),
           case .array(var qs) = m[qi].value, case .object(var q0) = qs[0] {
            q0.removeAll { $0.key == "explanation" }
            qs[0] = .object(q0); m[qi].value = .array(qs); noExpl = .object(m)
        }
        XCTAssertEqual(AIAnswers.checkWeekTest(noExpl), "Aufgabe 1 ohne Erklaerung")
        XCTAssertNil(AIAnswers.checkWeekTest(try PyJSON.parse(Data(TestEndpointsTests.validTest().utf8))))
    }

    /// Prompt: Zahl und Verteilung, nur die gewaehlten Arten, Hinweise zu Wahr/Falsch und Luecke, Thema als Material,
    /// ohne schwere Aufgaben keine Altklausur
    func testPromptFollowsTheOptions() throws {
        let o = try WeekTestOptions.parse(.object([.init("count", .int("10")), .init("difficulty", .string("mittel")),
                                                    .init("types", .array([.string("cloze"), .string("tf")])), .init("topic", .string("nur Kapitel 3"))]))
        let p = AIPrompts.weekTest(subject: "Testmathe", durationMin: 30, materialsBlock: "### Folien", examBlock: "### Klausur", options: o)
        XCTAssertTrue(p.contains("Genau 10 Aufgaben, alle mit \"difficulty\": \"mittel\""), p)
        XCTAssertTrue(p.contains("Mischung aus Wahr/Falsch (\"type\": \"tf\") und Lueckentext (\"type\": \"cloze\"); keine anderen Aufgabenarten."), p)
        XCTAssertTrue(p.contains("genau eine Luecke als ___") && p.contains("[\"Wahr\", \"Falsch\"]"))
        XCTAssertTrue(p.contains("Schwerpunkt oder Hinweis des Studierenden (\(AIPromptTexts.untrusted)): nur Kapitel 3"))
        XCTAssertFalse(p.contains("Altklausur"), "mittel: keine schwere Aufgabe, also keine Klausuraufgabe")
        XCTAssertTrue(p.contains("\"type\": \"tf\" | \"cloze\""))
        XCTAssertTrue(p.contains("\"explanation\": \"1 bis 3 Saetze"))
        let std = AIPrompts.weekTest(subject: "Testmathe", durationMin: 45, materialsBlock: "### Folien", examBlock: "### Klausur")
        XCTAssertTrue(std.contains("Genau 15 Aufgaben: genau 4 leicht, genau 6 mittel und genau 5 schwer"))
        XCTAssertTrue(std.contains("Genau EINE der 5 schweren Aufgaben"))
        XCTAssertFalse(std.contains("Schwerpunkt"))
    }

    // MARK: Endpunkt

    private func backend() async throws -> LocalBackend {
        try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: .fixed(berlin: "2026-11-04T10:00:00")!)
    }

    private func call(_ b: LocalBackend, _ method: String, _ path: String, _ body: JSONValue? = nil) async -> LocalResponse {
        await b.handle(LocalRequest(method: method, url: URL(string: "uniflow-local://device" + path)!,
                                    headers: body == nil ? [:] : ["Content-Type": "application/json"], body: body?.serialized()))
    }

    private func waitForJob(_ b: LocalBackend) async throws -> String {
        for _ in 0..<200 {
            let bg = await call(b, "GET", "/api/bg").json
            if bg?["running"] == false { return bg?["message"]?.string ?? "" }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Hintergrundauftrag endet nicht")
        return ""
    }

    private func seed(_ b: LocalBackend) async throws {
        let monday = 1_793_052_000.0
        try await b.context.database.transaction { c in
            _ = try c.execute("INSERT INTO modules(id, name, color, created_at, active, weekly_test) VALUES (7, 'Testmathe', '#123456', '2026-10-01', 1, 1)")
            _ = try c.execute("INSERT INTO courses(id, title, kind, created_at, module_id, active, subject) VALUES ('k1', 'Testmathe I', 'vorlesung', '2026-10-01', 7, 1, 'Testmathe')")
            for (i, f) in [("f1", "vl01.pdf", "vorlesung", "Folgen und Reihen"), ("f2", "blatt01.pdf", "uebung", "Aufgabe 1")].enumerated() {
                _ = try c.execute("INSERT INTO files(id, course_id, name, chdate, kind, local_path, text_excerpt, content_sha256) VALUES (?, 'k1', ?, ?, 'pdf', ?, ?, ?)",
                                  [.text(f.0), .text(f.1), .integer(Int64(monday) + Int64(i * 3600)), .text("k1/\(f.1)"), .text(f.3),
                                   .text(String(repeating: String(i), count: 64))])
                _ = try c.execute("INSERT INTO analysis(file_id, doc_type, title, raw) VALUES (?, ?, ?, '{}')", [.text(f.0), .text(f.2), .text("Titel \(f.1)")])
            }
        }
    }

    /// Fuenf Wahr/Falsch-Aufgaben als Antwort der Schein-KI
    private static func fiveTrueFalse() -> String {
        let qs: [JSONValue] = (1...5).map { i in
            ["nr": .number(Double(i)), "type": "tf", "difficulty": "leicht", "question": .string("Aussage \(i)"), "options": ["Wahr", "Falsch"],
             "answer": "Wahr", "explanation": .string("Weil \(i)."), "points": 20]
        }
        return JSONValue.object(["title": "Wochentest Testmathe – Aussagen", "questions": .array(qs)]).jsonString()
    }

    func testPrivateOptionsMakeAnUnsharedTestAndHideExplanationUntilSubmit() async throws {
        let b = try await backend()
        try await seed(b)
        let ai = ScriptedAI([Self.fiveTrueFalse()])
        b.context.ai.set(ai)
        let r = await call(b, "POST", "/api/tests/generate", ["module_id": 7, "duration_min": 15, "count": 5, "difficulty": "leicht", "types": ["tf"], "topic": "nur Kapitel 3"])
        XCTAssertEqual(r.status, 200, String(decoding: r.body, as: UTF8.self))
        let message = try await waitForJob(b)
        XCTAssertTrue(message.hasPrefix("Test: fertig"), message)
        XCTAssertTrue(ai.prompts.first?.contains("Genau 5 Aufgaben, alle mit \"difficulty\": \"leicht\"") ?? false)
        XCTAssertTrue(ai.prompts.first?.contains("nur Kapitel 3") ?? false)
        let listed = await call(b, "GET", "/api/tests").json?.array
        let list = try XCTUnwrap(listed)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0]["question_count"], 5)
        XCTAssertEqual(list[0]["shared"], .null, "eigener Test: nicht geteilt")
        let row = try await b.context.database.queryOne("SELECT share_key, share_variant FROM tests")
        XCTAssertEqual(row?["share_key"]?.json, .null, "kein Schluessel ausserhalb der Standardeinstellung")
        let id = Int(try XCTUnwrap(list[0]["id"]?.double))
        let opened = await call(b, "GET", "/api/tests/\(id)").json
        let open = try XCTUnwrap(opened)
        let first = try XCTUnwrap(open["questions"]?.array?.first)
        XCTAssertNil(first["explanation"], "Erklaerung erst nach Abgabe")
        XCTAssertNil(first["answer"])
        XCTAssertEqual(first["options"], ["Wahr", "Falsch"])
    }

    func testStandardOptionsFromTheDialogKeepTheShareKey() async throws {
        let b = try await backend()
        try await seed(b)
        b.context.ai.set(ScriptedAI([TestEndpointsTests.validTest()]))
        let body: JSONValue = ["module_id": 7, "duration_min": 45, "count": 15, "difficulty": "beliebig", "types": ["mc", "tf", "cloze", "short", "calc"], "topic": ""]
        let started = await call(b, "POST", "/api/tests/generate", body)
        XCTAssertEqual(started.status, 200)
        _ = try await waitForJob(b)
        let row = try await b.context.database.queryOne("SELECT share_key FROM tests")
        XCTAssertTrue(row?["share_key"]?.string?.hasPrefix(TestShare.version + ":") ?? false, "Standardeinstellung: Schluessel wie beim automatischen Wochentest")
    }

    func testInvalidOptionsAre400() async throws {
        let b = try await backend()
        try await seed(b)
        b.context.ai.set(ScriptedAI([TestEndpointsTests.validTest()]))
        for (body, text) in [(["module_id": 7, "count": 12] as JSONValue, "count muss 5, 10, 15 oder 20 sein"),
                             (["module_id": 7, "types": []], "types: mindestens eine Aufgabenart"),
                             (["module_id": 7, "types": ["essay"]], "types: unbekannte Aufgabenart 'essay'"),
                             (["module_id": 7, "difficulty": "einfach"], "difficulty muss beliebig, leicht, mittel oder schwer sein")] {
            let r = await call(b, "POST", "/api/tests/generate", body)
            XCTAssertEqual(r.status, 400, text)
            XCTAssertEqual(r.json?["detail"]?.string, text)
        }
        let bg = await call(b, "GET", "/api/bg").json
        XCTAssertEqual(bg?["running"], false, "nichts gestartet")
    }
}
