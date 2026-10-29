import Foundation
import XCTest
@testable import UniFlowCore

/// Notenspiegel des LSF Hildesheim wie qis.parse_grade_rows / test_grade_rows_hildesheim_layout (eine Fassung: `GradeRows`).
/// Erfundene Seite (Rechner lsf.test, Person "Erika Beispiel"); Stammdaten duerfen nirgends auftauchen.
final class QISHildesheimTests: XCTestCase {

    /// dieselben Zeilen wie test_grade_rows_hildesheim_layout (Werte erfunden)
    private let rows: [[String]] = [
        ["Abschluss: [82] Bachelor Studiengang: [052] B.A. Testfach PO-Version: 2022 Prüfungsordnung Studienordnung"],
        ["Prüfungsnr.", "Bezeichnung der Leistung / der Lehrveranstaltung", "Note", "Status", "Bonus"],
        ["5010", "Modul 1: Einführung", "", "", "12"],
        ["5011", "TM 1: Grundlagen /\n0424 Einführung", "1,7", "bestanden", "6"],
        ["5013", "TM 3: Prozesse / 0503 Methodik", "", "bestanden", "3"],
        ["5032", "TM 2: Kindheit / 0410 Kindheit", "", "angemeldet (SoSe 26)", "0"],
        ["8000", "Gesamtkonto studienbegleitender Prüfungen", "", "", "44,5"],
        ["Abschluss: [82] Bachelor Studiengang: [021] Begleitfach PO-Version: 2022"],
        ["Prüfungsnr.", "Bezeichnung der Leistung / der Lehrveranstaltung", "Note", "Status", "Bonus"],
        ["10010", "Pflichtmodule (mindestens 12 LP)", "", "Prüfung vorhanden", "6"],
        ["4220", "Grundlagen I / 3200 Grundlagen 1", "2,3", "bestanden", "6"],
    ]

    private func check(_ g: [QISGrade], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(g.map { [$0.pruefungsnr, $0.note, $0.status, $0.credits] }, [
            ["5011", "1,7", "bestanden", "6"], ["5013", "", "bestanden", "3"], ["5032", "", "angemeldet (SoSe 26)", "0"],
            ["4220", "2,3", "bestanden", "6"],
        ], file: file, line: line)
        XCTAssertEqual(g.first?.text, "TM 1: Grundlagen / 0424 Einführung", file: file, line: line)
        XCTAssertEqual(g.first?.abschluss, "Abschluss: [82] Bachelor Studiengang: [052] B.A. Testfach PO-Version: 2022", file: file, line: line)
        XCTAssertTrue(g.last?.abschluss?.hasSuffix("[021] Begleitfach PO-Version: 2022") ?? false, file: file, line: line)
    }

    func testRowsLikePython() {
        let g = GradeRows.parse(rows: rows, abschluss: "Fallback")
        check(g)
        XCTAssertEqual(g[0].raw, "5011 | TM 1: Grundlagen / 0424 Einführung | 1,7 | bestanden | 6")
    }

    func testFallbackAbschlussAndHeaderAnywhere() {
        let g = GradeRows.parse(rows: [["Hinweis", "x", "y"], ["Prüfungsnr.", "Bezeichnung", "Note", "Status"], ["1", "A", "1,0", "bestanden"]],
                                         abschluss: "Fallback")
        XCTAssertEqual(g.map(\.abschluss), ["Fallback"])
        XCTAssertTrue(GradeRows.parse(rows: [["1", "A", "1,0", "bestanden"]]).isEmpty, "ohne Kopfzeile keine Leistungen")
        // NFD-Kopfzeile wird erkannt
        let nfd = GradeRows.parse(rows: [["Pru\u{0308}fungsnr.", "Bezeichnung", "Note", "Status"], ["2", "B", "2,0", ""]])
        XCTAssertEqual(nfd.first?.pruefungsnr, "2")
    }

    /// Dieselbe Tabelle als HTML wie im LSF: eine Tabelle, th-Kopfzeilen, Abschluss-Zeile mit colspan, br im Text,
    /// davor die Stammdaten der Person.
    private let html = """
    <html><head><title>Notenspiegel</title></head><body>
    <h1>Studien-/Prüfungsleistungen (Notenspiegel)</h1>
    <table summary="Stammdaten"><tr><th>Name</th><td>Erika Beispiel</td></tr>
    <tr><th>Geburtsdatum</th><td>02.02.2002</td></tr><tr><th>Matrikelnummer</th><td>7654321</td></tr>
    <tr><th>Anschrift</th><td>Beispielweg 1, 31141 Hildesheim</td></tr></table>
    <table>
    <tr><td colspan="5" class="qis_konto">Abschluss: [82] Bachelor Studiengang: [052] B.A. Testfach PO-Version: 2022 Prüfungsordnung Studienordnung</td></tr>
    <tr><th class="tabelleheader">Prüfungsnr.</th><th>Bezeichnung der Leistung / der Lehrveranstaltung</th><th>Note</th><th>Status</th><th>Bonus</th></tr>
    <tr><td>5010</td><td><b>Modul 1: Einführung</b></td><td></td><td></td><td>12</td></tr>
    <tr><td>5011</td><td>TM 1: Grundlagen /<br>0424 Einf&uuml;hrung</td><td>1,7</td><td>bestanden</td><td>6</td></tr>
    <tr><td>5013</td><td>TM 3: Prozesse / 0503 Methodik</td><td>&nbsp;</td><td>bestanden</td><td>3</td></tr>
    <tr><td>5032</td><td>TM 2: Kindheit / 0410 Kindheit</td><td></td><td>angemeldet (SoSe 26)</td><td>0</td></tr>
    <tr><td>8000</td><td>Gesamtkonto studienbegleitender Prüfungen</td><td></td><td></td><td>44,5</td></tr>
    <tr><td colspan="5">Abschluss: [82] Bachelor Studiengang: [021] Begleitfach PO-Version: 2022</td></tr>
    <tr><th>Prüfungsnr.</th><th>Bezeichnung der Leistung / der Lehrveranstaltung</th><th>Note</th><th>Status</th><th>Bonus</th></tr>
    <tr><td>10010</td><td>Pflichtmodule (mindestens 12 LP)</td><td></td><td>Prüfung vorhanden</td><td>6</td></tr>
    <tr><td>4220</td><td>Grundlagen I / 3200 Grundlagen 1</td><td>2,3</td><td>bestanden</td><td>6</td></tr>
    </table></body></html>
    """

    /// LSF mit festen Antworten (kein Netz): Startseite mit Link zum Notenspiegel, dann die Seite `page`; beide mit
    /// "Abmelden" (angemeldet)
    private func lsf(_ page: String) -> FakeUniTransport {
        let t = FakeUniTransport()
        let signedIn = #"<a href="rds?state=user&amp;type=4">Abmelden</a>"#
        t.on(LSFClient.startURL, ok(signedIn + #"<a href="rds?state=notenspiegelStudent&amp;nodeID=a">Studien-/Prüfungsleistungen (Notenspiegel)</a>"#))
        t.on("\(HildesheimCAS.lsfBase)/qisserver/rds?state=notenspiegelStudent", ok(page.replacingOccurrences(of: "<body>", with: "<body>" + signedIn)))
        return t
    }

    /// Der eine Weg fuer den Hildesheimer Notenspiegel: `LSFClient.grades` (Tabellen, Stammdaten-Schutz, GradeRows)
    func testHildesheimPageAndNoStammdaten() async throws {
        let g = try await LSFClient(transport: lsf(html), retry: .none).grades()
        check(g)
        let json = QISParser.apiJSON(grades: g).jsonString()
        for secret in ["Erika", "Beispiel", "02.02.2002", "7654321", "Beispielweg", "31141", "Matrikel", "Geburtsdatum"] {
            XCTAssertFalse(json.contains(secret), secret)
            XCTAssertFalse(g.contains { $0.raw.contains(secret) || $0.text.contains(secret) }, secret)
        }
        XCTAssertEqual(QISParser.summary(g).passed, 3)
    }

    func testHildesheimReadsNoDocumentsLikePC() async throws {
        // qis.PROFILES["hildesheim"]["documents"] = False: keine Bescheinigungen/Transcripts, auch wenn die LSF-Seite
        // verpublish-Links hat (jeder Aufruf erzeugt ein Dokument); das QIS der LUH sammelt sie weiter
        let withLink = html.replacingOccurrences(of: "<h1>", with: #"<p><a href="rds?state=verpublish&amp;status=transform&amp;moduleCall=Studienbescheinigung&amp;publishConfFile=reports&amp;asi=SESSION.42">Studienbescheinigung</a></p><h1>"#)
        let t = lsf(withLink)
        check(try await LSFClient(transport: t, retry: .none).grades())
        XCTAssertFalse(t.requests.contains { $0.url.absoluteString.contains("verpublish") }, "keine Bescheinigung aufgerufen")
        let p = QISPage.parse(html: withLink, url: URL(string: "https://lsf.test/qisserver/rds?state=notenspiegelStudent&next=list.vm")!)
        XCTAssertEqual(p.documents.count, 1, "Seite enthaelt einen Bescheinigungs-Link")
        var luh = QISCollector()
        luh.absorb(p)
        XCTAssertEqual(luh.documents.count, 1, "LUH unveraendert")
        XCTAssertFalse(UniversityProfile.hildesheim.qisDocuments)
        XCTAssertTrue(UniversityProfile.luh.qisDocuments)
        XCTAssertEqual(UniversityProfile.hildesheim.gradeLayout, .hildesheim)
    }

    func testTableWithStammdatenRowIsNeverRead() async throws {
        // Steht eine Stammdaten-Zeile in der Leistungstabelle, verwirft LSFClient.grades die ganze Tabelle
        // (QISParser.isStammdaten, sicherer Weg; dann bleibt der Notenspiegel leer statt Stammdaten zu lesen)
        let mixed = html.replacingOccurrences(of: "</table></body>", with: "<tr><td>Matrikelnummer</td><td>7654321</td><td>1,0</td><td>x</td><td></td></tr></table></body>")
        let fromPage = try await LSFClient(transport: lsf(mixed), retry: .none).grades()
        XCTAssertTrue(fromPage.isEmpty)
        // direkt ausgewertete Zeilen: die Stammdaten-Zeile wird uebersprungen
        let g = GradeRows.parse(rows: rows + [["Matrikelnummer", "7654321", "1,0", "bestanden", ""]])
        XCTAssertFalse(g.contains { $0.raw.contains("7654321") })
        XCTAssertEqual(g.count, 4)
    }

    func testLuhLayoutUnchanged() {
        // LUH-Aufbau wie test_grade_rows_luh_layout_still_works
        let luh = """
        <table><tr><th>Prüfungsnr</th><th>Prüfungstext</th><th>Semester</th><th>Note</th><th>Status</th><th>Credits</th><th>Versuch</th></tr>
        <tr><td>1001</td><td>Mathematik I</td><td>WiSe 26/27</td><td>2,0</td><td>bestanden</td><td>8</td><td>1</td></tr>
        <tr><td>1002</td><td>Nur Text ohne Note</td><td>WiSe 26/27</td><td></td><td></td><td></td><td>1</td></tr></table>
        """
        let p = QISPage.parse(html: luh, url: URL(string: "https://qis.test/qisserver/rds?state=notenspiegelStudent")!)
        let old = p.grades(abschluss: "Abschluss 82 Bachelor of Science")
        // eine Fassung von qis.parse_grade_rows (GradeRows) auch fuer das QIS der LUH: eine Zeile ohne Note und Status ist
        // keine Leistung (vorher eigene LUH-Regel, die sie behielt)
        XCTAssertEqual(old.map(\.text), ["Mathematik I"])
        XCTAssertEqual(old[0].semester, "WiSe 26/27")
        XCTAssertEqual(old[0].credits, "8")
        XCTAssertEqual(old[0].versuch, "1")
        XCTAssertEqual(old[0].abschluss, "Abschluss 82 Bachelor of Science")
        XCTAssertEqual(p.gradeTableCount, 1)
        var c = QISCollector()
        c.absorb(p)
        XCTAssertEqual(c.grades, p.grades(), "QISCollector ist der Weg der LUH")
        // dieselbe Tabelle als Zellen direkt an GradeRows: gleiches Ergebnis
        let cells = [["Prüfungsnr", "Prüfungstext", "Semester", "Note", "Status", "Credits", "Versuch"],
                     ["1001", "Mathematik I", "WiSe 26/27", "2,0", "bestanden", "8", "1"],
                     ["1002", "Nur Text ohne Note", "WiSe 26/27", "", "", "", "1"]]
        XCTAssertEqual(GradeRows.parse(rows: cells, abschluss: "Abschluss 82 Bachelor of Science").map(\.text), ["Mathematik I"])
    }

    /// GET /api/grades wie qis.summary mit app/grades_model.py (seit 28.10.2026): Module (keine Art, kein Versuch), neueste
    /// Semester zuerst, darin nach Text (Codepunkte), ohne Semester zuletzt; Schnitt der bestandenen benoteten Module nach
    /// LP, abgeschnitten (die 5,0 zaehlt nicht mehr); letzter Abruf. Erwartete Werte aus grades_model.summary mit
    /// denselben erfundenen Zeilen: average 1.9, average_exact 1.94, credits 10.0, passed 3. Der ganze Vertrag:
    /// GradesModelTests (grades.json).
    func testGradesEndpointMatchesQISSummary() async throws {
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: .fixed(Date(timeIntervalSince1970: 1_792_900_000)))
        let empty = await backend.handle(LocalRequest(method: "GET", path: "/api/grades"))
        XCTAssertEqual(empty.json, ["grades": [], "average": .null, "average_exact": .null, "graded_count": 0, "graded_credits": 0,
                                    "credits": 0, "passed": 0, "basis": "leistungen", "bereiche": [], "failed_attempts": 0,
                                    "last_run": .null, "documents": []])
        XCTAssertEqual(backend.route(method: "GET", path: "/api/grades")?.placeholder, false)
        let grades = [QISGrade(pruefungsnr: "5011", text: "TM 1: Grundlagen", semester: "WiSe 25/26", note: "1,7", status: "bestanden", credits: "6"),
                      QISGrade(pruefungsnr: "5020", text: "Statistik", semester: "SoSe 26", note: "2,3", status: "bestanden", credits: "4"),
                      QISGrade(pruefungsnr: "5032", text: "TM 2: Kindheit", status: "angemeldet (SoSe 26)", credits: "0"),
                      QISGrade(pruefungsnr: "5040", text: "Ästhetik", semester: "SoSe 26", note: "5,0", status: "nicht bestanden", credits: "5"),
                      QISGrade(pruefungsnr: "5050", text: "Zusatz", semester: "SoSe 26", note: "1,0", status: "bestanden")]
        try await backend.context.database.transaction { c in
            try UniStore.storeGrades(c, grades, now: "2026-10-26T10:00:00")
            try c.execute("INSERT INTO qis_runs(started_at, finished_at, ok, message, grades, documents) VALUES ('a','b',1,'4 Leistungen',4,0)")
        }
        let filled = await backend.handle(LocalRequest(method: "GET", path: "/api/grades"))
        let r = try XCTUnwrap(filled.json)
        XCTAssertEqual(r["grades"]?.array?.compactMap { $0["text"]?.string }, ["Statistik", "Zusatz", "Ästhetik", "TM 1: Grundlagen", "TM 2: Kindheit"])
        XCTAssertEqual(r["average"], 1.9)
        XCTAssertEqual(r["average_exact"], 1.94)
        XCTAssertEqual(r["credits"], 10)
        XCTAssertEqual(r["basis"], "module")
        XCTAssertEqual(r["passed"], 3)
        XCTAssertEqual(r["last_run"]?["message"], "4 Leistungen")
        XCTAssertEqual(r["last_run"]?["ok"], 1)
        XCTAssertEqual(r["documents"], [])
        XCTAssertEqual(r["grades"]?.array?.first?["fetched_at"], "2026-10-26T10:00:00")
        XCTAssertEqual(r["grades"]?.array?.first?["level"], "modul")

        // erneuter Abruf (Hildesheim: ohne Semester und Versuch, NULL in der UNIQUE-Spalte): aktualisiert statt doppelt
        var again = grades
        again[2].note = "2,0"
        again[2].status = "bestanden"
        let updated = again
        try await backend.context.database.transaction { try UniStore.storeGrades($0, updated, now: "2026-10-27T10:00:00") }
        let rows = try await backend.context.database.rows("SELECT text, note, fetched_at FROM grades ORDER BY id")
        XCTAssertEqual(rows.count, 5, "keine doppelten Leistungen")
        XCTAssertEqual(rows[2]["note"]?.string, "2,0")
        XCTAssertEqual(rows[2]["fetched_at"]?.string, "2026-10-27T10:00:00")
    }
}
