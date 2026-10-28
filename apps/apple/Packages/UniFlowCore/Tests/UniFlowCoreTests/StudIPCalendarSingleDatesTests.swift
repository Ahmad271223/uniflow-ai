import Foundation
import XCTest
@testable import UniFlowCore

// Eigener Stud.IP-Kalender bei Einzelterminen ohne Kurszeiten: dieselbe Regel wie Python (`timetable._apply_calendar`,
// `remove_foreign_series`, `_same_series`, PC-Stand 8cc7463) und dieselben Erwartungen wie tests/test_studip_calendar.py
// auf derselben erfundenen Fixture packages/shared-contracts/fixtures/studip-schedule/kalender. Die Kurszeiten
// (seminar-cycle-dates) sind hier aus users-schedule.json entfernt: Python liest sie nicht, das Geraet nimmt dann wie
// Python nur die Einzeltermine. Uhr: Sonntag, 25.10.2026, 14:30 (Europe/Berlin), wie FETCHED im Python-Test.

private let clock = UniFlowClock.fixed(berlin: "2026-10-25T14:30:05")!

private func kalender(_ name: String) throws -> Data {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return try Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/studip-schedule/kalender/\(name)"))
}

private let courseTitles = [("k-vl", "Testvorlesung Kalender"), ("k-ue", "Übung Testvorlesung Kalender"),
                            ("k-prog", "Übung Testprogrammierung Kalender"), ("k-frei", "Testmathe ohne Kalender"),
                            ("k-frage", "Fragestunden Testmathe"), ("k-tut", "Tutorium Testphysik")]
private let courses = courseTitles.map { StudIPCourse(id: $0.0, title: $0.1, semesterTitle: "WiSe 2026/27") }

/// `WITH_CALENDAR` aus tests/test_studip_calendar.py: wie `withCalendar` in StudIPCalendarTests, dazu die ganz
/// vergangene Kurszeit als zwei Einzeltermine (Fr 12:00), weil ohne Kurszeiten Einzeltermine zusammengefasst werden
private let withCalendar = [
    "Testvorlesung Kalender|0|10:00|Hörsaal K1|1",
    "Fragestunden Testmathe|0|14:00|Raum F1|1",
    "Übung Testvorlesung Kalender|1|08:00|Raum U1|1",
    "Fragestunden Testmathe|1|16:00|Raum F1|1",
    "Übung Testvorlesung Kalender|2|08:00|Raum U3|1",
    "Fragestunden Testmathe|2|16:00|Raum F1|1",
    "Lerngruppe Kalender alle 2 Wochen|2|18:00||1",
    "Tutorium Testphysik|3|08:00|Raum T1|1",
    "Fragestunden Testmathe|3|16:00|Raum F1|1",
    "Übung Testprogrammierung Kalender|4|09:40|Hörsaal K2|1",
    "Testvorlesung Kalender|4|12:00|Hörsaal K1|1",
    "Testvorlesung Kalender|4|12:00|Hörsaal K1|1",
]

final class StudIPCalendarSingleDatesTests: XCTestCase {

    /// Antworten der Fixture; users/{id}/schedule nur mit den persoenlichen Eintraegen, ohne Kalender 404
    private func routes(calendar: Bool) throws -> [String: HTTPReply] {
        var schedule = try JSONValue.parse(kalender("users-schedule.json")).object ?? [:]
        schedule["data"] = .array((schedule["data"]?.array ?? []).filter { $0["type"]?.string == "schedule-entries" })
        let api = "application/vnd.api+json"
        var r: [String: HTTPReply] = [
            "/jsonapi.php/v1/users/u-test/schedule": HTTPReply(status: 200, contentType: api, body: JSONValue.object(schedule).serialized()),
            "/jsonapi.php/v1/users/u-test/courses?page[limit]=100&include=start-semester,end-semester": HTTPReply(status: 200, contentType: api, body: try kalender("users-courses.json")),
        ]
        for (id, _) in courseTitles {
            r["/jsonapi.php/v1/courses/\(id)/events?page[limit]=200"] = HTTPReply(status: 200, contentType: api, body: try kalender("course-events-\(id).json"))
        }
        if calendar {
            r["/jsonapi.php/v1/users/u-test/events.ics"] = HTTPReply(status: 200, contentType: "text/calendar; charset=utf-8", body: try kalender("users-events.ics"))
        }
        return r
    }

    /// Abgleich wie StudIPScheduleSync (speichern, Kalender, auto_import in einer Transaktion)
    @discardableResult
    private func sync(_ backend: LocalBackend, calendar: Bool) async throws -> StudIPScheduleResult {
        let client = StudIPClient(base: URL(string: "https://studip.test")!, transport: StubTransport(try routes(calendar: calendar)), pauseMillis: 0)
        let d = await StudIPScheduleStore.fetch(client: client, userID: "u-test", courses: courses)
        XCTAssertEqual(d.cycles?.count, 0, "ohne Kurszeiten wie Python")
        return try await backend.context.database.transaction { try StudIPScheduleStore.store(d, in: $0, clock: clock) }
    }

    private func autoImport(_ backend: LocalBackend) async throws -> StudIPScheduleImport.AutoResult {
        try await backend.context.database.transaction { try StudIPScheduleImport.autoImport($0, clock: clock) }
    }

    private func entries(_ backend: LocalBackend) async throws -> [LocalTimetableImport.Entry] {
        try await backend.context.database.transaction { try LocalTimetableImport.studipEntries($0, clock: clock) }
    }

    /// `_series(conn)`: "Titel|Wochentag|Beginn|Raum|attend"
    private func series(_ backend: LocalBackend) async throws -> [String] {
        try await backend.context.database.rows("SELECT title, weekday, start_time, room, attend FROM course_events ORDER BY weekday, start_time, title").map { r in
            ["title", "weekday", "start_time", "room", "attend"].map { k in r[k].map { $0 == .null ? "" : LocalTimetable.text($0) } ?? "" }.joined(separator: "|")
        }
    }

    private func open() async throws -> LocalBackend { try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock) }

    /// test_calendar_picks_own_groups: eigene Gruppen, "Hauptveranst.", alle Fragestunden; fremde Gruppen und der Kurs
    /// ohne Kalendertermine nicht; zweiter Abgleich: nichts doppelt, nichts entfernt
    func testCalendarPicksOwnGroups() async throws {
        let backend = try await open()
        let r = try await sync(backend, calendar: true)
        let s = try await series(backend)
        XCTAssertEqual(s, withCalendar)
        XCTAssertEqual(r.newEvents, 12)
        XCTAssertEqual(r.removedEvents, 0)
        let again = try await autoImport(backend)
        XCTAssertTrue(again.calendar)
        XCTAssertEqual(again.new, 0)
        XCTAssertEqual(again.removed, 0)
        let s2 = try await series(backend)
        XCTAssertEqual(s2, withCalendar)

        // Vorschau wie studip_entries: je Serie die Entscheidung des Kalenders
        let list = try await entries(backend)
        let shown = list.map { e in
            "\(e["title"]?.string ?? "")|\(e["weekday"]?.int ?? -1)|\(e["start_time"]?.string ?? "")|\(e["room"]?.string ?? "")|"
                + "\(e["selected"] == true ? 1 : 0)|\(e["calendar"].map { $0.string ?? "null" } ?? "-")"
        }
        XCTAssertEqual(shown, [
            "Testvorlesung Kalender|0|10:00|Hörsaal K1|1|eigen",
            "Übung Testprogrammierung Kalender|0|12:00|Raum P1|0|fremd",
            "Fragestunden Testmathe|0|14:00|Raum F1|1|eigen",
            "Übung Testvorlesung Kalender|1|08:00|Raum U1|1|eigen",
            "Testmathe ohne Kalender|1|10:00|Hörsaal K3|0|kurs_fehlt",
            "Übung Testprogrammierung Kalender|1|12:00|Raum P2|0|fremd",
            "Übung Testvorlesung Kalender|1|14:00|Raum U2|0|fremd",
            "Fragestunden Testmathe|1|16:00|Raum F1|1|eigen",
            "Übung Testvorlesung Kalender|2|08:00|Raum U3|1|eigen",
            "Übung Testprogrammierung Kalender|2|12:00|Raum P3|0|fremd",
            "Fragestunden Testmathe|2|16:00|Raum F1|1|eigen",
            "Lerngruppe Kalender alle 2 Wochen|2|18:00||1|-",
            "Tutorium Testphysik|3|08:00|Raum T1|1|eigen",
            "Testmathe ohne Kalender|3|10:00|Hörsaal K3|0|kurs_fehlt",
            "Übung Testprogrammierung Kalender|3|12:00|Raum P4|0|fremd",
            "Fragestunden Testmathe|3|16:00|Raum F1|1|eigen",
            "Übung Testprogrammierung Kalender|4|09:40|Hörsaal K2|1|eigen",
            "Testvorlesung Kalender|4|12:00|Hörsaal K1|1|null",
            "Testvorlesung Kalender|4|12:00|Hörsaal K1|1|null",
        ], "Stand von app/timetable.py auf derselben Fixture")
        let frei = try XCTUnwrap(list.first { $0["course_id"] == "k-frei" })
        XCTAssertTrue(frei["hint"]?.string?.contains("Stud.IP-Kalender") ?? false, "bleibt in der Vorschau wählbar")
        XCTAssertTrue(list.allSatisfy { $0["event_id"] == nil }, "event_id nur intern wie in Python")
        // Abweichung des Geraets (Bitte an die PC-Sitzung): was der Kalender entschieden hat, ist keine offene Gruppe
        XCTAssertEqual(again.pendingGroups, 0, "fremd und kurs_fehlt zaehlen nicht (Python gleich seit 28.10.2026)")
    }

    /// test_without_calendar_the_old_rule_stays
    func testWithoutCalendarTheOldRuleStays() async throws {
        let backend = try await open()
        let r = try await sync(backend, calendar: false)
        let s = try await series(backend)
        XCTAssertGreaterThan(r.pendingGroups, 0, "Gruppen bleiben zur Auswahl")
        XCTAssertTrue(s.contains("Testmathe ohne Kalender|1|10:00|Hörsaal K3|1"), "ohne Kalender bisherige Regel")
        XCTAssertFalse(s.contains { $0.hasPrefix("Fragestunden") }, "vier Serien gelten ohne Kalender als Gruppen")
        XCTAssertFalse(s.contains { $0.hasPrefix("Übung Testprogrammierung Kalender") }, "der Fehler aus der Windows-App")
        let again = try await autoImport(backend)
        XCTAssertFalse(again.calendar)
        let list = try await entries(backend)
        XCTAssertTrue(list.allSatisfy { $0["calendar"] == nil }, "ohne Kalender kein Schlüssel calendar wie in Python")
    }

    /// test_calendar_removes_what_is_not_own_but_keeps_user_changes
    func testCalendarRemovesWhatIsNotOwnButKeepsUserChanges() async throws {
        let backend = try await open()
        try await sync(backend, calendar: false)
        let thu = try await backend.context.database.scalar("SELECT id FROM course_events WHERE course_id='k-frei' AND weekday=3")
        _ = try await backend.context.database.execute("UPDATE course_events SET attend=0 WHERE id=?", [.integer(Int64(try XCTUnwrap(thu?.int)))])
        let r = try await sync(backend, calendar: true)
        let s = try await series(backend)
        XCTAssertEqual(r.removedEvents, 1, "die unveränderte Serie des Kurses ohne Kalendertermine")
        XCTAssertFalse(s.contains("Testmathe ohne Kalender|1|10:00|Hörsaal K3|1"))
        XCTAssertTrue(s.contains("Testmathe ohne Kalender|3|10:00|Hörsaal K3|0"), "eigene Änderung bleibt")
        XCTAssertTrue(s.contains("Fragestunden Testmathe|0|14:00|Raum F1|1"), "jetzt eindeutig")
        XCTAssertTrue(s.contains("Übung Testprogrammierung Kalender|4|09:40|Hörsaal K2|1"))
        XCTAssertTrue(s.contains("Tutorium Testphysik|3|08:00|Raum T1|1"))
        XCTAssertFalse(s.contains { $0.contains("Raum T2") })
        let links = try await backend.context.database.scalar("SELECT COUNT(*) FROM studip_timetable_links WHERE entry_key LIKE 'series:k-frei|%'")
        XCTAssertEqual(links?.int, 1, "Verknüpfung der entfernten Serie weg, die geänderte bleibt verknüpft")
    }

    /// test_hand_confirmed_preview_is_never_removed: von Hand gewaehlt heisst "studip-manual" und bleibt
    func testHandConfirmedPreviewIsNeverRemoved() async throws {
        let backend = try await open()
        try await sync(backend, calendar: true)
        let chosen = try await entries(backend).filter { $0["course_id"] == "k-frei" }.prefix(1).map(JSONValue.object)
        let body: JSONValue = ["entries": .array(Array(chosen)), "source": "studip"]
        let res = await backend.handle(LocalRequest(method: "POST", path: "/api/timetable/import/confirm",
                                                    headers: ["Content-Type": "application/json"], body: body.serialized()))
        XCTAssertEqual(res.status, 200)
        XCTAssertEqual(res.json?["new"], 1)
        let source = try await backend.context.database.scalar("SELECT source FROM course_events WHERE course_id='k-frei'")
        XCTAssertEqual(source, .text("studip-manual"))
        let again = try await autoImport(backend)
        XCTAssertEqual(again.removed, 0)
        let n = try await backend.context.database.scalar("SELECT COUNT(*) FROM course_events WHERE course_id='k-frei'")
        XCTAssertEqual(n?.int, 1)
    }

    /// test_decisions_survive_when_the_dates_are_past: am Semesterende gilt die gespeicherte Entscheidung weiter
    func testDecisionsSurviveWhenTheDatesArePast() async throws {
        let backend = try await open()
        try await sync(backend, calendar: true)
        _ = try await backend.context.database.execute("UPDATE studip_calendar_dates SET fetched_at='2027-03-01T08:00:00'")
        let r = try await autoImport(backend)
        XCTAssertEqual(r.new, 0)
        XCTAssertEqual(r.removed, 0)
        let s = try await series(backend)
        XCTAssertEqual(s, withCalendar)
        let v = try await backend.context.database.scalar("SELECT relevant FROM studip_series_relevance WHERE series='k-prog|0|12:00|13:00'")
        XCTAssertEqual(v?.int, 0)
    }

    /// test_diff_same_course_same_day_needs_overlapping_time: zwei Serien desselben Kurses am selben Tag sind keine
    /// Doppel; jede vorhandene Serie passt hoechstens zu einem Eintrag
    func testDiffSameCourseSameDayNeedsOverlappingTime() async throws {
        let backend = try await open()
        _ = try await backend.context.database.execute("""
            INSERT INTO course_events(course_id, title, kind, weekday, start_time, end_time, rrule, attend, source, created_at)
            VALUES ('k-diff', 'Mathe I', 'vorlesung', 0, '10:00', '11:30', 'weekly', 1, 'studip', '2026-10-27')
            """)
        func e(_ st: String, _ en: String, course: JSONValue = "k-diff", title: String = "Mathe I") -> LocalTimetableImport.Entry {
            ["title": .string(title), "weekday": 0, "start_time": .string(st), "end_time": .string(en), "course_id": course]
        }
        func diff(_ list: [LocalTimetableImport.Entry]) async throws -> JSONValue {
            try await backend.context.database.withConnection { try LocalTimetableImport.diffAgainstExisting($0, list) }
        }
        var d = try await diff([e("10:00", "11:30"), e("14:00", "15:30")])
        XCTAssertEqual(d["same"]?.array?.count, 1)
        XCTAssertEqual(d["new"]?.array?.compactMap { $0["start_time"]?.string }, ["14:00"], "Fragestunde am Nachmittag ist neu")
        d = try await diff([e("10:15", "11:45")])
        XCTAssertEqual(d["changed"]?.array?.count, 1, "überlappend = geändert")
        XCTAssertEqual(d["changed"]?.array?.first?["old_start"], "10:00")
        d = try await diff([e("10:00", "11:30", course: "k-anders")])
        XCTAssertEqual(d["new"]?.array?.count, 1, "anderer Kurs, gleiche Zeit und gleicher Titel: eigene Serie")
        d = try await diff([e("10:00", "11:30", course: .null, title: "Mathe I (ICS)")])
        XCTAssertEqual(d["new"]?.array?.count, 1)
        XCTAssertEqual(d["same"]?.array?.count, 0)
        d = try await diff([e("10:00", "11:30", course: .null)])
        XCTAssertEqual(d["same"]?.array?.count, 1, "ohne Kurs (Kalenderdatei) zählt der Titel")
        d = try await diff([e("10:00", "11:30"), e("10:00", "11:30")])
        XCTAssertEqual(d["same"]?.array?.count, 1)
        XCTAssertEqual(d["new"]?.array?.count, 1, "eine vorhandene Serie passt nur zu einem Eintrag")
        // jede Zeile mit vorhandener Serie traegt deren existing_id selbst, die neue Zeile keine (196555e)
        let rows = try await backend.context.database.withConnection { c -> [LocalTimetableImport.Entry] in
            var list = [e("10:00", "11:30"), e("10:00", "11:30")]
            _ = try LocalTimetableImport.diffAgainstExisting(c, marking: &list)
            return list
        }
        XCTAssertEqual(rows.map { $0["existing_id"] }, [.number(1), nil])
        XCTAssertEqual(d["removed"]?.array?.count, 0)
        d = try await diff([])
        XCTAssertEqual(d["removed"]?.array?.compactMap { $0["title"]?.string }, ["Mathe I"])
        // gleiche Zeit hat Vorrang vor bloss ueberlappender, auch wenn die ueberlappende zuerst steht
        _ = try await backend.context.database.execute("UPDATE course_events SET start_time='09:30', end_time='11:00'")
        _ = try await backend.context.database.execute("""
            INSERT INTO course_events(course_id, title, kind, weekday, start_time, end_time, rrule, attend, source, created_at)
            VALUES ('k-diff', 'Mathe I', 'vorlesung', 0, '10:00', '11:30', 'weekly', 1, 'studip', '2026-10-27')
            """)
        d = try await diff([e("10:00", "11:30")])
        XCTAssertEqual(d["same"]?.array?.first?["existing_id"], 2)
        XCTAssertEqual(d["removed"]?.array?.compactMap { $0["id"]?.int }, [1])
    }
}
