import Foundation
import XCTest
@testable import UniFlowCore

// Notenspiegel (app/grades_model.py, 28.10.2026) gegen die Python-Referenz: grades.json (tools/gen-grades-fixture.py)
// mit erfundenen Notenspiegeln im Aufbau von LUH-QIS und LSF Hildesheim; dazu die Hilfsfunktionen einzeln.

private func fixture() throws -> JSONValue {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return try JSONValue.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/local-backend/grades.json")))
}

final class GradesModelTests: XCTestCase {

    /// Lokales Backend mit genau diesen Zeilen in `grades` (wie nach qis.store_grades am PC)
    private func backend(rows: [JSONValue]) async throws -> LocalBackend {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: .fixed(berlin: "2026-10-29T09:00:00")!)
        try await b.context.database.transaction { c in
            try c.execute("DELETE FROM grades")
            for row in rows {
                let cols = (row.object ?? [:]).keys.sorted()
                let sql = "INSERT INTO grades(\(cols.joined(separator: ", "))) VALUES (\(cols.map { _ in "?" }.joined(separator: ", ")))"
                try c.execute(sql, cols.map { SQLiteValue(json: row[$0] ?? .null) ?? .null })
            }
        }
        return b
    }

    private func grades(_ b: LocalBackend) async throws -> JSONValue {
        let r = await b.handle(LocalRequest(method: "GET", url: URL(string: "uniflow-local://device/api/grades")!, headers: [:], body: nil))
        XCTAssertEqual(r.status, 200)
        return try XCTUnwrap(r.json)
    }

    func testEndpointMatchesPythonServer() async throws {
        let cases = try fixture()["cases"]?.array ?? []
        XCTAssertEqual(cases.map { $0["name"]?.string ?? "" }, ["luh", "abschneiden", "hildesheim", "ohne_lp", "leer"])
        for c in cases {
            let name = c["name"]?.string ?? ""
            let local = try await grades(try await backend(rows: c["rows"]?.array ?? []))
            let expected = c["response"] ?? .null
            XCTAssertEqual(local, expected, "\(name):\n  lokal  \(local.jsonString(sortedKeys: true).prefix(3000))\n  Python \(expected.jsonString(sortedKeys: true).prefix(3000))")
            // Reihenfolge der Zeilen (Bereiche, Module, Pruefungen; neueste Semester zuerst) ausdruecklich
            XCTAssertEqual(local["grades"]?.array?.map { $0["id"] }, expected["grades"]?.array?.map { $0["id"] }, name)
        }
    }

    /// Gegenprobe: die bisherige Rechnung (QISParser.summary, jede Note 1,0-5,0, Doppelte und Pruefungszeilen zaehlen
    /// mit) liegt beim LUH-Aufbau neben dem Schnitt der Module
    func testOldFlatAverageDiffersOnLUHLayout() throws {
        let luh = try XCTUnwrap(try fixture()["cases"]?.array?.first { $0["name"]?.string == "luh" })
        let rows = luh["rows"]?.array ?? []
        let old = QISParser.summary(rows.map {
            QISGrade(pruefungsnr: $0["pruefungsnr"]?.string, text: $0["text"]?.string ?? "", semester: $0["semester"]?.string,
                     note: $0["note"]?.string, status: $0["status"]?.string, credits: $0["credits"]?.string,
                     versuch: $0["versuch"]?.string, datum: $0["datum"]?.string, abschluss: nil, raw: $0["raw"]?.string ?? "")
        })
        let new = luh["response"]?["average_exact"]?.double
        XCTAssertNotNil(new)
        XCTAssertNotEqual(old.average, new, "die alte Rechnung ergaebe denselben Schnitt; der Fall prueft dann nichts")
    }

    func testHelpersMatchPython() throws {
        let fx = try fixture()
        for c in fx["norm_semester"]?.array ?? [] {
            XCTAssertEqual(GradesModel.normSemester(c["in"]?.string), c["out"]?.string, c["in"]?.string ?? "")
        }
        for c in fx["truncate1"]?.array ?? [] {
            let x = try XCTUnwrap(c["in"]?.double)
            XCTAssertEqual(GradesModel.truncate1(x), c["out"]?.double, "\(x)")
        }
        for c in fx["fields_from_raw"]?.array ?? [] {
            let raw = c["in"]?.string ?? ""
            let expected = (c["out"]?.object ?? [:]).mapValues { $0.string ?? "" }
            XCTAssertEqual(GradesModel.fieldsFromRaw(raw), expected, raw)
        }
        XCTAssertGreaterThanOrEqual(fx["fields_from_raw"]?.array?.count ?? 0, 25)
    }

    /// Wie Python nach Codepunkten: dieselbe Pruefung mit zerlegtem Umlaut ist kein Doppel (Swifts `==` saehe eins)
    func testDuplicatesCompareCodePoints() {
        let composed = "Pr\u{FC}fung", decomposed = "Pru\u{308}fung"
        XCTAssertEqual(composed, decomposed, "Swift vergleicht kanonisch")
        let rows: [[String: JSONValue]] = [composed, decomposed].map { t in
            ["text": .string(t), "semester": .string("SoSe 25"), "note": .string("2,0"), "status": .string("bestanden"), "raw": .string("")]
        }
        XCTAssertEqual(GradesModel.model(rows).count, 2)
    }
}
