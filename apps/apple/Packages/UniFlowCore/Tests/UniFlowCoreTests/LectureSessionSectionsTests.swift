import Foundation
import XCTest
@testable import UniFlowCore

/// Learnweb-Seminar mit Sitzungsabschnitten (echtes Hildesheim-Konto, 14.11.2026): Abschnitte "1. Sitzung (29.10.2026)"
/// bis "14. Sitzung (11.02.2027)", dazu "Seminarplan (Stand: 29.10.2026)" und "Anforderungen für die Studienleistung";
/// kein Termin im Stundenplan (Online-Seminar), alle Dateien mit Aenderungsdatum 26.10. Abschnittstitel wie im Kurs,
/// Dateinamen gekuerzt bzw. erfunden.
final class LectureSessionSectionsTests: XCTestCase {

    private static let sections: [(String, [String])] = [
        ("1. Sitzung (29.10.2026)", ["Karikaturen.pdf", "Warum Nachhaltigkeit.pdf"]),
        ("2. Sitzung (05.11.2026)", ["CO2Spiel.pdf"]),
        ("3. Sitzung (12.11.2026)", ["Imperiale_Lebensweise_Kapitel_3.pdf", "Imperiale_Lebensweise_Kapitel_6.pdf"]),
        ("4. Sitzung (19.11.2026)", ["Nach der Tragödie.pdf"]),
        ("9. Sitzung (07.01.2027)", ["Grunwald 2010.pdf"]),
        ("13. Sitzung (04.02.2027)", ["Umkämpftes grün.pdf"]),
        ("14. Sitzung (11.02.2027)", ["Erste Schritte.pdf", "Weiterführende Gedanken.pdf", "Broschüre Klima.pdf"]),
        ("Seminarplan (Stand: 29.10.2026)", ["Seminarplan_1586_WiSe2627.pdf"]),
        ("Anforderungen für die Studienleistung", ["Vorlage zum Lerntagebuch_WiSe2627.docx"]),
    ]

    private func inputs() -> [LectureWeeks.Input] {
        var out: [LectureWeeks.Input] = []
        for (i, (sec, names)) in Self.sections.enumerated() {
            for (j, n) in names.enumerated() {
                out.append(LectureWeeks.Input(id: "f\(i)-\(j)", name: n, section: sec, date: 1_792_965_600))   // 26.10.2026
            }
        }
        return out
    }

    private func backend() async throws -> LocalBackend {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: .fixed(berlin: "2026-11-14T10:00:00")!, university: "hildesheim")
        try await b.context.database.transaction { c in
            try c.execute("INSERT INTO modules(id, name, color, sort) VALUES (6, 'Nachhaltigkeit(sbildung) trifft Diversity', '#16a34a', 0)")
            try c.execute("INSERT INTO courses(id, title, subject, kind, semester, active, module_id, created_at) VALUES ('lw-2260', 'Nachhaltigkeit(sbildung) trifft Diversity', 'x', 'seminar', 'WiSe 2026/27', 1, 6, 't')")
            for f in self.inputs() {
                try c.execute("INSERT INTO files(id, course_id, name, chdate, studip_folder) VALUES (?, 'lw-2260', ?, 1792965600, ?)",
                              [.text(f.id), .text(f.name), .text(f.section ?? "")])
            }
        }
        return b
    }

    private func stored(_ b: LocalBackend) async throws -> [String: (String?, String)] {
        try await b.context.database.withConnection { c in
            var out: [String: (String?, String)] = [:]
            for r in try c.query("SELECT file_id, week_monday, detail FROM lecture_file_weeks") {
                out[r["file_id"]?.string ?? ""] = (r["week_monday"]?.string, r["detail"]?.string ?? "")
            }
            return out
        }
    }

    private func check(_ s: [String: (String?, String)], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(s["f0-0"]?.0, "2026-10-26", "1. Sitzung: Woche ab 26.10.", file: file, line: line)
        XCTAssertEqual(s["f2-0"]?.0, "2026-11-09", "3. Sitzung: Abschnitt vor \"Kapitel 3\"", file: file, line: line)
        XCTAssertEqual(s["f2-1"]?.0, "2026-11-09", "3. Sitzung: Abschnitt vor \"Kapitel 6\"", file: file, line: line)
        XCTAssertEqual(s["f4-0"]?.0, "2027-01-04", "9. Sitzung nach der Weihnachtspause", file: file, line: line)
        for j in 0..<3 { XCTAssertEqual(s["f6-\(j)"]?.0, "2027-02-08", "14. Sitzung nach dem rechnerischen Vorlesungsende", file: file, line: line) }
        XCTAssertNil(s["f7-0"]?.0 ?? nil, "Seminarplan: Allgemein, nicht die Woche des Stands", file: file, line: line)
        XCTAssertEqual(s["f7-0"]?.1, "Abschnitt ohne Sitzung", file: file, line: line)
        XCTAssertNil(s["f8-0"]?.0 ?? nil, "Anforderungen: Allgemein, nicht die Woche des Aenderungsdatums", file: file, line: line)
    }

    func testSessionDatesInSectionTitlesDecideTheWeek() async throws {
        let b = try await backend()
        try await b.context.database.transaction { c in
            try LectureWeeks.assignCourse(c, courseID: "lw-2260", semester: "WiSe 2026/27", university: "hildesheim", files: self.inputs(), now: "2026-11-14T10:00:00")
        }
        check(try await stored(b))
        // Moduldetail: je Sitzung eine Woche, "Allgemein" statt Woche 2, nichts unter "Nicht zugeordnet", Woche 16 nach dem Ende
        let r = await b.handle(LocalRequest(method: "GET", url: URL(string: "uniflow-local://device/api/modules/6")!))
        let weeks = (r.json?["weeks"]?.array ?? []).map { ($0["week"]?.int ?? 0, $0["label"]?.string ?? "", $0["count"]?.int ?? 0) }
        XCTAssertEqual(weeks.filter { $0.0 >= 1 }.count, 7, "sieben Sitzungen mit Dateien")
        XCTAssertTrue(weeks.contains { $0.0 == LectureWeeks.generalWeek && $0.2 == 2 }, "\(weeks)")
        XCTAssertFalse(weeks.contains { $0.0 == ModuleLayout.unassignedWeek }, "\(weeks)")
        XCTAssertTrue(weeks.contains { $0.1.hasPrefix("Woche 16 · 08.02.") && $0.2 == 3 }, "\(weeks)")
        XCTAssertTrue(weeks.contains { $0.1.hasPrefix("Woche 4 · 09.11.") && $0.2 == 2 }, "\(weeks)")
    }

    /// Stand des Testkontos: fruehere Zuordnung ueber Name und Datum wird beim naechsten Abgleich einmal korrigiert
    func testOldAssignmentsAreReassessedOnce() async throws {
        let b = try await backend()
        try await b.context.database.transaction { c in
            try LectureWeeks.assignCourse(c, courseID: "lw-2260", semester: "WiSe 2026/27", university: "hildesheim", files: self.inputs(), now: "2026-11-14T10:00:00")
            // wie in der Kopie: "Kapitel 6" in Woche 6, 14. Sitzung und Seminarplan in Woche 2
            try c.execute("UPDATE lecture_file_weeks SET rule='name', detail='kapitel 6', week_monday='2026-11-23' WHERE file_id='f2-1'")
            try c.execute("UPDATE lecture_file_weeks SET rule='datum', detail='Datum 2026-10-26', week_monday='2026-10-26' WHERE file_id LIKE 'f6-%' OR file_id IN ('f7-0','f8-0')")
            try LectureWeeks.assignCourse(c, courseID: "lw-2260", semester: "WiSe 2026/27", university: "hildesheim", files: self.inputs(), now: "2026-11-15T10:00:00")
        }
        check(try await stored(b))
        // danach bleibt alles, wie es ist
        let n = try await b.context.database.transaction { c in
            try LectureWeeks.assignCourse(c, courseID: "lw-2260", semester: "WiSe 2026/27", university: "hildesheim", files: self.inputs(), now: "2026-11-16T10:00:00").count
        }
        XCTAssertEqual(n, 0)
    }

    func testSessionTitlesAndNoSessionWeeksWithoutDates() {
        let term = LectureWeeks.Term(semester: "WiSe 2026/27", start: BerlinClock.parseISODate("2026-10-19")!, end: BerlinClock.parseISODate("2027-02-05")!, source: "test")
        XCTAssertEqual(LectureWeeks.sessionDay("Sitzung 3 am 12.11.", term: term), BerlinClock.parseISODate("2026-11-12"))
        XCTAssertEqual(LectureWeeks.sessionDay("Blocktag 1 – 14.11.2026", term: term), BerlinClock.parseISODate("2026-11-14"))
        XCTAssertNil(LectureWeeks.sessionDay("Seminarplan (Stand: 29.10.2026)", term: term))
        XCTAssertNil(LectureWeeks.sessionDay("3. Sitzung", term: term), "ohne Datum keine Sitzungswoche")
        XCTAssertNil(LectureWeeks.sessionDay("1. Sitzung (29.10.2025)", term: term), "Datum eines anderen Semesters")
    }
}
