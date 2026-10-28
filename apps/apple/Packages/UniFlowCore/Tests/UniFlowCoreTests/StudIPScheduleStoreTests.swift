import Foundation
import XCTest
@testable import UniFlowCore

// Stundenplan aus Stud.IP auf dem Geraet (S5): Abruf ueber die JSON:API mit erfundenen Antworten
// (packages/shared-contracts/fixtures/studip-schedule), Ablage in der lokalen Datenbank wie fetch_events/
// store_events/store_schedule_entries in app/studip_sync.py und Uebernahme in den Stundenplan wie auto_import.
// Uhr eingefroren: Sonntag, 25.10.2026 (Tag der Zeitumstellung), Europe/Berlin.

private let clock = UniFlowClock.fixed(berlin: "2026-10-25T14:30:05")!
private let base = URL(string: "https://studip.test")!

private func fixtureReply(_ name: String) throws -> HTTPReply {
    // .../apps/apple/Packages/UniFlowCore/Tests/UniFlowCoreTests/StudIPScheduleStoreTests.swift -> Repository-Wurzel
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    let data = try Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/studip-schedule/\(name)"))
    return HTTPReply(status: 200, contentType: "application/vnd.api+json", body: data)
}

private let emptyList = HTTPReply(status: 200, contentType: "application/vnd.api+json", body: Data(#"{"data": [], "links": {}}"#.utf8))
private let serverError = HTTPReply(status: 500, contentType: "text/plain")

/// Kurse wie nach dem Datei-Abgleich (StudIPClient.courses)
private let courses = [
    StudIPCourse(id: "c-ana", title: "Testanalysis I", number: "9001", semesterTitle: "WiSe 2026/27"),
    StudIPCourse(id: "c-ana-ue", title: "Übung Testanalysis I", number: "9002", semesterTitle: "WiSe 2026/27"),
    StudIPCourse(id: "c-prog", title: "Testprogrammierung", number: "9003", semesterTitle: "WiSe 2026/27"),
    StudIPCourse(id: "c-sem", title: "Testseminar Beispiel", semesterTitle: "WiSe 2026/27"),
    StudIPCourse(id: "c-erst", title: "Begrüßung der Erstsemester", semesterTitle: "WiSe 2026/27"),
]

/// Antworten je Pfad; `replace` ueberschreibt einzelne (Fehlerfaelle)
private func routes(_ replace: [String: HTTPReply] = [:]) throws -> [String: HTTPReply] {
    var r: [String: HTTPReply] = [
        "/jsonapi.php/v1/users/u-test/schedule": try fixtureReply("users-schedule.json"),
        "/jsonapi.php/v1/users/u-test/courses?page[limit]=100&include=start-semester": try fixtureReply("users-courses.json"),
        "/jsonapi.php/v1/courses/c-ana/events?page[limit]=200": try fixtureReply("course-events-c-ana-1.json"),
        "/jsonapi.php/v1/courses/c-ana/events?page[offset]=3&page[limit]=200": try fixtureReply("course-events-c-ana-2.json"),
        "/jsonapi.php/v1/courses/c-sem/events?page[limit]=200": try fixtureReply("course-events-c-sem.json"),
        "/jsonapi.php/v1/courses/c-ana-ue/events?page[limit]=200": emptyList,
        "/jsonapi.php/v1/courses/c-prog/events?page[limit]=200": emptyList,
        "/jsonapi.php/v1/courses/c-erst/events?page[limit]=200": emptyList,
    ]
    for (k, v) in replace { r[k] = v }
    return r
}

private func download(_ replace: [String: HTTPReply] = [:]) async throws -> (StudIPScheduleDownload, StubTransport) {
    let t = StubTransport(try routes(replace))
    let client = StudIPClient(base: base, transport: t, pauseMillis: 0)
    return (await StudIPScheduleStore.fetch(client: client, userID: "u-test", courses: courses), t)
}

private func store(_ d: StudIPScheduleDownload, _ backend: LocalBackend) async throws -> StudIPScheduleResult {
    try await backend.context.database.transaction { try StudIPScheduleStore.store(d, in: $0, clock: clock) }
}

/// users/{id}/schedule wie die Fixture mit ersetzten Textstellen (weitere Ausfaelle, weitere Kurszeiten)
private func scheduleReply(_ replace: [(String, String)]) throws -> HTTPReply {
    var text = String(decoding: try fixtureReply("users-schedule.json").body, as: UTF8.self)
    for (a, b) in replace {
        guard text.contains(a) else { throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "nicht in der Fixture: \(a)"]) }
        text = text.replacingOccurrences(of: a, with: b)
    }
    return HTTPReply(status: 200, contentType: "application/vnd.api+json", body: Data(text.utf8))
}

/// Ausfaelle von cy-ana-1 (Testanalysis I, Montag 10:00) in users-schedule.json
private let anaExdates = #""EXDATES": ["2026-11-02T10:00:00+01:00"]"#

/// Antwort des lokalen Backends (JSON-Rumpf)
private func call(_ backend: LocalBackend, _ method: String, _ path: String, _ body: JSONValue? = nil) async -> LocalResponse {
    await backend.handle(LocalRequest(method: method, path: path, body: body?.serialized() ?? Data()))
}

/// Termine eines Tages als "Titel Status"
private func day(_ backend: LocalBackend, _ date: String) async -> [String] {
    let r = await backend.handle(LocalRequest(method: "GET", path: "/api/timetable/day", query: [.init("date", date)]))
    return r.json?["events"]?.array?.map { "\($0["title"]?.string ?? "") \($0["status"]?.string ?? "")" } ?? []
}

/// Ausnahmen einer Serie als "Datum|Art|Notiz"
private func exceptions(_ backend: LocalBackend, _ eventID: Int) async throws -> [String] {
    try await backend.context.database.rows("SELECT date, type, note FROM event_exceptions WHERE event_id=? ORDER BY date", [.integer(Int64(eventID))])
        .map { "\($0["date"]?.string ?? "")|\($0["type"]?.string ?? "")|\($0["note"]?.string ?? "")" }
}

private func eventID(_ backend: LocalBackend, _ whereSQL: String) async throws -> Int {
    let id = try await backend.context.database.scalar("SELECT id FROM course_events WHERE \(whereSQL)")
    return try XCTUnwrap(id?.int, whereSQL)
}

/// Importvorschau "aus Stud.IP" wie TimetableView
private func studipPreview(_ backend: LocalBackend) async throws -> JSONValue {
    let b = "x-test"
    let body = "--\(b)\r\nContent-Disposition: form-data; name=\"source\"\r\n\r\nstudip\r\n--\(b)--\r\n"
    let r = await backend.handle(LocalRequest(method: "POST", path: "/api/timetable/import/preview",
                                              headers: ["Content-Type": "multipart/form-data; boundary=\(b)"], body: Data(body.utf8)))
    XCTAssertEqual(r.status, 200)
    return try XCTUnwrap(r.json)
}

/// Gruppe aus der Vorschau waehlen wie TimetablePreviewDialog.confirm: existing_id aus diff.changed/diff.same,
/// bei Kurszeiten ueber die Stud.IP-ID
private func choose(_ backend: LocalBackend, room: String) async throws -> JSONValue {
    let preview = try await studipPreview(backend)
    var o = try XCTUnwrap(preview["entries"]?.array?.first { $0["selected"] == false && $0["room"]?.string == room }?.object)
    o["selected"] = true
    let candidates = (preview["diff"]?["changed"]?.array ?? []) + (preview["diff"]?["same"]?.array ?? [])
    o["existing_id"] = candidates.first { $0["studip_id"] == o["studip_id"] }?["existing_id"] ?? .null
    let body: JSONValue = ["entries": [.object(o)], "source": "studip", "import_id": preview["import_id"] ?? .null, "remove_ids": []]
    let r = await call(backend, "POST", "/api/timetable/import/confirm", body)
    XCTAssertEqual(r.status, 200)
    return try XCTUnwrap(r.json)
}

/// Jede Anfrage scheitert mit einem Netzfehler (Server haengt: Zeitlimit), ausser den Pfaden in `routes`
final class FailingTransport: StudIPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let routes: [String: HTTPReply]
    private let error: Error
    private var log: [String] = []

    init(_ error: Error, routes: [String: HTTPReply] = [:]) {
        self.error = error
        self.routes = routes
    }

    var requested: [String] { lock.lock(); defer { lock.unlock() }; return log }

    func get(_ url: URL, accept: String?) async throws -> HTTPReply {
        let key = url.absoluteString.replacingOccurrences(of: "https://studip.test", with: "")
            .replacingOccurrences(of: "%5B", with: "[").replacingOccurrences(of: "%5D", with: "]")
        record(key)
        if let r = routes[key] { return r }
        throw error
    }

    private func record(_ key: String) { lock.lock(); log.append(key); lock.unlock() }
}

/// Serien im Stundenplan als "Titel|Wochentag|Beginn-Ende|rrule|von|bis|Raum|Art"
private func series(_ backend: LocalBackend) async throws -> [String] {
    try await backend.context.database.rows("SELECT * FROM course_events ORDER BY weekday, start_time, title").map { e in
        ["title", "weekday", "start_time", "end_time", "rrule", "date_from", "date_to", "room", "kind", "source"]
            .map { e[$0].map(LocalTimetable.text) ?? "None" }.joined(separator: "|")
    }
}

final class StudIPScheduleStoreTests: XCTestCase {

    func testFetchReadsScheduleCoursesAndEventsWithPaging() async throws {
        let (d, t) = try await download(["/jsonapi.php/v1/courses/c-prog/events?page[limit]=200": serverError])
        XCTAssertFalse(d.sessionExpired)
        XCTAssertNil(d.scheduleError)
        XCTAssertEqual(d.cycles?.count, 8)
        XCTAssertEqual(d.personal?.map { $0["id"]?.string ?? "" }, ["pe-1", "pe-2", "pe-3"])
        XCTAssertEqual(d.courseTypes, ["c-ana": 1, "c-ana-ue": 3, "c-prog": 1, "c-sem": 2, "c-erst": 7])
        // abgesagte Termine und Eintraege ohne ID fehlen wie in fetch_events; Raum bis zum ersten Komma
        let ana = try XCTUnwrap(d.events["c-ana"])
        XCTAssertEqual(ana.map(\.id), ["ev-ana-1", "ev-ana-2", "ev-ana-3", "ev-ana-k"])
        XCTAssertEqual(ana[0], StudIPCourseEvent(id: "ev-ana-1", courseID: "c-ana", title: "Sitzung 1", start: "2026-10-12T10:00:00",
                                                 end: "2026-10-12T11:30:00", room: "Hörsaal Test 1 (9999 - A001)"))
        XCTAssertEqual(ana[2].start, "2026-10-26T10:00:00", "Ortszeit wie geliefert, die ersten 19 Zeichen")
        XCTAssertEqual(ana[3].room, "Halle Test")
        XCTAssertEqual(d.events["c-sem"]?.map(\.room), ["Seminarraum Test", "Seminarraum Test", ""])
        XCTAssertEqual(d.events["c-ana-ue"], [])
        XCTAssertNil(d.events["c-prog"], "nicht geladen: das Gespeicherte bleibt")
        XCTAssertEqual(d.failedCourses, ["c-prog"])
        XCTAssertTrue(t.requested.contains("/jsonapi.php/v1/courses/c-ana/events?page[offset]=3&page[limit]=200"), "Folgeseite")
    }

    func testSessionExpiredStopsBeforeEvents() async throws {
        let (d, t) = try await download(["/jsonapi.php/v1/users/u-test/schedule": HTTPReply(status: 401)])
        XCTAssertTrue(d.sessionExpired)
        XCTAssertNil(d.cycles)
        XCTAssertNil(d.personal)
        XCTAssertTrue(d.events.isEmpty)
        XCTAssertFalse(t.requested.contains { $0.contains("/events") })
    }

    /// Ablage und Uebernahme: Kurszeiten ersetzen die aus Einzelterminen abgeleiteten Serien ihres Kurses, ein Kurs
    /// ohne Kurszeiten wird wie auf dem PC aus drei Einzelterminen eine Serie, parallele Uebungsgruppen bleiben offen,
    /// Ausfaelle (EXDATES) werden zu Ausnahmen, "Begruessung" kommt nicht in den Stundenplan.
    func testStoreImportsUniqueEntriesLikeAutoImport() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let (d, _) = try await download()
        let r = try await store(d, backend)
        XCTAssertEqual(r, StudIPScheduleResult(newEvents: 8, pendingGroups: 3, cycles: 8, events: 7))

        let s = try await series(backend)
        XCTAssertEqual(s, [
            "Testanalysis I|0|10:00|11:30|weekly|2026-10-12|2027-01-25|Hörsaal Test 1 (9999 - A001)|vorlesung|studip",
            "Testprogrammierung|1|12:00|13:30|weekly|2026-10-13|2027-01-26|Hörsaal Test 3|vorlesung|studip",
            "Testseminar Beispiel|1|16:00|17:30|weekly|2026-10-13|2026-10-27|Seminarraum Test|seminar|studip",
            "Testanalysis I|2|09:00|11:00|once|2027-02-10|2027-02-10|Halle Test|vorlesung|studip",
            "Übung Testanalysis I|2|14:00|15:30|weekly|2026-10-14|2027-01-27||uebung|studip",
            "Lerngruppe Test alle 2 Wochen|2|18:00|19:30|biweekly|None|None||vorlesung|studip",
            "Testanalysis I|3|08:15|09:45|biweekly|2026-10-15|2027-01-28|Raum Test 2|vorlesung|studip",
            "Chorprobe|6|17:00|19:00|weekly|None|None||vorlesung|studip",
        ])
        let ex = try await backend.context.database.rows("SELECT e.title, x.date, x.type, x.note FROM event_exceptions x JOIN course_events e ON e.id=x.event_id")
        XCTAssertEqual(ex.map { "\($0["title"]?.string ?? "")|\($0["date"]?.string ?? "")|\($0["type"]?.string ?? "")|\($0["note"]?.string ?? "")" },
                       ["Testanalysis I|2026-11-02|cancelled|Ausfall laut Stud.IP"])
        // Kurse wie run_sync, Art wie classify (nur gesetzt, wenn leer)
        let kinds = try await backend.context.database.rows("SELECT id, kind FROM courses WHERE id != '__user__' ORDER BY id")
        XCTAssertEqual(kinds.map { "\($0["id"]?.string ?? "")=\($0["kind"]?.string ?? "")" },
                       ["c-ana=vorlesung", "c-ana-ue=uebung", "c-erst=sonstiges", "c-prog=vorlesung", "c-sem=vorlesung"])
        // eigene Eintraege wie store_schedule_entries: Wochentag 0 = Montag, Stud.IP 7 = Sonntag; ohne Uhrzeit verworfen
        let personal = try await backend.context.database.rows("SELECT id, weekday, start, end FROM studip_schedule_entries ORDER BY id")
        XCTAssertEqual(personal.map { "\($0["id"]?.string ?? "")|\($0["weekday"]?.int ?? -1)|\($0["start"]?.string ?? "")-\($0["end"]?.string ?? "")" },
                       ["pe-1|2|18:00-19:30", "pe-2|6|17:00-19:00"])
        let events = try await backend.context.database.scalar("SELECT COUNT(*) FROM studip_events")
        XCTAssertEqual(events, .integer(7))
        // Import im Protokoll wie auto_import
        let imports = try await backend.context.database.rows("SELECT source, status, confirmed FROM schedule_imports")
        XCTAssertEqual(imports.map { "\($0["source"]?.string ?? "")|\($0["status"]?.string ?? "")|\($0["confirmed"]?.int ?? 0)" }, ["studip-auto|auto|1"])
    }

    func testWeekShowsStudIPTimetableAcrossDaylightSaving() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let (d, _) = try await download()
        _ = try await store(d, backend)
        // Woche nach der Zeitumstellung: Ortszeiten bleiben gleich
        let w = await backend.handle(LocalRequest(method: "GET", path: "/api/timetable/week", query: [.init("start", "2026-10-26")]))
        XCTAssertEqual(w.status, 200)
        let days = try XCTUnwrap(w.json?["days"]?.array)
        func line(_ e: JSONValue) -> String { "\(e["title"]?.string ?? "") \(e["start"]?.string ?? "")-\(e["end"]?.string ?? "") \(e["status"]?.string ?? "")" }
        XCTAssertEqual(days[0]["events"]?.array?.map(line), ["Testanalysis I 10:00-11:30 teilnahme"])
        XCTAssertEqual(days[1]["events"]?.array?.map(line), ["Testprogrammierung 12:00-13:30 teilnahme", "Testseminar Beispiel 16:00-17:30 teilnahme"])
        XCTAssertEqual(days[2]["events"]?.array?.map(line), ["Übung Testanalysis I 14:00-15:30 teilnahme", "Lerngruppe Test alle 2 Wochen 18:00-19:30 teilnahme"])
        XCTAssertEqual(days[3]["events"]?.array?.map(line), ["Testanalysis I 08:15-09:45 teilnahme"])
        XCTAssertEqual(days[4]["events"], [], "Uebungsgruppen am Freitag warten auf die Auswahl")
        XCTAssertEqual(days[6]["events"]?.array?.map(line), ["Chorprobe 17:00-19:00 teilnahme"])
        // Ausfall laut Stud.IP am 02.11.
        let next = await backend.handle(LocalRequest(method: "GET", path: "/api/timetable/week", query: [.init("start", "2026-11-02")]))
        XCTAssertEqual(next.json?["days"]?.array?.first?["events"]?.array?.map(line), ["Testanalysis I 10:00-11:30 ausfall"])
        // Lerngruppe alle zwei Wochen ab Semesterbeginn (12.10.): 28.10. ja, 04.11. nein
        XCTAssertEqual(next.json?["days"]?.array?[2]["events"]?.array?.map(line), ["Übung Testanalysis I 14:00-15:30 teilnahme"])
        // freie Fenster mit Fahrtzeit vor dem ersten Campus-Termin
        let free = await backend.handle(LocalRequest(method: "GET", path: "/api/timetable/free", query: [.init("date", "2026-10-26")]))
        XCTAssertEqual(free.json?.array?.map { "\($0["start_hm"]?.string ?? "")-\($0["end_hm"]?.string ?? "")" }, ["08:00-09:30", "12:00-21:00"])
    }

    /// Gruppenauswahl wie in der Web-App: Vorschau "aus Stud.IP" zeigt die parallelen Gruppen unausgewaehlt mit
    /// Hinweis, die gewaehlte Gruppe kommt mit ihren Ausfaellen in den Stundenplan.
    func testGroupChoiceThroughPreviewAndConfirm() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let (d, _) = try await download()
        _ = try await store(d, backend)
        let status = await backend.handle(LocalRequest(method: "GET", path: "/api/timetable/auto-status"))
        XCTAssertEqual(status.json?["pending_groups"], 3)
        XCTAssertEqual(status.json?["courses"], ["Testprogrammierung"])
        XCTAssertEqual(status.json?["personal"]?.array?.map { $0["title"]?.string ?? "" }, ["Lerngruppe Test alle 2 Wochen", "Chorprobe"])

        let b = "x-test"
        let body = "--\(b)\r\nContent-Disposition: form-data; name=\"source\"\r\n\r\nstudip\r\n--\(b)--\r\n"
        let preview = await backend.handle(LocalRequest(method: "POST", path: "/api/timetable/import/preview",
                                                        headers: ["Content-Type": "multipart/form-data; boundary=\(b)"], body: Data(body.utf8)))
        XCTAssertEqual(preview.status, 200)
        let entries = try XCTUnwrap(preview.json?["entries"]?.array)
        let groups = entries.filter { $0["selected"] == false }
        XCTAssertEqual(groups.map { "\($0["weekday"]?.int ?? -1) \($0["start_time"]?.string ?? "") \($0["room"]?.string ?? "")" },
                       ["2 16:00 Pool Test C", "4 08:00 Pool Test A", "4 10:00 Pool Test B"])
        XCTAssertEqual(Set(groups.compactMap { $0["hint"]?.string }), ["3 parallele Gruppen – nur deine Gruppe auswählen"])
        XCTAssertTrue(groups.allSatisfy { $0["uncertain"] == true && $0["kind"] == "uebung" })
        XCTAssertEqual(preview.json?["diff"]?["same"]?.array?.count, 8, "schon uebernommen")

        // wie TimetablePreviewDialog.confirm: nur die gewaehlte Gruppe 2 (Freitag 10:00)
        var chosen = try XCTUnwrap(groups.first { $0["room"] == "Pool Test B" }?.object)
        chosen["selected"] = true
        chosen["existing_id"] = .null
        let confirm: JSONValue = ["entries": [.object(chosen)], "source": "studip", "import_id": preview.json?["import_id"] ?? .null, "remove_ids": []]
        let res = await backend.handle(LocalRequest(method: "POST", path: "/api/timetable/import/confirm", body: confirm.serialized()))
        XCTAssertEqual(res.json?["new"], 1)
        let fri = await backend.handle(LocalRequest(method: "GET", path: "/api/timetable/day", query: [.init("date", "2026-12-25")]))
        XCTAssertEqual(fri.json?["events"]?.array?.map { "\($0["title"]?.string ?? "") \($0["status"]?.string ?? "")" }, ["Testprogrammierung ausfall"])
        let notes = try await backend.context.database.rows("SELECT date, note FROM event_exceptions WHERE type='cancelled' ORDER BY date")
        XCTAssertEqual(notes.map { $0["date"]?.string ?? "" }, ["2026-11-02", "2026-12-25", "2027-01-01"])
    }

    /// Zweiter Abgleich: nichts doppelt, Aenderungen des Nutzers bleiben; was nicht geladen werden konnte, bleibt
    /// wie zuletzt gespeichert
    func testSecondRunKeepsUserChangesAndFailedParts() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let (d, _) = try await download()
        _ = try await store(d, backend)
        let id = try await backend.context.database.scalar("SELECT id FROM course_events WHERE title='Chorprobe'")
        let skip: JSONValue = ["event_id": .number(Double(id?.int ?? 0)), "date": "2026-11-01", "mode": "today_skip"]
        _ = await backend.handle(LocalRequest(method: "POST", path: "/api/timetable/attendance", body: skip.serialized()))
        let before = try await series(backend)

        // Stundenplan und Termine von c-ana nicht lesbar, c-sem neu ohne den dritten Termin
        let semTwo = HTTPReply(status: 200, contentType: "application/vnd.api+json", body: Data(#"""
            {"data": [{"id": "ev-sem-1", "type": "course-events", "attributes": {"title": "Termin", "start": "2026-10-13T16:00:00+02:00", "end": "2026-10-13T17:30:00+02:00", "location": "Seminarraum Test"}}], "links": {}}
            """#.utf8))
        let (d2, _) = try await download(["/jsonapi.php/v1/users/u-test/schedule": serverError,
                                          "/jsonapi.php/v1/courses/c-ana/events?page[limit]=200": serverError,
                                          "/jsonapi.php/v1/courses/c-sem/events?page[limit]=200": semTwo])
        XCTAssertNotNil(d2.scheduleError)
        XCTAssertTrue(d2.scheduleError?.contains("HTTP 500") ?? false, d2.scheduleError ?? "")
        XCTAssertEqual(d2.failedCourses, ["c-ana"])
        let r2 = try await store(d2, backend)
        XCTAssertEqual(r2.newEvents, 0)
        XCTAssertEqual(r2.cycles, 0, "nicht geladen")
        let after = try await series(backend)
        XCTAssertEqual(after, before, "nichts doppelt, nichts entfernt")
        let kept = try await backend.context.database.rows("SELECT course_id, COUNT(*) AS n FROM studip_events GROUP BY course_id ORDER BY course_id")
        XCTAssertEqual(kept.map { "\($0["course_id"]?.string ?? "")=\($0["n"]?.int ?? 0)" }, ["c-ana=4", "c-sem=1"])
        let cycles = try await backend.context.database.scalar("SELECT COUNT(*) FROM studip_cycle_dates")
        XCTAssertEqual(cycles, .integer(8))
        let personal = try await backend.context.database.scalar("SELECT COUNT(*) FROM studip_schedule_entries")
        XCTAssertEqual(personal, .integer(2))
        let skipped = try await backend.context.database.scalar("SELECT COUNT(*) FROM event_exceptions WHERE type='skip' AND date='2026-11-01'")
        XCTAssertEqual(skipped, .integer(1))
    }

    /// Ohne Kurszeiten (Tabelle fehlt) ist studip_entries auf dem Geraet dasselbe wie in Python
    func testWithoutCyclesEntriesComeFromSingleEvents() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        var (d, _) = try await download()
        d.cycles = nil
        _ = try await store(d, backend)
        let s = try await series(backend)
        // c-ana: drei Montagstermine werden eine Serie, die Klausur bleibt einmalig
        XCTAssertTrue(s.contains("Testanalysis I|0|10:00|11:30|weekly|2026-10-12|2026-10-26|Hörsaal Test 1 (9999 - A001)|vorlesung|studip"), "\(s)")
        XCTAssertTrue(s.contains("Testanalysis I|2|09:00|11:00|once|2027-02-10|2027-02-10|Halle Test|vorlesung|studip"), "\(s)")
        let table = try await backend.context.database.scalar("SELECT COUNT(*) FROM sqlite_master WHERE name='studip_cycle_dates'")
        XCTAssertEqual(table, .integer(0), "Tabelle nur bei Bedarf")
    }

    // MARK: Nachbesserung S5: Verknuepfung Stud.IP-Eintrag -> Serie (StudIPScheduleImport)

    /// Ausfaelle, die Stud.IP erst nach der ersten Uebernahme meldet, kommen in die vorhandene Serie; was der Nutzer
    /// an einem Tag geaendert hat, bleibt; ein zurueckgenommener Ausfall entfaellt wieder
    func testLaterCancellationsReachExistingSeries() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let (d, _) = try await download()
        _ = try await store(d, backend)
        let ana = try await eventID(backend, "title='Testanalysis I' AND weekday=0")
        // Nutzer: Ausfall vom 02.11. zurueckgesetzt (findet doch statt), 16.11. selbst ausgelassen
        for (date, mode) in [("2026-11-02", "reset"), ("2026-11-16", "today_skip")] {
            _ = await call(backend, "POST", "/api/timetable/attendance", ["event_id": .number(Double(ana)), "date": .string(date), "mode": .string(mode)])
        }
        let more = try scheduleReply([(anaExdates, #""EXDATES": ["2026-11-02T10:00:00+01:00", "2026-11-09T10:00:00+01:00", "2026-11-16T10:00:00+01:00"]"#)])
        let (d2, _) = try await download(["/jsonapi.php/v1/users/u-test/schedule": more])
        let r2 = try await store(d2, backend)
        XCTAssertEqual(r2.newEvents, 0)
        let after = await day(backend, "2026-11-09")
        XCTAssertEqual(after, ["Testanalysis I ausfall"])
        let reset = await day(backend, "2026-11-02")
        XCTAssertEqual(reset, ["Testanalysis I teilnahme"], "vom Nutzer zurueckgesetzt, kommt nicht wieder")
        let ex = try await exceptions(backend, ana)
        XCTAssertEqual(ex, ["2026-11-09|cancelled|Ausfall laut Stud.IP", "2026-11-16|skip|"])
        // Stud.IP nimmt die Ausfaelle vom 09. und 16.11. zurueck: der eigene vom 16.11. bleibt
        let (d3, _) = try await download()
        _ = try await store(d3, backend)
        let back = try await exceptions(backend, ana)
        XCTAssertEqual(back, ["2026-11-16|skip|"])
        let n = try await backend.context.database.scalar("SELECT COUNT(*) FROM course_events")
        XCTAssertEqual(n, .integer(8), "nichts doppelt")
    }

    /// Zwei Kurszeiten desselben Kurses am selben Tag (gleicher Titel und Wochentag): der Ausfall landet in der
    /// richtigen Serie (Zuordnung ueber die Stud.IP-ID, nicht ueber Titel und Wochentag)
    func testCancellationGoesToTheRightSeriesOfTheDay() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let extra = #"""
            {"data": [
             {"id": "cy-ana-3", "type": "seminar-cycle-dates",
              "attributes": {"title": "Kurszeit", "description": "Übung", "start": "14:00", "end": "15:30", "weekday": 1, "color": null,
                             "recurrence": {"FREQ": "WEEKLY", "INTERVAL": 1, "DTSTART": "2026-10-12", "UNTIL": "2027-01-25"EXTRA}, "locations": ["Raum Test 4"]},
              "relationships": {"owner": {"data": {"type": "courses", "id": "c-ana"}}}},
            """#
        let first = try scheduleReply([(#"{"data": ["#, extra.replacingOccurrences(of: "EXTRA", with: ""))])
        let (d, _) = try await download(["/jsonapi.php/v1/users/u-test/schedule": first])
        let r = try await store(d, backend)
        XCTAssertEqual(r.newEvents, 9)
        let morning = try await eventID(backend, "title='Testanalysis I' AND weekday=0 AND start_time='10:00'")
        let afternoon = try await eventID(backend, "title='Testanalysis I' AND weekday=0 AND start_time='14:00'")
        let later = try scheduleReply([(#"{"data": ["#, extra.replacingOccurrences(of: "EXTRA", with: #", "EXDATES": ["2026-11-09"]"#))])
        let (d2, _) = try await download(["/jsonapi.php/v1/users/u-test/schedule": later])
        _ = try await store(d2, backend)
        let m = try await exceptions(backend, morning), a = try await exceptions(backend, afternoon)
        XCTAssertEqual(m, ["2026-11-02|cancelled|Ausfall laut Stud.IP"])
        XCTAssertEqual(a, ["2026-11-09|cancelled|Ausfall laut Stud.IP"])
        let shown = await day(backend, "2026-11-09")
        XCTAssertEqual(shown, ["Testanalysis I teilnahme", "Testanalysis I ausfall"])
        // Nachmittag geloescht: die Vorschau bietet ihn als neu an, statt ihn mit dem Vormittag zu paaren
        _ = await call(backend, "DELETE", "/api/timetable/events/\(afternoon)")
        let preview = try await studipPreview(backend)
        let back = (preview["diff"]?["new"]?.array ?? []).first { $0["studip_id"] == "cy-ana-3" }
        XCTAssertNotNil(back)
        XCTAssertNil(back?["existing_id"])
        XCTAssertEqual(preview["diff"]?["same"]?.array?.first { $0["studip_id"] == "cy-ana-1" }?["existing_id"]?.int, morning)
        let r3 = try await store(d2, backend)
        XCTAssertEqual(r3.newEvents, 0, "geloescht bleibt geloescht")
    }

    /// Geloeschte oder umbenannte Serien legt der naechste Abgleich nicht wieder an; ueber die Vorschau laesst sich
    /// eine geloeschte Serie zurueckholen
    func testDeletedOrRenamedSeriesAreNotRecreated() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let (d, _) = try await download()
        _ = try await store(d, backend)
        let chor = try await eventID(backend, "title='Chorprobe'")
        let prog = try await eventID(backend, "title='Testprogrammierung'")
        let del = await call(backend, "DELETE", "/api/timetable/events/\(chor)")
        XCTAssertEqual(del.status, 200)
        let patch = await call(backend, "PATCH", "/api/timetable/events/\(prog)", ["title": "Programmierung (VL)", "weekday": 3])
        XCTAssertEqual(patch.status, 200)
        let before = try await series(backend)

        let r2 = try await store(d, backend)
        XCTAssertEqual(r2.newEvents, 0)
        let after = try await series(backend)
        XCTAssertEqual(after, before, "nichts neu angelegt")
        XCTAssertFalse(after.contains { $0.hasPrefix("Chorprobe|") || $0.hasPrefix("Testprogrammierung|") }, "\(after)")

        // zurueckholen: die Vorschau bietet die geloeschte Chorprobe als neu an
        let preview = try await studipPreview(backend)
        var o = try XCTUnwrap(preview["diff"]?["new"]?.array?.first { $0["title"] == "Chorprobe" }?.object)
        o["selected"] = true
        let res = await call(backend, "POST", "/api/timetable/import/confirm", ["entries": [.object(o)], "source": "studip", "remove_ids": []])
        XCTAssertEqual(res.json?["new"], 1)
        let r3 = try await store(d, backend)
        XCTAssertEqual(r3.newEvents, 0)
        let n = try await backend.context.database.scalar("SELECT COUNT(*) FROM course_events WHERE title='Chorprobe'")
        XCTAssertEqual(n, .integer(1))
    }

    /// Gewaehlte Gruppe: kein Hinweis "zur Auswahl" mehr (Abgleich und Auto-Status), spaetere Ausfaelle kommen dazu
    func testChosenGroupIsNoLongerPendingAndGetsLaterCancellations() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let (d, _) = try await download()
        let r = try await store(d, backend)
        XCTAssertEqual(r.pendingGroups, 3)
        let res = try await choose(backend, room: "Pool Test B")
        XCTAssertEqual(res["new"], 1)
        let r2 = try await store(d, backend)
        XCTAssertEqual(r2, StudIPScheduleResult(newEvents: 0, pendingGroups: 0, cycles: 8, events: 7))
        let status = await call(backend, "GET", "/api/timetable/auto-status")
        XCTAssertEqual(status.json?["pending_groups"], 0)
        XCTAssertEqual(status.json?["courses"], [])
        // die Vorschau zeigt die Gruppen weiter (Wechsel bleibt moeglich)
        let preview = try await studipPreview(backend)
        XCTAssertEqual(preview["entries"]?.array?.filter { $0["selected"] == false }.count, 3)

        let later = try scheduleReply([(#""EXDATES": ["2026-12-25", "2027-01-01"]"#, #""EXDATES": ["2026-12-25", "2027-01-01", "2027-01-08"]"#)])
        let (d3, _) = try await download(["/jsonapi.php/v1/users/u-test/schedule": later])
        _ = try await store(d3, backend)
        let shown = await day(backend, "2027-01-08")
        XCTAssertEqual(shown, ["Testprogrammierung ausfall"])
    }

    /// Ohne Gruppe gewaehlt, aber eine Serie mit Kurs, Wochentag und Beginn einer Gruppe (vor der Verknuepfung
    /// gewaehlt): die Gruppe gilt als entschieden; andere Arten desselben Kurses zaehlen nicht
    func testGroupChosenBeforeLinksCountsAsDecided() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let (d, _) = try await download()
        _ = try await store(d, backend)
        // Vorlesung desselben Kurses (Art vorlesung) entscheidet die Uebungsgruppen nicht
        let pendingBefore = try await store(d, backend).pendingGroups
        XCTAssertEqual(pendingBefore, 3)
        _ = await call(backend, "POST", "/api/timetable/events", ["title": "Testprogrammierung", "kind": "uebung", "weekday": 4,
                                                                  "start_time": "08:00", "end_time": "09:30", "course_id": "c-prog"])
        let r = try await store(d, backend)
        XCTAssertEqual(r.pendingGroups, 0)
    }

    /// Gruppe gewechselt (A ersetzt B ueber diff.changed): die Ausfaelle laut Stud.IP von B entfallen, eigene
    /// Ausnahmen bleiben, der naechste Abgleich bringt B's Ausfaelle nicht zurueck
    func testSwitchingGroupDropsCancellationsOfOldGroup() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let (d, _) = try await download()
        _ = try await store(d, backend)
        _ = try await choose(backend, room: "Pool Test B")
        let row = try await eventID(backend, "weekday=4")
        let b = try await exceptions(backend, row)
        XCTAssertEqual(b, ["2026-12-25|cancelled|Ausfall laut Stud.IP", "2027-01-01|cancelled|Ausfall laut Stud.IP"])
        _ = await call(backend, "POST", "/api/timetable/attendance", ["event_id": .number(Double(row)), "date": "2026-11-06", "mode": "today_skip"])

        let res = try await choose(backend, room: "Pool Test A")
        XCTAssertEqual(res["updated"], 1, "ersetzt die bisherige Gruppe (gleicher Titel und Wochentag)")
        let s = try await series(backend)
        // von Hand gewaehlt: Quelle "studip-manual" wie app/server.py seit 8cc7463 (nie als fremde Gruppe entfernt)
        XCTAssertEqual(s.filter { $0.contains("|4|") }, ["Testprogrammierung|4|08:00|09:30|weekly|2026-10-16|2027-01-29|Pool Test A|uebung|studip-manual"])
        let a = try await exceptions(backend, row)
        XCTAssertEqual(a, ["2026-11-06|skip|"])
        _ = try await store(d, backend)
        let again = try await exceptions(backend, row)
        XCTAssertEqual(again, ["2026-11-06|skip|"])
        let xmas = await day(backend, "2026-12-25")
        XCTAssertEqual(xmas, ["Testprogrammierung teilnahme"])
    }

    /// Vorlesung und Uebungsgruppe eines Kurses am selben Wochentag (gleicher Titel): die Gruppenwahl legt die Gruppe
    /// neu an und laesst die Vorlesung stehen; ein Wechsel zu einer anderen Gruppe am selben Tag ersetzt die Gruppe
    func testGroupOnLectureDayKeepsLecture() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        // Gruppe 3 (Pool Test C) am Dienstag wie die Vorlesung, dazu eine vierte Gruppe am Dienstag
        let tuesday = try scheduleReply([
            (#""description": "Übung Gruppe 3", "start": "16:00", "end": "17:30", "weekday": 3"#, #""description": "Übung Gruppe 3", "start": "16:00", "end": "17:30", "weekday": 2"#),
            (#"{"data": ["#, #"""
                {"data": [
                 {"id": "cy-prog-ue4", "type": "seminar-cycle-dates",
                  "attributes": {"title": "Kurszeit", "description": "Übung Gruppe 4", "start": "08:00", "end": "09:30", "weekday": 2, "color": null,
                                 "recurrence": {"FREQ": "WEEKLY", "INTERVAL": 1, "DTSTART": "2026-10-13", "UNTIL": "2027-01-26", "EXDATES": ["2026-11-10"]}, "locations": ["Pool Test D"]},
                  "relationships": {"owner": {"data": {"type": "courses", "id": "c-prog"}}}},
                """#),
        ])
        let (d, _) = try await download(["/jsonapi.php/v1/users/u-test/schedule": tuesday])
        _ = try await store(d, backend)
        let lecture = try await eventID(backend, "title='Testprogrammierung' AND weekday=1")
        // Titel und Wochentag allein trafen die Vorlesung (Python: "changed" mit ihrer ID)
        let preview = try await studipPreview(backend)
        let c = (preview["diff"]?["new"]?.array ?? []).first { $0["room"] == "Pool Test C" }
        XCTAssertNotNil(c, "Gruppe am Vorlesungstag ist neu")
        XCTAssertNil(c?["existing_id"])
        XCTAssertEqual(preview["diff"]?["same"]?.array?.first { $0["studip_id"] == "cy-prog-vl" }?["existing_id"]?.int, lecture)

        let res = try await choose(backend, room: "Pool Test C")
        XCTAssertEqual(res["new"], 1)
        XCTAssertEqual(res["updated"], 0)
        let tue = try await series(backend).filter { $0.contains("|1|") && $0.hasPrefix("Testprogrammierung|") }
        XCTAssertEqual(tue, ["Testprogrammierung|1|12:00|13:30|weekly|2026-10-13|2027-01-26|Hörsaal Test 3|vorlesung|studip",
                             "Testprogrammierung|1|16:00|17:30|weekly|2026-10-14|2027-01-27|Pool Test C|uebung|studip-manual"])
        // Wechsel zu Gruppe 4 (auch Dienstag): ersetzt Gruppe 3, die Vorlesung bleibt, Ausfall der neuen Gruppe dazu
        let sw = try await choose(backend, room: "Pool Test D")
        XCTAssertEqual(sw["updated"], 1)
        _ = try await store(d, backend)
        let after = try await series(backend).filter { $0.contains("|1|") && $0.hasPrefix("Testprogrammierung|") }
        XCTAssertEqual(after.count, 2, "\(after)")
        XCTAssertTrue(after.contains("Testprogrammierung|1|12:00|13:30|weekly|2026-10-13|2027-01-26|Hörsaal Test 3|vorlesung|studip"), "\(after)")
        XCTAssertTrue(after.contains { $0.hasPrefix("Testprogrammierung|1|08:00|09:30|") && $0.contains("Pool Test D") }, "\(after)")
        let shown = await day(backend, "2026-11-10")
        XCTAssertEqual(shown, ["Testprogrammierung ausfall", "Testprogrammierung teilnahme"])
        let ex = try await exceptions(backend, lecture)
        XCTAssertEqual(ex, [], "Vorlesung ohne Ausfall der Gruppe")
    }

    /// Serien aus der Zeit vor der Verknuepfung (Tabelle fehlt): genau passende Serien werden verknuepft statt neu
    /// angelegt und bekommen spaetere Ausfaelle
    func testSeriesFromBeforeLinksAreAdopted() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let (d, _) = try await download()
        _ = try await store(d, backend)
        try await backend.context.database.transaction { try $0.executeScript("DROP TABLE studip_timetable_links") }
        let before = try await series(backend)
        let more = try scheduleReply([(anaExdates, #""EXDATES": ["2026-11-02T10:00:00+01:00", "2026-11-09T10:00:00+01:00"]"#)])
        let (d2, _) = try await download(["/jsonapi.php/v1/users/u-test/schedule": more])
        let r = try await store(d2, backend)
        XCTAssertEqual(r.newEvents, 0)
        let after = try await series(backend)
        XCTAssertEqual(after, before)
        let shown = await day(backend, "2026-11-09")
        XCTAssertEqual(shown, ["Testanalysis I ausfall"])
        let links = try await backend.context.database.scalar("SELECT COUNT(*) FROM studip_timetable_links")
        XCTAssertEqual(links, .integer(8))
    }

    // MARK: Nachbesserung S5: Netzfehler

    /// Haengt der Server (Zeitlimit) oder fehlt das Netz, fragt der Abruf nichts mehr ab: hoechstens eine Anfrage
    /// bis zum Zeitlimit statt einer je Kurs
    func testTransportErrorStopsFetch() async throws {
        let many = (1...12).map { StudIPCourse(id: "c-\($0)", title: "Testkurs \($0)") }
        for error in [URLError(.timedOut), URLError(.notConnectedToInternet), CancellationError()] as [Error] {
            let t = FailingTransport(error)
            let client = StudIPClient(base: base, transport: t, pauseMillis: 0)
            let d = await StudIPScheduleStore.fetch(client: client, userID: "u-test", courses: many)
            XCTAssertEqual(t.requested.count, 1, "\(error)")
            XCTAssertTrue(d.unreachable)
            XCTAssertEqual(d.failedCourses, many.map(\.id))
            XCTAssertNotNil(d.scheduleError)
            XCTAssertTrue(d.events.isEmpty)
        }
        // Kurszeiten geladen, dann haengt der Server bei den Einzelterminen
        let ok = try routes()
        let t = FailingTransport(URLError(.timedOut), routes: ok.filter { !$0.key.contains("/events") })
        let d = await StudIPScheduleStore.fetch(client: StudIPClient(base: base, transport: t, pauseMillis: 0), userID: "u-test", courses: courses)
        XCTAssertEqual(t.requested.count, 3, "\(t.requested)")
        XCTAssertNil(d.scheduleError)
        XCTAssertEqual(d.cycles?.count, 8)
        XCTAssertTrue(d.unreachable)
        XCTAssertEqual(d.failedCourses, courses.map(\.id))
        // HTTP-Fehler eines Kurses sind kein Netzfehler: die anderen Kurse werden weiter geladen
        let (d2, _) = try await download(["/jsonapi.php/v1/courses/c-ana/events?page[limit]=200": serverError])
        XCTAssertFalse(d2.unreachable)
        XCTAssertEqual(d2.failedCourses, ["c-ana"])
        XCTAssertEqual(d2.events.count, 4)
    }
}

// MARK: - Ankuendigungen (News) der Kurse wie fetch_news/announcements.store in run_sync

final class StudIPNewsStoreTests: XCTestCase {
    private func newsReply(_ items: [(String, String, String, String)]) -> HTTPReply {
        let data: [JSONValue] = items.map { id, title, content, start in
            .object(["id": .string(id), "type": .string("news"),
                     "attributes": .object(["title": .string(title), "content": .string(content), "publication-start": .string(start)])])
        }
        return HTTPReply(status: 200, contentType: "application/vnd.api+json", body: JSONValue.object(["data": .array(data)]).serialized())
    }

    func testNewsAreStoredPerCourseAndRemovedWhenGone() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let news = "/jsonapi.php/v1/courses/c-ana/news?page[limit]=100"
        let (d1, t) = try await download([news: newsReply([
            ("n1", "Ausfall", "<p>Die Vorlesung am <b>12.11.</b> f&auml;llt leider aus.</p>", "2026-10-20T12:00:00+02:00"),
            ("n2", "Skript", "Das Skript ist online.", "2026-10-21T12:00:00+02:00"),
        ])])
        XCTAssertEqual(d1.news["c-ana"]?.count, 2)
        XCTAssertNil(d1.news["c-prog"], "404 (kein News-Recht): Bestand bleibt, kein Fehler des Kurses")
        XCTAssertTrue(t.requested.contains(news))
        _ = try await store(d1, backend)
        let rows = try await backend.context.database.rows("SELECT id, source, course_id, title, text, url, dates FROM announcements ORDER BY id")
        XCTAssertEqual(rows.map { $0["id"]?.string ?? "" }, ["sp-news-n1", "sp-news-n2"])
        XCTAssertEqual(rows[0]["text"]?.string, "Die Vorlesung am 12.11. fällt leider aus.")
        XCTAssertEqual(rows[0]["url"]?.string, "https://studip.test/dispatch.php/course/overview?cid=c-ana")
        let dates = try JSONValue.parse(Data((rows[0]["dates"]?.string ?? "[]").utf8))
        XCTAssertEqual(dates.array?.first?["date"], "2026-11-12")
        XCTAssertEqual(dates.array?.first?["kind"], "ausfall")
        XCTAssertEqual(rows[1]["dates"]?.string, "[]")
        // Uebersicht: Ankuendigung der letzten 21 Tage mit kommendem Termin
        let dash = await call(backend, "GET", "/api/dashboard")
        XCTAssertEqual(dash.json?["announcements"]?.array?.map { $0["id"]?.string ?? "" }, ["sp-news-n2", "sp-news-n1"], "neueste zuerst")
        let week = await backend.handle(LocalRequest(method: "GET", path: "/api/timetable/week", query: [.init("start", "2026-11-09")]))
        let thursday = week.json?["days"]?.array?[3]
        XCTAssertEqual(thursday?["notices"]?.array?.first?["kind_label"], "Ausfall?")

        // zweiter Lauf: n2 in Stud.IP geloescht -> weg; Kurs ohne lesbare News behaelt seinen Bestand
        let (d2, _) = try await download([news: newsReply([("n1", "Ausfall", "Die Vorlesung am 12.11. fällt aus.", "2026-10-20T12:00:00+02:00")])])
        _ = try await store(d2, backend)
        let after2 = try await backend.context.database.rows("SELECT id FROM announcements ORDER BY id").map { $0["id"]?.string ?? "" }
        XCTAssertEqual(after2, ["sp-news-n1"])
        // Termine eines Kurses nicht lesbar: seine Ankuendigungen kommen trotzdem (eigener Versuch wie in run_sync)
        let (d4, _) = try await download(["/jsonapi.php/v1/courses/c-ana/events?page[limit]=200": serverError,
                                          news: newsReply([("n1", "Ausfall", "x", "2026-10-20T12:00:00+02:00")])])
        XCTAssertEqual(d4.failedCourses, ["c-ana"])
        XCTAssertEqual(d4.news["c-ana"]?.count, 1)
        let (d3, _) = try await download([news: HTTPReply(status: 500, contentType: "text/plain")])
        _ = try await store(d3, backend)
        let count3 = try await backend.context.database.scalar("SELECT COUNT(*) FROM announcements")?.int
        XCTAssertEqual(count3, 1)
    }
}

// MARK: - Externer Pruefbericht Runden 12/13 (381-390, 421-430): HTTP 200 ist noch kein gueltiger Datensatz

/// Fixture-Datei mit ersetzten Textstellen (wie `scheduleReply`)
private func fixtureReply(_ name: String, _ replace: [(String, String)]) throws -> HTTPReply {
    var text = String(decoding: try fixtureReply(name).body, as: UTF8.self)
    for (a, b) in replace {
        guard text.contains(a) else { throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "nicht in \(name): \(a)"]) }
        text = text.replacingOccurrences(of: a, with: b)
    }
    return HTTPReply(status: 200, contentType: "application/vnd.api+json", body: Data(text.utf8))
}

private func apiReply(_ json: String) -> HTTPReply {
    HTTPReply(status: 200, contentType: "application/vnd.api+json", body: Data(json.utf8))
}

/// Inhalt der Tabellen, die ein Stundenplan-Abgleich schreibt (je Zeile sortiertes JSON)
private func dump(_ backend: LocalBackend, _ tables: [String] = ["course_events", "event_exceptions", "event_notes", "studip_events",
                                                                 "studip_schedule_entries", "studip_cycle_dates", "studip_timetable_links",
                                                                 "schedule_imports", "announcements", "courses"]) async throws -> [String: [String]] {
    var out: [String: [String]] = [:]
    for t in tables {
        let exists = try await backend.context.database.scalar("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?", [.text(t)])
        guard exists?.int == 1 else { out[t] = ["(fehlt)"]; continue }
        out[t] = try await backend.context.database.rows("SELECT * FROM \(t)").map { JSONValue.object($0).jsonString(sortedKeys: true) }.sorted()
    }
    return out
}

private func ids(_ backend: LocalBackend, _ sql: String) async throws -> [String] {
    try await backend.context.database.rows(sql).map { $0["id"]?.string ?? "" }
}

final class StudIPScheduleIntegrityTests: XCTestCase {

    /// 421, 422, 425, 382: HTTP 200, aber eigene Eintraege ohne Uhrzeit, eine Kurszeit ohne lesbare Uhrzeit, ein Kurs
    /// nur mit Terminen ohne Kennung, ein Termin mit kaputtem Beginn. Der bisherige Stand jedes dieser Eintraege bleibt,
    /// der Stundenplan bleibt gleich, und die Zahl der nicht lesbaren Eintraege wird gemeldet. Was Stud.IP wirklich nicht
    /// mehr liefert, verschwindet weiterhin.
    func testFormallyValidButBrokenEntriesKeepTheirStoredState() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let (d, _) = try await download()
        XCTAssertEqual(d.unreadable, 2, "Fixture: ein Termin ohne Kennung (c-ana), ein eigener Eintrag ohne Uhrzeit")
        _ = try await store(d, backend)
        let seriesBefore = try await series(backend)
        let personalBefore = try await dump(backend, ["studip_schedule_entries"])
        let cycleBefore = try await backend.context.database.scalar("SELECT data FROM studip_cycle_dates WHERE id='cy-ana-1'")

        let broken = try scheduleReply([
            (##""start": "18:00", "end": "19:30", "weekday": 3, "color": "#00aa00""##, ##""start": "", "end": "", "weekday": 3, "color": "#00aa00""##),
            (#""start": "17:00", "end": "19:00", "weekday": 7"#, #""start": "17:00", "end": null, "weekday": 7"#),
            (##""start": "10:00", "end": "11:30", "weekday": 1, "color": "#3366cc""##, ##""start": "kaputt", "end": "11:30", "weekday": 1, "color": "#3366cc""##),
        ])
        let semWithoutIDs = apiReply(#"""
            {"data": [{"type": "course-events", "attributes": {"title": "Termin", "start": "2026-10-13T16:00:00+02:00", "end": "2026-10-13T17:30:00+02:00"}}], "links": {}}
            """#)
        let anaBrokenStart = try fixtureReply("course-events-c-ana-1.json", [(#""start": "2026-10-19T10:00:00+02:00""#, #""start": "19.10.2026""#)])
        let (d2, _) = try await download(["/jsonapi.php/v1/users/u-test/schedule": broken,
                                          "/jsonapi.php/v1/courses/c-sem/events?page[limit]=200": semWithoutIDs,
                                          "/jsonapi.php/v1/courses/c-ana/events?page[limit]=200": anaBrokenStart])
        XCTAssertNil(d2.scheduleError)
        XCTAssertEqual(d2.failedCourses, [])
        // pe-1, pe-2, pe-3, cy-ana-1, der Termin ohne Kennung in c-sem und in c-ana, ev-ana-2 mit kaputtem Beginn
        XCTAssertEqual(d2.unreadable, 7)
        XCTAssertEqual(d2.incompleteCourses, ["c-ana", "c-sem"])
        XCTAssertEqual(d2.keptEvents["c-ana"], ["ev-ana-2"])
        let r2 = try await store(d2, backend)
        XCTAssertEqual(r2.newEvents, 0)
        let seriesAfter = try await series(backend)
        XCTAssertEqual(seriesAfter, seriesBefore, "Stundenplan unveraendert")
        let personalAfter = try await dump(backend, ["studip_schedule_entries"])
        XCTAssertEqual(personalAfter, personalBefore, "eigene Eintraege ohne Uhrzeit ersetzen den gespeicherten Stand nicht")
        let cycleAfter = try await backend.context.database.scalar("SELECT data FROM studip_cycle_dates WHERE id='cy-ana-1'")
        XCTAssertEqual(cycleAfter, cycleBefore, "nicht lesbare Kurszeit behaelt ihren Stand")
        let cycleCount = try await backend.context.database.scalar("SELECT COUNT(*) FROM studip_cycle_dates")
        XCTAssertEqual(cycleCount, .integer(8))
        let sem = try await ids(backend, "SELECT id FROM studip_events WHERE course_id='c-sem' ORDER BY id")
        XCTAssertEqual(sem, ["ev-sem-1", "ev-sem-2", "ev-sem-3"], "Kurs nur mit Terminen ohne Kennung: kein Kursverlust")
        let ana = try await backend.context.database.rows("SELECT id, start FROM studip_events WHERE course_id='c-ana' ORDER BY id")
        XCTAssertEqual(ana.map { "\($0["id"]?.string ?? "")=\($0["start"]?.string ?? "")" },
                       ["ev-ana-1=2026-10-12T10:00:00", "ev-ana-2=2026-10-19T10:00:00", "ev-ana-3=2026-10-26T10:00:00", "ev-ana-k=2027-02-10T09:00:00"])

        // vollstaendige Antwort ohne pe-2 und ohne ev-sem-3: das verschwindet wie bisher
        let without = try scheduleReply([(#""id": "pe-2""#, #""id": "pe-9""#)])
        let semTwo = try fixtureReply("course-events-c-sem.json", [(#""id": "ev-sem-3""#, #""id": "ev-sem-4""#)])
        let (d3, _) = try await download(["/jsonapi.php/v1/users/u-test/schedule": without,
                                          "/jsonapi.php/v1/courses/c-sem/events?page[limit]=200": semTwo])
        _ = try await store(d3, backend)
        let personal3 = try await ids(backend, "SELECT id FROM studip_schedule_entries ORDER BY id")
        XCTAssertEqual(personal3, ["pe-1", "pe-9"])
        let sem3 = try await ids(backend, "SELECT id FROM studip_events WHERE course_id='c-sem' ORDER BY id")
        XCTAssertEqual(sem3, ["ev-sem-1", "ev-sem-2", "ev-sem-4"])
    }

    /// 423, 385, 386: leere, aber erfolgreiche Antworten ("wirklich keine Termine" laesst sich vom Geraet aus nicht von
    /// "unerwartet leer" unterscheiden) leeren nur die Abbilder der Stud.IP-Daten; der Stundenplan des Nutzers bleibt,
    /// und der naechste volle Abruf legt nichts doppelt an.
    func testEmptySuccessfulResponsesNeverRemoveTheTimetable() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let (d, _) = try await download()
        _ = try await store(d, backend)
        let before = try await dump(backend, ["course_events", "event_exceptions", "studip_timetable_links"])
        let empty = apiReply(#"{"data": [], "links": {}}"#)
        var replace = ["/jsonapi.php/v1/users/u-test/schedule": empty]
        for c in courses { replace["/jsonapi.php/v1/courses/\(c.id)/events?page[limit]=200"] = empty }
        let (d2, _) = try await download(replace)
        XCTAssertNil(d2.scheduleError)
        XCTAssertEqual(d2.cycles?.count, 0)
        let r2 = try await store(d2, backend)
        XCTAssertEqual(r2.newEvents, 0)
        XCTAssertEqual(r2.removedEvents, 0)
        let after = try await dump(backend, ["course_events", "event_exceptions", "studip_timetable_links"])
        XCTAssertEqual(after, before, "kein Termin des Stundenplans entfernt")
        let r3 = try await store(d, backend)
        XCTAssertEqual(r3.newEvents, 0, "voller Abruf danach: nichts doppelt")
        let again = try await dump(backend, ["course_events", "event_exceptions", "studip_timetable_links"])
        XCTAssertEqual(again, before)
    }

    /// 423 (strukturell): HTTP 200 ohne Liste `data` (z. B. `{}` oder nur `errors`) ist kein leerer Bestand, sondern
    /// ein Fehler; Kurszeiten, eigene Eintraege, Termine und Ankuendigungen bleiben wie gespeichert.
    func testSuccessWithoutDataListIsAFailure() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let news = "/jsonapi.php/v1/courses/c-ana/news?page[limit]=100"
        let item = apiReply(#"{"data": [{"id": "n1", "type": "news", "attributes": {"title": "Info", "content": "x", "publication-start": "2026-10-20T12:00:00+02:00"}}]}"#)
        let (d, _) = try await download([news: item])
        _ = try await store(d, backend)
        let tables = ["course_events", "event_exceptions", "studip_events", "studip_schedule_entries", "studip_cycle_dates",
                      "studip_timetable_links", "announcements"]
        let before = try await dump(backend, tables)
        for body in [#"{}"#, #"{"errors": [{"status": "500"}]}"#, #"{"data": null}"#, #"{"data": {"id": "x"}}"#] {
            let bad = apiReply(body)
            let (d2, _) = try await download(["/jsonapi.php/v1/users/u-test/schedule": bad,
                                              "/jsonapi.php/v1/courses/c-ana/events?page[limit]=200": bad,
                                              "/jsonapi.php/v1/courses/c-sem/events?page[limit]=200": bad, news: bad])
            XCTAssertNotNil(d2.scheduleError, body)
            XCTAssertNil(d2.cycles, body)
            XCTAssertNil(d2.personal, body)
            XCTAssertEqual(d2.failedCourses, ["c-ana", "c-sem"], body)
            XCTAssertNil(d2.news["c-ana"], body)
            _ = try await store(d2, backend)
            let after = try await dump(backend, tables)
            XCTAssertEqual(after, before, body)
        }
    }

    /// 424: erste Seite gelesen, Folgeseite gescheitert: der Kurs gilt als nicht geladen, seine Termine bleiben
    func testFailingLaterPageKeepsTheCourse() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let (d, _) = try await download()
        _ = try await store(d, backend)
        let before = try await dump(backend, ["studip_events", "course_events"])
        for failure in [serverError, HTTPReply(status: 200, contentType: "text/plain", body: Data("abgeschnitten".utf8))] {
            let (d2, t) = try await download(["/jsonapi.php/v1/courses/c-ana/events?page[offset]=3&page[limit]=200": failure])
            XCTAssertTrue(t.requested.contains("/jsonapi.php/v1/courses/c-ana/events?page[offset]=3&page[limit]=200"))
            XCTAssertEqual(d2.failedCourses, ["c-ana"])
            XCTAssertNil(d2.events["c-ana"], "keine halbe Liste")
            _ = try await store(d2, backend)
            let after = try await dump(backend, ["studip_events", "course_events"])
            XCTAssertEqual(after, before)
        }
    }

    /// 426: dieselbe Kennung zweimal (z. B. Seiten ueberlappen, weil sich die Liste zwischen zwei Abfragen verschoben
    /// hat): ein Eintrag, eine Serie, nichts doppelt
    func testDuplicateIDsCountOnce() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let overlap = try fixtureReply("course-events-c-ana-2.json", [(#"{"data": ["#, #"""
            {"data": [
             {"id": "ev-ana-3", "type": "course-events", "attributes": {"title": "Sitzung 3", "start": "2026-10-26T10:00:00+01:00",
              "end": "2026-10-26T11:30:00+01:00", "categories": "Sitzung", "location": "Hörsaal Test 1", "is-cancelled": false}},
            """#)])
        let cycleTwice = try scheduleReply([(#"{"data": ["#, #"""
            {"data": [
             {"id": "cy-ana-2", "type": "seminar-cycle-dates",
              "attributes": {"title": "Kurszeit", "description": "", "start": "08:15", "end": "09:45", "weekday": 4, "color": null,
                             "recurrence": {"FREQ": "WEEKLY", "INTERVAL": 2, "DTSTART": "2026-10-15", "UNTIL": "2027-01-28"},
                             "locations": ["Raum Test 2"]},
              "relationships": {"owner": {"data": {"type": "courses", "id": "c-ana"}}}},
            """#)])
        let (d, _) = try await download(["/jsonapi.php/v1/courses/c-ana/events?page[offset]=3&page[limit]=200": overlap,
                                         "/jsonapi.php/v1/users/u-test/schedule": cycleTwice])
        XCTAssertEqual(d.events["c-ana"]?.map(\.id), ["ev-ana-1", "ev-ana-2", "ev-ana-3", "ev-ana-k"])
        let r = try await store(d, backend)
        XCTAssertEqual(r.events, 7)
        XCTAssertEqual(r.newEvents, 8, "wie ohne Doppel")
        let cycles = try await backend.context.database.scalar("SELECT COUNT(*) FROM studip_cycle_dates")
        XCTAssertEqual(cycles, .integer(8))
        let s = try await series(backend)
        XCTAssertEqual(s.filter { $0.hasPrefix("Testanalysis I|3|") }.count, 1)
    }

    /// 427: Fehler mitten im Speichern (hier beim Protokoll am Ende von auto_import): die ganze Transaktion wird
    /// zurueckgerollt, keine Tabelle ist halb ersetzt; danach gelingt derselbe Abgleich.
    func testFailureDuringStoreRollsBackEverything() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let (d, _) = try await download()
        _ = try await store(d, backend)
        let before = try await dump(backend)
        let more = try scheduleReply([(anaExdates, #""EXDATES": ["2026-11-02T10:00:00+01:00", "2026-11-09T10:00:00+01:00"]"#),
                                      (#""id": "pe-2""#, #""id": "pe-7""#)])
        let semTwo = try fixtureReply("course-events-c-sem.json", [(#""id": "ev-sem-3""#, #""id": "ev-sem-8""#)])
        let (d2, _) = try await download(["/jsonapi.php/v1/users/u-test/schedule": more,
                                          "/jsonapi.php/v1/courses/c-sem/events?page[limit]=200": semTwo])
        try await backend.context.database.transaction {
            try $0.executeScript("CREATE TRIGGER test_abbruch BEFORE INSERT ON schedule_imports BEGIN SELECT RAISE(ABORT, 'Testabbruch'); END;")
        }
        do {
            _ = try await store(d2, backend)
            XCTFail("Speichern muss scheitern")
        } catch {}
        let after = try await dump(backend)
        XCTAssertEqual(after, before, "alles zurueckgerollt")
        try await backend.context.database.transaction { try $0.executeScript("DROP TRIGGER test_abbruch;") }
        _ = try await store(d2, backend)
        let shown = await day(backend, "2026-11-09")
        XCTAssertEqual(shown, ["Testanalysis I ausfall"])
        let personal = try await ids(backend, "SELECT id FROM studip_schedule_entries ORDER BY id")
        XCTAssertEqual(personal, ["pe-1", "pe-7"])
    }

    /// 387: eine beschaedigte gespeicherte Kurszeit wird beim Lesen uebersprungen (die anderen gelten weiter, ihre Serie
    /// bleibt), der naechste Abruf schreibt sie neu
    func testUnreadableStoredCycleIsSkippedAndRepairedByTheNextRun() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let (d, _) = try await download()
        _ = try await store(d, backend)
        let before = try await series(backend)
        try await backend.context.database.transaction { try $0.execute("UPDATE studip_cycle_dates SET data='{kaputt' WHERE id='cy-ana-1'") }
        let entries = try await backend.context.database.transaction { try StudIPScheduleStore.cycleEntries($0).map(\.entry.id) }
        XCTAssertFalse(entries.contains("cy-ana-1"))
        XCTAssertEqual(entries.count, 6, "die anderen Kurszeiten gelten weiter (ohne die Begruessung, sonstiges)")
        let r = try await store(StudIPScheduleDownload(courses: courses), backend)       // Abgleich ohne neue Daten
        XCTAssertEqual(r.newEvents, 0)
        let kept = try await series(backend)
        XCTAssertEqual(kept, before, "Serie der beschaedigten Kurszeit bleibt")
        _ = try await store(d, backend)
        let repaired = try await backend.context.database.scalar("SELECT data FROM studip_cycle_dates WHERE id='cy-ana-1'")
        XCTAssertNotNil(try JSONValue.parse(Data((repaired?.string ?? "").utf8))["attributes"])
        let after = try await series(backend)
        XCTAssertEqual(after, before)
    }

    /// 383: ein abgesagter Einzeltermin eines Kurses ohne Kurszeiten fehlt nicht still: die Serie aus den uebrigen
    /// Terminen zeigt den Tag als Ausfall (bei Kurszeiten kommt die Absage als EXDATE, siehe
    /// `testStoreImportsUniqueEntriesLikeAutoImport`)
    func testCancelledSingleDateStaysVisibleAsCancellation() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let sem = apiReply(#"""
            {"data": [
             {"id": "ev-sem-1", "type": "course-events", "attributes": {"title": "Termin", "start": "2026-10-13T16:00:00+02:00", "end": "2026-10-13T17:30:00+02:00", "location": "Seminarraum Test", "is-cancelled": false}},
             {"id": "ev-sem-2", "type": "course-events", "attributes": {"title": "Termin (fällt aus)", "start": "2026-10-20T16:00:00+02:00", "end": "2026-10-20T17:30:00+02:00", "location": "Seminarraum Test", "is-cancelled": true}},
             {"id": "ev-sem-3", "type": "course-events", "attributes": {"title": "Termin", "start": "2026-10-27T16:00:00+01:00", "end": "2026-10-27T17:30:00+01:00", "location": "Seminarraum Test", "is-cancelled": false}},
             {"id": "ev-sem-5", "type": "course-events", "attributes": {"title": "Termin", "start": "2026-11-03T16:00:00+01:00", "end": "2026-11-03T17:30:00+01:00", "location": "Seminarraum Test", "is-cancelled": false}}
            ], "links": {}}
            """#)
        let (d, _) = try await download(["/jsonapi.php/v1/courses/c-sem/events?page[limit]=200": sem])
        XCTAssertEqual(d.events["c-sem"]?.map(\.id), ["ev-sem-1", "ev-sem-3", "ev-sem-5"])
        _ = try await store(d, backend)
        let cancelled = await day(backend, "2026-10-20")
        XCTAssertEqual(cancelled, ["Testprogrammierung teilnahme", "Testseminar Beispiel ausfall"])
        let normal = await day(backend, "2026-10-27")
        XCTAssertEqual(normal, ["Testprogrammierung teilnahme", "Testseminar Beispiel teilnahme"])
    }

    /// 428: Kurs eines frueheren Semesters (Stud.IP legt je Semester eine neue Veranstaltung mit neuer Kennung an):
    /// seine Einzeltermine liegen im alten Semester, die abgeleitete Serie endet dort und erscheint nicht im laufenden
    /// Semester; Kurszeiten (users/{id}/schedule) kommen ohnehin nur fuer das laufende
    func testCourseOfAnEarlierSemesterStaysInItsSemester() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let old = apiReply(#"""
            {"data": [
             {"id": "ev-alt-1", "type": "course-events", "attributes": {"title": "Termin", "start": "2026-04-14T16:00:00+02:00", "end": "2026-04-14T17:30:00+02:00", "location": "Raum Alt"}},
             {"id": "ev-alt-2", "type": "course-events", "attributes": {"title": "Termin", "start": "2026-04-21T16:00:00+02:00", "end": "2026-04-21T17:30:00+02:00", "location": "Raum Alt"}},
             {"id": "ev-alt-3", "type": "course-events", "attributes": {"title": "Termin", "start": "2026-04-28T16:00:00+02:00", "end": "2026-04-28T17:30:00+02:00", "location": "Raum Alt"}}
            ], "links": {}}
            """#)
        let (d, _) = try await download(["/jsonapi.php/v1/courses/c-sem/events?page[limit]=200": old])
        _ = try await store(d, backend)
        let s = try await series(backend).filter { $0.hasPrefix("Testseminar Beispiel|") }
        XCTAssertEqual(s, ["Testseminar Beispiel|1|16:00|17:30|weekly|2026-04-14|2026-04-28|Raum Alt|seminar|studip"])
        let now = await day(backend, "2026-10-27")
        XCTAssertEqual(now, ["Testprogrammierung teilnahme"], "nichts aus dem alten Semester im laufenden")
    }

    /// 388: Kennungen aus Einzelterminen: zwei einzelne Termine desselben Kurses zur selben Zeit an verschiedenen Tagen
    /// bleiben zwei Eintraege (der Tag gehoert zur Kennung), Kurszeiten haben ihre Stud.IP-ID
    func testSingleDatesOfTheSameCourseAndTimeKeepTheirOwnKey() throws {
        let a: [String: JSONValue] = ["course_id": "c-sem", "title": "Termin", "weekday": 1, "start_time": "16:00", "end_time": "17:30",
                                      "rrule": "once", "date_from": "2026-10-13"]
        var b = a
        b["date_from"] = "2026-10-20"
        XCTAssertNotEqual(StudIPScheduleImport.key(a), StudIPScheduleImport.key(b))
        var cycle = a
        cycle["studip_id"] = "cy-1"
        XCTAssertEqual(StudIPScheduleImport.key(cycle), "cycle:cy-1")
        var personal = a
        personal["personal"] = true
        XCTAssertNotEqual(StudIPScheduleImport.key(personal), StudIPScheduleImport.key(a), "eigener Eintrag nie gleich einer Kursserie")
    }

    /// Kalender abgeschnitten (HTTP 200, aber ohne END:VCALENDAR): nichts wird entschieden, sonst galten alle Kurszeiten
    /// mit Terminen im fehlenden Teil als "nicht im Kalender" und verschwaenden aus dem Stundenplan
    func testTruncatedCalendarIsAnError() async throws {
        let ics = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:Stud.IP-SEM-ev-ana-1@studip.test\r\nDTSTART:20261012T080000Z\r\n"
        let t = StubTransport(try routes(["/jsonapi.php/v1/users/u-test/events.ics": HTTPReply(status: 200, contentType: "text/calendar", body: Data(ics.utf8))]))
        let client = StudIPClient(base: base, transport: t, pauseMillis: 0)
        do {
            _ = try await client.calendarICS(userID: "u-test")
            XCTFail("abgeschnittener Kalender")
        } catch let e as StudIPError {
            XCTAssertTrue(e.description.contains("unvollständig"), e.description)
        }
        let d = await StudIPScheduleStore.fetch(client: client, userID: "u-test", courses: courses)
        XCTAssertNil(d.calendar)
        XCTAssertNotNil(d.calendarError)
        let whole = StubTransport(try routes(["/jsonapi.php/v1/users/u-test/events.ics": HTTPReply(status: 200, contentType: "text/calendar",
                                                                                                    body: Data((ics + "END:VEVENT\r\nEND:VCALENDAR\r\n").utf8))]))
        let ok = try await StudIPClient(base: base, transport: whole, pauseMillis: 0).calendarICS(userID: "u-test")
        XCTAssertEqual(StudIPCalendar.dateIDs(ics: ok), ["ev-ana-1"])
    }
}
