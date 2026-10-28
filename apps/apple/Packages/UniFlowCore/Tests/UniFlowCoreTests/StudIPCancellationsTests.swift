import Foundation
import XCTest
@testable import UniFlowCore

// Ausfaelle laut Stud.IP wie Stud.IP ausblenden (Entscheidung des Inhabers, 28.10.2026), nur in der Anzeige: die
// Antworten von occurrences bleiben wie in Python, `GET /api/timetable/studip-cancelled` nennt die Ausfaelle laut
// Stud.IP, `StudIPCancellations.hiding` laesst sie weg. Selbst markierte Ausfaelle und "nicht besucht" bleiben. Erfundene
// Daten, Montag 26.10.2026.

private let clock = UniFlowClock.fixed(berlin: "2026-10-26T07:30:00")!

final class StudIPCancellationsTests: XCTestCase {

    private func call(_ b: LocalBackend, _ method: String, _ path: String, _ body: JSONValue? = nil) async -> LocalResponse {
        await b.handle(LocalRequest(method: method, url: URL(string: "uniflow-local://device" + path)!,
                                    headers: body == nil ? [:] : ["Content-Type": "application/json"], body: body?.serialized()))
    }

    /// Drei Serien am Montag: Vorlesung 10:00 (Ausfall laut Stud.IP), Uebung 14:00 (vom Nutzer als ausgefallen markiert),
    /// Tutorium 16:00 (heute nicht besucht)
    private func seeded() async throws -> LocalBackend {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        try await b.context.database.transaction { c in
            for (title, kind, start, end) in [("Testvorlesung Ausfall", "vorlesung", "10:00", "11:30"), ("Testübung Ausfall", "uebung", "14:00", "15:30"),
                                              ("Testtutorium Ausfall", "tutorium", "16:00", "17:00")] {
                try c.execute("""
                    INSERT INTO course_events(title, kind, weekday, start_time, end_time, rrule, date_from, date_to, attend, source, created_at)
                    VALUES (?,?,0,?,?,'weekly','2026-10-12','2027-01-25',1,'studip','2026-10-01T08:00:00')
                    """, [.text(title), .text(kind), .text(start), .text(end)])
            }
            // wie der Abgleich (apply_import mit Quelle studip, StudIPScheduleImport.refresh)
            try LocalTimetableImport.addCancellations(c, eventID: .integer(1), dates: ["2026-10-26", "2026-12-21"],
                                                      note: StudIPCancellations.note, clock: clock)
        }
        let user = await call(b, "POST", "/api/timetable/attendance", ["event_id": 2, "date": "2026-10-26", "mode": "cancelled"])
        XCTAssertEqual(user.status, 200)
        let skip = await call(b, "POST", "/api/timetable/attendance", ["event_id": 3, "date": "2026-10-26", "mode": "today_skip"])
        XCTAssertEqual(skip.status, 200)
        return b
    }

    func testListNamesOnlyStudIPCancellations() async throws {
        let b = try await seeded()
        let r = await call(b, "GET", "/api/timetable/studip-cancelled?start=2026-10-26&end=2026-11-01")
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.json, [["event_id": 1, "date": "2026-10-26"]], "nur der Ausfall laut Stud.IP, nicht der selbst markierte")
        let all = await call(b, "GET", "/api/timetable/studip-cancelled?start=2026-10-01&end=2026-12-31")
        XCTAssertEqual(all.json?.array?.count, 2)
        for bad in ["/api/timetable/studip-cancelled?start=2026-10-26", "/api/timetable/studip-cancelled?start=x&end=2026-11-01",
                    "/api/timetable/studip-cancelled?start=2026-11-01&end=2026-10-26"] {
            let r = await call(b, "GET", bad)
            XCTAssertEqual(r.status, 422, bad)
        }
    }

    /// Die Woche des lokalen Backends bleibt wie in Python (Ausfall mit `status: ausfall`); ausgeblendet wird erst mit
    /// der Liste, und nur der Ausfall laut Stud.IP
    func testHidingKeepsUserMarksAndLeavesTheResponseAlone() async throws {
        let b = try await seeded()
        let week = await call(b, "GET", "/api/timetable/week?start=2026-10-26")
        let raw = try XCTUnwrap(week.json)
        func monday(_ v: JSONValue) -> [String] {
            (v["days"]?.array?.first?["events"]?.array ?? []).map { "\($0["title"]?.string ?? "") \($0["status"]?.string ?? "")" }
        }
        XCTAssertEqual(monday(raw), ["Testvorlesung Ausfall ausfall", "Testübung Ausfall ausfall", "Testtutorium Ausfall nicht_teilnahme"],
                       "Antwort unverändert wie in Python")
        let keys = StudIPCancellations.keys(await call(b, "GET", "/api/timetable/studip-cancelled?start=2026-10-26&end=2026-11-01").json)
        let shown = StudIPCancellations.hiding(in: raw, keys: keys)
        XCTAssertEqual(monday(shown), ["Testübung Ausfall ausfall", "Testtutorium Ausfall nicht_teilnahme"])
        XCTAssertEqual(shown["days"]?.array?.first?["free"], raw["days"]?.array?.first?["free"], "freie Fenster unverändert")
        // Tag und Lernkalender haben dieselbe Form
        let day = await call(b, "GET", "/api/timetable/day?date=2026-10-26")
        XCTAssertEqual(StudIPCancellations.hiding(in: try XCTUnwrap(day.json), keys: keys)["events"]?.array?.count, 2)
        let cal = await call(b, "GET", "/api/calendar?start=2026-10-26&end=2026-10-26")
        let calShown = StudIPCancellations.hiding(in: try XCTUnwrap(cal.json), keys: keys)
        XCTAssertEqual(calShown["days"]?.array?.first?["events"]?.array?.count, 2)
        XCTAssertEqual(StudIPCancellations.hiding(in: raw, keys: []), raw, "ohne Ausfaelle laut Stud.IP alles wie geliefert")
        // Woche des Vertrags woche.json: der Ausfall am 19.11. bleibt in der Antwort, nur die Anzeige laesst ihn weg
        let other: JSONValue = ["event_id": 1, "date": "2026-10-26", "status": "teilnahme", "exception": .null]
        XCTAssertFalse(StudIPCancellations.hides(other, keys: keys), "nur Ausfaelle")
    }

    /// Ein Ausfall laut Stud.IP ist keine belegte Zeit: freie Fenster und Lernplan haben die Zeit frei
    func testStudIPCancellationIsFreeTime() async throws {
        let b = try await seeded()
        let (busy, free) = try await b.context.database.withConnection { c -> ([LocalFreeWindows.Block], [JSONValue]) in
            let d = try XCTUnwrap(BerlinClock.parseISODate("2026-10-26"))
            let s = try LocalSettings.read(c)
            return (try LocalFreeWindows.busyBlocks(c, day: d, settings: s, includePackages: false), try LocalFreeWindows.compute(c, day: d, settings: s))
        }
        XCTAssertFalse(busy.contains { $0.kind == "event" }, "alle drei Termine frei: Ausfall laut Stud.IP, eigener Ausfall, nicht besucht")
        XCTAssertTrue(free.contains { ($0["start"]?.int ?? 9999) <= 10 * 60 && ($0["end"]?.int ?? 0) >= 11 * 60 + 30 }, "\(free)")
    }
}
