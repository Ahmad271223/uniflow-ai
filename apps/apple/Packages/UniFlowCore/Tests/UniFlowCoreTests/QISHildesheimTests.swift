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

    func testHildesheimPageAndNoStammdaten() {
        let p = QISPage.parse(html: html, url: URL(string: "https://lsf.test/qisserver/rds?state=notenspiegelStudent&next=list.vm")!)
        XCTAssertEqual(p.gradeTableCount(layout: .hildesheim), 1)
        let g = p.grades(abschluss: "Fallback", layout: .hildesheim)
        check(g)
        let json = QISParser.apiJSON(grades: g).jsonString()
        for secret in ["Erika", "Beispiel", "02.02.2002", "7654321", "Beispielweg", "31141", "Matrikel", "Geburtsdatum"] {
            XCTAssertFalse(json.contains(secret), secret)
            XCTAssertFalse(g.contains { $0.raw.contains(secret) || $0.text.contains(secret) }, secret)
        }
        XCTAssertEqual(QISParser.summary(g).passed, 3)

        var collector = QISCollector()
        collector.absorb(p, via: nil, layout: .hildesheim)
        check(collector.grades)
    }

    func testHildesheimCollectsNoDocumentsLikePC() throws {
        // qis.PROFILES["hildesheim"]["documents"] = False: keine Bescheinigungen/Transcripts, auch wenn die LSF-Seite
        // verpublish-Links hat; die LUH sammelt sie weiter
        let withLink = html.replacingOccurrences(of: "<h1>", with: #"<p><a href="rds?state=verpublish&amp;status=transform&amp;moduleCall=Studienbescheinigung&amp;publishConfFile=reports&amp;asi=SESSION.42">Studienbescheinigung</a></p><h1>"#)
        let p = QISPage.parse(html: withLink, url: URL(string: "https://lsf.test/qisserver/rds?state=notenspiegelStudent&next=list.vm")!)
        XCTAssertEqual(p.documents.count, 1, "Seite enthaelt einen Bescheinigungs-Link")
        var hi = QISCollector()
        hi.absorb(p, layout: .hildesheim)
        check(hi.grades)
        XCTAssertTrue(hi.documents.isEmpty, "Hildesheim: keine Bescheinigungs-Links")
        XCTAssertEqual(hi.apiJSON()["documents"]?.array?.count, 0)
        var luh = QISCollector()
        luh.absorb(p)
        XCTAssertEqual(luh.documents.count, 1, "LUH unveraendert")
        XCTAssertFalse(UniversityProfile.hildesheim.qisDocuments)
        XCTAssertTrue(UniversityProfile.luh.qisDocuments)
        XCTAssertEqual(UniversityProfile.hildesheim.gradeLayout.collectsDocuments, UniversityProfile.hildesheim.qisDocuments)
    }

    func testTableWithStammdatenRowIsNeverRead() {
        // Steht eine Stammdaten-Zeile in der Leistungstabelle, verwirft schon QISPage.parse die ganze Tabelle
        // (sicherer Weg; dann bleibt der Notenspiegel leer statt Stammdaten zu lesen)
        let mixed = html.replacingOccurrences(of: "</table></body>", with: "<tr><td>Matrikelnummer</td><td>7654321</td><td>1,0</td><td>x</td><td></td></tr></table></body>")
        let p = QISPage.parse(html: mixed, url: URL(string: "https://lsf.test/qisserver/rds?state=notenspiegelStudent")!)
        XCTAssertTrue(p.grades(layout: .hildesheim).isEmpty)
        XCTAssertEqual(p.gradeTableCount(layout: .hildesheim), 0)
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
        XCTAssertEqual(p.grades(abschluss: "Abschluss 82 Bachelor of Science", layout: .luh), old)
        XCTAssertEqual(old.map(\.text), ["Mathematik I", "Nur Text ohne Note"], "LUH-Regeln wie bisher (Zeilen ohne Note bleiben)")
        XCTAssertEqual(old[0].semester, "WiSe 26/27")
        XCTAssertEqual(old[0].credits, "8")
        XCTAssertEqual(old[0].versuch, "1")
        XCTAssertEqual(old[0].abschluss, "Abschluss 82 Bachelor of Science")
        XCTAssertEqual(p.gradeTableCount(layout: .luh), p.gradeTableCount)
        var c = QISCollector()
        c.absorb(p)
        XCTAssertEqual(c.grades, p.grades(), "Standard bleibt LUH")
        // Python-Regeln fuer dieselbe Tabelle (Hildesheim): Zeile ohne Note und Status ist keine Leistung
        XCTAssertEqual(p.grades(abschluss: "Abschluss 82 Bachelor of Science", layout: .hildesheim).map(\.text), ["Mathematik I"])
    }
}
