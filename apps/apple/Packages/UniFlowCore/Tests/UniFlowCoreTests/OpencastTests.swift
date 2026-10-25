import Foundation
import XCTest
@testable import UniFlowCore

// Opencast-Aufzeichnungen: Fixtures mit erfundenen Werten nach dem Aufbau der LUH-Seite media/index
// (docs/QIS-STUDIP-STRUKTUR.md, Abschnitt Opencast). Rechner studip.test / oc.example.test, keine echten Namen.

private func fixture(_ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/opencast/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
}

private let cal = LectureWeek.calendar
private func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Date {
    cal.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
}
/// Semesterbeginn der Tests: Montag, 12.10.2026 (Woche 4 = 02.11. – 08.11.)
private let start = day(2026, 10, 12, hour: 0)

private func html(_ s: String, status: Int = 200, finalURL: String? = nil) -> HTTPReply {
    HTTPReply(status: status, contentType: "text/html; charset=UTF-8", finalURL: finalURL.flatMap(URL.init(string:)), body: Data(s.utf8))
}

final class OpencastParserTests: XCTestCase {

    func testVideosFixture() throws {
        guard case .videos(let v) = OpencastParser.parse(html: try fixture("media-index-videos.html"), status: 200,
                                                         pageURL: URL(string: "https://studip.example.test/plugins.php/opencastpluginluh/media/index?cid=x")) else {
            return XCTFail("keine Videos erkannt")
        }
        XCTAssertEqual(v.map(\.id), ["aaaaaaaa-0000-4000-8000-000000000001", "aaaaaaaa-0000-4000-8000-000000000002", "Xyzab-12345-6789"])

        let a = v[0]
        XCTAssertEqual(a.title, "3. Vorlesung vom 06.11.2026 – Grenzwerte & Folgen")         // &ndash; und &amp;
        XCTAssertNil(a.description)                                                          // leerer div
        XCTAssertEqual(a.duration, 1 * 3600 + 28 * 60 + 59)
        XCTAssertEqual(a.author, "Prof. Dr. Erika Beispiel")
        XCTAssertEqual(a.created, Date(timeIntervalSince1970: 1_794_045_600))
        XCTAssertEqual(a.thumbnailURL?.absoluteString,
                       "https://oc.example.test/static/org/engage-player/aaaaaaaa-0000-4000-8000-000000000001/bbbbbbbb-0000-4000-8000-000000000001/vorschau_3.000s-player.jpg")
        XCTAssertEqual(a.playerURL?.absoluteString,                                          // ohne "#ts="
                       "https://studip.example.test/plugins.php/opencastpluginluh/media/player/aaaaaaaa-0000-4000-8000-000000000001?cid=0123456789abcdef0123456789abcdef")
        XCTAssertEqual(a.downloads.map(\.quality), ["1080p", "720p", "480p"])
        XCTAssertEqual(a.downloads.map(\.height), [1080, 720, 480])
        XCTAssertEqual(a.download("720p")?.url.lastPathComponent, "res0720.mp4")

        let b = v[1]
        XCTAssertEqual(b.title, "Zentralübung 02")
        XCTAssertEqual(b.description, "Besprechung von Übungsblatt 2: Induktion und Ungleichungen")
        XCTAssertNil(b.author)                                                               // "-"
        XCTAssertEqual(b.duration, 35 * 60 + 48)
        XCTAssertEqual(b.downloads.map(\.quality), ["720p", "480p"])                          // 1080p fehlt
        XCTAssertNil(b.download("1080p"))

        let c = v[2]
        XCTAssertEqual(c.id, "Xyzab-12345-6789")                                             // kurze Kennung
        XCTAssertEqual(c.title, "02. Vorlesungswoche - Ergänzung zu Teil 2 (Video aus SoSe 21)")
        XCTAssertEqual(c.description, "Korrektur eines Rechenfehlers bei der LR-Zerlegung")
        XCTAssertEqual(c.author, "Dr. Max Muster")
        XCTAssertEqual(c.created, Date(timeIntervalSince1970: 1_649_932_712))
        XCTAssertEqual(c.thumbnailURL?.pathExtension, "png")
        XCTAssertTrue(c.playerURL?.path.hasSuffix("/media/player/Xyzab-12345-6789") ?? false)
    }

    func testEmptyTableIsOpencastWithoutVideos() throws {
        XCTAssertEqual(OpencastParser.parse(html: try fixture("media-index-empty.html"), status: 200), .videos([]))
    }

    func testMissingNavigationIsNoOpencast() throws {
        let page = try fixture("media-index-no-plugin.html")
        XCTAssertEqual(OpencastParser.parse(html: page, status: 500), .noOpencast)
        XCTAssertEqual(OpencastParser.parse(html: page, status: 200), .noOpencast)
        XCTAssertEqual(OpencastParser.parse(html: "<html><body>Nicht gefunden</body></html>", status: 404), .noOpencast)
        // andere Fehlerseiten sagen nichts ueber den Kurs
        XCTAssertEqual(OpencastParser.parse(html: "<html><body>Wartungsarbeiten</body></html>", status: 503), .unrecognized)
        XCTAssertEqual(OpencastParser.parse(html: "<html><body>Fehler!</body></html>", status: 500), .unrecognized)
        XCTAssertEqual(OpencastParser.parse(html: "<html><body><p>Startseite</p></body></html>", status: 200), .unrecognized)
    }

    func testMalformedHTML() {
        // offene tr/td, Grossbuchstaben, Attribute ohne Anfuehrungszeichen, relative Links, Entities in Attributen,
        // Kommentar und Skript mit Tabellen-Text
        let page = """
        <TABLE class="default media-table"><TBODY>
        <!-- <tr class="media-table-row" id="kommentar"> -->
        <script>var s = '<tr class="media-table-row" id="skript">';</script>
        <TR CLASS=media-table-row ID=Abc-1>
          <TD><DIV class=thumb-container style="background-image:url(/thumb/a.jpg)"></DIV>
          <TD><div class="media-table-infos"><div><A HREF="/plugins.php/opencastpluginluh/media/player/Abc-1?cid=k1&amp;x=1">Vorlesung&nbsp;4 &#8211; Reihen &lt;Teil 1&gt;</A></div>
              <div>Zeile eins<br>Zeile &quot;zwei&quot;</div></div>
          <TD class="media-table-duration" data-sort-value="45:10">45:10
          <TD class=media-table-lecturer>  Dr.   Erika   Beispiel
          <TD class="media-table-created">13.11.2026
          <TD class=actions><a href="https://oc.example.test/v/a-720.mp4">Download: 720p</a><a href='https://oc.example.test/v/a-audio.m4a'>Download: Audio</a>
              <a href="mailto:hilfe@example.test">Problem melden</a>
        <TR class="media-table-row" id="Abc-2"><td><div class="media-table-infos"><div><a href="player/Abc-2">Zweites</a></div></div>
        </TBODY></TABLE>
        """
        guard case .videos(let v) = OpencastParser.parse(html: page, status: 200, pageURL: URL(string: "https://studip.test/plugins.php/opencastpluginluh/media/index?cid=k1")) else {
            return XCTFail("keine Videos")
        }
        XCTAssertEqual(v.map(\.id), ["Abc-1", "Abc-2"])
        XCTAssertEqual(v[0].title, "Vorlesung 4 – Reihen <Teil 1>")
        XCTAssertEqual(v[0].description, "Zeile eins\nZeile \"zwei\"")
        XCTAssertEqual(v[0].duration, 45 * 60 + 10)
        XCTAssertEqual(v[0].author, "Dr. Erika Beispiel")
        XCTAssertEqual(v[0].created, day(2026, 11, 13))                                    // Text, ohne data-sort-value
        XCTAssertEqual(v[0].thumbnailURL?.absoluteString, "https://studip.test/thumb/a.jpg")
        XCTAssertEqual(v[0].playerURL?.absoluteString, "https://studip.test/plugins.php/opencastpluginluh/media/player/Abc-1?cid=k1&x=1")
        XCTAssertEqual(v[0].downloads.map(\.quality), ["720p"])                             // Audio ist keine Videofassung
        XCTAssertNil(v[1].duration)
        XCTAssertEqual(v[1].playerURL?.absoluteString, "https://studip.test/plugins.php/opencastpluginluh/media/player/Abc-2")
        XCTAssertTrue(v[1].downloads.isEmpty)
    }

    func testForeignAndPlainHTTPHostsAreIgnored() {
        // Player fremder Hosts nie (Webansicht mit Stud.IP-Sitzung); Downloads und Vorschau nur https vom Videoserver
        let page = """
        <table class="media-table"><tbody>
        <tr class="media-table-row" id="v1"><td><div class="thumb-container" style="background-image:url('https://oc.example.test/t1.jpg')"></div>
          <td><div class="media-table-infos"><div><a href="https://studip.test/plugins.php/opencastpluginluh/media/player/v1">Eins</a></div></div>
          <td class="actions"><a href="https://oc.example.test/v1-720.mp4">Download: 720p</a>
            <a href="http://oc.example.test/v1-480.mp4">Download: 480p</a>
            <a href="https://fremd.example.org/v1-1080.mp4">Download: 1080p</a>
        <tr class="media-table-row" id="v2"><td><div class="thumb-container" style="background-image:url('https://fremd.example.org/t2.jpg')"></div>
          <td><div class="media-table-infos"><div><a href="https://fremd.example.org/plugins.php/opencastpluginluh/media/player/v2">Zwei</a></div></div>
          <td class="actions"><a href="https://oc.example.test/v2-720.mp4">Download: 720p</a>
        <tr class="media-table-row" id="v3"><td><div class="thumb-container" style="background-image:url('http://oc.example.test/t3.jpg')"></div>
          <td><div class="media-table-infos"><div><a href="http://studip.test/plugins.php/opencastpluginluh/media/player/v3">Drei</a></div></div>
        </tbody></table>
        """
        guard case .videos(let v) = OpencastParser.parse(html: page, status: 200, pageURL: URL(string: "https://studip.test/plugins.php/opencastpluginluh/media/index?cid=k1")) else {
            return XCTFail("keine Videos")
        }
        XCTAssertEqual(v.map(\.id), ["v1", "v2", "v3"])
        XCTAssertEqual(v[0].downloads.map(\.url.absoluteString), ["https://oc.example.test/v1-720.mp4"])
        XCTAssertEqual(v[0].thumbnailURL?.absoluteString, "https://oc.example.test/t1.jpg")
        XCTAssertEqual(v[0].playerURL?.host, "studip.test")
        XCTAssertNil(v[1].playerURL)                                                        // fremder Host
        XCTAssertNil(v[1].thumbnailURL)
        XCTAssertEqual(v[1].downloads.map(\.quality), ["720p"])
        XCTAssertNil(v[2].playerURL)                                                        // http statt https
        XCTAssertNil(v[2].thumbnailURL)
    }

    func testOverviewNavigationAndLoginPage() throws {
        let withTab = """
        <ul id="tabs"><li><a href="/dispatch.php/course/overview?cid=k1">Übersicht</a></li>
        <li><a href="/plugins.php/opencastpluginluh/media/index?cid=k1"><span>Aufzeichnungen</span></a></li></ul>
        """
        XCTAssertTrue(OpencastParser.courseHasRecordings(overviewHTML: withTab))
        XCTAssertTrue(OpencastParser.courseHasRecordings(overviewHTML: #"<nav><a href="/x">Aufzeichnungen</a></nav>"#))
        XCTAssertFalse(OpencastParser.courseHasRecordings(overviewHTML: #"<ul><li><a href="/dispatch.php/course/files?cid=k1">Dateien</a></li></ul>"#))

        XCTAssertTrue(OpencastParser.looksLikeLoginPage(#"<form action="https://studip.test/dispatch.php/login" method=post><input type="text" name="loginname"><INPUT TYPE=PASSWORD name=password></form>"#))
        XCTAssertTrue(OpencastParser.looksLikeLoginPage(#"<form action="https://sso.test/idp/profile/SAML2/Redirect/SSO"></form>"#))
        XCTAssertFalse(OpencastParser.looksLikeLoginPage(try fixture("media-index-videos.html")))
        XCTAssertFalse(OpencastParser.looksLikeLoginPage(try fixture("media-index-no-plugin.html")))
    }

    func testDurationText() {
        XCTAssertEqual(OpencastParser.seconds("01:28:59"), 5339)
        XCTAssertEqual(OpencastParser.seconds("05:46"), 346)
        XCTAssertNil(OpencastParser.seconds("lang"))
        XCTAssertNil(OpencastParser.seconds("1:-2:3"))
    }
}

final class LectureWeekTests: XCTestCase {
    private func g(_ title: String, _ desc: String? = nil, created: Date? = nil, start s: Date? = start) -> LectureWeekGuess {
        LectureWeek.guess(title: title, description: desc, created: created, semesterStart: s)
    }

    func testExplicitWeek() {
        XCTAssertEqual(g("02. Vorlesungswoche - Ergänzung zu Teil 2 (Video aus SoSe 21)", created: day(2022, 4, 14)),
                       LectureWeekGuess(week: 2, source: .title))                         // Angabe schlaegt altes Semester
        XCTAssertEqual(g("Woche 3: Zusammenfassung"), LectureWeekGuess(week: 3, source: .title))
        XCTAssertEqual(g("Lehrwoche 04 – Reihen"), LectureWeekGuess(week: 4, source: .title))
        XCTAssertEqual(g("5. Woche"), LectureWeekGuess(week: 5, source: .title))
        XCTAssertEqual(g("Nachtrag", "Material zur Vorlesungswoche 6"), LectureWeekGuess(week: 6, source: .title))
        XCTAssertEqual(g("VL-Woche 2"), LectureWeekGuess(week: 2, source: .title))
    }

    func testCalendarWeekIsNotLectureWeek() {
        // KW 45 ist die Kalenderwoche; die Lehrwoche kommt aus dem Erstelldatum (03.11.2026 = Woche 4)
        XCTAssertEqual(g("Aufzeichnung KW 45", created: day(2026, 11, 3)), LectureWeekGuess(week: 4, source: .date))
        XCTAssertEqual(g("Mitschnitt aus Kalenderwoche 44", created: day(2026, 10, 27)), LectureWeekGuess(week: 3, source: .date))
        XCTAssertEqual(g("44. KW", created: day(2026, 10, 27)), LectureWeekGuess(week: 3, source: .date))
        XCTAssertEqual(g("KW 45"), .unknown)
    }

    func testNumberedSessions() {
        XCTAssertEqual(g("3. Vorlesung vom 06.11.2026 – Grenzwerte & Folgen"), LectureWeekGuess(week: 3, source: .title))
        XCTAssertEqual(g("Vorlesung 5"), LectureWeekGuess(week: 5, source: .title))
        XCTAssertEqual(g("Analysis VL03"), LectureWeekGuess(week: 3, source: .title))
        XCTAssertEqual(g("Zentralübung 02"), LectureWeekGuess(week: 2, source: .title))
        XCTAssertEqual(g("Zentraluebung 7"), LectureWeekGuess(week: 7, source: .title))
        XCTAssertEqual(g("Übung 6"), LectureWeekGuess(week: 6, source: .title))
        XCTAssertEqual(g("2. Übung"), LectureWeekGuess(week: 2, source: .title))
        XCTAssertEqual(g("Hörsaalübung Nr. 4"), LectureWeekGuess(week: 4, source: .title))
        XCTAssertEqual(g("Vorlesung 4 (2023)"), LectureWeekGuess(week: 4, source: .title))  // Nummer trotz altem Jahr
        // keine Nummer: "Übungsblatt 2", "Gruppenübung 3", Datum hinter "Vorlesung"
        XCTAssertEqual(g("Besprechung Übungsblatt 2"), .unknown)
        XCTAssertEqual(g("Vorlesung 06.11.2026"), LectureWeekGuess(week: 4, source: .date))
    }

    func testDateInTitleOrCreated() {
        XCTAssertEqual(g("Vorlesung vom 06.11.2026", created: day(2026, 11, 20)), LectureWeekGuess(week: 4, source: .date))
        XCTAssertEqual(g("Vorlesung am 13.11.", created: day(2026, 12, 1)), LectureWeekGuess(week: 5, source: .date))
        XCTAssertEqual(g("Aufzeichnung 2026-10-20"), LectureWeekGuess(week: 2, source: .date))
        XCTAssertEqual(g("Grenzwerte und Stetigkeit", created: day(2026, 10, 20)), LectureWeekGuess(week: 2, source: .date))
        XCTAssertEqual(g("Kapitel 2.1. Reihen", created: day(2026, 10, 20)), LectureWeekGuess(week: 2, source: .date))
        // Kapitel- oder Versionsnummer mit drei Teilen ist kein Datum (sonst 01.02.2010); es gilt das Erstelldatum
        XCTAssertEqual(g("Kapitel 1.2.10 Reihen", created: day(2026, 11, 3)), LectureWeekGuess(week: 4, source: .date))
        XCTAssertEqual(g("Version 2.3.11", created: day(2026, 10, 20)), LectureWeekGuess(week: 2, source: .date))
        XCTAssertEqual(g("Mitschnitt 6.11.26", created: day(2026, 12, 1)), LectureWeekGuess(week: 4, source: .date))   // Semesterjahr
        XCTAssertEqual(g("Mitschnitt vom 6.11.26", created: day(2026, 12, 1)), LectureWeekGuess(week: 4, source: .date))
        // zweistelliges Jahr nach "vom", aber vor Semesterbeginn: kein Hinweis auf altes Semester, Erstelldatum
        XCTAssertEqual(g("Nachtrag vom 1.2.10", created: day(2026, 10, 20)), LectureWeekGuess(week: 2, source: .date))
        XCTAssertEqual(g("Kapitel 1.2.10 vom 06.11.2026"), LectureWeekGuess(week: 4, source: .date))   // erstes gueltiges Datum
        XCTAssertEqual(g("Prozess 12 Analyse", created: day(2026, 10, 20)), LectureWeekGuess(week: 2, source: .date)) // kein "SS 12"
        // Zeitumstellung am 25.10.2026: Montag 26.10. bleibt Woche 3
        XCTAssertEqual(g("Montag", created: day(2026, 10, 26, hour: 0)), LectureWeekGuess(week: 3, source: .date))
        XCTAssertEqual(g("Begrüßung", created: day(2026, 10, 12, hour: 0)), LectureWeekGuess(week: 1, source: .date))
        XCTAssertEqual(g("WiSe 2026/27 – Einführung", created: day(2026, 10, 14)), LectureWeekGuess(week: 1, source: .date))
        XCTAssertEqual(g("Wiederholung", created: day(2027, 6, 1)), .unknown)               // nach Woche 20
    }

    func testEarlierSemesterIsUnknown() {
        XCTAssertEqual(g("Grenzwerte (2023)", created: day(2026, 10, 20)), .unknown)
        XCTAssertEqual(g("Analysis SoSe 21", created: day(2026, 10, 20)), .unknown)
        XCTAssertEqual(g("Integration WS 22/23", created: day(2026, 10, 20)), .unknown)
        XCTAssertEqual(g("Sommersemester 2025: Reihen", created: day(2026, 10, 20)), .unknown)
        XCTAssertEqual(g("Grenzwerte", "aus dem Wintersemester 2023/24", created: day(2026, 10, 20)), .unknown)
        XCTAssertEqual(g("Grenzwerte vom 06.11.2023"), .unknown)                            // Datum vor Semesterbeginn
        XCTAssertEqual(g("Ergänzung zu Teil 2", created: day(2022, 4, 14)), .unknown)       // erstellt vor Semesterbeginn
        XCTAssertEqual(g("Vorab", created: day(2026, 10, 9)), .unknown)                     // Freitag vor Woche 1
    }

    func testWithoutSemesterStartOnlyTitleCounts() {
        XCTAssertEqual(g("Vorlesung 5", start: nil), LectureWeekGuess(week: 5, source: .title))
        XCTAssertEqual(g("Vorlesung vom 06.11.2026", created: day(2026, 11, 6), start: nil), .unknown)
        XCTAssertNil(LectureWeekGuess(week: nil, source: .date).week)
        XCTAssertEqual(LectureWeekGuess(week: nil, source: .date).source, .unknown)
    }

    func testSemesterStartAndLabels() {
        let labels: [(week: Int, label: String)] = [(-2, "Klausuren & Altklausuren"), (0, "Vor Vorlesungsbeginn"), (3, "Woche 3 · 26.10. – 01.11.")]
        XCTAssertEqual(LectureWeek.semesterStart(fromWeekLabels: labels, reference: day(2026, 11, 1)), start)
        // Wintersemester ueber Neujahr: Woche 13 beginnt am 04.01.2027
        XCTAssertEqual(LectureWeek.semesterStart(fromWeekLabels: [(13, "Woche 13 · 04.01. – 10.01.")], reference: day(2027, 1, 5)), start)
        XCTAssertNil(LectureWeek.semesterStart(fromWeekLabels: [(-1, "Ältere Unterlagen")], reference: day(2026, 11, 1)))
        XCTAssertEqual(LectureWeek.semesterStart(isoDay: "2026-10-14"), start)
        XCTAssertEqual(LectureWeek.semesterStart(isoDay: "2026-10-12T00:00:00+02:00"), start)
        XCTAssertNil(LectureWeek.semesterStart(isoDay: "bald"))
        XCTAssertEqual(LectureWeek.label(3, semesterStart: start), "Woche 3 · 26.10. – 01.11.")
        XCTAssertEqual(LectureWeek.label(3, semesterStart: nil), "Woche 3")
        XCTAssertEqual(LectureWeek.weekIndex(start: start, date: day(2026, 11, 8, hour: 23)), 4)
    }
}

final class RecordingAssignmentTests: XCTestCase {

    func testClassifyLikePython() {
        XCTAssertEqual(StudIPSubject.classify("Übung zu Testfach Analysis (Tranche A)").subject, "Testfach Analysis")
        XCTAssertEqual(StudIPSubject.classify("Übung zu Testfach Analysis (Tranche A)").kind, "uebung")
        XCTAssertEqual(StudIPSubject.classify("Testfach Analysis").kind, "vorlesung")
        XCTAssertEqual(StudIPSubject.classify("Zentralübung Testfach Analysis").kind, "hoersaaluebung")
        XCTAssertEqual(StudIPSubject.classify("12345 Testfach Physik - Fragestunden").subject, "Testfach Physik")
        XCTAssertEqual(StudIPSubject.classify("Begrüßung der Erstsemester").kind, "sonstiges")
    }

    func testCourseToModule() {
        let modules = [RecordingModuleRef(id: 1, name: "Testfach Analysis"), RecordingModuleRef(id: 2, name: "Testfach Physik")]
        let courses = [RecordingCourseRef(id: "c1", moduleID: 1, subject: "Testfach Analysis"),
                       RecordingCourseRef(id: "c2", moduleID: nil, subject: "Testfach  physik"),
                       RecordingCourseRef(id: "c3", moduleID: 2, subject: "Testfach Analysis")]
        // Zuordnung der App gilt
        XCTAssertEqual(RecordingAssignment.moduleID(courseID: "c1", courseTitle: "egal", courses: courses, modules: modules), 1)
        XCTAssertEqual(RecordingAssignment.moduleID(courseID: "c3", courseTitle: "Testfach Analysis", courses: courses, modules: modules), 2)
        // ohne Modul: gespeichertes Fach
        XCTAssertEqual(RecordingAssignment.moduleID(courseID: "c2", courseTitle: "Anderer Titel", courses: courses, modules: modules), 2)
        // unbekannter Kurs (lokaler Modus): Fach aus dem Kurstitel
        XCTAssertEqual(RecordingAssignment.moduleID(courseID: "neu", courseTitle: "Übung zu Testfach Analysis", courses: [], modules: modules), 1)
        XCTAssertNil(RecordingAssignment.moduleID(courseID: "neu", courseTitle: "Testfach Chemie", courses: [], modules: modules))
        XCTAssertNil(RecordingAssignment.moduleID(courseID: "neu", courseTitle: "Begrüßung der Erstsemester Testfach Analysis", courses: [], modules: modules))
    }

    func testGroupBySubjectWithoutModules() {
        let now = day(2026, 11, 1)
        let v = OpencastVideo(id: "v", title: "Vorlesung 1")
        let index = RecordingsIndex(courses: [
            RecordingCourse(courseID: "c1", courseTitle: "Testfach Analysis", status: .available, videos: [v], lastChecked: now),
            RecordingCourse(courseID: "c2", courseTitle: "Übung zu Testfach Analysis", status: .available, videos: [v], lastChecked: now),
            RecordingCourse(courseID: "c3", courseTitle: "Testfach Physik", status: .available, videos: [v], lastChecked: now),
            RecordingCourse(courseID: "c4", courseTitle: "Testfach Chemie", status: .available, videos: [], lastChecked: now),
            RecordingCourse(courseID: "c5", courseTitle: "Testfach Biologie", status: .noOpencast, lastChecked: now),
        ])
        let local = RecordingAssignment.group(index, courses: [], modules: [])
        XCTAssertTrue(local.byModule.isEmpty)
        XCTAssertEqual(local.bySubject.map(\.subject), ["Testfach Analysis", "Testfach Physik"])
        XCTAssertEqual(local.bySubject[0].courses.map(\.courseID), ["c1", "c2"])          // Vorlesung und Uebung zusammen

        let withModule = RecordingAssignment.group(index, courses: [], modules: [RecordingModuleRef(id: 7, name: "testfach analysis")])
        XCTAssertEqual(withModule.byModule[7]?.map(\.courseID), ["c1", "c2"])
        XCTAssertEqual(withModule.bySubject.map(\.subject), ["Testfach Physik"])
    }

    func testWeekHintOfSheet() {
        XCTAssertEqual(StudIPWeekHint.weekHint(name: "Blatt03.pdf", folder: nil), 3)
        XCTAssertEqual(StudIPWeekHint.weekHint(name: "uebung_2.pdf", folder: "Übungen"), 2)
        XCTAssertEqual(StudIPWeekHint.weekHint(name: "Aufgaben.pdf", folder: "Übungen/Woche 5"), 5)
        XCTAssertEqual(StudIPWeekHint.weekHint(name: "02A.pdf", folder: nil), 2)
        XCTAssertNil(StudIPWeekHint.weekHint(name: "Skript.pdf", folder: "Vorlesung"))
    }
}

final class RecordingsRefreshTests: XCTestCase {
    private let base = URL(string: "https://studip.test")!
    private let now = day(2026, 11, 1)
    private let courses = [StudIPCourse(id: "c1", title: "Testfach Analysis"), StudIPCourse(id: "c2", title: "Testfach Begrüßung"),
                           StudIPCourse(id: "c3", title: "Testfach Physik")]

    private func media(_ id: String) -> String { "/plugins.php/opencastpluginluh/media/index?cid=\(id)" }
    private func overview(_ id: String) -> String { "/dispatch.php/course/overview?cid=\(id)" }

    func testFetchesEachCourseAndTreats500AsNoOpencast() async throws {
        let t = StubTransport([media("c1"): html(try fixture("media-index-videos.html")),
                               media("c2"): html(try fixture("media-index-no-plugin.html"), status: 500),
                               media("c3"): html(try fixture("media-index-empty.html"))])
        let client = StudIPClient(base: base, transport: t, pauseMillis: 0)
        let r = try await client.refreshRecordings(courses: courses, index: RecordingsIndex(), now: now)
        XCTAssertEqual(r.index.courses.map(\.courseID), ["c1", "c2", "c3"])
        XCTAssertEqual(r.index.course("c1")?.status, .available)
        XCTAssertEqual(r.index.course("c1")?.videos.count, 3)
        XCTAssertEqual(r.index.course("c2")?.status, .noOpencast)                               // 500 ist kein Fehler
        XCTAssertEqual(r.index.course("c3")?.status, .available)
        XCTAssertEqual(r.index.course("c3")?.videos, [])
        XCTAssertEqual(r.checked, 3)
        XCTAssertTrue(r.failed.isEmpty)
        XCTAssertEqual(t.requested, [media("c1"), media("c2"), media("c3")])               // kein Umweg ueber den Ueberblick
        XCTAssertEqual(r.index.course("c1")?.lastChecked, now)
        XCTAssertEqual(r.summary, "3 Aufzeichnungen")
    }

    func testNoOpencastRememberedForSevenDays() async throws {
        let old = RecordingsIndex(courses: [
            RecordingCourse(courseID: "c2", courseTitle: "Alt", status: .noOpencast, lastChecked: now.addingTimeInterval(-3 * 86400)),
            RecordingCourse(courseID: "c3", courseTitle: "Testfach Physik", status: .noOpencast, lastChecked: now.addingTimeInterval(-8 * 86400)),
        ])
        let t = StubTransport([media("c1"): html(try fixture("media-index-empty.html")),
                               media("c3"): html(try fixture("media-index-videos.html"))])
        let r = try await StudIPClient(base: base, transport: t, pauseMillis: 0)
            .refreshRecordings(courses: courses, index: old, now: now)
        XCTAssertEqual(t.requested, [media("c1"), media("c3")])                            // c2 erst nach 7 Tagen wieder
        XCTAssertEqual(r.skipped, 1)
        XCTAssertEqual(r.index.course("c2")?.status, .noOpencast)
        XCTAssertEqual(r.index.course("c2")?.courseTitle, "Testfach Begrüßung")             // Titel aktualisiert
        XCTAssertEqual(r.index.course("c2")?.lastChecked, old.course("c2")?.lastChecked)
        XCTAssertEqual(r.index.course("c3")?.status, .available)                            // nach 8 Tagen neu geprueft

        XCTAssertFalse(RecordingsRefresh.needsCheck(old.course("c2"), now: now))
        XCTAssertTrue(RecordingsRefresh.needsCheck(old.course("c2"), now: now.addingTimeInterval(4 * 86400)))
        XCTAssertTrue(RecordingsRefresh.needsCheck(nil, now: now))
        XCTAssertTrue(RecordingsRefresh.needsCheck(RecordingCourse(courseID: "x", courseTitle: "x", status: .available, lastChecked: now), now: now))
    }

    func testLoginPageMeansSessionExpired() async throws {
        let login = #"<html><body><form action="/dispatch.php/login" method="post"><input type="password" name="password"></form></body></html>"#
        for reply in [html(login), html("<html></html>", finalURL: "https://studip.test/dispatch.php/login?cancel_login=1"),
                      html("", status: 401), html("<html></html>", finalURL: "https://sso.test/idp/profile/SAML2/Redirect/SSO")] {
            let t = StubTransport([media("c1"): reply])
            do {
                _ = try await StudIPClient(base: base, transport: t, pauseMillis: 0).refreshRecordings(courses: courses, index: RecordingsIndex(), now: now)
                XCTFail("Sitzungsablauf nicht erkannt")
            } catch let e as StudIPError {
                XCTAssertEqual(e, .sessionExpired)
            }
        }
    }

    func testUnclearPageAsksOverviewAndKeepsOldStateOnErrors() async throws {
        let video = OpencastVideo(id: "alt", title: "Alt")
        let old = RecordingsIndex(courses: [RecordingCourse(courseID: "c1", courseTitle: "Testfach Analysis", status: .available,
                                                            videos: [video], lastChecked: now.addingTimeInterval(-3600))])
        let maintenance = html("<html><body>Wartungsarbeiten</body></html>", status: 503)
        let t = StubTransport([
            media("c1"): maintenance, overview("c1"): html(#"<a href="/plugins.php/opencastpluginluh/media/index?cid=c1">Aufzeichnungen</a>"#),
            media("c2"): maintenance, overview("c2"): html(#"<a href="/dispatch.php/course/files?cid=c2">Dateien</a>"#),
            media("c3"): maintenance, overview("c3"): maintenance,
        ])
        let r = try await StudIPClient(base: base, transport: t, pauseMillis: 0).refreshRecordings(courses: courses, index: old, now: now)
        XCTAssertEqual(r.index.course("c1")?.videos, [video])                              // Reiter da, Seite gestoert: alter Stand
        XCTAssertEqual(r.index.course("c2")?.status, .noOpencast)                                 // kein Reiter im Ueberblick
        XCTAssertNil(r.index.course("c3"))                                                  // Fehler, nichts bekannt
        XCTAssertEqual(r.failed, ["Testfach Analysis", "Testfach Physik"])
        XCTAssertEqual(r.summary, "1 Aufzeichnung, 2 Kurse nicht erreichbar")
    }

    func testRequestLimitStopsAndKeepsRest() async throws {
        let old = RecordingsIndex(courses: [RecordingCourse(courseID: "c3", courseTitle: "Testfach Physik", status: .available,
                                                            videos: [OpencastVideo(id: "v", title: "V")], lastChecked: now)])
        let t = StubTransport([media("c1"): html(try fixture("media-index-empty.html"))])
        let r = try await StudIPClient(base: base, transport: t, pauseMillis: 0, maxRequests: 1)
            .refreshRecordings(courses: courses, index: old, now: now)
        XCTAssertTrue(r.stoppedEarly)
        XCTAssertEqual(r.index.courses.map(\.courseID), ["c1", "c3"])
        XCTAssertEqual(t.requested.count, 1)
    }

    func testPausesBetweenRequests() async throws {
        let t = StubTransport([media("c1"): html(try fixture("media-index-empty.html")), media("c2"): html(try fixture("media-index-empty.html"))])
        let started = Date()
        _ = try await StudIPClient(base: base, transport: t, pauseMillis: 120)
            .refreshRecordings(courses: Array(courses.prefix(2)), index: RecordingsIndex(), now: now)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.11)
    }

    func testIndexRoundTrip() throws {
        guard case .videos(let v) = OpencastParser.parse(html: try fixture("media-index-videos.html"), status: 200) else { return XCTFail() }
        let index = RecordingsIndex(courses: [RecordingCourse(courseID: "c1", courseTitle: "Testfach Analysis", status: .available, videos: v, lastChecked: now)])
        XCTAssertEqual(try RecordingsIndex.decode(index.encoded()), index)
        XCTAssertEqual(index.videoCount, 3)
    }
}

final class RecordingSuggestionTests: XCTestCase {
    private func candidates(module: Int = 1) throws -> [RecordingCandidate] {
        guard case .videos(let v) = OpencastParser.parse(html: try fixture("media-index-videos.html"), status: 200) else { return [] }
        return v.map { RecordingCandidate(courseID: "c1", video: $0, moduleID: module,
                                          week: LectureWeek.guess(title: $0.title, description: $0.description, created: $0.created, semesterStart: start).week) }
    }

    func testCandidateWeeks() throws {
        XCTAssertEqual(try candidates().map(\.week), [3, 2, 2])
    }

    func testSameWeekAndKeywords() throws {
        let s = RecordingSuggester.best(for: RecordingTaskContext(moduleID: 1, sheetWeek: 3,
                                                                  text: "Aufgabe 1: Bestimmen Sie die Grenzwerte der folgenden Folgen."),
                                        among: try candidates())
        XCTAssertEqual(s?.video.id, "aaaaaaaa-0000-4000-8000-000000000001")
        XCTAssertEqual(s?.reason, "Vorlesung derselben Woche · passt zu: Grenzwerte, Folgen")
        XCTAssertEqual(s?.score ?? 0, 4.0, accuracy: 0.001)
    }

    func testSameWeekAloneAndWeekBefore() throws {
        // Blatt 2: Zentraluebung 02 und die Ergaenzung liegen in Woche 2; die Uebung passt zusaetzlich ueber "Induktion"
        let two = RecordingSuggester.best(for: RecordingTaskContext(moduleID: 1, sheetWeek: 2, text: "Zeigen Sie per Induktion"), among: try candidates())
        XCTAssertEqual(two?.video.title, "Zentralübung 02")
        XCTAssertEqual(two?.reason, "Übung derselben Woche · passt zu: Induktion")
        // Blatt 4: nur die Vorlesung der Woche davor
        let four = RecordingSuggester.best(for: RecordingTaskContext(moduleID: 1, sheetWeek: 4, text: "Konvergenz von Reihen"), among: try candidates())
        XCTAssertEqual(four?.video.id, "aaaaaaaa-0000-4000-8000-000000000001")
        XCTAssertEqual(four?.reason, "Vorlesung der Woche davor")
    }

    func testKeywordsOnlyNeedTwoContentWords() throws {
        let strong = RecordingSuggester.best(for: RecordingTaskContext(moduleID: 1, sheetWeek: nil, text: "Grenzwerte der Folgen"), among: try candidates())
        XCTAssertEqual(strong?.video.id, "aaaaaaaa-0000-4000-8000-000000000001")
        XCTAssertEqual(strong?.reason, "passt zu: Grenzwerte, Folgen")
        XCTAssertEqual(strong?.score ?? 0, 2.0, accuracy: 0.001)
        // ein einzelnes Wort reicht nicht, auch kein langes Fachwort
        XCTAssertNil(RecordingSuggester.best(for: RecordingTaskContext(moduleID: 1, sheetWeek: nil, text: "Grenzwerte"), among: try candidates()))
        XCTAssertNil(RecordingSuggester.best(for: RecordingTaskContext(moduleID: 1, sheetWeek: nil, text: "Berechnen Sie die Folgen"), among: try candidates()))
        // nur Allerweltswoerter des Titels ("Teil", "Ergänzung", "Vorlesungswoche") zaehlen nicht
        XCTAssertNil(RecordingSuggester.best(for: RecordingTaskContext(moduleID: 1, sheetWeek: nil, text: "Teil 2 Ergänzung Vorlesungswoche Korrektur"), among: try candidates()))
        // weit entfernte Woche: Stichwoerter heben die Strafe nur auf, wenn sie deutlich sind
        XCTAssertNil(RecordingSuggester.best(for: RecordingTaskContext(moduleID: 1, sheetWeek: 9, text: "Grenzwerte der Folgen"), among: try candidates()))
        XCTAssertNil(RecordingSuggester.best(for: RecordingTaskContext(moduleID: 1, sheetWeek: 9, text: "nichts Passendes"), among: try candidates()))
    }

    /// Kopf eines Uebungsblatts mit Modulname; Video eines alten Semesters mit demselben Namen im Titel
    private let oldVideo = OpencastVideo(id: "alt-1", title: "Testfach Analysis I – Komplexe Zahlen (2023)", created: day(2023, 11, 2))
    private let sheet = "Übungsblatt 3 zur Vorlesung Testfach Analysis I\nAufgabe 1: Zeigen Sie per vollständiger Induktion"

    func testModuleNameInSheetHeadAndVideoTitleIsNoMatch() {
        let week = LectureWeek.guess(title: oldVideo.title, created: oldVideo.created, semesterStart: start).week
        XCTAssertNil(week)                                                                  // altes Semester: Woche unbekannt
        // Modulname als Name der Aufgabe
        let c = RecordingCandidate(courseID: "c1", video: oldVideo, moduleID: 1, week: week)
        XCTAssertNil(RecordingSuggester.best(for: RecordingTaskContext(moduleID: 1, sheetWeek: 3, text: sheet, names: ["Testfach Analysis I"]), among: [c]))
        // Kurstitel des Videos genuegt ebenso
        let titled = RecordingCandidate(courseID: "c1", video: oldVideo, moduleID: 1, week: week, courseTitle: "Testfach Analysis I")
        XCTAssertNil(RecordingSuggester.best(for: RecordingTaskContext(moduleID: 1, sheetWeek: 3, text: sheet), among: [titled]))
        // Uebungskurs mit "Übung zu …" im Titel
        let exercise = RecordingCandidate(courseID: "c2", video: oldVideo, moduleID: 1, week: nil, courseTitle: "Übung zu Testfach Analysis I")
        XCTAssertNil(RecordingSuggester.best(for: RecordingTaskContext(moduleID: 1, sheetWeek: nil, text: sheet), among: [exercise]))
        // passt der Inhalt wirklich, bleibt der Vorschlag (Modulname zaehlt nicht mit)
        let fitting = RecordingCandidate(courseID: "c1", video: OpencastVideo(id: "alt-2", title: "Testfach Analysis I – vollständige Induktion und Ungleichungen (2023)"),
                                         moduleID: 1, week: nil, courseTitle: "Testfach Analysis I")
        let s = RecordingSuggester.best(for: RecordingTaskContext(moduleID: 1, sheetWeek: 3, text: sheet + " und Ungleichungen", names: ["Testfach Analysis I"]),
                                        among: [titled, fitting])
        XCTAssertEqual(s?.video.id, "alt-2")
        XCTAssertEqual(s?.reason, "passt zu: vollständige, Induktion, Ungleichungen")
    }

    func testGeneralWordsAreNoMatch() {
        func one(_ title: String, _ text: String) -> RecordingSuggestion? {
            RecordingSuggester.best(for: RecordingTaskContext(moduleID: 1, sheetWeek: nil, text: text),
                                    among: [RecordingCandidate(courseID: "c1", video: OpencastVideo(id: "v", title: title), moduleID: 1, week: nil)])
        }
        XCTAssertNil(one("Zusammenfassung", "Zusammenfassung der Hinweise"))
        XCTAssertNil(one("Einführung und Organisatorisches", "Einführung: Organisatorisches zur Übung"))
        XCTAssertNil(one("Klausurvorbereitung – Fragestunde", "Fragestunde zur Klausurvorbereitung, Überblick"))
        XCTAssertNil(one("Nachtrag zur Zusammenfassung", "Nachtrag Zusammenfassungen Überblick Grundlagen"))
        XCTAssertNotNil(one("Zusammenfassung: Eigenwerte und Diagonalisierung", "Bestimmen Sie die Eigenwerte und prüfen Sie die Diagonalisierung"))
    }

    func testOtherOrUnknownModuleNever() throws {
        let text = "Bestimmen Sie die Grenzwerte der Folgen, Induktion und LR-Zerlegung"
        XCTAssertNil(RecordingSuggester.best(for: RecordingTaskContext(moduleID: 2, sheetWeek: 3, text: text), among: try candidates(module: 1)))
        XCTAssertNil(RecordingSuggester.best(for: RecordingTaskContext(moduleID: nil, sheetWeek: 3, text: text), among: try candidates(module: 1)))
        let unassigned = try candidates().map { RecordingCandidate(courseID: $0.courseID, video: $0.video, moduleID: nil, week: $0.week) }
        XCTAssertNil(RecordingSuggester.best(for: RecordingTaskContext(moduleID: 1, sheetWeek: 3, text: text), among: unassigned))
        XCTAssertEqual(RecordingSuggester.threshold, 1.5)
    }

    func testScriptSearchTokens() {
        XCTAssertEqual(ScriptSearchText.tokens("Bestimmen Sie die Grenzwerte der folgenden Folgen"), ["grenzwert", "folg"])
        XCTAssertEqual(ScriptSearchText.normalize("Unabh¨ angigkeit"), "Unabhängigkeit")
        XCTAssertEqual(ScriptSearchText.tokens("Unabh¨ angigkeit"), ["unabhängigkeit"])
    }
}

final class RecordingPlaybackTests: XCTestCase {
    private let u = URL(string: "https://oc.example.test/v.mp4")!
    private func video(_ qualities: [Int], player: Bool = true) -> OpencastVideo {
        OpencastVideo(id: "v1", title: "V", playerURL: player ? URL(string: "https://studip.test/plugins.php/opencastpluginluh/media/player/v1") : nil,
                      downloads: qualities.map { OpencastDownload(quality: "\($0)p", height: $0, url: URL(string: "https://oc.example.test/\($0).mp4")!) })
    }

    func testQualityChoice() {
        XCTAssertEqual(RecordingPlayback.quality(for: video([1080, 720, 480]))?.quality, "720p")
        XCTAssertEqual(RecordingPlayback.quality(for: video([1080, 480, 360]))?.quality, "480p")   // beste unter 1080p
        XCTAssertEqual(RecordingPlayback.quality(for: video([1080]))?.quality, "1080p")
        XCTAssertEqual(RecordingPlayback.quality(for: video([1080, 720, 480]), preferred: "1080p")?.quality, "1080p")
        XCTAssertEqual(RecordingPlayback.quality(for: video([720, 480]), preferred: "1080p")?.quality, "720p")
        XCTAssertNil(RecordingPlayback.quality(for: video([])))
    }

    func testLocalBeforeStreamBeforeWeb() {
        let v = video([1080, 720, 480])
        XCTAssertEqual(RecordingPlayback.source(for: v, downloaded: ["480p", "720p"]), .local(quality: "720p"))
        XCTAssertEqual(RecordingPlayback.source(for: v, downloaded: ["480p", "720p"], preferred: "480p"), .local(quality: "480p"))
        XCTAssertEqual(RecordingPlayback.source(for: v, downloaded: ["1080p"]), .local(quality: "1080p"))  // offline vor Stream
        // ausdruecklich gewaehlte, nicht geladene Fassung: deren Stream statt der geladenen Datei
        XCTAssertEqual(RecordingPlayback.source(for: v, downloaded: ["480p"], preferred: "1080p"),
                       .stream(URL(string: "https://oc.example.test/1080.mp4")!, quality: "1080p"))
        XCTAssertEqual(RecordingPlayback.source(for: v, downloaded: ["480p"], preferred: "480p"), .local(quality: "480p"))
        XCTAssertEqual(RecordingPlayback.source(for: v, downloaded: ["480p"], preferred: "360p"), .local(quality: "480p"))  // gibt es nicht
        XCTAssertEqual(RecordingPlayback.source(for: v, downloaded: []), .stream(URL(string: "https://oc.example.test/720.mp4")!, quality: "720p"))
        XCTAssertEqual(RecordingPlayback.source(for: video([]), downloaded: []), .webPlayer(URL(string: "https://studip.test/plugins.php/opencastpluginluh/media/player/v1")!))
        XCTAssertEqual(RecordingPlayback.source(for: video([], player: false), downloaded: []), .unavailable)
    }

    func testResumePosition() {
        XCTAssertNil(RecordingPlayback.resumePosition(saved: nil, duration: 3600))
        XCTAssertNil(RecordingPlayback.resumePosition(saved: 4, duration: 3600))
        XCTAssertEqual(RecordingPlayback.resumePosition(saved: 1234, duration: 3600), 1234)
        XCTAssertNil(RecordingPlayback.resumePosition(saved: 3590, duration: 3600))               // fast zu Ende: von vorn
        XCTAssertEqual(RecordingPlayback.resumePosition(saved: 300, duration: nil), 300)
        XCTAssertNil(RecordingPlayback.resumePosition(saved: .nan, duration: nil))
    }

    func testFilePathsAndStorage() {
        XCTAssertEqual(RecordingFilesLayout.relativePath(courseID: "0123456789abcdef0123456789abcdef", videoID: "Xyzab-12345-6789", quality: "720p"),
                       "files/0123456789abcdef0123456789abcdef/Xyzab-12345-6789-720p.mp4")
        let evil = RecordingFilesLayout.relativePath(courseID: "../..", videoID: "a/b", quality: "720p")
        XCTAssertFalse(evil.split(separator: "/").contains(".."))                        // kein Weg aus dem Ordner
        XCTAssertEqual(evil.split(separator: "/").count, 3)
        XCTAssertEqual(RecordingFilesLayout.resumeDataPath(courseID: "c", videoID: "v", quality: "480p"), "files/c/v-480p.mp4.resume")

        XCTAssertEqual(RecordingFilesLayout.storageWarning(fileSize: 1_000_000_000, freeBytes: 500_000_000),
                       "Nicht genug Speicherplatz: Die Aufzeichnung braucht 1,0 GB, frei sind 500 MB.")
        XCTAssertEqual(RecordingFilesLayout.storageWarning(fileSize: 800_000_000, freeBytes: 1_500_000_000),
                       "Wenig Speicherplatz: Nach dem Laden sind nur noch 700 MB frei.")
        XCTAssertNil(RecordingFilesLayout.storageWarning(fileSize: 800_000_000, freeBytes: 10_000_000_000))
        XCTAssertNil(RecordingFilesLayout.storageWarning(fileSize: nil, freeBytes: nil))
        XCTAssertEqual(RecordingFilesLayout.megabytes(412_300_000), "412 MB")
        XCTAssertEqual(RecordingFilesLayout.megabytes(1_240_000_000), "1,2 GB")
    }
}

final class RecordingFilesTests: XCTestCase {
    func testStoredFileNames() {
        XCTAssertEqual(RecordingFilesLayout.storedFile(course: "c1", name: "Xyzab-12345-6789-720p.mp4"),
                       RecordingStoredFile(course: "c1", video: "Xyzab-12345-6789", quality: "720p", partial: false))
        XCTAssertEqual(RecordingFilesLayout.storedFile(course: "c1", name: "v1-1080p.mp4.resume"),
                       RecordingStoredFile(course: "c1", video: "v1", quality: "1080p", partial: true))
        XCTAssertNil(RecordingFilesLayout.storedFile(course: "c1", name: "notiz.txt"))
        XCTAssertNil(RecordingFilesLayout.storedFile(course: "c1", name: "-720p.mp4"))
        XCTAssertNil(RecordingFilesLayout.storedFile(course: "c1", name: "ohne.mp4"))
    }

    func testOrphansOfDeselectedCourseOrRemovedVideo() {
        let index = RecordingsIndex(courses: [
            RecordingCourse(courseID: "c1", courseTitle: "Testfach A", status: .available, videos: [OpencastVideo(id: "v1", title: "Vorlesung 1")], lastChecked: start),
            RecordingCourse(courseID: "c3", courseTitle: "Testfach C", status: .noOpencast, lastChecked: start),
        ])
        let files = [RecordingStoredFile(course: "c1", video: "v1", quality: "720p", partial: false),
                     RecordingStoredFile(course: "c1", video: "v2", quality: "720p", partial: false),     // aus Opencast entfernt
                     RecordingStoredFile(course: "c2", video: "v7", quality: "480p", partial: true),      // Kurs abgewaehlt
                     RecordingStoredFile(course: "c3", video: "v8", quality: "480p", partial: false)]     // Kurs ohne Opencast
        XCTAssertEqual(RecordingFilesLayout.orphans(files, index: index).map(\.video), ["v2", "v7", "v8"])
        XCTAssertEqual(RecordingFilesLayout.orphans(files, index: RecordingsIndex()).count, 4)
    }

    func testSizeCacheForSevenDays() throws {
        let u = URL(string: "https://oc.example.test/a/res0720.mp4")!
        var cache = RecordingSizeCache()
        XCTAssertNil(cache.size(for: u, now: start))
        cache.set(412_300_000, for: u, now: start)
        XCTAssertEqual(cache.size(for: u, now: start.addingTimeInterval(6 * 86400)), 412_300_000)
        XCTAssertNil(cache.size(for: u, now: start.addingTimeInterval(7 * 86400)))           // nach 7 Tagen neu fragen
        XCTAssertNil(cache.size(for: u, now: start.addingTimeInterval(-60)))                // Uhr zurueckgestellt
        let b = URL(string: "https://oc.example.test/b.mp4")!
        cache.set(nil, for: b, now: start)
        XCTAssertEqual(cache.size(for: b, now: start), -1)                                   // unbekannt, aber gefragt
        let back = try RecordingSizeCache.decode(cache.encoded())
        XCTAssertEqual(back, cache)
        cache.prune(now: start.addingTimeInterval(8 * 86400))
        XCTAssertTrue(cache.entries.isEmpty)
    }
}

final class RecordingWeeksTests: XCTestCase {
    func testGroupedLikeWeekBlocks() throws {
        guard case .videos(let v) = OpencastParser.parse(html: try fixture("media-index-videos.html"), status: 200) else { return XCTFail() }
        let extra = OpencastVideo(id: "ohne", title: "Gastvortrag", created: day(2022, 5, 1))
        let courses = [RecordingCourse(courseID: "c1", courseTitle: "Testfach Analysis", status: .available, videos: v, lastChecked: start),
                       RecordingCourse(courseID: "c2", courseTitle: "Übung zu Testfach Analysis", status: .available, videos: [extra], lastChecked: start),
                       RecordingCourse(courseID: "c3", courseTitle: "Testfach Physik", status: .noOpencast, lastChecked: start)]
        let entries = RecordingWeeks.entries(courses, semesterStart: start)
        let groups = RecordingWeeks.grouped(entries)
        XCTAssertEqual(groups.map(\.week), [2, 3, nil])                                     // "Ohne Woche" zuletzt
        // Woche 2: Ergaenzung (erstellt 2022) vor der Zentraluebung (2026)
        XCTAssertEqual(groups[0].entries.map(\.video.id), ["Xyzab-12345-6789", "aaaaaaaa-0000-4000-8000-000000000002"])
        XCTAssertEqual(groups[2].entries.map(\.id), ["c2|ohne"])
        XCTAssertEqual(RecordingWeeks.counts(entries), [2: 2, 3: 1])
        XCTAssertEqual(entries.first?.week.source, .title)
    }
}
