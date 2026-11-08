import Foundation
import XCTest
@testable import UniFlowCore

// Entscheidung des Inhabers vom 08.11.2026: Der Lernplan wird nach einem Abgleich nicht mehr neu geplant. Nur neue
// Dokumente kommen dazu, in freie Luecken vor der passenden Klausur und nicht vor ihrer Lehrwoche; alles, was schon im
// Plan steht (verschoben, nachgeholt, erledigt, eigene Pakete), bleibt Zeile fuer Zeile gleich. Seed aus
// study-plan.json (Vorlesungsbeginn 12.10.2026, Testmathematik I mit Klausur 20.11., Samstag frei, 4 Stunden am Tag).

private func seedFixture() throws -> JSONValue {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return try JSONValue.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/local-backend/study-plan.json")))
}

private final class PlanNow: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ local: String) { date = UniFlowClock.fixed(berlin: local)!.now }
    func set(_ local: String) { lock.withLock { date = UniFlowClock.fixed(berlin: local)!.now } }
    var clock: UniFlowClock { UniFlowClock { [self] in lock.withLock { date } } }
}

final class LernplanEinordnenTests: XCTestCase {

    // MARK: Hilfen

    private func backend(_ now: PlanNow) async throws -> LocalBackend {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: now.clock)
        let fx = try seedFixture()
        try await b.context.database.transaction { c in
            for s in fx["seed"]?.array ?? [] { try c.execute(s["sql"]?.string ?? "", (s["params"]?.array ?? []).map { SQLiteValue(json: $0) ?? .null }) }
            try c.execute("DELETE FROM study_tasks")
            try c.execute("DELETE FROM study_packages")
            try c.execute("UPDATE files SET status='neu' WHERE status='erledigt'")
        }
        await send(b, "PUT", "/api/settings", ["auto_plan": true])
        return b
    }

    @discardableResult
    private func send(_ b: LocalBackend, _ method: String, _ path: String, _ body: JSONValue? = nil,
                      file: StaticString = #filePath, line: UInt = #line) async -> JSONValue {
        let r = await b.handle(LocalRequest(method: method, path: path, body: body.map { $0.serialized() } ?? Data()))
        XCTAssertEqual(r.status, 200, "\(method) \(path): \(String(data: r.body, encoding: .utf8) ?? "")", file: file, line: line)
        return r.json ?? .null
    }

    private func addFiles(_ b: LocalBackend, course: String, _ rows: [(id: String, name: String, folder: String, local: String)]) async throws {
        try await b.context.database.transaction { c in
            _ = try UniStore.storeFiles(c, courseID: course, rows.map { r in
                UniStore.FileRow(id: r.id, name: r.name, size: 1000, mime: "application/pdf", chdate: BerlinClock.utcSeconds(localISO: r.local),
                                 downloadURL: "https://example.invalid/\(r.id)", folder: r.folder)
            }, now: "2026-10-26T08:00:00", fileExists: { _ in true })
        }
    }

    /// Alle Zeilen von study_packages und study_tasks, je Tabelle nach ID
    private func snapshot(_ b: LocalBackend) async throws -> (packages: [Int: [String: JSONValue]], tasks: [Int: [String: JSONValue]]) {
        try await b.context.database.withConnection { c in
            var p: [Int: [String: JSONValue]] = [:], t: [Int: [String: JSONValue]] = [:]
            for r in try c.rows("SELECT * FROM study_packages") { p[r["id"]?.int ?? -1] = r }
            for r in try c.rows("SELECT * FROM study_tasks") { t[r["id"]?.int ?? -1] = r }
            return (p, t)
        }
    }

    private func newTasks(_ b: LocalBackend, after before: [Int: [String: JSONValue]]) async throws -> [[String: JSONValue]] {
        try await b.context.database.withConnection { c in
            try c.rows("SELECT t.*, p.date, p.week_no, p.start_time AS p_start FROM study_tasks t JOIN study_packages p ON p.id=t.package_id ORDER BY t.id")
        }.filter { before[$0["id"]?.int ?? -1] == nil }
    }

    private func assertUnchanged(_ before: (packages: [Int: [String: JSONValue]], tasks: [Int: [String: JSONValue]]),
                                 _ after: (packages: [Int: [String: JSONValue]], tasks: [Int: [String: JSONValue]]),
                                 file: StaticString = #filePath, line: UInt = #line) {
        for (id, row) in before.packages {
            XCTAssertEqual(after.packages[id], row, "Paket \(id) veraendert oder weg", file: file, line: line)
        }
        for (id, row) in before.tasks {
            XCTAssertEqual(after.tasks[id], row, "Aufgabe \(id) veraendert oder weg", file: file, line: line)
        }
    }

    private func lectureWeek(_ b: LocalBackend, _ day: String, now: PlanNow) async throws -> Int {
        try await b.context.database.withConnection { c in
            let start = try LocalModules.Dates(c, clock: now.clock).start
            return StudyWeeks.dayWeek(start: start, day: BerlinClock.parseISODate(day)!, today: BerlinClock.parseISODate(now.clock.today)!)
        }
    }

    // MARK: (a) Bestehender Plan bleibt, nur neue Dokumente kommen dazu

    func testNewDocumentsJoinWithoutTouchingMovedDoneAndOwnEntries() async throws {
        let now = PlanNow("2026-10-26T07:30:00")                          // Montag, Lehrwoche 3
        let b = try await backend(now)
        try await addFiles(b, course: "k-ma-vl", [("n-ma-v3", "VL03 Reihen.pdf", "Vorlesung", "2026-10-26T06:00:00")])
        try await addFiles(b, course: "k-ma-ue", [("n-ma-u3", "Blatt 3.pdf", "Übungsblätter", "2026-10-26T06:30:00")])
        let gen = await send(b, "POST", "/api/calendar/generate", ["start": "2026-10-26", "days": 7])
        XCTAssertGreaterThan(gen["created"]?.int ?? 0, 0, "\(gen)")
        // erster Lauf mit bestehendem Plan: nur merken, nichts planen
        let first = try await StudyAutoPlan.afterSync(b, newFiles: 2)
        XCTAssertNil(first, "\(String(describing: first))")
        // der Nutzer arbeitet am Plan: erledigt, verschoben (anderer Tag, eigene Uhrzeit), eigenes Paket
        let initial = try await snapshot(b)
        let firstTasks = initial.tasks.values.sorted { ($0["id"]?.int ?? 0) < ($1["id"]?.int ?? 0) }
        let done = try XCTUnwrap(firstTasks.first?["id"]?.int)
        await send(b, "POST", "/api/tasks/\(done)/status", ["status": "erledigt"])
        let movedPkg = try XCTUnwrap(initial.packages.keys.sorted().last)
        await send(b, "PATCH", "/api/packages/\(movedPkg)", ["date": "2026-10-30", "start_time": "15:00"])
        await send(b, "POST", "/api/packages", ["date": "2026-10-28", "title": "Eigenes Lesen", "minutes": 30])
        // Abend: der Abgleich bringt zwei neue Dokumente (Testphysik, Lehrwoche 3)
        now.set("2026-10-26T18:00:00")
        let before = try await snapshot(b)
        try await addFiles(b, course: "k-ph", [("n-ph-v3", "Folien Kapitel 3.pdf", "Vorlesung", "2026-10-26T12:00:00"),
                                                ("n-ph-u3", "Übungsblatt 3.pdf", "Übungen", "2026-10-26T13:00:00")])
        let r = try await StudyAutoPlan.afterSync(b, newFiles: 2)
        XCTAssertEqual(r?["created"]?.int, 2, "\(String(describing: r))")
        let after = try await snapshot(b)
        assertUnchanged(before, after)
        XCTAssertEqual(after.packages.count, before.packages.count + 2)
        XCTAssertEqual(after.tasks.count, before.tasks.count + 2)
        let added = try await newTasks(b, after: before.tasks)
        XCTAssertEqual(Set(added.compactMap { $0["file_id"]?.string }), ["n-ph-v3", "n-ph-u3"])
        for t in added {
            XCTAssertGreaterThan(t["date"]?.string ?? "", "2026-10-26", "nicht heute und nicht in die Vergangenheit: \(t)")
            XCTAssertEqual(t["week_no"]?.int, 3)
            XCTAssertNotNil(t["p_start"]?.string, "neues Paket ohne Uhrzeit: \(t)")
        }
        // die beiden neuen Pakete ueberlappen keinen bestehenden Lernblock
        let rows = try await b.context.database.withConnection { c in
            try c.rows("SELECT id, date, start_time, end_time FROM study_packages WHERE start_time IS NOT NULL AND status NOT IN ('verschoben','uebersprungen')")
        }
        let newPkgIDs = Set(added.compactMap { $0["package_id"]?.int })
        for n in rows where newPkgIDs.contains(n["id"]?.int ?? -1) {
            for o in rows where o["id"] != n["id"] && o["date"] == n["date"] {
                let ns = n["start_time"]?.string ?? "", ne = n["end_time"]?.string ?? "", os = o["start_time"]?.string ?? "", oe = o["end_time"]?.string ?? ""
                XCTAssertFalse(ns < oe && ne > os, "Paket \(n) ueberlappt \(o)")
            }
        }
    }

    // MARK: (b) Ohne neue Dokumente bleibt der Plan gleich, auch nach Tageswechsel und neuer Woche

    func testNoNewDocumentsKeepsPlanIdenticalAcrossDays() async throws {
        let now = PlanNow("2026-10-26T07:30:00")
        let b = try await backend(now)
        try await addFiles(b, course: "k-ma-vl", [("n-ma-v3", "VL03 Reihen.pdf", "Vorlesung", "2026-10-26T06:00:00")])
        // erster Abgleich nach der Einrichtung, noch kein Plan: die laufende Woche wie bisher
        let first = try await StudyAutoPlan.afterSync(b, newFiles: 1)
        XCTAssertGreaterThan(first?["created"]?.int ?? 0, 0, "\(String(describing: first))")
        let before = try await snapshot(b)
        XCTAssertFalse(before.packages.isEmpty)
        for t in ["2026-10-26T18:00:00", "2026-10-27T07:00:00", "2026-10-29T12:00:00", "2026-11-02T08:00:00", "2026-11-03T08:00:00"] {
            now.set(t)
            let r = try await StudyAutoPlan.afterSync(b, newFiles: 0)
            XCTAssertNil(r, "\(t): \(String(describing: r))")
            let c = try await StudyAutoPlan.catchUp(b)                   // Oeffnen der App
            XCTAssertNil(c, "\(t): \(String(describing: c))")
            let after = try await snapshot(b)
            XCTAssertEqual(after.packages, before.packages, "\(t): Pakete geaendert")
            XCTAssertEqual(after.tasks, before.tasks, "\(t): Aufgaben geaendert")
        }
    }

    // MARK: (c) Dasselbe Dokument zweimal gemeldet: einmal eingeordnet

    func testSameDocumentReportedTwiceIsPlacedOnce() async throws {
        let now = PlanNow("2026-10-26T07:30:00")
        let b = try await backend(now)
        await send(b, "POST", "/api/packages", ["date": "2026-10-27", "title": "Eigenes", "minutes": 30])
        _ = try await StudyAutoPlan.afterSync(b, newFiles: 0)            // vorhandene Dateien merken
        let base = try await snapshot(b)
        let file: [(id: String, name: String, folder: String, local: String)] = [("n-ph-v3", "Folien Kapitel 3.pdf", "Vorlesung", "2026-10-26T12:00:00")]
        try await addFiles(b, course: "k-ph", file)
        let r1 = try await StudyAutoPlan.afterSync(b, newFiles: 1)
        XCTAssertEqual(r1?["created"]?.int, 1)
        // derselbe Abgleich meldet die Datei noch einmal, der Hintergrundabgleich auch, dann das Oeffnen der App
        try await addFiles(b, course: "k-ph", file)
        let r2 = try await StudyAutoPlan.afterSync(b, newFiles: 1)
        XCTAssertNil(r2)
        let r3 = try await StudyAutoPlan.catchUp(b)
        XCTAssertNil(r3)
        let added = try await newTasks(b, after: base.tasks)
        XCTAssertEqual(added.compactMap { $0["file_id"]?.string }, ["n-ph-v3"])
    }

    // MARK: (d) In freie Luecken vor der Klausur, nicht vor der Lehrwoche, nie in die Vergangenheit

    func testNewDocumentsGoIntoFreeGapsBeforeExamAndNotIntoThePast() async throws {
        let now = PlanNow("2026-10-28T09:00:00")                          // Mittwoch, Lehrwoche 3
        let b = try await backend(now)
        try await b.context.database.transaction { c in
            try c.execute("UPDATE modules SET exam_date='2026-11-04' WHERE name='Testmathematik I'")
        }
        // Montag 2.11. (Beginn Lehrwoche 4) schon voll verplant: 4 Stunden eigenes Paket
        await send(b, "POST", "/api/packages", ["date": "2026-11-02", "title": "Voll", "minutes": 240])
        _ = try await StudyAutoPlan.afterSync(b, newFiles: 0)
        let base = try await snapshot(b)
        // VL04 schon jetzt hochgeladen (Lehrwoche 4 laut Name), ein Blatt der Lehrwoche 2 erst jetzt synchronisiert
        try await addFiles(b, course: "k-ma-vl", [("n-ma-v4", "VL04 Integrale.pdf", "Vorlesung", "2026-10-28T08:00:00")])
        try await addFiles(b, course: "k-ph", [("n-ph-u2b", "Zusatzblatt 2.pdf", "Übungen", "2026-10-21T08:00:00")])
        let r = try await StudyAutoPlan.afterSync(b, newFiles: 2)
        XCTAssertEqual(r?["created"]?.int, 2, "\(String(describing: r))")
        let added = try await newTasks(b, after: base.tasks)
        let v4 = try XCTUnwrap(added.first { $0["file_id"] == "n-ma-v4" })
        // nicht vor Lehrwoche 4, vor der Klausur am 4.11., nicht am vollen Montag: Dienstag 3.11.
        XCTAssertEqual(v4["date"], "2026-11-03", "\(v4)")
        let lw = try await lectureWeek(b, v4["date"]?.string ?? "", now: now)
        XCTAssertGreaterThanOrEqual(lw, 4)
        let u2 = try XCTUnwrap(added.first { $0["file_id"] == "n-ph-u2b" })
        // Stoff einer vergangenen Woche: ab morgen, nicht in Lehrwoche 2
        XCTAssertEqual(u2["date"], "2026-10-29", "\(u2)")
        assertUnchanged(base, try await snapshot(b))
        // Klausur vorbei, bevor die Lehrwoche beginnt: kein Platz, nichts eingeplant (bleibt fuer die Hand)
        try await b.context.database.transaction { c in
            try c.execute("UPDATE modules SET exam_date='2026-10-31' WHERE name='Testmathematik I'")
        }
        let before = try await snapshot(b)
        try await addFiles(b, course: "k-ma-vl", [("n-ma-v5", "VL05 Reihen II.pdf", "Vorlesung", "2026-10-28T08:30:00")])
        let none = try await StudyAutoPlan.afterSync(b, newFiles: 1)
        XCTAssertNil(none, "\(String(describing: none))")
        let after = try await snapshot(b)
        XCTAssertEqual(after.packages, before.packages)
        XCTAssertEqual(after.tasks, before.tasks)
    }

    // MARK: Tarif ohne automatischen Lernplan und auto_plan aus

    /// Ohne Erlaubnis wird nichts geplant, aber gemerkt: spaeter eingeschaltet kommt nur, was danach neu ist
    @MainActor
    func testWithoutAutoPlanFilesAreRememberedNotPlanned() async throws {
        let now = PlanNow("2026-10-26T07:30:00")
        let b = try await backend(now)
        await send(b, "POST", "/api/packages", ["date": "2026-10-27", "title": "Eigenes", "minutes": 30])
        StudyAutoPlan.allowed = { false }
        defer { StudyAutoPlan.allowed = { true } }
        try await addFiles(b, course: "k-ph", [("n-ph-v3", "Folien Kapitel 3.pdf", "Vorlesung", "2026-10-26T12:00:00")])
        let base = try await snapshot(b)
        let off = try await StudyAutoPlan.afterSync(b, newFiles: 1)
        XCTAssertNil(off)
        StudyAutoPlan.allowed = { true }
        let on = try await StudyAutoPlan.afterSync(b, newFiles: 0)
        XCTAssertNil(on, "Datei aus der Zeit ohne Tarif nicht nachtraeglich eingeplant")
        let after = try await snapshot(b)
        XCTAssertEqual(after.packages, base.packages)
        XCTAssertEqual(after.tasks, base.tasks)
    }
}
