import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Tests & Wiederholung auf dem iPhone (402 x 874, schmal): Testkarten untereinander, "Wochentest erstellen" als Blatt,
/// Testlauf mit einer Aufgabe je Bildschirm (Fortschritt oben, Zurueck/Weiter unten), Ergebnis mit Ring und "Frag die
/// KI zu Aufgabe n" als Blatt, Karte "Nächste Klausuren". Gegenprobe iPad quer: alle Aufgaben untereinander, KI-Hilfe
/// als Spalte. Schein-Transport, erfundene Tests, keine KI.
@MainActor
final class IPhoneLearnExamsTests: IPhoneLearnTestCase {

    private static let questions: [JSONValue] = [
        ["nr": 1, "type": "tf", "difficulty": "leicht", "question": "Die Dezimalzahl 255 ist hexadezimal F0.", "options": ["Wahr", "Falsch"],
         "points": 20, "answer": "Falsch", "explanation": "255 = 15·16 + 15, also FF. F0 wäre 240."],
        ["nr": 2, "type": "mc", "difficulty": "leicht", "question": "Wie lautet die Dezimalzahl 13 im Dualsystem?", "options": ["1011", "1101", "1110", "1001"],
         "points": 20, "answer": "1101", "explanation": "13 = 8 + 4 + 1, also 1101."],
        ["nr": 3, "type": "calc", "difficulty": "schwer", "question": "Was ist das Zweierkomplement von 0101 (4 Bit)?", "points": 20,
         "answer": "1011", "explanation": "Bits umkehren (1010) und 1 addieren: 1011."],
    ]

    private static let submitted: JSONValue = [
        "id": 8, "title": "Wochentest Demo Informatik – Zahlensysteme", "subject": "Demo Informatik", "duration_min": 15, "week_no": 1,
        "submitted_at": "2026-11-03T10:00:00", "started_at": "2026-11-03T09:40:00", "answers": ["1": "Wahr", "2": "1101", "3": ""],
        "questions": .array(questions),
        "feedback": ["total": 20, "max": 60, "summary": "Das Dualsystem sitzt; Hexadezimal und Zweierkomplement lohnen eine Wiederholung.",
                     "weak_topics": ["Hexadezimalsystem", "Zweierkomplement"],
                     "per_question": [["nr": 1, "points": 0, "max": 20, "feedback": "F0 ist 240, nicht 255."],
                                      ["nr": 2, "points": 20, "max": 20, "feedback": "Richtig."],
                                      ["nr": 3, "points": 0, "max": 20, "feedback": "Keine Antwort."]]]]

    private static let open: JSONValue = [
        "id": 9, "title": "Wochentest Demo Informatik – Zahlensysteme", "subject": "Demo Informatik", "duration_min": 15, "week_no": 1,
        "submitted_at": .null, "started_at": "2026-11-03T09:40:00", "answers": ["1": "Wahr"], "questions": .array(questions), "feedback": .null]

    private func transport() -> Canned {
        let t = Canned()
        t.answer("/api/tests", [
            ["id": 8, "subject": "Demo Informatik", "title": "Wochentest Demo Informatik – Zahlensysteme (15 Minuten)", "week_no": 1, "duration_min": 15,
             "question_count": 3, "auto": 1, "submitted_at": "2026-11-03T10:00:00", "score": 20, "max_score": 60, "week_start": "2026-10-26"],
            ["id": 9, "subject": "Demo Informatik", "title": "Wochentest Demo Informatik – Zahlensysteme", "week_no": 1, "duration_min": 15,
             "question_count": 3, "auto": 1, "submitted_at": .null, "started_at": "2026-11-03T09:40:00", "week_start": "2026-10-26"],
            ["id": 10, "subject": "Testanalysis I", "title": "Folgen und Reihen mit einem sehr langen Titel, der umbrechen muss", "week_no": 2,
             "duration_min": 30, "question_count": 15, "auto": 0, "submitted_at": .null, "week_start": "2026-11-02",
             "shared": ["variant": 2, "of": 3]]])
        t.answer("/api/modules", [["id": 1, "name": "Demo Informatik", "color": "#4f5bd5"], ["id": 2, "name": "Testanalysis I", "color": "#1f9d5b"]])
        t.answer("/api/flashcards", [["id": 1, "question": "Q", "answer": "A"]])
        t.answer("/api/tests/8", Self.submitted)
        t.answer("/api/tests/9", Self.open)
        t.answer("/api/ai/tutor", ["answer": "## Kurz gesagt\n255 ist im Hexadezimalsystem **FF**, nicht F0.", "cards": .null, "sources": []])
        return t
    }

    override func tearDown() {
        (ActiveContainer.current?.defaults ?? .standard).removeObject(forKey: "exam-draft:http://erfunden.test/:9")
        super.tearDown()
    }

    /// Liste: Testkarten untereinander; "Wochentest erstellen" als Blatt mit Zahl, Schwierigkeit, Arten und Thema
    func testListStacksCardsAndComposerIsASheet() throws {
        let env = try hostPhone(ExamsPage(generation: TestGenerationState(), entitlements: Entitlements(observe: false, plan: .plus))
            .environment(\.ufAIEnabled, true), api: remote(transport()))
        XCTAssertTrue(env.wait { self.button(env, "Starten") != nil && self.button(env, "Ansehen") != nil }, dump(env))
        let view = frame(button(env, "Ansehen")), start = frame(button(env, "Fortsetzen"))
        XCTAssertGreaterThan(start.minY, view.maxY, "Karten untereinander")
        assertFitsOnAllPhones(env, "tests-liste")
        shoot(env, "iphone-tests-liste")
        XCTAssertTrue(tap(env, "Wochentest erstellen"))
        XCTAssertTrue(waitSheet(env, showing: "Schwierigkeit"), dump(env))
        XCTAssertTrue(shows(env, "Aufgabenarten (mindestens eine)"))
        XCTAssertNotNil(element(env, label: "Thema oder Hinweise"), dump(env))
        XCTAssertNotNil(element(env, label: "10 Aufgaben"), dump(env))
        assertFits(env, "tests-wochentest-blatt")
        shoot(env, "iphone-tests-wochentest-blatt")
    }

    /// Testlauf schmal: eine Aufgabe je Bildschirm, Weiter/Zurueck unten, auf der letzten "Abgeben & bewerten"
    func testRunShowsOneQuestionPerScreen() throws {
        let env = try hostPhone(ExamRunPage(id: 9, task: nil), api: remote(transport()))
        XCTAssertTrue(env.wait { self.shows(env, "Die Dezimalzahl 255 ist hexadezimal F0.") }, dump(env))
        XCTAssertFalse(shows(env, "Wie lautet die Dezimalzahl 13"), "nur eine Aufgabe")
        XCTAssertTrue(shows(env, "Fortschritt 1 von 3 beantwortet"), dump(env))
        let next = frame(button(env, "Weiter"))
        XCTAssertGreaterThan(next.maxY, Self.phone.height - 130, "Weiter unten in Daumennaehe: \(next)")
        XCTAssertNotNil(button(env, "Zurück"))
        assertFitsOnAllPhones(env, "testlauf-1")
        shoot(env, "iphone-testlauf-aufgabe-1")
        XCTAssertTrue(tap(env, "Weiter"))
        XCTAssertTrue(env.wait { self.shows(env, "Wie lautet die Dezimalzahl 13") }, dump(env))
        XCTAssertFalse(shows(env, "Die Dezimalzahl 255 ist hexadezimal F0."))
        XCTAssertTrue(tap(env, "1101"), "Antwort waehlen")
        XCTAssertTrue(env.wait { self.shows(env, "Fortschritt 2 von 3 beantwortet") }, dump(env))
        shoot(env, "iphone-testlauf-aufgabe-2")
        XCTAssertTrue(tap(env, "Weiter"))
        XCTAssertTrue(env.wait { self.button(env, "Abgeben & bewerten") != nil }, dump(env))
        XCTAssertNil(button(env, "Weiter"), "letzte Aufgabe: Abgeben statt Weiter")
        assertFits(env, "testlauf-3")
        shoot(env, "iphone-testlauf-aufgabe-3")
        XCTAssertTrue(tap(env, "Zurück"))
        XCTAssertTrue(env.wait { self.shows(env, "Wie lautet die Dezimalzahl 13") }, dump(env))
    }

    /// Ergebnis schmal: Ring und Zahlen, "Frag die KI zu Aufgabe 1" oeffnet die KI-Hilfe als Blatt
    func testResultAsksAIInASheet() throws {
        // ein Gespraech aus einem frueheren Lauf auf demselben Simulator zeigte Anschlussfragen statt der ersten Frage
        TutorConversations.shared.clear(fileID: TutorConversations.examKey(testID: 8, nr: "1"))
        let env = try hostPhone(ExamRunPage(id: 8, task: nil).environment(\.ufAIEnabled, true), api: remote(transport()))
        XCTAssertTrue(env.wait { self.shows(env, "33 %") }, dump(env))
        XCTAssertTrue(shows(env, "1/3 richtig"))
        assertFitsOnAllPhones(env, "ergebnis")
        shoot(env, "iphone-ergebnis")
        XCTAssertTrue(tap(env, "Frag die KI zu Aufgabe 1"))
        XCTAssertTrue(waitSheet(env, showing: "Richtige Antwort: Falsch"), dump(env))
        XCTAssertTrue(tap(env, "Warum ist meine Antwort zu Aufgabe 1 falsch?"), dump(env))
        XCTAssertTrue(env.wait { self.shows(env, "Kurz gesagt") }, dump(env))
        assertFits(env, "ergebnis-ki-blatt")
        shoot(env, "iphone-ergebnis-ki-blatt")
    }

    /// Karte "Nächste Klausuren" schmal: Tag, Titel, Countdown und Ort passen
    func testExamDatesCardFits() throws {
        let items: [JSONValue] = [
            ["id": "e1", "title": "Klausur Lineare Algebra I mit langem Titel", "date": "2027-02-12", "days_left": 100, "in_days": "in 100 Tagen",
             "time": "09:00", "end": "11:00", "room": "Hörsaal F 303 (Hauptgebäude)", "source_label": "aus Stud.IP-Terminen", "module_id": 1],
            ["id": "e2", "title": "Analysis I", "date": "2027-02-20", "days_left": 108, "in_days": "in 108 Tagen", "source_label": "QIS-Anmeldung"]]
        let view = ScrollView { UpcomingExamsList(items: items) { _ in }.padding(16) }.background(UF.bg)
        let env = try hostPhone(view, api: remote(transport()))
        XCTAssertTrue(env.wait { self.shows(env, "Nächste Klausuren") }, dump(env))
        XCTAssertTrue(shows(env, "Klausur Lineare Algebra I mit langem Titel"))
        assertFitsOnAllPhones(env, "klausurtermine")
        shoot(env, "iphone-klausurtermine")
    }

    /// iPad quer unveraendert: alle Aufgaben untereinander, kein Weiter; Ergebnis mit KI-Hilfe als Spalte
    func testPadKeepsAllQuestionsAndColumn() throws {
        let env = try hostPad(ExamRunPage(id: 9, task: nil), api: remote(transport()))
        XCTAssertTrue(env.wait { self.shows(env, "Die Dezimalzahl 255 ist hexadezimal F0.") }, dump(env))
        XCTAssertTrue(shows(env, "Wie lautet die Dezimalzahl 13"), "alle Aufgaben")
        XCTAssertNil(button(env, "Weiter"))
        XCTAssertNotNil(button(env, "Abgeben & bewerten"))
        let result = try hostPad(ExamRunPage(id: 8, task: nil).environment(\.ufAIEnabled, true), api: remote(transport()))
        XCTAssertTrue(result.wait { self.shows(result, "33 %") }, dump(result))
        XCTAssertTrue(tap(result, "Frag die KI zu Aufgabe 1"))
        XCTAssertTrue(result.wait { self.shows(result, "Richtige Antwort: Falsch") }, dump(result))
        XCTAssertFalse(sheetOpen(result), "breit als Spalte, kein Blatt")
    }
}
