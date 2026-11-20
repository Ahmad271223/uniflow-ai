import Foundation
import XCTest
@testable import UniFlowCore

// Selbst eingetragene Leistungen (Entscheidung des Inhabers 20.11.2026, GradesManual wie app/grades_manual.py, dieselben
// Faelle wie tests/test_grades_manual.py): abhaken zaehlt die LP einmal in Uni & Noten und Studienverlauf, QIS geht
// spaeter vor (keine Doppelzaehlung), 5,0 zaehlt nicht, Loeschen. Katalog TIBSc22 aus endpoints.json, erfundene Noten.

private func endpointsFixture() throws -> JSONValue {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return try JSONValue.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/study-plan-engine/endpoints.json")))
}

final class GradesManualTests: XCTestCase {
    private typealias QIS = (text: String, semester: String, status: String, note: String, credits: String, nr: String)

    private func qis(_ text: String, _ semester: String, _ status: String = "bestanden", note: String = "2,0", credits: String = "5",
                     nr: String = "") -> QIS {
        (text, semester, status, note, credits, nr)
    }

    private func add(_ b: LocalBackend, _ rows: [QIS]) async throws {
        try await b.context.database.transaction { c in
            for r in rows {
                try c.execute("INSERT INTO grades(text, semester, status, note, versuch, pruefungsnr, credits, datum, abschluss, raw, fetched_at) "
                              + "VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                              [.text(r.text), .text(r.semester), .text(r.status), .text(r.note), .text(""), .text(r.nr), .text(r.credits),
                               .text(""), .null, .null, .text("2026-11-01T08:00:00")])
            }
        }
    }

    /// Katalog (TIBSc22) und drei QIS-Zeilen: 13 LP bestanden; heute 04.11.2026
    private func world() async throws -> LocalBackend {
        let fx = try endpointsFixture()
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: UniFlowClock.fixed(berlin: "2026-11-04T10:00:00")!)
        let catalogSQL = (fx["steps"]?.array ?? []).first { $0["sql"] != nil }?["sql"]?.array ?? []
        let seed = (fx["seed"]?.array ?? []).filter { !($0["sql"]?.string ?? "").hasPrefix("INSERT INTO grades") } + catalogSQL
        try await b.context.database.transaction { c in
            for s in seed {
                _ = try c.execute(s["sql"]?.string ?? "", (s["params"]?.array ?? []).map { SQLiteValue(json: $0) ?? .null })
            }
        }
        try await add(b, [qis("Programmieren I", "WiSe 25/26", note: "1,7"), qis("Mathematik I", "WiSe 25/26", note: "2,3", credits: "8"),
                          qis("Programmieren II", "SoSe 26", "nicht bestanden", note: "5,0")])
        return b
    }

    @discardableResult
    private func call(_ b: LocalBackend, _ method: String, _ path: String, _ body: JSONValue? = nil,
                      status: Int = 200, file: StaticString = #filePath, line: UInt = #line) async throws -> JSONValue {
        let r = await b.handle(LocalRequest(method: method, url: URL(string: "uniflow-local://device" + path)!,
                                            headers: body == nil ? [:] : ["Content-Type": "application/json"], body: body.map { $0.serialized() }))
        XCTAssertEqual(r.status, status, "\(method) \(path): \(r.json.map { $0.jsonString(sortedKeys: true) } ?? "")", file: file, line: line)
        return r.json ?? .null
    }

    private func modules(_ plan: JSONValue) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for s in plan["semesters"]?.array ?? [] { for m in s["modules"]?.array ?? [] { if let id = m["id"]?.string { out[id] = m } } }
        return out
    }

    func testTickOffCountsOnceInAllFigures() async throws {
        let b = try await world()
        let plan0 = try await call(b, "GET", "/api/study-plan"), grades0 = try await call(b, "GET", "/api/grades")
        XCTAssertEqual(plan0["lp_done"], 13)
        XCTAssertEqual(grades0["credits"], 13)
        XCTAssertNil(plan0["lp_manual"])
        XCTAssertNil(grades0["manual"], "ohne Eintraege bleibt die Antwort wie bisher")
        let detail0 = try await call(b, "GET", "/api/study-plan/module/rechnerstrukturen")
        XCTAssertEqual(detail0["own"]?["can_mark"], true)
        XCTAssertEqual(detail0["own"]?["manual"], .null)

        let out = try await call(b, "POST", "/api/grades/manual", ["module_id": "rechnerstrukturen", "grade": "1,7", "semester": "SoSe 26",
                                                                  "lp": 99, "title": "egal"])
        let e = try XCTUnwrap(out["entry"])
        XCTAssertEqual(e["title"], "Rechnerstrukturen", "Titel aus dem Katalog")
        XCTAssertEqual(e["lp"], 5, "LP aus dem Katalog")
        XCTAssertEqual(e["grade"], "1,7")
        XCTAssertEqual(e["semester"], "SoSe 26")
        XCTAssertEqual(e["counted"], true)
        XCTAssertEqual(e["replaced"], false)

        let plan = try await call(b, "GET", "/api/study-plan")
        let m = try XCTUnwrap(modules(plan)["rechnerstrukturen"])
        XCTAssertEqual(m["status"], "bestanden")
        XCTAssertEqual(m["grade"], "1,7")
        XCTAssertEqual(m["manual"], true)
        XCTAssertEqual(plan["lp_done"], 18)
        XCTAssertEqual(plan["lp_manual"], 5)
        let grades = try await call(b, "GET", "/api/grades")
        XCTAssertEqual(grades["credits"], 18)
        XCTAssertEqual(grades["credits_manual"], 5)
        XCTAssertEqual(grades["credits_qis"], 13)
        XCTAssertEqual(grades["passed"]?.double, (grades0["passed"]?.double ?? 0) + 1)
        XCTAssertEqual(grades["graded_count"]?.double, (grades0["graded_count"]?.double ?? 0) + 1)
        XCTAssertEqual(grades["average_exact"]?.double, ((1.7 * 5 + 2.3 * 8 + 1.7 * 5) / 18 * 100).rounded() / 100)
        XCTAssertFalse(grades["grades"]?.array?.contains { $0["source"] == "manuell" } ?? true, "Notenspiegel-Zeilen bleiben QIS")
        let detail = try await call(b, "GET", "/api/study-plan/module/rechnerstrukturen")
        XCTAssertEqual(detail["own"]?["status"], "bestanden")
        XCTAssertEqual(detail["own"]?["grade"], "1,7")
        XCTAssertEqual(detail["own"]?["manual"]?["id"], e["id"])
        XCTAssertEqual(detail["own"]?["attempts"], [], "der eigene Eintrag ist kein QIS-Versuch")

        // nochmal fuer dasselbe Modul: derselbe Eintrag, ohne Note zaehlt er weiter, aber nicht im Schnitt
        let again = try await call(b, "POST", "/api/grades/manual", ["module_id": "rechnerstrukturen", "grade": ""])
        XCTAssertEqual(again["entry"]?["id"], e["id"])
        XCTAssertEqual(again["entry"]?["grade"], .null)
        let g2 = try await call(b, "GET", "/api/grades")
        XCTAssertEqual(g2["credits"], 18)
        XCTAssertEqual(g2["average_exact"], grades0["average_exact"])
        let listed = try await call(b, "GET", "/api/grades/manual")
        XCTAssertEqual(listed["entries"]?.array?.count, 1)
        XCTAssertEqual(listed["credits_manual"], 5)
    }

    func testQISLaterWinsWithoutDoubleCount() async throws {
        let b = try await world()
        try await call(b, "POST", "/api/grades/manual", ["module_id": "rechnerstrukturen", "grade": "1,0"])
        try await add(b, [qis("Rechnerstrukturen", "SoSe 26", note: "2,7")])
        let grades = try await call(b, "GET", "/api/grades")
        let e = try XCTUnwrap(grades["manual"]?.array?.first)
        XCTAssertEqual(e["replaced"], true)
        XCTAssertEqual(e["counted"], false)
        XCTAssertEqual(e["replaced_by"]?["note"], "2,7")
        XCTAssertEqual(grades["credits"], 18, "5 LP aus QIS, nicht noch einmal 5 selbst")
        XCTAssertEqual(grades["credits_manual"], 0)
        let plan = try await call(b, "GET", "/api/study-plan")
        XCTAssertEqual(plan["lp_done"], 18)
        XCTAssertEqual(modules(plan)["rechnerstrukturen"]?["grade"], "2,7")
        XCTAssertNil(modules(plan)["rechnerstrukturen"]?["manual"])
        let detail = try await call(b, "GET", "/api/study-plan/module/rechnerstrukturen")
        XCTAssertEqual(detail["own"]?["can_mark"], false)
        XCTAssertEqual(detail["own"]?["manual"]?["replaced"], true)
        // QIS ueber die Pruefungsnummer (Kuerzel 1234 im Katalog), anderer Text
        try await call(b, "POST", "/api/grades/manual", ["module_id": "programmieren-2", "grade": "3,0"])
        try await add(b, [qis("Prog. 2 (Klausur)", "WiSe 26/27", note: "3,3", nr: "1234")])
        let g2 = try await call(b, "GET", "/api/grades")
        XCTAssertEqual(g2["manual"]?.array?.map { $0["replaced"] }, [true, true])
        XCTAssertEqual(g2["credits"], 23)
    }

    func testGradeFiveIsNotPassedAndRemovalWorks() async throws {
        let b = try await world()
        let out = try await call(b, "POST", "/api/grades/manual", ["module_id": "et-2", "grade": "5,0"])
        XCTAssertEqual(out["entry"]?["passed"], false)
        XCTAssertEqual(out["entry"]?["counted"], false)
        let plan = try await call(b, "GET", "/api/study-plan")
        XCTAssertEqual(plan["lp_done"], 13)
        XCTAssertNotEqual(modules(plan)["et-2"]?["status"], "bestanden")
        let grades = try await call(b, "GET", "/api/grades")
        XCTAssertEqual(grades["credits"], 13)
        XCTAssertEqual(grades["manual"]?.array?.count, 1)
        let id = Int(out["entry"]?["id"]?.double ?? 0)
        try await call(b, "DELETE", "/api/grades/manual/\(id)")
        try await call(b, "DELETE", "/api/grades/manual/\(id)", status: 404)
        let after = try await call(b, "GET", "/api/grades")
        XCTAssertNil(after["manual"])
        XCTAssertEqual(after["credits"], 13)
    }

    func testFreeEntryAndValidation() async throws {
        let b = try await world()
        let out = try await call(b, "POST", "/api/grades/manual", ["title": "  Spanisch   A1 ", "lp": "4,5", "grade": 2])
        XCTAssertEqual(out["entry"]?["title"], "Spanisch A1")
        XCTAssertEqual(out["entry"]?["lp"], 4.5)
        XCTAssertEqual(out["entry"]?["grade"], "2,0")
        let grades = try await call(b, "GET", "/api/grades")
        XCTAssertEqual(grades["credits"], 17.5)
        let plan = try await call(b, "GET", "/api/study-plan")
        XCTAssertEqual(plan["lp_done"], 17.5)
        XCTAssertFalse(plan["unmatched"]?.array?.contains("Spanisch A1") ?? true)
        let bad: [JSONValue] = [["title": "x", "grade": "0,7"], ["title": "x", "grade": "2,35"], ["title": "x", "grade": "sehr gut"],
                                ["title": "x", "lp": "viele"], ["title": "x", "lp": 61], ["title": "x", "semester": "Herbst"],
                                ["title": ""], ["title": "x", "passed": "ja"]]
        for body in bad { try await call(b, "POST", "/api/grades/manual", body, status: 400) }
        try await call(b, "POST", "/api/grades/manual", ["id": 999, "title": "x"], status: 404)
    }

    func testResolveMatchesPartsButNeverAreaRows() {
        let rows = GradesModel.model([
            ["text": "Thermodynamik I", "semester": "WiSe 25/26", "status": "bestanden", "note": "2,0", "credits": "5"],
            ["text": "Studium Generale", "semester": "WiSe 25/26", "status": "", "note": "", "credits": "5", "versuch": ""],
            ["text": "Kompetenzbereich Pflichtmodule", "semester": "", "status": "bestanden", "note": "", "credits": "60"],
        ])
        let out = GradesManual.resolve(rows, [
            ["id": 1, "title": "Thermodynamik I / Chemie", "code": .null, "passed": true, "lp": 10],
            ["id": 2, "title": "Pflichtmodule", "code": .null, "passed": true, "lp": 5],
            ["id": 3, "title": "Chemie", "code": .null, "passed": true, "lp": 5],
        ])
        XCTAssertEqual(out.map { $0["replaced"] }, [true, false, false], "Teil laut QIS bestanden; Bereichszeilen nie")
    }

    /// Nie im Geraete-Abgleich (Datenschutz: Noten bleiben auf dem Geraet, Abgleich ueber Geraete braucht eine Entscheidung)
    func testNotInDeviceSync() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let sync = try String(contentsOf: url.appendingPathComponent("Sources/UniFlowCore/DeviceSync.swift"), encoding: .utf8)
        XCTAssertFalse(sync.contains("grades_manual"))
    }
}
