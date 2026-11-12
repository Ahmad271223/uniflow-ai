import Foundation
import XCTest
@testable import UniFlowCore

/// Echter Aufbau des LUH-Notenspiegels (Beschreibung des Inhabers 12.11.2026, Testdaten erfunden), dieselben Werte wie
/// tests/test_qis_notenspiegel_echt.py: fixtures/qis-notenspiegel/luh-notenspiegel.tsv (Tabulator-getrennt wie aus QIS
/// kopiert) und luh-notenspiegel.html (Tabelle wie QIS im Seitenaufbau von qis-echt-list.html). Text- und HTML-Weg
/// muessen dasselbe ergeben.
///
/// Am alten Stand (580072ea) falsch: anerkannte Leistungen zeigten die Note "0,0" (Uni & Noten, Studienverlauf), die
/// Leistung "Betriebswirtschaftslehre" des Moduls "Studium Generale" stand im Studienverlauf als "nicht zugeordnet",
/// Leistungen kannten ihr Modul nicht (`modul_nr`), zwei bestandene Eintraege derselben Pruefung zaehlten beide, mit
/// Spalte "Prf.Art" machte ein Wert in "Versuch" eine Modulzeile zur Leistung, und die Navigation folgte Links ohne
/// Rueckhalt bis zur Seitengrenze (kein Schutz vor Schleifen, kein eigener Studiengang zuerst).
final class QISNotenspiegelEchtTests: XCTestCase {
    private let pageURL = URL(string: "https://qis.verwaltung.uni-hannover.de/qisserver/servlet/de.his.servlet.RequestDispatcherServlet?state=notenspiegelStudent&next=list.vm&nextdir=qispos/notenspiegel/student&nodeID=auswahlBaum%7Cabschluss%3Aabschl%3D82%7Cstudiengang%3Astg%3DM24&asi=S1abcDEF")!
    private let abschluss = "Maschinenbau (PO-Version 2024)"
    private let noWait = UniRetry(attempts: 2, delayNanos: { _ in 0 })

    private func repo(_ relative: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url.deleteLastPathComponent() }
        return try String(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/qis-notenspiegel/" + relative),
                          encoding: .utf8)
    }

    private func textGrades() throws -> [QISGrade] {
        let rows = try repo("luh-notenspiegel.tsv").split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        return GradeRows.parse(rows: rows, abschluss: abschluss)
    }

    private func htmlGrades() throws -> [QISGrade] {
        QISPage.parse(html: try repo("luh-notenspiegel.html"), url: pageURL).grades(abschluss: abschluss)
    }

    private func database() async throws -> SQLiteDatabase {
        let db = try SQLiteDatabase(path: SQLiteDatabase.inMemory)
        try await db.migrate(clock: .fixed(Date(timeIntervalSince1970: 1_792_900_000)), university: "luh")
        return db
    }

    /// Wie nach einem Abruf: Zeilen in der Tabelle grades (Reihenfolge der Seite)
    private func stored(_ grades: [QISGrade]) async throws -> [[String: JSONValue]] {
        let db = try await database()
        try await db.transaction { c in try UniStore.replaceGrades(c, grades, now: "2026-11-12T09:00:00") }
        return try await db.rows("SELECT * FROM grades ORDER BY id")
    }

    static let catalog: JSONValue = [
        "v": 1, "university": "luh", "program": "Maschinenbau", "code": "MBBSc24", "po": "2024", "regular_semesters": 6,
        "total_lp": 180, "areas": [["id": "pflicht", "kind": "pflicht", "name": "Pflichtmodule"]],
        "modules": [
            ["id": "mathe-1", "title": "Mathematik für die Ingenieurwissenschaften I", "lp": 8, "semester": 1, "kind": "pflicht",
             "area": "pflicht", "turnus": "WS", "code": .null],
            ["id": "tm-2", "title": "Technische Mechanik II", "lp": 5, "semester": 2, "kind": "pflicht", "area": "pflicht",
             "turnus": "SS", "code": .null],
            ["id": "studium-generale", "title": "Studium Generale", "lp": 6, "semester": 3, "kind": "pflicht", "area": "pflicht",
             "turnus": .null, "code": .null],
        ],
    ]

    private func check(_ grades: [QISGrade], file: StaticString = #filePath, line: UInt = #line) async throws {
        XCTAssertEqual(grades.map(\.pruefungsnr), ["11", "100", "110", "1110", "1110", "2500", "132110"], "jede Zeile", file: file, line: line)
        let rows = try await stored(grades)
        let s = GradesModel.summary(rows)
        let m = (s["grades"]?.array ?? []).compactMap(\.object)
        func row(_ nr: String, _ sem: String) throws -> [String: JSONValue] {
            try XCTUnwrap(m.first { $0["pruefungsnr"]?.string == nr && $0["semester_norm"]?.string == sem }, "\(nr) \(sem)", file: file, line: line)
        }
        // Reihenfolge der Leistungen wie in GradesModel.model (Seite)
        let leistungen = GradesModel.model(rows).filter { $0["level"]?.string == "pruefung" }
        XCTAssertEqual(leistungen.map { $0["pruefungsnr"]?.string }, ["110", "1110", "1110", "132110"], "4 Leistungen (PL/SL)", file: file, line: line)
        XCTAssertEqual(leistungen.map { $0["art"]?.string }, ["PL", "PL", "PL", "PL"], file: file, line: line)
        let bereich = try row("11", "")
        XCTAssertEqual(bereich["level"], "bereich", file: file, line: line)
        XCTAssertEqual(bereich["lp_counted"], 0, "Kompetenzbereich (Summe 22 LP) nie", file: file, line: line)
        XCTAssertEqual(try row("100", "WiSe 24/25")["level"], "modul", file: file, line: line)
        XCTAssertEqual(try row("2500", "WiSe 24/25")["level"], "modul", file: file, line: line)
        // Technische Mechanik II: Fehlversuch SoSe 25, bestanden SoSe 26
        let tm = try row("1110", "SoSe 26")
        XCTAssertEqual([tm["note"], tm["credits"], tm["datum_iso"], tm["passed"], tm["graded"], tm["counted"]],
                       ["3,3", "5", "2026-08-21", true, true, true], file: file, line: line)
        let fail = try row("1110", "SoSe 25")
        XCTAssertEqual([fail["status"], fail["datum_iso"], fail["passed"], fail["counted"]], ["nicht bestanden", "2025-08-22", false, false],
                       file: file, line: line)
        XCTAssertEqual(s["failed_attempts"], 1, file: file, line: line)
        // anerkannt ohne Note
        let m1 = try row("110", "WiSe 24/25")
        XCTAssertEqual([m1["note"], m1["anerkannt"], m1["passed"], m1["graded"]], ["", true, true, false], "0,0 = anerkannt", file: file, line: line)
        XCTAssertEqual([m1["modul_nr"], m1["modul_text"]], ["100", "Mathematik für die Ingenieurwissenschaften I"], file: file, line: line)
        XCTAssertEqual(try row("100", "WiSe 24/25")["note"], "", file: file, line: line)
        let bwl = try row("132110", "WiSe 24/25")
        XCTAssertEqual([bwl["modul_nr"], bwl["modul_text"]], ["2500", "Studium Generale"], "Leistung des Moduls ohne eigene Pruefungen",
                       file: file, line: line)
        XCTAssertEqual(tm["modul_nr"], .null, "gehoert nicht zum bestandenen Modul davor", file: file, line: line)
        // LP 19: Mathematik I 8 einmal, Technische Mechanik II 5, Studium Generale 6; Schnitt nur aus 3,3
        XCTAssertEqual(s["credits"], 19, file: file, line: line)
        XCTAssertEqual(GradesModel.creditsDone(rows), 19, file: file, line: line)
        var counted: [String: Double] = [:]
        for r in m where r["counted"]?.bool == true { counted[r["pruefungsnr"]?.string ?? ""] = r["lp_counted"]?.double }
        XCTAssertEqual(counted, ["100": 8, "1110": 5, "2500": 6], file: file, line: line)
        XCTAssertEqual([s["average"], s["average_exact"], s["graded_count"], s["passed"]], [3.3, 3.3, 1, 3], file: file, line: line)
        // Studienverlauf
        let p = StudyPlanEngine.buildPlan(catalog: Self.catalog, grades: GradesModel.model(rows), settings: [:], today: "2026-11-12")
        var mods: [String: (String, JSONValue)] = [:]
        for sem in p["semesters"]?.array ?? [] { for mod in sem["modules"]?.array ?? [] { mods[mod["id"]?.string ?? ""] = (sem["term"]?.string ?? "", mod) } }
        XCTAssertEqual(p["lp_done"], 19, file: file, line: line)
        XCTAssertEqual(p["start_term"], "WiSe 24/25", file: file, line: line)
        XCTAssertEqual(p["unmatched"], [], "Betriebswirtschaftslehre gehoert zu Studium Generale", file: file, line: line)
        let t = try XCTUnwrap(mods["tm-2"], file: file, line: line)
        // Versuchsspalte zeigt bei beiden 1: gezaehlt wird der Fehlversuch (eigenes Semester und Datum), der bestandene
        // ist Versuch 2 (max(Fehlversuche + 1, Versuch laut QIS))
        XCTAssertEqual(t.0, "SoSe 26", file: file, line: line)
        XCTAssertEqual([t.1["status"], t.1["attempt"], t.1["grade"], t.1["attempt_known"]], ["bestanden", 2, "3,3", true], file: file, line: line)
        XCTAssertEqual(mods["mathe-1"]?.0, "WiSe 24/25", file: file, line: line)
        XCTAssertEqual(mods["mathe-1"]?.1["grade"], .null, "anerkannt: keine Note", file: file, line: line)
        XCTAssertEqual(mods["studium-generale"]?.0, "WiSe 24/25", file: file, line: line)
        XCTAssertEqual([mods["studium-generale"]?.1["status"], mods["studium-generale"]?.1["grade"], mods["studium-generale"]?.1["attempt_known"]],
                       ["bestanden", .null, true], file: file, line: line)
    }

    func testTextPathLUHNotenspiegel() async throws {
        let g = try textGrades()
        XCTAssertEqual(g.first?.semester, "2,5", "Kompetenzbereich ohne Zelle fuer Semester: verschoben wie kopiert")
        try await check(g)
    }

    func testHTMLPathLUHNotenspiegel() async throws {
        let g = try htmlGrades()
        XCTAssertEqual([g.first?.note, g.first?.credits], ["2,5", "22"], "colspan: Note und LP unter ihrer Spalte")
        XCTAssertFalse(g.contains { $0.raw.contains("Erika") || $0.raw.contains("1234567") }, "Stammdaten nie gelesen")
        try await check(g)
    }

    /// Knopf "Diese Seite auslesen": dieselbe Seite aus der Webansicht -> dieselben Zeilen in der Datenbank
    func testReadDisplayedPageStoresTheNotenspiegel() async throws {
        let db = try await database()
        let r = await QISPageImport.read(db: db, html: try repo("luh-notenspiegel.html"), url: pageURL,
                                         clock: .fixed(berlin: "2026-11-12T10:00:00")!, abschluss: abschluss)
        XCTAssertEqual(r.result, .grades(7))
        let rows = try await db.rows("SELECT * FROM grades ORDER BY id")
        XCTAssertEqual(GradesModel.summary(rows)["credits"], 19)
        XCTAssertFalse(rows.contains { ($0["raw"]?.string ?? "").contains("S1abcDEF") || ($0["raw"]?.string ?? "").contains("Erika") })
        let run = try await db.rows("SELECT message, ok FROM qis_runs ORDER BY id DESC LIMIT 1").first
        XCTAssertEqual(run?["ok"]?.int, 1)
        XCTAssertTrue(QISPageImport.accepts(pageURL, allowedHosts: ["qis.verwaltung.uni-hannover.de"]))
        XCTAssertFalse(QISPageImport.accepts(URL(string: "https://qis.example.org/x")!, allowedHosts: ["qis.verwaltung.uni-hannover.de"]))
        // Anmeldeseite und fremde Seite: nichts gespeichert
        let login = await QISPageImport.read(db: db, html: #"<form><input name="asdf"><input type="password" name="fdsa"></form>"#, url: pageURL)
        XCTAssertEqual(login.result, .loginPage)
        let other = await QISPageImport.read(db: db, html: "<html><body><h1>Mein Studium</h1></body></html>", url: pageURL)
        XCTAssertEqual(other.result, .nothing)
    }

    /// Info über angemeldete Prüfungen (echte Seite qis-echt-list.html) ueber denselben Knopf
    func testReadDisplayedRegistrationPage() async throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url.deleteLastPathComponent() }
        let html = try String(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/exam-registration/qis-echt-list.html"), encoding: .utf8)
        let db = try await database()
        let r = await QISPageImport.read(db: db, html: html, url: pageURL)
        guard case .registrations(let n) = r.result else { return XCTFail("\(r.result)") }
        XCTAssertGreaterThan(n, 0)
        let stored = try await db.withConnection { c in try QISRegistrationsSync.rows(c) }
        XCTAssertEqual(stored.count, n)
        let count = try await db.scalar("SELECT COUNT(*) FROM grades")?.int
        XCTAssertEqual(count, 0, "keine Leistung aus der Anmeldeliste")
    }

    /// Zwei bestandene Eintraege derselben Pruefung: der neueste nach Datum gilt (alter Stand: LP 10, Schnitt 3,0)
    func testNewestPassedEntryOfAnExamCountsOnce() async throws {
        let g = GradeRows.parse(rows: [
            ["PrfNr.", "Bezeichnung der Leistung", "Prf.Art", "Semester", "Note", "Status", "Leistungspunkte", "Datum", "Versuch"],
            ["1110", "Technische Mechanik II", "PL", "SoSe 25", "3,7", "bestanden", "5", "22.08.2025", "1"],
            ["1110", "Technische Mechanik II", "PL", "WiSe 25/26", "2,3", "bestanden", "5", "20.02.2026", "2"]])
        let s = GradesModel.summary(try await stored(g))
        XCTAssertEqual([s["credits"], s["average_exact"], s["passed"]], [5, 2.3, 1])
        let old = try XCTUnwrap(s["grades"]?.array?.first { $0["semester_norm"] == "SoSe 25" })
        XCTAssertEqual([old["superseded"], old["counted"], old["graded"]], [true, false, false])
    }

    /// Mit Spalte Prf.Art ist eine Zeile ohne Art eine Modulzeile, auch mit Wert in "Versuch"; SL immer unbenotet
    func testArtColumnDecidesModuleRows() async throws {
        let g = GradeRows.parse(rows: [
            ["PrfNr.", "Bezeichnung der Leistung", "Prf.Art", "Semester", "Note", "Status", "Leistungspunkte", "Datum", "Versuch"],
            ["300", "Konstruktionslehre", "", "SoSe 26", "2,0", "bestanden", "6", "30.07.2026", "1"],
            ["310", "Konstruktionslehre Klausur", "PL", "SoSe 26", "2,0", "bestanden", "4", "30.07.2026", "1"],
            ["320", "Konstruktionslehre Entwurf", "SL", "SoSe 26", "", "bestanden", "2", "15.07.2026", "1"]])
        let s = GradesModel.summary(try await stored(g))
        let rows = (s["grades"]?.array ?? [])
        XCTAssertEqual(rows.first { $0["pruefungsnr"] == "300" }?["level"], "modul")
        XCTAssertEqual([s["credits"], s["passed"], s["basis"]], [6, 1, "module"])
        let sl = try XCTUnwrap(rows.first { $0["pruefungsnr"] == "320" })
        XCTAssertEqual([sl["art"], sl["graded"], sl["modul_nr"]], ["SL", false, "300"])
    }

    func testHeaderPrfArtAndNavigationRules() {
        XCTAssertEqual(GradeRows.headerMap(["PrfNr.", "Bezeichnung der Leistung", "Prf.Art", "Semester ", "Note", "Status", "Leistungspunkte",
                                            "Datum", "Versuch", "Vermerk", "Freiversuch"]),
                       ["pruefungsnr", "text", "art", "semester", "note", "status", "credits", "datum", "versuch", "status", nil])
        func link(_ text: String, _ address: String) -> QISLink {
            QISLink(text: text, address: address, parameters: QISParser.parameters(of: address))
        }
        let q = "https://qis.verwaltung.uni-hannover.de/qisserver/rds"
        for l in [link("Logout", q + "?state=user&type=4&category=auth.logout"), link("Prüfungsanmeldung/-abmeldung", q + "?state=prfAnmStudent"),
                  link("Abmelden", q), link("PDF-Notenspiegel", q + "?state=verpublish")] {
            XCTAssertTrue(QISParser.isForbiddenNavigation(l), l.text)
        }
        XCTAssertFalse(QISParser.isForbiddenNavigation(link("Leistungen für Maschinenbau (PO-Version 2024) anzeigen",
                                                            q + "?state=notenspiegelStudent&next=list.vm&nodeID=auswahlBaum|abschluss:abschl=82|studiengang:stg=M24")))
        XCTAssertFalse(QISParser.isForbiddenNavigation(link("Info über angemeldete Prüfungen", q + "?state=examsinfosStudent&next=tree.vm")))
        let a = link("Leistungen für Mathematik (PO-Version 2017) anzeigen", q + "?a"), b = link("Leistungen für Maschinenbau (PO-Version 2024) anzeigen", q + "?b")
        XCTAssertEqual(QISParser.preferProgram([a, b], ["Maschinenbau (PO-Version 2024)"]).map(\.address), [b.address, a.address], "eigener zuerst")
        XCTAssertEqual(QISParser.preferProgram([a, b], []).map(\.address), [a.address, b.address])
    }

    /// Zwei Studiengaenge, Seitengrenze 6: der eigene (zuletzt gelesene) Studiengang wird zuerst gelesen, auch wenn er auf
    /// der Seite an zweiter Stelle steht; nie ein Link zum Abmelden oder zur Pruefungsanmeldung
    func testOwnProgramFirstAndNeverForbiddenLinks() async throws {
        let base = "https://qis.verwaltung.uni-hannover.de/qisserver/rds"
        let asi = "S1abcDEF"
        let logout = #"<a href="\#(base)?state=user&amp;type=4&amp;category=auth.logout&amp;asi=\#(asi)">Abmelden</a>"#
        let start = "<html><body>\(logout)<a href=\"\(base)?state=change&amp;type=1&amp;moduleParameter=studyPOSMenu&amp;asi=\(asi)\">Mein Studium</a></body></html>"
        let studium = """
            <html><body>\(logout)<a href="\(base)?state=prfAnmStudent&amp;asi=\(asi)">Prüfungsanmeldung/-abmeldung</a>
            <a href="\(base)?state=notenspiegelStudent&amp;next=tree.vm&amp;asi=\(asi)">Notenspiegel / Studienverlauf</a></body></html>
            """
        func stg(_ id: String, _ name: String) -> String {
            #"<li><a href="\#(base)?state=notenspiegelStudent&amp;next=list.vm&amp;nodeID=auswahlBaum|abschluss:abschl=82|studiengang:stg=\#(id)&amp;asi=\#(asi)" title="Leistungen für \#(name) (PO-Version 2024) anzeigen"><img alt=""></a></li>"#
        }
        let tree = "<html><body>\(logout)<ul>\(stg("MA", "Mathematik"))\(stg("MB", "Maschinenbau"))</ul></body></html>"
        let list = try repo("luh-notenspiegel.html")
        var order: [String] = []
        let t = FakeUniTransport { r in
            let u = r.url.absoluteString.removingPercentEncoding ?? ""
            XCTAssertFalse(u.contains("prfAnm") || u.contains("logout"), "nie Anmeldung/Abmelden: \(u)")
            if u == QISClient.startURL.absoluteString { return ok(start) }
            if u.contains("studyPOSMenu") { return ok(studium) }
            if u.contains("next=list.vm") { order.append(u.contains("stg=MB") ? "MB" : "MA"); return ok(list) }
            if u.contains("notenspiegelStudent") { return ok(tree) }
            return UniResponse(status: 404)
        }
        let r = try await QISClient(transport: t, retry: noWait, preferred: ["Maschinenbau (PO-Version 2024)"]).fetch()
        XCTAssertEqual(order, ["MB", "MA"], "eigener Studiengang zuerst")
        XCTAssertTrue(r.complete)
    }

    /// Schutz vor Schleifen: eine Seite, die immer neue Baumknoten ohne Leistungen anbietet -> nach `stallLimit` Seiten
    /// ohne Leistungstabelle wird keinem Link mehr gefolgt (vorher bis zur Seitengrenze 60)
    func testLoopStopsAfterStallLimit() async throws {
        let base = "https://qis.verwaltung.uni-hannover.de/qisserver/rds"
        let asi = "S1abcDEF"
        let logout = #"<a href="\#(base)?state=user&amp;type=4&amp;category=auth.logout&amp;asi=\#(asi)">Abmelden</a>"#
        let start = "<html><body>\(logout)<a href=\"\(base)?state=notenspiegelStudent&amp;next=tree.vm&amp;asi=\(asi)\">Notenspiegel</a></body></html>"
        var n = 0
        let t = FakeUniTransport { r in
            if r.url.absoluteString == QISClient.startURL.absoluteString { return ok(start) }
            n += 1
            return ok(#"<html><body>\#(logout)<a href="\#(base)?state=notenspiegelStudent&amp;next=tree.vm&amp;nodeID=auswahlBaum|abschluss:abschl=\#(n)&amp;expand=0&amp;asi=\#(asi)">Abschluss \#(n)</a></body></html>"#)
        }
        let r = try await QISClient(transport: t, retry: noWait).fetch()
        XCTAssertEqual(r.pages, 1 + QISClient.stallLimit)
        XCTAssertFalse(r.complete, "abgebrochen: ersetzt den gespeicherten Notenspiegel nicht")
    }

    /// Info über angemeldete Prüfungen: echte Spalten, Prüfungsdatum mit Uhrzeit
    func testRegistrationsRealColumnsWithTime() {
        let r = RegistrationRows.parse(rows: [
            ["PrfNr.", "Prüfungsbezeichnung", "Prüfer/in", "Semester (Termin)", "Anmeldedatum *)", "Rücktritt über QIS möglich bis", "Prüfungsdatum"],
            ["1110", "Technische Mechanik II", "Muster", "SoSe 27 (01)", "10.05.2027", "13.08.2027", "20.08.2027 10:00"]])
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual([r.first?.pruefungsnr, r.first?.pruefer, r.first?.isoDate, r.first?.clock, r.first?.isoWithdraw],
                       ["1110", "Muster", "2027-08-20", "10:00", "2027-08-13"])
        XCTAssertEqual(r.first?.registered, true)
    }
}
