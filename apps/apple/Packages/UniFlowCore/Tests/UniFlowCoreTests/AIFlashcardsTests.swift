import Foundation
import XCTest
@testable import UniFlowCore

// Karteikarten aus einem Dokument (03.11.2026): Prompt, Schema und Pruefung byte-gleich mit app/ai.py
// (packages/shared-contracts/ai/contract.json, tools/gen-ai-contract.py) und der Endpunkt POST /api/ai/flashcards
// des lokalen Backends wie `ai_flashcards` in app/server.py. Nichts geht ins Netz.

private func contract() throws -> PyJSON {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return try PyJSON.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/ai/contract.json")))
}

private func g(_ v: PyJSON?, _ key: String) -> PyJSON? { AIPrompts.get(v, key) }
private func s(_ v: PyJSON?, _ key: String) -> String { if case .string(let t)? = g(v, key) { return t }; return "" }
private func list(_ v: PyJSON?, _ key: String) -> [PyJSON] { if case .array(let a)? = g(v, key) { return a }; return [] }

/// Schein-KI, die sich auch das Schema merkt
private final class SchemaFakeAI: AIProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(system: String, prompt: String, schema: JSONValue?)] = []
    var reply: String
    var failure: AIError?
    init(_ reply: String) { self.reply = reply }
    var prompts: [(system: String, prompt: String, schema: JSONValue?)] { lock.withLock { calls } }
    func answer(system: String, prompt: String) async throws -> String { try await answer(system: system, prompt: prompt, schema: nil) }
    func answer(system: String, prompt: String, schema: JSONValue?) async throws -> String {
        lock.withLock { calls.append((system, prompt, schema)) }
        if let failure { throw failure }
        return reply
    }
}

final class AIFlashcardsTests: XCTestCase {

    private func same(_ swift: String, _ python: String, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        if !swift.unicodeScalars.elementsEqual(python.unicodeScalars) {
            let x = Array(swift.unicodeScalars), y = Array(python.unicodeScalars)
            let i = zip(x, y).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(x.count, y.count)
            func around(_ u: [Unicode.Scalar]) -> String { String(String.UnicodeScalarView(u[max(0, i - 40)..<min(u.count, i + 40)])) }
            XCTFail("\(label): ab Zeichen \(i):\n  Swift  \(around(x).debugDescription)\n  Python \(around(y).debugDescription)", file: file, line: line)
        }
    }

    func testTextsAndSchemaMatchPython() throws {
        let t = g(try contract(), "texts")
        XCTAssertEqual(g(t, "flashcards_default"), .int(String(AIPrompts.flashcardsDefault)))
        XCTAssertEqual(g(t, "flashcards_max"), .int(String(AIPrompts.flashcardsMax)))
        XCTAssertEqual(g(t, "flashcards_text_chars"), .int(String(AIPromptTexts.flashcardsTextChars)))
        let schema = try XCTUnwrap(g(t, "flashcards_schema"))
        XCTAssertEqual(AIPrompts.flashcardsSchema, schema.json, "Schema wie ai.FLASHCARDS_SCHEMA")
        XCTAssertEqual(AIPrompts.flashcardsSchema["required"], ["cards"])
        XCTAssertEqual(AIPrompts.flashcardsSchema["properties"]?["cards"]?["items"]?["required"], ["question", "answer", "kind", "page"])
    }

    func testPromptsMatchPython() throws {
        let cases = list(g(try contract(), "prompts"), "flashcards")
        XCTAssertGreaterThanOrEqual(cases.count, 4)
        for (i, c) in cases.enumerated() {
            let a = g(c, "in")
            var pages: [Int] = []
            if case .array(let p)? = g(a, "pages") { pages = p.compactMap { if case .int(let d) = $0 { return Int(d) }; return nil } }
            let count: Int = { if case .int(let d)? = g(a, "count") { return Int(d) ?? AIPrompts.flashcardsDefault }; return AIPrompts.flashcardsDefault }()
            let p = AIPrompts.flashcards(course: s(a, "course"), fileName: s(a, "file_name"), pages: pages, text: s(a, "text"),
                                         count: count, topic: s(a, "topic"))
            same(p, s(c, "prompt"), "Karteikarten-Prompt \(i)")
        }
        // Seitenangabe und Schwerpunkt sichtbar, Text als Material gekennzeichnet
        let p = AIPrompts.flashcards(course: "K", fileName: "f.pdf", pages: [2, 3], text: "Inhalt", count: 7, topic: "Beweise")
        XCTAssertTrue(p.contains("Datei: f.pdf, Seiten 2–3"))
        XCTAssertTrue(p.contains("Erstelle genau 7 Karteikarten"))
        XCTAssertTrue(p.contains(AIPromptTexts.flashcardsRules) && p.hasSuffix(AIPromptTexts.flashcardsAnswerForm))
        XCTAssertTrue(p.contains("SCHWERPUNKT: Beweise"))
        XCTAssertTrue(p.contains(AIPromptTexts.untrusted))
        XCTAssertTrue(AIPrompts.flashcards(course: "K", fileName: "f.pdf", pages: [4], text: " ").contains("Seite 4\n"))
        XCTAssertTrue(AIPrompts.flashcards(course: "K", fileName: "f.pdf", pages: [], text: " ").contains("[kein Text extrahierbar]"))
    }

    func testPagesTextMatchesPython() throws {
        let cases = list(try contract(), "flashcards_pages_text")
        XCTAssertGreaterThanOrEqual(cases.count, 4)
        for (i, c) in cases.enumerated() {
            let pages = list(c, "pages").compactMap { v -> Int? in if case .int(let d) = v { return Int(d) }; return nil }
            let texts = list(c, "texts").map { v -> String in if case .string(let t) = v { return t }; return "" }
            same(AIPrompts.flashcardsPagesText(pages: pages, texts: texts), s(c, "out"), "Seitentext \(i)")
        }
    }

    /// Gespeicherte Stapel (CardStackShare) bleiben ganz: ohne die Qualitaetspruefung fallen nur leere Karten weg
    func testStoredStacksKeepAllCards() {
        let long = String(repeating: "A", count: AIPromptTexts.flashcardsAnswerChars + 1)
        let res: PyJSON = .array([.object([.init("question", .string("F")), .init("answer", .string(long))]),
                                  .object([.init("question", .string("F")), .init("answer", .string("doppelt"))])])
        XCTAssertEqual(AIAnswers.checkFlashcards(res).count, 1, "zu lang faellt weg, die zweite Karte bleibt")
        XCTAssertEqual(AIAnswers.checkFlashcards(res, quality: false).count, 2)
    }

    func testCheckAndCountMatchPython() throws {
        let cases = list(try contract(), "check_flashcards")
        XCTAssertGreaterThanOrEqual(cases.count, 10)
        for (i, c) in cases.enumerated() {
            if let input = g(c, "in") {
                let expected = list(c, "out").map { AIAnswers.Flashcard(question: s($0, "question"), answer: s($0, "answer")) }
                var pages: [Int] = []
                if case .array(let p)? = g(c, "pages") { pages = p.compactMap { if case .int(let d) = $0 { return Int(d) }; return nil } }
                XCTAssertEqual(AIAnswers.checkFlashcards(input, pages: pages), expected, "Fall \(i)")
            } else {
                // null kommt als fehlender Schluessel nicht zurueck: `in` fehlt, `out` ist leer
                if case .object(let members) = c, members.contains(where: { $0.key == "out" }) {
                    XCTAssertEqual(AIAnswers.checkFlashcards(.null), [], "Fall \(i)")
                } else {
                    XCTAssertEqual(g(c, "count"), .int(String(AIPrompts.flashcardsCount(g(c, "count_in")))), "Zahl der Karten, Fall \(i)")
                }
            }
        }
        XCTAssertEqual(AIPrompts.flashcardsCount(nil), AIPrompts.flashcardsDefault)
        XCTAssertEqual(AIPrompts.flashcardsCount(.int("50")), AIPrompts.flashcardsMax)
    }

    // MARK: Endpunkt

    private func backend() async throws -> LocalBackend {
        try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: .fixed(berlin: "2026-11-03T09:00:00")!)
    }

    private func post(_ b: LocalBackend, _ path: String, _ body: JSONValue) async -> LocalResponse {
        await b.handle(LocalRequest(method: "POST", url: URL(string: "uniflow-local://device" + path)!,
                                    headers: ["Content-Type": "application/json"], body: body.serialized()))
    }

    /// Modul mit einer Datei und drei Seitentexten (wie nach dem Download)
    private func seed(_ b: LocalBackend) async throws {
        try await b.context.database.transaction { c in
            try c.execute("INSERT INTO modules(id, name, color, created_at) VALUES (7, 'Testmathe', '#123456', '2026-10-01')")
            try c.execute("INSERT INTO courses(id, title, kind, created_at, module_id, active) VALUES ('k1', 'Testmathe I', 'vorlesung', '2026-10-01', 7, 1)")
            try c.execute("INSERT INTO files(id, course_id, name, chdate, kind) VALUES ('f1', 'k1', 'vl03.pdf', 5, 'pdf')")
            try c.execute("INSERT INTO files(id, course_id, name, chdate, kind) VALUES ('f2', 'k1', 'leer.pdf', 5, 'pdf')")
            for (p, t) in [(1, "Grenzwerte von Folgen und Konvergenz"), (2, "Cauchy-Folgen und Vollstaendigkeit"), (3, "Reihen und Konvergenzkriterien")] {
                try c.execute("INSERT INTO page_texts(file_id, page, text, chdate, search) VALUES ('f1', ?, ?, 5, ?)",
                              [.integer(Int64(p)), .text(t), .text(ScriptSearch.searchForm(t))])
            }
        }
    }

    func testEndpointBuildsPromptFromChosenPagesAndPassesTheSchema() async throws {
        let b = try await backend()
        try await seed(b)
        let noAI = await post(b, "/api/ai/flashcards", ["file_id": "f1"])
        XCTAssertEqual(noAI.status, 404, "ohne KI")
        let ai = SchemaFakeAI(#"```json\n{"cards": [{"question": " Was ist eine Cauchy-Folge? ", "answer": "Eine Folge, deren Glieder sich beliebig nahe kommen.", "kind": "begriff", "page": 2}, {"question": "", "answer": "x"}, {"question": "Reihe?", "answer": "Summe", "page": 1}]}\n```"#)
        b.context.ai.set(ai)
        let r = await post(b, "/api/ai/flashcards", ["file_id": "f1", "pages": [3, 2, 3, 99, "2"], "count": "2", "topic": " Konvergenz "])
        XCTAssertEqual(r.status, 200, String(decoding: r.body, as: UTF8.self))
        let j = try XCTUnwrap(r.json)
        XCTAssertEqual(j["pages"], [2, 3], "aufsteigend, ohne Doppelte, nur vorhandene Seiten")
        XCTAssertEqual(j["count"], 2)
        XCTAssertEqual(j["cards"]?.array?.map { $0["question"]?.string ?? "" }, ["Was ist eine Cauchy-Folge?", "Reihe?"], "nur Karten mit Frage und Antwort, ohne Leerraum")
        XCTAssertEqual(j["cards"]?.array?.map { $0["answer"]?.string ?? "" },
                       ["Eine Folge, deren Glieder sich beliebig nahe kommen. (S. 2)", "Summe"], "Seitenangabe nur fuer gewaehlte Seiten")
        let call = try XCTUnwrap(ai.prompts.first)
        XCTAssertEqual(call.system, AIPromptTexts.system)
        XCTAssertEqual(call.schema, AIPrompts.flashcardsSchema, "Schema an die KI")
        XCTAssertTrue(call.prompt.hasPrefix("Kurs: Testmathe I\nDatei: vl03.pdf, Seiten 2–3\n"), call.prompt)
        XCTAssertTrue(call.prompt.contains("genau 2 Karteikarten"))
        XCTAssertTrue(call.prompt.contains("SCHWERPUNKT: Konvergenz"))
        XCTAssertTrue(call.prompt.contains("### Seite 2\nCauchy-Folgen und Vollstaendigkeit\n\n### Seite 3\nReihen und Konvergenzkriterien"), "Text der gewaehlten Seiten")
        XCTAssertFalse(call.prompt.contains("Grenzwerte von Folgen"), "Seite 1 nicht gewaehlt")
        XCTAssertEqual(ai.prompts.count, 1)

        // ohne Seitenangabe: die ersten Seiten, Vorgabe fuer die Zahl
        let all = await post(b, "/api/ai/flashcards", ["file_id": "f1"])
        XCTAssertEqual(all.status, 200)
        XCTAssertEqual(all.json?["pages"], [1, 2, 3])
        XCTAssertEqual(all.json?["count"], .number(Double(AIPrompts.flashcardsDefault)))
        XCTAssertTrue(ai.prompts.last?.prompt.contains("Seiten 1–3") ?? false)

        // Fehlerfaelle wie am PC: ohne file_id 400, unbekannte Datei 404, ohne Seitentext 404 no_content, ohne Karten 502
        let noFile = await post(b, "/api/ai/flashcards", [:])
        XCTAssertEqual(noFile.status, 400)
        let unknown = await post(b, "/api/ai/flashcards", ["file_id": "gibt-es-nicht"])
        XCTAssertEqual(unknown.status, 404)
        let none = await post(b, "/api/ai/flashcards", ["file_id": "f2"])
        XCTAssertEqual(none.status, 404)
        XCTAssertEqual(none.json?["detail"]?["code"], "no_content")
        ai.reply = "Hier sind keine Karten."
        let empty = await post(b, "/api/ai/flashcards", ["file_id": "f1", "pages": [1]])
        XCTAssertEqual(empty.status, 502)
        XCTAssertEqual(empty.json?["detail"]?["code"], "ai_no_cards")
        ai.failure = AIError("chatgpt_limit", "Kontingent aufgebraucht")
        let limited = await post(b, "/api/ai/flashcards", ["file_id": "f1"])
        XCTAssertEqual(limited.status, 429)
    }

    func testPageListLikePython() {
        XCTAssertEqual(AIEndpoints.pageList(.array([.int("3"), .int("1"), .int("3"), .float(2.7), .string("4"), .bool(true), .null, .int("0"), .int("-2")]), total: 3), [1, 2, 3])
        XCTAssertEqual(AIEndpoints.pageList(nil, total: 5), [1, 2, 3, 4, 5])
        XCTAssertEqual(AIEndpoints.pageList(.string("x"), total: 25), Array(1...AIEndpoints.flashcardPagesMax))
        XCTAssertEqual(AIEndpoints.pageList(.array((1...40).map { .int(String($0)) }), total: 40).count, AIEndpoints.flashcardPagesMax)
        XCTAssertEqual(AIEndpoints.pageList(.array([.int("9")]), total: nil), [9])
        XCTAssertEqual(AIEndpoints.pageList(nil, total: nil), [])
    }
}
