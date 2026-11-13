import Foundation
import XCTest
@testable import UniFlowCore

/// Zusammengesetzte Modultitel (12.11.2026, iPad eines Nutzers, Maschinenbau B.Sc.; Zeilen anonymisiert, Noten und Daten
/// erfunden), dieselben Werte wie tests/test_qis_teilmodule.py. Der Modulkatalog der LUH nennt "Thermodynamik I / Chemie"
/// (beide Teile noetig) und "Tutorien oder Studium Generale" (einer reicht); das QIS fuehrt die Teile: Modul "Studium
/// Generale" mit seiner Leistung, die Leistung "Grundzüge der Chemie" und auf "Info über angemeldete Prüfungen" die
/// Anmeldung "Thermodynamik I".
///
/// Am alten Stand (dfb319c6) falsch: alle vier Zeilen standen im Studienverlauf als "nicht zugeordnet", Studium Generale
/// blieb offen, Thermodynamik I / Chemie stand ohne Stand da (auch mit beiden Teilen bestanden) und die
/// Pruefungsanmeldung zeigte Thermodynamik als "nicht angemeldet".
final class QISTeilmoduleTests: XCTestCase {
    static let abschluss = "Maschinenbau (PO-Version 2017)"
    static let rows: [[String]] = [
        ["PrfNr.", "Bezeichnung der Leistung", "Prf.Art", "Semester ", "Note", "Status", "Leistungspunkte", "Datum", "Versuch", "Vermerk",
         "Freiversuch"],
        ["2500", "Studium Generale", "", "WiSe 24/25", " 0,0", "bestanden", " 4", "24.03.2025", "", "", ""],
        ["132110", "Betriebswirtschaftslehre", "PL", "WiSe 24/25", "0,0 ", "bestanden", "4", "24.03.2025", "1", " LAI", ""],
        ["1310", "Grundzüge der Chemie", "SL", "WiSe 25/26", "", "bestanden", "2", "20.02.2026", "1", "", ""],
    ]
    static let registrations = [
        QISRegistration(pruefungsnr: "1300", text: "Thermodynamik I", semester: "WiSe 26/27", raw: ""),
        QISRegistration(pruefungsnr: "1200", text: "Technische Mechanik III", semester: "WiSe 26/27", raw: ""),
    ]

    static func mod(_ id: String, _ title: String, sem: Int, lp: Int = 5, exam: String? = "Klausur 120 min",
                    area: String = "pflicht") -> JSONValue {
        ["id": .string(id), "title": .string(title), "code": .null, "area": .string(area), "kind": "pflicht", "lp": .number(Double(lp)),
         "semester": .number(Double(sem)), "turnus": "WS", "exam": exam.map(JSONValue.string) ?? .null, "coursework": .null,
         "prerequisites": [], "language": "deutsch", "workload_h": 150, "source_page": 1]
    }

    /// Titel wie im Grundstock (maschinenbau|b.sc.|2017)
    static let catalog: JSONValue = [
        "v": 1, "university": "luh", "program": "Maschinenbau", "degree": "B.Sc.", "po": "2017", "catalog_term": "WS 2026/27",
        "code": "maschinenbau|b.sc.|2017", "regular_semesters": 7, "total_lp": 210,
        "source": ["url": "https://modkat.example/mb.pdf", "fetched_at": "t", "sha256": "x"],
        "areas": [["id": "pflicht", "name": "Pflicht", "kind": "pflicht"],
                  ["id": "schluessel", "name": "Schlüssselkompetenzen", "kind": "pflicht"]],
        "modules": [
            mod("technische-mechanik-3", "Technische Mechanik III", sem: 3),
            mod("thermodynamik-1-chemie", "Thermodynamik I / Chemie", sem: 3, lp: 7, exam: "Klausur - Thermodynamik 120 min"),
            mod("tutorien-oder-studium-generale", "Tutorien oder Studium Generale", sem: 5, lp: 4, exam: nil, area: "schluessel"),
        ],
    ]

    static func grades() -> [QISGrade] { GradeRows.parse(rows: rows, abschluss: abschluss) }

    /// Notenspiegel plus Anmeldungen wie `StudyPlanAPI.gradeRows`
    static func planRows() -> [[String: JSONValue]] {
        var rows: [[String: JSONValue]] = grades().enumerated().map { i, g in
            ["id": .number(Double(i + 1)), "pruefungsnr": g.pruefungsnr.map(JSONValue.string) ?? .null, "text": .string(g.text),
             "semester": g.semester.map(JSONValue.string) ?? .null, "note": g.note.map(JSONValue.string) ?? .null,
             "status": g.status.map(JSONValue.string) ?? .null, "credits": g.credits.map(JSONValue.string) ?? .null,
             "versuch": g.versuch.map(JSONValue.string) ?? .null, "datum": g.datum.map(JSONValue.string) ?? .null,
             "abschluss": .string(abschluss), "raw": .string(g.raw)]
        }
        for r in registrations {
            rows.append(["pruefungsnr": r.pruefungsnr.map(JSONValue.string) ?? .null, "text": .string(r.text),
                         "semester": r.semester.map(JSONValue.string) ?? .null, "note": "", "status": "angemeldet", "versuch": .null,
                         "credits": .null, "datum": .null, "abschluss": .string(abschluss), "raw": .null, "source": "anmeldung"])
        }
        return GradesModel.model(rows)
    }

    static func modules(_ p: JSONValue) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for s in p["semesters"]?.array ?? [] { for m in s["modules"]?.array ?? [] { out[m["id"]?.string ?? ""] = m } }
        return out
    }

    func testTitleParts() {
        let th = StudyPlanEngine.titleParts("Thermodynamik I / Chemie")
        XCTAssertEqual(th.parts.map(\.text), ["Thermodynamik I", "Chemie"])
        XCTAssertTrue(th.all)
        let sg = StudyPlanEngine.titleParts("Tutorien oder Studium Generale")
        XCTAssertEqual(sg.parts.map(\.text), ["Tutorien", "Studium Generale"])
        XCTAssertFalse(sg.all)
        XCTAssertTrue(StudyPlanEngine.titleParts("Ein-/Ausgabe").parts.isEmpty, "/ ohne Leerzeichen trennt nicht")
        XCTAssertTrue(StudyPlanEngine.titleParts("Technische Mechanik III").parts.isEmpty)
        XCTAssertEqual(StudyPlanEngine.partIndex("Thermodynamik I", th.parts), 0)
        XCTAssertEqual(StudyPlanEngine.partIndex("Grundzüge der Chemie", th.parts), 1, "endet mit dem Teil")
        XCTAssertNil(StudyPlanEngine.partIndex("Thermodynamik II", th.parts))
        XCTAssertNil(StudyPlanEngine.partIndex("Biochemie", th.parts), "nur ganze Woerter")
    }

    func testStudyPlanAssignsParts() throws {
        let p = StudyPlanEngine.buildPlan(catalog: Self.catalog, grades: Self.planRows(), settings: [:], today: "2026-11-12")
        XCTAssertEqual(p["unmatched"], [], "jede Leistung und Anmeldung gehoert zu einem Modul")
        let mods = Self.modules(p)
        XCTAssertEqual(mods["tutorien-oder-studium-generale"]?["status"], "bestanden",
                       "Studium Generale (Modulzeile und Leistung) fuellt 'Tutorien oder Studium Generale'")
        let th = try XCTUnwrap(mods["thermodynamik-1-chemie"])
        XCTAssertEqual(th["status"], "angemeldet", "nur Chemie bestanden, Thermodynamik I angemeldet")
        XCTAssertEqual(th["hints"]?.array?.first, "Teil bestanden: Grundzüge der Chemie – es fehlt noch: Thermodynamik I")
        XCTAssertEqual([th["attempt"], th["final"]], [1, false], "der bestandene Teil ist kein Fehlversuch")
        XCTAssertEqual(mods["technische-mechanik-3"]?["status"], "angemeldet")
    }

    func testBothPartsOrModuleRowPassTheModule() throws {
        var both = Self.planRows().filter { $0["source"]?.string != "anmeldung" }
        both.append(["id": 9, "pruefungsnr": "1300", "text": "Thermodynamik I", "semester": "SoSe 26", "note": "2,7", "status": "bestanden",
                     "credits": "5", "versuch": "1", "datum": "10.08.2026", "abschluss": .string(Self.abschluss),
                     "raw": "1300 | Thermodynamik I | PL | SoSe 26 | 2,7 | bestanden | 5 | 10.08.2026 | 1"])
        let p = StudyPlanEngine.buildPlan(catalog: Self.catalog, grades: GradesModel.model(both), settings: [:], today: "2026-11-12")
        let th = try XCTUnwrap(Self.modules(p)["thermodynamik-1-chemie"])
        XCTAssertEqual([th["status"], th["grade"], th["hints"]], ["bestanden", "2,7", .array([])])
        let row: [[String: JSONValue]] = [["id": 1, "pruefungsnr": "1350", "text": "Thermodynamik I / Chemie", "semester": "SoSe 26",
                                           "note": "2,7", "status": "bestanden", "credits": "7", "versuch": .null, "datum": "10.08.2026",
                                           "abschluss": .string(Self.abschluss), "raw": ""]]
        let q = StudyPlanEngine.buildPlan(catalog: Self.catalog, grades: GradesModel.model(row), settings: [:], today: "2026-11-12")
        XCTAssertEqual(Self.modules(q)["thermodynamik-1-chemie"]?["status"], "bestanden")
    }

    func testExamRegistrationSeesThePart() async throws {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: .fixed(berlin: "2026-11-12T10:00:00")!, university: "luh")
        try await b.context.database.transaction { c in
            _ = try StudyCatalogStore.store(c, payload: String(decoding: Self.catalog.serialized(), as: UTF8.self), texts: nil,
                                            origin: "fixture", now: "t")
            try UniStore.storeGrades(c, Self.grades(), now: "t")
            try QISRegistrationsSync.store(c, Self.registrations, now: "t")
        }
        let r = await b.handle(LocalRequest(method: "GET", path: "/api/exam-registration"))
        XCTAssertEqual(r.status, 200)
        let v = try XCTUnwrap(r.json)
        var one: [String: JSONValue] = [:]
        for s in v["suggestions"]?.array ?? [] { one[s["id"]?.string ?? ""] = s }
        XCTAssertEqual(one["thermodynamik-1-chemie"]?["registered"], true)
        XCTAssertEqual(one["thermodynamik-1-chemie"]?["registered_via"], "qis_info")
        XCTAssertEqual(one["technische-mechanik-3"]?["registered_via"], "qis_info")
        XCTAssertEqual(v["open_count"], 0)
    }
}
