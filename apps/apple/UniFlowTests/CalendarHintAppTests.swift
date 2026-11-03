import SwiftUI
import UIKit
import XCTest
import UniFlowCore
@testable import UniFlow

/// Hinweise im Kalenderkopf antippbar (Auftrag des Inhabers 03.11.2026): je Art (Ausfall, Raumaenderung, Pruefung aus
/// Ankuendigungen, Learnweb-/Courseware-Frist, Feiertag, vorlesungsfreie Zeit) zeigt das Detail Art, Datum und Uhrzeit,
/// Kurs, den Satz aus der Quelle, die Quelle mit Titel und Datum, "Quelle öffnen" nur fuer http(s) und den Termin
/// dazu. Lokales Backend mit eingefrorener Uhr, nur erfundene Daten.
@MainActor
final class CalendarHintAppTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-hint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func awaiting<T>(_ body: @escaping @MainActor () async throws -> T) throws -> T {
        var result: Result<T, Error>?
        let done = expectation(description: "async")
        Task { @MainActor in
            do { result = .success(try await body()) } catch { result = .failure(error) }
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
        return try XCTUnwrap(result).get()
    }

    /// Modul mit Vorlesung (Do 10:15) und Uebung (Do 14:15); Ankuendigungen: Ausfall der Vorlesung, Raum der Uebung,
    /// Klausur am Freitag; Courseware-Frist Do 12:00 und Learnweb-Frist mit javascript:-Adresse
    private func seededAPI() async throws -> APIClient {
        let host = LocalBackendHost(directory: try tempDir().appendingPathComponent("db", isDirectory: true),
                                    clock: .fixed(berlin: "2026-11-02T09:30:00")!)
        let backend = try await host.backend()
        let news = [
            Announcements.make(id: "sp-news-h1", source: "studip", courseID: "k-vl", title: "Hinweis zur Vorlesung",
                               bodyHTML: "<p>Die Vorlesung am 12.11. fällt aus.</p>", author: "",
                               postedAt: "2026-11-02T09:00:00+01:00", url: "https://studip.example/news/1", today: 0),
            Announcements.make(id: "sp-news-h2", source: "studip", courseID: "k-ue", title: "Raum der Übung",
                               bodyHTML: "<p>Die Übung am 12.11. um 14:15 Uhr ist in Raum F 102.</p>", author: "",
                               postedAt: "2026-11-01T18:00:00+01:00", url: "javascript:alert(1)", today: 0),
        ]
        try await backend.context.database.transaction { c in
            try c.execute("INSERT INTO modules(name, color, sort, created_at) VALUES ('Testmathematik', '#4f5bd5', 0, '2026-10-01T08:00:00')")
            let mid = try XCTUnwrap(c.rows("SELECT id FROM modules WHERE name='Testmathematik'").first?["id"]?.int)
            for (id, title, kind) in [("k-vl", "Testmathematik", "vorlesung"), ("k-ue", "Übung Testmathematik", "uebung")] {
                try c.execute("INSERT INTO courses(id, title, semester, kind, active, module_id, created_at) VALUES (?,?,?,?,1,?,?)",
                              [.text(id), .text(title), .text("WiSe 2026/27"), .text(kind), .integer(Int64(mid)), .text("2026-10-01T08:00:00")])
            }
            for (course, title, kind, start, end) in [("k-vl", "Testmathematik", "vorlesung", "10:15", "11:45"),
                                                      ("k-ue", "Übung Testmathematik", "uebung", "14:15", "15:45")] {
                try c.execute("""
                    INSERT INTO course_events(module_id, course_id, title, kind, weekday, start_time, end_time, rrule, attend, source, created_at)
                    VALUES (?,?,?,?,3,?,?,'weekly',1,'manual','2026-10-01T08:00:00')
                    """, [.integer(Int64(mid)), .text(course), .text(title), .text(kind), .text(start), .text(end)])
            }
            try c.execute("""
                INSERT INTO deadlines(id, source, course_id, title, full_title, kind, module, due_at, url, overdue, fetched_at) VALUES
                ('sp-cw-1','studip','k-ue','Aufgabe 2','Aufgabe 2','abgabe','courseware','2026-11-12T12:00','https://studip.example/cw/2',0,'t'),
                ('lw-ev-9','learnweb','k-vl','Test 1','Test 1 (öffnet)','test_beginn','quiz','2026-11-12T08:00','javascript:alert(1)',0,'t')
                """)
            _ = try Announcements.store(c, news, source: "studip", fetchedAt: "2026-11-02T09:00:00")
        }
        return APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
    }

    func testEachKindShowsWhatItIsAbout() throws {
        let day = try awaiting {
            let api = try await self.seededAPI()
            let cal = try await api.value("/api/calendar?start=2026-11-12&end=2026-11-12")
            return try XCTUnwrap(cal.list("days").first)
        }
        let hints = UFHint.all(day)
        let events = day.list("events")

        // Ausfall aus einer Stud.IP-Ankuendigung: Satz, Quelle mit Titel und Datum, Link, Termin = die Vorlesung
        let cancel = try XCTUnwrap(hints.first { $0.kind == "ausfall" })
        XCTAssertEqual(cancel.category, .notice)
        XCTAssertEqual(cancel.kindText, "Ausfall?")
        XCTAssertTrue(cancel.isCancellation)
        XCTAssertEqual(cancel.title, "Hinweis zur Vorlesung")
        XCTAssertEqual(cancel.course, "Testmathematik")
        XCTAssertEqual(cancel.snippet, "Die Vorlesung am 12.11. fällt aus.")
        XCTAssertEqual(cancel.source, "Stud.IP-Ankündigung „Hinweis zur Vorlesung“ vom 02.11.2026")
        XCTAssertEqual(cancel.url?.absoluteString, "https://studip.example/news/1")
        XCTAssertTrue(cancel.dateText.hasPrefix("Donnerstag, 12. November 2026"))
        let lecture = try XCTUnwrap(cancel.relatedEvent(in: events))
        XCTAssertEqual(lecture.s("course_id"), "k-vl")
        XCTAssertTrue(UFCancel.unsure(lecture), "der Termin traegt den Hinweis und wartet auf die Entscheidung")
        XCTAssertNotNil(lecture.i("event_id"), "Fällt aus / Findet statt brauchen die Serie")

        // Raum der Uebung: Termin ist die Uebung um 14:15, fremde Adresse (javascript:) wird nicht geoeffnet
        let room = try XCTUnwrap(hints.first { $0.kind == "raum" })
        XCTAssertEqual(room.kindText, "Raumänderung")
        XCTAssertEqual(room.time, "14:15")
        XCTAssertEqual(room.dateText, "Donnerstag, 12. November 2026, 14:15 Uhr")
        XCTAssertNil(room.url)
        XCTAssertEqual(room.relatedEvent(in: events)?.s("course_id"), "k-ue")
        XCTAssertFalse(room.isCancellation)

        // Courseware-Frist (Stud.IP) und Learnweb-Test: Quelle je Herkunft, Link nur http(s), kein Termin
        let cw = try XCTUnwrap(hints.first { $0.category == .deadline && $0.title == "Aufgabe 2" })
        XCTAssertEqual(cw.kindText, "Abgabe")
        XCTAssertEqual(cw.source, "Aufgabe aus Stud.IP Courseware")
        XCTAssertEqual(cw.time, "12:00")
        XCTAssertEqual(cw.course, "Übung Testmathematik")
        XCTAssertEqual(cw.url?.absoluteString, "https://studip.example/cw/2")
        XCTAssertNil(cw.relatedEvent(in: events))
        let quiz = try XCTUnwrap(hints.first { $0.category == .deadline && $0.title == "Test 1" })
        XCTAssertEqual(quiz.source, "Frist aus dem Learnweb-Kalender")
        XCTAssertEqual(quiz.kindText, "Test beginnt")
        XCTAssertEqual(quiz.snippet, "Test 1 (öffnet)")
        XCTAssertNil(quiz.url)

        // Chips: kompakt Uhrzeit und Art, breit mit Titel
        XCTAssertEqual(UFDayExtraChips.text(cw, compact: true), "12:00 Abgabe")
        XCTAssertEqual(UFDayExtraChips.text(cancel, compact: false), "Ausfall?: Hinweis zur Vorlesung")
    }

    func testHolidayLectureFreeAndExamNotice() {
        let hol = UFHint.mark(["kind": "feiertag", "label": "Reformationstag"], date: "2026-10-31")
        XCTAssertEqual(hol.kindText, "Feiertag")
        XCTAssertEqual(hol.source, "Gesetzlicher Feiertag")
        XCTAssertEqual(hol.tone, .ok)
        XCTAssertNil(hol.url)
        let free = UFHint.mark(["kind": "vorlesungsfrei", "label": "Vorlesungsfreie Zeit"], date: "2027-02-15")
        XCTAssertEqual(free.kindText, "Vorlesungsfreie Zeit")
        XCTAssertEqual(free.source, "Semesterzeiten der Hochschule")
        XCTAssertEqual(UFDayExtraChips.text(free, compact: true), "vorlesungsfrei")

        let exam = UFHint.notice(["announcement_id": "lw-post-3", "title": "Klausurtermin", "kind": "pruefung", "time": "10:00",
                                  "snippet": "Die Klausur ist am 6.11. um 10 Uhr im Audimax.", "url": "https://learnweb.example/d/3",
                                  "course_title": "Erziehungswissenschaft", "source": "learnweb", "posted_at": "2026-11-02T10:00:00+01:00",
                                  "course_id": "lw-3", "module_id": 4], date: "2026-11-06")
        XCTAssertEqual(exam.kindText, "Klausur / Prüfung")
        XCTAssertEqual(exam.tone, .bad)
        XCTAssertEqual(exam.source, "Learnweb-Ankündigung „Klausurtermin“ vom 02.11.2026")
        // Termin desselben Moduls nur, wenn er zur Uhrzeit laeuft
        let other: JSONValue = ["event_id": 7, "course_id": "lw-9", "module_id": 4, "start": "14:00", "end": "15:30", "status": "teilnahme"]
        let match: JSONValue = ["event_id": 8, "course_id": "lw-3", "module_id": 4, "start": "10:00", "end": "12:00", "status": "teilnahme"]
        XCTAssertNil(exam.relatedEvent(in: [other]))
        XCTAssertEqual(exam.relatedEvent(in: [other, match])?.i("event_id"), 8)
    }

    /// Das Detailblatt baut sich fuer jede Art auf (Umgebung wie in der App)
    func testDialogRendersForEveryKind() throws {
        let day = try awaiting {
            let api = try await self.seededAPI()
            let cal = try await api.value("/api/calendar?start=2026-11-12&end=2026-11-12")
            return try XCTUnwrap(cal.list("days").first)
        }
        let hints = UFHint.all(day) + [UFHint.mark(["kind": "feiertag", "label": "Reformationstag"], date: "2026-10-31")]
        XCTAssertGreaterThanOrEqual(hints.count, 5)
        for h in hints {
            let view = UFHintDialog(hint: h, events: day.list("events"))
                .environmentObject(Session(local: .local(.unavailable)))
                .environmentObject(UFOverlay())
                .environmentObject(UFToastCenter())
                .environmentObject(UFRouter())
                .frame(width: 620)
            let r = ImageRenderer(content: view)
            r.scale = 1
            let img = try XCTUnwrap(r.uiImage, "Detail fuer \(h.kindText)")
            XCTAssertGreaterThan(img.size.height, 150, h.kindText)
        }
    }
}
