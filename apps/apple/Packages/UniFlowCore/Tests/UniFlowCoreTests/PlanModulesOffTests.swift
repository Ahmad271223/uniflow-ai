import Foundation
import XCTest
@testable import UniFlowCore

// Fehlerbericht des Inhabers (13.11.2026, Build 37): "Mathe 1" in "Was soll in den Lernkalender?" abgewaehlt, trotzdem
// eingeplant. Ein abgewaehltes Fach bekommt NIE Lernpakete, Lernbloecke oder Lernziel-Vorschlaege – auf keinem Weg:
// Stundenplaner (Lernziele), alter Lernplan, neue Dateien, KI-Lernplan uebernehmen, Nachholen/Woche retten,
// Pakete eines anderen Geraets nach dem Abgleich. Schon vorhandene automatische Pakete verschwinden beim Abwaehlen;
// selbst angelegte, gesperrte oder geaenderte nur nach Rueckfrage (`remove_own`). Wieder angehakt: plant normal.

private func repo() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return url
}

final class PlanModulesOffTests: XCTestCase {
    @discardableResult
    private func send(_ b: LocalBackend, _ method: String, _ path: String, _ body: JSONValue? = nil, status: Int = 200,
                      file: StaticString = #filePath, line: UInt = #line) async -> JSONValue {
        let r = await b.handle(LocalRequest(method: method, url: URL(string: "uniflow-local://device" + path)!, body: body.map { $0.serialized() } ?? Data()))
        XCTAssertEqual(r.status, status, "\(method) \(path): \(String(data: r.body, encoding: .utf8) ?? "")", file: file, line: line)
        return r.json ?? .null
    }

    private func rows(_ b: LocalBackend, _ q: String, _ p: [SQLiteValue] = []) async throws -> [[String: JSONValue]] {
        try await b.context.database.withConnection { try $0.rows(q, p) }
    }

    private func sql(_ b: LocalBackend, _ q: String, _ p: [SQLiteValue] = []) async throws {
        try await b.context.database.transaction { try $0.execute(q, p) }
    }

    private func count(_ b: LocalBackend, module: Int) async throws -> Int {
        try await rows(b, "SELECT id FROM study_packages WHERE module_id=?", [.integer(Int64(module))]).count
    }

    private func deselect(_ b: LocalBackend, _ name: String, planned: Bool = false) async -> JSONValue {
        await send(b, "POST", "/api/calendar/modules", ["modules": [["name": .string(name), "planned": .bool(planned)]]])
    }

    // MARK: Stundenplaner (Lernziele)

    func testSmartPlannerNeverPlansADeselectedModule() async throws {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: UniFlowClock.fixed(berlin: "2026-11-16T08:00:00")!)
        var ids: [Int] = []
        for (i, (name, weeks)) in [("Mathe 1", 10), ("Programmieren", 12)].enumerated() {
            let exam = BerlinClock.isoDate(BerlinClock.parseISODate("2026-11-16")! + 7 * weeks)
            ids.append(try await b.context.database.transaction { c in
                try c.execute("INSERT INTO modules(name, color, sort, exam_date, created_at) VALUES (?, '#336699', ?, ?, '2026-10-01T09:00:00')",
                              [.text(name), .integer(Int64(i)), .text(exam)])
                return Int(c.lastInsertRowID)
            })
        }
        let (math, prog) = (ids[0], ids[1])
        for id in ids { await send(b, "PUT", "/api/goals/\(id)", ["target_hours": 60]) }
        await send(b, "POST", "/api/goals/plan", [:])
        let mathBlocks = try await rows(b, "SELECT id FROM study_packages WHERE source='smart' AND module_id=? ORDER BY date", [.integer(Int64(math))])
        XCTAssertGreaterThan(mathBlocks.count, 2, "vor der Abwahl geplant")
        let locked = try XCTUnwrap(mathBlocks.last?["id"]?.int)
        await send(b, "PATCH", "/api/goals/blocks/\(locked)", ["locked": true])

        // Abwaehlen: automatische Bloecke sofort weg, der gesperrte bleibt (Rueckfrage: kept = 1)
        let saved = await deselect(b, "Mathe 1")
        XCTAssertEqual(saved["kept"]?.int, 1, "\(saved)")
        let left = try await rows(b, "SELECT id FROM study_packages WHERE module_id=?", [.integer(Int64(math))])
        XCTAssertEqual(left.compactMap { $0["id"]?.int }, [locked], "nur der gesperrte Block bleibt")

        // Uebersicht: kein Ziel, kein Vorschlag, nicht unter "Module ohne Ziel"; Ziel setzen geht nicht
        let o = await send(b, "GET", "/api/goals")
        XCTAssertFalse((o["modules"]?.array ?? []).contains { $0["module_id"]?.int == math }, "\(o["modules"] ?? .null)")
        XCTAssertFalse((o["modules_without_goal"]?.array ?? []).contains { $0["module_id"]?.int == math })
        XCTAssertTrue((o["modules"]?.array ?? []).contains { $0["module_id"]?.int == prog })
        await send(b, "PUT", "/api/goals/\(math)", ["target_hours": 80], status: 409)
        await send(b, "POST", "/api/goals/plan", [:])
        await send(b, "GET", "/api/goals")
        let after = try await count(b, module: math)
        XCTAssertEqual(after, 1, "Neu planen legt nichts fuer das abgewaehlte Fach an")
        let progCount = try await count(b, module: prog)
        XCTAssertGreaterThan(progCount, 0, "andere Faecher bleiben geplant")

        // Nach Rueckfrage auch den gesperrten entfernen
        let own = await send(b, "POST", "/api/calendar/modules", ["remove_own": true])
        XCTAssertEqual(own["kept"]?.int, 0)
        let gone = try await count(b, module: math)
        XCTAssertEqual(gone, 0)

        // Wieder anhaken: das alte Ziel gilt wieder, es wird normal geplant
        _ = await deselect(b, "Mathe 1", planned: true)
        let back = await send(b, "GET", "/api/goals")
        XCTAssertTrue((back["modules"]?.array ?? []).contains { $0["module_id"]?.int == math })
        await send(b, "POST", "/api/goals/plan", [:])
        let replanned = try await count(b, module: math)
        XCTAssertGreaterThan(replanned, 0)
    }

    // MARK: Alter Lernplan, neue Dateien, KI-Plan, Nachholen, Abgleich

    private let clock = UniFlowClock.fixed(berlin: "2026-10-26T07:30:00")!

    private func seeded() async throws -> LocalBackend {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let fx = try JSONValue.parse(Data(contentsOf: repo().appendingPathComponent("packages/shared-contracts/fixtures/local-backend/study-plan.json")))
        try await b.context.database.transaction { c in
            for s in fx["seed"]?.array ?? [] { try c.execute(s["sql"]?.string ?? "", (s["params"]?.array ?? []).map { SQLiteValue(json: $0) ?? .null }) }
            try c.execute("DELETE FROM study_tasks")
            try c.execute("DELETE FROM study_packages")
            try c.execute("UPDATE files SET status='neu' WHERE status='erledigt'")
            for (course, id, name, folder) in [("k-ma-vl", "n-ma-v3", "VL03 Reihen.pdf", "Vorlesung"), ("k-ma-ue", "n-ma-u3", "Blatt 3.pdf", "Übungsblätter"),
                                               ("k-ph", "n-ph-v3", "Folien Kapitel 3.pdf", "Vorlesung"), ("k-ph", "n-ph-u3", "Übungsblatt 3.pdf", "Übungen")] {
                _ = try UniStore.storeFiles(c, courseID: course, [UniStore.FileRow(
                    id: id, name: name, size: 1000, mime: "application/pdf", chdate: BerlinClock.utcSeconds(localISO: "2026-10-26T06:00:00"),
                    downloadURL: "https://example.invalid/\(id)", folder: folder)], now: "2026-10-26T08:00:00", fileExists: { _ in true })
            }
        }
        return b
    }

    private func moduleID(_ b: LocalBackend, _ name: String) async throws -> Int {
        let found = try await rows(b, "SELECT id FROM modules WHERE name=?", [.text(name)])
        return try XCTUnwrap(found.first?["id"]?.int)
    }

    func testEveryOtherPlanningPathSkipsADeselectedModule() async throws {
        let b = try await seeded()
        await send(b, "POST", "/api/calendar/generate", ["start": "2026-10-26", "days": 7])
        let math = try await moduleID(b, "Testmathematik I")
        let phys = try await moduleID(b, "Testphysik")
        let before = try await count(b, module: math)
        XCTAssertGreaterThan(before, 0, "vor der Abwahl geplant")

        // eigenes Paket (selbst angelegt, generated=0) mit nachzuholender Aufgabe von letzter Woche
        try await sql(b, """
            INSERT INTO study_packages(date, module_id, subject, title, planned_minutes, status, sort, generated, created_at)
            VALUES ('2026-10-20', ?, 'Testmathematik I', 'Eigenes Paket', 30, 'geplant', 0, 0, '2026-10-19T09:00:00')
            """, [.integer(Int64(math))])
        let own = try await rows(b, "SELECT id FROM study_packages WHERE title='Eigenes Paket'")[0]["id"]?.int ?? 0
        try await sql(b, "INSERT INTO study_tasks(package_id, type, title, sort, est_minutes, status, created_at) VALUES (?, 'frei', 'Altes Blatt', 0, 30, 'nachholen', '2026-10-19T09:00:00')",
                      [.integer(Int64(own))])

        // Abwaehlen entfernt die automatischen Pakete sofort (ohne neu zu planen); das eigene bleibt und wird gemeldet
        let saved = await deselect(b, "Testmathematik I")
        let auto = try await rows(b, "SELECT id FROM study_packages WHERE module_id=? AND generated=1", [.integer(Int64(math))])
        XCTAssertTrue(auto.isEmpty, "automatische Pakete weg: \(auto)")
        XCTAssertEqual(saved["kept"]?.int, 0, "das eigene Paket liegt in der Vergangenheit: \(saved)")
        let ownLeft = try await count(b, module: math)
        XCTAssertEqual(ownLeft, 1, "selbst angelegtes Paket wird nie still geloescht")

        // Lernplan neu erstellen (ohne vorher aufzuraeumen), neue Dateien einordnen
        await send(b, "POST", "/api/calendar/generate", ["start": "2026-10-26", "days": 7])
        try await b.context.database.transaction { c in
            _ = try UniStore.storeFiles(c, courseID: "k-ma-vl", [UniStore.FileRow(
                id: "n-ma-v4", name: "VL04 Potenzreihen.pdf", size: 1000, mime: "application/pdf", chdate: BerlinClock.utcSeconds(localISO: "2026-10-26T07:00:00"),
                downloadURL: "https://example.invalid/n-ma-v4", folder: "Vorlesung")], now: "2026-10-26T07:10:00", fileExists: { _ in true })
        }
        _ = try await StudyAutoPlan.afterSync(b, newFiles: 1)
        let afterPlans = try await count(b, module: math)
        XCTAssertEqual(afterPlans, 1, "kein Paket aus Lernplan oder neuen Dateien")
        let physCount = try await count(b, module: phys)
        XCTAssertGreaterThan(physCount, 0, "andere Faecher werden weiter geplant")

        // KI-Lernplan uebernehmen: ein Block fuer das abgewaehlte Fach wird nicht angelegt
        await send(b, "POST", "/api/calendar/ai-apply", ["blocks": [
            ["date": "2026-10-28", "module_id": .number(Double(math)), "module": "Testmathematik I", "title": "Reihen",
             "tasks": [["type": "frei", "title": "Reihen wiederholen", "minutes": 30]]],
            ["date": "2026-10-28", "module_id": .number(Double(phys)), "module": "Testphysik", "title": "Kapitel 3",
             "tasks": [["type": "frei", "title": "Kapitel 3 lesen", "minutes": 30]]]]])
        let afterAI = try await count(b, module: math)
        XCTAssertEqual(afterAI, 1, "KI-Block fuer das abgewaehlte Fach nicht uebernommen")

        // Woche retten / Nachholen: die nachzuholende Aufgabe des abgewaehlten Fachs wird nicht neu verteilt
        let rescue = await send(b, "POST", "/api/calendar/suggest", ["rescue": true])
        XCTAssertFalse((rescue["moves"]?.array ?? []).contains { $0["module_id"]?.int == math }, "\(rescue)")

        // Ein anderes Geraet hat vor der Abwahl ein automatisches Paket angelegt (kommt per Abgleich): beim naechsten
        // Abgleich bzw. Planen ist es weg
        try await sql(b, """
            INSERT INTO study_packages(date, module_id, subject, title, planned_minutes, status, sort, generated, created_at)
            VALUES ('2026-10-29', ?, 'Testmathematik I', 'Vom Mac', 45, 'geplant', 0, 1, '2026-10-26T06:00:00')
            """, [.integer(Int64(math))])
        _ = try await StudyAutoPlan.afterSync(b, newFiles: 0)
        let synced = try await rows(b, "SELECT id FROM study_packages WHERE title='Vom Mac'")
        XCTAssertTrue(synced.isEmpty, "Paket eines anderen Geraets entfernt")

        // Umbenennen behaelt die Abwahl; wieder anhaken plant normal
        await send(b, "PATCH", "/api/modules/\(math)", ["name": "Mathe 1"])
        await send(b, "POST", "/api/calendar/generate", ["start": "2026-10-26", "days": 7])
        let renamed = try await count(b, module: math)
        XCTAssertEqual(renamed, 1, "umbenannt bleibt abgewaehlt")
        _ = await deselect(b, "Mathe 1", planned: true)
        await send(b, "POST", "/api/calendar/generate", ["start": "2026-10-26", "days": 7])
        let back = try await count(b, module: math)
        XCTAssertGreaterThan(back, 1, "wieder angehakt: wird geplant")
    }
}
