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
        XCTAssertEqual(cases.map { $0["name"]?.string ?? "" }, ["luh", "abschneiden", "hildesheim", "ohne_lp", "leer", "qis_regel"])
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
        for c in fx["term_of_date"]?.array ?? [] {
            XCTAssertEqual(GradesModel.termOfDate(c["in"]?.string), c["out"]?.int, c["in"]?.string ?? "")
        }
        XCTAssertGreaterThanOrEqual(fx["term_of_date"]?.array?.count ?? 0, 10)
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

    // MARK: Regel des Inhabers 12.11.2026: jede bestandene QIS-Leistung einmal, LP-Summe nur aus QIS

    private func row(_ nr: String, _ text: String, art: String = "", _ semester: String, note: String = "", _ status: String,
                     lp: String = "", versuch: String = "") -> [String: JSONValue] {
        ["pruefungsnr": .string(nr), "text": .string(text), "semester": .string(semester), "note": .string(note),
         "status": .string(status), "credits": .string(lp), "versuch": .string(versuch),
         "raw": .string([nr, text, art, semester, note, status, lp, "", versuch, ""].joined(separator: " | "))]
    }

    private func counted(_ m: [[String: JSONValue]]) -> [String: Double] {
        var out: [String: Double] = [:]
        for r in m where r["counted"] == .bool(true) { out[r["pruefungsnr"]?.string ?? ""] = r["lp_counted"]?.double ?? -1 }
        return out
    }

    /// Ursache 1: Pruefung ohne Modulzeile (Schluesselkompetenz unter einer Bereichszeile) fehlte in LP und "bestanden",
    /// sobald es ein benotetes Modul gab (vorher 8 LP, 1 bestanden)
    func testPassedExamWithoutModuleRowCounts() {
        let rows = [row("1100", "Mathematik I", "WiSe 23/24", note: "2,0", "bestanden", lp: "8"),
                    row("1101", "Mathematik I", art: "PL", "WiSe 23/24", note: "2,0", "bestanden", lp: "8", versuch: "1"),
                    row("9000", "Kompetenzbereich Schlüsselkompetenzen", "", "bestanden", lp: "4"),
                    row("9011", "Englisch B2", art: "SL", "WiSe 24/25", "bestanden", lp: "4", versuch: "1")]
        let s = GradesModel.summary(rows)
        XCTAssertEqual(s["credits"], 12, "Modul 8 LP (Pruefung darunter nicht doppelt) + Englisch 4 LP, Bereich nie")
        XCTAssertEqual(s["passed"], 2)
        XCTAssertEqual(counted(GradesModel.model(rows)), ["1100": 8, "9011": 4])
        XCTAssertEqual(GradesModel.creditsDone(rows), 12, "dieselbe Zahl fuer den Studienverlauf")
    }

    /// Ursache 2: "BE", "bestanden (anerkannt)", "angerechnet" und Note ohne Status galten nicht als bestanden
    func testPassedStatusVariantsAndNoteWithoutStatus() {
        let rows = [row("201", "Seminar A", art: "SL", "SoSe 25", "BE", lp: "3", versuch: "1"),
                    row("202", "Auslandsmodul", art: "AN", "SoSe 25", "bestanden (anerkannt)", lp: "5", versuch: "1"),
                    row("203", "Vorkurs", art: "SL", "SoSe 25", "angerechnet", lp: "2", versuch: "1"),
                    row("204", "Projekt", art: "PL", "SoSe 25", note: "1,7", "", lp: "6", versuch: "1"),
                    row("205", "Klausur X", art: "PL", "SoSe 25", note: "5,0", "", lp: "6", versuch: "1"),
                    row("206", "Klausur Y", art: "PL", "SoSe 26", "angemeldet", versuch: "1"),
                    row("207", "Klausur Z", art: "PL", "SoSe 25", note: "4,0", "nicht bestanden", lp: "6", versuch: "1")]
        let m = GradesModel.model(rows)
        XCTAssertEqual(m.map { $0["passed"] == .bool(true) }, [true, true, true, true, false, false, false])
        XCTAssertEqual(GradesModel.summary(rows)["credits"], 16)
        XCTAssertTrue(GradesModel.isPassed(["status": "be"]))
        XCTAssertFalse(GradesModel.isPassed(["status": "bestanden", "source": "anmeldung"]), "Pruefungsanmeldung nie bestanden")
    }

    /// Ursache 3: "Vertiefung der Betriebssysteme" galt als Bereichszeile (Summe) und fehlte ganz (Tabelle und LP)
    func testVertiefungDerIsAModuleNotABereich() {
        let rows = [row("300", "Vertiefung der Betriebssysteme", "WiSe 24/25", note: "1,7", "bestanden", lp: "5"),
                    row("310", "Vertiefung Informatik", "WiSe 24/25", "bestanden", lp: "15")]
        let m = GradesModel.model(rows)
        XCTAssertEqual(m.map { $0["level"]?.string }, ["modul", "bereich"])
        XCTAssertEqual(GradesModel.summary(rows)["credits"], 5)
        XCTAssertTrue(GradesModel.isBereichText("Schwerpunkt Robotik"))
        XCTAssertFalse(GradesModel.isBereichText("Schwerpunkt in der Medizintechnik"))
    }

    /// Modul + Pruefung zaehlen einmal: gleicher Text, Nummer unter der Modulnummer oder Pruefung direkt unter dem
    /// Modul; LP der Modulzeile, ohne LP dort die der Pruefung; offenes Modul: seine bestandenen Pruefungen (hoechstens
    /// die LP der Modulzeile)
    func testModuleAndItsExamsCountOnce() {
        let rows = [row("1100", "Mathematik I", "WiSe 23/24", note: "2,0", "bestanden", lp: "8"),
                    row("1101", "Klausur Mathematik I", art: "PL", "WiSe 23/24", note: "2,0", "bestanden", lp: "8", versuch: "1"),
                    row("1102", "Übungsschein", art: "SL", "WiSe 23/24", "bestanden", lp: "8", versuch: "1"),
                    // Modulzeile davor bestanden, Pruefung aber zwei Semester spaeter: gehoert zu einem anderen, noch
                    // offenen Modul (dessen Zeile ohne Note und Status liest QIS nicht als Leistung)
                    row("6001", "Labor Regelung", art: "LA", "WiSe 25/26", "bestanden", lp: "2", versuch: "1"),
                    row("4000", "Programmierpraktikum", "SoSe 24", "bestanden"),
                    row("4711", "Praktikum Abnahme", art: "PR", "SoSe 24", "bestanden", lp: "6", versuch: "1"),
                    row("5000", "Elektrotechnik", "SoSe 25", "", lp: "10"),
                    row("5001", "Elektrotechnik", art: "PL", "SoSe 25", note: "2,3", "bestanden", lp: "7", versuch: "1"),
                    row("5002", "Elektrotechnik", art: "LA", "SoSe 25", "bestanden", lp: "7", versuch: "1")]
        XCTAssertEqual(counted(GradesModel.model(rows)), ["1100": 8, "4000": 6, "5001": 7, "5002": 3, "6001": 2])
        XCTAssertEqual(GradesModel.summary(rows)["credits"], 26)
        XCTAssertTrue(GradesModel.nrChild("1101", "1100") && GradesModel.nrChild("1101", "11") && !GradesModel.nrChild("1201", "1100"))
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
