import Foundation
import XCTest
@testable import UniFlowCore

// Smart Planner 2.0 (Auftrag 12.11.2026): der Swift-Rechenkern muss fuer jede Eingabe dasselbe JSON liefern wie
// app/smart_planner.py (smart-planner.json aus tools/gen-smart-planner-fixture.py).

private func fixture() throws -> JSONValue {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return try JSONValue.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/local-backend/smart-planner.json")))
}

final class SmartPlannerParityTests: XCTestCase {
    private func same(_ got: JSONValue, _ want: JSONValue?, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        if got != want {
            XCTFail("\(name): Swift weicht von Python ab\nSwift:  \(got.jsonString(sortedKeys: true).prefix(1500))\nPython: \((want ?? .null).jsonString(sortedKeys: true).prefix(1500))",
                    file: file, line: line)
        }
    }

    func testPlanMatchesPython() throws {
        let cases = try fixture()["plan"]?.array ?? []
        XCTAssertGreaterThanOrEqual(cases.count, 45)
        for c in cases {
            same(try SmartPlanner.plan(c["input"] ?? .null), c["output"], c["name"]?.string ?? "?")
        }
    }

    func testBuildDaysMatchesPython() throws {
        for (i, c) in (try fixture()["build_days"]?.array ?? []).enumerated() {
            same(.array(SmartPlanner.buildDays(c["dates"]?.array ?? [], settings: c["settings"]?.object ?? [:])), c["output"], "build_days \(i)")
        }
    }

    func testCreditMatchesPython() throws {
        for (i, c) in (try fixture()["credit"]?.array ?? []).enumerated() {
            same(SmartPlanner.credit(c["sessions"]?.array ?? [], nowTs: c["now_ts"]?.int ?? 0), c["output"], "credit \(i)")
        }
    }

    func testDiffAssignStatsAndHoursMatchPython() throws {
        let fx = try fixture()
        for (i, c) in (fx["diff"]?.array ?? []).enumerated() {
            same(SmartPlanner.diff(c["existing"]?.array ?? [], c["new"]?.array ?? []), c["output"], "diff \(i)")
        }
        for (i, c) in (fx["assign"]?.array ?? []).enumerated() {
            same(SmartPlanner.assignMaterials(c["blocks"]?.array ?? [], c["materials"]?.array ?? [], maxBlock: c["max_block"]?.int ?? 120),
                 c["output"], "assign \(i)")
        }
        for (i, c) in (fx["stats"]?.array ?? []).enumerated() {
            same(SmartPlanner.moduleStats(c["input"] ?? .null), c["output"], "stats \(i)")
        }
        for (k, v) in fx["hours_text"]?.object ?? [:] {
            XCTAssertEqual(SmartPlanner.hoursText(Int(k)!), v.string, "hours_text \(k)")
        }
    }

    func testUnterdeckungText() throws {
        let c = try XCTUnwrap((try fixture()["plan"]?.array ?? []).first { $0["name"] == "unterdeckung_320" })
        let r = try SmartPlanner.plan(c["input"] ?? .null)
        XCTAssertEqual(r["message"]?.string, "670 h nötig, 350 h verfügbar, fehlen 320 h")
        XCTAssertEqual(r["blocks"]?.array?.count, 0)
    }
}
