import Foundation
import XCTest
@testable import UniFlowCore

// KI-Lernplan (AIStudyPlan.swift, AIPlanEndpoints.swift, 07.11.2026): der Prompt nennt nur Titel, Wochen, Dateinamen,
// Arten, Dauern, Termine und Zeiten; die Antwort wird gegen die Eingabe geprueft; `ai-suggest` liefert nur den
// Vorschlag, `ai-apply` legt die gewaehlten Bloecke als Lernpakete an. Schein-KI, nie ins Netz.

final class AIStudyPlanTests: XCTestCase {
    private var input: AIStudyPlan.Input {
        AIStudyPlan.Input(
            today: "2026-11-09", minutesPerDay: 240, subjectsPerDay: 2,
            days: [.init(date: "2026-11-09", week: 5, freeMinutes: 180, planned: []),
                   .init(date: "2026-11-10", week: 5, freeMinutes: 90, planned: ["Analysis · Folgen · 45 min"])],
            modules: [.init(id: 7, name: "Analysis I", priority: 3, examDate: "2027-02-10",
                            units: [.init(week: 4, label: "Lehrwoche 4", topic: "Grenzwerte",
                                          files: [.init(id: "f1", name: "VL04.pdf", kind: "vorlesung", minutes: 45),
                                                  .init(id: "f2", name: "Blatt 4.pdf", kind: "uebung", minutes: 60)]),
                                    .init(week: 5, label: "Lehrwoche 5", topic: "",
                                          files: [.init(id: "f3", name: "VL05.pdf", kind: "vorlesung", minutes: 45)])]),
                      .init(id: 8, name: "Physik", priority: 2, examDate: nil,
                            units: [.init(week: 5, label: "Lehrwoche 5", topic: "", files: [.init(id: "p1", name: "Folien Kapitel 5.pdf", kind: "vorlesung", minutes: 45)])])])
    }

    func testPromptCarriesOnlyTitlesWeeksFilesAndTimes() {
        let p = AIStudyPlan.prompt(input)
        for s in ["Heute ist 2026-11-09", "240 Minuten je Lerntag", "2026-11-09 (Montag), Lehrwoche 5, frei: 180 min",
                  "schon geplant: Analysis · Folgen · 45 min", "## Analysis I (Prioritaet 3), Klausur am 2027-02-10",
                  "Lehrwoche 4 (Lehrwoche 4), Thema: Grenzwerte: VL04.pdf [vorlesung, 45 min]; Blatt 4.pdf [uebung, 60 min]",
                  "## Physik (Prioritaet 2)", "Antworte nur mit JSON"] {
            XCTAssertTrue(p.contains(s), s)
        }
        XCTAssertFalse(p.contains("f1") || p.contains("p1"), "keine Kennungen, nur Namen")
        XCTAssertTrue(AIRelayTask.isKnown("study_plan"), "dieselbe Aufgabe beim Dienst (app/ai_relay.py)")
        XCTAssertEqual(AIStudyPlan.schema["required"]?.array?.first?.string, "blocks")
    }

    func testCheckKeepsOnlyValidBlocksAndResolvesFiles() throws {
        let answer: JSONValue = ["blocks": [
            ["date": "2026-11-09", "module": "analysis i", "title": "Grenzwerte nacharbeiten", "minutes": 100, "why": "Klausur naht",
             "tasks": [["type": "vorlesung", "title": "VL 4 lesen", "file": "vl04.pdf", "minutes": 45],
                       ["type": "uebung", "title": "Blatt 4", "file": "Blatt 4.pdf", "minutes": 60],
                       ["type": "uebung", "title": "Erfundenes Blatt", "file": "Blatt 9.pdf", "minutes": 30],
                       ["type": "quatsch", "title": "", "minutes": 10]]],
            ["date": "2026-11-09", "module": "Physik", "title": "Kapitel 5", "minutes": 45,
             "tasks": [["type": "vorlesung", "title": "Folien", "file": "Folien Kapitel 5.pdf", "minutes": 5000]]],
            ["date": "2026-11-12", "module": "Physik", "title": "falscher Tag", "minutes": 45, "tasks": []],
            ["date": "2026-11-10", "module": "Chemie", "title": "unbekanntes Modul", "minutes": 45, "tasks": []],
            ["date": "2026-11-10", "module": "Physik", "title": "Wiederholung", "minutes": 30, "tasks": []],
            // Tagesgrenze: anderthalbfache Lernzeit (360 min), 30 sind schon vergeben
            ["date": "2026-11-10", "module": "Analysis I", "title": "zu viel fuer den Tag", "minutes": 360,
             "tasks": [["type": "frei", "title": "Alles", "minutes": 180], ["type": "frei", "title": "Noch mehr", "minutes": 180]]],
        ]]
        let blocks = AIStudyPlan.check(answer, input: input)
        XCTAssertEqual(blocks.map(\.title), ["Grenzwerte nacharbeiten", "Kapitel 5", "Wiederholung"])
        let a = blocks[0]
        XCTAssertEqual(a.moduleID, 7)
        XCTAssertEqual(a.module, "Analysis I")
        XCTAssertEqual(a.week, 4, "Lehrwoche der Dateien")
        XCTAssertEqual(a.tasks.map(\.fileID), ["f1", "f2", nil], "Dateien nur aus dem Modul, erfundene werden frei")
        XCTAssertEqual(a.tasks.map(\.type), ["vorlesung", "uebung", "frei"])
        XCTAssertEqual(a.minutes, 135, "Summe der Aufgaben")
        XCTAssertEqual(a.why, "Klausur naht")
        XCTAssertEqual(blocks[1].tasks.first?.minutes, AIStudyPlan.taskMinutes.upperBound, "Dauer begrenzt")
        XCTAssertEqual(blocks[2].tasks, [.init(type: "frei", title: "Wiederholung", fileID: nil, fileName: nil, minutes: 30)], "ohne Aufgaben: eine freie")
        XCTAssertEqual(blocks[2].week, 5, "Lehrwoche des Tages")
        // Form fuer "Uebernehmen" und zurueck
        let again = AIStudyPlan.blocks(fromApply: .array(blocks.map(\.json)))
        XCTAssertEqual(again.map(\.moduleID), [7, 8, 8])
        XCTAssertEqual(again[0].tasks.map(\.fileID), ["f1", "f2", nil])
        XCTAssertEqual(AIStudyPlan.blocks(fromApply: ["kaputt"]), [])
        XCTAssertEqual(AIStudyPlan.check(["blocks": "nix"], input: input), [])
    }

    // MARK: Endpunkte

    private func backend() async throws -> LocalBackend {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: .fixed(berlin: "2026-11-09T07:30:00")!)
        try await b.context.database.transaction { c in
            try c.execute("INSERT INTO courses(id, title, semester, subject, kind, created_at) VALUES ('k1', 'Testmathematik I', 'WiSe 2026/27', 'Testmathematik I', 'vorlesung', '2026-10-01T08:00:00')")
            for (id, name, chdate) in [("f-v1", "VL01.pdf", 1_792_000_000), ("f-v2", "VL02.pdf", 1_792_600_000)] {
                try c.execute("INSERT INTO files(id, course_id, name, studip_folder, chdate, status, kind) VALUES (?, 'k1', ?, 'Vorlesung', ?, 'neu', 'pdf')",
                              [.text(id), .text(name), .integer(Int64(chdate))])
            }
        }
        return b
    }

    private func post(_ b: LocalBackend, _ path: String, _ body: JSONValue) async -> LocalResponse {
        await b.handle(LocalRequest(method: "POST", url: URL(string: "uniflow-local://device" + path)!,
                                    headers: ["Content-Type": "application/json"], body: body.serialized()))
    }

    func testSuggestAsksTheAIWithTheStudyPlanTaskAndApplyCreatesPackages() async throws {
        let b = try await backend()
        let none = await post(b, "/api/calendar/ai-suggest", ["start": "2026-11-09", "days": 7])
        XCTAssertEqual(none.status, 404, "ohne KI")
        let ai = FakeAI("")
        b.context.ai.setKey(ai)
        // Modul und Dateinamen erst aus der Datenbank kennen: ein Durchlauf ohne Antwort zeigt den Prompt
        ai.reply = "{}"
        let empty = await post(b, "/api/calendar/ai-suggest", ["start": "2026-11-09", "days": 7])
        XCTAssertEqual(empty.status, 502, String(decoding: empty.body, as: UTF8.self))
        let prompt = try XCTUnwrap(ai.prompts.last)
        XCTAssertEqual(prompt.system, AIPromptTexts.system)
        XCTAssertTrue(prompt.prompt.contains("## Testmathematik I"), prompt.prompt)
        XCTAssertTrue(prompt.prompt.contains("VL01.pdf [vorlesung, 45 min]"), prompt.prompt)
        XCTAssertTrue(prompt.prompt.contains("- 2026-11-09 (Montag)"), prompt.prompt)
        XCTAssertFalse(prompt.prompt.contains("k1") || prompt.prompt.contains("f-v1"), "keine Kennungen")
        ai.reply = """
        ```json
        {"blocks": [{"date": "2026-11-09", "module": "Testmathematik I", "title": "Einstieg", "minutes": 90, "why": "Start",
                     "tasks": [{"type": "vorlesung", "title": "VL 1 durcharbeiten", "file": "VL01.pdf", "minutes": 45},
                               {"type": "wiederholung", "title": "Begriffe wiederholen", "file": null, "minutes": 20}]},
                    {"date": "2026-11-11", "module": "Testmathematik I", "title": "Weiter", "minutes": 45,
                     "tasks": [{"type": "vorlesung", "title": "VL 2", "file": "VL02.pdf", "minutes": 45}]}]}
        ```
        """
        let r = await post(b, "/api/calendar/ai-suggest", ["start": "2026-11-09", "days": 7])
        XCTAssertEqual(r.status, 200, String(decoding: r.body, as: UTF8.self))
        let blocks = try XCTUnwrap(r.json?["blocks"]?.array)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0]["tasks"]?.array?.first?["file_id"]?.string, "f-v1")
        XCTAssertEqual(blocks[0]["minutes"]?.double, 65)
        XCTAssertEqual(r.json?["message"]?.string, "2 Lernblöcke vorgeschlagen")
        // noch nichts eingetragen
        let before = try await b.context.database.rows("SELECT COUNT(*) n FROM study_packages")
        XCTAssertEqual(before.first?["n"]?.int, 0, "Vorschlag traegt nichts ein")
        // der Nutzer uebernimmt nur den ersten Block
        let applied = await post(b, "/api/calendar/ai-apply", ["blocks": .array([blocks[0]])])
        XCTAssertEqual(applied.status, 200, String(decoding: applied.body, as: UTF8.self))
        XCTAssertEqual(applied.json?["created"]?.double, 1)
        XCTAssertEqual(applied.json?["message"]?.string, "1 Lernblock übernommen")
        let pk = try await b.context.database.rows("SELECT * FROM study_packages ORDER BY id")
        XCTAssertEqual(pk.count, 1)
        XCTAssertEqual(pk[0]["date"]?.string, "2026-11-09")
        XCTAssertEqual(pk[0]["title"]?.string, "Einstieg")
        XCTAssertEqual(pk[0]["subject"]?.string, "Testmathematik I")
        XCTAssertEqual(pk[0]["planned_minutes"]?.int, 65)
        XCTAssertEqual(pk[0]["generated"]?.int, 1)
        XCTAssertNotNil(pk[0]["start_time"]?.string, "Zeitslot im freien Fenster")
        let tasks = try await b.context.database.rows("SELECT type, file_id, title, est_minutes FROM study_tasks ORDER BY sort")
        XCTAssertEqual(tasks.map { $0["type"]?.string }, ["vorlesung", "wiederholung"])
        XCTAssertEqual(tasks[0]["file_id"]?.string, "f-v1")
        XCTAssertEqual(tasks[1]["file_id"], .null)
        // Ohne Bloecke 400; Blocke in der Vergangenheit oder zu fremden Modulen werden uebergangen
        let noBlocks = await post(b, "/api/calendar/ai-apply", ["blocks": []])
        XCTAssertEqual(noBlocks.status, 400)
        let past = await post(b, "/api/calendar/ai-apply", ["blocks": [["date": "2026-11-01", "module_id": 1, "title": "alt", "tasks": [["type": "frei", "title": "x", "minutes": 30]]],
                                                                       ["date": "2026-11-12", "module_id": 999, "title": "fremd", "tasks": [["type": "frei", "title": "x", "minutes": 30]]]]])
        XCTAssertEqual(past.json?["created"]?.double, 0)
    }

    func testSuggestWithoutOpenMaterialReturnsNothingToPlan() async throws {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: .fixed(berlin: "2026-11-09T07:30:00")!)
        let ai = FakeAI("{}")
        b.context.ai.setKey(ai)
        let r = await post(b, "/api/calendar/ai-suggest", [:])
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.json?["blocks"]?.array?.count, 0)
        XCTAssertEqual(r.json?["message"]?.string, "Keine offenen Vorlesungen oder Übungen für die Planung.")
        XCTAssertTrue(ai.prompts.isEmpty, "ohne Stoff keine Anfrage")
        // KI-Fehler kommen mit Code durch
        let b2 = try await backend()
        let failing = FakeAI("")
        failing.failure = AIError("openai_quota", "Guthaben leer")
        b2.context.ai.setKey(failing)
        let e = await post(b2, "/api/calendar/ai-suggest", [:])
        XCTAssertEqual(e.status, 429)
        XCTAssertEqual(e.json?["detail"]?["code"]?.string ?? e.json?["code"]?.string, "openai_quota")
    }
}
