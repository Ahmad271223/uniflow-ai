import Foundation
import XCTest
@testable import UniFlowCore

// Antwort auf "Welche Termine besuchst du?" in der Woche (Befund des Inhabers am iPad, 10.11.2026): er waehlte von
// zehn Uebungszeiten nur Freitag 14:15; die Woche zeigte danach drei andere Zeiten als besucht und den Freitag gar
// nicht. Die Antwort muss fuer jedes Vorkommen gelten, egal ob es aus einer verknuepften Serie, einer anderen Serie
// desselben Kurses oder nur aus einem Stud.IP-Einzeltermin stammt, und die gewaehlte Zeit erscheint auch dann, wenn
// ihr Termin in dieser Woche nicht im eigenen Stud.IP-Kalender steht. Daten: erfundene Antworten in
// packages/shared-contracts/fixtures/studip-schedule/kalender (Kurs "k-frage" mit vier Kurszeiten Mo 14:00,
// Di/Mi/Do 16:00). Uhr: Sonntag, 25.10.2026, 14:30.

private let clock = UniFlowClock.fixed(berlin: "2026-10-25T14:30:05")!
private let base = URL(string: "https://studip.test")!
private let courseTitles = [("k-vl", "Testvorlesung Kalender"), ("k-ue", "Übung Testvorlesung Kalender"),
                            ("k-prog", "Übung Testprogrammierung Kalender"), ("k-frei", "Testmathe ohne Kalender"),
                            ("k-frage", "Fragestunden Testmathe"), ("k-tut", "Tutorium Testphysik")]

private func fixture(_ name: String) throws -> Data {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return try Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/studip-schedule/kalender/\(name)"))
}

/// Kalender ohne die Termine `without` (ganze VEVENT-Bloecke)
private func ics(without: Set<String>) throws -> Data {
    let text = String(decoding: try fixture("users-events.ics"), as: UTF8.self)
    var out: [String] = [], block: [String] = []
    var inside = false
    for line in text.components(separatedBy: "\n") {
        if line.hasPrefix("BEGIN:VEVENT") { inside = true; block = [line]; continue }
        if inside {
            block.append(line)
            if line.hasPrefix("END:VEVENT") {
                inside = false
                if !without.contains(where: { id in block.contains { $0.contains("Stud.IP-SEM-\(id)@") } }) { out += block }
            }
            continue
        }
        out.append(line)
    }
    return Data(out.joined(separator: "\n").utf8)
}

private func syncedBackend(withoutInCalendar: Set<String> = []) async throws -> LocalBackend {
    var r: [String: HTTPReply] = [
        "/jsonapi.php/v1/users/u-test/schedule": HTTPReply(status: 200, contentType: "application/vnd.api+json", body: try fixture("users-schedule.json")),
        "/jsonapi.php/v1/users/u-test/courses?page[limit]=100&include=start-semester,end-semester":
            HTTPReply(status: 200, contentType: "application/vnd.api+json", body: try fixture("users-courses.json")),
        "/jsonapi.php/v1/users/u-test/events.ics": HTTPReply(status: 200, contentType: "text/calendar; charset=utf-8", body: try ics(without: withoutInCalendar)),
    ]
    for (id, _) in courseTitles {
        r["/jsonapi.php/v1/courses/\(id)/events?page[limit]=200"] = HTTPReply(status: 200, contentType: "application/vnd.api+json", body: try fixture("course-events-\(id).json"))
    }
    let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
    let client = StudIPClient(base: base, transport: StubTransport(r), pauseMillis: 0)
    let d = await StudIPScheduleStore.fetch(client: client, userID: "u-test", courses: courseTitles.map { StudIPCourse(id: $0.0, title: $0.1, semesterTitle: "WiSe 2026/27") })
    _ = try await backend.context.database.transaction { try StudIPScheduleStore.store(d, in: $0, clock: clock) }
    return backend
}

/// Nur Donnerstag 16:00 (cy-frage-4) besucht, die drei anderen Kurszeiten abgewaehlt
private func answerOnlyThursday(_ backend: LocalBackend) async throws {
    let r = await backend.handle(LocalRequest(method: "POST", path: "/api/timetable/studip-questions/times",
                                              body: (["course_id": "k-frage", "attend": ["cy-frage-4"]] as JSONValue).serialized()))
    XCTAssertEqual(r.status, 200)
}

private let monday = BerlinClock.parseISODate("2026-10-26")!

/// Vorkommen des Kurses in der Woche ab 26.10. als "Datum Beginn Status"
private func week(_ backend: LocalBackend, includeSkipped: Bool = true) async throws -> [String] {
    try await backend.context.database.transaction { c in
        try LocalTimetable.occurrences(c, from: monday, to: monday + 6, includeSkipped: includeSkipped)
            .filter { $0["title"] == "Fragestunden Testmathe" }
            .map { "\($0["date"]?.string ?? "") \($0["start"]?.string ?? "") \($0["status"]?.string ?? "")" }
    }
}

private let expected = ["2026-10-26 14:00 nicht_teilnahme", "2026-10-27 16:00 nicht_teilnahme",
                        "2026-10-28 16:00 nicht_teilnahme", "2026-10-29 16:00 teilnahme"]

final class StudIPCalendarAnswerWeekTests: XCTestCase {

    /// Grundfall: verknuepfte Serien, alle Termine im Kalender
    func testAnswerGreysSkippedTimesAndKeepsTheChosenOne() async throws {
        let backend = try await syncedBackend()
        try await answerOnlyThursday(backend)
        let w = try await week(backend)
        XCTAssertEqual(w, expected)
        let shown = try await week(backend, includeSkipped: false)
        XCTAssertEqual(shown, ["2026-10-29 16:00 teilnahme"])
    }

    /// Die gewaehlte Zeit steht diese Woche nicht im eigenen Stud.IP-Kalender (andere Wochen schon): sie erscheint
    /// trotzdem (vorher fiel sie weg, weil Stud.IP-Serien ohne Kalendertermin an diesem Tag ausgeblendet werden)
    func testChosenTimeShowsEvenWithoutCalendarEntryThisWeek() async throws {
        let backend = try await syncedBackend(withoutInCalendar: ["ev-frage-4-1029"])
        try await answerOnlyThursday(backend)
        let w = try await week(backend)
        XCTAssertEqual(w, expected)
    }

    /// Eine Serie desselben Kurses, die nicht mit der Kurszeit verknuepft ist (z. B. frueher uebernommen), wird fuer
    /// eine abgewaehlte Zeit ebenfalls grau; ein von Hand auf "besucht" gesetzter Tag bleibt besucht
    func testUnlinkedSeriesFollowsTheAnswer() async throws {
        let backend = try await syncedBackend()
        try await answerOnlyThursday(backend)
        try await backend.context.database.transaction { c in
            let id = try XCTUnwrap(try c.queryOne("SELECT id FROM course_events WHERE title='Fragestunden Testmathe' AND weekday=0")?["id"]?.int64)
            try c.execute("DELETE FROM studip_timetable_links WHERE event_id=?", [.integer(id)])
            try c.execute("UPDATE course_events SET attend=1 WHERE id=?", [.integer(id)])
        }
        var w = try await week(backend)
        XCTAssertEqual(w, expected)

        try await backend.context.database.transaction { c in
            let id = try XCTUnwrap(try c.queryOne("SELECT id FROM course_events WHERE title='Fragestunden Testmathe' AND weekday=0")?["id"]?.int64)
            try LocalTimetable.setException(c, eventID: .integer(id), date: "2026-10-26", type: "attend", clock: clock)
        }
        w = try await week(backend)
        XCTAssertEqual(w.first, "2026-10-26 14:00 teilnahme", "eigene Ausnahme fuer den Tag gilt vor der Antwort")
    }

    /// Ohne Serie, nur Stud.IP-Einzeltermine im Kalender: abgewaehlte Zeiten sind grau, die gewaehlte bleibt
    func testDatedOnlyFollowsTheAnswer() async throws {
        let backend = try await syncedBackend()
        try await answerOnlyThursday(backend)
        try await backend.context.database.transaction { c in
            try c.execute("DELETE FROM studip_timetable_links WHERE event_id IN (SELECT id FROM course_events WHERE title='Fragestunden Testmathe')")
            try c.execute("DELETE FROM course_events WHERE title='Fragestunden Testmathe'")
        }
        let w = try await week(backend)
        XCTAssertEqual(w, expected)
    }

    /// Abgewaehlte Zeit ist frei fuer Lernbloecke, die gewaehlte nicht
    func testSkippedTimeIsFreeForStudyBlocks() async throws {
        let backend = try await syncedBackend()
        try await answerOnlyThursday(backend)
        try await backend.context.database.transaction { c in
            let s = try LocalSettings.read(c)
            let mo = try LocalFreeWindows.busyBlocks(c, day: monday, settings: s, includePackages: false).filter { $0.kind == "event" }
            XCTAssertFalse(mo.contains { $0.title == "Fragestunden Testmathe" }, "Montag abgewaehlt")
            let th = try LocalFreeWindows.busyBlocks(c, day: monday + 3, settings: s, includePackages: false).filter { $0.kind == "event" }
            XCTAssertTrue(th.contains { $0.title == "Fragestunden Testmathe" && $0.start == 16 * 60 }, "Donnerstag besucht")
        }
    }
}
