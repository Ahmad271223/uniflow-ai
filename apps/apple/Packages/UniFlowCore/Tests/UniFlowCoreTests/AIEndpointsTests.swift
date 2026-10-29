import Foundation
import XCTest
@testable import UniFlowCore

// KI-Endpunkte des lokalen Backends mit der KI des Nutzers (`LocalContext.ai`) wie app/server.py am eigenen PC:
// POST /api/ai/tutor mit Seitentext, Quellen aus der Skriptsuche und Karteikarten. Ohne KI unveraendert 404.

/// Schein-KI: merkt sich die Prompts, antwortet fest oder mit einem Fehler
final class FakeAI: AIProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(system: String, prompt: String)] = []
    var reply: String
    var failure: AIError?
    init(_ reply: String = "Antwort") { self.reply = reply }
    var prompts: [(system: String, prompt: String)] { lock.withLock { calls } }
    func answer(system: String, prompt: String) async throws -> String {
        lock.withLock { calls.append((system, prompt)) }
        if let failure { throw failure }
        return reply
    }
}

final class AIEndpointsTests: XCTestCase {
    private func backend() async throws -> LocalBackend {
        try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: .fixed(berlin: "2026-10-29T09:00:00")!)
    }

    private func post(_ b: LocalBackend, _ path: String, _ body: JSONValue) async -> LocalResponse {
        await b.handle(LocalRequest(method: "POST", url: URL(string: "uniflow-local://device" + path)!,
                                    headers: ["Content-Type": "application/json"], body: body.serialized()))
    }

    /// Modul mit zwei Dateien und Seitentexten (wie nach dem Download)
    private func seed(_ b: LocalBackend) async throws {
        try await b.context.database.transaction { c in
            try c.execute("INSERT INTO modules(id, name, color, created_at) VALUES (7, 'Testmathe', '#123456', '2026-10-01')")
            try c.execute("INSERT INTO courses(id, title, kind, created_at, module_id, active) VALUES ('k1', 'Testmathe I', 'vorlesung', '2026-10-01', 7, 1)")
            for (id, name, type) in [("f1", "vl03.pdf", "vorlesung"), ("f2", "skript.pdf", "skript")] {
                try c.execute("INSERT INTO files(id, course_id, name, chdate, kind) VALUES (?, 'k1', ?, 5, 'pdf')", [.text(id), .text(name)])
                try c.execute("INSERT INTO analysis(file_id, doc_type, raw) VALUES (?, ?, '{}')", [.text(id), .text(type)])
            }
            // Skriptsuche: Vorlesungen und Skripte, Seiten ab 1, mindestens fuenf Woerter
            let pages: [(String, Int, String)] = [
                ("f1", 1, "Grenzwerte von Folgen und Konvergenz im Reellen, Beispiele monotoner beschränkter Folgen, Epsilon-Kriterium"),
                // zweiter, schwacher Kandidat: die Skriptsuche verlangt deutlichen Abstand zum Durchschnitt (s >= 1,6 x Mittel),
                // ein einzelner Kandidat faellt am PC wie hier heraus
                ("f1", 2, "Cauchy-Folgen sind in vollständigen metrischen Räumen konvergent, Beweis über Teilfolgen, Reihen und Konvergenz"),
                ("f2", 1, "Integralrechnung mit Stammfunktionen, partieller Integration, Substitutionsregel und Beispielen"),
                ("f2", 2, "Konvergenz unendlicher Reihen: Quotientenkriterium, Wurzelkriterium, Majorantenkriterium, Leibnizkriterium")]
            for (f, p, t) in pages {
                try c.execute("INSERT INTO page_texts(file_id, page, text, chdate, search) VALUES (?,?,?,5,?)",
                              [.text(f), .integer(Int64(p)), .text(t), .text(ScriptSearch.searchForm(t))])
            }
        }
    }

    func testAnalysisOfOneFileIsStoredLikePlannerAndOnlyThisFile() async throws {
        let b = try await backend()
        try await seed(b)
        let none = await post(b, "/api/files/f1/analyze", [:])
        XCTAssertEqual(none.status, 404, "ohne KI")
        let ai = FakeAI(#"```json\n{"doc_type": "vorlesung", "title": "Folgen und Grenzwerte", "topics": ["Folgen", "Konvergenz"], "difficulty": "4", "est_minutes": 75.9, "summary": "Worum es geht", "prerequisites": []}\n```"#)
        b.context.ai.set(ai)
        let r = await post(b, "/api/files/f1/analyze", [:])
        XCTAssertEqual(r.status, 200, String(decoding: r.body, as: UTF8.self))
        let a = try XCTUnwrap(r.json?["analysis"])
        XCTAssertEqual(a["doc_type"], "vorlesung")
        XCTAssertEqual(a["difficulty"], 4, "int(\"4\") wie in Python")
        XCTAssertEqual(a["est_minutes"], 75, "int(75.9)")
        XCTAssertEqual(a["topics"], #"["Folgen", "Konvergenz"]"#)
        XCTAssertTrue(a["raw"]?.string?.contains(#""_input": "text""#) ?? false)
        XCTAssertEqual(ai.prompts.count, 1, "genau eine Anfrage: nur diese Datei")
        let prompt = try XCTUnwrap(ai.prompts.first?.prompt)
        XCTAssertTrue(prompt.hasPrefix("Analysiere diese Lernunterlage aus dem Kurs \"Testmathe I\".\nDateiname: vl03.pdf"), prompt)
        XCTAssertTrue(prompt.contains("Grenzwerte von Folgen und Konvergenz im Reellen"), "Seitentext der Datei")
        let other = try await b.context.database.queryOne("SELECT 1 FROM analysis WHERE file_id=\u{27}f2\u{27} AND created_at IS NOT NULL")
        XCTAssertNil(other, "andere Dateien unberuehrt")
        let excerpt = try await b.context.database.scalar("SELECT text_excerpt FROM files WHERE id=\u{27}f1\u{27}")?.string
        XCTAssertTrue(excerpt?.hasPrefix("Grenzwerte von Folgen") ?? false)
        // Antwort ohne Einordnung: nichts gespeichert
        ai.reply = #"{"title": "ohne Art"}"#
        let bad = await post(b, "/api/files/f2/analyze", [:])
        XCTAssertEqual(bad.status, 502)
        XCTAssertEqual(bad.json?["detail"]?["code"], "ai_no_analysis")
        let kept = try await b.context.database.scalar("SELECT doc_type FROM analysis WHERE file_id=\u{27}f2\u{27}")?.string
        XCTAssertEqual(kept, "skript", "alte Einordnung bleibt")
        let missing = await post(b, "/api/files/fx/analyze", [:])
        XCTAssertEqual(missing.status, 404)
    }

    func testWithoutAIStill404() async throws {
        let b = try await backend()
        let r = await post(b, "/api/ai/tutor", ["mode": "explain"])
        XCTAssertEqual(r.status, 404)
        XCTAssertEqual(r.json?["detail"]?.string, DroppedEndpoints.noAI)
    }

    func testPageTextWithoutFileGoesStraightIntoThePrompt() async throws {
        let b = try await backend()
        let ai = FakeAI("Erklärung [1]")
        b.context.ai.set(ai)
        let r = await post(b, "/api/ai/tutor", ["mode": "hints", "page_text": "Aufgabe 2", "selection": "markiert", "question": "Wie?"])
        XCTAssertEqual(r.status, 200, String(decoding: r.body, as: UTF8.self))
        XCTAssertEqual(r.json?["answer"], "Erklärung [1]")
        XCTAssertEqual(r.json?["sources"], [], "ohne Datei keine Quellen")
        XCTAssertEqual(r.json?["cards"], .null)
        XCTAssertEqual(ai.prompts.first?.system, AIPromptTexts.tutorSystem)
        XCTAssertEqual(ai.prompts.first?.prompt, AIPrompts.tutor(mode: "hints", pageText: "Aufgabe 2", selection: "markiert", question: "Wie?",
                                                                 page: .int("1")))
    }

    func testFileUsesStoredPageAndSourcesFromTheModule() async throws {
        let b = try await backend()
        try await seed(b)
        let ai = FakeAI("Siehe [2], nicht [7].")
        b.context.ai.set(ai)
        // Markierung mit mehreren Fachbegriffen: die Skriptsuche (BM25) verlangt mindestens zwei Treffer und eine Mindestguete
        let r = await post(b, "/api/ai/tutor", ["mode": "explain", "file_id": "f1", "page": 1,
                                                "selection": "Konvergenz unendlicher Reihen: Quotientenkriterium, Wurzelkriterium, Majorantenkriterium, Leibnizkriterium"])
        XCTAssertEqual(r.status, 200, String(decoding: r.body, as: UTF8.self))
        let sources = r.json?["sources"]?.array ?? []
        XCTAssertEqual(sources.first?["current"], true)
        XCTAssertEqual(sources.first?["page"], 1)
        XCTAssertEqual(sources.first?["title"], "vl03.pdf")
        XCTAssertTrue(sources.dropFirst().contains { $0["file_id"] == "f2" && $0["page"] == 2 }, "\(sources)")
        XCTAssertFalse(sources.dropFirst().contains { $0["file_id"] == "f1" && $0["page"] == 1 }, "die offene Seite nicht doppelt")
        XCTAssertEqual(sources.first { $0["n"] == 2 }?["cited"], true)
        XCTAssertEqual(sources.first?["cited"], false)
        let prompt = try XCTUnwrap(ai.prompts.first?.prompt)
        XCTAssertTrue(prompt.contains("Kurs: Testmathe I\nDatei: vl03.pdf, Seite 1"), prompt)
        XCTAssertTrue(prompt.contains("Grenzwerte von Folgen und Konvergenz im Reellen"), "Seitentext aus page_texts")
        XCTAssertTrue(prompt.contains("[1] vl03.pdf, Seite 1 (diese Seite)"), prompt)
        XCTAssertTrue(prompt.contains("skript.pdf, Seite 2: Konvergenz unendlicher Reihen"), prompt)
        XCTAssertFalse(prompt.contains("Integralrechnung"), "nur passende Seiten")
    }

    func testFlashcardsComeBackParsedAndWithoutSources() async throws {
        let b = try await backend()
        try await seed(b)
        let ai = FakeAI("```json\n[{\"question\": \"Was ist ein Grenzwert?\", \"answer\": \"…\"}]\n```")
        b.context.ai.set(ai)
        let r = await post(b, "/api/ai/tutor", ["mode": "flashcards", "file_id": "f1", "page": 2])
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.json?["cards"]?.array?.first?["question"], "Was ist ein Grenzwert?")
        XCTAssertEqual(r.json?["sources"], [])
        XCTAssertFalse(ai.prompts.first?.prompt.contains("QUELLEN") ?? true)
        XCTAssertTrue(ai.prompts.first?.prompt.contains("Cauchy-Folgen") ?? false)
    }

    func testFileWithoutPageTextIs404AndAIErrorsKeepTheirCode() async throws {
        let b = try await backend()
        try await seed(b)
        try await b.context.database.execute("INSERT INTO files(id, course_id, name, chdate, kind) VALUES ('f3', 'k1', 'leer.pdf', 5, 'pdf')")
        let ai = FakeAI()
        b.context.ai.set(ai)
        let r = await post(b, "/api/ai/tutor", ["file_id": "f3"])
        XCTAssertEqual(r.status, 404)
        XCTAssertEqual(r.json?["detail"]?["code"], "no_content", "wie HTTPException(404, {detail, code}) am PC")
        XCTAssertTrue(ai.prompts.isEmpty, "nichts gesendet")
        ai.failure = AIError("chatgpt_limit", "Kontingent aufgebraucht")
        let limited = await post(b, "/api/ai/tutor", ["page_text": "x"])
        XCTAssertEqual(limited.status, 429)
        XCTAssertEqual(limited.json?["detail"]?["code"], "chatgpt_limit")
        ai.failure = AIError("chatgpt_login_needed", "neu verbinden")
        let login = await post(b, "/api/ai/tutor", ["page_text": "x"])
        XCTAssertEqual(login.status, 503)
        XCTAssertEqual(login.json?["detail"]?["detail"], "neu verbinden")
        b.context.ai.set(nil)
        let gone = await post(b, "/api/ai/tutor", ["page_text": "x"])
        XCTAssertEqual(gone.status, 404, "getrennt: wieder ohne KI")
    }
}
