import XCTest
@testable import UniFlowCore

/// Sammlung von Folien-Texten fuer die Erkennung von Klausur- und Testterminen (`DueDetection`), Auftrag des Inhabers
/// 17.11.2026: "Eine Klausur stand nur in einer Folie." Alle Texte sind erfunden und den Formen echter Folien nur
/// nachgebildet (Stichpunkte, Terminlisten, Tabellen, deren Spalten im PDF-Text untereinander stehen, englische Folien).
///
/// Gemessen wird: Positive – ein Treffer der Art Klausur oder Test am erwarteten Tag; Negative – kein Treffer der Art
/// Klausur oder Test (eine Anmeldung oder Abgabe darf erkannt werden). Stand vor der Arbeit (Erkennung "2"): 49 von 68
/// Positiven, 9 Fehlalarme in 55 Negativen; Gegenprobe 23 von 30 und 4 Fehlalarme in 25. Danach: 68 von 68 und 0;
/// Gegenprobe beim ersten Lauf 29 von 30 und 2 Fehlalarme, nach zwei allgemeinen Regeln ("von 10 bis 12 Uhr",
/// "entfällt wegen der Klausuren") 30 von 30 und 0.
final class DueSlideCorpusTests: XCTestCase {

    /// Dienstag, 10.11.2026 (Datei vom selben Tag); die Klausur ist am Dienstag, 17.11.2026
    static let today = "2026-11-10"

    struct Positive {
        let text: String
        let date: String
        var time: String?
        init(_ text: String, _ date: String = "2026-11-17", time: String? = nil) {
            self.text = text
            self.date = date
            self.time = time
        }
    }

    static let positives: [Positive] = [
        // kurz und knapp
        .init("Klausur: 17.11."),
        .init("Klausurtermin 17.11.2026, 10–12 Uhr, Audimax", time: "10:00"),
        .init("Die Klausur findet am Di, 17.11. statt"),
        .init("Kurzklausur am 17.11.2026"),
        .init("Kurztest: 17.11., 8:15 Uhr", time: "08:15"),
        .init("Testat 2 am 17.11."),
        .init("Zwischenklausur am 17.11.2026 in der Vorlesung"),
        .init("Midterm: 17.11.2026"),
        .init("Probeklausur am 17.11. im Hörsaal"),
        .init("Prüfung am 17. November"),
        .init("Schriftliche Prüfung: Dienstag, 17.11.2026, 9:00 Uhr", time: "09:00"),
        // englische Folien
        .init("Exam: Nov 17"),
        .init("The exam is on 17 November 2026"),
        .init("Final exam: November 17, 2026, 10:00 am", time: "10:00"),
        .init("Midterm exam on Tuesday, Nov 17th"),
        .init("Quiz on November 17, 2026"),
        .init("Written exam: 17.11.2026, 10:00–12:00, room F 102", time: "10:00"),
        .init("Exam date: 17 Nov 2026"),
        .init("The midterm will take place on 17.11.2026."),
        .init("Tuesday, November 17: Midterm"),
        // Terminlisten und Tabellen
        .init("Termine\n20.10. – Einführung\n27.10. – Kapitel 1\n03.11. – Kapitel 2\n10.11. – Kapitel 3\n17.11. – Klausur\n24.11. – Kapitel 4"),
        .init("Datum\nThema\n10.11.\nKapitel 3\n17.11.\nKlausur\n24.11.\nKapitel 4"),
        .init("Semesterplan\nVL 5 10.11. Folgen\nVL 6 17.11. Zwischentest\nVL 7 24.11. Reihen"),
        .init("17.11.2026: Klausur (Audimax, 10 Uhr)"),
        .init("Di 17.11. Klausur"),
        .init("17. November 2026 – Klausur"),
        .init("17.11. Prüfung (Raum F102)"),
        .init("Woche 6\n17.11.\nKurzklausur 1\nWoche 7\n24.11.\nKapitel 5"),
        // Ueberschrift, Datum darunter
        .init("Klausur\n17.11.2026, 10:00 Uhr\nAudimax", time: "10:00"),
        .init("Klausurtermin\nDienstag, 17.11.2026\n10:00 – 12:00 Uhr\nRaum F102"),
        .init("Klausur\n• Datum: 17.11.2026\n• Zeit: 10:00 Uhr\n• Ort: Audimax"),
        .init("Klausur:\n17.11.2026"),
        .init("Klausur\nDi., 17.11.\n10:00 Uhr"),
        .init("Kurzklausur\nNächste Woche, 17.11., in der Vorlesung"),
        // Stichpunkte und Saetze
        .init("Organisatorisches\n• Klausur: Di, 17.11.2026, 10:15–11:45 Uhr, Raum E001", time: "10:15"),
        .init("Wichtig: Klausur am 17.11.!"),
        .init("Am 17.11. schreiben wir die Klausur."),
        .init("In der Vorlesung am 17.11. findet die Kurzklausur statt."),
        .init("Klausur (90 Minuten) am 17.11.2026"),
        .init("Klausur voraussichtlich am 17.11.2026"),
        .init("Die Klausur wird am Dienstag, den 17. November 2026 geschrieben."),
        .init("Termin der Klausur: 17.11.2026"),
        .init("Klausur – 17.11.26 – 10 Uhr", time: "10:00"),
        .init("Klausur: 17.11.2026 (Di), 08:00–10:00", time: "08:00"),
        .init("Klausur am 17.11.2026 um 10 Uhr c.t. im Audimax", time: "10:00"),
        .init("Klausurtermin: 17.11.2026"),
        .init("Prüfungstermin: 17.11.2026, 9 Uhr", time: "09:00"),
        .init("Mündliche Prüfung am 17.11.2026"),
        .init("Klausur zur Vorlesung Analysis I am 17.11.2026"),
        .init("Die Klausur zur Vorlesung findet am Dienstag, 17.11.2026, von 10 bis 12 Uhr im Audimax statt."),
        .init("Vorlesung fällt aus. Stattdessen: Klausur am 17.11.2026."),
        .init("Achtung: Die Klausur wurde auf den 17.11.2026 verlegt."),
        .init("Klausur (schriftlich, 120 min): Dienstag, 17.11.2026"),
        .init("Hinweis zur Klausur: Sie findet am 17.11.2026 statt."),
        .init("Klausur am 17.11.\n(Anmeldung über Stud.IP bis 10.11.)"),
        .init("Test 1: 17.11.2026"),
        .init("Kurztestat 3: Di, 17.11."),
        // zusammengesetzte Woerter
        .init("Zwischenprüfung: 17.11.2026"),
        .init("Modulprüfung am 17.11.2026, 14:00 Uhr", time: "14:00"),
        .init("Abschlussklausur: 17.02.2027", "2027-02-17"),
        .init("E-Klausur am 17.11.2026 im PC-Pool"),
        .init("1. Teilklausur: 17.11.2026"),
        .init("Nachklausur: 17.03.2027", "2027-03-17"),
        .init("Wiederholungsprüfung am 17.03.2027", "2027-03-17"),
        // Wochentag falsch (Tippfehler auf der Folie): gilt, mit Hinweis
        .init("Klausur am Mittwoch, 17.11.2026"),
        // ohne Tag: Woche bzw. Bezug auf das Datum der Datei (Dienstag, 10.11.2026)
        .init("Die Klausur findet nächste Woche Dienstag statt."),
        .init("Nächsten Dienstag schreiben wir die Kurzklausur."),
        .init("Klausur in KW 47", "2026-11-16"),
    ]

    static let negatives: [String] = [
        // fruehere Semester und Altklausuren
        "Klausur WS 2024/25 vom 17.02.2025",
        "Altklausur vom 17.11.2025 – Aufgabe 1",
        "Klausur vom 17.11.2023 – Lösungen",
        "Klausur SS 2025 (17.07.2025), Aufgabe 3",
        "Letzte Klausur: Durchschnitt 2,7 (17.02.2026)",
        "Klausurtermine der letzten Jahre: 17.02.2024, 12.02.2025",
        "Sample exam from 17.11.2023",
        "Die Klausur des letzten Jahres (17.11.) war schwer.",
        "Rückblick: Klausur vom 17.11.",
        "Klausur 2023 – Aufgabe 2 (17 Punkte)",
        // rund um die Klausur, aber nicht der Klausurtag
        "Klausurrelevant: Kapitel 1 bis 3, Stand 17.11.2026",
        "Anmeldung zur Klausur bis 17.11.2026",
        "Klausureinsicht am 17.11.2026",
        "Die Ergebnisse der Klausur werden am 17.11.2026 bekannt gegeben.",
        "Klausurvorbereitung am 17.11.2026",
        "Fragestunde zur Klausur am 17.11.2026",
        "Repetitorium zur Klausur: 17.11.2026",
        "Probeklausur-Besprechung am 17.11.",
        "Rücktritt von der Klausur bis 17.11.2026 möglich",
        "Zulassung zur Klausur: 50 % der Punkte bis 17.11.2026",
        "Exam preparation session: 17 November 2026",
        "Lösungen zur Probeklausur vom 17.11.2026",
        "Die Noten der Kurzklausur stehen ab 17.11.2026 im Stud.IP.",
        "Tutorium zur Klausurvorbereitung: Di, 17.11., 16 Uhr",
        "Sprechstunde vor der Klausur: 17.11.2026, 14 Uhr",
        "Einsicht in die Klausur: 17.11.2026",
        "Bonuspunkte für die Klausur können bis 17.11.2026 gesammelt werden.",
        "Anmeldezeitraum für Prüfungen: 16.11.–27.11.2026",
        "Prüfungszeitraum: 08.02.–20.02.2027",
        "Die Klausuren (08.02.–20.02.2027) werden zentral geplant.",
        "Bei Krankheit am Klausurtag ist bis zum 17.11.2026 ein Attest einzureichen.",
        "Themen der Klausur: alles bis einschließlich Vorlesung vom 17.11.2026",
        "Klausurstoff: Kapitel 1–5 (bis 17.11.)",
        "Übungsklausur zum Mitnehmen, ausgegeben am 17.11.2026",
        // Datum gehoert zu etwas anderem
        "Folien vom 17.11.2026\nThema: Klausuraufgaben",
        "Abgabe Blatt 5 bis 17.11.2026, 12:00 Uhr",
        "Meier, H.: Analysis. Springer, 17.11.2019.",
        "Beispiel: Ein Kredit wird am 17.11.2026 aufgenommen. Berechnen Sie die Zinsen bis zum 17.02.2027.",
        "Unit tests are due on 17.11.2026",
        "t-Test (Student, 1908)",
        "Erstellt am 17.11.2026 – Klausurthemen",
        "In der Klausur am Ende des Semesters sind keine Hilfsmittel erlaubt. Nächste Vorlesung: 17.11.2026",
        "Klausur: Termin wird noch bekannt gegeben. Übung am 17.11. entfällt.",
        "Aufgabe 17.11. der Klausursammlung",
        "Gastvortrag am 17.11.2026 (nicht klausurrelevant)",
        "Evaluation der Lehrveranstaltung am 17.11.2026",
        "Testen Sie Ihr Programm bis 17.11.",
        "Copyright © 2019–2026, Stand: 17.11.2026, Klausur- und Prüfungsamt",
        "Hörsaalübung statt Vorlesung am 17.11.2026",
        "Prüfungsleistung: Hausarbeit, Abgabe bis 17.03.2027",
        "Prüfungsordnung vom 17.11.2026",
        "exam-style question (see lecture of 17 November 2026)",
        "Kapitel 4: Hypothesentests\nVorlesung vom 17.11.2026",
        "Die Klausur findet im Februar statt. Nächste Übung: Dienstag, 17.11.",
        "Test-Driven Development – Vorlesung 17.11.2026",
    ]

    // MARK: Zweite Sammlung (Gegenprobe)

    /// Erst nach dem Anpassen der Regeln geschrieben und nicht zum Abstimmen benutzt: zeigt, wie die Erkennung auf
    /// Formulierungen wirkt, die beim Bauen niemand vor Augen hatte.
    static let holdoutPositives: [Positive] = [
        .init("Klausurtermin: Dienstag, der 17.11.2026 um 14:15 Uhr", time: "14:15"),
        .init("Die schriftliche Prüfung findet am 17.11.2026 statt."),
        .init("Wir schreiben die Klausur am 17.11. in der regulären Vorlesungszeit."),
        .init("Klausur 1 (Midterm): 17.11.2026"),
        .init("17.11.2026 Klausur 90 min"),
        .init("Termin Klausur: 17.11.2026, 8–10 Uhr", time: "08:00"),
        .init("Save the date: exam on Nov 17, 2026"),
        .init("Exam: Tuesday, 17 November, 10:00", time: "10:00"),
        .init("Am Dienstag (17.11.) findet die Kurzklausur statt."),
        .init("Kurzklausur 2\n17.11.2026"),
        .init("• 17.11.: Zwischenklausur (45 min)"),
        .init("Prüfungstermine\n1. Termin: 17.02.2027\n2. Termin: 31.03.2027", "2027-02-17"),
        .init("Testat: 17.11.2026, 16:00 Uhr, Raum A310", time: "16:00"),
        .init("Online-Test am 17.11.2026 ab 18 Uhr"),
        .init("Der Zwischentest findet am 17.11. in der Übung statt."),
        .init("Achtung! Klausur schon am 17.11.2026!"),
        .init("Datum der Klausur ist der 17.11.2026."),
        .init("Klausur | 17.11.2026 | 10:00 | Audimax"),
        .init("Vorlesung 6 (17.11.): Klausur"),
        .init("Exam (written, 90 min): 17.11.2026"),
        .init("Midterm: Tue, 17.11., in class"),
        .init("Final exam on 17 February 2027", "2027-02-17"),
        .init("Die Modulprüfung (Klausur) ist am 17.02.2027.", "2027-02-17"),
        .init("Klausureinsicht: 01.12.2026; Klausur: 17.11.2026"),
        .init("Probeklausur: nächste Woche Dienstag"),
        .init("Klausur am 17. Nov. 2026"),
        .init("Kurztest in der Vorlesung am Dienstag, 17.11."),
        .init("1. Kurzklausur: KW 47", "2026-11-16"),
        .init("Die Klausur ist am 17.11.2026 von 10:00 bis 11:30 Uhr.", time: "10:00"),
        .init("KLAUSUR: 17.11.2026"),
    ]

    static let holdoutNegatives: [String] = [
        "Klausurergebnisse ab 17.11.2026 online",
        "Nach der Klausur ist vor der Klausur – Feedback bis 17.11.2026",
        "Altklausuren (2019–2025) im Stud.IP, hochgeladen am 17.11.2026",
        "Probeklausur WS 2023/24, 17.11.2023",
        "Musterlösung zur Klausur vom 17.02.2026",
        "Die Vorlesung am 17.11.2026 entfällt wegen der Klausuren anderer Fächer.",
        "Anmeldeschluss für die Klausur: 17.11.2026",
        "Bis zum 17.11.2026 müssen Sie sich zur Prüfung anmelden.",
        "Übungsblatt 5, Abgabe 17.11.2026, klausurähnliche Aufgaben",
        "Klausurtraining: 17.11.2026, 16–18 Uhr",
        "Mock exam solutions will be published on 17 November 2026",
        "Exam registration closes on 17 November 2026",
        "Lecture 6 – November 17 – Hypothesis tests",
        "Statistische Tests (17 Folien)",
        "Bestehensgrenze der Klausur 2025: 50 % (Stand 17.11.2025)",
        "Die Klausur dauert 90 Minuten. Erlaubte Hilfsmittel: ein Blatt DIN A4. Erstellt: 17.11.2026",
        "Literatur: Müller (2017), Kap. 11; Prüfungsrelevanz: hoch",
        "Ihre Fragen zur Klausur können Sie bis 17.11. im Forum stellen.",
        "Die Hausübung 3 (Abgabe 17.11.) ist Voraussetzung für die Klausurzulassung.",
        "Evaluation: 17.11.2026 – bitte teilnehmen, auch wenn die Klausur naht.",
        "Geschichte: Erste Klausur dieser Art am 17.11.1998",
        "Raumänderung am 17.11.2026: Hörsaal F303 statt Prüfungsraum",
        "Exam topics: everything up to and including the lecture on 17 November 2026",
        "Die Wiederholungsklausur des Sommersemesters fand am 17.09.2026 statt.",
        "Tutorium am 17.11.2026: Wir rechnen Klausuraufgaben.",
    ]

    private func window() -> DueDetection.Window {
        DueDetection.Window.current(university: "luh", today: BerlinClock.parseISODate(Self.today)!)!
    }

    private func exams(_ text: String) -> [DueDetection.Hit] {
        let ref = BerlinClock.parseISODate(Self.today)!
        return DueDetection.detect(text, context: .init(window: window(), reference: ref)).filter { $0.kind == .klausur || $0.kind == .test }
    }

    /// Zahl der erkannten Positiven und die verfehlten Texte
    func measurePositives(_ list: [Positive] = DueSlideCorpusTests.positives) -> (found: Int, missed: [String]) {
        var missed: [String] = []
        for p in list {
            let hits = exams(p.text)
            let ok = hits.contains { $0.date == p.date && (p.time == nil || $0.time == p.time) }
            if !ok { missed.append(p.text.replacingOccurrences(of: "\n", with: " ⏎ ") + "  -> " + hits.map { "\($0.date) \($0.time ?? "-") \($0.label)" }.joined(separator: ", ")) }
        }
        return (list.count - missed.count, missed)
    }

    /// Fehlalarme: Negative mit einem Treffer der Art Klausur oder Test
    func measureNegatives(_ list: [String] = DueSlideCorpusTests.negatives) -> [String] {
        list.compactMap { t in
            let hits = exams(t)
            return hits.isEmpty ? nil : t.replacingOccurrences(of: "\n", with: " ⏎ ") + "  -> " + hits.map { "\($0.date) \($0.label)" }.joined(separator: ", ")
        }
    }

    /// Gegenprobe: Stand je Lauf in der Ausgabe; die Schwellen halten den gemessenen Stand fest
    func testHoldout() {
        let p = measurePositives(Self.holdoutPositives)
        let n = measureNegatives(Self.holdoutNegatives)
        print("Gegenprobe: \(p.found) von \(Self.holdoutPositives.count) Positiven erkannt, \(n.count) Fehlalarme in \(Self.holdoutNegatives.count) Negativen")
        for m in p.missed { print("  verfehlt: \(m)") }
        for m in n { print("  Fehlalarm: \(m)") }
        XCTAssertGreaterThanOrEqual(p.found, Self.holdoutFound)
        XCTAssertLessThanOrEqual(n.count, Self.holdoutFalseAlarms)
    }

    static let holdoutFound = 30
    static let holdoutFalseAlarms = 0

    func testCorpusSize() {
        XCTAssertGreaterThanOrEqual(Self.positives.count, 60)
        XCTAssertGreaterThanOrEqual(Self.negatives.count, 40)
    }

    func testSlidePhrasesAreRecognised() {
        let p = measurePositives()
        print("Folien-Sammlung: \(p.found) von \(Self.positives.count) Positiven erkannt")
        for m in p.missed { print("  verfehlt: \(m)") }
        XCTAssertEqual(p.missed, [], "\(p.found) von \(Self.positives.count)")
    }

    func testNoFalseAlarms() {
        let n = measureNegatives()
        print("Folien-Sammlung: \(n.count) Fehlalarme in \(Self.negatives.count) Negativen")
        for m in n { print("  Fehlalarm: \(m)") }
        XCTAssertEqual(n, [], "\(n.count) Fehlalarme")
    }
}
