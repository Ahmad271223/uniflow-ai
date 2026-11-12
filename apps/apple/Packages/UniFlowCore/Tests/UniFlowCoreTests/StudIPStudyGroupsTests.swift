import Foundation
import XCTest
@testable import UniFlowCore

// Studiengruppen aus Stud.IP und Faecher im Lernkalender (Auftrag des Inhabers 12.11.2026). Erfundene Antworten unter
// packages/shared-contracts/fixtures/studip-studygroups; Lernkalender mit dem Seed aus study-plan.json.

private let clock = UniFlowClock.fixed(berlin: "2026-10-26T07:30:00")!
private let base = URL(string: "https://studip.test")!

private func repo() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return url
}

private func fixture(_ name: String) throws -> HTTPReply {
    HTTPReply(status: 200, contentType: "application/vnd.api+json",
              body: try Data(contentsOf: repo().appendingPathComponent("packages/shared-contracts/fixtures/studip-studygroups/\(name)")))
}

private func client() throws -> StudIPClient {
    let t = StubTransport([
        "/jsonapi.php/v1/users/u-test/courses?page[limit]=100&include=start-semester,end-semester": try fixture("users-courses.json"),
        "/jsonapi.php/v1/users/u-test/schedule": try fixture("users-schedule.json"),
    ])
    return StudIPClient(base: base, transport: t, pauseMillis: 0)
}

private func courses() async throws -> [StudIPCourse] { try await client().courses(userID: "u-test") }

final class StudIPStudyGroupsTests: XCTestCase {

    // MARK: Erkennen

    func testCourseListMarksStudyGroupsByCourseType() async throws {
        let list = try await courses()
        XCTAssertEqual(list.map(\.courseType), [1, 99, 99, 3])
        XCTAssertEqual(list.filter { StudIPStudyGroups.isStudyGroup($0) }.map(\.id), ["sg-lern", "sg-fach"])
        // die Gruppe aus einem frueheren Semester laeuft unbegrenzt: laufend nach der Semesterregel
        let lern = try XCTUnwrap(list.first { $0.id == "sg-lern" })
        XCTAssertNil(lern.number)
        XCTAssertEqual(lern.semesterEnd, "unbegrenzt")
        // ohne Art (Kursliste von vor dem 12.11.2026): nur ohne Nummer und mit "Studiengruppe" im Titel
        XCTAssertTrue(StudIPStudyGroups.isStudyGroup(StudIPCourse(id: "x", title: "Studiengruppe Analysis")))
        XCTAssertFalse(StudIPStudyGroups.isStudyGroup(StudIPCourse(id: "x", title: "Studiengruppe Analysis", number: "1234")))
        XCTAssertFalse(StudIPStudyGroups.isStudyGroup(StudIPCourse(id: "x", title: "Lerngruppe Beispiel")))
        // mit Art entscheidet nur die Art
        XCTAssertFalse(StudIPStudyGroups.isStudyGroup(StudIPCourse(id: "x", title: "Studiengruppe Analysis", courseType: 1)))
        // aeltere courses.json ohne Feld laesst sich weiter lesen
        let old = try JSONDecoder().decode(StudIPCourse.self, from: Data(#"{"id":"a","title":"T"}"#.utf8))
        XCTAssertNil(old.courseType)
    }

    // MARK: Schalter

    func testPlanKeepsGroupsOutUntilSwitchedOn() async throws {
        let list = try await courses()
        let all = Set(list.map(\.id))                              // die alte Kursauswahl hatte die Gruppen von selbst dabei
        var s = StudIPStudyGroups.Settings()
        var p = StudIPStudyGroups.plan(courses: list, selected: all, settings: s)
        XCTAssertEqual(p.store.map(\.id), ["c-vl", "c-ue"], "Vorgabe: alles aus")
        XCTAssertEqual(p.files, ["c-vl", "c-ue"])
        XCTAssertEqual(p.timetable, ["c-vl", "c-ue"])
        XCTAssertEqual(p.groups.map(\.id), ["sg-lern", "sg-fach"])
        XCTAssertEqual(p.timetableOff, ["sg-lern", "sg-fach"])

        s.choices["sg-lern"] = .init(files: true)
        p = StudIPStudyGroups.plan(courses: list, selected: all, settings: s)
        XCTAssertEqual(p.store.map(\.id), ["c-vl", "sg-lern", "c-ue"])
        XCTAssertTrue(p.files.contains("sg-lern"))
        XCTAssertFalse(p.timetable.contains("sg-lern"))

        s.choices["sg-lern"] = .init(timetable: true)
        s.choices["sg-fach"] = .init(module: true)
        p = StudIPStudyGroups.plan(courses: list, selected: [], settings: s)
        XCTAssertEqual(p.store.map(\.id), ["sg-lern", "sg-fach"], "abgewaehlte Kurse bleiben aus, Gruppen nach ihrer Wahl")
        XCTAssertEqual(p.files, [])
        XCTAssertEqual(p.timetable, ["sg-lern"])
        XCTAssertEqual(p.timetableOff, ["sg-fach"])
    }

    func testSettingsAreStoredAndReadBack() throws {
        let suite = "groups-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertEqual(StudIPStudyGroups.Settings.load(d), StudIPStudyGroups.Settings())
        let s = StudIPStudyGroups.Settings(asked: true, choices: ["sg": .init(files: true, module: true, moduleName: "Testanalysis I")])
        s.save(d)
        XCTAssertEqual(StudIPStudyGroups.Settings.load(d), s)
        XCTAssertFalse(StudIPStudyGroups.Settings.load(d).choice("unbekannt").anyOn)
    }

    // MARK: Module

    func testModuleSwitchAssignsOwnChosenOrNoModule() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let list = try await courses()
        let db = backend.context.database
        func modules() async throws -> [String: String] {
            var out: [String: String] = [:]
            for r in try await db.rows("SELECT c.id, m.name FROM courses c LEFT JOIN modules m ON m.id=c.module_id WHERE c.id != '__user__'") {
                out[r["id"]?.string ?? ""] = r["name"]?.string ?? "-"
            }
            return out
        }
        func sync(_ s: StudIPStudyGroups.Settings) async throws {
            let p = StudIPStudyGroups.plan(courses: list, selected: ["c-vl", "c-ue"], settings: s)
            try await db.transaction { c in
                try StudIPLibrary.storeCourses(c, p.store, startedAt: clock.nowISO, today: clock.today)
                try StudIPStudyGroups.applyModules(c, groups: p.groups, settings: s, clock: clock)
                try LocalModules.ensureModules(c, clock: clock)
            }
        }
        // nur Dateien: als Kurs gespeichert, aber ohne Modul
        var s = StudIPStudyGroups.Settings(asked: true, choices: ["sg-lern": .init(files: true)])
        try await sync(s)
        var m = try await modules()
        XCTAssertEqual(m["sg-lern"], "-")
        XCTAssertNil(m["sg-fach"], "ganz aus: nicht gespeichert")
        XCTAssertEqual(m["c-vl"], "Testanalysis I")

        // eigenes Modul: Titel der Gruppe, im Lernkalender aus
        s.choices["sg-lern"] = .init(files: true, module: true)
        try await sync(s)
        m = try await modules()
        XCTAssertEqual(m["sg-lern"], "Lerngruppe Testanalysis")
        let off = try await db.withConnection { try StudyPlanModules.off($0) }
        XCTAssertEqual(off, ["Lerngruppe Testanalysis"])

        // gewaehltes Modul
        s.choices["sg-lern"] = .init(files: true, module: true, moduleName: "Testanalysis I")
        try await sync(s)
        m = try await modules()
        XCTAssertEqual(m["sg-lern"], "Testanalysis I")
        XCTAssertEqual(m["c-vl"], "Testanalysis I")

        // wieder aus: kein Modul, und `ensureModules` legt keines nach dem Titel an
        s.choices["sg-lern"] = .init(files: true)
        try await sync(s)
        m = try await modules()
        XCTAssertEqual(m["sg-lern"], "-")
    }

    // MARK: Stundenplan

    func testTimetableSwitchKeepsGroupMeetingsOutAndRemovesThemLater() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let list = try await courses()
        let c = try client()
        func run(_ s: StudIPStudyGroups.Settings) async throws -> [String] {
            let p = StudIPStudyGroups.plan(courses: list, selected: ["c-vl", "c-ue"], settings: s)
            try await backend.context.database.transaction { c in
                try StudIPLibrary.storeCourses(c, p.store, startedAt: clock.nowISO, today: clock.today)
                try StudIPStudyGroups.applyModules(c, groups: p.groups, settings: s, clock: clock)
            }
            let d = await StudIPScheduleStore.fetch(client: c, userID: "u-test", courses: p.store.filter { p.timetable.contains($0.id) },
                                                    excluding: p.timetableOff)
            _ = try await backend.context.database.transaction { try StudIPScheduleStore.store(d, in: $0, clock: clock) }
            return try await backend.context.database.rows("SELECT title, weekday, start_time, course_id FROM course_events ORDER BY weekday")
                .map { "\($0["title"]?.string ?? "")|\($0["weekday"]?.int ?? -1)|\($0["start_time"]?.string ?? "")|\($0["course_id"]?.string ?? "")" }
        }
        // Vorgabe aus: nur die Vorlesung
        var s = StudIPStudyGroups.Settings(asked: true)
        var rows = try await run(s)
        XCTAssertEqual(rows, ["Testanalysis I|0|10:00|c-vl"])
        // an: das Treffen der Gruppe kommt dazu (auch ohne Dateien und Modul)
        s.choices["sg-lern"] = .init(timetable: true)
        rows = try await run(s)
        XCTAssertEqual(rows, ["Testanalysis I|0|10:00|c-vl", "Lerngruppe Testanalysis|2|18:00|sg-lern"])
        // wieder aus: das schon uebernommene Treffen verschwindet
        s.choices["sg-lern"] = .init(files: true)
        rows = try await run(s)
        XCTAssertEqual(rows, ["Testanalysis I|0|10:00|c-vl"])
        let cycles = try await backend.context.database.rows("SELECT course_id FROM studip_cycle_dates ORDER BY id").compactMap { $0["course_id"]?.string }
        XCTAssertEqual(cycles, ["c-vl"])
    }
}

// MARK: - Faecher im Lernkalender

final class StudyPlanModulesTests: XCTestCase {
    private func seeded() async throws -> LocalBackend {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let fx = try JSONValue.parse(Data(contentsOf: repo().appendingPathComponent("packages/shared-contracts/fixtures/local-backend/study-plan.json")))
        try await b.context.database.transaction { c in
            for s in fx["seed"]?.array ?? [] { try c.execute(s["sql"]?.string ?? "", (s["params"]?.array ?? []).map { SQLiteValue(json: $0) ?? .null }) }
            try c.execute("DELETE FROM study_tasks")
            try c.execute("DELETE FROM study_packages")
            try c.execute("UPDATE files SET status='neu' WHERE status='erledigt'")
        }
        return b
    }

    @discardableResult
    private func send(_ b: LocalBackend, _ method: String, _ path: String, _ body: JSONValue? = nil,
                      file: StaticString = #filePath, line: UInt = #line) async -> JSONValue {
        let r = await b.handle(LocalRequest(method: method, path: path, body: body.map { $0.serialized() } ?? Data()))
        XCTAssertEqual(r.status, 200, "\(method) \(path): \(String(data: r.body, encoding: .utf8) ?? "")", file: file, line: line)
        return r.json ?? .null
    }

    private func plannedSubjects(_ b: LocalBackend) async throws -> Set<String> {
        Set(try await b.context.database.rows("SELECT subject FROM study_packages").compactMap { $0["subject"]?.string })
    }

    func testOnlyChosenModulesGetStudyBlocks() async throws {
        let b = try await seeded()
        // Vorgabe: alle aktuellen Module geplant, noch nicht gefragt
        let first = await send(b, "GET", "/api/calendar/modules")
        XCTAssertEqual(first["asked"], false)
        let names = (first["modules"]?.array ?? []).compactMap { $0["name"]?.string }
        XCTAssertTrue(names.contains("Testmathematik I") && names.contains("Testphysik"), "\(names)")
        XCTAssertFalse(names.contains("Altmodul"), "nur aktuelle Module")
        XCTAssertTrue((first["modules"]?.array ?? []).allSatisfy { $0["planned"] == true })

        // Unterlagen der Lehrwoche 3 (Montag 26.10.) fuer zwei Faecher
        try await b.context.database.transaction { c in
            for (course, id, name, folder) in [("k-ma-vl", "n-ma-v3", "VL03 Reihen.pdf", "Vorlesung"), ("k-ma-ue", "n-ma-u3", "Blatt 3.pdf", "Übungsblätter"),
                                               ("k-ph", "n-ph-v3", "Folien Kapitel 3.pdf", "Vorlesung"), ("k-ph", "n-ph-u3", "Übungsblatt 3.pdf", "Übungen")] {
                _ = try UniStore.storeFiles(c, courseID: course, [UniStore.FileRow(
                    id: id, name: name, size: 1000, mime: "application/pdf", chdate: BerlinClock.utcSeconds(localISO: "2026-10-26T06:00:00"),
                    downloadURL: "https://example.invalid/\(id)", folder: folder)], now: "2026-10-26T08:00:00", fileExists: { _ in true })
            }
        }
        let all = await send(b, "POST", "/api/calendar/generate", ["start": "2026-10-26", "days": 7])
        XCTAssertGreaterThan(all["created"]?.int ?? 0, 0, "\(all)")
        var subjects = try await plannedSubjects(b)
        XCTAssertTrue(subjects.contains("Testmathematik I"), "\(subjects)")

        // Testmathematik aus dem Lernkalender: neu planen ohne sie, Modul und Dateien bleiben
        let saved = await send(b, "POST", "/api/calendar/modules", ["modules": [["name": "Testmathematik I", "planned": false]]])
        XCTAssertEqual(saved["asked"], true)
        XCTAssertEqual(saved["modules"]?.array?.first { $0["name"]?.string == "Testmathematik I" }?["planned"], false)
        try await b.context.database.transaction { c in
            try c.execute("DELETE FROM study_tasks")
            try c.execute("DELETE FROM study_packages")
        }
        let again = await send(b, "POST", "/api/calendar/generate", ["start": "2026-10-26", "days": 7])
        subjects = try await plannedSubjects(b)
        XCTAssertFalse(subjects.contains("Testmathematik I"), "\(subjects)")
        XCTAssertGreaterThan(again["created"]?.int ?? 0, 0, "andere Faecher werden weiter geplant: \(again)")
        let modules = await send(b, "GET", "/api/modules")
        XCTAssertTrue((modules.array ?? []).contains { $0["name"]?.string == "Testmathematik I" }, "bleibt in den Modulen")

        // Umbenennen behaelt die Wahl; "Später" merkt nur, dass gefragt wurde
        let id = try XCTUnwrap(modules.array?.first { $0["name"]?.string == "Testmathematik I" }?["id"]?.int)
        await send(b, "PATCH", "/api/modules/\(id)", ["name": "Testmathe"])
        let off = try await b.context.database.withConnection { try StudyPlanModules.off($0) }
        XCTAssertEqual(off, ["Testmathe"])
        await send(b, "POST", "/api/calendar/modules", ["asked": true])
        let after = try await b.context.database.withConnection { try StudyPlanModules.off($0) }
        XCTAssertEqual(after, ["Testmathe"])
    }
}
