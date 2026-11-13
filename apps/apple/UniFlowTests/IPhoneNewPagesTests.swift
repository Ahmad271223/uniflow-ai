import SwiftUI
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Neue Seiten aus develop (12./13.11.2026) auf dem iPhone: Lernziele (Smart Planner 2.0), Modul mit eigenen Wochen,
/// Studiengruppen- und Faecher-Frage. Nichts ragt ueber den Rand, auch nicht auf dem kleinsten iPhone. Lokaler
/// Speicher mit erfundenen Daten, kein Netz.
@MainActor
final class IPhoneNewPagesTests: IPhoneLearnTestCase {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-iphone-neu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func localAPI() throws -> APIClient {
        let host = LocalBackendHost(directory: try tempDir().appendingPathComponent("db", isDirectory: true),
                                    clock: .fixed(berlin: "2026-11-12T10:00:00")!)
        try awaiting {
            let backend = try await host.backend()
            try await backend.context.database.transaction { c in
                try c.execute("INSERT INTO modules(id, name, color, sort) VALUES (1, 'Einführung in die Informatik', '#175ee8', 0), (2, 'Lineare Algebra I für Studierende der Informatik', '#16a34a', 1)")
                try c.execute("INSERT INTO courses(id, title, subject, kind, semester, active, module_id, created_at) VALUES ('sp-1', 'Lineare Algebra', 'Lineare Algebra', 'vorlesung', 'WiSe 2026/27', 1, 2, 't')")
                for (i, n) in ["Einführung", "Vektorräume", "Basis und Dimension"].enumerated() {
                    try c.execute("INSERT INTO files(id, course_id, name, chdate) VALUES (?,?,?,?)",
                                  [.text("la-\(i + 1)"), .text("sp-1"), .text("LA \(n).pdf"), .integer(Int64(1_791_878_400 + 60 * i))])
                }
            }
        }
        return APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
    }

    func testGoalsPageFitsThePhone() throws {
        let env = try hostPhone(GoalsPage { _ in }, api: try localAPI())
        XCTAssertTrue(env.wait(timeout: 15) { self.shows(env, "Lernziele") && !self.shows(env, "Nicht mit dem Server") }, dump(env))
        env.pump(1)
        XCTAssertNotNil(button(env, "Ziele"), "Leiste wie im Lernkalender: \(dump(env))")
        assertFitsOnAllPhones(env, "lernziele")
        shoot(env, "iphone-lernziele")
    }

    func testModuleWithOwnWeeksFitsThePhone() throws {
        let env = try hostPhone(ModulePage(id: 2), api: try localAPI())
        env.router.go(.module(2))
        XCTAssertTrue(env.wait(timeout: 15) { self.shows(env, "Lineare Algebra") }, dump(env))
        env.pump(1)
        assertFitsOnAllPhones(env, "modul-wochen")
        shoot(env, "iphone-modul-wochen")
    }

    func testStudyGroupQuestionsFitThePhone() throws {
        let groups = [StudIPCourse(id: "sg1", title: "Lerngruppe Analysis I", courseType: 99),
                      StudIPCourse(id: "sg2", title: "Fachschaft Maschinenbau", courseType: 99)]
        let sheet = ScrollView {
            StudyGroupsSheet(groups: groups, modules: ["Analysis I", "Technische Mechanik"],
                             choices: ["sg1": .init(files: true, module: true, moduleName: "Analysis I", timetable: true)], asQuestion: true)
                .padding(16)
        }
        let env = try hostPhone(sheet, api: remote(Canned()))
        XCTAssertTrue(env.wait { self.shows(env, "Lerngruppe Analysis I") }, dump(env))
        assertFitsOnAllPhones(env, "studiengruppen")
        shoot(env, "iphone-studiengruppen")
        let plan = ScrollView {
            PlanModulesSheet(items: [PlanModuleItem(name: "Analysis I", color: "#4f46e5", planned: true),
                                     PlanModuleItem(name: "Lerngruppe Analysis I", color: "#f59e0b", planned: false)], asQuestion: true)
                .padding(16)
        }
        let env2 = try hostPhone(plan, api: remote(Canned()))
        XCTAssertTrue(env2.wait { self.shows(env2, "Analysis I") }, dump(env2))
        assertFitsOnAllPhones(env2, "lernkalender-faecher")
        shoot(env2, "iphone-lernkalender-faecher")
    }

    func testPlanBarOnPhoneHasGoalsAndWeek() {
        XCTAssertEqual(PlanView.views(compact: true).map(\.value), ["ziele", "day", "3days", "week", "month", "list"])
        XCTAssertEqual(PlanView.views(compact: false).map(\.value), PlanViews.all.map(\.value), "iPad wie develop")
        XCTAssertEqual(PlanView.views(compact: false).map(\.label), PlanViews.all.map(\.label))
    }
}
