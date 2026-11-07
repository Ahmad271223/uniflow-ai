import Foundation
import XCTest
@testable import UniFlowCore

/// Lehrwochen selbst bestimmen (`LectureWeeks`, 07.11.2026): Namensmuster, Datum -> Lehrwoche, Weihnachtspause,
/// Merken je Datei und der Moodle-Abgleich der HsH ueber die Sitzung. Alle Namen und Adressen sind erfunden.
final class LectureWeeksTests: XCTestCase {

    private func day(_ iso: String) -> Int { BerlinClock.parseISODate(iso)! }
    private func iso(_ d: Int?) -> String? { d.map(BerlinClock.isoDate) }
    private var hsh: LectureWeeks.Term { LectureWeeks.tableTerm(university: "hsh", semester: "WiSe 2026/27")! }
    private var luh: LectureWeeks.Term { LectureWeeks.tableTerm(university: "luh", semester: "WiSe 2026/27")! }

    // MARK: Semester

    func testSemesterKeys() {
        XCTAssertEqual(LectureWeeks.semesterKey("WiSe 2026/27"), "w2026")
        XCTAssertEqual(LectureWeeks.semesterKey("WS 26/27"), "w2026")
        XCTAssertEqual(LectureWeeks.semesterKey("Wintersemester 2026/2027"), "w2026")
        XCTAssertEqual(LectureWeeks.semesterKey("SoSe 2027"), "s2027")
        XCTAssertEqual(LectureWeeks.semesterKey("SS 27"), "s2027")
        XCTAssertEqual(LectureWeeks.semesterKey("Sommersemester 2027"), "s2027")
        XCTAssertNil(LectureWeeks.semesterKey(""))
        XCTAssertNil(LectureWeeks.semesterKey("Mathematik 1"))
    }

    /// Tabelle (Holidays.semesters): HsH 21.09.2026 bis 31.01.2027, Weihnachten 23.12. bis 02.01.; LUH 12.10. bis
    /// 30.01., Weihnachtspause 23.12. bis 05.01.; Hildesheim 19.10. bis 05.02.; SoSe 2027 fuer alle drei
    func testTableTermsForAllUniversities() {
        XCTAssertEqual(iso(hsh.firstMonday), "2026-09-21")
        XCTAssertEqual(hsh.source, "tabelle")
        XCTAssertEqual(hsh.lectureMondays.count, 18, "19 Kalenderwochen ohne die Woche 28.12.–01.01.")
        XCTAssertEqual(iso(luh.firstMonday), "2026-10-12")
        XCTAssertEqual(luh.lectureMondays.count, 15)
        let hi = LectureWeeks.tableTerm(university: "hildesheim", semester: "WiSe 2026/27")!
        XCTAssertEqual(iso(hi.firstMonday), "2026-10-19")
        for u in ["hsh", "luh", "hildesheim"] {
            XCTAssertNotNil(LectureWeeks.tableTerm(university: u, semester: "SoSe 2027"), u)
        }
        XCTAssertEqual(iso(LectureWeeks.tableTerm(university: "hsh", semester: "SoSe 2027")?.start), "2027-03-01")
        XCTAssertNil(LectureWeeks.tableTerm(university: "hsh", semester: "WiSe 2019/20"))
    }

    func testChristmasBreakIsSkipped() {
        // HsH: Woche 14 ist die vom 21.12., die Woche 28.12. ist ganz frei, danach Woche 15 ab 04.01.
        XCTAssertTrue(hsh.isBreakWeek(monday: day("2026-12-28")))
        XCTAssertFalse(hsh.isBreakWeek(monday: day("2026-12-21")), "Mo/Di 21./22.12. sind Vorlesungstage")
        XCTAssertEqual(iso(hsh.monday(ofLectureWeek: 14)), "2026-12-21")
        XCTAssertEqual(iso(hsh.monday(ofLectureWeek: 15)), "2027-01-04")
        // ein Datum in der Pause zaehlt zur letzten Lehrwoche davor
        XCTAssertEqual(iso(hsh.weekMonday(forDay: day("2026-12-30"))), "2026-12-21")
        XCTAssertEqual(hsh.lectureWeek(ofMonday: day("2026-12-28")), 14)
        // LUH: 23.12. bis 05.01.; die Woche ab 04.01. hat ab Mittwoch Vorlesungen
        XCTAssertTrue(luh.isBreakWeek(monday: day("2026-12-28")))
        XCTAssertFalse(luh.isBreakWeek(monday: day("2027-01-04")))
        XCTAssertEqual(luh.lectureWeek(ofMonday: day("2027-01-04")), 12)
        XCTAssertEqual(iso(luh.weekMonday(forDay: day("2027-01-05"))), "2027-01-04")
    }

    func testDateToLectureWeek() {
        XCTAssertEqual(hsh.weekMonday(forDay: day("2026-10-14")).flatMap(hsh.lectureWeek(ofMonday:)), 4)
        XCTAssertEqual(luh.weekMonday(forDay: day("2026-10-14")).flatMap(luh.lectureWeek(ofMonday:)), 1)
        XCTAssertEqual(luh.weekMonday(forDay: day("2026-11-06")).flatMap(luh.lectureWeek(ofMonday:)), 4)
        // bis 7 Tage vor Beginn: Woche 1; frueher (kopierter Kurs) und nach dem Ende: keine Woche
        XCTAssertEqual(iso(luh.weekMonday(forDay: day("2026-10-08"))), "2026-10-12")
        XCTAssertNil(luh.weekMonday(forDay: day("2026-09-30")))
        XCTAssertNil(luh.weekMonday(forDay: day("2027-02-15")))
    }

    func testCalendarWeekToLectureWeek() {
        // KW 46/2026 beginnt am 09.11.2026; KW 2/2027 am 11.01.2027
        XCTAssertEqual(iso(hsh.monday(ofCalendarWeek: 46)), "2026-11-09")
        XCTAssertEqual(hsh.lectureWeek(ofMonday: hsh.monday(ofCalendarWeek: 46)!), 8)
        XCTAssertEqual(luh.lectureWeek(ofMonday: luh.monday(ofCalendarWeek: 46)!), 5)
        XCTAssertEqual(iso(luh.monday(ofCalendarWeek: 2)), "2027-01-11")
        XCTAssertEqual(iso(luh.monday(ofCalendarWeek: 53)), "2026-12-21", "KW 53/2026 liegt in der Pause -> Woche davor")
        XCTAssertNil(luh.monday(ofCalendarWeek: 30), "KW 30 liegt in keinem Wintersemester")
    }

    func testEstimatedTermWithoutTable() {
        let t = LectureWeeks.estimatedTerm(semester: "WiSe 2031/32")!
        XCTAssertEqual(iso(t.start), "2031-10-13")
        XCTAssertEqual(t.source, "schaetzung")
        XCTAssertTrue(t.isBreakWeek(monday: day("2031-12-29")))
        XCTAssertEqual(iso(LectureWeeks.estimatedTerm(semester: "SoSe 2031")?.start), "2031-04-07")
    }

    // MARK: Namensmuster

    func testNamePatterns() {
        typealias K = LectureWeeks.NumberKind
        let cases: [(String, K, Int)] = [
            ("VL 3.pdf", .lecture, 3), ("Vorlesung_03.pdf", .lecture, 3), ("V03_Sortieren.pdf", .lecture, 3),
            ("vl03-baeume.pdf", .lecture, 3), ("Folien 7.pptx", .lecture, 7), ("Lecture-12.pdf", .lecture, 12),
            ("Kapitel 3.pdf", .chapter, 3), ("Kap. 4 Integrale.pdf", .chapter, 4),
            ("Übung 2.pdf", .sheet, 2), ("Übungsblatt 02.pdf", .sheet, 2), ("Blatt 4.pdf", .sheet, 4), ("Ü3.pdf", .sheet, 3),
            ("Uebungsblatt_5.pdf", .sheet, 5), ("Aufgabenblatt 6.pdf", .sheet, 6), ("Sheet 1.pdf", .sheet, 1),
            ("Tutorium 5.pdf", .tutorial, 5), ("Lösung 2.pdf", .solution, 2), ("Loesung_Blatt_03.pdf", .solution, 3),
            ("Musterlösung zu Übung 4.pdf", .solution, 4), ("Blatt 2 Lösung.pdf", .solution, 2), ("Übung 3 (Musterlösung).pdf", .solution, 3),
            ("Skript Teil 4.pdf", .part, 4), ("Woche 5.pdf", .week, 5), ("3. Woche.pdf", .week, 3), ("KW 46.pdf", .calendarWeek, 46),
            ("KW46_Folien.pdf", .calendarWeek, 46), ("Sitzung 4.pdf", .lecture, 4), ("Termin 2 Folien.pdf", .lecture, 2),
            ("9_Hinweise zu Blatt 3.pdf", .sheet, 3),
        ]
        for (name, kind, n) in cases {
            XCTAssertEqual(LectureWeeks.nameHint(name), LectureWeeks.NameHint(kind: kind, number: n), name)
        }
    }

    func testNamesWithoutWeekNumber() {
        for name in ["Skript_v2.pdf", "Formelsammlung.pdf", "Mathe 2 Folien.pdf", "Literatur 2026.pdf", "12.10.2026 Folien.pdf",
                     "Programmieren2.pdf", "Klausur WS 2025.pdf", "3D-Modell.pdf",
                     // nackte Laufnummer der Moodle-Ressourcen (HsH, 07.11.2026): keine Lehrwoche
                     "01 Einleitung.pdf", "07.pdf", "6_Internes Rechnungswesen_zusätzliche Übungsaufgaben.pdf", "7_Literaturempfehlungen.pdf",
                     "10_Errata - Fehler gefunden.pdf", "8_Übungsklausur.pdf", "9_Hinweise Übungsklausuren.pdf"] {
            XCTAssertNil(LectureWeeks.nameHint(name), name)
        }
    }

    /// Befund vom echten iPad (HsH-Moodle, anonymisiert): "N_" am Anfang ist die Reihenfolge im Kurs, Literatur,
    /// Errata und Hinweise sind Allgemein-Material, Übungsklausuren gehoeren zu den Klausuren
    func testLeadingNumbersAndGeneralMaterialStayGeneral() {
        let files = [
            input("a", "6_Internes Rechnungswesen_zusätzliche Übungsaufgaben.pdf"),
            input("b", "7_Literaturempfehlungen.pdf", date: "2026-11-02T10:00:00"),
            input("c", "10_Errata - Fehler gefunden.pdf", date: "2026-11-02T10:00:00"),
            input("d", "8_Übungsklausur.pdf", date: "2026-11-02T10:00:00"),
            input("e", "9_Hinweise Übungsklausuren.pdf"),
            input("f", "list.pdf", module: "Literaturempfehlungen", date: "2026-11-02T10:00:00"),
            input("g", "3_Formelsammlung.pdf"),
            input("h", "9_Hinweise zu Blatt 3.pdf"),
            input("i", "5_Modulbeschreibung.pdf", section: "Woche 2"),
            input("j", "4_Übungsaufgaben.pdf", date: "2026-11-02T10:00:00"),
        ]
        let a = byID(LectureWeeks.assign(files, term: luh))
        XCTAssertEqual(a["a"]?.rule, .general, "ohne Schluesselwort und ohne Datum: Allgemein, nicht Woche 6")
        XCTAssertEqual(a["b"]?.rule, .general, "Literatur bleibt Allgemein, auch mit Datum")
        XCTAssertNil(a["b"]?.lectureWeek)
        XCTAssertEqual(a["c"]?.rule, .general)
        XCTAssertEqual(a["d"]?.docType, "klausur")
        XCTAssertNil(a["d"]?.lectureWeek, "Klausuren ohne Woche")
        XCTAssertEqual(a["e"]?.docType, "klausur")
        XCTAssertEqual(a["f"]?.rule, .general, "Name der Moodle-Ressource zaehlt")
        XCTAssertEqual(a["g"]?.rule, .general)
        XCTAssertEqual(a["h"]?.lectureWeek, 3, "Schluesselwort mit Nummer geht vor")
        XCTAssertEqual(a["i"]?.lectureWeek, 2, "ein Wochen-Abschnitt geht immer vor")
        XCTAssertEqual(a["j"]?.lectureWeek, 4, "ohne Schluesselwort: Datum (02.11. -> Woche 4 der LUH)")
        XCTAssertEqual(a["j"]?.rule, .date)
    }

    func testDateInName() {
        XCTAssertEqual(iso(LectureWeeks.dateInName("VL_2026-10-12.pdf")), "2026-10-12")
        XCTAssertEqual(iso(LectureWeeks.dateInName("Folien 20261019.pdf")), "2026-10-19")
        XCTAssertEqual(iso(LectureWeeks.dateInName("Sitzung vom 12.10.2026.pdf")), "2026-10-12")
        XCTAssertEqual(iso(LectureWeeks.dateInName("Sitzung 2.11.26.pdf")), "2026-11-02")
        XCTAssertNil(LectureWeeks.dateInName("Blatt 3.pdf"))
        XCTAssertNil(LectureWeeks.dateInName("2026-13-40.pdf"))
    }

    func testSectionWeeks() {
        XCTAssertEqual(LectureWeeks.sectionWeek("Woche 3", term: luh)?.monday, luh.monday(ofLectureWeek: 3))
        XCTAssertEqual(LectureWeeks.sectionWeek(Learnweb.sectionLabel("4", number: 4), term: luh)?.monday, luh.monday(ofLectureWeek: 4))
        XCTAssertEqual(LectureWeeks.sectionWeek("2. Woche", term: luh)?.monday, luh.monday(ofLectureWeek: 2))
        XCTAssertEqual(iso(LectureWeeks.sectionWeek("KW 46", term: luh)?.monday), "2026-11-09")
        // Wochenformat von Moodle
        XCTAssertEqual(iso(LectureWeeks.sectionWeek("19. Oktober - 25. Oktober", term: luh)?.monday), "2026-10-19")
        XCTAssertEqual(iso(LectureWeeks.sectionWeek("4. Januar - 10. Januar", term: luh)?.monday), "2027-01-04")
        XCTAssertEqual(iso(LectureWeeks.sectionWeek("26.10. - 01.11.", term: luh)?.monday), "2026-10-26")
        XCTAssertEqual(iso(LectureWeeks.sectionWeek("2 November - 8 November", term: luh)?.monday), "2026-11-02")
        for s in ["Allgemeines", "Thema 3", "Vorlesung und Übung", "", "Abschnitt 2"] {
            XCTAssertNil(LectureWeeks.sectionWeek(s, term: luh), s)
        }
    }

    // MARK: Zuordnung

    private func input(_ id: String, _ name: String, folder: String? = nil, section: String? = nil, module: String? = nil,
                       date: String? = nil, final: Bool = true) -> LectureWeeks.Input {
        LectureWeeks.Input(id: id, name: name, folder: folder, section: section, moduleName: module,
                           date: date.flatMap { BerlinClock.utcSeconds(localISO: $0) }, final: final)
    }

    private func byID(_ a: [LectureWeeks.Assignment]) -> [String: LectureWeeks.Assignment] {
        Dictionary(uniqueKeysWithValues: a.map { ($0.fileID, $0) })
    }

    func testAssignOrderOfRules() {
        let files = [
            input("a", "folien.pdf", folder: "Woche 2", section: "Woche 2", module: "Vorlesung 5", date: "2026-11-20T10:00:00"),
            input("b", "aufgaben.pdf", folder: "Übungen", section: "Übungen", module: "Übungsblatt 3", date: "2026-11-20T10:00:00"),
            input("c", "loesung.pdf", module: "Lösung zu Blatt 3"),
            input("d", "kapitel-04.pdf", module: "Skript"),
            input("e", "folien_KW46.pdf"),
            input("f", "Handout.pdf", date: "2026-10-14T09:00:00"),
            input("g", "literatur.pdf"),
            input("h", "material.pdf", date: "2026-12-30T12:00:00"),
            input("i", "alt.pdf", date: "2024-10-14T09:00:00"),
            input("j", "noch-unbekannt.pdf", final: false),
            input("k", "Sitzung vom 26.10.2026.pdf"),
        ]
        let a = byID(LectureWeeks.assign(files, term: luh))
        XCTAssertEqual(a["a"]?.lectureWeek, 2, "1. Wochen-Abschnitt schlaegt den Namen")
        XCTAssertEqual(a["a"]?.rule, .section)
        XCTAssertEqual(a["b"]?.lectureWeek, 3, "2. Name der Moodle-Ressource")
        XCTAssertEqual(a["b"]?.docType, "uebung")
        XCTAssertEqual(a["c"]?.lectureWeek, 4, "Lösung eine Woche nach dem Blatt")
        XCTAssertEqual(a["c"]?.docType, "loesung")
        XCTAssertEqual(a["d"]?.lectureWeek, 4)
        XCTAssertEqual(a["e"]?.lectureWeek, 5, "KW 46 -> Lehrwoche 5 (LUH)")
        XCTAssertEqual(a["f"]?.lectureWeek, 1, "3. Datum der Datei")
        XCTAssertEqual(a["f"]?.rule, .date)
        XCTAssertEqual(a["g"]?.rule, .general, "4. ohne Hinweis: Allgemein, nicht Woche 1")
        XCTAssertNil(a["g"]?.lectureWeek)
        XCTAssertEqual(a["h"]?.lectureWeek, 11, "Datum in der Weihnachtspause -> letzte Lehrwoche davor")
        XCTAssertEqual(a["i"]?.rule, .general, "Datum ausserhalb des Semesters sagt nichts")
        XCTAssertNil(a["j"], "ohne Datum und nicht final: spaeter")
        XCTAssertEqual(a["k"]?.lectureWeek, 3, "Datum im Namen")
    }

    /// Schon gemerkte Zuordnungen ueber die nackte Nummer werden einmal neu bewertet; alles andere bleibt
    func testLegacyLeadingNumberAssignmentsAreReevaluatedOnce() async throws {
        let (db, clock) = try await database(university: "hsh", today: "2026-11-07T10:00:00")
        let now = clock.nowISO
        try await db.transaction { c in
            try UniStore.upsertCourse(c, UniStore.CourseRow(id: "lw-2", title: "Rechnungswesen", number: nil, semester: "WiSe 2026/27"), now: now)
            try LectureWeeks.ensureTables(c)
            for (id, week, rule, detail) in [("lw-2-a", 7, "name", "nummer 7"), ("lw-2-b", 3, "name", "vl 3"), ("lw-2-c", 5, "datum", "Datum 2026-10-20"),
                                             ("lw-2-d", 2, "abschnitt", "Abschnitt Woche 2")] {
                let monday = BerlinClock.isoDate(self.hsh.monday(ofLectureWeek: week)!)
                try c.execute("INSERT INTO lecture_file_weeks(file_id, course_id, week_monday, lecture_week, doc_type, rule, detail, assigned_at) VALUES (?,?,?,?,?,?,?,?)",
                              [.text(id), .text("lw-2"), .text(monday), .integer(Int64(week)), .text("vorlesung"), .text(rule), .text(detail), .text(now)])
            }
        }
        let files = [input("lw-2-a", "7_Literaturempfehlungen.pdf"), input("lw-2-b", "VL 3.pdf"), input("lw-2-c", "material.pdf"),
                     input("lw-2-d", "5_Modulbeschreibung.pdf", section: "Woche 2")]
        let redone = try await db.transaction { c in
            try LectureWeeks.assignCourse(c, courseID: "lw-2", semester: "WiSe 2026/27", university: "hsh", files: files, now: now)
        }
        XCTAssertEqual(redone.map(\.fileID), ["lw-2-a"], "nur die Zuordnung ueber die nackte Nummer")
        XCTAssertEqual(redone.first?.rule, .general)
        let rows = try await db.rows("SELECT file_id, lecture_week, rule FROM lecture_file_weeks WHERE course_id='lw-2' ORDER BY file_id")
        XCTAssertEqual(rows.map { $0["lecture_week"]?.int }, [nil, 3, 5, 2])
        XCTAssertEqual(rows.map { $0["rule"]?.string }, ["allgemein", "name", "datum", "abschnitt"])
        // zweiter Lauf: nichts mehr zu tun
        let again = try await db.transaction { c in
            try LectureWeeks.assignCourse(c, courseID: "lw-2", semester: "WiSe 2026/27", university: "hsh", files: files, now: now)
        }
        XCTAssertTrue(again.isEmpty)
    }

    func testSheetZeroAndTwoLecturesPerWeek() {
        // Blatt 0 bis 3: Blatt 0 in Woche 1
        let sheets = (0...3).map { input("s\($0)", "Blatt \($0).pdf") }
        XCTAssertEqual(LectureWeeks.assign(sheets, term: luh).map(\.lectureWeek), [1, 2, 3, 4])
        // 30 Vorlesungen in 15 Wochen: zwei je Woche
        let lectures = (1...30).map { input("v\($0)", String(format: "VL%02d.pdf", $0)) }
        let weeks = LectureWeeks.assign(lectures, term: luh).map(\.lectureWeek)
        XCTAssertEqual(Array(weeks.prefix(4)), [1, 1, 2, 2])
        XCTAssertEqual(weeks.last, 15)
        // eine neue Datei allein wird mit der ganzen Reihe des Kurses gestaucht
        XCTAssertEqual(LectureWeeks.assign([lectures[9]], all: lectures, term: luh).first?.lectureWeek, 5)
    }

    func testTypes() {
        let a = byID(LectureWeeks.assign([input("1", "VL 1.pdf"), input("2", "Skript Teil 2.pdf"), input("3", "Tutorium 5.pdf"),
                                          input("4", "Lösung 2.pdf"), input("5", "Raumplan.pdf")], term: luh))
        XCTAssertEqual(a["1"]?.docType, "vorlesung")
        XCTAssertEqual(a["2"]?.docType, "skript")
        XCTAssertEqual(a["3"]?.docType, "uebung")
        XCTAssertEqual(a["4"]?.docType, "loesung")
        XCTAssertEqual(a["5"]?.docType, "sonstiges")
    }

    func testHTTPDate() {
        XCTAssertEqual(LectureWeeks.parseHTTPDate("Wed, 14 Oct 2026 07:28:00 GMT"), 1_791_962_880)
        XCTAssertNil(LectureWeeks.parseHTTPDate("gestern"))
        XCTAssertNil(LectureWeeks.parseHTTPDate(nil))
    }

    func testLabelsSkipTheBreak() {
        let start = hsh.firstMonday
        let w = BerlinClock.floorDiv(day("2027-01-04") - start, 7) + 1
        XCTAssertEqual(LectureWeeks.weekLabel(start: start, week: w, term: hsh), "Woche 15 · 04.01. – 10.01.")
        XCTAssertEqual(LectureWeeks.weekLabel(start: start, week: 1, term: hsh), "Woche 1 · 21.09. – 27.09.")
        XCTAssertEqual(LectureWeeks.weekLabel(start: start, week: LectureWeeks.generalWeek, term: hsh), "Allgemein")
        XCTAssertEqual(StudyWeeks.weekLabel(start: start, week: 3), "Woche 3 · 05.10. – 11.10.", "ohne Semester wie bisher")
    }

    // MARK: Merken

    private func database(university: String, today: String) async throws -> (SQLiteDatabase, UniFlowClock) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let clock = UniFlowClock.fixed(berlin: today)!
        let db = try SQLiteDatabase(path: dir.appendingPathComponent("t.db").path)
        try await db.migrate(clock: clock, university: university)
        return (db, clock)
    }

    func testAssignmentIsRememberedAndOnlyNewFilesAreAdded() async throws {
        let (db, clock) = try await database(university: "hsh", today: "2026-11-07T10:00:00")
        let now = clock.nowISO
        let rows = ["lw-1-a": "VL 3.pdf", "lw-1-b": "literatur.pdf"]
        try await db.transaction { c in
            try UniStore.upsertCourse(c, UniStore.CourseRow(id: "lw-1", title: "Mathematik 1", number: nil, semester: "WiSe 2026/27"), now: now)
            _ = try UniStore.storeFiles(c, courseID: "lw-1", rows.map { UniStore.FileRow(id: $0.key, name: $0.value, size: 1, mime: "application/pdf",
                                                                                           chdate: nil, downloadURL: "https://moodle.example.org/x", folder: "") },
                                        now: now, fileExists: { _ in false })
        }
        let first = try await db.transaction { c in
            try LectureWeeks.assignCourse(c, courseID: "lw-1", semester: "WiSe 2026/27", university: "hsh",
                                          files: [self.input("lw-1-a", "VL 3.pdf"), self.input("lw-1-b", "literatur.pdf")], now: now)
        }
        XCTAssertEqual(first.count, 2)
        // naechster Abgleich: dieselben Dateien mit anderem Datum aendern nichts; eine neue Datei kommt dazu
        let second = try await db.transaction { c in
            try LectureWeeks.assignCourse(c, courseID: "lw-1", semester: "WiSe 2026/27", university: "hsh",
                                          files: [self.input("lw-1-a", "VL 3.pdf", date: "2026-11-20T10:00:00"),
                                                  self.input("lw-1-b", "literatur.pdf", date: "2026-11-20T10:00:00"),
                                                  self.input("lw-1-c", "Blatt 4.pdf")], now: now)
        }
        XCTAssertEqual(second.map(\.fileID), ["lw-1-c"])
        let stored = try await db.transaction { try LectureWeeks.stored($0) }
        XCTAssertEqual(iso(stored["lw-1-a"]?.monday), "2026-10-05")
        XCTAssertNil(stored["lw-1-b"]?.monday)
        XCTAssertEqual(iso(stored["lw-1-c"]?.monday), "2026-10-12")
        let term = try await db.transaction { try LectureWeeks.storedTerm($0, courseID: "lw-1") }
        XCTAssertEqual(term?.source, "tabelle")
        XCTAssertEqual(iso(term?.start), "2026-09-21")
    }

    func testCourseWithoutSemesterUsesTheRunningTerm() async throws {
        let (db, clock) = try await database(university: "hsh", today: "2026-11-07T10:00:00")
        let now = clock.nowISO
        let t = try await db.transaction { c in
            try LectureWeeks.rememberTerm(c, courseID: "lw-9", semester: "", university: "hsh", earliestDay: nil, now: now)
        }
        XCTAssertEqual(t?.semester, "WiSe 2026/27")
    }

    func testFallbackFromEarliestFileAndUpgradeToTable() async throws {
        let (db, clock) = try await database(university: "hsh", today: "2026-11-07T10:00:00")
        let now = clock.nowISO
        let t = try await db.transaction { c in
            try LectureWeeks.rememberTerm(c, courseID: "lw-5", semester: "WiSe 2019/20", university: "hsh",
                                          earliestDay: BerlinClock.parseISODate("2019-10-16"), now: now)
        }
        XCTAssertEqual(t?.source, "kurs")
        XCTAssertEqual(iso(t?.start), "2019-10-14")
    }

    func testOtherUniversityWithoutAssignmentsIsUnchanged() async throws {
        // Stud.IP der LUH: keine Tabellen, Woche wie bisher aus Aenderungszeit und Hinweis im Namen
        let (db, clock) = try await database(university: "luh", today: "2026-11-07T10:00:00")
        let dates = try await db.transaction { try LocalModules.Dates($0, clock: clock) }
        XCTAssertNil(dates.term)
        XCTAssertTrue(dates.stored.isEmpty)
        let has = try await db.transaction { try LectureWeeks.hasTables($0) }
        XCTAssertFalse(has, "nur lesen legt keine Tabelle an")
    }

    // MARK: Moodle-Abgleich der HsH (Sitzung)

    func testHsHMoodleSyncAssignsWeeksOnceAndShowsThemInTheModule() async throws {
        let base = "https://moodle.example.org"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hsh-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let layout = DataContainerLayout(base: root, key: DataContainerKey(userID: "001234.erfunden.0002", university: .hsh))
        let clock = UniFlowClock.fixed(berlin: "2026-11-07T10:00:00")!
        try layout.prepare(clock: clock)
        try FileManager.default.createDirectory(at: layout.databaseDirectory, withIntermediateDirectories: true)
        let db = try SQLiteDatabase(path: layout.databaseURL.path)
        try await db.migrate(clock: clock, university: "hsh")

        // ein Kurs im Themenformat mit einem grossen Abschnitt (erfunden)
        func state(_ cms: [(Int, String)]) -> JSONValue {
            .object(["section": .array([.object(["id": .string("11"), "number": .number(1), "title": .string("Vorlesung und Übung")])]),
                     "cm": .array(cms.map { .object(["id": .string(String($0.0)), "module": .string("resource"), "name": .string($0.1),
                                                     "sectionid": .string("11")]) })])
        }
        let t = FakeUniTransport()
        t.on("\(base)/my/courses.php", ok(#"<script>M.cfg = {"sesskey":"abc123","wwwroot":"x"};</script>"#))
        t.on("\(base)/lib/ajax/service.php?sesskey=abc123&info=core_course_get_enrolled_courses_by_timeline_classification",
             okJSON(.array([.object(["error": .bool(false), "data": .object(["courses": .array([
                .object(["id": .number(501), "fullname": .string("Mathematik 1, WiSe 2026/27, Dr. Beispiel")])])])])])))
        var cms = [(7, "Vorlesung 3"), (8, "Übungsblatt 2"), (9, "Lösung zu Blatt 2"), (10, "Handout"), (12, "Literatur")]
        func route(_ cms: [(Int, String)]) {
            t.on("\(base)/lib/ajax/service.php?sesskey=abc123&info=core_courseformat_get_state",
                 okJSON(.array([.object(["error": .bool(false), "data": .string(state(cms).jsonString())])])))
        }
        route(cms)
        let names = [7: "folien.pdf", 8: "aufgaben.pdf", 9: "loesung.pdf", 10: "handout.pdf", 12: "literatur.pdf", 13: "zusatz.pdf"]
        for (id, name) in names {
            let file = "\(base)/pluginfile.php/\(id)/mod_resource/content/1/\(name)"
            t.on("\(base)/mod/resource/view.php?id=\(id)", UniResponse(status: 303, headers: ["Location": file]))
            let lm = [10: "Wed, 14 Oct 2026 07:28:00 GMT", 13: "Wed, 04 Nov 2026 09:00:00 GMT"][id]
            t.on(file, UniResponse(status: 200, headers: lm.map { ["Last-Modified": $0] } ?? [:], body: Data("%PDF-1.7 \(id)".utf8)))
        }
        let noWait = UniRetry(attempts: 2, delayNanos: { _ in 0 })
        let sync = HildesheimSync(db: db, container: layout, learnweb: LearnwebAPI(base: base, mode: .session, transport: t, retry: noWait),
                                  lsf: nil, transport: t, clock: clock, names: .hsh)
        let r1 = await sync.run()
        XCTAssertEqual(r1.newFiles.count, 5, r1.messages.joined(separator: "; "))

        func weeks() async throws -> [String: Int?] {
            let rows = try await db.rows("SELECT f.name, w.lecture_week FROM lecture_file_weeks w JOIN files f ON f.id=w.file_id")
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["name"]?.string ?? "", $0["lecture_week"]?.int) })
        }
        let w1 = try await weeks()
        XCTAssertEqual(w1["folien.pdf"], 3)
        XCTAssertEqual(w1["aufgaben.pdf"], 2)
        XCTAssertEqual(w1["loesung.pdf"], 3)
        XCTAssertEqual(w1["handout.pdf"], 4, "Last-Modified 14.10. -> Lehrwoche 4 der HsH")
        XCTAssertEqual(w1["literatur.pdf"], .some(nil), "Allgemein-Material")

        // zweiter Lauf mit einer neuen Datei: Bekanntes bleibt, nur die neue wird zugeordnet, keine HEAD-Anfragen
        cms.append((13, "Zusatzmaterial"))
        route(cms)
        let r2 = await sync.run()
        XCTAssertEqual(r2.newFiles.count, 1)
        let w2 = try await weeks()
        XCTAssertEqual(w2["zusatz.pdf"], 7, "Last-Modified 04.11. -> Lehrwoche 7")
        for (k, v) in w1 { XCTAssertEqual(w2[k], v, k) }
        XCTAssertFalse(t.requests.contains { $0.method == "HEAD" })

        // Moduldetail: Wochen ab dem 21.09., "Allgemein" statt alles in einer Woche
        let detail = try await db.transaction { c -> [String: JSONValue]? in
            try LocalModules.ensureModules(c, clock: clock)
            let m = try c.scalar("SELECT module_id FROM courses WHERE id='lw-501'")
            return try LocalModules.detail(c, moduleID: m ?? .null, clock: clock)
        }
        let labels = (detail?["weeks"]?.array ?? []).compactMap { $0["label"]?.string }
        XCTAssertEqual(labels, ["Allgemein", "Woche 2 · 28.09. – 04.10.", "Woche 3 · 05.10. – 11.10.", "Woche 4 · 12.10. – 18.10.",
                                "Woche 7 · 02.11. – 08.11."])
    }

    /// Schon vor dieser Fassung geladene Dateien ohne Hinweis im Namen: einmal HEAD fuer `Last-Modified`
    func testAlreadyDownloadedFilesGetTheirDateOnce() async throws {
        let base = "https://moodle.example.org"
        let file = LectureWeeksTests.sessionFile(base: base, id: 10, name: "handout.pdf")
        let t = FakeUniTransport()
        t.on(file.downloadURL, UniResponse(status: 200, headers: ["Last-Modified": "Wed, 14 Oct 2026 07:28:00 GMT"]))
        let api = LearnwebAPI(base: base, mode: .session, transport: t, retry: UniRetry(attempts: 1, delayNanos: { _ in 0 }))
        let got = await api.lastModified(file)
        XCTAssertEqual(got, .some(1_791_962_880))
        XCTAssertEqual(t.requests.last?.method, "HEAD")
        let tok = LearnwebAPI(base: base, mode: .token(LearnwebToken("TOK")!), transport: t)
        let none = await tok.lastModified(file)
        XCTAssertNil(none, "mit Schluessel kommt timemodified mit der Liste")
    }

    static func sessionFile(base: String, id: Int, name: String) -> Learnweb.File {
        Learnweb.File(id: "lw-\(id)-x", name: name, size: nil, mime: "application/pdf", chdate: nil,
                      downloadURL: "\(base)/pluginfile.php/\(id)/mod_resource/content/1/\(name)", folder: "")
    }
}
