import Foundation
import XCTest
@testable import UniFlowCore

/// Wochen von Hand (`ModuleSections`, 07.11.2026): die gesetzte Woche gewinnt ueber die automatische Zuordnung
/// (Stud.IP wie Moodle) und ueberlebt den naechsten Abgleich; eigene Abschnitte je Modul anlegen, umbenennen, ordnen,
/// loeschen; Wochenliste; Endpunkte; Regal. Alle Namen sind erfunden.
final class ModuleSectionsTests: XCTestCase {

    private func database(university: String, today: String) async throws -> (SQLiteDatabase, UniFlowClock) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ms-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let clock = UniFlowClock.fixed(berlin: today)!
        let db = try SQLiteDatabase(path: dir.appendingPathComponent("t.db").path)
        try await db.migrate(clock: clock, university: university)
        return (db, clock)
    }

    private func ts(_ local: String) -> SQLiteValue {
        .integer(Int64(UniFlowClock.fixed(berlin: local)!.now.timeIntervalSince1970))
    }

    /// Ein Fach (Vorlesung) mit zwei Dateien in Lehrwoche 1 und 2 (Stud.IP der LUH: Woche aus der Aenderungszeit)
    private func seedStudIP(_ db: SQLiteDatabase, clock: UniFlowClock) async throws -> Int {
        try await db.transaction { c in
            let (subject, kind) = UniRules.classify("Testmathematik I")
            try c.execute("INSERT INTO courses(id, title, semester, subject, kind, created_at) VALUES (?,?,?,?,?,?)",
                          [.text("k-v"), .text("Testmathematik I"), .text("WiSe 2026/27"), .text(subject), .text(kind), .text("2026-10-01T08:00:00")])
            for (id, name, when) in [("f-1", "VL01.pdf", "2026-10-13T10:00"), ("f-2", "VL02.pdf", "2026-10-20T10:00"), ("f-3", "Altklausur WS25.pdf", "2026-10-20T11:00")] {
                try c.execute("INSERT INTO files(id, course_id, name, chdate, status, kind, mime) VALUES (?,?,?,?,'neu','pdf','application/pdf')",
                              [.text(id), .text("k-v"), .text(name), self.ts(when)])
            }
            try LocalModules.ensureModules(c, clock: clock)
            return try c.scalar("SELECT id FROM modules")?.int ?? 0
        }
    }

    private func weeks(_ db: SQLiteDatabase, moduleID: Int, clock: UniFlowClock) async throws -> [(week: Int, label: String, files: [String])] {
        try await db.transaction { c in
            let d = try XCTUnwrap(try LocalModules.detail(c, moduleID: .integer(Int64(moduleID)), clock: clock))
            return (d["weeks"]?.array ?? []).map { w in
                let files = LocalModules.groupKeys.flatMap { (w[$0]?.array ?? []).compactMap { $0["id"]?.string } }
                return (w["week"]?.int ?? 0, w["label"]?.string ?? "", files)
            }
        }
    }

    // MARK: Gesetzte Woche gewinnt

    func testManualWeekWinsForStudIPAndSurvivesWithoutLectureTables() async throws {
        let (db, clock) = try await database(university: "luh", today: "2026-11-20T10:00:00")
        let mid = try await seedStudIP(db, clock: clock)
        var ws = try await weeks(db, moduleID: mid, clock: clock)
        XCTAssertEqual(ws.map(\.label), ["Woche 1 · 12.10. – 18.10.", "Woche 2 · 19.10. – 25.10.", "Klausuren & Altklausuren"])
        // f-2 nach Woche 5, die Altklausur nach "Allgemein"
        let n = try await db.transaction { c in try ModuleSections.set(c, fileIDs: ["f-2", "f-3", "gibt-es-nicht"], week: 5, now: clock.nowISO) }
        XCTAssertEqual(n, 2, "nur vorhandene Dateien")
        _ = try await db.transaction { c in try ModuleSections.set(c, fileIDs: ["f-3"], week: LectureWeeks.generalWeek, now: clock.nowISO) }
        ws = try await weeks(db, moduleID: mid, clock: clock)
        XCTAssertEqual(ws.map(\.label), ["Allgemein", "Woche 1 · 12.10. – 18.10.", "Woche 5 · 09.11. – 15.11."])
        XCTAssertEqual(ws[2].files, ["f-2"])
        XCTAssertEqual(ws[0].files, ["f-3"], "auch eine Klausur laesst sich von Hand verschieben")
        // Kennzeichen fuer "Zurueck auf automatisch"
        let rows = try await db.transaction { c in try LocalModules.fileRows(c, moduleID: .integer(Int64(mid))) }
        XCTAssertEqual(rows.first { $0.id.string == "f-2" }?.json["week_manual"]?.bool, true)
        XCTAssertNil(rows.first { $0.id.string == "f-1" }?.json["week_manual"])
        // Stud.IP braucht dafuer keine Lehrwochen-Tabellen
        let lw = try await db.transaction { try LectureWeeks.hasTables($0) }
        XCTAssertFalse(lw)
        // zurueck auf automatisch
        let reset = try await db.transaction { c in try ModuleSections.reset(c, fileIDs: ["f-2", "f-3"]) }
        XCTAssertEqual(reset, 2)
        ws = try await weeks(db, moduleID: mid, clock: clock)
        XCTAssertEqual(ws.map(\.label), ["Woche 1 · 12.10. – 18.10.", "Woche 2 · 19.10. – 25.10.", "Klausuren & Altklausuren"])
    }

    func testManualWeekWinsOverMoodleAssignmentAndNextSync() async throws {
        let (db, clock) = try await database(university: "hsh", today: "2026-11-20T10:00:00")
        let now = clock.nowISO
        let mid = try await db.transaction { c -> Int in
            try UniStore.upsertCourse(c, UniStore.CourseRow(id: "lw-1", title: "Mathematik 1", number: nil, semester: "WiSe 2026/27"), now: now)
            _ = try UniStore.storeFiles(c, courseID: "lw-1", [("lw-1-a", "VL 3.pdf"), ("lw-1-b", "literatur.pdf")].map {
                UniStore.FileRow(id: $0.0, name: $0.1, size: 1, mime: "application/pdf", chdate: nil, downloadURL: "https://moodle.example.org/x", folder: "")
            }, now: now, fileExists: { _ in false })
            try c.execute("UPDATE courses SET subject='Mathematik 1', kind='vorlesung' WHERE id='lw-1'")
            try LocalModules.ensureModules(c, clock: clock)
            try LectureWeeks.assignCourse(c, courseID: "lw-1", semester: "WiSe 2026/27", university: "hsh",
                                          files: [LectureWeeks.Input(id: "lw-1-a", name: "VL 3.pdf"), LectureWeeks.Input(id: "lw-1-b", name: "literatur.pdf")], now: now)
            return try c.scalar("SELECT id FROM modules")?.int ?? 0
        }
        var ws = try await weeks(db, moduleID: mid, clock: clock)
        XCTAssertEqual(ws.map(\.label), ["Allgemein", "Woche 3 · 05.10. – 11.10."])
        // von Hand nach Woche 9
        _ = try await db.transaction { c in try ModuleSections.set(c, fileIDs: ["lw-1-a"], week: 9, now: now) }
        // naechster Abgleich: Moodle liefert dieselbe Datei mit einem Datum und eine neue dazu
        let later = try await db.transaction { c in
            try LectureWeeks.assignCourse(c, courseID: "lw-1", semester: "WiSe 2026/27", university: "hsh",
                                          files: [LectureWeeks.Input(id: "lw-1-a", name: "VL 3.pdf", date: 1_764_000_000),
                                                  LectureWeeks.Input(id: "lw-1-b", name: "literatur.pdf"),
                                                  LectureWeeks.Input(id: "lw-1-c", name: "Blatt 4.pdf")], now: now)
        }
        XCTAssertEqual(later.map(\.fileID), ["lw-1-c"], "nur die neue Datei wird zugeordnet")
        ws = try await weeks(db, moduleID: mid, clock: clock)
        XCTAssertEqual(ws.map(\.label), ["Allgemein", "Woche 9 · 16.11. – 22.11."])
        XCTAssertEqual(ws[1].files, ["lw-1-a"])
        let stored = try await db.transaction { try LectureWeeks.stored($0) }
        XCTAssertEqual(stored["lw-1-a"]?.monday, BerlinClock.parseISODate("2026-10-05"), "die automatische Zuordnung bleibt gemerkt, die Wahl liegt darueber")
        let manual = try await db.transaction { try ModuleSections.overrides($0) }
        XCTAssertEqual(manual["lw-1-a"], ModuleSections.Override(week: 9, sectionID: nil))
    }

    // MARK: Eigene Abschnitte

    func testSectionsCreateRenameOrderDelete() async throws {
        let (db, clock) = try await database(university: "luh", today: "2026-11-20T10:00:00")
        let mid = try await seedStudIP(db, clock: clock)
        let now = clock.nowISO
        let (alt, prep) = try await db.transaction { c -> (ModuleSections.Section, ModuleSections.Section) in
            let a = try ModuleSections.create(c, moduleID: mid, name: "  Altklausuren ", now: now)
            let p = try ModuleSections.create(c, moduleID: mid, name: "Woche 2b Klausurvorbereitung", afterWeek: 2, now: now)
            return (a, p)
        }
        XCTAssertEqual(alt.name, "Altklausuren")
        XCTAssertEqual(alt.afterWeek, ModuleSections.topAnchor)
        XCTAssertEqual(prep.afterWeek, 2)
        XCTAssertLessThan(alt.week, -1000)
        // leere Abschnitte stehen als Bloecke an ihrer Stelle
        var ws = try await weeks(db, moduleID: mid, clock: clock)
        XCTAssertEqual(ws.map(\.label), ["Altklausuren", "Woche 1 · 12.10. – 18.10.", "Woche 2 · 19.10. – 25.10.", "Woche 2b Klausurvorbereitung",
                                         "Klausuren & Altklausuren"])
        XCTAssertEqual(ws[0].files, [])
        // Dateien hinein
        _ = try await db.transaction { c in
            try ModuleSections.set(c, fileIDs: ["f-3"], week: alt.week, now: now)
            try ModuleSections.set(c, fileIDs: ["f-2"], week: prep.week, now: now)
        }
        ws = try await weeks(db, moduleID: mid, clock: clock)
        XCTAssertEqual(ws.map(\.label), ["Altklausuren", "Woche 1 · 12.10. – 18.10.", "Woche 2b Klausurvorbereitung"])
        XCTAssertEqual(ws[0].files, ["f-3"])
        XCTAssertEqual(ws[2].files, ["f-2"])
        // Ordnen: "Altklausuren" zweimal nach unten (hinter Woche 1, dann hinter 2b), einmal zu weit
        let present = ws.map(\.week)
        _ = try await db.transaction { c in try ModuleSections.move(c, id: alt.id, up: false, weeks: present) }
        ws = try await weeks(db, moduleID: mid, clock: clock)
        XCTAssertEqual(ws.map(\.label), ["Woche 1 · 12.10. – 18.10.", "Altklausuren", "Woche 2b Klausurvorbereitung"])
        _ = try await db.transaction { c in try ModuleSections.move(c, id: alt.id, up: false, weeks: present) }
        ws = try await weeks(db, moduleID: mid, clock: clock)
        XCTAssertEqual(ws.map(\.label), ["Woche 1 · 12.10. – 18.10.", "Woche 2b Klausurvorbereitung", "Altklausuren"])
        let after = try await db.transaction { c in try ModuleSections.move(c, id: alt.id, up: false, weeks: present) }
        XCTAssertEqual(after.map(\.name), ["Woche 2b Klausurvorbereitung", "Altklausuren"], "ganz unten bleibt unten")
        XCTAssertEqual(after.map(\.afterWeek), [1, 1])
        XCTAssertEqual(after.map(\.position), [0, 1])
        // und wieder nach oben, ganz nach oben
        for _ in 0..<3 { _ = try await db.transaction { c in try ModuleSections.move(c, id: alt.id, up: true, weeks: present) } }
        ws = try await weeks(db, moduleID: mid, clock: clock)
        XCTAssertEqual(ws.map(\.label).first, "Altklausuren")
        let anchor = try await db.transaction { try ModuleSections.get($0, id: alt.id)?.afterWeek }
        XCTAssertEqual(anchor, ModuleSections.topAnchor)
        // Umbenennen und hinter eine andere Woche setzen
        let renamed = try await db.transaction { c in try ModuleSections.update(c, id: prep.id, name: "Klausurvorbereitung", afterWeek: 1) }
        XCTAssertEqual(renamed.name, "Klausurvorbereitung")
        XCTAssertEqual(renamed.afterWeek, 1)
        ws = try await weeks(db, moduleID: mid, clock: clock)
        XCTAssertEqual(ws.map(\.label), ["Altklausuren", "Woche 1 · 12.10. – 18.10.", "Klausurvorbereitung"])
        // Loeschen: die Dateien darin gehen zurueck auf automatisch
        try await db.transaction { c in try ModuleSections.delete(c, id: prep.id) }
        ws = try await weeks(db, moduleID: mid, clock: clock)
        XCTAssertEqual(ws.map(\.label), ["Altklausuren", "Woche 1 · 12.10. – 18.10.", "Woche 2 · 19.10. – 25.10."])
        XCTAssertEqual(ws[2].files, ["f-2"])
        let manual = try await db.transaction { try ModuleSections.overrides($0) }
        XCTAssertNil(manual["f-2"])
        XCTAssertNotNil(manual["f-3"])
        // Fehler: leerer Name, unbekanntes Modul, unbekannter Abschnitt
        await XCTAssertThrowsErrorAsync(try await db.transaction { c in try ModuleSections.create(c, moduleID: mid, name: "   ", now: now) })
        await XCTAssertThrowsErrorAsync(try await db.transaction { c in try ModuleSections.create(c, moduleID: 999, name: "x", now: now) })
        await XCTAssertThrowsErrorAsync(try await db.transaction { c in try ModuleSections.set(c, fileIDs: ["f-1"], week: prep.week, now: now) })
        await XCTAssertThrowsErrorAsync(try await db.transaction { c in try ModuleSections.set(c, fileIDs: ["f-1"], week: -7, now: now) })
    }

    func testChoicesListAllWeeksWithSectionsInPlace() async throws {
        let (db, clock) = try await database(university: "luh", today: "2026-11-20T10:00:00")
        let mid = try await seedStudIP(db, clock: clock)
        _ = try await db.transaction { c in
            try ModuleSections.create(c, moduleID: mid, name: "Altklausuren", afterWeek: -2, now: clock.nowISO)
            try ModuleSections.create(c, moduleID: mid, name: "Woche 7b", afterWeek: 7, now: clock.nowISO)
        }
        let d = try await db.transaction { c in try XCTUnwrap(try LocalModules.detail(c, moduleID: .integer(Int64(mid)), clock: clock)) }
        let labels = (d["week_choices"]?.array ?? []).map { $0["label"]?.string ?? "" }
        XCTAssertEqual(labels.first, "Allgemein")
        XCTAssertEqual(labels[1], "Woche 1 · 12.10. – 18.10.")
        XCTAssertEqual(labels.suffix(2), ["Klausuren & Altklausuren", "Altklausuren"])
        XCTAssertEqual(labels.firstIndex(of: "Woche 7b"), labels.firstIndex(of: "Woche 7 · 23.11. – 29.11.").map { $0 + 1 })
        XCTAssertTrue(labels.contains("Woche 14 · 11.01. – 17.01."), "mindestens 14 Wochen: \(labels)")
        XCTAssertFalse(labels.contains("Woche 15 · 18.01. – 24.01."))
        XCTAssertEqual(labels.filter { $0 == "Woche 2 · 19.10. – 25.10." }.count, 1)
        let custom = (d["week_choices"]?.array ?? []).filter { $0["custom"]?.bool == true }.map { $0["label"]?.string ?? "" }
        XCTAssertEqual(custom, ["Woche 7b", "Altklausuren"])
        XCTAssertEqual((d["sections"]?.array ?? []).map { $0["name"]?.string ?? "" }, ["Woche 7b", "Altklausuren"])
    }

    // MARK: Endpunkte und Regal

    private func call(_ backend: LocalBackend, _ method: String, _ path: String, _ body: JSONValue? = nil) async throws -> (Int, JSONValue) {
        let r = await backend.handle(LocalRequest(method: method, path: path, headers: ["Content-Type": "application/json"],
                                                  body: body?.serialized() ?? Data()))
        return (r.status, r.body.isEmpty ? .null : try JSONValue.parse(r.body))
    }

    func testEndpointsMoveFilesAndManageSections() async throws {
        let (db, clock) = try await database(university: "luh", today: "2026-11-20T10:00:00")
        let mid = try await seedStudIP(db, clock: clock)
        let backend = try LocalBackend(database: db, clock: clock)
        // mehrere Dateien auf einmal
        var (status, out) = try await call(backend, "POST", "/api/files/week", ["file_ids": ["f-1", "f-2"], "week": 4])
        XCTAssertEqual(status, 200)
        XCTAssertEqual(out["changed"]?.int, 2)
        (status, out) = try await call(backend, "GET", "/api/modules/\(mid)")
        XCTAssertEqual((out["weeks"]?.array ?? []).map { $0["label"]?.string ?? "" }, ["Woche 4 · 02.11. – 08.11.", "Klausuren & Altklausuren"])
        XCTAssertEqual(out["weeks"]?.array?.first?["vorlesungen"]?.array?.count, 2)
        // Abschnitt anlegen und gleich f-3 hinein
        (status, out) = try await call(backend, "POST", "/api/modules/\(mid)/sections", ["name": "Altklausuren", "after_week": -2, "file_ids": ["f-3"]])
        XCTAssertEqual(status, 200)
        let sid = try XCTUnwrap(out["id"]?.int)
        let code = try XCTUnwrap(out["week"]?.int)
        XCTAssertEqual(code, ModuleSections.weekCode(sectionID: sid))
        (status, out) = try await call(backend, "GET", "/api/modules/\(mid)/sections")
        XCTAssertEqual((out["sections"]?.array ?? []).map { $0["name"]?.string ?? "" }, ["Altklausuren"])
        XCTAssertTrue((out["choices"]?.array ?? []).contains { $0["week"]?.int == code && $0["custom"]?.bool == true })
        (status, out) = try await call(backend, "GET", "/api/modules/\(mid)")
        XCTAssertEqual((out["weeks"]?.array ?? []).map { $0["label"]?.string ?? "" }, ["Woche 4 · 02.11. – 08.11.", "Altklausuren"])
        XCTAssertEqual(out["weeks"]?.array?.last?["custom"]?.bool, true)
        XCTAssertEqual(out["weeks"]?.array?.last?["section_id"]?.int, sid)
        // umbenennen, ordnen, loeschen
        (status, out) = try await call(backend, "PATCH", "/api/modules/\(mid)/sections/\(sid)", ["name": "Alte Klausuren"])
        XCTAssertEqual(out["name"]?.string, "Alte Klausuren")
        (status, out) = try await call(backend, "POST", "/api/modules/\(mid)/sections/\(sid)/move", ["direction": "up"])
        XCTAssertEqual(status, 200)
        XCTAssertEqual(out["sections"]?.array?.first?["after_week"]?.int, ModuleSections.topAnchor)
        (status, out) = try await call(backend, "GET", "/api/modules/\(mid)")
        XCTAssertEqual((out["weeks"]?.array ?? []).map { $0["label"]?.string ?? "" }, ["Alte Klausuren", "Woche 4 · 02.11. – 08.11."])
        (status, _) = try await call(backend, "DELETE", "/api/modules/\(mid)/sections/\(sid)")
        XCTAssertEqual(status, 200)
        (status, _) = try await call(backend, "DELETE", "/api/modules/\(mid)/sections/\(sid)")
        XCTAssertEqual(status, 404)
        (status, _) = try await call(backend, "PATCH", "/api/modules/\(mid + 1)/sections/\(sid)", ["name": "x"])
        XCTAssertEqual(status, 404)
        // zurueck auf automatisch
        (status, out) = try await call(backend, "POST", "/api/files/week", ["file_ids": ["f-1", "f-2", "f-3"], "auto": true])
        XCTAssertEqual(out["changed"]?.int, 2, "f-3 war mit dem Abschnitt schon zurueckgesetzt")
        (status, out) = try await call(backend, "GET", "/api/modules/\(mid)")
        XCTAssertEqual((out["weeks"]?.array ?? []).map { $0["label"]?.string ?? "" }, ["Woche 1 · 12.10. – 18.10.", "Woche 2 · 19.10. – 25.10.", "Klausuren & Altklausuren"])
        // Fehler
        (status, _) = try await call(backend, "POST", "/api/files/week", ["file_ids": [], "week": 4])
        XCTAssertEqual(status, 400)
        (status, _) = try await call(backend, "POST", "/api/files/week", ["file_ids": ["f-1"], "week": "x"])
        XCTAssertEqual(status, 400)
        (status, _) = try await call(backend, "POST", "/api/modules/\(mid)/sections", ["name": ""])
        XCTAssertEqual(status, 400)
    }

    func testShelfShowsManualWeeksAndSections() async throws {
        let (db, clock) = try await database(university: "luh", today: "2026-11-20T10:00:00")
        let mid = try await seedStudIP(db, clock: clock)
        let sid = try await db.transaction { c -> Int in
            let s = try ModuleSections.create(c, moduleID: mid, name: "Altklausuren", afterWeek: -2, now: clock.nowISO)
            try ModuleSections.set(c, fileIDs: ["f-2"], week: 6, now: clock.nowISO)
            return s.id
        }
        let shelf = try await db.transaction { c in try DocIndexStore.shelf(c, moduleID: nil, clock: clock) }
        let module = try XCTUnwrap(shelf["programs"]?.array?.first?["semesters"]?.array?.first?["modules"]?.array?.first)
        let weeks = module["weeks"]?.array ?? []
        XCTAssertEqual(weeks.map { $0["label"]?.string ?? "" }, ["Woche 1 · 12.10. – 18.10.", "Woche 6 · 16.11. – 22.11.", "Klausuren & Altklausuren", "Altklausuren"])
        XCTAssertEqual(weeks.last?["custom"]?.bool, true)
        XCTAssertEqual(weeks.last?["week"]?.int, ModuleSections.weekCode(sectionID: sid))
        let moved = weeks[1]["kinds"]?.array?.first?["files"]?.array?.first
        XCTAssertEqual(moved?["file_id"]?.string, "f-2")
        XCTAssertEqual(moved?["week_manual"]?.bool, true)
        XCTAssertEqual(weeks[0]["kinds"]?.array?.first?["files"]?.array?.first?["week_manual"]?.bool, false)
        XCTAssertTrue((module["week_choices"]?.array ?? []).contains { $0["label"]?.string == "Altklausuren" })
    }
}

/// `XCTAssertThrowsError` fuer async-Ausdruecke
func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, _ message: String = "",
                                  file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("Kein Fehler: \(message)", file: file, line: line)
    } catch {}
}
