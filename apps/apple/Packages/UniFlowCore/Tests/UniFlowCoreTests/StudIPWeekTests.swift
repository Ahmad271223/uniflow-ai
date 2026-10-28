import Foundation
import XCTest
@testable import UniFlowCore

// Woche 1:1 aus dem eigenen Stud.IP-Kalender und nur das aktuelle Semester, gegen die Python-Referenz
// packages/shared-contracts/fixtures/studip-schedule/woche.json (tools/gen-studip-week-fixture.py, PC-Stand 81eecf0,
// erfundene Daten, eingefrorene Uhr Mittwoch 28.10.2026 08:00 = WiSe 2026/27). Dieselben Schritte wie der Generator:
// Semesterregel, Kursliste mit end-semester, Kursanlage mit Modulen, eigene Entscheidung, merge_weekly ueber zwei
// Jahrgaenge, dann die Woche 16.-22.11.2026 (studip_dated, occurrences, belegte Zeit am 18.11.).

private func woche() throws -> JSONValue {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return try JSONValue.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/studip-schedule/woche.json")))
}

final class StudIPWeekTests: XCTestCase {

    private func fixture() throws -> (JSONValue, UniFlowClock, String) {
        let fx = try woche()
        let now = try XCTUnwrap(fx["now"]?.string)
        return (fx, try XCTUnwrap(UniFlowClock.fixed(berlin: now)), try XCTUnwrap(fx["today"]?.string))
    }

    /// `semesters.key`, `current`/`label` und `is_current`
    func testSemesterRuleMatchesPython() throws {
        let (fx, _, today) = try fixture()
        for c in fx["semester_keys"]?.array ?? [] {
            XCTAssertEqual(Semesters.key(c["title"]?.string)?.json ?? .null, c["key"] ?? .null, c["title"]?.string ?? "")
        }
        for c in fx["current"]?.array ?? [] {
            let k = Semesters.current(c["day"]?.string ?? "")
            XCTAssertEqual(k.json, c["key"], c["day"]?.string ?? "")
            XCTAssertEqual(Semesters.label(k), c["label"]?.string, c["day"]?.string ?? "")
        }
        let cases = fx["semester_cases"]?.array ?? []
        XCTAssertGreaterThanOrEqual(cases.count, 9)
        for c in cases {
            let got = Semesters.isCurrent(semester: c["semester"]?.string, semesterEnd: c["semester_end"]?.string, endsAt: c["ends_at"]?.string, today: today)
            XCTAssertEqual(got.map(JSONValue.bool) ?? .null, c["is_current"] ?? .null, c.jsonString())
        }
    }

    /// Kursliste mit `include=start-semester,end-semester`: Endsemester, "unbegrenzt" bei `data: null`, nil ohne Beziehung
    func testFetchCoursesReadsEndSemester() async throws {
        let (fx, _, _) = try fixture()
        let request = try XCTUnwrap(fx["fetch_courses"]?["request"]?.string)
        XCTAssertEqual(request, "users/{id}/courses?page[limit]=100&include=start-semester,end-semester")
        let body = try XCTUnwrap(fx["fetch_courses"]?["response"]).serialized()
        let path = "/jsonapi.php/v1/" + request.replacingOccurrences(of: "{id}", with: "u-test")
        let transport = StubTransport([path: HTTPReply(status: 200, contentType: "application/vnd.api+json", body: body)])
        let client = StudIPClient(base: URL(string: "https://studip.test")!, transport: transport, pauseMillis: 0)
        let got = try await client.courses(userID: "u-test")
        let shown: JSONValue = .array(got.map { c in
            ["id": .string(c.id), "title": .string(c.title), "number": c.number.map(JSONValue.string) ?? .null,
             "semester": .string(c.semesterTitle ?? ""), "semester_end": c.semesterEnd.map(JSONValue.string) ?? .null,
             "semester_ends_at": c.semesterEndsAt.map(JSONValue.string) ?? .null]
        })
        XCTAssertNil(jsonDiff(shown, fx["fetch_courses"]?["courses"]), jsonDiff(shown, fx["fetch_courses"]?["courses"]) ?? "")
    }

    /// `merge_weekly`: derselbe Kurstitel in zwei Jahrgaengen (zwei Kurs-IDs) sind zwei Serien
    func testMergeWeeklyKeepsYearsApart() throws {
        let (fx, _, _) = try fixture()
        var entries: [LocalTimetableImport.Entry] = []
        for (cid, days) in [("w-mt-24", ["2024-10-16", "2024-10-23", "2024-10-30"]), ("w-mt-26", ["2026-10-21", "2026-10-28", "2026-11-04"])] {
            for d in days {
                entries.append(["title": "Testmesstechnik I", "course_id": .string(cid), "weekday": 2, "start_time": "10:00",
                                "end_time": "10:45", "date_from": .string(d)])
            }
        }
        let got: JSONValue = .array(try LocalTimetableImport.mergeWeekly(entries).map(JSONValue.object))
        let want = fx["merge_weekly_multi_year"]?["merged"]
        XCTAssertNil(jsonDiff(got, want), jsonDiff(got, want) ?? "")
        XCTAssertEqual(got.array?.count, 2)
    }

    /// Kursanlage wie `upsert_course` nacheinander, dann `ensure_modules`: aktiv ist nur, was laut Regel aktuell ist;
    /// Module nur fuer aktive Kurse; eine eigene Entscheidung (`active_custom`) bleibt beim naechsten Abgleich; danach
    /// die Woche wie Stud.IP
    func testCoursesModulesAndWeekMatchPython() async throws {
        let (fx, clock, today) = try fixture()
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let now = try XCTUnwrap(fx["now"]?.string)
        func row(_ c: JSONValue) -> UniStore.CourseRow {
            UniStore.CourseRow(id: c["id"]?.string ?? "", title: c["title"]?.string ?? "", number: c["number"]?.string,
                               semester: c["semester"]?.string, semesterEnd: c["semester_end"]?.string, semesterEndsAt: c["semester_ends_at"]?.string)
        }
        let coursesIn = fx["courses_in"]?.array ?? []
        let (courses, modules, choice) = try await backend.context.database.transaction { c -> (JSONValue, JSONValue, JSONValue) in
            for x in coursesIn { try UniStore.upsertCourse(c, row(x), now: now, today: today) }
            try LocalModules.ensureModules(c, clock: clock)
            let courses: JSONValue = .array(try c.rows("""
                SELECT id, title, semester, semester_end, semester_ends_at, subject, kind, active, active_custom, module_id
                FROM courses WHERE id LIKE 'w-%' ORDER BY id
                """).map(JSONValue.object))
            let modules: JSONValue = .array(try c.rows("SELECT id, name, semester, color, active, active_custom FROM modules ORDER BY id").map(JSONValue.object))
            try c.execute(fx["user_choice"]?["sql"]?.string ?? "")
            let again = try XCTUnwrap(coursesIn.first { $0["id"] == fx["user_choice"]?["then_upsert"] })
            try UniStore.upsertCourse(c, row(again), now: now, today: today)
            let choice: JSONValue = try c.rows("SELECT id, active, active_custom FROM courses WHERE id='w-alt-23'").first.map(JSONValue.object) ?? .null
            for s in fx["seed"]?.array ?? [] {
                try c.execute(s["sql"]?.string ?? "", (s["params"]?.array ?? []).map { SQLiteValue(json: $0) ?? .null })
            }
            return (courses, modules, choice)
        }
        XCTAssertNil(jsonDiff(courses, fx["courses_after"]), jsonDiff(courses, fx["courses_after"]) ?? "")
        XCTAssertNil(jsonDiff(modules, fx["modules_after"]), jsonDiff(modules, fx["modules_after"]) ?? "")
        XCTAssertNil(jsonDiff(choice, fx["user_choice"]?["course"]), jsonDiff(choice, fx["user_choice"]?["course"]) ?? "")

        let start = try XCTUnwrap(BerlinClock.parseISODate(fx["week"]?["start"]?.string ?? ""))
        let end = try XCTUnwrap(BerlinClock.parseISODate(fx["week"]?["end"]?.string ?? ""))
        let (dated, occ, busy) = try await backend.context.database.withConnection { c -> (JSONValue, JSONValue, JSONValue) in
            let dated: JSONValue = .array(try LocalTimetable.studipDated(c, from: start, to: end).map(JSONValue.object))
            let occ: JSONValue = .array(try LocalTimetable.occurrences(c, from: start, to: end))
            let day = try XCTUnwrap(BerlinClock.parseISODate("2026-11-18"))
            let busy: JSONValue = .array(try LocalFreeWindows.busyBlocks(c, day: day, settings: try LocalSettings.read(c), includePackages: false).map { b in
                ["start": .number(Double(b.start)), "end": .number(Double(b.end)), "kind": .string(b.kind), "title": b.title, "campus": .bool(b.campus)]
            })
            return (dated, occ, busy)
        }
        XCTAssertNil(jsonDiff(dated, fx["week"]?["studip_dated"]), jsonDiff(dated, fx["week"]?["studip_dated"]) ?? "")
        XCTAssertNil(jsonDiff(occ, fx["week"]?["occurrences"]), jsonDiff(occ, fx["week"]?["occurrences"]) ?? "")
        XCTAssertNil(jsonDiff(busy, fx["week"]?["busy_2026_11_18"]), jsonDiff(busy, fx["week"]?["busy_2026_11_18"]) ?? "")

        // ausdruecklich: drei Raeume ein Termin, andere Gruppe fehlt, veraltete Serie fehlt, Ausfall bleibt sichtbar
        let list = occ.array ?? []
        XCTAssertEqual(list.filter { $0["course_id"] == "w-ue-26" }.map { $0["room"]?.string ?? "" },
                       ["Raum F303: Testsaal · Raum 031: e-Classroom · Raum F102"])
        XCTAssertFalse(list.contains { $0["studip_id"] == "e-ue-x" }, "andere Gruppe")
        XCTAssertFalse(list.contains { $0["start"] == "13:45" }, "veraltete Serie ohne Stud.IP-Termin")
        XCTAssertEqual(list.filter { $0["date"] == "2026-11-19" && $0["course_id"] == "w-rt-26" }.map { $0["status"]?.string ?? "" }, ["ausfall"])
    }
}
