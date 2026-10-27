import XCTest
@testable import UniFlowCore

/// Erkennung von Abgaben, Tests und Pruefungsterminen in Texten (`DueDetection`). Alle Texte sind erfunden und den
/// Formen echter Uebungsblaetter, Folien und Ankuendigungen nur nachgebildet.
final class DueDetectionTests: XCTestCase {

    private func day(_ iso: String) -> Int { BerlinClock.parseISODate(iso)! }

    /// LUH am 27.10.2026: Wintersemester 2026/27 (21 Tage vor Vorlesungsbeginn bis zum Tag vor dem Sommersemester)
    private func luh(_ today: String = "2026-10-27") -> DueDetection.Window {
        DueDetection.Window.current(university: "luh", today: day(today))!
    }

    private func detect(_ text: String, today: String = "2026-10-27", reference: String? = nil, name: String? = nil,
                        university: String = "luh") -> [DueDetection.Hit] {
        let w = DueDetection.Window.current(university: university, today: day(today))!
        return DueDetection.detect(text, context: .init(window: w, reference: reference.map(day), name: name))
    }

    private func summary(_ hits: [DueDetection.Hit]) -> [String] {
        hits.map { "\($0.date)\($0.time.map { " " + $0 } ?? "") \($0.kind.rawValue) \($0.label)" }
    }

    // MARK: Zeitraum

    func testWindowIsRunningSemesterPlusExamPeriod() {
        let w = luh()
        XCTAssertEqual(BerlinClock.isoDate(w.from), "2026-09-21")
        XCTAssertEqual(BerlinClock.isoDate(w.to), "2027-04-04")
        XCTAssertEqual(w.semesters, [DueDetection.SemesterKey(winter: true, year: 2026)])
        let hi = DueDetection.Window.current(university: "hildesheim", today: day("2026-10-27"))!
        XCTAssertEqual(BerlinClock.isoDate(hi.from), "2026-09-28")
        XCTAssertEqual(BerlinClock.isoDate(hi.to), "2027-04-04")
        // Uebergang: kurz vor dem Sommersemester gelten beide
        let both = luh("2027-03-25")
        XCTAssertEqual(both.semesters, [DueDetection.SemesterKey(winter: true, year: 2026), DueDetection.SemesterKey(winter: false, year: 2027)])
        XCTAssertNil(DueDetection.Window.current(university: "unbekannt", today: day("2026-10-27")))
    }

    func testSemesterMentions() {
        XCTAssertEqual(DueDetection.semesters(in: "Mathematik I – Wintersemester 2020/21"), [.init(winter: true, year: 2020)])
        XCTAssertEqual(DueDetection.semesters(in: "WS 20/21, SoSe 2022, SS22, WiSe 2026/2027"),
                       [.init(winter: true, year: 2020), .init(winter: false, year: 2022), .init(winter: true, year: 2026)])
        XCTAssertEqual(DueDetection.semesters(in: "Klasse 2022"), [])
        XCTAssertEqual(DueDetection.headSemester(firstPage: "Übungsblatt 3\nWintersemester 2020/21", name: nil), .init(winter: true, year: 2020))
        XCTAssertEqual(DueDetection.headSemester(firstPage: "Übungsblatt 3", name: "Probeklausur_SoSe22.pdf"), .init(winter: false, year: 2022))
        XCTAssertNil(DueDetection.headSemester(firstPage: "Übungsblatt 3", name: "blatt3.pdf"))
    }

    // MARK: Beispiele wie beim Inhaber (erfunden)

    func testProbeKurztestSentence() {
        let hits = detect("Für den ersten Probe-Kurztest am 09.11.2026 ist der Stoff bis Kapitel 2 wichtig.")
        XCTAssertEqual(summary(hits), ["2026-11-09 test Probe-Kurztest"])
        XCTAssertTrue(hits[0].snippet.contains("Probe-Kurztest am 09.11.2026"))
    }

    func testKurzklausurWithWeekdayAndRegistrationNote() {
        // "Anmeldung über Stud.IP" ist ein Hinweis, kein Anmeldeschluss
        let hits = detect("Kurzklausurtermin – Datum: Fr, 11.12.2026, Anmeldung über Stud.IP")
        XCTAssertEqual(summary(hits), ["2026-12-11 klausur Kurzklausur"])
    }

    func testKeywordWithoutDateGivesNothing() {
        XCTAssertEqual(detect("Organisatorisches\nEs gibt 3 Kurztestate (je 20 Minuten) im Semester\nBestehensgrenze 50 %"), [])
        XCTAssertEqual(detect("Die Abgabe erfolgt über Stud.IP in Zweiergruppen."), [])
    }

    func testDateWithoutKeywordGivesNothing() {
        XCTAssertEqual(detect("Vorlesung am 02.11.2026 im Raum F102, danach Übung."), [])
        XCTAssertEqual(detect("Folie 12 – Stand 26.10.2026"), [])
    }

    func testSemesterPlanTable() {
        let text = """
            Semesterplan
            Woche Datum Thema
            1 19.10. Einführung
            3 02.11. Grundlagen, Kurztestat 1
            5 16.11. Kapitel 3 Kurztestat 2
            7 30.11. Kapitel 5
            9 14.12. Wiederholung Kurztestat 3
            11 11.01. Kapitel 8
            """
        XCTAssertEqual(summary(detect(text, reference: "2026-10-15")),
                       ["2026-11-02 test Kurztestat 1", "2026-11-16 test Kurztestat 2", "2026-12-14 test Kurztestat 3"])
    }

    func testTableWithOneCellPerLine() {
        // PDF-Text mit einer Zelle je Zeile: Datum am Zeilenende, Schluesselwort am Anfang der naechsten
        let text = "Termine\n02.11.\nKurztestat 1\n09.11.\nKapitel 3\n16.11.\nKurztestat 2"
        XCTAssertEqual(summary(detect(text)), ["2026-11-02 test Kurztestat 1", "2026-11-16 test Kurztestat 2"])
    }

    func testOldSemesterDatesAreDropped() {
        // alte Probe-Kurzklausur mit Jahr: ausserhalb des Semesters
        XCTAssertEqual(detect("Alte Probe-Kurzklausur vom 14.11.2023 mit Lösungsskizze"), [])
        XCTAssertEqual(detect("Klausur am 15.02.2026, Nachklausur am 30.03.2026"), [])
        // ohne Jahr, aber Datei von 2022: der Tag liegt nicht im laufenden Semester
        XCTAssertEqual(detect("Abgabe bis 03.11.", reference: "2022-10-20"), [])
        XCTAssertEqual(summary(detect("Abgabe bis 03.11.", reference: "2026-10-20")), ["2026-11-03 abgabe Abgabe"])
        // genannter Wochentag passt nicht zu diesem Jahr (09.11.2023 war ein Donnerstag)
        XCTAssertEqual(detect("Abgabe: Do, 09.11."), [])
        XCTAssertEqual(summary(detect("Abgabe: Mo, 09.11.")), ["2026-11-09 abgabe Abgabe"])
    }

    func testYearChange() {
        let hits = detect("Abgabe bis Fr, 08.01. um 12 Uhr\nDie Klausur findet am 15.02. statt.\nAbgabe Blatt 9: 21.12.",
                          today: "2026-12-20", reference: "2026-12-15")
        XCTAssertEqual(summary(hits), ["2026-12-21 abgabe Abgabe Blatt 9", "2027-01-08 12:00 abgabe Abgabe", "2027-02-15 klausur Klausur"])
        // Bereich ueber den Jahreswechsel: Ende zaehlt bei Abgaben
        XCTAssertEqual(summary(detect("Bearbeitungszeit und Abgabe 28.12.–08.01.2027", today: "2026-12-20")), ["2027-01-08 abgabe Abgabe"])
    }

    // MARK: Datumsformen und Uhrzeiten

    func testDateForms() {
        XCTAssertEqual(summary(detect("Abgabe: 05.11.2026, 23:59 Uhr")), ["2026-11-05 23:59 abgabe Abgabe"])
        XCTAssertEqual(summary(detect("Abgabe bis 5.11. 12:00")), ["2026-11-05 12:00 abgabe Abgabe"])
        XCTAssertEqual(summary(detect("Die Hausarbeit ist bis zum 15. März 2027 einzureichen.")), ["2027-03-15 abgabe Hausarbeit"])
        XCTAssertEqual(summary(detect("Testat am 2. November")), ["2026-11-02 test Testat"])
        XCTAssertEqual(summary(detect("Deadline 2026-11-20T12:00")), ["2026-11-20 12:00 abgabe Deadline"])
        XCTAssertEqual(summary(detect("Assignment 4 due: November 9, 2026, 11:59 PM")), ["2026-11-09 23:59 abgabe Assignment 4"])
        XCTAssertEqual(summary(detect("Submission deadline: 12 November 2026")), ["2026-11-12 abgabe Abgabe"])
        XCTAssertEqual(summary(detect("Einsendeschluss ist Montag, der 16.11.2026.")), ["2026-11-16 abgabe Einsendeschluss"])
        XCTAssertEqual(summary(detect("Einsendeschluss: Montag, 16.11.2026")), ["2026-11-16 abgabe Einsendeschluss"])
        XCTAssertEqual(summary(detect("Abgabe 05.11.26 bis 10 Uhr")), ["2026-11-05 10:00 abgabe Abgabe"])
    }

    func testNumberingIsNoDate() {
        XCTAssertEqual(detect("Abgabe: Aufgabe 3.11. und 3.12. aus dem Skript"), [])
        XCTAssertEqual(detect("Abgabe Aufgabe 2.1."), [])
        XCTAssertEqual(detect("Klausurrelevant: Kapitel 2.11. bis 3.4."), [])
    }

    func testBlockedContexts() {
        XCTAssertEqual(detect("Stoff der Klausur: Folien vom 02.11."), [])
        XCTAssertEqual(detect("Klausur (Stand: 01.10.2026)"), [])
        XCTAssertEqual(detect("Die Lösungen zum Kurztestat werden am 10.11. veröffentlicht."), [])
        XCTAssertEqual(detect("Rückgabe der korrigierten Abgaben am 12.11."), [])
        XCTAssertEqual(detect("Die Vorlesung am 02.11.2026 fällt due to illness aus."), [])
        XCTAssertEqual(detect("02.11.2026: Prüfung der Voraussetzungen von Satz 3"), [])
        XCTAssertEqual(detect("Test-Driven Development (09.11.2026)"), [])
        XCTAssertEqual(detect("Klausur-Vorbereitung am 01.02.2027"), [])
        XCTAssertEqual(summary(detect("Kurztestat-Termin: 16.11.2026")), ["2026-11-16 test Kurztestat"])
    }

    func testKindsAndRegistration() {
        XCTAssertEqual(summary(detect("Anmeldung zur Klausur vom 01.12. bis 15.12.2026")), ["2026-12-15 anmeldung Anmeldung"])
        XCTAssertEqual(summary(detect("Anmeldeschluss: 20.01.2027")), ["2027-01-20 anmeldung Anmeldeschluss"])
        XCTAssertEqual(summary(detect("Bitte bis 20.01.2027 im QIS anmelden.")), ["2027-01-20 anmeldung Anmeldung"])
        XCTAssertEqual(summary(detect("Klausur: 10.02.2027 (Nachklausur: 31.03.2027)")),
                       ["2027-02-10 klausur Klausur", "2027-03-31 klausur Nachklausur"])
        XCTAssertEqual(summary(detect("Frist für die Bonuspunkte: 30.11.2026")), ["2026-11-30 sonstiges Frist"])
    }

    func testSentenceBoundaries() {
        // "aus." beendet den Satz: die Abgabe gehoert nicht zum Ausfall am 03.11.
        XCTAssertEqual(summary(detect("Die Vorlesung am 03.11. fällt aus. Die Abgabe von Blatt 3 ist am 10.11.")),
                       ["2026-11-10 abgabe Abgabe Blatt 3"])
        // Abkuerzungen sind kein Satzende
        XCTAssertEqual(summary(detect("Abgabe bzw. Upload: 12.11.2026")), ["2026-11-12 abgabe Abgabe"])
        XCTAssertEqual(summary(detect("Analysis I – Übungsblatt 2 – Ausgabe: 26.10.2026 – Abgabe: 02.11.2026, 12:00 Uhr")),
                       ["2026-11-02 12:00 abgabe Abgabe Blatt 2"])
        XCTAssertEqual(summary(detect("Due date: Monday, 9 November 2026, 11:59 PM")), ["2026-11-09 23:59 abgabe Abgabe"])
        XCTAssertEqual(summary(detect("Testat-Termine: 02.11., 16.11., 30.11.")),
                       ["2026-11-02 test Testat", "2026-11-16 test Testat", "2026-11-30 test Testat"])
        XCTAssertEqual(detect("Prüfungszeitraum: 08.02.–20.02.2027"), [])
        XCTAssertEqual(summary(detect("Termin der Nachklausur: Fr, 26.03.2027 10:00 Uhr, Raum F102")), ["2027-03-26 10:00 klausur Nachklausur"])
        XCTAssertEqual(summary(detect("Test 3 (online, 45 min): 07.12.2026–11.12.2026")), ["2026-12-07 test Test 3"])
    }

    func testDateListAfterKeyword() {
        XCTAssertEqual(summary(detect("Die Kurztestate finden am 02.11., 16.11. und 30.11. in der Übung statt.")),
                       ["2026-11-02 test Kurztestat", "2026-11-16 test Kurztestat", "2026-11-30 test Kurztestat"])
    }

    func testLineWrapInSentence() {
        let text = "Der Stoff bis hier gehört zum zweiten Probe-\nKurztest am\n16.11.2026 im Hörsaal."
        XCTAssertEqual(summary(detect(text)), ["2026-11-16 test Probe-Kurztest"])
        // ohne Verbindungswort am Zeilenende kein Paar ueber die Zeile
        XCTAssertEqual(detect("Kurztestat\nVorlesung 02.11.2026"), [])
    }

    func testFileNames() {
        XCTAssertEqual(DueDetection.nameText("Blatt 3 Abgabe 05.11.pdf"), "Blatt 3 Abgabe 05.11.")
        XCTAssertEqual(summary(detect(DueDetection.nameText("Blatt 3 Abgabe 05.11.pdf"), reference: "2026-10-28")), ["2026-11-05 abgabe Abgabe Blatt 3"])
        XCTAssertEqual(summary(detect(DueDetection.nameText("Uebung_04_Abgabe_2026-11-12.pdf"))), ["2026-11-12 abgabe Abgabe Blatt 4"])
        XCTAssertEqual(detect(DueDetection.nameText("Vorlesung_05.11.pdf")), [])
    }

    func testSheetNumberFromPageHead() {
        let page = "Übungsblatt 3\nLineare Algebra I\nAbgabe: bis Mo, 09.11.2026, 12:00 Uhr im Kasten vor F 411"
        XCTAssertEqual(summary(detect(page)), ["2026-11-09 12:00 abgabe Abgabe Blatt 3"])
    }

    func testAnnouncementHildesheim() {
        let text = "Klausurtermin\nLiebe Studierende, die Klausur findet am 10.02.2027 um 10 Uhr im Audimax statt. Anmeldung bis 20.01.2027 im LSF."
        XCTAssertEqual(summary(detect(text, reference: "2026-10-26", university: "hildesheim")),
                       ["2027-01-20 anmeldung Anmeldung", "2027-02-10 10:00 klausur Klausur"])
    }

    func testDecomposedUmlautsAndSoftHyphen() {
        // PDF-Text mit zerlegten Umlauten und Trennstrich am Zeilenende
        XCTAssertEqual(summary(detect("Pru\u{308}fungstermin: 12.02.2027")), ["2027-02-12 klausur Prüfung"])
        XCTAssertEqual(summary(detect("Die Abga-\nbe ist am 05.11.2026.")), ["2026-11-05 abgabe Abgabe"])
    }

    // MARK: Ueberschrift mit Unterpunkten

    func testHeadingWithSubPoints() {
        // Zeile nur aus Aufzaehlungszeichen und Schluesselwort, das Datum im Unterpunkt darunter
        let text = """
            ◼ Kurzklausurtermin
            ❑ Datum: Do, 03.12.2026,
            ❑ Anmeldung über das Prüfungsportal
            ❑ Raum + Uhrzeit werden im Portal bekanntgegeben
            ◼ Übungsbetrieb
            ❑ Beginn in der zweiten Vorlesungswoche
            """
        let hits = detect(text)
        XCTAssertEqual(summary(hits), ["2026-12-03 klausur Kurzklausur"])
        XCTAssertTrue(hits.first?.snippet.contains("Datum: Do, 03.12.2026") ?? false, "\(hits)")
        // andere Zeichen und Komposita; ein Datum nach "Termin:" geht dem ersten vor
        XCTAssertEqual(summary(detect("• Abgabetermin\n  ◦ Ausgabe der Aufgabe am 05.11.2026\n  ◦ Termin: Fr, 20.11.2026, 12:00 Uhr\n• Rückfragen im Forum")),
                       ["2026-11-20 12:00 abgabe Abgabe"])
        // Ueberschrift ohne eigenes Zeichen, Unterpunkte mit
        XCTAssertEqual(summary(detect("Klausurtermin\n- Datum: 09.02.2027\n- Dauer: 90 Minuten")), ["2027-02-09 klausur Klausur"])
        // Datum auf der Folgezeile des Unterpunkts
        XCTAssertEqual(summary(detect("◼ Testattermine\n❑ Termin:\n17.11.2026 in den Tutorien")), ["2026-11-17 test Testat"])
    }

    func testHeadingCounterChecks() {
        // der naechste Hauptpunkt beendet die Unterpunkte: sein Datum gehoert nicht zur Ueberschrift
        XCTAssertEqual(detect("◼ Klausurtermin\n❑ wird in der Vorlesung bekanntgegeben\n◼ Übungsbetrieb\n❑ Beginn: 02.11.2026"), [])
        // gleiches Zeichen wie die Ueberschrift: Nachbar, kein Unterpunkt
        XCTAssertEqual(detect("• Kurzklausur\n• Vorlesungsbeginn: 19.10.2026"), [])
        // Unterpunkt mit eigenem Schluesselwort: das Datum gehoert ihm
        XCTAssertEqual(summary(detect("◼ Klausurtermine\n❑ Probeklausur am 26.11.2026\n❑ Klausur: Datum folgt")), ["2026-11-26 klausur Probeklausur"])
        // ohne Unterpunkte wie bisher
        XCTAssertEqual(detect("◼ Abgabetermin\nDie Vorlesung am 12.11.2026 fällt aus."), [])
        // Einsicht im Unterpunkt: kein Termin
        XCTAssertEqual(detect("◼ Klausur\n❑ Einsicht: 03.03.2027"), [])
        // Folien und andere Ereignisse in Unterpunkten geben der Ueberschrift kein Datum
        XCTAssertEqual(detect("• Abgabe\n  – über das Portal als PDF\n  – Folien vom 02.11. beachten"), [])
        XCTAssertEqual(detect("◼ Klausur\n❑ Stoff: Kapitel 1–6\n❑ Die Vorlesung am 02.11. entfällt"), [])
    }

    // MARK: Testate im Semesterplan

    func testTestatColumnInSemesterPlan() {
        let plan = """
            Semesterplan Programmierkurs
            Nr Datum Thema Tutorien & Testate
            1 23.10. Organisation, Werkzeuge
            3 06.11. Schleifen und Felder (…) T1: Kontrollfluss (VL 1-3) - 16.11 bis 19.11.
            5 20.11. Recursion (base cases, accumulators, local helpers, tests), recipe for lists
            7 04.12. Zeiger und Speicher (…) T2: Felder und Zeiger (VL 4-6) - 14.12 - 17.12.
            9 08.01. Dateien und Ströme T3: Speicher (VL 7-8) - 18.01. bis 21.01.
            11 22.01. Wiederholung
            """
        let hits = detect(plan, reference: "2026-10-15")
        XCTAssertEqual(summary(hits), ["2026-11-16 test Testat T1 (bis 19.11.)", "2026-12-14 test Testat T2 (bis 17.12.)",
                                       "2027-01-18 test Testat T3 (bis 21.01.)"])
        XCTAssertTrue(hits.first?.snippet.contains("T1: Kontrollfluss (VL 1-3) - 16.11 bis 19.11.") ?? false, "\(hits)")
        // derselbe Zeitraum noch einmal im Text: ein Treffer
        XCTAssertEqual(summary(detect(plan + "\n\nDas Testat T1 findet vom 16.11. bis 19.11. statt.", reference: "2026-10-15")).first,
                       "2026-11-16 test Testat T1 (bis 19.11.)")
        XCTAssertEqual(detect(plan + "\n\nDas Testat T1 findet vom 16.11. bis 19.11. statt.", reference: "2026-10-15").count, 3)
    }

    func testTestatMarkerNeedsTestatHeader() {
        // Kopf ohne Testate: "T1:" ist kein Testat
        XCTAssertEqual(detect("Nr Datum Thema Übungen\n3 06.11. Schleifen T1: Kontrollfluss - 16.11 bis 19.11.", reference: "2026-10-15"), [])
        // ausserhalb einer Tabelle
        XCTAssertEqual(detect("Gruppe T1: Raum F102, 16.11. bis 19.11."), [])
        // Zeile ohne Datum hinter "T1:": das Datum der Vorlesung davor gehoert nicht zum Testat
        XCTAssertEqual(detect("Woche Datum Thema Testate\n3 06.11. Schleifen T1: Kontrollfluss\n5 20.11. Rekursion", reference: "2026-10-15"), [])
        // Liste statt Tabelle: wie bisher
        XCTAssertEqual(summary(detect("Termine der Testate:\n16.11.2026, 14.12.2026")), ["2026-11-16 test Testat", "2026-12-14 test Testat"])
        XCTAssertEqual(summary(detect("Termine der Testate\nT1: 16.11.2026\nT2: 14.12.2026")), ["2026-11-16 test Testat T1", "2026-12-14 test Testat T2"])
    }

    func testRangeStartWithoutDot() {
        XCTAssertEqual(summary(detect("Testat 14.12 - 17.12.")), ["2026-12-14 test Testat"])
        XCTAssertEqual(summary(detect("Abgabe 16.11 bis 19.11.")), ["2026-11-19 abgabe Abgabe"])
        // ohne Bereich kein Datum
        XCTAssertEqual(detect("Abgabe 16.11 im Kasten"), [])
        XCTAssertEqual(detect("Klausurrelevant: Kapitel 2.11 bis 3.4."), [])
    }

    // MARK: Englisch klein "test"

    func testLowercaseEnglishTestNeedsExamContext() {
        // Themenliste in Klammern
        XCTAssertEqual(detect("Recursion (base cases, accumulators, local helpers, tests), recipe for lists 20.11.2026"), [])
        // Wortgruppen
        XCTAssertEqual(detect("Write unit tests until 20.11.2026"), [])
        XCTAssertEqual(detect("Add tests for the parser by 20.11.2026"), [])
        // ohne Pruefungsbezug
        XCTAssertEqual(detect("we run the tests again 20.11.2026"), [])
        // mit klarem Bezug: "test on <Datum>", "test: <Datum>", Pruefungswort im Satz
        XCTAssertEqual(summary(detect("The second test on 26.11.2026 covers recursion.")), ["2026-11-26 test Test"])
        XCTAssertEqual(summary(detect("Next test: 03.12.2026, 10:00")), ["2026-12-03 10:00 test Test"])
        XCTAssertEqual(summary(detect("As announced for the exam, the test 10.12.2026 is mandatory.")), ["2026-12-10 test Test"])
        // gross geschrieben wie bisher
        XCTAssertEqual(summary(detect("Tests am 17.12.2026 in der Übung")), ["2026-12-17 test Test"])
    }

    // MARK: Zeitraum nach "Klausuren", "Pruefungen", "Pruefungszeitraum"

    func testRangeAfterPluralExamsIsNoExamDay() {
        // Absatz ueber den Meldezeitraum: der Zeitraum nach "Klausuren" ist die Anmeldung, das Ende zaehlt
        let text = """
            Anmeldung zur Teilklausur
            Die Anmeldung erfolgt nur im Melde- und Rücktrittszeitraum über das Prüfungsportal. Dieser unterscheidet sich von den „regulären“ Klausuren (16.11.-27.11.) und wird in der Vorlesung bekanntgegeben.
            """
        XCTAssertEqual(summary(detect(text)), ["2026-11-27 anmeldung Anmeldung"])
        XCTAssertEqual(summary(detect("Meldezeitraum wie bei allen Prüfungen: 16.11.–27.11.2026")), ["2026-11-27 anmeldung Anmeldung"])
        XCTAssertEqual(summary(detect("Wer sich nicht rechtzeitig angemeldet hat, kann nicht teilnehmen. Es gelten die Zeiten wie bei den Prüfungen (16.11.–27.11.).")),
                       ["2026-11-27 anmeldung Anmeldung"])
        // ohne Anmeldung in den zwei Saetzen davor: kein Termin
        XCTAssertEqual(detect("Die Kurzklausuren ersetzen nicht die regulären Klausuren (01.02.–12.02.2027)."), [])
        XCTAssertEqual(detect("Die Anmeldung erfolgt online. Der Stoff umfasst alle Kapitel der Vorlesung. Hilfsmittel sind nicht erlaubt. "
                              + "Es gelten die Termine der regulären Klausuren (16.11.-27.11.)."), [])
        // Anmeldung mit eigenem Datum: der Zeitraum nach "Klausuren" ist die Pruefungszeit
        XCTAssertEqual(summary(detect("Prüfungsanmeldung: 16.11.–27.11.2026 im Portal\nKlausuren: 01.02.–12.02.2027")),
                       ["2026-11-27 anmeldung Anmeldung"])
        // "Pruefungszeitraum" ist nie ein Klausurtag und nie die Anmeldung
        XCTAssertEqual(detect("Die Prüfungsanmeldung erfolgt im Portal. Prüfungszeitraum: 01.02.–12.02.2027"), [])
        XCTAssertEqual(detect("Klausur im Prüfungszeitraum 01.02.–12.02.2027"), [])
        // einzelner Tag bleibt ein Klausurtag
        XCTAssertEqual(summary(detect("Die Klausuren finden am 03.02.2027 statt.")), ["2027-02-03 klausur Klausur"])
        XCTAssertEqual(summary(detect("Klausur in der Prüfungsphase am 03.02.2027")), ["2027-02-03 klausur Klausur"])
    }
}
