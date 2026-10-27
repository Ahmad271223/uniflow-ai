import Foundation
import XCTest
@testable import UniFlowCore

// Eigener Stud.IP-Kalender (users/{id}/events.ics) als Auswahl fuer den Stundenplan: nur die Termine, die Stud.IP
// dem Nutzer selbst zeigt (eigene Gruppen, Kurse mit Kalenderbindung). Erfundene Antworten in
// packages/shared-contracts/fixtures/studip-schedule/kalender. Uhr: Sonntag, 25.10.2026, 14:30 (Europe/Berlin).

private let clock = UniFlowClock.fixed(berlin: "2026-10-25T14:30:05")!
private let base = URL(string: "https://studip.test")!

private func kalender(_ name: String, type: String = "application/vnd.api+json") throws -> HTTPReply {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    let data = try Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/studip-schedule/kalender/\(name)"))
    return HTTPReply(status: 200, contentType: type, body: data)
}

/// Kurse wie nach dem Datei-Abgleich (StudIPClient.courses), Titel wie in users-courses.json
private let courseTitles = [("k-vl", "Testvorlesung Kalender"), ("k-ue", "Übung Testvorlesung Kalender"),
                            ("k-prog", "Übung Testprogrammierung Kalender"), ("k-frei", "Testmathe ohne Kalender"),
                            ("k-frage", "Fragestunden Testmathe"), ("k-tut", "Tutorium Testphysik")]
private let courseIDs = courseTitles.map(\.0)
private let courses = courseTitles.map { StudIPCourse(id: $0.0, title: $0.1, semesterTitle: "WiSe 2026/27") }
private let icsPath = "/jsonapi.php/v1/users/u-test/events.ics"

/// Antworten je Pfad; ohne `calendar` fehlt der Kalender (404 wie eine alte Stud.IP-Fassung)
private func routes(calendar: Bool = true, _ replace: [String: HTTPReply] = [:]) throws -> [String: HTTPReply] {
    var r: [String: HTTPReply] = [
        "/jsonapi.php/v1/users/u-test/schedule": try kalender("users-schedule.json"),
        "/jsonapi.php/v1/users/u-test/courses?page[limit]=100&include=start-semester": try kalender("users-courses.json"),
    ]
    for id in courseIDs { r["/jsonapi.php/v1/courses/\(id)/events?page[limit]=200"] = try kalender("course-events-\(id).json") }
    if calendar { r[icsPath] = try kalender("users-events.ics", type: "text/calendar; charset=utf-8") }
    for (k, v) in replace { r[k] = v }
    return r
}

/// Abgleich wie StudIPScheduleSync: laden, dann in einer Transaktion speichern und uebernehmen
private func sync(_ backend: LocalBackend, calendar: Bool = true, _ replace: [String: HTTPReply] = [:]) async throws
    -> (StudIPScheduleDownload, StudIPScheduleResult) {
    let client = StudIPClient(base: base, transport: StubTransport(try routes(calendar: calendar, replace)), pauseMillis: 0)
    let d = await StudIPScheduleStore.fetch(client: client, userID: "u-test", courses: courses)
    let r = try await backend.context.database.transaction { try StudIPScheduleStore.store(d, in: $0, clock: clock) }
    return (d, r)
}

private func open() async throws -> LocalBackend { try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock) }

/// Serien als "Titel|Wochentag|Beginn|Raum|attend"
private func series(_ backend: LocalBackend) async throws -> [String] {
    try await backend.context.database.rows("SELECT * FROM course_events ORDER BY weekday, start_time, title").map { e in
        ["title", "weekday", "start_time", "room", "attend"].map { e[$0].map(LocalTimetable.text) ?? "None" }.joined(separator: "|")
    }
}

private func call(_ backend: LocalBackend, _ method: String, _ path: String, _ body: JSONValue? = nil) async -> LocalResponse {
    await backend.handle(LocalRequest(method: method, path: path, body: body?.serialized() ?? Data()))
}

private func questions(_ backend: LocalBackend) async throws -> JSONValue {
    let r = await call(backend, "GET", "/api/timetable/studip-questions")
    XCTAssertEqual(r.status, 200)
    return try XCTUnwrap(r.json)
}

/// Erwarteter Stundenplan mit Kalender: eigene Gruppen, Kurszeit "Hauptveranst." neben vielen Gruppen, alle vier
/// Fragestunden, eine Serie fuer zwei Raeume zur selben Zeit, die vergangene Einfuehrung wie bisher, der eigene Eintrag
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
]

final class StudIPCalendarTests: XCTestCase {

    func testDateIDsOnlyFromCourseDates() {
        let ics = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:Stud.IP-SEM-abc@studip.test\r\nDTSTART;TZID=Europe/Berlin:20261026T100000\r\nEND:VEVENT\r\n"
            + "BEGIN:VEVENT\r\nUID:Stud.IP-SEM-de\r\n f@studip.test\r\nDTSTART:20261027T090000Z\r\nEND:VEVENT\r\n"
            + "BEGIN:VEVENT\r\nUID:Stud.IP-0123@studip.test\r\nDTSTART:20261028T090000Z\r\nEND:VEVENT\r\n"
            + "BEGIN:VEVENT\r\nUID:Stud.IP-SEM-abc@studip.test\r\nDTSTART:20261102T090000Z\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
        XCTAssertEqual(StudIPCalendar.dateIDs(ics: ics), ["abc", "def"], "eigene Kalendertermine fehlen, gefaltete Zeilen, keine Doppelten")
    }

    /// Kalender bekannt: genau die Termine aus Stud.IP-Kalender, keine Gruppenwahl offen, der Kurs ohne Kalendertermine
    /// und der Kurs mit vier Serien je Woche als Frage
    func testCalendarPicksOwnDates() async throws {
        let backend = try await open()
        let (d, r) = try await sync(backend)
        XCTAssertNil(d.calendarError)
        XCTAssertEqual(d.calendar?.count, 44, "Kurstermine ab jetzt samt Ausfall-Eintrag, ohne eigenen Termin")
        XCTAssertEqual(r, StudIPScheduleResult(newEvents: 11, pendingGroups: 0, cycles: 19, events: 113, removedEvents: 0, openQuestions: 2))
        let v1 = try await series(backend)
        XCTAssertEqual(v1, withCalendar)

        let decisions = try await backend.context.database.withConnection { try StudIPCalendar.decisions($0) }
        XCTAssertEqual(decisions["cy-ue-2"], 0, "fremde Gruppe")
        XCTAssertEqual(decisions["cy-ue-3a"], 0, "erster Teil der Gruppe, nicht im Kalender")
        XCTAssertEqual(decisions["cy-ue-3b"], 2, "zweiter Teil: gleiche Zeit wie der erste, der Raum entscheidet")
        XCTAssertEqual(decisions["cy-frei-1"], 0)
        XCTAssertEqual(decisions["cy-tut-1"], 2, "Raum passt")
        XCTAssertEqual(decisions["cy-tut-2"], 0, "gleiche Zeit, anderer Raum")
        XCTAssertNil(decisions["cy-vl-2"], "ganz vergangen: unentschieden")

        // Ausfall laut Stud.IP bleibt
        let vl = try await backend.context.database.scalar("SELECT id FROM course_events WHERE title='Testvorlesung Kalender' AND weekday=0")
        let ex = try await backend.context.database.rows("SELECT date, note FROM event_exceptions WHERE event_id=?", [.integer(Int64(try XCTUnwrap(vl?.int)))])
        XCTAssertEqual(ex.map { $0["date"]?.string ?? "" }, ["2026-11-16"])

        let q = try await questions(backend)
        XCTAssertEqual(q["hidden"]?.array?.map { $0["course_id"]?.string ?? "" }, ["k-frei"])
        XCTAssertEqual(q["hidden"]?.array?.first?["title"]?.string, "Testmathe ohne Kalender")
        XCTAssertEqual(q["busy"]?.array?.map { $0["course_id"]?.string ?? "" }, ["k-frage"])
        XCTAssertEqual(q["busy"]?.array?.first?["times"]?.array?.map { $0["attend"] == true }, [true, true, true, true], "alle vorausgewählt")

        let status = await call(backend, "GET", "/api/timetable/auto-status")
        XCTAssertEqual(status.json?["pending_groups"], 0)

        // zweiter Abgleich: nichts doppelt, nichts entfernt
        let (_, again) = try await sync(backend)
        XCTAssertEqual(again.newEvents, 0)
        XCTAssertEqual(again.removedEvents, 0)
        let v2 = try await series(backend)
        XCTAssertEqual(v2, withCalendar)
    }

    /// Ohne Kalender (404, alte Stud.IP-Fassung) bleibt die bisherige Regel, mit ehrlichem Hinweis
    func testFallbackWithoutCalendar() async throws {
        let backend = try await open()
        let (d, r) = try await sync(backend, calendar: false)
        XCTAssertNil(d.calendar)
        XCTAssertNotNil(d.calendarError)
        XCTAssertEqual(r.openQuestions, 0)
        XCTAssertGreaterThan(r.pendingGroups, 0, "Gruppen bleiben zur Auswahl")
        let s = try await series(backend)
        XCTAssertTrue(s.contains("Testmathe ohne Kalender|1|10:00|Hörsaal K3|1"), "ohne Kalender bisherige Regel")
        XCTAssertFalse(s.contains { $0.hasPrefix("Fragestunden") }, "vier Kurszeiten gelten als Gruppen")
        let table = try await backend.context.database.scalar("SELECT COUNT(*) FROM sqlite_master WHERE name='studip_cycle_relevance'")
        XCTAssertEqual(table?.int, 0)

        // Kalender ohne Veranstaltungstermine entscheidet nichts
        let empty = HTTPReply(status: 200, contentType: "text/calendar", body: Data("BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n".utf8))
        let (d2, _) = try await sync(backend, [icsPath: empty])
        XCTAssertNil(d2.calendar)
        XCTAssertEqual(d2.calendarError, "Stud.IP-Kalender ohne Veranstaltungstermine")
        let v3 = try await series(backend)
        XCTAssertEqual(v3, s)

        // Anmeldeseite statt Kalender: Sitzung abgelaufen, danach keine Einzeltermine mehr
        let login = HTTPReply(status: 200, contentType: "text/html", body: Data("<html>Login</html>".utf8))
        let (d3, _) = try await sync(backend, [icsPath: login])
        XCTAssertTrue(d3.sessionExpired)
        XCTAssertTrue(d3.events.isEmpty)
    }

    /// Erst ohne Kalender uebernommen, dann mit: was nicht im Kalender steht, verschwindet; eigene Aenderungen bleiben
    func testCalendarRemovesWhatIsNotOwnButKeepsUserChanges() async throws {
        let backend = try await open()
        _ = try await sync(backend, calendar: false)
        // der Nutzer hat eine Serie des Kurses ohne Kalendertermine auf "nicht besuchen" gesetzt
        let kept = try await backend.context.database.scalar("SELECT id FROM course_events WHERE title='Testmathe ohne Kalender' AND weekday=3")
        _ = try await backend.context.database.execute("UPDATE course_events SET attend=0 WHERE id=?", [.integer(Int64(try XCTUnwrap(kept?.int)))])

        let (_, r) = try await sync(backend)
        XCTAssertEqual(r.removedEvents, 1, "die unveränderte Serie des Kurses ohne Kalendertermine")
        let s = try await series(backend)
        XCTAssertFalse(s.contains("Testmathe ohne Kalender|1|10:00|Hörsaal K3|1"))
        XCTAssertTrue(s.contains("Testmathe ohne Kalender|3|10:00|Hörsaal K3|0"), "eigene Änderung bleibt")
        XCTAssertTrue(s.contains("Fragestunden Testmathe|0|14:00|Raum F1|1"), "jetzt eindeutig")
        XCTAssertTrue(s.contains("Tutorium Testphysik|3|08:00|Raum T1|1"))
        XCTAssertFalse(s.contains { $0.hasPrefix("Tutorium Testphysik") && $0.contains("Raum T2") })
    }

    /// Frage A: Kurs ohne Kalendertermine; die Antwort gilt bei jedem Abgleich weiter
    func testHiddenCourseAnswerIsRemembered() async throws {
        let backend = try await open()
        _ = try await sync(backend)
        let take = await call(backend, "POST", "/api/timetable/studip-questions/course", ["course_id": "k-frei", "include": true])
        XCTAssertEqual(take.status, 200)
        XCTAssertEqual(take.json?["new"], 2, "beide Vorlesungen wie mit der bisherigen Regel")
        var s = try await series(backend)
        XCTAssertTrue(s.contains("Testmathe ohne Kalender|1|10:00|Hörsaal K3|1"))
        XCTAssertTrue(s.contains("Testmathe ohne Kalender|3|10:00|Hörsaal K3|1"))
        let v4 = try await questions(backend)
        XCTAssertEqual(v4["hidden"]?.array?.count, 0)

        let (_, again) = try await sync(backend)
        XCTAssertEqual(again.removedEvents, 0, "übernommen bleibt übernommen")
        XCTAssertEqual(again.newEvents, 0, "nichts doppelt")
        XCTAssertEqual(again.openQuestions, 1, "nur noch die Fragestunden")
        s = try await series(backend)
        XCTAssertEqual(s.filter { $0.hasPrefix("Testmathe ohne Kalender") }.count, 2)

        // Weglassen in einer anderen Datenbank (anderer Nutzer oder andere Hochschule): dort eigene Antwort
        let other = try await open()
        _ = try await sync(other)
        let v5 = try await questions(other)
        XCTAssertEqual(v5["hidden"]?.array?.count, 1, "Antworten je Datenbank getrennt")
        let drop = await call(other, "POST", "/api/timetable/studip-questions/course", ["course_id": "k-frei", "include": false])
        XCTAssertEqual(drop.status, 200)
        let (_, r) = try await sync(other)
        XCTAssertEqual(r.openQuestions, 1)
        let v6 = try await series(other)
        XCTAssertFalse(v6.contains { $0.hasPrefix("Testmathe ohne Kalender") })
        let v7 = try await series(backend)
        XCTAssertTrue(v7.contains("Testmathe ohne Kalender|1|10:00|Hörsaal K3|1"), "erste Datenbank unberührt")

        let unknown = await call(backend, "POST", "/api/timetable/studip-questions/course", ["course_id": "k-vl", "include": true])
        XCTAssertEqual(unknown.status, 404, "keine offene Frage zu einem Kurs im Kalender")
        let bad = await call(backend, "POST", "/api/timetable/studip-questions/course", ["course_id": "k-frei"])
        XCTAssertEqual(bad.status, 400)
    }

    /// Frage B: Kurs mit vier Serien je Woche; abgewaehlte werden grau (attend=0), die Antwort bleibt gemerkt
    func testBusyCourseAnswerSetsAttendance() async throws {
        let backend = try await open()
        _ = try await sync(backend)
        let r = await call(backend, "POST", "/api/timetable/studip-questions/times", ["course_id": "k-frage", "attend": ["cy-frage-1", "cy-frage-3"]])
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.json?["skipped"], 2)
        var s = try await series(backend)
        XCTAssertTrue(s.contains("Fragestunden Testmathe|0|14:00|Raum F1|1"))
        XCTAssertTrue(s.contains("Fragestunden Testmathe|1|16:00|Raum F1|0"))
        XCTAssertTrue(s.contains("Fragestunden Testmathe|2|16:00|Raum F1|1"))
        XCTAssertTrue(s.contains("Fragestunden Testmathe|3|16:00|Raum F1|0"))
        let v8 = try await questions(backend)
        XCTAssertEqual(v8["busy"]?.array?.count, 0)

        let (_, again) = try await sync(backend)
        XCTAssertEqual(again.openQuestions, 1, "nur noch der Kurs ohne Kalendertermine")
        let v9 = try await series(backend)
        XCTAssertEqual(v9, s, "Antwort gilt weiter, nichts entfernt")

        // eine abgewaehlte Serie kommt nach dem Loeschen samt Verknuepfung wieder: gleich als "nicht besucht"
        try await backend.context.database.transaction { c in
            let id = try XCTUnwrap(try c.queryOne("SELECT id FROM course_events WHERE title='Fragestunden Testmathe' AND weekday=1")?["id"]?.int64)
            try c.execute("DELETE FROM course_events WHERE id=?", [.integer(id)])
            try c.execute("DELETE FROM studip_timetable_links WHERE event_id=?", [.integer(id)])
        }
        let (_, third) = try await sync(backend)
        XCTAssertEqual(third.newEvents, 1)
        s = try await series(backend)
        XCTAssertTrue(s.contains("Fragestunden Testmathe|1|16:00|Raum F1|0"))

        let none = await call(backend, "POST", "/api/timetable/studip-questions/times", ["course_id": "k-frage", "attend": []])
        XCTAssertEqual(none.status, 404, "schon beantwortet")
    }

    /// Doppel nur bei gleichem Kurs (oder ohne Kurs gleichem Titel), Tag und ueberlappender Zeit - nicht bei gleichem
    /// Titelanfang: Fragestunde und Vorlesung desselben Fachs am selben Tag sind zwei Serien (Befund 27.10.2026)
    func testDoubleNeedsSameCourseNotSameTitleStart() {
        let vl: [String: JSONValue] = ["title": "Mathematik für die Ingenieurwissenschaften III - Numerik, Tranche 1",
                                       "course_id": "k-vl", "weekday": 3, "start_time": "11:45", "end_time": "13:30"]
        var frage = vl
        frage["title"] = "Mathematik für die Ingenieurwissenschaften III - Numerik - Fragestunden"
        frage["course_id"] = "k-frage"
        frage["start_time"] = "12:15"; frage["end_time"] = "13:45"
        XCTAssertFalse(StudIPScheduleImport.isDouble(frage, vl), "anderer Kurs, gleicher Titelanfang, überlappend")
        XCTAssertTrue(StudIPScheduleImport.isDouble(vl, vl))
        var later = vl
        later["start_time"] = "13:30"; later["end_time"] = "15:00"
        XCTAssertFalse(StudIPScheduleImport.isDouble(later, vl), "schliesst nur an, ueberlappt nicht")
        var otherDay = vl
        otherDay["weekday"] = 4
        XCTAssertFalse(StudIPScheduleImport.isDouble(otherDay, vl))
        let own: [String: JSONValue] = ["title": "Lerngruppe  alle 2 Wochen", "weekday": 1, "start_time": "12:15", "end_time": "13:45"]
        var ownAgain = own
        ownAgain["title"] = "lerngruppe alle 2 wochen"
        XCTAssertTrue(StudIPScheduleImport.isDouble(ownAgain, own), "ohne Kurs: gleicher Titel")
        XCTAssertFalse(StudIPScheduleImport.isDouble(own, vl), "nur eine Seite mit Kurs")
    }
}
