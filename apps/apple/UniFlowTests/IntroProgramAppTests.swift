import SwiftUI
import XCTest
import UniFlowCore
@testable import UniFlow

/// Frage "Was studierst du?" im Einstieg (Universitaet Hildesheim, 14.11.2026): nur dort gestellt, Mehrfachwahl
/// (Hauptfach plus Neben-/Begleitfach), "Später" erlaubt; Liste aus `GET /api/study-catalog/programs`.
@MainActor
final class IntroProgramAppTests: XCTestCase {

    private static let list: JSONValue = ["programs": [
        ["id": "betriebswirtschaftslehre-begleitfach", "program": "Betriebswirtschaftslehre", "degree": "Begleitfach", "pos": []],
        ["id": "erziehungswissenschaft-b-a", "program": "Erziehungswissenschaft", "degree": "B.A.", "faculty": "Fachbereich 1",
         "pos": [["po": "2020", "code": "erziehungswissenschaft|b.a.|2020"], ["po": "2023", "code": "erziehungswissenschaft|b.a.|2023"]]],
        ["id": "sozialpaedagogik-b-a", "program": "Sozialpädagogik", "degree": "B.A.", "faculty": "Fachbereich 1",
         "pos": [["po": "2025", "code": "sozialpaedagogik|b.a.|2025"]]],
    ], "count": 3]

    func testListTakesNewestPOAndFilters() {
        let l = IntroProgram.list(Self.list)
        XCTAssertEqual(l.map(\.name), ["Betriebswirtschaftslehre (Begleitfach)", "Erziehungswissenschaft (B.A.)", "Sozialpädagogik (B.A.)"])
        XCTAssertEqual(l[1].code, "erziehungswissenschaft|b.a.|2023", "neueste PO")
        XCTAssertNil(l[0].code, "ohne Modulkatalog")
        XCTAssertEqual(l[0].key, "betriebswirtschaftslehre-begleitfach")
        XCTAssertEqual(IntroProgram.filter(l, "sozialp").map(\.program), ["Sozialpädagogik"])
    }

    func testStepOnlyForHildesheimWithMultipleChoice() {
        var m = IntroSetupModel()
        m.name = "Lea"
        XCTAssertEqual(m.next(after: .name), .modules, "ohne Hildesheim keine Frage")
        XCTAssertEqual(m.shownSteps.count, 3)
        m.askProgram = true
        m.programs = IntroProgram.list(Self.list)
        XCTAssertEqual(m.next(after: .name), .program)
        XCTAssertEqual(m.next(after: .program), .modules)
        XCTAssertEqual(m.shownSteps.count, 4)
        m.step = .program
        XCTAssertEqual(m.progressIndex, 1)
        XCTAssertEqual(m.question(.program), "Hallo Lea! Was studierst du an der Universität Hildesheim?")
        XCTAssertNil(m.answer(.program), "Später: keine Antwort")
        m.toggleProgram(m.programs[1])
        m.toggleProgram(m.programs[0])
        XCTAssertEqual(m.answer(.program), "Erziehungswissenschaft (B.A.), dazu Betriebswirtschaftslehre (Begleitfach).")
        m.toggleProgram(m.programs[2])
        m.toggleProgram(m.programs[2])
        XCTAssertEqual(m.chosenPrograms.count, 2, "wieder entfernt")
        m.toggleProgram(m.programs[2])
        m.toggleProgram(IntroProgram(id: "x", program: "X", degree: nil, faculty: nil, code: nil))
        XCTAssertEqual(m.chosenPrograms.count, 3, "hoechstens drei")
    }

    func testAnswerViewShowsListAndChoice() throws {
        XCTAssertTrue(HostedEnvironment.accessibilityAutomation(true))
        defer { HostedEnvironment.accessibilityAutomation(false) }
        var m = IntroSetupModel()
        m.askProgram = true
        m.step = .program
        m.programs = IntroProgram.list(Self.list)
        m.toggleProgram(m.programs[2])
        let env = try hostWithEnvironment(IntroSetupLayout(model: .constant(m), onAnswer: { _ in }, onSkipAll: {}, onFinish: {}))
        XCTAssertTrue(env.wait { env.labels().contains { $0.contains("Was studierst du an der Universität Hildesheim?") } }, env.labels().joined(separator: "\n"))
        XCTAssertTrue(env.labels().contains("Hauptfach"), env.labels().joined(separator: "\n"))
        XCTAssertTrue(env.labels().contains("Erziehungswissenschaft (B.A.)"))
        XCTAssertTrue(env.labels().contains("Später"))
    }
}
