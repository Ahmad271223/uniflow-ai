import Foundation
import XCTest
@testable import UniFlowCore

// Studienverlauf gegen die Python-Referenz (app/study_plan.py): engine.json und endpoints.json aus
// tools/gen-study-plan-fixture.py. Erfundener Katalog (29 Module, 6 Semester, Turnus, Voraussetzungen, Wahlpflicht) und
// QIS-Verlaeufe: im Plan, im WS nicht bestanden, nicht bestanden mit abhaengigen Modulen, dritter Versuch, Beginn im
// SS, Wahlpflicht mit Ausgleich ueber 36 LP, Namensvarianten, ohne QIS. Dazu die Endpunkte auf einer Datenbank mit
// eingefrorener Uhr (Mittwoch, 04.11.2026).

private func studyPlanFixture(_ name: String) throws -> JSONValue {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return try JSONValue.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/study-plan-engine/\(name)")))
}

final class StudyPlanEngineTests: XCTestCase {
    private let clock = UniFlowClock.fixed(berlin: "2026-11-04T10:00:00")!

    /// Jeder QIS-Verlauf ergibt exakt den Plan von Python
    func testStudyPlanCasesMatchPython() throws {
        let fx = try studyPlanFixture("engine.json")
        let catalog = try XCTUnwrap(fx["catalog"])
        let cases = fx["cases"]?.array ?? []
        XCTAssertGreaterThanOrEqual(cases.count, 8)
        for c in cases {
            let grades = (c["grades"]?.array ?? []).compactMap(\.object)
            // eigener Katalog je Fall (z. B. mit Studienverlaufsplan `plan_slots`)
            let cat = c["catalog_code"]?.string.flatMap { fx["catalogs"]?[$0] } ?? catalog
            let got = StudyPlanEngine.buildPlan(catalog: cat, grades: grades, settings: c["settings"]?.object ?? [:],
                                                today: c["today"]?.string ?? "")
            XCTAssertNil(jsonDiff(got, c["expected"]), "\(c["name"]?.string ?? ""): \(jsonDiff(got, c["expected"]) ?? "")")
        }
    }

    /// Bausteine: Namensschluessel, Semesternamen, aktuelles Semester, Katalogwahl
    func testStudyPlanPartsMatchPython() throws {
        let fx = try studyPlanFixture("engine.json")
        for n in fx["name_keys"]?.array ?? [] {
            XCTAssertEqual(StudyPlanEngine.nameKey(n["text"]?.string ?? ""), n["key"]?.string, n["text"]?.string ?? "")
        }
        for t in fx["terms"]?.array ?? [] {
            let term = StudyPlanEngine.parseTerm(t["text"]?.string)
            XCTAssertEqual(term, t["term"]?.int, t["text"]?.string ?? "")
            XCTAssertEqual(term.map(StudyPlanEngine.termName), t["name"]?.string)
        }
        for d in fx["current_terms"]?.array ?? [] {
            XCTAssertEqual(StudyPlanEngine.termName(StudyPlanEngine.currentTerm(d["today"]?.string ?? "")), d["term"]?.string)
        }
        let catalogs = fx["catalogs"]?.object ?? [:]
        for p in fx["picks"]?.array ?? [] {
            let list = (p["catalogs"]?.array ?? []).compactMap { $0.string.flatMap { catalogs[$0] } }
            let got = StudyPlanEngine.pickCatalog(list, settings: p["settings"]?.object ?? [:],
                                                  grades: (p["grades"]?.array ?? []).compactMap(\.object))
            XCTAssertEqual(got.catalog?["code"]?.string, p["code"]?.string)
            XCTAssertEqual(got.reason, p["reason"]?.string)
        }
    }

    private func run(_ backend: LocalBackend, _ sql: [JSONValue]) async throws {
        try await backend.context.database.transaction { c in
            for s in sql {
                _ = try c.execute(s["sql"]?.string ?? "", (s["params"]?.array ?? []).map { SQLiteValue(json: $0) ?? .null })
            }
        }
    }

    private func request(_ s: JSONValue) -> LocalRequest {
        let url = URL(string: "uniflow-local://device" + (s["path"]?.string ?? ""))!
        let body = s["body"].map { $0.serialized() }
        return LocalRequest(method: s["method"]?.string ?? "GET", url: url, headers: body == nil ? [:] : ["Content-Type": "application/json"], body: body)
    }

    /// Dieselben Anfragen wie gegen app/server.py: Status und Antwort exakt gleich, danach dieselbe Einstellung (Text)
    func testStudyPlanEndpointsMatchPython() async throws {
        let fx = try studyPlanFixture("endpoints.json")
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        try await run(backend, fx["seed"]?.array ?? [])
        var problems: [String] = []
        for (i, s) in (fx["steps"]?.array ?? []).enumerated() {
            if let sql = s["sql"]?.array { try await run(backend, sql); continue }
            let label = "\(i) \(s["method"]?.string ?? "") \(s["path"]?.string ?? "")"
            let r = await backend.handle(request(s))
            if r.status != s["status"]?.int {
                problems.append("\(label): Status \(r.status) statt \(s["status"]?.int ?? 0) \(String(decoding: r.body, as: UTF8.self))")
                continue
            }
            if let d = jsonDiff(r.json, s["response"]) { problems.append("\(label): \(d)") }
        }
        XCTAssertEqual(problems, [], problems.joined(separator: "\n"))
        let after = try await backend.context.database.withConnection { c -> JSONValue in
            ["settings": .array(try c.rows("SELECT key, value FROM settings WHERE key='study_plan'").map(JSONValue.object))]
        }
        XCTAssertNil(jsonDiff(after, fx["tables_after"]), jsonDiff(after, fx["tables_after"]) ?? "")
    }

    /// Katalog aus dem Speicher statt aus der Tabelle (Quelle austauschbar, solange der Katalog-Abruf fehlt)
    func testMemoryCatalogSource() async throws {
        let fx = try studyPlanFixture("engine.json")
        let catalog = try XCTUnwrap(fx["catalog"])
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock)
        let source = MemoryStudyCatalogSource(catalogs: [catalog, .string("kaputt")],
                                              texts: [StudyPlanEngine.catalogKey(catalog): ["mathematik-1": ["content": "Analysis", "goals": .null, "literature": .null]]])
        let (plan, detail, empty) = try await backend.context.database.withConnection { c in
            (try StudyPlanAPI.plan(c, today: "2026-11-04", source: source),
             try StudyPlanAPI.module(c, id: "mathematik-1", today: "2026-11-04", source: source),
             try StudyPlanAPI.plan(c, today: "2026-11-04", source: MemoryStudyCatalogSource(catalogs: [])))
        }
        XCTAssertEqual(plan["available"]?.bool, true)
        XCTAssertEqual(plan["semesters"]?.array?.first?["term"]?.string, "WiSe 26/27")
        XCTAssertEqual(plan["disclaimer"]?.string, "Verbindlich ist die Prüfungsordnung deiner Hochschule.")
        XCTAssertEqual(detail["texts"]?["content"]?.string, "Analysis")
        XCTAssertEqual(detail["own"]?["status"]?.string, "offen")
        XCTAssertEqual(empty["available"]?.bool, false)
        XCTAssertEqual(empty["reason"]?.string, "no_catalog")
    }
}
