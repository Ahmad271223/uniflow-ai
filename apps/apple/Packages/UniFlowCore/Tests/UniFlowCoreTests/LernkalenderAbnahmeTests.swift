import Foundation
import XCTest
@testable import UniFlowCore

// Abnahme Lernkalender 1.0 (07.11.2026): wirkliche Ablaeufe mit erfundenen Daten (Seed aus study-plan.json, dazu
// eigene Dateien und Termine) und einer Uhr, die der Test vorstellt. Prueft keine Python-Gleichheit (das tut
// LocalStudyPlanTests), sondern Eigenschaften, die immer gelten muessen: kein Lernblock in einem Termin oder einer
// Sperrzeit, nichts geht verloren, nichts doppelt, erledigt bleibt erledigt, nur Stoff der Lehrwoche.

private func studyFixture() throws -> JSONValue {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return try JSONValue.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/local-backend/study-plan.json")))
}

private final class TestNow: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ local: String) { date = UniFlowClock.fixed(berlin: local)!.now }
    func set(_ local: String) { lock.withLock { date = UniFlowClock.fixed(berlin: local)!.now } }
    var clock: UniFlowClock { UniFlowClock { [self] in lock.withLock { date } } }
}

final class LernkalenderAbnahmeTests: XCTestCase {

    // MARK: Hilfen

    private func backend(_ now: TestNow, seed: Bool = true) async throws -> LocalBackend {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: now.clock)
        guard seed else { return b }
        let fx = try studyFixture()
        try await b.context.database.transaction { c in
            for s in fx["seed"]?.array ?? [] { try c.execute(s["sql"]?.string ?? "", (s["params"]?.array ?? []).map { SQLiteValue(json: $0) ?? .null }) }
            // die vergangenen Pakete des Seeds weg: jeder Test baut seinen Plan selbst
            try c.execute("DELETE FROM study_tasks")
            try c.execute("DELETE FROM study_packages")
            try c.execute("UPDATE files SET status='neu' WHERE status='erledigt'")
        }
        return b
    }

    @discardableResult
    private func send(_ b: LocalBackend, _ method: String, _ path: String, _ body: JSONValue? = nil,
                      query: [LocalRequest.QueryItem] = [], file: StaticString = #filePath, line: UInt = #line) async -> JSONValue {
        let r = await b.handle(LocalRequest(method: method, path: path, query: query, body: body.map { $0.serialized() } ?? Data()))
        XCTAssertEqual(r.status, 200, "\(method) \(path): \(String(data: r.body, encoding: .utf8) ?? "")", file: file, line: line)
        return r.json ?? .null
    }

    private func tasks(_ b: LocalBackend) async throws -> [[String: JSONValue]] {
        try await b.context.database.withConnection { c in
            try c.rows("SELECT t.*, p.date, p.week_no, p.module_id, p.generated, p.start_time AS p_start, p.end_time AS p_end FROM study_tasks t JOIN study_packages p ON p.id=t.package_id ORDER BY t.id")
        }
    }

    /// Jede Datei steht hoechstens einmal in einer offenen oder erledigten Aufgabe (Teile 1/n gelten als eine)
    private func assertNoDuplicateFiles(_ b: LocalBackend, file: StaticString = #filePath, line: UInt = #line) async throws {
        var seen: [String: Set<Int>] = [:]
        for t in try await tasks(b) where ["geplant", "in_bearbeitung", "erledigt", "nachholen"].contains(t["status"]?.string ?? "") {
            guard let f = t["file_id"]?.string else { continue }
            let title = t["title"]?.string ?? ""
            if title.contains("(Teil ") { continue }
            seen[f, default: []].insert(t["id"]?.int ?? 0)
        }
        for (f, ids) in seen where ids.count > 1 { XCTFail("Datei \(f) doppelt im Plan: Aufgaben \(ids.sorted())", file: file, line: line) }
    }

    /// Kein Lernblock (Paket mit Uhrzeit) in einem besuchten Termin, einer Sperrzeit oder einem anderen Lernblock
    private func assertNoOverlaps(_ b: LocalBackend, days: [String], file: StaticString = #filePath, line: UInt = #line) async throws {
        for day in days {
            let d = try XCTUnwrap(BerlinClock.parseISODate(day))
            let (busy, pkgs) = try await b.context.database.withConnection { c -> ([(Int, Int, String)], [(Int, Int, String)]) in
                let s = try LocalSettings.read(c)
                let blocks = try LocalFreeWindows.busyBlocks(c, day: d, settings: s, includePackages: false).map { ($0.start, $0.end, $0.kind) }
                let p = try c.rows("SELECT id, start_time, end_time FROM study_packages WHERE date=? AND start_time IS NOT NULL AND status NOT IN ('verschoben','uebersprungen')", [.text(day)])
                    .map { (try LocalFreeWindows.hm($0["start_time"], key: "s"), try LocalFreeWindows.hm($0["end_time"], key: "e"), "Paket \($0["id"]?.int ?? 0)") }
                return (blocks, p)
            }
            for (a, e, name) in pkgs {
                for (bs, be, kind) in busy where a < be && e > bs {
                    XCTFail("\(day): \(name) \(LocalFreeWindows.mh(a))–\(LocalFreeWindows.mh(e)) liegt in \(kind) \(LocalFreeWindows.mh(bs))–\(LocalFreeWindows.mh(be))", file: file, line: line)
                }
            }
            for i in pkgs.indices { for j in pkgs.indices where i < j && pkgs[i].0 < pkgs[j].1 && pkgs[i].1 > pkgs[j].0 {
                XCTFail("\(day): \(pkgs[i].2) und \(pkgs[j].2) ueberlappen", file: file, line: line)
            } }
        }
    }

    private func isoDays(_ from: String, _ n: Int) -> [String] {
        let d = BerlinClock.parseISODate(from)!
        return (0..<n).map { BerlinClock.isoDate(d + $0) }
    }

    private func addFiles(_ b: LocalBackend, course: String, _ rows: [(id: String, name: String, folder: String, local: String)]) async throws {
        try await b.context.database.transaction { c in
            _ = try UniStore.storeFiles(c, courseID: course, rows.map { r in
                UniStore.FileRow(id: r.id, name: r.name, size: 1000, mime: "application/pdf", chdate: BerlinClock.utcSeconds(localISO: r.local),
                                 downloadURL: "https://example.invalid/\(r.id)", folder: r.folder)
            }, now: "2026-10-26T08:00:00", fileExists: { _ in true })
        }
    }

    // MARK: Automatisch (Plus)

    /// Plan fuer die Woche: nur Stoff der Lehrwoche des Tages, keine Ueberschneidung mit Terminen/Sperrzeiten,
    /// Machbarkeit dabei; eigene und begonnene Pakete ueberstehen "Ersetzen", nichts doppelt
    func testAutoPlanWeekRuleNoOverlapAndReplaceKeepsOwnAndStarted() async throws {
        let now = TestNow("2026-10-26T07:30:00")                              // Montag, Lehrwoche 3
        let b = try await backend(now)
        try await addFiles(b, course: "k-ma-vl", [("n-ma-v3", "VL03 Reihen.pdf", "Vorlesung", "2026-10-26T06:00:00")])
        try await addFiles(b, course: "k-ma-ue", [("n-ma-u3", "Blatt 3.pdf", "Übungsblätter", "2026-10-26T06:30:00")])
        let gen = await send(b, "POST", "/api/calendar/generate", ["start": "2026-10-26", "days": 7])
        XCTAssertGreaterThan(gen["created"]?.int ?? 0, 0, "\(gen)")
        XCTAssertNotNil(gen["feasibility"]?["available_minutes_4w"]?.int)
        let week = isoDays("2026-10-26", 7)
        try await assertNoOverlaps(b, days: week)
        try await assertNoDuplicateFiles(b)
        // nur Stoff der Lehrwoche des Tages (week_no), jede Datei mit Lehrwoche = Paketwoche
        let ts = try await tasks(b)
        let dates = try await b.context.database.withConnection { try LocalModules.Dates($0, clock: now.clock) }
        let rows = try await b.context.database.withConnection { try LocalModules.fileRows($0, moduleID: nil) }
        for t in ts {
            guard let f = t["file_id"]?.string, let r = rows.first(where: { $0.id.string == f }) else { continue }
            let fw = try LocalModules.week(r, dates: dates)
            XCTAssertEqual(fw, t["week_no"]?.int, "\(f) im Paket der Lehrwoche \(t["week_no"] ?? .null) am \(t["date"] ?? .null)")
        }
        // eigenes Paket und begonnene Aufgabe
        let own = await send(b, "POST", "/api/packages", ["date": "2026-10-27", "title": "Eigenes Lesen", "minutes": 30])
        let started = try XCTUnwrap(ts.first { $0["file_id"]?.isNull == false })
        await send(b, "POST", "/api/tasks/\(started["id"]?.int ?? 0)/status", ["status": "in_bearbeitung"])
        await send(b, "POST", "/api/calendar/generate", ["start": "2026-10-26", "days": 7, "replace": true])
        let after = try await tasks(b)
        XCTAssertTrue(after.contains { $0["package_id"] == own["id"] }, "eigenes Paket weg")
        XCTAssertEqual(after.first { $0["id"] == started["id"] }?["status"], "in_bearbeitung", "begonnene Aufgabe ersetzt")
        try await assertNoDuplicateFiles(b)
        try await assertNoOverlaps(b, days: week)
    }

    // MARK: Von Hand (Free)

    /// Block anlegen, Uhrzeit, auf einen Tag mit Termin zur selben Zeit ziehen (rueckt in ein freies Fenster), auf
    /// einen freien Tag (Uhrzeit bleibt), abhaken, teilweise, loeschen
    func testManualBlockMoveDoneDelete() async throws {
        let now = TestNow("2026-10-26T07:30:00")
        let b = try await backend(now)
        let p = await send(b, "POST", "/api/packages", ["date": "2026-10-27", "title": "Formeln", "tasks": [
            ["type": "frei", "title": "Teil A", "est_minutes": 30], ["type": "frei", "title": "Teil B", "est_minutes": 30]]])
        let id = try XCTUnwrap(p["id"]?.int)
        await send(b, "PATCH", "/api/packages/\(id)", ["start_time": "09:30"])
        var pk = await send(b, "GET", "/api/packages/\(id)")
        XCTAssertEqual(pk["start_time"], "09:30")
        XCTAssertEqual(pk["end_time"], "10:30")
        // Montag 10:00–11:30 Testmathematik (Termin): dieselbe Uhrzeit geht nicht, das Paket rueckt in ein freies Fenster
        await send(b, "PATCH", "/api/packages/\(id)", ["date": "2026-11-09"])
        pk = await send(b, "GET", "/api/packages/\(id)")
        XCTAssertEqual(pk["date"], "2026-11-09")
        XCTAssertNotEqual(pk["start_time"], "09:30")
        try await assertNoOverlaps(b, days: ["2026-11-09"])
        // Ziehen auf anderen Tag und andere Uhrzeit in einem Schritt (Raster: Datum und Beginn)
        await send(b, "PATCH", "/api/packages/\(id)", ["date": "2026-10-29", "start_time": "15:00"])
        pk = await send(b, "GET", "/api/packages/\(id)")
        XCTAssertEqual(pk["date"], "2026-10-29")
        XCTAssertEqual(pk["start_time"], "15:00")
        let taskTimes = (pk["tasks"]?.array ?? []).compactMap { $0["start_time"]?.string }
        for t in taskTimes { XCTAssertGreaterThanOrEqual(t, "15:00", "Aufgaben ruecken mit") }
        // teilweise: eine von zwei erledigt, der Tag vergeht
        let t1 = try XCTUnwrap(pk["tasks"]?.array?.first?["id"]?.int)
        await send(b, "POST", "/api/tasks/\(t1)/status", ["status": "erledigt"])
        now.set("2026-10-30T08:00:00")
        pk = await send(b, "GET", "/api/packages/\(id)")
        XCTAssertEqual(pk["status"], "teilweise")
        XCTAssertEqual(pk["tasks"]?.array?.map { $0["status"]?.string ?? "" }, ["erledigt", "nachholen"])
        let cal = await send(b, "GET", "/api/calendar", query: [.init("start", "2026-10-29"), .init("end", "2026-10-29")])
        XCTAssertEqual(cal["days"]?.array?.first?["status"], "teilweise")
        // loeschen
        await send(b, "DELETE", "/api/packages/\(id)")
        let gone = await b.handle(LocalRequest(method: "GET", path: "/api/packages/\(id)"))
        XCTAssertEqual(gone.status, 404)
    }

    // MARK: Nicht geschafft

    /// Plan, ein Teil erledigt, zwei Tage vergehen: offene Aufgaben "nachholen", Uebersicht zaehlt sie, "Woche retten"
    /// verteilt sie (ohne Termine zu ueberplanen), erneut planen ersetzt nichts Verschobenes, nichts doppelt, nichts weg
    func testMissedDaysCatchUpRescueAndReplanWithoutLossOrDuplicates() async throws {
        let now = TestNow("2026-10-26T07:30:00")
        let b = try await backend(now)
        try await addFiles(b, course: "k-ma-vl", [("n-ma-v3", "VL03 Reihen.pdf", "Vorlesung", "2026-10-26T06:00:00")])
        try await addFiles(b, course: "k-ma-ue", [("n-ma-u3", "Blatt 3.pdf", "Übungsblätter", "2026-10-26T06:30:00")])
        try await addFiles(b, course: "k-ph", [("n-ph-v3", "Folien Kapitel 3.pdf", "Vorlesung", "2026-10-26T06:40:00")])
        await send(b, "POST", "/api/calendar/generate", ["start": "2026-10-26", "days": 7])
        let before = try await tasks(b)
        XCTAssertGreaterThan(before.count, 1)
        let monday = before.filter { $0["date"] == "2026-10-26" }
        XCTAssertFalse(monday.isEmpty, "Montag ohne Plan: \(before.map { $0["date"] ?? .null })")
        let done = try XCTUnwrap(monday.first?["id"]?.int)
        await send(b, "POST", "/api/tasks/\(done)/status", ["status": "erledigt"])
        // zwei Tage vergehen
        now.set("2026-10-28T09:00:00")
        let open = await send(b, "GET", "/api/tasks/open")
        let catchUp = (open.array ?? []).filter { $0["status"] == "nachholen" }
        let expected = before.filter { ($0["date"]?.string ?? "") < "2026-10-28" && $0["id"]?.int != done }.count
        XCTAssertEqual(catchUp.count, expected, "alles Vergangene ausser dem Erledigten ist nachzuholen")
        let dash = await send(b, "GET", "/api/dashboard")
        XCTAssertEqual(dash["backlog"]?.int, expected)
        let cal = await send(b, "GET", "/api/calendar", query: [.init("start", "2026-10-26"), .init("end", "2026-10-27")])
        XCTAssertEqual(cal["days"]?.array?.first?["status"], monday.count > 1 ? "teilweise" : "erledigt")
        // Woche retten: Vorschlag, dann uebernehmen
        let sug = await send(b, "POST", "/api/calendar/suggest", ["rescue": true])
        let moves = sug["moves"]?.array ?? []
        XCTAssertEqual(moves.count, expected)
        for m in moves { XCTAssertGreaterThanOrEqual(m["to"]?.string ?? "", "2026-10-28", "\(m)") }
        let applied = await send(b, "POST", "/api/calendar/apply", ["moves": .array(moves)])
        XCTAssertEqual(applied["moved"]?.int, expected)
        let afterRescue = try await tasks(b)
        XCTAssertEqual(afterRescue.count, before.count, "keine Aufgabe verloren")
        XCTAssertEqual(afterRescue.first { $0["id"]?.int == done }?["status"], "erledigt")
        XCTAssertEqual(afterRescue.filter { $0["status"] == "nachholen" }.count, 0)
        // nachgeholte Aufgaben haben im Raster eine Uhrzeit, ohne Termin darunter
        for t in afterRescue where t["moved_from"]?.isNull == false {
            XCTAssertNotNil(t["p_start"]?.string, "nachgeholte Aufgabe \(t["id"] ?? .null) am \(t["date"] ?? .null) ohne Uhrzeit")
        }
        try await assertNoOverlaps(b, days: isoDays("2026-10-28", 8))
        // erneut erstellen (Ersetzen): nichts doppelt, Verschobenes bleibt
        await send(b, "POST", "/api/calendar/generate", ["start": "2026-10-28", "days": 5, "replace": true])
        let again = try await tasks(b)
        try await assertNoDuplicateFiles(b)
        for t in afterRescue where t["moved_from"]?.isNull == false {
            XCTAssertTrue(again.contains { $0["id"] == t["id"] }, "nachgeholte Aufgabe \(t["id"] ?? .null) beim Ersetzen geloescht")
        }
        let files = Set(before.compactMap { $0["file_id"]?.string })
        let filesAgain = Set(again.compactMap { $0["file_id"]?.string })
        XCTAssertTrue(files.isSubset(of: filesAgain), "Dateien fehlen: \(files.subtracting(filesAgain))")
        try await assertNoOverlaps(b, days: isoDays("2026-10-28", 8))
        // ein Paket "Neu einplanen" (einzeln), dann noch einmal Woche retten: nichts mehr offen
        let again2 = await send(b, "POST", "/api/calendar/suggest", ["rescue": true])
        XCTAssertEqual(again2["moves"]?.array?.count, 0)
    }

    // MARK: Neue Dateien nach dem Abgleich

    /// auto_plan an: neue Dateien der laufenden Lehrwoche kommen in den Plan, ein begonnenes und ein eigenes Paket
    /// bleiben, nichts doppelt
    func testNewFilesAfterSyncJoinPlanWithoutDestroyingBlocks() async throws {
        let now = TestNow("2026-10-26T07:30:00")
        let b = try await backend(now)
        await send(b, "PUT", "/api/settings", ["auto_plan": true])
        try await addFiles(b, course: "k-ma-vl", [("n-ma-v3", "VL03 Reihen.pdf", "Vorlesung", "2026-10-26T06:00:00")])
        let first = try await b.context.database.transaction { try StudyPlan.autoPlanWeek($0, newFiles: 1, clock: now.clock) }
        XCTAssertGreaterThan(first?["created"]?.int ?? 0, 0, "\(String(describing: first))")
        let ts = try await tasks(b)
        let startedID = try XCTUnwrap(ts.first?["id"]?.int)
        await send(b, "POST", "/api/tasks/\(startedID)/status", ["status": "in_bearbeitung"])
        let own = await send(b, "POST", "/api/packages", ["date": "2026-10-29", "title": "Eigenes", "minutes": 30])
        // naechster Abgleich am Abend: zwei neue Dateien der Lehrwoche 3
        now.set("2026-10-26T18:00:00")
        try await addFiles(b, course: "k-ma-ue", [("n-ma-u3", "Blatt 3.pdf", "Übungsblätter", "2026-10-27T12:00:00")])
        try await addFiles(b, course: "k-ph", [("n-ph-v3", "Folien Kapitel 3.pdf", "Vorlesung", "2026-10-27T13:00:00")])
        let second = try await b.context.database.transaction { try StudyPlan.autoPlanWeek($0, newFiles: 2, clock: now.clock) }
        XCTAssertNotNil(second)
        let after = try await tasks(b)
        let planned = Set(after.compactMap { $0["file_id"]?.string })
        XCTAssertTrue(planned.contains("n-ma-u3"), "neues Blatt fehlt im Plan")
        XCTAssertTrue(planned.contains("n-ph-v3"), "neue Folien fehlen im Plan")
        XCTAssertEqual(after.first { $0["id"]?.int == startedID }?["status"], "in_bearbeitung")
        XCTAssertTrue(after.contains { $0["package_id"] == own["id"] })
        try await assertNoDuplicateFiles(b)
        try await assertNoOverlaps(b, days: isoDays("2026-10-26", 7))
        // derselbe Abgleich ohne neue Dateien: nichts aendert sich
        let third = try await b.context.database.transaction { try StudyPlan.autoPlanWeek($0, newFiles: 0, clock: now.clock) }
        XCTAssertNil(third)
    }

    // MARK: Grenzfaelle

    /// Tag ohne freie Zeit (Termine von Lernbeginn bis Lernende): kein Lernblock ueber den Terminen
    func testDayWithoutFreeTimeGetsNoBlockOverEvents() async throws {
        let now = TestNow("2026-10-26T07:30:00")
        let b = try await backend(now)
        try await addFiles(b, course: "k-ma-vl", [("n-ma-v3", "VL03 Reihen.pdf", "Vorlesung", "2026-10-26T06:00:00")])
        try await addFiles(b, course: "k-ma-ue", [("n-ma-u3", "Blatt 3.pdf", "Übungsblätter", "2026-10-26T06:30:00")])
        try await b.context.database.transaction { c in        // Dienstag ganz belegt
            try c.execute("""
                INSERT INTO course_events(module_id, course_id, title, kind, weekday, start_time, end_time, room, lecturer, rrule, date_from, date_to, attend, source, color, created_at)
                VALUES (NULL, NULL, 'Ganztags-Praktikum', 'sonstiges', 1, '07:00', '21:00', '', '', 'weekly', NULL, NULL, 1, 'manual', NULL, '2026-10-01T09:00:00')
                """)
        }
        now.set("2026-10-27T06:30:00")
        let gen = await send(b, "POST", "/api/calendar/generate", ["start": "2026-10-27", "days": 1])
        print("Tag ohne freie Zeit:", gen)
        try await assertNoOverlaps(b, days: ["2026-10-27"])
        // eigener Block an dem Tag, "Uhrzeiten vergeben": ebenfalls nicht ueber den Termin
        let p = await send(b, "POST", "/api/packages", ["date": "2026-10-27", "title": "Eigenes", "minutes": 30])
        await send(b, "POST", "/api/timetable/reslot", ["dates": ["2026-10-27"], "only_unset": true])
        let pk = await send(b, "GET", "/api/packages/\(p["id"]?.int ?? 0)")
        print("Eigenes Paket am vollen Tag:", pk["start_time"] ?? .null, pk["end_time"] ?? .null)
        try await assertNoOverlaps(b, days: ["2026-10-27"])
    }

    /// Wochenende ohne Lerntag, leere Woche, Sommerzeit-Wechsel im Maerz, sehr viele Dateien
    func testWeekendEmptyWeekDSTAndManyFiles() async throws {
        let now = TestNow("2026-10-26T07:30:00")
        let b = try await backend(now)
        // Lerntage Mo–Fr
        await send(b, "PUT", "/api/settings", ["free_days": [5, 6]])
        try await addFiles(b, course: "k-ma-vl", (0..<120).map { i in ("v\(i)", "VL03 Teil \(i).pdf", "Vorlesung", "2026-10-26T06:00:00") })
        try await addFiles(b, course: "k-ma-ue", (0..<120).map { i in ("u\(i)", "Blatt 3-\(i).pdf", "Übungsblätter", "2026-10-26T06:00:00") })
        let t0 = Date()
        let gen = await send(b, "POST", "/api/calendar/generate", ["start": "2026-10-26", "days": 14])
        XCTAssertLessThan(Date().timeIntervalSince(t0), 10)
        XCTAssertGreaterThan(gen["created"]?.int ?? 0, 0)
        let ts = try await tasks(b)
        XCTAssertFalse(ts.contains { ["2026-10-31", "2026-11-01", "2026-11-07", "2026-11-08"].contains($0["date"]?.string ?? "") }, "Wochenende verplant")
        try await assertNoDuplicateFiles(b)
        try await assertNoOverlaps(b, days: isoDays("2026-10-26", 14))
        let feas = await send(b, "GET", "/api/calendar/feasibility")
        // hoechstens 4 Vorlesungen und 4 Uebungen je Lehrwoche zaehlen (wie die Planung, Regel aus app/study.py)
        XCTAssertGreaterThan(feas["open_minutes"]?.int ?? 0, 0, "\(feas)")
        let cal = await send(b, "GET", "/api/calendar", query: [.init("start", "2026-10-26"), .init("end", "2026-11-08")])
        XCTAssertEqual(cal["days"]?.array?.count, 14)

        // leere Woche: neue Datenbank ohne Dateien
        let empty = try await backend(TestNow("2026-10-26T07:30:00"), seed: false)
        let none = await send(empty, "POST", "/api/calendar/generate", ["start": "2026-10-26", "days": 7])
        XCTAssertEqual(none["created"]?.int ?? 0, 0)

        // Sommerzeit: 29.03.2027 (Sonntag 28.03. 02:00 -> 03:00): Kalender ueber den Wechsel ohne Luecke/Doppel
        now.set("2027-03-27T10:00:00")
        let dst = await send(b, "GET", "/api/calendar", query: [.init("start", "2027-03-27"), .init("end", "2027-03-30")])
        XCTAssertEqual(dst["days"]?.array?.map { $0["date"]?.string ?? "" }, ["2027-03-27", "2027-03-28", "2027-03-29", "2027-03-30"])
        let p = await send(b, "POST", "/api/packages", ["date": "2027-03-28", "title": "DST", "minutes": 60])
        await send(b, "PATCH", "/api/packages/\(p["id"]?.int ?? 0)", ["start_time": "01:30"])
        let pk = await send(b, "GET", "/api/packages/\(p["id"]?.int ?? 0)")
        XCTAssertEqual(pk["end_time"], "02:30")
        await send(b, "PATCH", "/api/packages/\(p["id"]?.int ?? 0)", ["date": "2027-03-29"])
        now.set("2027-03-29T23:30:00")
        let o = await send(b, "GET", "/api/tasks/open")
        XCTAssertEqual(o.array?.first { $0["package_id"] == p["id"] }?["status"], "geplant", "am selben Tag noch nicht nachzuholen")
        now.set("2027-03-30T00:10:00")
        let o2 = await send(b, "GET", "/api/tasks/open")
        XCTAssertEqual(o2.array?.first { $0["package_id"] == p["id"] }?["status"], "nachholen")
    }

    /// Semesterwechsel: im Sommersemester plant der Plan keine Unterlagen des Wintersemesters
    func testSemesterChangeDoesNotPlanOldTermFiles() async throws {
        let now = TestNow("2027-04-19T08:00:00")
        let b = try await backend(now)
        let gen = await send(b, "POST", "/api/calendar/generate", ["start": "2027-04-19", "days": 7])
        XCTAssertEqual(gen["created"]?.int ?? 0, 0, "\(gen)")
        let ts = try await tasks(b)
        XCTAssertTrue(ts.isEmpty, "\(ts.map { $0["file_id"] ?? .null })")
    }

    // MARK: Dokumente

    /// Datei verschieben, umbenennen, Favorit, Papierkorb; Notizen bleiben, die Lernplan-Aufgabe zeigt weiter auf die
    /// Datei; ein neuer Stud.IP-Abgleich legt sie weder zurueck noch doppelt an; im Papierkorb plant der Plan sie nicht
    func testDocumentMoveRenameFavoriteTrashSurviveSyncAndPlan() async throws {
        let now = TestNow("2026-10-26T07:30:00")
        let b = try await backend(now)
        try await addFiles(b, course: "k-ma-vl", [("n-ma-v3", "VL03 Reihen.pdf", "Vorlesung", "2026-10-26T06:00:00")])
        try await addFiles(b, course: "k-ma-ue", [("n-ma-u3", "Blatt 3.pdf", "Übungsblätter", "2026-10-26T06:30:00")])
        await send(b, "POST", "/api/calendar/generate", ["start": "2026-10-26", "days": 7])
        let all0 = try await tasks(b)
        let task = try XCTUnwrap(all0.first { $0["file_id"] == "n-ma-v3" })
        let folder = await send(b, "POST", "/api/folders", ["name": "Prüfung", "module_id": 1])
        let fid = try XCTUnwrap(folder["id"]?.int)
        try await b.context.database.execute("INSERT INTO annotations(file_id, data, updated_at, version) VALUES ('n-ma-v3', '{\"pages\":{}}', '2026-10-26T08:00:00', 1)")
        await send(b, "PATCH", "/api/library/files/n-ma-v3", ["folder_id": .number(Double(fid)), "title": "Reihen (meine)"])
        await send(b, "POST", "/api/files/n-ma-v3/favorite", ["favorite": true])
        // erneuter Abgleich mit derselben und einer geaenderten Fassung
        try await addFiles(b, course: "k-ma-vl", [("n-ma-v3", "VL03 Reihen.pdf", "Vorlesung", "2026-10-27T06:00:00")])
        let row = try await b.context.database.withConnection { try $0.rows("SELECT * FROM files WHERE id='n-ma-v3'") }
        XCTAssertEqual(row.count, 1)
        XCTAssertEqual(row.first?["folder_id"]?.int, fid)
        XCTAssertEqual(row.first?["title"], "Reihen (meine)")
        XCTAssertEqual(row.first?["favorite"]?.int, 1)
        let n = try await b.context.database.scalar("SELECT COUNT(*) FROM files WHERE name='VL03 Reihen.pdf'")
        XCTAssertEqual(n?.int, 1)
        let notes = try await b.context.database.scalar("SELECT COUNT(*) FROM annotations WHERE file_id='n-ma-v3'")
        XCTAssertEqual(notes?.int, 1)
        let pk = await send(b, "GET", "/api/packages/\(task["package_id"]?.int ?? 0)")
        XCTAssertTrue((pk["tasks"]?.array ?? []).contains { $0["file_id"] == "n-ma-v3" && $0["file_name"] == "VL03 Reihen.pdf" })
        let lib = await send(b, "GET", "/api/library")
        XCTAssertEqual((lib["files"]?.array ?? []).filter { $0["id"] == "n-ma-v3" }.count, 1)
        // Papierkorb: bleibt nach Abgleich im Papierkorb, der Plan nimmt sie beim Ersetzen nicht neu auf
        await send(b, "PATCH", "/api/library/files/n-ma-u3", ["trash": true])
        try await addFiles(b, course: "k-ma-ue", [("n-ma-u3", "Blatt 3.pdf", "Übungsblätter", "2026-10-26T06:30:00")])
        let trashed = try await b.context.database.scalar("SELECT deleted_at FROM files WHERE id='n-ma-u3'")
        XCTAssertNotNil(trashed?.string)
        await send(b, "POST", "/api/calendar/generate", ["start": "2026-10-26", "days": 7, "replace": true])
        let planned = try await tasks(b).filter { $0["file_id"] == "n-ma-u3" && $0["status"] != "erledigt" }
        XCTAssertTrue(planned.isEmpty, "Datei im Papierkorb wieder eingeplant")
        let feas = await send(b, "GET", "/api/calendar/feasibility")
        XCTAssertNotNil(feas["open_minutes"])
        // wiederhergestellt: kommt wieder in den Plan
        await send(b, "PATCH", "/api/library/files/n-ma-u3", ["restore": true])
        await send(b, "POST", "/api/calendar/generate", ["start": "2026-10-26", "days": 7, "replace": true])
        let all1 = try await tasks(b)
        XCTAssertTrue(all1.contains { $0["file_id"] == "n-ma-u3" })
    }
}
