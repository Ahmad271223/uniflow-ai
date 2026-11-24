import UniFlowCore
import XCTest
@testable import UniFlow

/// Klausur-Generator, Stufe (a): Texte und Zaehler des Auswahl-Blatts (`ExamGeneratorPicker`). Die Regeln selbst
/// prueft der Kern (`ExamGeneratorSelectionTests`).
final class ExamGeneratorAppTests: XCTestCase {
    // In 1.0.7 aus (Entscheidung des Inhabers 24.11.2026); die Tests pruefen die Funktion weiter mit Schalter an
    override func setUp() { super.setUp(); ExamGenerator.isEnabled = true }
    override func tearDown() { ExamGenerator.isEnabled = false; super.tearDown() }

    private typealias Item = ExamGeneratorSelection.Item
    private let limits = ExamGeneratorSelection.limits

    func testCountersShowWhatTheOwnerLimits() {
        var c = ExamGeneratorSelection.Check()
        c.materialPages = 212; c.examFiles = 4; c.exerciseFiles = 10
        XCTAssertEqual(ExamGenerator.counter(.material, c, limits: limits), "212 von 300 Seiten")
        XCTAssertEqual(ExamGenerator.counter(.exams, c, limits: limits), "4 von 10")
        XCTAssertEqual(ExamGenerator.counter(.exercises, c, limits: limits), "10 von 10")
        XCTAssertFalse(ExamGenerator.isOver(.material, c, limits: limits))
        XCTAssertFalse(ExamGenerator.isOver(.exercises, c, limits: limits), "genau 10 ist erlaubt")
    }

    func testGroupTurnsRedOnlyWhenItsOwnLimitIsExceeded() {
        var c = ExamGeneratorSelection.Check()
        c.materialPages = 301
        XCTAssertTrue(ExamGenerator.isOver(.material, c, limits: limits))
        XCTAssertFalse(ExamGenerator.isOver(.exams, c, limits: limits))
        c = ExamGeneratorSelection.Check(); c.examSolutions = 11
        XCTAssertTrue(ExamGenerator.isOver(.exams, c, limits: limits), "auch zu viele Lösungen färben die Gruppe")
        c = ExamGeneratorSelection.Check(); c.exerciseFiles = 11
        XCTAssertTrue(ExamGenerator.isOver(.exercises, c, limits: limits))
    }

    func testRowIsSpokenWithTypePagesAndState() {
        let vl = Item(id: "a", title: "VL01 Folgen", label: "Vorlesung", group: .material, isSolution: false, pages: 24)
        XCTAssertEqual(ExamGenerator.rowAccessibility(vl, selected: true), "VL01 Folgen, Vorlesung, 24 Seiten, ausgewählt")
        XCTAssertEqual(ExamGenerator.rowAccessibility(vl, selected: false), "VL01 Folgen, Vorlesung, 24 Seiten, nicht ausgewählt")
        let one = Item(id: "b", title: "Blatt 1", label: "Übung", group: .exercises, isSolution: false, pages: 1)
        XCTAssertEqual(ExamGenerator.rowAccessibility(one, selected: false), "Blatt 1, Übung, 1 Seite, nicht ausgewählt")
        let missing = Item(id: "c", title: "VL02", label: "Vorlesung", group: .material, isSolution: false, pages: nil)
        XCTAssertEqual(ExamGenerator.rowAccessibility(missing, selected: true), "VL02, Vorlesung, nicht auf dem Gerät")
    }

    func testSectionsNameTheThreeGroups() {
        XCTAssertEqual(ExamGeneratorSelection.Group.allCases.map(ExamGenerator.sectionTitle), ["Vorlesung und Skript", "Altklausuren", "Übungen"])
    }

    func testPriceAndSplitLines() {
        XCTAssertEqual(ExamGenerator.priceLine(count: 3, price: 15), "3 Probeklausuren × 15 Credits = 45 Credits")
        XCTAssertEqual(ExamGenerator.priceLine(count: 1, price: 15), "1 Probeklausur × 15 Credits = 15 Credits")
        XCTAssertEqual(ExamGenerator.splitLine(ready: 1, new: 2), "1 ist schon fertig (sofort da), 2 erstellt StudiNow neu (einige Minuten).")
        XCTAssertEqual(ExamGenerator.splitLine(ready: 2, new: 0), "2 sind schon fertig (sofort da).")
        XCTAssertEqual(ExamGenerator.buyButton(45), "Für 45 Credits kaufen")
        XCTAssertTrue(ExamGenerator.sendNote.contains("kostet es nichts"))
    }

    func testCardListsOwnExamsByNumber() {
        XCTAssertEqual(ExamGenerator.mineTitle, "Deine Probeklausuren")
        XCTAssertEqual(ExamGenerator.examName(1), "Probeklausur 1")
        XCTAssertEqual(ExamGenerator.examName(0), "Probeklausur", "ohne lesbare Nummer keine 0")
        XCTAssertEqual([ExamGenerator.tasks, ExamGenerator.solutions], ["Aufgaben", "Lösungen"])
    }

    func testStatusTexts() {
        XCTAssertEqual(ExamGenerator.statusText("ready", hasFiles: true), "liegt im Modul")
        XCTAssertEqual(ExamGenerator.statusText("running", hasFiles: false), "wird erstellt")
        XCTAssertEqual(ExamGenerator.statusText("failed", hasFiles: false), "hat nicht geklappt – nichts berechnet")
    }
}
