import Foundation
import XCTest
@testable import UniFlowCore

// Audit 08.11.2026, Paket 49 (KI-Datenfluss, Vorlesungsmarker, Uebungen, Altklausuren; docs/audit/AUDIT-2026-11-08-PAKET-48-49.md):
// - P49-06: Musterloesung ueber den Dateinamen: "Blatt 1" bekam die Loesung von "Blatt 10" (Teilwort-Rueckfall)
// - P49-03/07: erkannter Text (Texterkennung einer Scan-Seite) ist keine neue Fassung (`doc_version` auf der Textebene
//   wie app/weekly.py), sonst meldet der Marker "Dokument wurde geaendert" und sperrt den Stoff
// - P49-07: Marker nach einer echten Dokumentaenderung: verschoben, mehrdeutig, geaendert
// - P49 Textmengen: Wochentest-/Pruefungs-Prompt bleibt unter der Grenze des Dienstes (`weekly`: 120 000 Zeichen,
//   app/ai_relay.py), auch mit vielen Uebungsquellen
final class AuditPaket4849Tests: XCTestCase {

    private func backend() async throws -> LocalBackend {
        try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: .fixed(berlin: "2026-11-08T09:00:00")!)
    }

    /// 2026-11-06 12:00 als Sekunden ohne Zone (wie `Weekly.now`)
    private let now = Weekly.seconds("2026-11-06T12:00:00")!

    private func seedModule(_ c: SQLiteConnection) throws {
        try c.execute("INSERT INTO modules(id, name, color, created_at) VALUES (7, 'Testmathe', '#123456', '2026-10-01')")
        try c.execute("INSERT INTO courses(id, title, kind, created_at, module_id, active) VALUES ('k1', 'Testmathe I', 'vorlesung', '2026-10-01', 7, 1)")
        try c.execute("INSERT INTO courses(id, title, kind, created_at, module_id, active) VALUES ('k2', 'Übung Testmathe I', 'uebung', '2026-10-01', 7, 1)")
    }

    private func file(_ c: SQLiteConnection, _ id: String, _ name: String, course: String = "k1", chdate: Int = 5, docType: String? = nil) throws {
        try c.execute("INSERT INTO files(id, course_id, name, chdate, kind) VALUES (?, ?, ?, ?, 'pdf')",
                      [.text(id), .text(course), .text(name), .integer(Int64(chdate))])
        if let docType {
            try c.execute("INSERT INTO analysis(file_id, doc_type, created_at) VALUES (?, ?, '2026-10-01')", [.text(id), .text(docType)])
        }
    }

    /// neue Fassung: Aenderungszeit und Seitentexte
    private func revise(_ c: SQLiteConnection, _ id: String, chdate: Int, _ texts: [String]) throws {
        try c.execute("UPDATE files SET chdate=? WHERE id=?", [.integer(Int64(chdate)), .text(id)])
        try pages(c, id, texts, chdate: chdate)
    }

    private func pages(_ c: SQLiteConnection, _ id: String, _ texts: [String], chdate: Int = 5) throws {
        try c.execute("DELETE FROM page_texts WHERE file_id=?", [.text(id)])
        for (i, t) in texts.enumerated() {
            try c.execute("INSERT INTO page_texts(file_id, page, text, chdate, search) VALUES (?, ?, ?, ?, ?)",
                          [.text(id), .integer(Int64(i + 1)), .text(t), .integer(Int64(chdate)), .text(ScriptSearch.searchForm(t))])
        }
    }

    // MARK: P49-06 Musterloesung

    private func task(_ c: SQLiteConnection, _ fileID: String, _ source: String, _ nr: String) throws {
        try c.execute("""
            INSERT INTO task_index(file_id, version, module_id, source, nr, label, page_from, page_to, text, lecture_refs, content_hash, indexed_at)
            VALUES (?, 'v', 7, ?, ?, ?, 1, 1, ?, '[]', 'h', '2026-11-01T10:00:00')
            """, [.text(fileID), .text(source), .text(nr), .text("\(fileID) \(nr)"), .text("Text von \(fileID), Aufgabe \(nr)")])
    }

    private func solution(_ c: SQLiteConnection, _ fileID: String, _ nr: String) throws -> String? {
        try c.scalar("SELECT solution_file_id FROM task_index WHERE file_id=? AND nr=?", [.text(fileID), .text(nr)])?.string
    }

    /// "Übungsblatt 1" ohne eigene Loesung bekam "Übungsblatt 10 Lösung" (der Schluessel "übungsblatt1" steckt in
    /// "übungsblatt10"), umgekehrt ebenso. Nur gleiche Nummern im Namen duerfen ueber den Rueckfall zusammenfinden.
    func testP49_06SheetOneNeverGetsTheSolutionOfSheetTen() async throws {
        let b = try await backend()
        try await b.context.database.transaction { c in
            try self.seedModule(c)
            try self.file(c, "b1", "Übungsblatt 1.pdf", course: "k2")
            try self.file(c, "b10", "Übungsblatt 10.pdf", course: "k2")
            try self.file(c, "l10", "Übungsblatt 10 Lösung.pdf", course: "k2")
            try self.file(c, "b2", "Blatt 2.pdf", course: "k2")
            try self.file(c, "b20", "Blatt 20.pdf", course: "k2")
            try self.file(c, "l2", "Lösung Blatt 2.pdf", course: "k2")
            try self.file(c, "b3", "Blatt 3.pdf", course: "k2")
            try self.file(c, "l3", "Übungsblatt 3 Musterlösung.pdf", course: "k2")
            for f in ["b1", "b10", "b2", "b20", "b3"] { try self.task(c, f, "uebungsblatt", "1") }
            for f in ["l10", "l2", "l3"] { try self.task(c, f, "loesung", "1") }
            try Weekly.linkSolutions(c, 7)
            XCTAssertEqual(try self.solution(c, "b10", "1"), "l10", "gleicher Name ohne Loesungswort")
            XCTAssertNil(try self.solution(c, "b1", "1"), "Blatt 1 hat keine Loesung, nie die von Blatt 10")
            XCTAssertEqual(try self.solution(c, "b2", "1"), "l2")
            XCTAssertNil(try self.solution(c, "b20", "1"), "Blatt 20 hat keine Loesung, nie die von Blatt 2")
            XCTAssertEqual(try self.solution(c, "b3", "1"), "l3", "Rueckfall ueber den Namensteil mit gleicher Nummer bleibt")
        }
    }

    // MARK: P49-03/07 Texterkennung ist keine neue Fassung

    /// Marker auf einer Scan-Seite, deren Erkennung beim Setzen noch fehlte (Vorschau ohne Ergebnis); spaeter ergaenzt
    /// die Texterkennung die Seite (`PageOCRStore.fill`: page_ocr + page_texts). Das ist keine Dokumentaenderung.
    func testP49_RecognizedTextIsNoNewDocumentVersion() async throws {
        let b = try await backend()
        try await b.context.database.transaction { c in
            try self.seedModule(c)
            try self.file(c, "f1", "vl03.pdf", docType: "vorlesung")
            try self.pages(c, "f1", ["Grenzwerte von Folgen und Reihen", "  2 ", "Reihen und Konvergenzkriterien im Detail"])
            let before = try Weekly.docVersion(c, "f1")
            let m = try Weekly.createMarker(c, fileID: "f1", page: 2, lectureDate: "2026-11-05", now: self.now)
            // Texterkennung wie PageOCRStore.fill
            try PageOCRStore.ensureTable(c)
            let ocr = "Cauchy-Folgen und Vollstaendigkeit der reellen Zahlen"
            try c.execute("INSERT INTO page_ocr(file_id, page, chdate, embedded, text) VALUES ('f1', 2, 5, '  2 ', ?)", [.text(ocr)])
            try c.execute("UPDATE page_texts SET text=?, search=? WHERE file_id='f1' AND page=2", [.text(ocr), .text(ScriptSearch.searchForm(ocr))])
            XCTAssertEqual(try Weekly.docVersion(c, "f1"), before, "erkannter Text aendert die Fassung nicht (wie app/weekly.py text_layer)")
            let changes = try Weekly.revalidateMarkers(c, fileID: "f1", now: self.now + 60)
            XCTAssertEqual(changes.count, 0)
            let row = try Weekly.markerRow(c, Int64(m["id"]?.int ?? 0))
            XCTAssertEqual(row?["needs_review"]?.int, 0, "kein falscher Hinweis 'Dokument wurde geändert'")
            XCTAssertEqual(try Weekly.coverage(c, moduleID: 7).segments.count, 1, "Stoff zaehlt weiter fuer Wochentests")
        }
    }

    // MARK: P49-07 Marker nach Dokumentaenderung

    private let p = (1...6).map { "Seite \($0): Thema \($0) mit genug eigenem Text fuer den Fingerabdruck \($0 * 7)" }

    func testP49_07MarkerFollowsAMovedPageAndIsBlockedWhenAmbiguousOrChanged() async throws {
        let b = try await backend()
        try await b.context.database.transaction { c in
            try self.seedModule(c)
            try self.file(c, "f1", "vl03.pdf", docType: "vorlesung")
            try self.pages(c, "f1", Array(self.p[0..<5]))
            let m = try Weekly.createMarker(c, fileID: "f1", page: 3, lectureDate: "2026-11-05", now: self.now)
            let id = Int64(m["id"]?.int ?? 0)

            // 1) neue Fassung mit eingeschobener Seite: Seite 3 steht jetzt auf Seite 4 -> Marker wandert mit
            try self.revise(c, "f1", chdate: 6, [self.p[0], "Neue eingeschobene Seite zum Thema Vorwissen", self.p[1], self.p[2], self.p[3]])
            try Weekly.revalidateMarkers(c, fileID: "f1", now: self.now + 60)
            var row = try XCTUnwrap(Weekly.markerRow(c, id))
            XCTAssertEqual(row["page"]?.int, 4)
            XCTAssertEqual(row["needs_review"]?.int, 0)
            XCTAssertEqual(try Weekly.coverage(c, moduleID: 7).segments.map { [$0.from, $0.to] }, [[1, 4]])

            // 2) Seite doppelt: nicht eindeutig -> zur Pruefung, Stoff zaehlt nicht
            try self.revise(c, "f1", chdate: 7, [self.p[0], self.p[2], self.p[1], self.p[3], self.p[2]])
            try Weekly.revalidateMarkers(c, fileID: "f1", now: self.now + 120)
            row = try XCTUnwrap(Weekly.markerRow(c, id))
            XCTAssertEqual(row["needs_review"]?.int, 1)
            XCTAssertEqual(row["page"]?.int, 4, "Seite bleibt bis zur Pruefung")
            var cov = try Weekly.coverage(c, moduleID: 7)
            XCTAssertTrue(cov.segments.isEmpty)
            XCTAssertEqual(cov.blocked.count, 1)

            // 3) Inhalt geaendert (Seite nirgends mehr): bleibt gesperrt
            try self.revise(c, "f1", chdate: 8, [self.p[0], self.p[1], self.p[3], self.p[4], self.p[5]])
            try Weekly.revalidateMarkers(c, fileID: "f1", now: self.now + 180)
            row = try XCTUnwrap(Weekly.markerRow(c, id))
            XCTAssertEqual(row["needs_review"]?.int, 1)
            cov = try Weekly.coverage(c, moduleID: 7)
            XCTAssertTrue(cov.segments.isEmpty)

            // 4) Pruefen = Marker neu auf eine Seite setzen: zaehlt wieder
            _ = try Weekly.updateMarker(c, id: id, page: 2, now: self.now + 240)
            row = try XCTUnwrap(Weekly.markerRow(c, id))
            XCTAssertEqual(row["needs_review"]?.int, 0)
            XCTAssertEqual(try Weekly.coverage(c, moduleID: 7).segments.map { [$0.from, $0.to] }, [[1, 2]])
        }
    }

    // MARK: P49 Textmengen an die KI

    /// Grenze des Dienstes fuer die Aufgabe `weekly` (app/ai_relay.py `_tasks()["weekly"].max_chars`); ein laengerer
    /// Prompt endet mit 413 `prompt_too_large`, der Wochentest scheitert dann bei jedem Versuch
    static let relayWeeklyMaxChars = 120_000

    private func long(_ n: Int) -> String { String(String(repeating: "wort ", count: n / 5 + 1).prefix(n)) }

    /// Modul mit fuenf Uebungsquellen (je 5 Aufgaben) und 4 Altklausuraufgaben, lange Aufgabentexte und Loesungen, 60
    /// markierte Seiten, 12 fruehere Abschnitte: Entwurf und Fachpruefung (mit 15 ausfuehrlichen Aufgaben) bleiben unter
    /// der Grenze. Vorher: Fachpruefung ~122 000 Zeichen -> "Fachprüfung fehlgeschlagen" in jeder Runde.
    func testP49_PromptsStayBelowTheServiceLimitWithManyExerciseSources() async throws {
        let b = try await backend()
        let ctx: Weekly.Context = try await b.context.database.transaction { c in
            try self.seedModule(c)
            try self.file(c, "f1", "vl.pdf", docType: "vorlesung")
            try self.pages(c, "f1", (1...80).map { "Folie \($0) " + self.long(1200) })
            // Stud.IP-Kurs mit Beschreibung und Hinweisen (geht als Einordnung mit, `CourseContext`)
            try c.execute("UPDATE courses SET description=?, miscellaneous=? WHERE id='k1'", [.text(self.long(2000)), .text(self.long(1000))])
            let prior = (0..<12).map { k in
                PyJSON.object([.init("file_id", .string("f1")), .init("version", .string("v")), .init("from", Weekly.i(k + 1)), .init("to", Weekly.i(k + 1)),
                               .init("week", Weekly.i(1)), .init("marker_id", .int("1")), .init("topic", .string(String(repeating: "T", count: 120))),
                               .init("lecture_date", .string("2026-10-20")), .init("lecture_end", .string("2026-10-20T12:00:00"))])
            }
            let new = PyJSON.object([.init("file_id", .string("f1")), .init("version", .string("v")), .init("from", Weekly.i(13)), .init("to", Weekly.i(80)),
                                     .init("week", Weekly.i(3)), .init("marker_id", .int("2")), .init("topic", .string("Neues Thema")),
                                     .init("lecture_date", .string("2026-11-03")), .init("lecture_end", .string("2026-11-03T12:00:00"))])
            let covj = PyJSON.object([.init("new", .array([new])), .init("prior", .array(prior)), .init("blocked", .array([]))])
            let plan: [String: JSONValue] = ["id": 1, "module_id": 7, "week_no": 3, "scope_key": "k", "coverage": .string(covj.dumps(ensureASCII: false)),
                                             "lecture_end": "2026-11-03T12:00:00"]
            var cands: [Weekly.Candidate] = []
            let sources = ["uebungsblatt", "zusatz", "hoersaaluebung", "gruppenuebung", "tutorium"]
            for (k, s) in (sources.flatMap { Array(repeating: $0, count: 5) } + Array(repeating: "altklausur", count: 4)).enumerated() {
                let row: [String: JSONValue] = ["id": .number(Double(k + 1)), "source": .string(s), "label": .string("\(s) · Blatt · Aufgabe \(k + 1)"),
                                                "text": .string(self.long(6000)), "solution_text": .string(self.long(5000)), "file_id": "u1",
                                                "page_from": 1, "points": 10, "difficulty": 3, "exam_term": s == "altklausur" ? "WS 23" : .null]
                cands.append(Weekly.Candidate(row: row, isNewWeek: true, refs: [Weekly.Ref(fileID: "f1", page: 20, score: 9)]))
            }
            return try Weekly.buildContext(c, plan: plan, ok: cands, excluded: [], missing: [])
        }
        XCTAssertEqual(ctx.tasks.count, 29, "je Quelle hoechstens 5, Altklausur 4")
        XCTAssertEqual(ctx.lecture.count, 60)
        let gen = Weekly.genPrompt(ctx)
        let q = PyJSON.object([.init("nr", Weekly.i(1)), .init("level", .string("mittel")), .init("type", .string("calc")), .init("topic", .string("Thema")),
                               .init("difficulty", Weekly.i(3)),
                               .init("question", .string(long(400))), .init("answer", .string(long(800))),
                               .init("steps", .array(Array(repeating: .string(long(150)), count: 4))),
                               .init("rubric", .array(Array(repeating: .object([.init("criterion", .string(long(80))), .init("points", Weekly.i(5))]), count: 3))),
                               .init("points", Weekly.i(7)), .init("refs", .array([.string("L1"), .string("A2")])), .init("from_exam", .null),
                               .init("exam_mode", .null)])
        let review = Weekly.reviewPrompt(ctx, Array(repeating: q, count: 15))
        XCTAssertLessThan(Weekly.len(gen), Self.relayWeeklyMaxChars)
        XCTAssertLessThan(Weekly.len(review), Self.relayWeeklyMaxChars, "Fachpruefung muss der Dienst annehmen")
        // jede Aufgabe kommt noch mit Text und Loesung an
        XCTAssertTrue(ctx.tasks.allSatisfy { Weekly.len($0.text) >= 500 && Weekly.len($0.solution) >= 300 })
    }

    /// Wenige Aufgaben (bis 14): Text und Loesung so lang wie bisher (1400/900), der gemeinsame Vertrag mit Python
    /// (weekly.json) bleibt unveraendert
    func testP49_FewTasksKeepTheirFullLength() {
        XCTAssertEqual(Weekly.taskChars(14), 1400)
        XCTAssertEqual(Weekly.solutionChars(14), 900)
        XCTAssertEqual(Weekly.taskChars(1), 1400)
        XCTAssertEqual(Weekly.taskChars(29), 689)
        XCTAssertEqual(Weekly.solutionChars(29), 448)
        XCTAssertEqual(Weekly.taskChars(100), 500)
        XCTAssertEqual(Weekly.solutionChars(100), 300)
    }
}
