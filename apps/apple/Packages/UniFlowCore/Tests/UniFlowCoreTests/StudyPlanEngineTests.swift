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

    /// Eigene Lage (05.11.2026): verschieben/vorziehen, Bestandenes bleibt, Nachholen folgt der Lage, Turnus- und
    /// Voraussetzungshinweise, LP-Summen je Semester; Wahlbereiche: Plaetze und Schwerpunkt
    func testPlacementsLockingHintsAndSlots() throws {
        let fx = try studyPlanFixture("engine.json")
        let cat = try XCTUnwrap(fx["catalogs"]?["TIBSc22"])
        func g(_ text: String, _ sem: String, _ status: String, _ note: String = "2,0", _ v: String = "") -> [String: JSONValue] {
            ["text": .string(text), "semester": .string(sem), "status": .string(status), "note": .string(note), "versuch": .string(v),
             "pruefungsnr": "", "credits": "", "datum": "", "abschluss": "Technische Informatik (PO-Version 2017)"]
        }
        func where_(_ p: JSONValue) -> [String: (String, JSONValue)] {
            var out: [String: (String, JSONValue)] = [:]
            for s in p["semesters"]?.array ?? [] { for m in s["modules"]?.array ?? [] { out[m["id"]!.string!] = (s["term"]!.string!, m) } }
            return out
        }
        let moved = StudyPlanEngine.buildPlan(catalog: cat, grades: [], settings: [
            "start_term": "WiSe 26/27", "placements": ["rechnernetze": "WiSe 26/27", "mathematik-3": "SoSe 29"]], today: "2026-11-04")
        let rn = try XCTUnwrap(where_(moved)["rechnernetze"])
        XCTAssertEqual(rn.0, "WiSe 26/27")
        XCTAssertEqual(rn.1["placed"], true)
        XCTAssertEqual(rn.1["hints"]?.array?.first?.string, "Laut Katalog nur im Sommersemester angeboten")
        XCTAssertEqual(where_(moved)["mathematik-3"]?.0, "SoSe 29")
        for s in moved["semesters"]?.array ?? [] {
            XCTAssertEqual(s["lp"]?.double, (s["modules"]?.array ?? []).reduce(0.0) { $0 + ($1["lp"]?.double ?? 0) })
        }
        let grades = [g("Programmieren I", "WiSe 25/26", "bestanden"), g("Mathematik I", "WiSe 25/26", "nicht bestanden", "5,0", "1")]
        let locked = StudyPlanEngine.buildPlan(catalog: cat, grades: grades, settings: [
            "placements": ["programmieren-1": "SoSe 27", "mathematik-1": "WiSe 27/28"]], today: "2026-11-04")
        XCTAssertEqual(where_(locked)["programmieren-1"]?.0, "WiSe 25/26", "Bestandenes bleibt im QIS-Semester")
        XCTAssertEqual(where_(locked)["mathematik-1"]?.0, "WiSe 27/28", "Nachholen folgt der eigenen Lage")
        // Wahlbereiche: Plaetze ohne Wahl, mit Schwerpunkt keiner fuer die Gruppe
        let areas = try XCTUnwrap(fx["catalogs"]?["ETBSc25"])
        let open = StudyPlanEngine.buildPlan(catalog: areas, grades: [], settings: [:], today: "2026-11-04")
        let slots = (open["semesters"]?.array ?? []).flatMap { $0["slots"]?.array ?? [] }
        XCTAssertEqual(slots.map { $0["title"]?.string ?? "" }, ["Seminare", "Studium Generale", "Schwerpunkt wählen"])
        let chosen = StudyPlanEngine.buildPlan(catalog: areas, grades: [], settings: ["tracks": ["schwerpunkt": "schwerpunkt-daten"]],
                                               today: "2026-11-04")
        XCTAssertFalse((chosen["semesters"]?.array ?? []).flatMap { $0["slots"]?.array ?? [] }.contains { $0["kind"] == "track" })
    }

    /// Volle Bereiche (Fund 05.11.2026, INFBSc22: "Proseminar" blieb bei "noch 0 von 5 LP offen" stehen): kein Platz
    /// eines Bereichs, dessen Bedarf (LP und/oder Zahl der Module) durch Module gedeckt ist; nur LP, nur Zahl, beides
    func testFullAreasHaveNoOpenSlots() throws {
        let fx = try studyPlanFixture("engine.json")
        let cat = try XCTUnwrap(fx["catalogs"]?["TIBSc26"])
        func plan(_ settings: [String: JSONValue]) -> (slots: [String: [Int]], areas: [String: JSONValue]) {
            var start = settings
            start["start_term"] = "WiSe 26/27"
            let p = StudyPlanEngine.buildPlan(catalog: cat, grades: [], settings: start, today: "2026-11-04")
            var slots: [String: [Int]] = [:]
            for s in p["semesters"]?.array ?? [] {
                for sl in s["slots"]?.array ?? [] { slots[sl["area"]?.string ?? "", default: []].append(s["fachsemester"]?.int ?? 0) }
            }
            var areas: [String: JSONValue] = [:]
            for a in p["areas"]?.array ?? [] { areas[a["id"]?.string ?? ""] = a }
            return (slots, areas)
        }
        let open = plan([:])
        XCTAssertEqual(open.slots, ["akademisches-arbeiten": [4], "vertiefung": [4, 5, 6, 6], "seminare": [5], "labore": [5, 5]])
        // Proseminar: Modul mit Fachsemester 1 deckt den Bereich (wie INFBSc22), bzw. Proseminar auf eigener Lage ohne Platz
        for settings: [String: JSONValue] in [["electives": ["einfuehrung-wa"]],
                                              ["electives": ["proseminar-a"], "placements": ["proseminar-a": "WiSe 27/28"]]] {
            let r = plan(settings)
            XCTAssertNil(r.slots["akademisches-arbeiten"], "\(settings)")
            XCTAssertEqual(r.areas["akademisches-arbeiten"]?["lp_open"]?.double, 0)
            XCTAssertEqual(r.slots["vertiefung"], [4, 5, 6, 6])
        }
        // nur LP: gedeckt -> keine Plaetze, Wahlmodule an die Spanne der Praxis; teilweise -> Rest bleibt
        let full = plan(["custom": [["title": "Auslandsmodul", "lp": 10, "area": "vertiefung"]]])
        XCTAssertNil(full.slots["vertiefung"])
        XCTAssertEqual(full.slots["praxis"], [6, 6])
        let part = plan(["electives": ["vertiefung-c"]])
        XCTAssertEqual(part.slots["vertiefung"], [5, 6, 6])
        XCTAssertEqual(part.areas["vertiefung"]?["lp_open"]?.double, 5)
        XCTAssertEqual(part.areas["praxis"]?["chosen"], .array([]), "Modul in zwei Bereichen zaehlt einmal")
        // nur Zahl: gedeckt -> kein Platz; LP und Zahl: LP gedeckt, 1 von 2 Modulen -> ein Platz bleibt
        let count = plan(["electives": ["labor-a"], "custom": [["title": "Seminar im Ausland", "lp": 3, "area": "seminare"]]])
        XCTAssertNil(count.slots["seminare"])
        XCTAssertEqual(count.slots["labore"], [5])
    }

    /// Verschieben ueber die Endpunkte wie am iPad (Befund 09.11.2026): POST `placements`, danach GET. Geplantes und
    /// Nicht-Bestandenes landen im Ziel; Bestandenes und zur Pruefung Angemeldetes bleiben im Semester aus QIS (die
    /// Ansicht sperrt genau diese, StudyPlanModule.lockReason)
    func testMoveThroughEndpointsOnlyWhatIsMovable() async throws {
        let fx = try studyPlanFixture("endpoints.json")
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: UniFlowClock.fixed(berlin: "2026-11-09T10:00:00")!)
        try await run(backend, (fx["seed"]?.array ?? []) + (fx["steps"]?.array ?? []).flatMap { $0["sql"]?.array ?? [] })
        try await run(backend, [["sql": "INSERT INTO grades(text, semester, status, note, versuch, pruefungsnr, credits, datum, abschluss, raw, fetched_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                                 "params": ["Signale und Systeme", "WiSe 26/27", "angemeldet", "", "1", "", "", "", "Technische Informatik (PO-Version 2017)",
                                            .null, "2026-11-09T08:00:00"]]])
        func terms() async throws -> [String: (term: String, status: String)] {
            let r = await backend.handle(request(["method": "GET", "path": "/api/study-plan"]))
            XCTAssertEqual(r.status, 200)
            var out: [String: (String, String)] = [:]
            for s in r.json?["semesters"]?.array ?? [] {
                for m in s["modules"]?.array ?? [] { out[m["id"]?.string ?? ""] = (s["term"]?.string ?? "", m["status"]?.string ?? "") }
            }
            return out
        }
        let before = try await terms()
        XCTAssertEqual(before["stochastik"]?.term, "SoSe 27")
        XCTAssertEqual(before["stochastik"]?.status, "geplant")
        XCTAssertEqual(before["programmieren-2"]?.status, "nicht_bestanden")
        XCTAssertEqual(before["signale-systeme"]?.term, "WiSe 26/27")
        XCTAssertEqual(before["signale-systeme"]?.status, "angemeldet")
        XCTAssertEqual(before["programmieren-1"]?.status, "bestanden")
        let all: JSONValue = ["stochastik": "SoSe 28", "programmieren-2": "SoSe 28", "signale-systeme": "SoSe 28", "programmieren-1": "SoSe 28"]
        let saved = await backend.handle(request(["method": "POST", "path": "/api/study-plan/settings", "body": ["placements": all]]))
        XCTAssertEqual(saved.status, 200, String(decoding: saved.body, as: UTF8.self))
        let after = try await terms()
        XCTAssertEqual(after["stochastik"]?.term, "SoSe 28", "geplant: verschoben")
        XCTAssertEqual(after["programmieren-2"]?.term, "SoSe 28", "nicht bestanden: Nachholen folgt der Lage")
        XCTAssertEqual(after["signale-systeme"]?.term, "WiSe 26/27", "angemeldet: bleibt im aktuellen Semester")
        XCTAssertEqual(after["programmieren-1"]?.term, "WiSe 25/26", "bestanden: bleibt im QIS-Semester")
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
