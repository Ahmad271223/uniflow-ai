import Foundation
import XCTest
@testable import UniFlowCore

// Erfundene QIS-Seiten nach dem Aufbau in docs/QIS-STUDIP-STRUKTUR.md (Rechner qis.test, Person "Max Muster").
// Absichtlich unsauberes HTML: offene td/tr, Gross-/Kleinschreibung gemischt, Entities, Layout-Tabellen.

private let servlet = "https://qis.test/qisserver/servlet/de.his.servlet.RequestDispatcherServlet"

private func page(_ html: String, _ query: String = "state=user&type=0&asi=SESSION.42") -> QISPage {
    QISPage.parse(html: html, url: URL(string: "\(servlet)?\(query)")!)
}

private let startHTML = """
<!DOCTYPE html><html><head><title>QIS Startseite</title>
<script>var x = "<a href='javascript:evil()'>Mein Studium</a>";</script></head>
<body><table class="layout"><tr><td>
<!-- Menue <a href="/kommentar">Mein Studium</a> -->
<ul class="menu">
 <li><a href="/qisserver/servlet/de.his.servlet.RequestDispatcherServlet?state=change&amp;type=1&amp;moduleParameter=studentDataMenu&amp;next=menu.vm&amp;asi=SESSION.42">Meine Benutzerdaten</a>
 <li><A HREF="rds?state=change&amp;type=1&amp;moduleParameter=studyPOSMenu&amp;next=menu.vm&amp;asi=SESSION.42" class=auflistung>Mein
     Studium</A>
 <li><a href='/qisserver/servlet/de.his.servlet.RequestDispatcherServlet?state=change&amp;type=1&amp;moduleParameter=studentReportsMenu&amp;next=menu.vm&amp;subdir=qissos/reports&amp;asi=SESSION.42'>Meine&nbsp;Bescheinigungen</a>
 <li><a href="https://qis.test/qisserver/servlet/de.his.servlet.RequestDispatcherServlet?state=user&amp;type=4&amp;re=last&amp;menuid=logout&amp;category=auth.logout&amp;asi=SESSION.42">Logout</a>
 <li><a href="https://andere.test/seite?asi=FREMD.1">Fremde Seite</a>
 <li><a href="javascript:void(0)">Drucken</a><li><a href="#oben">nach oben</a>
</ul></td></tr></table></body></html>
"""

private let meinStudiumHTML = """
<html><body><h1>Mein Studium</h1>
<a href="rds?state=change&amp;type=1&amp;moduleParameter=studyPOSMenu&amp;next=menu.vm&amp;asi=SESSION.42">Mein Studium</a>
<a href="rds?state=wimma&amp;stg=pruefungsanmeldung&amp;asi=SESSION.42">Pr&uuml;fungsanmeldung/-abmeldung</a>
<a href="rds?state=wimma&amp;stg=info&amp;asi=SESSION.42">Info &uuml;ber angemeldete Pr&uuml;fungen</a>
<a href="rds?state=notenspiegelStudent&amp;next=tree.vm&amp;nextdir=qispos/notenspiegel/student&amp;menuid=notenspiegelStudent&amp;breadcrumb=notenspiegel&amp;asi=SESSION.42">Notenspiegel / Studienverlauf</a>
<a href="rds?state=wplan&amp;act=show&amp;asi=SESSION.42">Mein Stundenplan</a>
<a href="rds?state=user&amp;type=4&amp;asi=SESSION.42">Abmelden</a>
</body></html>
"""

private let treeHTML = """
<html><body><h1>Notenspiegel</h1>
<form action="rds?state=notenspiegelStudent&amp;asi=SESSION.42" method="post"><input type="hidden" name="asi" value="SESSION.42"></form>
<ul class="treelist">
 <li><a href="rds?state=notenspiegelStudent&amp;next=tree.vm&amp;nextdir=qispos/notenspiegel/student&amp;struct=auswahlBaum&amp;nodeID=auswahlBaum|abschluss:abschl=82&amp;expand=0&amp;asi=SESSION.42#auswahlBaum|abschluss:abschl=82" title="Ausklappen">Abschluss 82 Bachelor of Science</a>
  <ul><li><a href="rds?state=notenspiegelStudent&amp;next=list.vm&amp;nextdir=qispos/notenspiegel/student&amp;createInfos=Y&amp;struct=auswahlBaum&amp;nodeID=auswahlBaum%7Cabschluss%3Aabschl%3D82%2Cstgnr%3D1%7Cstudiengang%3Astg%3DX12%2Cpversion%3D2017%2Ckzfa%3DH&amp;expand=0&amp;asi=SESSION.42"><img src="/QIS/images//information.svg" alt="Leistungen f&uuml;r Musterfach (PO-Version 2017) anzeigen" title="Leistungen f&uuml;r Musterfach (PO-Version 2017) anzeigen"></a>
      <a href="rds?state=notenspiegelStudent&amp;next=list.vm&amp;nextdir=qispos/notenspiegel/student&amp;createInfos=Y&amp;struct=auswahlBaum&amp;nodeID=auswahlBaum%7Cabschluss%3Aabschl%3D82%2Cstgnr%3D1%7Cstudiengang%3Astg%3DX12%2Cpversion%3D2017%2Ckzfa%3DH&amp;expand=0&amp;asi=SESSION.42">Leistungen f&uuml;r Musterfach (PO-Version 2017) anzeigen</a>
  </ul>
</ul>
<a href="rds?state=user&amp;type=4&amp;asi=SESSION.42">Logout</a>
</body></html>
"""

/// Stammdaten wie im echten QIS (th.mod_header + td.mod_n_basic), aber erfunden.
private let stammdaten = """
<table summary="Liste der Stammdaten des Studierenden" border="0">
 <tr><th class="mod_header" colspan="4">Stammdaten</th></tr>
 <tr><th class="mod_header">Name des Studierenden</th><td class="mod_n_basic">Max Muster
     <th class="mod_header">Geburtsdatum und -ort</th><td class="mod_n_basic">01.01.2000 in Musterstadt</td></tr>
 <tr><th class="mod_header">Abschluss</th><td class="mod_n_basic">[82] Bachelor of Science
     <th class="mod_header">Matrikelnummer</th><td class="mod_n_basic">1234567</tr>
 <tr><th class="mod_header">Pr&uuml;fungstext</th><td class="mod_n_basic">Note</td>
     <th class="mod_header">Anschrift</th><td class="mod_n_basic">Musterweg 1, 12345 Musterstadt</td></tr>
</table>
"""

private let leistungenHTML = """
<html><body><h1>Notenspiegel</h1>
<table class="layout"><tr><td>
\(stammdaten)
</td></tr><tr><td>
<table border="0" align="left" width="100%">
 <tr><th class="tabelleheader" colspan="9">Leistungen</th></tr>
 <tr>
  <th class="tabelleheader">Pr&uuml;fungsnr.</th><th class="tabelleheader">Pr&uuml;fungstext</th>
  <th class="tabelleheader">Semester</th><th class="tabelleheader">Note</th><th class="tabelleheader">Status</th>
  <th class="tabelleheader">Credits</th><th class="tabelleheader">Vermerk</th><th class="tabelleheader">Versuch</th>
  <th class="tabelleheader">Pr&uuml;fungsdatum</th>
 </tr>
 <tr><td class="qis_konto" colspan="9">Grundlagenmodule</td></tr>
 <tr><td class="tabelle1_alignleft">1001<td class="tabelle1_alignleft">Mathematik&nbsp;I
     <td>WiSe 25/26<td class="tabelle1_alignright"> 1,3 <td>bestanden<td>6,0<td><td>1<td>15.02.2026
 <tr><td>1002</td><td>Programmieren &amp; Algorithmen</td><td>SoSe 26</td><td>2,0</td><td>bestanden</td><td>10</td><td></td><td>1</td><td>20.07.2026</td></tr>
 <tr><td>1003</td><td>Physik f&#252;r&#x20;Ingenieure</td><td>SoSe 26</td><td>5,0</td><td>nicht bestanden</td><td>4</td><td></td><td>1</td><td>22.07.2026</td></tr>
 <tr><td>1004</td><td>Schl&uuml;sselkompetenzen</td><td>SoSe 26</td><td></td><td>BE</td><td>3</td><td></td><td>1</td><td></td></tr>
 <tr><td>1003</td><td>Physik f&uuml;r Ingenieure</td><td>SoSe 26</td><td>5,0</td><td>nicht bestanden</td><td>4</td><td></td><td>1</td><td>22.07.2026</td></tr>
</table>
<a href="rds?state=notenspiegelStudent&amp;next=list.vm&amp;pdf=Y&amp;asi=SESSION.42">PDF-Notenspiegel zum Drucken</a>
</td></tr></table>
<a href="rds?state=user&amp;type=4&amp;asi=SESSION.42">Logout</a>
</body></html>
"""

private let keineLeistungenHTML = """
<html><body><h1>Notenspiegel</h1>
\(stammdaten)
<p>Es liegen keine Leistungen vor.</p>
<a href="rds?state=user&amp;type=4&amp;asi=SESSION.42">Logout</a>
</body></html>
"""

private let bescheinigungenHTML = """
<html><body><h1>Meine Bescheinigungen</h1>
<table><tr><td>Studienzeitbescheinigung / Immatrikulationsbescheinigung / Bescheinigung nach &sect; 9 BAf&ouml;G
  <td><a href="rds?state=verpublish&amp;status=transform&amp;vmfile=no&amp;moduleCall=Studienbescheinigung&amp;publishConfFile=reports&amp;publishSubDir=qissos&amp;asi=SESSION.42" target="_blank"><img src="/QIS/images//pdf.svg" alt="PDF"></a>
<tr><td><a href="rds?state=verpublish&amp;status=transform&amp;moduleCall=StudienbescheinigungEN&amp;publishConfFile=reports&amp;asi=SESSION.42">PDF-Certificate of study period and enrolment anzeigen</a>
<tr><td><a href="rds?state=verpublish&amp;status=transform&amp;moduleCall=StudienbescheinigungEN&amp;publishConfFile=reports&amp;asi=SESSION.42">PDF</a>
<tr><td><a href="rds?state=verify&amp;asi=SESSION.42">Bescheinigungen sind verifizierbar</a>
</table>
<a href="rds?state=user&amp;type=4&amp;asi=SESSION.42">Logout</a>
</body></html>
"""

/// Baum mit zwei Abschluessen (Bachelor und Master im selben Konto). Aufgeklappte Knoten zeigen ihren Studiengang,
/// ihr eigener Link klappt dann mit expand=1 wieder zu (andere Adresse als beim Aufklappen).
private func twoAbschlussTree(expanded: Set<Int>, numbers: (Int, Int) = (82, 88)) -> String {
    let nodes = [(numbers.0, "Bachelor of Science", "Bachelorfach"), (numbers.1, "Master of Science", "Masterfach")]
    var html = "<html><body><h1>Notenspiegel</h1><ul class=\"treelist\">"
    for (nr, name, fach) in nodes {
        let open = expanded.contains(nr)
        html += """
        <li><a href="rds?state=notenspiegelStudent&amp;next=tree.vm&amp;nextdir=qispos/notenspiegel/student&amp;struct=auswahlBaum&amp;nodeID=auswahlBaum|abschluss:abschl=\(nr)&amp;expand=\(open ? 1 : 0)&amp;asi=SESSION.42#auswahlBaum|abschluss:abschl=\(nr)" title="\(open ? "Zuklappen" : "Ausklappen")">Abschluss \(nr) \(name)</a>
        """
        if open {
            html += """
            <ul><li><a href="rds?state=notenspiegelStudent&amp;next=list.vm&amp;nextdir=qispos/notenspiegel/student&amp;createInfos=Y&amp;struct=auswahlBaum&amp;nodeID=auswahlBaum%7Cabschluss%3Aabschl%3D\(nr)%2Cstgnr%3D1%7Cstudiengang%3Astg%3DX\(nr)%2Cpversion%3D2017%2Ckzfa%3DH&amp;expand=0&amp;asi=SESSION.42">Leistungen f&uuml;r \(fach) (PO-Version 2017) anzeigen</a></ul>
            """
        }
    }
    return html + "</ul><a href=\"rds?state=user&amp;type=4&amp;asi=SESSION.42\">Logout</a></body></html>"
}

private func gradeListHTML(_ nr: String, _ text: String) -> String {
    """
    <html><body><table><tr><th>Pr&uuml;fungsnr.</th><th>Pr&uuml;fungstext</th><th>Semester</th><th>Note</th><th>Status</th><th>Credits</th></tr>
    <tr><td>\(nr)</td><td>\(text)</td><td>SoSe 26</td><td>1,7</td><td>bestanden</td><td>5</td></tr></table>
    <a href="rds?state=user&amp;type=4&amp;asi=SESSION.42">Logout</a></body></html>
    """
}

final class QISParserTests: XCTestCase {

    // MARK: Links und Sitzung

    func testStartPageLinksAreAbsoluteAndWithoutSession() throws {
        let p = page(startHTML)
        XCTAssertEqual(p.title, "QIS Startseite")
        XCTAssertTrue(p.isLoggedIn)
        XCTAssertFalse(p.hasLoginForm)
        let studium = try XCTUnwrap(p.link(.meinStudium))
        XCTAssertEqual(studium.text, "Mein Studium")
        XCTAssertEqual(studium.address, "https://qis.test/qisserver/servlet/rds?state=change&type=1&moduleParameter=studyPOSMenu&next=menu.vm")
        XCTAssertEqual(studium.parameters["moduleparameter"], "studyPOSMenu")
        XCTAssertEqual(p.link(.bescheinigungen)?.text, "Meine Bescheinigungen")
        XCTAssertEqual(p.link(.logout)?.parameters["menuid"], "logout")
        XCTAssertNil(p.link(.notenspiegel))
        // Kommentar, Skript, javascript: und Anker werden nicht als Links gelesen
        XCTAssertFalse(p.links.contains { $0.address.contains("kommentar") || $0.address.contains("javascript") })
        XCTAssertFalse(p.links.contains { $0.text == "nach oben" || $0.text == "Drucken" })
        for l in p.links { XCTAssertFalse(l.address.lowercased().contains("asi="), l.address) }
        XCTAssertEqual(p.address, "\(servlet)?state=user&type=0")
    }

    func testSessionComesOnlyFromCurrentPageAndIsNeverExposed() throws {
        let p = page(startHTML)
        let session = try XCTUnwrap(p.session)
        XCTAssertEqual(session.token, "SESSION.42")                 // nicht das asi des fremden Rechners
        XCTAssertFalse(String(describing: session).contains("SESSION"))
        XCTAssertFalse(String(reflecting: session).contains("SESSION"))
        var dumped = ""
        dump(session, to: &dumped)
        XCTAssertFalse(dumped.contains("SESSION"))
        XCTAssertTrue(Mirror(reflecting: session).children.isEmpty)

        let studium = try XCTUnwrap(p.link(.meinStudium))
        XCTAssertEqual(p.url(for: studium)?.absoluteString, studium.address + "&asi=SESSION.42")
        // Fremder Rechner: nie mit asi
        let fremd = try XCTUnwrap(p.links.first { $0.text == "Fremde Seite" })
        XCTAssertEqual(p.url(for: fremd)?.absoluteString, "https://andere.test/seite")

        // Link einer anderen Seite bekommt das asi der aktuellen Seite
        let neu = page(meinStudiumHTML.replacingOccurrences(of: "SESSION.42", with: "NEU.7"), "state=user")
        XCTAssertEqual(neu.url(for: studium)?.absoluteString, studium.address + "&asi=NEU.7")
        // ohne asi auf der Seite: Adresse unveraendert
        let ohne = page(meinStudiumHTML.replacingOccurrences(of: "&amp;asi=SESSION.42", with: ""), "state=user")
        XCTAssertNil(ohne.session)
        XCTAssertEqual(ohne.url(for: studium)?.absoluteString, studium.address)
        // asi mit unzulaessigen Zeichen wird verworfen
        let boese = page(#"<a href="rds?state=x&amp;asi=a%26b%3Dc">x</a>"#, "state=user")
        XCTAssertNil(boese.session)

        // Gespeicherte Typen enthalten kein asi
        var c = QISCollector()
        c.absorb(p)
        let encoded = String(decoding: try JSONEncoder().encode(c), as: UTF8.self)
        XCTAssertFalse(encoded.contains("SESSION"))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(studium), as: UTF8.self).contains("asi"))
    }

    func testMeinStudiumFindsNotenspiegelAndIgnoresExamRegistration() throws {
        let p = page(meinStudiumHTML)
        XCTAssertEqual(p.title, "Mein Studium")
        let ns = try XCTUnwrap(p.link(.notenspiegel))
        XCTAssertEqual(ns.text, "Notenspiegel / Studienverlauf")
        XCTAssertEqual(ns.parameters["next"], "tree.vm")
        // "Pruefungsanmeldung/-abmeldung" ist weder Logout noch sonst ein Ziel
        XCTAssertEqual(p.links(.logout).map(\.text), ["Abmelden"])
        for t in QISTarget.allCases {
            XCTAssertFalse(p.links(t).contains { $0.text.contains("Prüfungsanmeldung") }, "\(t)")
        }
        XCTAssertEqual(p.nextLinksTowardGrades().map(\.text), ["Notenspiegel / Studienverlauf"])
    }

    func testTreeFindsAbschlussAndLeistungenLinks() throws {
        let p = page(treeHTML, "state=notenspiegelStudent&next=tree.vm&asi=SESSION.42")
        let abschluss = p.links(.abschluss)
        XCTAssertEqual(abschluss.map(\.text), ["Abschluss 82 Bachelor of Science"])
        XCTAssertEqual(abschluss[0].parameters["nodeid"], "auswahlBaum|abschluss:abschl=82")
        XCTAssertEqual(abschluss[0].parameters["expand"], "0")
        XCTAssertTrue(abschluss[0].address.contains("nodeID=auswahlBaum%7Cabschluss:abschl=82"))
        XCTAssertFalse(abschluss[0].address.contains("#"))
        XCTAssertNotNil(URL(string: abschluss[0].address))

        // Bild-Link (alt/title) und Text-Link zeigen auf dieselbe Adresse: nur einmal
        let leistungen = p.links(.leistungen)
        XCTAssertEqual(leistungen.count, 1)
        XCTAssertEqual(leistungen[0].studiengang, "Musterfach (PO-Version 2017)")
        XCTAssertEqual(leistungen[0].parameters["nodeid"], "auswahlBaum|abschluss:abschl=82,stgnr=1|studiengang:stg=X12,pversion=2017,kzfa=H")
        XCTAssertEqual(p.nextLinksTowardGrades(), leistungen)
        XCTAssertNil(p.link(.notenspiegel))                         // Baumknoten sind kein Notenspiegel-Einstieg
        XCTAssertEqual(p.session?.token, "SESSION.42")
    }

    func testLoginPageIsRecognized() {
        let p = page("""
        <html><body><form method="post" action="rds?state=user&amp;type=1&amp;category=auth.login">
        <input type="text" name="asdf" id="asdf"><input type="password" name="fdsa" id="fdsa">
        <input type="submit" value="Anmelden"></form></body></html>
        """, "state=user&type=0")
        XCTAssertTrue(p.hasLoginForm)
        XCTAssertFalse(p.isLoggedIn)
        XCTAssertNil(p.session)
        XCTAssertTrue(p.nextLinksTowardGrades().isEmpty)
    }

    // MARK: Leistungen

    func testGradeTableIsReadAndStammdatenAreSkipped() throws {
        let p = page(leistungenHTML, "state=notenspiegelStudent&next=list.vm&asi=SESSION.42")
        XCTAssertEqual(p.gradeTableCount, 1)
        let g = p.grades(abschluss: "Musterfach (PO-Version 2017)")
        XCTAssertEqual(g.map(\.text), ["Mathematik I", "Programmieren & Algorithmen", "Physik für Ingenieure", "Schlüsselkompetenzen"])
        let m = g[0]
        XCTAssertEqual(m.pruefungsnr, "1001")
        XCTAssertEqual(m.semester, "WiSe 25/26")
        XCTAssertEqual(m.note, "1,3")
        XCTAssertEqual(m.status, "bestanden")                       // "Vermerk" ist leer, Status zuerst
        XCTAssertEqual(m.credits, "6,0")
        XCTAssertEqual(m.versuch, "1")
        XCTAssertEqual(m.datum, "15.02.2026")
        XCTAssertEqual(m.abschluss, "Musterfach (PO-Version 2017)")
        XCTAssertEqual(m.raw, "1001 | Mathematik I | WiSe 25/26 | 1,3 | bestanden | 6,0 |  | 1 | 15.02.2026")
        XCTAssertEqual(g[3].note, "")

        // Keine Stammdaten, weder in den Leistungen noch im Ergebnis
        let json = QISParser.apiJSON(grades: g).jsonString()
        for secret in ["Muster ", "Max", "1234567", "Musterstadt", "Musterweg", "01.01.2000", "Geburtsdatum", "Matrikel"] {
            XCTAssertFalse(json.contains(secret), secret)
        }
        XCTAssertFalse(p.tables.contains { QISParser.isStammdaten($0) })
        XCTAssertFalse(p.tables.contains { $0.rows.joined().contains { $0.text.contains("Max Muster") } })
        // PDF-Notenspiegel ist kein Leistungen-Link und keine Bescheinigung (kein verpublish)
        XCTAssertTrue(p.links(.leistungen).isEmpty)
        XCTAssertTrue(p.links(.notenspiegel).isEmpty)
        XCTAssertTrue(p.documents.isEmpty)
    }

    func testNoGradesGivesEmptyList() {
        let p = page(keineLeistungenHTML, "state=notenspiegelStudent&next=list.vm&asi=SESSION.42")
        XCTAssertEqual(p.gradeTableCount, 0)
        XCTAssertTrue(p.grades().isEmpty)
        let json = QISParser.apiJSON(grades: p.grades())
        XCTAssertEqual(json["grades"], .array([]))
        XCTAssertEqual(json["average"], .null)
        XCTAssertEqual(json["credits"], 0)
        XCTAssertEqual(json["passed"], 0)
        XCTAssertEqual(json["documents"], .array([]))
        XCTAssertFalse(json.jsonString().contains("Muster"))
    }

    func testStammdatenWithoutSummaryAndFakeGradeHeaderAreSkipped() {
        let html = """
        <table><tr><th>Prüfungstext</th><th>Note</th><th>Semester</th></tr>
        <tr><td>Matrikelnummer</td><td>1234567</td><td>x</td></tr>
        <tr><td>Max Muster</td><td>1,0</td><td>WiSe</td></tr></table>
        <table summary="Liste der Stammdaten des Studierenden"><tr><th>Prüfungstext</th><th>Note</th><th>Semester</th></tr>
        <tr><td>Max Muster</td><td>1,0</td><td>WiSe</td></tr></table>
        """
        let p = page(html)
        XCTAssertEqual(p.gradeTableCount, 0)
        XCTAssertTrue(p.grades().isEmpty)
    }

    func testHeaderVariantsAndNestedTables() {
        let html = """
        <TABLE><TR><TD>
          <table><tr><td>Nr</td><td>Text</td><td>Note</td><td>ECTS</td><td>Status</td><td>Abschluss</td></tr>
          <tr><td>7</td><td>Seminar <b>Muster</b>arbeit</td><td>2,7</td><td>5</td><td>bestanden</td><td>Master</td></tr>
          <tr><td>Nr</td><td>Text</td><td>Note</td><td>ECTS</td><td>Status</td><td>Abschluss</td></tr>
          <tr><td>8</td><td></td><td>1,0</td><td>5</td><td>bestanden</td><td></td></tr>
          <tr><td>9</td><td>Kurz</td></tr>
          </table>
        </TD><TD>Layout ohne Kopfzeile</TD></TR></TABLE>
        """
        let g = page(html).grades(abschluss: "Baum")
        XCTAssertEqual(g.count, 1)
        XCTAssertEqual(g[0].text, "Seminar Musterarbeit")
        XCTAssertEqual(g[0].credits, "5")
        XCTAssertEqual(g[0].abschluss, "Master")                    // eigene Spalte vor dem Baum-Text
        XCTAssertNil(g[0].semester)
    }

    func testSummaryLikePython() {
        let g = page(leistungenHTML).grades()
        let s = QISParser.summary(g)
        // (1,3*6 + 2,0*10 + 5,0*4) / 20 = 2,39; Note 5,0 zaehlt wie in qis.summary(); "BE" ohne Note nicht
        XCTAssertEqual(s.average, 2.39)
        XCTAssertEqual(s.credits, 20)
        XCTAssertEqual(s.passed, 3)                                 // bestanden, bestanden, BE
        // ohne Credits: einfacher Mittelwert; unlesbare Credits lassen die Zeile aus
        let ohne = QISParser.summary([QISGrade(text: "A", note: "1,0"), QISGrade(text: "B", note: "2,0", credits: ""),
                                      QISGrade(text: "C", note: "3,0", credits: "viel"), QISGrade(text: "D", note: "6,0")])
        XCTAssertEqual(ohne.average, 1.5)
        XCTAssertEqual(ohne.credits, 0)
        XCTAssertNil(QISParser.summary([]).average)
        XCTAssertEqual(QISParser.summary([QISGrade(text: "X", note: "0x1p1", credits: "1")]).average, nil)
    }

    func testSummaryRoundsTheExactBinaryValueLikePython() {
        func avg(_ pairs: [(String, String)]) -> Double? {
            QISParser.summary(pairs.enumerated().map { QISGrade(text: "M\($0.offset)", note: $0.element.0, credits: $0.element.1) }).average
        }
        // Werte aus Python: round((1.0*3 + 1.3*1) / 4, 2) usw.; x*100 gerundet gaebe 1.08 / 1.42 / 1.98
        XCTAssertEqual(avg([("1,0", "3"), ("1,3", "1")]), 1.07)
        XCTAssertEqual(avg([("1,0", "3"), ("2,7", "1")]), 1.43)
        XCTAssertEqual(avg([("1,0", "1"), ("2,3", "3")]), 1.97)
        XCTAssertEqual(avg([("1,3", "6"), ("2,0", "10"), ("5,0", "4")]), 2.39)
        // Summen wie Pythons sum() (Neumaier): 87,2 / 32 = 2,725 -> 2,73; einfach summiert 2,7249999999999996 -> 2,72
        XCTAssertEqual(avg([("2,3", "2"), ("3,3", "4"), ("2,7", "2"), ("1,0", "4"), ("2,0", "10"), ("4,0", "10")]), 2.73)
        XCTAssertEqual(QISParser.summary([("2,3", "2"), ("3,3", "4"), ("2,7", "2"), ("1,0", "4"), ("2,0", "10"), ("4,0", "10")]
            .map { QISGrade(text: $0.0, note: $0.0, credits: $0.1) }).credits, 32)
        // Gleichstand auf dem exakten Wert: zur geraden Ziffer wie round()
        XCTAssertEqual(QISParser.round2(0.125), 0.12)
        XCTAssertEqual(QISParser.round2(2.675), 2.67)
        XCTAssertEqual(QISParser.round2(1.005), 1.0)
        XCTAssertEqual(QISParser.round2(2.0), 2.0)
    }

    // MARK: Bescheinigungen

    func testDocumentsAreListedWithTitles() {
        let p = page(bescheinigungenHTML, "state=change&type=1&moduleParameter=studentReportsMenu&asi=SESSION.42")
        XCTAssertEqual(p.documents.map(\.title), [
            "Studienzeitbescheinigung / Immatrikulationsbescheinigung / Bescheinigung nach § 9 BAföG",
            "Certificate of study period and enrolment",
        ])
        for d in p.documents {
            XCTAssertEqual(d.link.state, "verpublish")
            XCTAssertFalse(d.link.address.contains("asi"))
        }
        XCTAssertFalse(p.documents.contains { $0.link.state == "verify" })
        let json = QISParser.apiJSON(grades: [], documents: p.documents, fetchedAt: "2026-10-25T10:00:00")
        let docs = json["documents"]?.array ?? []
        XCTAssertEqual(docs.count, 2)
        // wie "ORDER BY id DESC": zuletzt gefunden zuerst; id als Text, damit sie nie als PC-id gilt
        XCTAssertEqual(docs.map { $0["title"]?.string ?? "" }, [
            "Certificate of study period and enrolment",
            "Studienzeitbescheinigung / Immatrikulationsbescheinigung / Bescheinigung nach § 9 BAföG",
        ])
        XCTAssertEqual(docs.map { $0["id"] }, ["device-2", "device-1"])
        for d in docs {
            XCTAssertNil(d["id"]?.int)
            XCTAssertEqual(d["source"], "device")
            XCTAssertEqual(Set(d.object.map { Array($0.keys) } ?? []), ["id", "source", "title", "url", "fetched_at"])
        }
        XCTAssertEqual(docs[1]["url"]?.string, p.documents[0].link.address)
        XCTAssertEqual(docs[0]["fetched_at"], "2026-10-25T10:00:00")
        XCTAssertFalse(json.jsonString().contains("SESSION"))
        XCTAssertEqual(QISParser.cleanTitle("  PDF-Notenspiegel   zum Drucken "), "Notenspiegel")
        XCTAssertEqual(QISParser.cleanTitle("PDF"), "Dokument")
    }

    func testImageLinksInBlocksGetTitleFromBlock() {
        let html = """
        <html><body><h1>Meine Bescheinigungen</h1>
        <ul class="liste">
         <li>Studienzeitbescheinigung <a href="rds?state=verpublish&amp;moduleCall=Studienbescheinigung&amp;asi=SESSION.42"><img src="/QIS/images//pdf.svg" alt="PDF"></a>
         <li>Immatrikulationsbescheinigung <a href="rds?state=verpublish&amp;moduleCall=Immatrikulation&amp;asi=SESSION.42"><img alt="PDF"></a></li>
         <li>Datenkontrollblatt
           <ul><li><span><a href="rds?state=verpublish&amp;moduleCall=Datenkontrollblatt&amp;asi=SESSION.42"><img alt="PDF"></a></span></ul>
        </ul>
        <div>Transcript of Records <span><a href="rds?state=verpublish&amp;moduleCall=Transcript&amp;asi=SESSION.42"><img alt="pdf"></a></span></div>
        <p>Bescheinigung nach &sect; 9 BAf&ouml;G <a href="rds?state=verpublish&amp;moduleCall=Bafoeg&amp;asi=SESSION.42"><img alt="PDF"></a>
        <p>Leistungs&uuml;bersicht <a href="rds?state=verpublish&amp;moduleCall=Leistungen&amp;asi=SESSION.42"><img alt="PDF"></a></p>
        <table><tr><td>Kopfzeile <div>Notenbescheinigung <a href="rds?state=verpublish&amp;moduleCall=Noten&amp;asi=SESSION.42"><img alt="PDF"></a>
          <td>Daneben</table>
        <div><table summary="Liste der Stammdaten des Studierenden"><tr><th>Name des Studierenden</th><td>Max Muster</td></tr></table>
         <a href="rds?state=verpublish&amp;moduleCall=Stammdatenblatt&amp;asi=SESSION.42"><img alt="PDF"></a></div>
        <a href="rds?state=user&amp;type=4&amp;asi=SESSION.42">Logout</a>
        </body></html>
        """
        let p = page(html, "state=change&type=1&moduleParameter=studentReportsMenu&asi=SESSION.42")
        XCTAssertEqual(p.documents.map(\.title), [
            "Studienzeitbescheinigung", "Immatrikulationsbescheinigung", "Datenkontrollblatt", "Transcript of Records",
            "Bescheinigung nach § 9 BAföG", "Leistungsübersicht", "Notenbescheinigung", "Dokument",
        ])
        XCTAssertFalse(p.documents.contains { $0.title.contains("Max") || $0.title.contains("Muster") })
        // Layout-Block um die ganze Seite ist kein Titel
        let long = String(repeating: "Layout ", count: 40)
        let q = page(#"<div>\#(long)<a href="rds?state=verpublish&amp;moduleCall=X"><img alt="PDF"></a></div>"#)
        XCTAssertEqual(q.documents.map(\.title), ["Dokument"])
    }

    // MARK: Ablauf und Format

    func testCollectorWalksTheTreeAndBuildsApiJSON() throws {
        var c = QISCollector()
        let tree = page(treeHTML, "state=notenspiegelStudent&next=tree.vm&asi=SESSION.42")
        c.absorb(tree)
        let next = c.nextLinks(on: tree)
        XCTAssertEqual(next.count, 1)
        let list = page(leistungenHTML, "state=notenspiegelStudent&next=list.vm&asi=SESSION.42")
        c.absorb(list, via: next[0])
        c.absorb(list, via: next[0])                                // doppelt aufgerufen: keine doppelten Zeilen
        XCTAssertTrue(c.nextLinks(on: tree).isEmpty)                // schon besucht
        XCTAssertEqual(c.grades.count, 4)
        XCTAssertEqual(c.grades[0].abschluss, "Musterfach (PO-Version 2017)")
        c.absorb(page(bescheinigungenHTML))
        c.absorb(page(bescheinigungenHTML))
        XCTAssertEqual(c.documents.count, 2)

        let json = c.apiJSON(fetchedAt: "2026-10-25T10:00:00")
        XCTAssertEqual(Set(json.object.map { Array($0.keys) } ?? []), ["grades", "average", "credits", "passed", "last_run", "documents"])
        XCTAssertEqual(json["average"], 2.39)
        XCTAssertEqual(json["credits"], 20)
        XCTAssertEqual(json["passed"], 3)
        XCTAssertEqual(json["last_run"], .null)
        let rows = json["grades"]?.array ?? []
        // ORDER BY semester DESC, text (Textvergleich wie SQLite: "WiSe 25/26" vor "SoSe 26")
        XCTAssertEqual(rows.map { $0["text"]?.string ?? "" },
                       ["Mathematik I", "Physik für Ingenieure", "Programmieren & Algorithmen", "Schlüsselkompetenzen"])
        let first = rows[0]
        XCTAssertEqual(Set(first.object.map { Array($0.keys) } ?? []),
                       ["id", "pruefungsnr", "text", "semester", "note", "status", "credits", "versuch", "datum", "abschluss", "raw", "fetched_at"])
        XCTAssertEqual(first["status"], "bestanden")
        XCTAssertEqual(first["fetched_at"], "2026-10-25T10:00:00")
        // Rundreise durch den eigenen JSON-Leser
        XCTAssertEqual(try JSONValue.parse(json.jsonString()), json)
        // Sammler laesst sich speichern und wieder laden
        let back = try JSONDecoder().decode(QISCollector.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back, c)
    }

    func testCollectorVisitsEveryAbschlussWithoutCollapsing() throws {
        var c = QISCollector()
        let start = page(twoAbschlussTree(expanded: []), "state=notenspiegelStudent&next=tree.vm&asi=SESSION.42")
        c.absorb(start)
        XCTAssertEqual(c.nextLinks(on: start).map(\.text), ["Abschluss 82 Bachelor of Science", "Abschluss 88 Master of Science"])

        // 82 aufklappen: dort erst der Studiengang
        let open82 = try XCTUnwrap(c.nextLinks(on: start).first)
        let tree82 = QISPage.parse(html: twoAbschlussTree(expanded: [82]), url: try XCTUnwrap(start.url(for: open82)))
        c.absorb(tree82, via: open82)
        let l82 = c.nextLinks(on: tree82)
        XCTAssertEqual(l82.map { $0.studiengang ?? "" }, ["Bachelorfach (PO-Version 2017)"])
        let list82 = QISPage.parse(html: gradeListHTML("1001", "Mathematik I"), url: try XCTUnwrap(tree82.url(for: l82[0])))
        c.absorb(list82, via: l82[0])

        // zurueck auf dem Baum: 88 kommt dran, 82 nicht noch einmal (sein Link dort klappt nur zu)
        XCTAssertTrue(tree82.links(.abschluss).contains { $0.text.hasPrefix("Abschluss 82") && $0.parameters["expand"] == "1" })
        let next = c.nextLinks(on: tree82)
        XCTAssertEqual(next.map(\.text), ["Abschluss 88 Master of Science"])
        // ohne besuchte Adressen weiterhin der erste Schritt der Seite
        XCTAssertEqual(tree82.nextLinksTowardGrades(), l82)

        let tree88 = QISPage.parse(html: twoAbschlussTree(expanded: [82, 88]), url: try XCTUnwrap(tree82.url(for: next[0])))
        c.absorb(tree88, via: next[0])
        let l88 = c.nextLinks(on: tree88)
        XCTAssertEqual(l88.map { $0.studiengang ?? "" }, ["Masterfach (PO-Version 2017)"])
        let list88 = QISPage.parse(html: gradeListHTML("2001", "Seminar"), url: try XCTUnwrap(tree88.url(for: l88[0])))
        c.absorb(list88, via: l88[0])
        XCTAssertTrue(c.nextLinks(on: tree88).isEmpty)
        XCTAssertTrue(c.nextLinks(on: tree82).isEmpty)
        XCTAssertEqual(c.grades.map(\.text), ["Mathematik I", "Seminar"])
        XCTAssertEqual(c.grades.map { $0.abschluss ?? "" }, ["Bachelorfach (PO-Version 2017)", "Masterfach (PO-Version 2017)"])

        // Knotennummern mit gleichem Anfang (8 und 82) gelten nicht als derselbe Knoten
        let similar = page(twoAbschlussTree(expanded: [], numbers: (82, 8)), "state=notenspiegelStudent&next=tree.vm&asi=SESSION.42")
        var d = QISCollector()
        d.absorb(similar, via: similar.links(.abschluss)[0])
        XCTAssertEqual(d.nextLinks(on: similar).map(\.text), ["Abschluss 8 Master of Science"])
    }

    func testNullSemesterSortsLast() {
        let json = QISParser.apiJSON(grades: [QISGrade(text: "B"), QISGrade(text: "A", semester: "SoSe 26"), QISGrade(text: "C", semester: "WiSe 25/26")])
        XCTAssertEqual(json["grades"]?.array?.map { $0["text"]?.string ?? "" }, ["C", "A", "B"])
        XCTAssertEqual(json["grades"]?.array?[2]["semester"], .null)
    }

    // MARK: Hilfsfunktionen

    func testEntitiesAndWhitespace() {
        XCTAssertEqual(QISParser.decodeEntities("Pr&uuml;fung &amp; &#246;&#xFC; &unbekannt; &amp &#150; &#0;"), "Prüfung & öü &unbekannt; &amp – \u{FFFD}")
        XCTAssertEqual(QISParser.clean(" a\u{A0}\n\t b\u{AD}c "), "a bc")
        XCTAssertEqual(QISParser.escapeUnsafe("a|b c%zz%41ä"), "a%7Cb%20c%25zz%41%C3%A4")
        let (address, asi) = QISParser.stripSession("https://qis.test/qisserver/rds;jsessionid=ABC?asi=X1&state=a&ASI=X2&b=c#frag")
        XCTAssertEqual(address, "https://qis.test/qisserver/rds?state=a&b=c")
        XCTAssertEqual(asi, "X1")
    }

    func testBrokenHTMLDoesNotCrash() {
        for html in ["", "<", "<a", "<a href=\"x", "<table><tr><td>1<td>2", "</table></tr></td>", "<!-- offen", "<a =x>t</a>",
                     "<script>nie zu", "<td>ohne Tabelle</td>", String(repeating: "<table><tr><td>", count: 200)] {
            let p = page(html)
            XCTAssertTrue(p.grades().isEmpty, html)
        }
    }
}
