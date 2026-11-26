import Foundation
import XCTest
@testable import UniFlowCore

/// Mehr-Faecher-Studiengang (26.11.2026, echtes Konto Uni Hildesheim): das LSF fuehrt jedes Fach eines Zwei-Faecher-
/// Bachelors als eigenen "Studiengang" unter demselben Abschluss. Die App nahm ein Fach als ganzen Studiengang ("69 von
/// 72 LP", ein anderes Fach als "Früheres Studium"). Jetzt: ein Studiengang mit 180 LP, je Fach seine LP, bestanden je
/// Semester. Gleiche Faelle wie tests/test_study_combined_degree.py. Bezeichnungen im Aufbau der echten Seite,
/// Leistungen erfunden.
final class StudyCombinedDegreeTests: XCTestCase {
    private static let b5 = "Abschluss: [B5] Polyvalenter Zwei-Fächer-Bachelor mit Lehramtsoption Realschule Studiengang: "
    private let math = b5 + "[105] Mathematik PO-Version: 2025"
    private let econ = b5 + "[011] Wirtschaft PO-Version: 2014"
    private let esw = b5 + "[ESW] Erziehungs- und Sozialwissenschaften PO-Version: 2022"
    private let old = "Abschluss: [82] Bachelor Studiengang: [052] B.A. Erziehungswissenschaft PO-Version: 2023"

    private func row(_ label: String, _ nr: String, _ text: String, _ semester: String = "", note: String = "", status: String = "bestanden",
                     lp: String = "0", versuch: String = "", datum: String = "") -> [String: JSONValue] {
        ["abschluss": .string(label), "pruefungsnr": .string(nr), "text": .string(text), "semester": .string(semester), "note": .string(note),
         "status": .string(status), "credits": .string(lp), "versuch": .string(versuch), "datum": .string(datum), "raw": ""]
    }

    private func account(_ label: String, _ text: String, _ lp: String, note: String = "") -> [String: JSONValue] {
        ["abschluss": .string(label), "pruefungsnr": .null, "text": .string("Gesamtkonto: " + text), "semester": .null,
         "note": note.isEmpty ? .null : .string(note), "status": .null, "credits": .string(lp), "versuch": .null, "datum": .null,
         "raw": .string("Konto 10 | \(text) | \(note) |  | \(lp) |  |  | ")]
    }

    private var raw: [[String: JSONValue]] {
        [account(math, "Mathematik", "9", note: "0,0"),
         row(math, "25011", "TM 1: Arithmetik / 5105 Arithmetik", "WiSe 25/26", note: "3,3", lp: "6", versuch: "1", datum: "20.02.2026"),
         row(math, "22021", "TM: Einführung in die Didaktik / 5201 Einführung", "SoSe 26", lp: "3", versuch: "1", datum: "15.07.2026"),
         account(math, "Vorläufige Gesamtnote aller Fächer", "20", note: "2,65"),
         account(econ, "Wirtschaft", "6"),
         row(econ, "14010", "BM 1: Betriebswirtschaftslehre I", "WiSe 25/26", note: "2,0", lp: "6"),
         row(econ, "14011", "TM: Grundlagen I (V) / 3200 Grundlagen 1", "WiSe 25/26", note: "2,0", lp: "3", versuch: "1", datum: "09.02.2026"),
         row(econ, "14012", "TM: Grundlagen II (Ü) / 3201 Grundlagen 2", "WiSe 25/26", lp: "3", versuch: "1", datum: "09.02.2026"),
         account(esw, "Pädagogik", "5"),
         row(esw, "21010", "BM 1: Handeln in der Schule", "SoSe 26", lp: "5"),
         row(esw, "21011", "TM: Schulpädagogik / 0424 Einführung", "SoSe 26", lp: "5", versuch: "1", datum: "01.07.2026")]
    }

    private var grades: [[String: JSONValue]] { GradesModel.model(raw) }

    func testSubjectsOfOneDegreeAreOneProgramWith180LP() {
        let grades = self.grades
        XCTAssertEqual(StudyPlanEngine.combinedDegree(grades),
                       .init(degree: "Polyvalenter Zwei-Fächer-Bachelor mit Lehramtsoption Realschule", labels: [math, econ, esw]))
        XCTAssertEqual(StudyPlanEngine.hisLabel(math),
                       .init(degreeKey: "[B5] Polyvalenter Zwei-Fächer-Bachelor mit Lehramtsoption Realschule",
                             degree: "Polyvalenter Zwei-Fächer-Bachelor mit Lehramtsoption Realschule", subject: "Mathematik", po: "2025"))
        XCTAssertNil(StudyPlanEngine.hisLabel("Technische Informatik (PO-Version 2017)"))
        let mine = StudyPlanEngine.gradesForCatalog(grades, catalog: ["program": "Mathematik im Polyvalenten Zwei-Fächer-Bachelor"],
                                                    university: "hildesheim")
        XCTAssertEqual(Set(mine.compactMap { $0["abschluss"]?.string }), [math], "die anderen Faecher zaehlen nicht im Katalog Mathematik")
        XCTAssertEqual(GradesModel.creditsDone(mine), 9)
        let d = StudyPlanEngine.degreeOverview(grades, current: mine)
        XCTAssertEqual(d["name"], "Polyvalenter Zwei-Fächer-Bachelor mit Lehramtsoption Realschule")
        XCTAssertEqual(d["lp_total"], 180)
        XCTAssertEqual(d["lp_done"], 20)
        XCTAssertEqual(d["official_lp"], 20)
        XCTAssertEqual(d["official_grade"], "2,65")
        let subjects: [[JSONValue]] = (d["subjects"]?.array ?? []).map { s in
            [s["program"] ?? .null, s["po"] ?? .null, s["lp_done"] ?? .null, s["passed"] ?? .null, s["current"] ?? .null]
        }
        let expected: [[JSONValue]] = [[.string("Mathematik"), .string("2025"), .number(9), .number(2), .bool(true)],
                                       [.string("Wirtschaft"), .string("2014"), .number(6), .number(1), .bool(false)],
                                       [.string("Erziehungs- und Sozialwissenschaften"), .string("2022"), .number(5), .number(1), .bool(false)]]
        XCTAssertEqual(subjects, expected)
        XCTAssertEqual(StudyPlanEngine.degreeOverview(grades, current: mine, lpManual: 4)["lp_done"], 24, "selbst eingetragene LP zaehlen mit")
        XCTAssertEqual(StudyPlanEngine.degreeTotal("Master of Education"), 120)
        XCTAssertNil(StudyPlanEngine.degreeTotal("Staatsexamen"))
    }

    func testPassedTermsListWhatWasPassedInWhichSemester() {
        let terms = StudyPlanEngine.passedTerms(grades)
        func heads(_ t: [JSONValue]) -> [[JSONValue]] { t.map { e in [e["name"] ?? .null, e["lp"] ?? .null] } }
        XCTAssertEqual(heads(terms), [[.string("WiSe 25/26"), .number(12)], [.string("SoSe 26"), .number(8)]])
        let first: [JSONValue] = terms[0]["rows"]?.array ?? []
        let cells: [[JSONValue]] = first.map { r in [r["text"] ?? .null, r["lp"] ?? .null, r["program"] ?? .null] }
        XCTAssertEqual(cells, [[.string("TM 1: Arithmetik / 5105 Arithmetik"), .number(6), .string("Mathematik")],
                               [.string("BM 1: Betriebswirtschaftslehre I"), .number(6), .string("Wirtschaft")]])
        XCTAssertEqual(first.first?["note"], .string("3,3"))
        // QIS der LUH: dieselbe Liste, ohne Fach; eine Leistung ohne Semester und ohne Datum steht am Ende
        let luh = GradesModel.model([
            ["abschluss": "Informatik (PO-Version 2017)", "pruefungsnr": "1100", "text": "Mathematik I", "semester": "WiSe 23/24",
             "note": "2,0", "status": "bestanden", "credits": "8", "versuch": "", "datum": "", "raw": ""],
            ["abschluss": "Informatik (PO-Version 2017)", "pruefungsnr": "1200", "text": "Programmieren", "semester": "",
             "note": "", "status": "bestanden", "credits": "5", "versuch": "", "datum": "", "raw": ""]])
        let t = StudyPlanEngine.passedTerms(luh)
        XCTAssertEqual(heads(t), [[.string("WiSe 23/24"), .number(8)], [.null, .number(5)]])
        let programs: [JSONValue] = t.flatMap { e in e["rows"]?.array ?? [] }.map { r in r["program"] ?? .null }
        XCTAssertEqual(programs, [.null, .null])
        XCTAssertNil(StudyPlanEngine.combinedDegree(luh))
        XCTAssertEqual(StudyPlanEngine.degreeOverview(luh, current: luh), .null)
    }

    func testChangeOfProgramInAPlainBachelorStaysAnEarlierStudy() {
        // zwei Studiengaenge unter "Bachelor" ohne Mehr-Faecher-Abschluss (Wechsel, 14.11.2026): kein gemeinsamer Studiengang
        let sop = "Abschluss: [82] Bachelor Studiengang: [161] B.A. Sozialpädagogik PO-Version: 2025"
        let change = GradesModel.model([row(old, "1", "Einführung", "WiSe 24/25", note: "2,0", lp: "6"),
                                        row(sop, "2", "Grundlagen", "SoSe 26", note: "2,0", lp: "6")])
        XCTAssertNil(StudyPlanEngine.combinedDegree(change))
        let kept = StudyPlanEngine.gradesForCatalog(change, catalog: ["program": "Sozialpädagogik"], university: "hildesheim")
        XCTAssertEqual(kept.compactMap { $0["text"]?.string }, ["Grundlagen"])
        // ein frueheres Studium neben dem Mehr-Faecher-Studiengang bleibt eines; seine LP wie in Uni & Noten
        let both = GradesModel.model(raw + [row(old, "1", "Einführung", "WiSe 23/24", note: "2,0", lp: "6")])
        XCTAssertEqual(StudyPlanEngine.combinedDegree(both)?.labels, [math, econ, esw])
        let economics = grades.filter { $0["abschluss"]?.string == econ && !StudyPlanEngine.isBereich($0) }
        XCTAssertEqual(StudyPlanAPI.earlierStudies(economics).first?["lp"], 6, "Modul und Teilmodule nicht doppelt (vorher 12)")
    }

    /// Eigene Module mit Arbeitsaufwand und Inhalt (26.11.2026): was die App nicht erkennt, legt man selbst an
    func testCustomEntriesKeepHoursAndContent() {
        let rows = StudyPlanEngine.cleanCustom([
            ["title": " Seminar Medien ", "lp": 5, "semester": 3, "workload_h": 150, "content": "  Grundlagen\nPraxisprojekt  "],
            ["title": "Ohne Angaben", "lp": 2.5, "workload_h": 0, "content": "   "],
            ["title": "Zu viel", "workload_h": 99999, "content": .string(String(repeating: "x", count: 2100))],
            ["title": "Text statt Zahl", "workload_h": "90"]])
        XCTAssertEqual(JSONValue.object(rows[0].json), ["id": "eigen-1", "title": "Seminar Medien", "lp": 5, "area": .null, "semester": 3,
                                                        "workload_h": 150, "content": "Grundlagen\nPraxisprojekt"])
        XCTAssertNil(rows[1].workloadH)
        XCTAssertNil(rows[1].content)
        XCTAssertNil(rows[2].workloadH)
        XCTAssertEqual(rows[2].content?.count, 2000)
        XCTAssertNil(rows[3].workloadH)
    }
}
