import Foundation
import XCTest
@testable import UniFlowCore

// Woche aus dem eigenen Stud.IP-Kalender am Abruftag und vor dem ersten Abruf (Befund mit echten Daten, 28.10.2026:
// Abruf am 27.10. um 02:39, Montag 26.10. und Dienstag 27.10. zeigten jede parallele Uebungsgruppe). Regel und
// Begruendung: docs/IPAD-STUDIP-SYNC.md §10, `StudIPCalendar.Coverage`. Alle Daten erfunden.
//
// Kurse: Vorlesung montags 10:00, Uebung dienstags in drei Gruppen (A 10:00 eigene, B 12:00, C 14:00), ein Kurs ganz
// ohne Kalendertermin (mittwochs 08:00) und eine Fruehuebung dienstags 01:00 (eigene) neben einer fremden um 00:30.
// Erster Abruf am Dienstag 27.10.2026 um 02:39: der Export beginnt mit dem Abruf, die Fruehuebung des Tages fehlt darin.

private let fetch1 = UniFlowClock.fixed(berlin: "2026-10-27T02:39:00")!
private let fetch2 = UniFlowClock.fixed(berlin: "2026-11-04T09:00:00")!

private let courses: [(String, String, String)] = [
    ("k-vl", "Testvorlesung Abruf", "vorlesung"), ("k-ue", "Übung Testprogrammierung Abruf", "uebung"),
    ("k-frei", "Testkurs ohne Kalender", "vorlesung"), ("k-frueh", "Frühübung Abruf", "uebung"),
]

/// (ID, Kurs, Beginn, Ende)
private let events: [(String, String, String, String)] = {
    var out: [(String, String, String, String)] = []
    for d in ["2026-10-19", "2026-10-26", "2026-11-02", "2026-11-09"] {
        out.append(("vl-\(d)", "k-vl", "\(d)T10:00:00", "\(d)T11:30:00"))
    }
    for d in ["2026-10-20", "2026-10-27", "2026-11-03", "2026-11-10"] {
        for (g, t, e) in [("A", "10:00", "11:30"), ("B", "12:00", "13:30"), ("C", "14:00", "15:30")] {
            out.append(("ue-\(g)-\(d)", "k-ue", "\(d)T\(t):00", "\(d)T\(e):00"))
        }
    }
    for d in ["2026-10-21", "2026-10-28", "2026-11-04"] { out.append(("frei-\(d)", "k-frei", "\(d)T08:00:00", "\(d)T09:30:00")) }
    out.append(("fr-2026-10-27", "k-frueh", "2026-10-27T01:00:00", "2026-10-27T02:00:00"))
    out.append(("fr-2026-11-03", "k-frueh", "2026-11-03T01:00:00", "2026-11-03T02:00:00"))
    out.append(("frx-2026-10-27", "k-frueh", "2026-10-27T00:30:00", "2026-10-27T01:30:00"))   // fremde Gruppe
    return out
}()

/// Erster Abruf: alles Eigene ab 27.10. 02:39 (die Fruehuebung des Tages begann schon)
private let calendar1 = ["ue-A-2026-10-27", "ue-A-2026-11-03", "ue-A-2026-11-10", "vl-2026-11-02", "vl-2026-11-09", "fr-2026-11-03"]

final class StudIPCalendarFetchDayTests: XCTestCase {

    private func backend(_ clock: UniFlowClock = fetch1) async throws -> LocalBackend {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        try await b.context.database.transaction { c in
            for (id, title, kind) in courses {
                try c.execute("INSERT INTO courses(id, title, semester, kind, active, created_at) VALUES (?,?,'WiSe 2026/27',?,1,'2026-10-01T08:00:00')",
                              [.text(id), .text(title), .text(kind)])
            }
            for (id, course, st, en) in events {
                try c.execute("INSERT INTO studip_events(id, course_id, title, start, end, room, fetched_at) VALUES (?,?,'Termin',?,?,'',?)",
                              [.text(id), .text(course), .text(st), .text(en), .text("2026-10-27T02:39:00")])
            }
            XCTAssertTrue(try StudIPCalendar.store(ids: calendar1, in: c, clock: fetch1))
        }
        return b
    }

    /// Termine eines Tages als "Titel Beginn Status"
    private func day(_ b: LocalBackend, _ iso: String) async throws -> [String] {
        let d = try XCTUnwrap(BerlinClock.parseISODate(iso))
        return try await b.context.database.withConnection { c in
            try LocalTimetable.occurrences(c, from: d, to: d).map { "\($0["title"]?.string ?? "") \($0["start"]?.string ?? "") \($0["status"]?.string ?? "")" }
        }
    }

    /// Abruftag: nur die eigene Gruppe; die Fruehuebung, die vor dem Abruf begann und darum nicht im Export steht, ueber
    /// ihren Zeitschlitz (derselbe Kurs dienstags 01:00-02:00 steht am 03.11. im Kalender); die fremde um 00:30 nicht.
    /// Vorher (PC-Regel: Kalender erst ab dem Tag nach dem Abruf) standen alle fuenf Termine da.
    func testFetchDayShowsOnlyOwnGroups() async throws {
        let b = try await backend()
        let tue = try await day(b, "2026-10-27")
        XCTAssertEqual(tue, ["Frühübung Abruf 01:00 teilnahme", "Übung Testprogrammierung Abruf 10:00 teilnahme"])
    }

    /// Zwischen Abruf und erstem eigenen Termin entscheidet der Kalender: eine Gruppe dienstags 08:15, die erst ab
    /// 10.11. die eigene ist (Befund mit echten Daten), steht am Abruftag 27.10. um 08:15 nicht im Export und ist darum
    /// nicht die eigene, obwohl der erste Kalendertermin erst um 10:00 beginnt. Vor dem ersten Abruf (20.10.) gilt der
    /// Zeitschlitz. Vorher (Grenze = fruehester Kalendertermin) stand sie am 27.10. da, am 03.11. nicht.
    func testFetchDayBeforeFirstOwnDateFollowsTheCalendar() async throws {
        let b = try await backend()
        try await b.context.database.transaction { c in
            try c.execute("INSERT INTO courses(id, title, semester, kind, active, created_at) VALUES ('k-spaet','Spätgruppe Abruf','WiSe 2026/27','uebung',1,'2026-10-01T08:00:00')")
            for d in ["2026-10-20", "2026-10-27", "2026-11-03", "2026-11-10"] {
                try c.execute("INSERT INTO studip_events(id, course_id, title, start, end, room, fetched_at) VALUES (?,'k-spaet','Termin',?,?,'',?)",
                              [.text("sp-\(d)"), .text("\(d)T08:15:00"), .text("\(d)T09:45:00"), .text("2026-10-27T02:39:00")])
            }
            XCTAssertTrue(try StudIPCalendar.store(ids: calendar1 + ["sp-2026-11-10"], in: c, clock: fetch1))
        }
        let fetchDay = try await day(b, "2026-10-27")
        XCTAssertEqual(fetchDay, ["Frühübung Abruf 01:00 teilnahme", "Übung Testprogrammierung Abruf 10:00 teilnahme"])
        let next = try await day(b, "2026-11-03")
        XCTAssertFalse(next.contains { $0.hasPrefix("Spätgruppe") }, "\(next)")
        let own = try await day(b, "2026-11-10")
        XCTAssertEqual(own, ["Spätgruppe Abruf 08:15 teilnahme", "Übung Testprogrammierung Abruf 10:00 teilnahme"])
        let before = try await day(b, "2026-10-20")
        XCTAssertEqual(before, ["Spätgruppe Abruf 08:15 teilnahme", "Übung Testprogrammierung Abruf 10:00 teilnahme"], "Zeitschlitz")
    }

    /// Woche vor dem ersten Abruf: nur Termine im Zeitschlitz eines Kalendertermins desselben Kurses; ein Kurs ganz
    /// ohne Kalendertermin faellt weg. Serien: automatisch uebernommene fremde Gruppe faellt weg, ihr gespeicherter
    /// Ausfall laut Stud.IP bleibt sichtbar; von Hand bestaetigte und eigene Serien bleiben immer.
    func testWeekBeforeFirstFetchShowsOwnSlotsOnly() async throws {
        let b = try await backend()
        try await b.context.database.transaction { c in
            let cols = "course_id, title, kind, weekday, start_time, end_time, room, rrule, date_from, date_to, source, attend, created_at"
            for v: [SQLiteValue] in [
                ["k-ue", "Übung Testprogrammierung Abruf", "uebung", 1, "12:00", "13:30", "", "weekly", "2026-10-13", "2027-01-26", "studip"],
                ["k-frei", "Testkurs ohne Kalender", "vorlesung", 2, "08:00", "09:30", "", "weekly", "2026-10-14", "2027-01-27", "studip-manual"],
                [.null, "Testlerngruppe", "sonstiges", 3, "18:00", "19:30", "", "weekly", "2026-10-15", "2027-01-28", "manual"],
            ] {
                try c.execute("INSERT INTO course_events(\(cols)) VALUES (?,?,?,?,?,?,?,?,?,?,?,1,'2026-10-01T08:00:00')", v)
            }
            let b12 = try XCTUnwrap(try c.queryOne("SELECT id FROM course_events WHERE start_time='12:00'")?["id"])
            try c.execute("INSERT INTO event_exceptions(event_id, date, type, note, created_at) VALUES (?, '2026-10-20', 'cancelled', 'Ausfall laut Stud.IP', '2026-10-02T08:00:00')", [b12])
        }
        let mon = try await day(b, "2026-10-19")
        XCTAssertEqual(mon, ["Testvorlesung Abruf 10:00 teilnahme"], "Zeitschlitz der Vorlesung steht im Kalender")
        let tue = try await day(b, "2026-10-20")
        XCTAssertEqual(tue, ["Übung Testprogrammierung Abruf 10:00 teilnahme", "Übung Testprogrammierung Abruf 12:00 ausfall"],
                       "eigene Gruppe; die fremde Serie nur mit ihrem gespeicherten Ausfall")
        let wed = try await day(b, "2026-10-21")
        XCTAssertEqual(wed, ["Testkurs ohne Kalender 08:00 teilnahme"], "nur die von Hand bestaetigte Serie, nicht der Einzeltermin")
        let wedDated = try await b.context.database.withConnection { c in
            try LocalTimetable.studipDated(c, from: BerlinClock.parseISODate("2026-10-21")!, to: BerlinClock.parseISODate("2026-10-21")!)
        }
        XCTAssertEqual(wedDated.count, 0, "Kurs ganz ohne Kalendertermin")
        let thu = try await day(b, "2026-10-22")
        XCTAssertEqual(thu, ["Testlerngruppe 18:00 teilnahme"])
        let monBefore = try await day(b, "2026-10-26")
        XCTAssertEqual(monBefore, ["Testvorlesung Abruf 10:00 teilnahme"], "Montag vor dem Abruf wie die Woche davor")
        let tueAfter = try await day(b, "2026-10-27")
        XCTAssertEqual(tueAfter, ["Frühübung Abruf 01:00 teilnahme", "Übung Testprogrammierung Abruf 10:00 teilnahme"],
                       "die fremde Serie ohne Ausnahme faellt weg")
    }

    /// Zweiter Abruf: IDs frueherer Abrufe bleiben, vergangene Tage bleiben auf dem zuletzt gesehenen Stand,
    /// `max(fetched_at)` ist der letzte Abruf. Vorher ersetzte jeder Abruf den Kalender.
    func testSecondFetchKeepsEarlierIDs() async throws {
        let b = try await backend()
        try await b.context.database.transaction { c in
            XCTAssertTrue(try StudIPCalendar.store(ids: ["ue-A-2026-11-10", "vl-2026-11-09"], in: c, clock: fetch2))
        }
        let ids = try await b.context.database.rows("SELECT id FROM studip_calendar_dates ORDER BY id").compactMap { $0["id"]?.string }
        XCTAssertEqual(ids, calendar1.sorted())
        let last = try await b.context.database.scalar("SELECT MAX(fetched_at) FROM studip_calendar_dates")
        XCTAssertEqual(last, .text("2026-11-04T09:00:00"))
        let kept = try await b.context.database.scalar("SELECT fetched_at FROM studip_calendar_dates WHERE id='ue-A-2026-10-27'")
        XCTAssertEqual(kept, .text("2026-10-27T02:39:00"), "frueherer Abruf mit seinem Zeitpunkt")
        let tue = try await day(b, "2026-11-03")
        XCTAssertEqual(tue, ["Frühübung Abruf 01:00 teilnahme", "Übung Testprogrammierung Abruf 10:00 teilnahme"])
        let earlier = try await day(b, "2026-10-27")
        XCTAssertEqual(earlier, ["Frühübung Abruf 01:00 teilnahme", "Übung Testprogrammierung Abruf 10:00 teilnahme"])
    }

    /// Aus dem Kalender entfernt (Gruppe gewechselt): ab dem neuen Abruf nicht mehr, davor bleibt der alte Stand
    func testRemovedDateDisappearsFromTheNewFetchOnButNotBefore() async throws {
        let b = try await backend()
        try await b.context.database.transaction { c in
            XCTAssertTrue(try StudIPCalendar.store(ids: ["ue-B-2026-11-10", "vl-2026-11-09"], in: c, clock: fetch2))
        }
        let ids = Set(try await b.context.database.rows("SELECT id FROM studip_calendar_dates").compactMap { $0["id"]?.string })
        XCTAssertFalse(ids.contains("ue-A-2026-11-10"), "Termin nach dem Abruf, nicht mehr im Kalender")
        XCTAssertTrue(ids.contains("ue-A-2026-11-03"), "Termin vor dem Abruf bleibt")
        let after = try await day(b, "2026-11-10")
        XCTAssertEqual(after, ["Übung Testprogrammierung Abruf 12:00 teilnahme"], "neue Gruppe")
        let before = try await day(b, "2026-11-03")
        XCTAssertEqual(before, ["Frühübung Abruf 01:00 teilnahme", "Übung Testprogrammierung Abruf 10:00 teilnahme"], "alte Gruppe davor")
    }

    /// Uebersicht "Heute an der Uni" am Abruftag (nach jedem Abgleich ist heute der Abruftag): nur eigene Termine
    func testDashboardTodayOnFetchDay() async throws {
        let b = try await backend(UniFlowClock.fixed(berlin: "2026-10-27T08:00:00")!)
        let r = await b.handle(LocalRequest(method: "GET", path: "/api/dashboard"))
        XCTAssertEqual(r.status, 200)
        let today = (r.json?["today"]?["events"]?.array ?? []).map { "\($0["title"]?.string ?? "") \($0["start"]?.string ?? "")" }
        XCTAssertEqual(today, ["Frühübung Abruf 01:00", "Übung Testprogrammierung Abruf 10:00"])
    }

    /// Termin ohne bekannten Einzeltermin (z. B. Kurs nicht abgeglichen): seine ID bleibt beim naechsten Abruf
    func testUnknownDateKeepsItsID() async throws {
        let b = try await backend()
        try await b.context.database.transaction { c in
            try c.execute("INSERT INTO studip_calendar_dates(id, fetched_at) VALUES ('unbekannt', '2026-10-27T02:39:00')")
            XCTAssertTrue(try StudIPCalendar.store(ids: ["vl-2026-11-09"], in: c, clock: fetch2))
        }
        let n = try await b.context.database.scalar("SELECT COUNT(*) FROM studip_calendar_dates WHERE id='unbekannt'")
        XCTAssertEqual(n?.int, 1)
    }
}
