import Foundation
import XCTest
@testable import UniFlowCore

// Stud.IP-Ergaenzungen (02.11.2026) gegen die Python-Referenz packages/shared-contracts/fixtures/studip-extras/extras.json
// (tools/gen-studip-extras-fixture.py, erfundene JSON:API-Antworten, Tag 02.11.2026): Semester und vorlesungsfreie
// Zeiten (Planer, Lernplan), fehlende Endpunkte, Stud.IP-weite Ankuendigungen, Nachrichten nur als Liste, Activity-Stream,
// Sprechstunden, Karte "Neuigkeiten". Dazu der Abruf ueber den Client (404 gemerkt, 400 -> ohne include) und das Speichern.

private func extras() throws -> JSONValue {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return try JSONValue.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/studip-extras/extras.json")))
}

private func day(_ s: String?) throws -> Int { try XCTUnwrap(BerlinClock.parseISODate(s ?? "")) }

private func itemJSON(_ a: Announcements.Item) -> JSONValue {
    ["id": .string(a.id), "source": .string(a.source), "course_id": a.courseID.map(JSONValue.string) ?? .null, "title": .string(a.title),
     "text": .string(a.text), "author": .string(a.author), "posted_at": .string(a.postedAt), "url": a.url.map(JSONValue.string) ?? .null,
     "discussion": a.discussion.map(JSONValue.string) ?? .null, "dates": .array(a.dates)]
}

private func assertSame(_ got: JSONValue, _ want: JSONValue?, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertNil(jsonDiff(got, want), "\(what): \(jsonDiff(got, want) ?? "")", file: file, line: line)
}

final class StudIPExtrasTests: XCTestCase {

    private var studip: StudIPTerms.Stored {
        get throws {
            let fx = try extras()
            return StudIPTerms.Stored(semesters: StudIPTerms.parseSemesters(fx["semesters"]?["response"]?["data"]),
                                      holidays: StudIPTerms.parseHolidays(fx["holidays"]?["response"]?["data"]))
        }
    }

    func testSemestersAndHolidaysMatchPython() throws {
        let fx = try extras()
        assertSame(.array(StudIPTerms.parseSemesters(fx["semesters"]?["response"]?["data"]).map(\.json)), fx["semesters"]?["parsed"], "Semester")
        assertSame(.array(StudIPTerms.parseHolidays(fx["holidays"]?["response"]?["data"]).map(\.json)), fx["holidays"]?["parsed"], "Ferien")
        let merged: JSONValue = .array(StudIPTerms.mergedSemesters(university: "luh", studip: try studip).map { s in
            [.string(s.name), .string(s.start), .string(s.end), .array(s.breaks.map { [.string($0.from), .string($0.to), .string($0.label)] })]
        })
        assertSame(merged, fx["merged_semesters"], "Zeitplan mit Stud.IP")
    }

    func testDayMarksMatchPython() throws {
        let fx = try extras()
        let s = try studip
        for m in fx["day_marks"]?.array ?? [] {
            let lo = try day(m["from"]?.string), hi = try day(m["to"]?.string)
            assertSame(.object(Holidays.dayMarks(from: lo, to: hi, university: "luh").mapValues(JSONValue.array)), m["plain"], "ohne Stud.IP")
            assertSame(.object(Holidays.dayMarks(from: lo, to: hi, university: "luh", studip: s).mapValues(JSONValue.array)), m["studip"], "mit Stud.IP")
        }
    }

    func testLectureWeekInBreaksMatchesPython() throws {
        let fx = try extras()
        let today = try day(fx["today"]?.string), sem = try day(fx["lecture_week"]?["semester_start"]?.string)
        let free = StudIPTerms.freeDays(from: try day("2026-12-21"), to: try day("2027-02-10"), university: "luh", studip: try studip)
        let cases = fx["lecture_week"]?["days"]?.array ?? []
        XCTAssertEqual(cases.count, 7)
        for c in cases {
            let d = try day(c["day"]?.string)
            XCTAssertEqual(StudIPTerms.lectureWeek(semesterStart: sem, day: d, today: today, free: free), c["week"]?.int, c["day"]?.string ?? "")
            XCTAssertEqual(StudyWeeks.dayWeek(start: sem, day: d, today: today), c["plain_week"]?.int)
        }
    }

    func testMissingEndpointsMatchPython() throws {
        let fx = try extras()
        for c in fx["should_ask"]?.array ?? [] {
            XCTAssertEqual(StudIPExtras.shouldAsk(c["missing"]?.object ?? [:], c["name"]?.string ?? "", today: c["today"]?.string ?? ""), c["ask"]?.bool)
        }
        for c in fx["remember"]?.array ?? [] {
            let got = StudIPExtras.remember(c["missing"]?.object ?? [:], c["name"]?.string ?? "", status: c["status"]?.int ?? 0, today: "2026-11-02")
            assertSame(.object(got), c["after"], "remember")
        }
    }

    func testParsersMatchPython() throws {
        let fx = try extras()
        let base = try XCTUnwrap(fx["base"]?.string), today = try day(fx["today"]?.string)
        assertSame(.array(StudIPExtras.globalNews(fx["global_news"]?["response"]?["data"], base: base, today: today).map(itemJSON)),
                   fx["global_news"]?["items"], "Stud.IP-weit")
        let inbox = fx["messages"]?["response"]
        let msgs = StudIPExtras.parseMessages(inbox?["data"], included: inbox?["included"], base: base, today: today)
        assertSame(.array(msgs.map(\.json)), fx["messages"]?["items"], "Nachrichten")
        XCTAssertEqual(msgs.first?.sender, "Lehrende", "Rolle statt Name")
        assertSame(.array(StudIPExtras.parseActivity(fx["activity"]?["response"]?["data"], base: base).map(\.json)), fx["activity"]?["items"], "Aenderungen")
        let b = fx["bookings"]?["response"]
        assertSame(.array(StudIPExtras.parseBookings(b?["data"], included: b?["included"]).map(\.json)), fx["bookings"]?["items"], "Sprechstunden")
    }

    func testFeedMatchesPython() throws {
        let fx = try extras()
        let f = fx["feed"]
        let got = StudIPExtras.feed(news: f?["news"]?.array ?? [], messages: fx["messages"]?["items"]?.array ?? [],
                                    activity: f?["activity"]?.array ?? [], today: fx["today"]?.string ?? "")
        assertSame(.array(got), f?["items"], "Neuigkeiten")
        XCTAssertEqual(got.prefix(3).map { $0["kind"]?.string }, ["ankuendigung", "nachricht", "aenderung"])
    }

    // MARK: Abruf ueber den Client und Speichern

    private func reply(_ v: JSONValue?) throws -> HTTPReply {
        HTTPReply(status: 200, contentType: "application/vnd.api+json", body: try XCTUnwrap(v).serialized())
    }

    func testFetchRemembersMissingAndStores() async throws {
        let fx = try extras()
        let p = "/jsonapi.php/v1/"
        let bookingsOnly: JSONValue = ["data": fx["bookings"]?["response"]?["data"] ?? .array([])]
        let t = StubTransport([
            p + "semesters?page[limit]=100": try reply(fx["semesters"]?["response"]),
            p + "studip/news?page[limit]=50": try reply(fx["global_news"]?["response"]),
            p + "users/u1/inbox?page[limit]=30&include=sender": try reply(fx["messages"]?["response"]),
            p + "users/u1/activitystream": try reply(fx["activity"]?["response"]),
            p + "users/u1/consultation-bookings?include=slot,slot.block": HTTPReply(status: 400, contentType: "application/vnd.api+json", body: Data("{}".utf8)),
            p + "users/u1/consultation-bookings": try reply(bookingsOnly),
        ])
        let client = StudIPClient(base: URL(string: "https://studip.test")!, transport: t, pauseMillis: 0)
        let clock = try XCTUnwrap(UniFlowClock.fixed(berlin: "2026-11-02T10:00:00"))
        let today = try day("2026-11-02")
        let d = await StudIPExtras.fetch(client: client, userID: "u1", missing: [:], today: today)
        XCTAssertEqual(d.missing, ["holidays": "2026-11-02"])
        XCTAssertNil(d.holidays)
        XCTAssertEqual(d.semesters?.count, 4)
        XCTAssertEqual(d.bookings?.count, 0, "ohne include keine Zeiten: nichts geraten")
        XCTAssertTrue(t.requested.contains(p + "users/u1/consultation-bookings"))
        XCTAssertFalse(t.requested.contains { $0.contains("/messages/") }, "nie die Einzelansicht einer Nachricht")

        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        try await backend.context.database.transaction { c in
            try c.execute("INSERT INTO courses(id, title, kind, active, created_at) VALUES ('k-vl', 'Testmathematik', 'vorlesung', 1, 't')")
            try StudIPExtras.store(d, in: c, clock: clock)
        }
        let items = try await backend.context.database.withConnection { try StudIPExtras.feedFor($0, today: today) }
        XCTAssertEqual(Set(items.compactMap { $0["kind"]?.string }), ["ankuendigung", "nachricht", "aenderung"])
        XCTAssertTrue(items.contains { $0["who"]?.string == "Stud.IP-weit" })

        // naechster Abruf: holidays nicht erneut gefragt
        let missing = try await backend.context.database.withConnection { try StudIPExtras.loadMissing($0) }
        let t2 = StubTransport([:])
        _ = await StudIPExtras.fetch(client: StudIPClient(base: URL(string: "https://studip.test")!, transport: t2, pauseMillis: 0),
                                     userID: "u1", missing: missing, today: today)
        XCTAssertFalse(t2.requested.contains { $0.contains("holidays") })
        XCTAssertTrue(t2.requested.contains { $0.contains("semesters") })

        // Endpunkt /api/news
        let news = await backend.handle(LocalRequest(method: "GET", path: "/api/news"))
        XCTAssertEqual(news.status, 200)
    }

    func testConsultationsAndHolidaysReachThePlanner() async throws {
        let clock = try XCTUnwrap(UniFlowClock.fixed(berlin: "2026-11-02T10:00:00"))
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let s = try studip
        try await backend.context.database.transaction { c in
            try StudIPExtras.storeConsultations(c, [StudIPExtras.Booking(id: "b1", start: "2026-11-05T14:00:00", end: "2026-11-05T14:15:00", room: "Raum 101")],
                                                fetchedAt: "t")
            try StudIPTerms.store(c, holidays: s.holidays, fetchedAt: "t")
        }
        let (occ, marks) = try await backend.context.database.withConnection { c in
            (try LocalTimetable.occurrences(c, from: try day("2026-11-05"), to: try day("2026-11-05")),
             try Holidays.calendarExtras(c, from: try day("2026-11-18"), to: try day("2026-11-18"), university: "luh").marks)
        }
        let consult = occ.filter { $0["source"]?.string == "studip-sprechstunde" }
        XCTAssertEqual(consult.count, 1)
        XCTAssertEqual(consult.first?["start"]?.string, "14:00")
        XCTAssertEqual(consult.first?["event_id"], .null)
        XCTAssertEqual(marks["2026-11-18"], [["kind": "pause", "label": "Hochschultag"]])
    }
}
