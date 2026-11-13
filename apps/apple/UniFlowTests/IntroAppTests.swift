import SwiftUI
import XCTest
import UniFlowCore
@testable import UniFlow

/// Neuer Einstieg (Inhaber 13.11.2026): Ablauf der Fragen, Schnellwahl der Pruefungstermine, Texte ohne Versprechen.
/// Reihenfolge der Schritte und bestehende Nutzer: AccountStoreTests; Bilder: IntroShotsAppTests.
@MainActor
final class IntroAppTests: XCTestCase {

    private func model() -> IntroSetupModel { IntroShotsAppTests.sampleSetup(step: .name) }

    func testQuestionsGreetWithNameAndCountQISDates() {
        var m = model()
        XCTAssertEqual(m.answer(.name), "Nenn mich Ahmad.")
        XCTAssertTrue(m.question(.modules).hasPrefix("Hallo Ahmad! "))
        XCTAssertTrue(m.question(.exams).hasPrefix("Einen Prüfungstermin kenne ich schon aus QIS."), m.question(.exams))
        XCTAssertEqual(m.answer(.modules), "Analysis I, Technische Mechanik, Programmieren.")
        m.name = "  "
        XCTAssertNil(m.answer(.name), "ohne Namen keine Antwortblase")
        XCTAssertFalse(m.question(.modules).contains("Hallo"))
    }

    func testNoPlannedModulesSkipsExamQuestion() {
        var m = model()
        for i in m.modules.indices { m.modules[i].planned = false }
        XCTAssertEqual(m.next(after: .modules), .ready)
        XCTAssertEqual(m.answer(.modules), "Erst mal keine.")
        m.modules = []
        XCTAssertNil(m.answer(.modules))
        XCTAssertTrue(m.question(.modules).contains("noch keine Fächer"))
    }

    func testExamFromQISCannotBeOverwritten() {
        var m = model()
        m.setExam("Analysis I", day: "2027-03-01")
        XCTAssertEqual(m.modules[0].exam, "2027-02-08", "Termin aus QIS bleibt")
        m.setExam("Programmieren", day: "2027-02-20")
        XCTAssertEqual(m.modules[2].exam, "2027-02-20")
        XCTAssertEqual(m.answer(.exams), "3 Termine stehen.")
        m.setExam("Programmieren", day: nil, none: true)
        XCTAssertTrue(m.modules[2].noExam)
        XCTAssertEqual(m.answer(.exams), "2 Termine stehen.")
    }

    func testQuickExamChoices() {
        let cal = Calendar(identifier: .gregorian)
        let today = cal.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 12))!
        XCTAssertEqual(IntroExamChoice.week.day(from: today, calendar: cal).map(IntroSetupModel.iso), "2026-11-20")
        XCTAssertEqual(IntroExamChoice.month.day(from: today, calendar: cal).map(IntroSetupModel.iso), "2026-12-13")
        XCTAssertNil(IntroExamChoice.none.day(from: today))
        XCTAssertEqual(IntroSetupModel.shown("2027-02-08"), "Mo., 8. Feb. 2027")
    }

    func testModulesJoinCalendarAndModuleList() {
        let cal: JSONValue = ["modules": [["name": "Analysis I", "color": "#4f5bd5", "planned": true],
                                          ["name": "Statistik", "color": "#16a34a", "planned": false]]]
        let list: JSONValue = [["id": 7, "name": "Analysis I", "exam_date": "2027-02-08T09:00:00"], ["id": 9, "name": "Statistik"]]
        let m = IntroSetupModel.modules(calendar: cal, list: list)
        XCTAssertEqual(m.map(\.name), ["Analysis I", "Statistik"])
        XCTAssertEqual(m[0].moduleID, 7)
        XCTAssertEqual(m[0].exam, "2027-02-08")
        XCTAssertTrue(m[0].examFromUni)
        XCTAssertNil(m[1].exam)
        XCTAssertFalse(m[1].planned)
    }

    /// Keine erfundenen Preise oder Versprechen im Einstieg
    func testTextsMakeNoPromises() {
        var all = IntroTourPage.allCases.flatMap { [$0.title, $0.text] }
        all += [IntroPlanText.headline(proAI: true), IntroPlanText.headline(proAI: false), IntroPlanText.sub, IntroWelcomeText.stageCaption]
        all += IntroSetupModel.Step.allCases.map { model().question($0) }
        for t in all {
            for word in ["Geld zurück", "erstatten", "garantiert", "Millionen", "€", "Monat"] {
                XCTAssertFalse(t.contains(word), "„\(word)“ in „\(t)“")
            }
        }
        XCTAssertTrue(IntroTourPage.notes.text.contains("mit Pro AI"), "KI-Karteikarten nur mit Pro AI")
    }
}
