import Foundation
import XCTest
@testable import UniFlowCore

// Altklausur-Loesungen (17.11.2026), gleiche Faelle wie tests/test_altklausur_loesungen.py:
// - Einordnung der Datei (`StudyClassify.effectiveType`): "sol3a.pdf" neben "kk3a.pdf", "Lsg_SS21.pdf", Loesungen in
//   Ordnern mit "Prüfung" oder "Exam" gehoeren als "Klausur-Lösung" in den Block "Klausuren & Altklausuren"
// - Klausur und Loesung zusammenfuehren (`Weekly.solutionKey`, `Weekly.linkSolutions`): gleicher Ordner zuerst,
//   Kennung ("kk3a"/"sol3a"), Sammeldatei nur bei eindeutiger Aufgabennummer
// Ausgedachte Dateinamen nach dem Muster echter Kurse. Die Tabelle gegen Python steht in study-modules.json
// (`LocalModulesTests.testEffectiveTypeLikePython`).
final class AltklausurLoesungenTests: XCTestCase {

    private func backend() async throws -> LocalBackend {
        try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: .fixed(berlin: "2026-11-17T09:00:00")!)
    }

    // MARK: Einordnung der Datei

    private func type(_ name: String, _ folder: String) -> String {
        let (t, label) = StudyClassify.effectiveType(name: name, folder: folder, aiType: nil)
        return "\(t)/\(label)"
    }

    func testTypeOfExamSolutionsAndNormalFiles() {
        let cases: [(String, String, String)] = [
            // "sol" + Kennung neben "kk" + Kennung
            ("sol0b.pdf", "Alte Klausuren/WS 21/22", "loesung/Klausur-Lösung"),
            ("sol3a.pdf", "Alte Klausuren/WS 21/22", "loesung/Klausur-Lösung"),
            ("kk3a.pdf", "Alte Klausuren/WS 21/22", "klausur/Altklausur"),
            ("kk3a_sol.pdf", "Kurzklausuren", "loesung/Klausur-Lösung"),
            ("sol.pdf", "Probeklausur", "loesung/Klausur-Lösung"),
            // "Lsg" am Namensanfang mit Unterstrich
            ("Lsg_SS21.pdf", "", "loesung/Lösung"),
            ("Lsg_SS21.pdf", "Klausuren", "loesung/Klausur-Lösung"),
            ("lsg2.pdf", "Übung 2", "loesung/Lösung"),
            // Ordner mit "Prüfung" oder "Exam" statt "Klausur"
            ("Loesung.pdf", "Alte Prüfungen/SS 21", "loesung/Klausur-Lösung"),
            ("Musterlösung.pdf", "Pruefung WS 20", "loesung/Klausur-Lösung"),
            ("Probeprüfung Lösung.pdf", "", "loesung/Klausur-Lösung"),
            ("solution.pdf", "Exam 2021", "loesung/Klausur-Lösung"),
            ("Solutions.pdf", "Old Exams", "loesung/Klausur-Lösung"),
            ("Pruefung_SS21.pdf", "Alte Prüfungen/SS 21", "klausur/Altklausur"),
            ("Aufgaben.pdf", "Prüfung", "klausur/Klausur"),
            // normale Dateien bleiben, was sie waren
            ("Lösung Blatt 3.pdf", "Übungen", "loesung/Lösung"),
            ("Blatt3_lsg.pdf", "Übungsblätter", "loesung/Lösung"),
            ("Example_solution.pdf", "Übung", "loesung/Lösung"),
            ("Lösung.pdf", "Prüfungsvorleistung", "loesung/Lösung"),
            ("Lösung Selbstüberprüfung.pdf", "Übung", "loesung/Lösung"),
            ("Solar.pdf", "Vorlesung", "vorlesung/Vorlesung"),
            ("Konsole.pdf", "Vorlesung", "vorlesung/Vorlesung"),
            ("Sol-Gel-Verfahren.pdf", "Vorlesung", "vorlesung/Vorlesung"),
            ("Prüfungsordnung.pdf", "", "sonstiges/Sonstiges"),
            ("Blatt3.pdf", "Prüfungsvorleistungen", "uebung/Übung"),
        ]
        for (name, folder, expected) in cases {
            XCTAssertEqual(type(name, folder), expected, "\(name) in \(folder)")
        }
    }

    func testExamSolutionsGoToTheExamBlockAndNormalSolutionsStayInTheirWeek() throws {
        func week(_ name: String, _ folder: String) throws -> Int {
            let (t, label) = StudyClassify.effectiveType(name: name, folder: folder, aiType: nil)
            return try LocalModules.week(docType: t, subLabel: label, weekHint: nil, chdate: .null, start: 0, today: 0)
        }
        for (name, folder) in [("sol3a.pdf", "Alte Klausuren/WS 21/22"), ("Lsg_SS21.pdf", "Klausuren"), ("Loesung.pdf", "Alte Prüfungen/SS 21"),
                               ("solution.pdf", "Exam 2021"), ("kk3a.pdf", "Alte Klausuren/WS 21/22")] {
            XCTAssertEqual(try week(name, folder), -2, "\(name) in \(folder): Block Klausuren & Altklausuren")
        }
        for (name, folder) in [("Lösung Blatt 3.pdf", "Übungen"), ("Lsg_SS21.pdf", ""), ("Lösung.pdf", "Prüfungsvorleistung")] {
            XCTAssertNotEqual(try week(name, folder), -2, "\(name) in \(folder): normale Loesung")
        }
    }

    // MARK: Moduldetail

    /// Befund am iPad (17.11.2026): im Block "Klausuren & Altklausuren" stehen nur Klausuren. Mit dem Muster des echten
    /// Kurses (Kursart Uebung, Ordner je Jahrgang, Dateien von 2023) liefert das Moduldetail die Loesung im Block.
    func testDetailShowsExamAndSolutionInTheExamBlock() async throws {
        let b = try await backend()
        let clock = UniFlowClock.fixed(berlin: "2026-11-17T09:00:00")!
        let detail = try await b.context.database.transaction { c -> [String: JSONValue]? in
            try c.execute("INSERT INTO modules(id, name, color, created_at) VALUES (7, 'Testmathe', '#123456', '2026-10-01')")
            try c.execute("INSERT INTO courses(id, title, kind, created_at, module_id, active) VALUES ('k2', 'Übung zu Testmathe I', 'uebung', '2026-10-01', 7, 1)")
            for (id, name, folder) in [("e1", "KK1.pdf", "Alte Klausuren/WS 22/23"), ("s1", "KK1loes.pdf", "Alte Klausuren/WS 22/23"),
                                       ("e2", "kk3a.pdf", "Alte Klausuren/WS 21/22"), ("s2", "sol3a.pdf", "Alte Klausuren/WS 21/22"),
                                       ("e3", "KK2.pdf", "Alte Klausuren/WS 20/21"), ("s3", "Lösungen.pdf", "Alte Klausuren/WS 20/21")] {
                try c.execute("INSERT INTO files(id, course_id, name, chdate, kind, studip_folder) VALUES (?, 'k2', ?, 1676000000, 'pdf', ?)",
                              [.text(id), .text(name), .text(folder)])
            }
            return try LocalModules.detail(c, moduleID: .integer(7), clock: clock)
        }
        let block = try XCTUnwrap(detail?["weeks"]?.array?.first { $0["week"]?.int == -2 }, "Block Klausuren & Altklausuren fehlt")
        XCTAssertEqual(block["label"]?.string, "Klausuren & Altklausuren")
        XCTAssertEqual(Set((block["klausuren"]?.array ?? []).compactMap { $0["id"]?.string }), ["e1", "e2", "e3"])
        XCTAssertEqual(Set((block["loesungen"]?.array ?? []).compactMap { $0["id"]?.string }), ["s1", "s2", "s3"])
        XCTAssertEqual(block["count"]?.int, 6)
        XCTAssertEqual(detail?["weeks"]?.array?.count, 1, "keine Loesung in einer anderen Woche")
    }

    // MARK: Schluessel

    func testKeysOfExamAndSolutionFit() {
        let pairs = [("kk3a.pdf", "sol3a.pdf"), ("TK.pdf", "Lösungen zu TK.pdf"),
                     ("Muster-Klausuraufgaben-WS1920.pdf", "A4-Loesung-Muster-Klausuraufgaben-WS1920.pdf"),
                     // diese Paare fanden sich schon vorher
                     ("KK1.pdf", "KK1loes.pdf"), ("gk.pdf", "gk_lsg.pdf"), ("KK2bWS2122auf.pdf", "KK2bWS2122lsg.pdf"),
                     ("kkw17_auf.pdf", "kkw17_loes.pdf"), ("A4.pdf", "A4_lsg.pdf")]
        for (task, solution) in pairs {
            let a = Weekly.solutionKey(task), b = Weekly.solutionKey(solution)
            let same = a == b || Weekly.plainKey(task) == Weekly.plainKey(solution)
            let part = min(Weekly.len(a), Weekly.len(b)) >= 4 && (a.contains(b) || b.contains(a)) && Weekly.numbers(a) == Weekly.numbers(b)
            let tail = Weekly.idTail.match(a)?.group(1)
            XCTAssertTrue(same || part || tail == b, "\(task) / \(solution): \(a) / \(b)")
        }
    }

    func testSolCountsOnlyAsAPieceOfItsOwnInTheKey() {
        XCTAssertEqual(Weekly.solutionKey("sol3a.pdf"), "3a")
        XCTAssertEqual(Weekly.solutionKey("kk3a_sol.pdf"), "kk3a")
        XCTAssertEqual(Weekly.solutionKey("Konsole 1.pdf"), "konsole1")
        XCTAssertEqual(Weekly.solutionKey("Solar_2.pdf"), "solar2")
        XCTAssertEqual(Weekly.solutionKey("Zusatzaufgaben.pdf"), "zusatzaufgaben", "'zu' faellt nur als eigenes Wort weg")
        XCTAssertEqual(Weekly.solutionKey("Lösungen zu TK.pdf"), "tk")
        XCTAssertEqual(Weekly.plainKey("A4-Loesung-Muster-Klausuraufgaben-WS1920.pdf"), "musterklausuraufgabenws1920")
        XCTAssertEqual(Weekly.plainKey("A4_lsg.pdf"), "a4", "Aufgabe 4 behaelt ihren Schluessel")
    }

    // MARK: Klausur und Loesung zusammenfuehren

    /// (ID, Name, Ordner, Quelle, Aufgabennummern)
    private typealias Entry = (String, String, String, String, [String])

    private func link(_ c: SQLiteConnection, _ files: [Entry]) throws {
        try c.execute("INSERT INTO modules(id, name, color, created_at) VALUES (7, 'Testmathe', '#123456', '2026-10-01')")
        try c.execute("INSERT INTO courses(id, title, kind, created_at, module_id, active) VALUES ('k2', 'Übung Testmathe I', 'uebung', '2026-10-01', 7, 1)")
        for (id, name, folder, source, nrs) in files {
            try c.execute("INSERT INTO files(id, course_id, name, chdate, kind, studip_folder) VALUES (?, 'k2', ?, 5, 'pdf', ?)",
                          [.text(id), .text(name), .text(folder)])
            for nr in nrs {
                try c.execute("""
                    INSERT INTO task_index(file_id, version, module_id, source, nr, label, page_from, page_to, text, lecture_refs, content_hash, indexed_at)
                    VALUES (?, 'v', 7, ?, ?, ?, 1, 1, ?, '[]', 'h', '2026-11-01T10:00:00')
                    """, [.text(id), .text(source), .text(nr), .text("\(id) \(nr)"), .text("Text von \(id), Aufgabe \(nr)")])
            }
        }
        try Weekly.linkSolutions(c, 7)
    }

    private func solution(_ c: SQLiteConnection, _ fileID: String, _ nr: String = "1") throws -> String? {
        let r = try c.rows("SELECT solution_file_id, solution_text FROM task_index WHERE file_id=? AND nr=?", [.text(fileID), .text(nr)]).first
        XCTAssertNotNil(r, "Aufgabe \(fileID)/\(nr) fehlt")
        XCTAssertEqual(r?["solution_file_id"]?.string == nil, r?["solution_text"]?.string == nil, "Datei und Text der Loesung gehoeren zusammen")
        return r?["solution_file_id"]?.string
    }

    func testPairsInTheSameFolder() async throws {
        let b = try await backend()
        let old = "Alte Klausuren/WS 21/22"
        try await b.context.database.transaction { c in
            try self.link(c, [
                // "kk" + Kennung und "sol" + Kennung
                ("k0", "kk0b.pdf", old, "altklausur", ["1", "2"]), ("s0", "sol0b.pdf", old, "loesung", ["1", "2"]),
                ("k3", "kk3a.pdf", old, "altklausur", ["1"]), ("s3", "sol3a.pdf", old, "loesung", ["1"]),
                ("k4", "kk4a.pdf", old, "altklausur", ["1"]),                                    // ohne Loesung
                // "Lösungen zu …" mit kurzem Namen
                ("tk", "TK.pdf", "Probeklausur", "altklausur", ["1"]), ("tks", "Lösungen zu TK.pdf", "Probeklausur", "loesung", ["1"]),
                // Papierformat vor dem Namen
                ("mk", "Muster-Klausuraufgaben-WS1920.pdf", "Klausur", "altklausur", ["1"]),
                ("mks", "A4-Loesung-Muster-Klausuraufgaben-WS1920.pdf", "Klausur", "loesung", ["1"]),
                // schon vorher gefunden
                ("a", "KK1.pdf", "Kurzklausuren", "altklausur", ["1"]), ("as", "KK1loes.pdf", "Kurzklausuren", "loesung", ["1"]),
                ("b", "gk.pdf", "Kurzklausuren", "altklausur", ["1"]), ("bs", "gk_lsg.pdf", "Kurzklausuren", "loesung", ["1"]),
                ("d", "KK2bWS2122auf.pdf", "Kurzklausuren", "altklausur", ["1"]), ("ds", "KK2bWS2122lsg.pdf", "Kurzklausuren", "loesung", ["1"]),
                ("e", "kkw17_auf.pdf", "Kurzklausuren", "altklausur", ["1"]), ("es", "kkw17_loes.pdf", "Kurzklausuren", "loesung", ["1"]),
            ])
            XCTAssertEqual(try self.solution(c, "k0"), "s0")
            XCTAssertEqual(try self.solution(c, "k0", "2"), "s0")
            XCTAssertEqual(try self.solution(c, "k3"), "s3")
            XCTAssertNil(try self.solution(c, "k4"), "kk4a hat keine Loesung, nie die von kk3a")
            XCTAssertEqual(try self.solution(c, "tk"), "tks")
            XCTAssertEqual(try self.solution(c, "mk"), "mks")
            XCTAssertEqual(try ["a", "b", "d", "e"].map { try self.solution(c, $0) }, ["as", "bs", "ds", "es"])
        }
    }

    func testSameNamesInTwoTermFoldersStayInTheirFolder() async throws {
        let b = try await backend()
        try await b.context.database.transaction { c in
            try self.link(c, [
                ("k21", "kk1b.pdf", "Alte Klausuren/WS 21/22", "altklausur", ["1"]), ("s21", "sol1b.pdf", "Alte Klausuren/WS 21/22", "loesung", ["1"]),
                ("k20", "kk1b.pdf", "Alte Klausuren/WS 20/21", "altklausur", ["1"]), ("s20", "sol1b.pdf", "Alte Klausuren/WS 20/21", "loesung", ["1"]),
                ("k19", "kk1b.pdf", "Alte Klausuren/WS 19/20", "altklausur", ["1"]),            // Ordner ohne Loesung
                ("p21", "KK2.pdf", "Alte Klausuren/WS 21/22", "altklausur", ["1"]), ("q21", "KK2loes.pdf", "Alte Klausuren/WS 21/22", "loesung", ["1"]),
                ("p20", "KK2.pdf", "Alte Klausuren/WS 20/21", "altklausur", ["1"]), ("q20", "KK2loes.pdf", "Alte Klausuren/WS 20/21", "loesung", ["1"]),
            ])
            XCTAssertEqual(try self.solution(c, "k21"), "s21")
            XCTAssertEqual(try self.solution(c, "k20"), "s20")
            XCTAssertNil(try self.solution(c, "k19"), "die Kennung zaehlt nur im eigenen Ordner")
            XCTAssertEqual(try self.solution(c, "p21"), "q21", "gleicher Name in zwei Semestern: der eigene Ordner gilt")
            XCTAssertEqual(try self.solution(c, "p20"), "q20")
        }
    }

    func testIdentifierPairsOnlyWhenUniqueAndNeverSheetOneWithTen() async throws {
        let b = try await backend()
        try await b.context.database.transaction { c in
            try self.link(c, [
                ("u3", "Übung 3.pdf", "Übungen", "uebungsblatt", ["1"]), ("l3", "Lösung 3.pdf", "Übungen", "loesung", ["1"]),
                ("b1", "Blatt 1.pdf", "Blätter", "uebungsblatt", ["1"]), ("b10", "Blatt 10.pdf", "Blätter", "uebungsblatt", ["1"]),
                ("l10", "Lösung 10.pdf", "Blätter", "loesung", ["1"]),
                // zwei Aufgabendateien mit derselben Kennung: nicht eindeutig
                ("g2", "GU 2.pdf", "Gemischt", "gruppenuebung", ["1"]), ("h2", "HU 2.pdf", "Gemischt", "hoersaaluebung", ["1"]),
                ("l2", "Lösung 2.pdf", "Gemischt", "loesung", ["1"]),
                // andere Ordner: die Kennung allein reicht nicht
                ("x5", "Blatt 5.pdf", "Aufgaben", "uebungsblatt", ["1"]), ("y5", "Lösung 5.pdf", "Lösungen", "loesung", ["1"]),
            ])
            XCTAssertEqual(try self.solution(c, "u3"), "l3")
            XCTAssertEqual(try self.solution(c, "b10"), "l10")
            XCTAssertNil(try self.solution(c, "b1"), "Blatt 1 nie mit der Loesung von Blatt 10 (Audit P49-06)")
            XCTAssertNil(try self.solution(c, "g2"))
            XCTAssertNil(try self.solution(c, "h2"))
            XCTAssertNil(try self.solution(c, "x5"))
        }
    }

    func testSolutionsInTheirOwnFolderStillFitByName() async throws {
        let b = try await backend()
        try await b.context.database.transaction { c in
            try self.link(c, [
                ("b2", "Blatt 2.pdf", "Übungsblätter", "uebungsblatt", ["1"]), ("l2", "Lösung Blatt 2.pdf", "Lösungen", "loesung", ["1"]),
                ("b7", "Übungsblatt 7.pdf", "Übungsblätter", "uebungsblatt", ["1"]),
                ("l7", "Übungsblatt 7 Musterlösung.pdf", "Lösungen", "loesung", ["1"]),
            ])
            XCTAssertEqual(try self.solution(c, "b2"), "l2")
            XCTAssertEqual(try self.solution(c, "b7"), "l7")
        }
    }

    func testCollectiveSolutionFileOnlyWhereTheTaskNumberIsUnique() async throws {
        let b = try await backend()
        let one = "Alte Klausuren/SS 21", many = "Alte Klausuren/WS 20/21", split = "Alte Klausuren/SS 20"
        try await b.context.database.transaction { c in
            try self.link(c, [
                // eine Klausur und "Lösung.pdf": sauber
                ("k", "Klausur.pdf", one, "altklausur", ["1", "2"]), ("ks", "Lösung.pdf", one, "loesung", ["1", "2"]),
                // KK1 bis KK4, jede mit Aufgabe 1 und 2, und eine Sammeldatei: nicht zu trennen
                ("m1", "KK1.pdf", many, "altklausur", ["1", "2"]), ("m2", "KK2.pdf", many, "altklausur", ["1", "2"]),
                ("m3", "KK3.pdf", many, "altklausur", ["1", "2"]), ("m4", "KK4.pdf", many, "altklausur", ["1", "2", "3"]),
                ("ms", "Lösungen.pdf", many, "loesung", ["1", "2", "3"]),
                // durchgezaehlte Aufgaben: jede Nummer gehoert zu genau einer Klausur
                ("n1", "KK1.pdf", split, "altklausur", ["1", "2"]), ("n2", "KK2.pdf", split, "altklausur", ["3", "4"]),
                ("ns", "Lösungen.pdf", split, "loesung", ["1", "2", "3", "4"]),
                // ohne Ordner und fuer Uebungsblaetter gilt die Sammeldatei nicht
                ("r", "Probeklausur.pdf", "", "altklausur", ["1"]), ("rs", "Lösung.pdf", "", "loesung", ["1"]),
                ("u", "Blatt 4.pdf", "Übungen", "uebungsblatt", ["1"]), ("us", "Lösungen.pdf", "Übungen", "loesung", ["1"]),
            ])
            XCTAssertEqual(try self.solution(c, "k"), "ks")
            XCTAssertEqual(try self.solution(c, "k", "2"), "ks")
            for f in ["m1", "m2", "m3", "m4"] {
                XCTAssertNil(try self.solution(c, f, "1"), "Aufgabe 1 steht in vier Klausuren")
                XCTAssertNil(try self.solution(c, f, "2"))
            }
            XCTAssertEqual(try self.solution(c, "m4", "3"), "ms", "Aufgabe 3 gibt es nur in KK4")
            XCTAssertEqual(try self.solution(c, "n1", "1"), "ns")
            XCTAssertEqual(try self.solution(c, "n1", "2"), "ns")
            XCTAssertEqual(try self.solution(c, "n2", "3"), "ns")
            XCTAssertEqual(try self.solution(c, "n2", "4"), "ns")
            XCTAssertNil(try self.solution(c, "r"))
            XCTAssertNil(try self.solution(c, "u"))
        }
    }

    func testTwoCollectiveFilesInOneFolderLinkNothing() async throws {
        let b = try await backend()
        let folder = "Alte Klausuren/SS 19"
        try await b.context.database.transaction { c in
            try self.link(c, [("k", "Klausur.pdf", folder, "altklausur", ["1"]), ("s1", "Lösung.pdf", folder, "loesung", ["1"]),
                              ("s2", "Musterlösung.pdf", folder, "loesung", ["1"])])
            XCTAssertNil(try self.solution(c, "k"))
        }
    }
}
