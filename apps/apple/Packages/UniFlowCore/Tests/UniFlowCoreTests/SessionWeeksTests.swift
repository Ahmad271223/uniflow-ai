import Foundation
import XCTest
@testable import UniFlowCore

/// Seminar mit wenigen Terminwochen (14.11.2026, erstes echtes Hildesheim-Konto: Seminar in 15 Wochen): nummerierte
/// Dateien in die Wochen der Termine, Vorlesungen jede Woche unveraendert. Erfundene Daten.
final class SessionWeeksTests: XCTestCase {

    private let clock = UniFlowClock.fixed(berlin: "2026-11-14T10:00:00")!

    /// Modul 1: Blockseminar, drei Samstage (Lehrwochen 2, 5, 9), "Sitzung 1" bis "Sitzung 15";
    /// Modul 2: Vorlesung jeden Montag, "VL 1" bis "VL 6"
    private func backend(seminarDates: Bool = true) async throws -> (LocalBackend, LectureWeeks.Term) {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let term = try await b.context.database.transaction { c -> LectureWeeks.Term in
            try c.execute("INSERT INTO modules(id, name, color, sort) VALUES (1, 'Nachhaltigkeit trifft Diversity', '#16a34a', 0), (2, 'Analysis', '#175ee8', 1)")
            try c.execute("INSERT INTO courses(id, title, subject, kind, semester, active, module_id, created_at) VALUES ('lw-sem', 'Nachhaltigkeit trifft Diversity', 'Nachhaltigkeit trifft Diversity', 'seminar', 'WiSe 2026/27', 1, 1, 't')")
            try c.execute("INSERT INTO courses(id, title, subject, kind, semester, active, module_id, created_at) VALUES ('lw-ana', 'Analysis', 'Analysis', 'vorlesung', 'WiSe 2026/27', 1, 2, 't')")
            let sem = (1...15).map { ("s\($0)", "Sitzung \($0) Texte.pdf") }
            let ana = (1...6).map { ("a\($0)", "VL \($0).pdf") }
            for (id, name) in sem { try c.execute("INSERT INTO files(id, course_id, name, chdate) VALUES (?, 'lw-sem', ?, 1760000000)", [.text(id), .text(name)]) }
            for (id, name) in ana { try c.execute("INSERT INTO files(id, course_id, name, chdate) VALUES (?, 'lw-ana', ?, 1760000000)", [.text(id), .text(name)]) }
            try LectureWeeks.assignCourse(c, courseID: "lw-sem", semester: "WiSe 2026/27", university: "hildesheim",
                                          files: sem.map { LectureWeeks.Input(id: $0.0, name: $0.1, section: "Material") }, now: "2026-10-12T09:00:00")
            try LectureWeeks.assignCourse(c, courseID: "lw-ana", semester: "WiSe 2026/27", university: "hildesheim",
                                          files: ana.map { LectureWeeks.Input(id: $0.0, name: $0.1, section: "Material") }, now: "2026-10-12T09:00:00")
            let term = try XCTUnwrap(LectureWeeks.currentTerm(c))
            if seminarDates {
                for n in [2, 5, 9] {
                    let sat = try XCTUnwrap(term.monday(ofLectureWeek: n)) + 5
                    try c.execute("INSERT INTO course_events(module_id, title, kind, weekday, start_time, end_time, rrule, date_from, date_to, source) VALUES (1, 'Seminar', 'seminar', 5, '09:00', '17:00', 'once', ?, ?, 'lsf')",
                                  [.text(BerlinClock.isoDate(sat)), .text(BerlinClock.isoDate(sat))])
                }
            }
            try c.execute("INSERT INTO course_events(module_id, title, kind, weekday, start_time, end_time, rrule, date_from, date_to, source) VALUES (2, 'Analysis', 'vorlesung', 0, '10:00', '12:00', 'weekly', ?, ?, 'lsf')",
                          [.text(BerlinClock.isoDate(term.start)), .text(BerlinClock.isoDate(term.end))])
            return term
        }
        return (b, term)
    }

    private func weeks(_ b: LocalBackend, _ module: Int) async throws -> [Int: [String]] {
        let r = await b.handle(LocalRequest(method: "GET", url: URL(string: "uniflow-local://device/api/modules/\(module)")!))
        XCTAssertEqual(r.status, 200)
        var out: [Int: [String]] = [:]
        for w in r.json?["weeks"]?.array ?? [] {
            let ids = ["vorlesungen", "uebungen", "loesungen", "skripte", "klausuren", "sonstiges"].flatMap { w[$0]?.array ?? [] }.compactMap { $0["id"]?.string }
            out[w["week"]?.int ?? 0] = ids.sorted { Int($0.dropFirst())! < Int($1.dropFirst())! }
        }
        return out
    }

    private func displayWeek(_ term: LectureWeeks.Term, lectureWeek n: Int) -> Int {
        BerlinClock.floorDiv(term.monday(ofLectureWeek: n)! - term.firstMonday, 7) + 1
    }

    func testBlockSeminarFilesGoIntoTheWeeksWithDates() async throws {
        let (b, term) = try await backend()
        let w = try await weeks(b, 1)
        let block = [2, 5, 9].map { displayWeek(term, lectureWeek: $0) }
        XCTAssertEqual(w.keys.sorted(), block, "nur die drei Terminwochen statt 15")
        XCTAssertEqual(w[block[0]], (1...5).map { "s\($0)" })
        XCTAssertEqual(w[block[1]], (6...10).map { "s\($0)" })
        XCTAssertEqual(w[block[2]], (11...15).map { "s\($0)" })
        // die Vorlesung jede Woche bleibt wie bisher: VL n in Lehrwoche n
        let a = try await weeks(b, 2)
        XCTAssertEqual(a.keys.sorted(), (1...6).map { displayWeek(term, lectureWeek: $0) })
    }

    func testFewerNumbersThanDatesGoToTheNthDate() async throws {
        let s = SessionWeeks(weeks: [3, 6, 8, 11], top: 3)
        let term = LectureWeeks.Term(semester: "WiSe 2026/27", start: 20_000, end: 20_100, source: "test")
        let stored = LectureWeeks.Stored(monday: term.monday(ofLectureWeek: 2), docType: "vorlesung", termEnd: nil, rule: "name", detail: "vl 2")
        XCTAssertEqual(s.week(for: stored, displayWeek: 2, term: term), 6, "Sitzung 2 in die Woche des zweiten Termins")
        let kw = LectureWeeks.Stored(monday: term.monday(ofLectureWeek: 2), docType: "vorlesung", termEnd: nil, rule: "name", detail: "kw 44")
        XCTAssertNil(s.week(for: kw, displayWeek: 2, term: term), "Kalenderwoche bleibt")
        let date = LectureWeeks.Stored(monday: term.monday(ofLectureWeek: 2), docType: "vorlesung", termEnd: nil, rule: "datum", detail: "Datum 2026-10-20")
        XCTAssertNil(s.week(for: date, displayWeek: 2, term: term), "Datum bleibt")
    }

    func testWithoutDatesNothingChanges() async throws {
        let (b, term) = try await backend(seminarDates: false)
        let w = try await weeks(b, 1)
        XCTAssertEqual(w.count, min(15, term.lectureMondays.count), "ohne Termine wie bisher: Sitzung n in Lehrwoche n")
    }
}
