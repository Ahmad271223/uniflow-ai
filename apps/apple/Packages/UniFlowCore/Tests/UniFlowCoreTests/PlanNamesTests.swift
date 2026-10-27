import Foundation
import XCTest
@testable import UniFlowCore

/// Kurznamen enger Kalenderbloecke (`PlanNames`) gegen die gemeinsamen Faelle in
/// packages/shared-contracts/fixtures/plan-names/cases.json; dieselben prueft tests/test_plan_names.py fuer
/// app/static/plan-names.js.
final class PlanNamesTests: XCTestCase {
    private func fixture() throws -> JSONValue {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url.deleteLastPathComponent() }
        return try JSONValue.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/plan-names/cases.json")))
    }

    /// Gleiche Codepunkte (Swift vergleicht Zeichenketten sonst kanonisch aequivalent, JavaScript nicht)
    private func same(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return Array(a.unicodeScalars) == Array(b.unicodeScalars)
    }

    func testSingleTitlesLikeWeb() throws {
        let cases = try fixture()["single"]?.array ?? []
        XCTAssertGreaterThanOrEqual(cases.count, 40)
        var problems: [String] = []
        for c in cases {
            let title = c["title"]?.string ?? "", got = PlanNames.tinyName(title)
            if !same(got, c["tiny"]?.string) { problems.append("\(title.debugDescription): \(got.debugDescription) statt \(c["tiny"]?.string ?? "-")") }
        }
        XCTAssertEqual(problems, [], problems.joined(separator: "\n"))
    }

    func testPlansLikeWeb() throws {
        let plans = try fixture()["plans"]?.array ?? []
        XCTAssertGreaterThanOrEqual(plans.count, 8)
        for p in plans {
            let items = (p["items"]?.array ?? []).map { (title: $0["title"]?.string ?? "", module: PlanNames.moduleKey($0["module_id"])) }
            let got = PlanNames.tinyNames(items)
            let expect = p["expect"]?.object ?? [:]
            XCTAssertEqual(got.count, expect.count, p["name"]?.string ?? "")
            for (title, name) in expect {
                XCTAssertTrue(same(got[title], name.string), "\(p["name"]?.string ?? ""): \(title) -> \(got[title] ?? "-") statt \(name.string ?? "-")")
            }
        }
    }

    /// Verschiedene Faecher im selben Plan haben nie denselben Kurznamen (auch bei vielen aehnlichen Titeln)
    func testDifferentSubjectsNeverShareAName() {
        let titles = ["Einführung in die Testkunde", "Einführung in die Testkultur", "Einführung in die Testkunst", "Einführung in die Testkunde II",
                      "Elektrotechnische Grundlagen der Informatik", "Signale und Systeme (für Elektrotechnik)", "Elektrotechnik", "Elektrotechnik II",
                      "Grundlagen der Testtechnik", "Grundlagen der Testtheorie", "Grundzüge der Testtechnik", "Testpsychologie", "Testpsychiatrie"]
        let names = PlanNames.tinyNames(titles.enumerated().map { (title: $0.element, module: String($0.offset)) })
        XCTAssertEqual(Set(titles.compactMap { names[$0] }).count, titles.count, "\(names)")
        XCTAssertEqual(PlanNames.moduleKey(.number(3)), "3")
        XCTAssertEqual(PlanNames.moduleKey(.string("3")), "3")
        XCTAssertNil(PlanNames.moduleKey(.null))
    }
}
