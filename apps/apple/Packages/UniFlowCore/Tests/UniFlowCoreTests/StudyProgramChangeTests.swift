import Foundation
import XCTest
@testable import UniFlowCore

/// Wechsel des Studiengangs (14.11.2026, erstes echtes Hildesheim-Konto): neuester Studiengang statt haeufigster,
/// Liste fuer die Frage "Welchen Studiengang studierst du gerade?", keine Leistungen des alten Studiengangs im neuen
/// Katalog. Gleiche Faelle wie tests/test_study_program_change.py.
final class StudyProgramChangeTests: XCTestCase {
    private let ew = "Abschluss: [82] Bachelor Studiengang: [052] B.A. Erziehungswissenschaft PO-Version: 2023"
    private let sop = "Abschluss: [82] Bachelor Studiengang: [161] B.A. Sozialpädagogik PO-Version: 2025"

    private func g(_ label: String, _ text: String) -> [String: JSONValue] {
        ["abschluss": .string(label), "text": .string(text), "note": "2,0", "status": "bestanden", "semester": "WiSe 24/25"]
    }

    func testNewestProgramWinsOverTheOneWithMostGrades() {
        let grades = (0..<5).map { g(ew, "Modul \($0)") } + [g(sop, "Grundlagen der Sozialpädagogik")]
        XCTAssertEqual(StudyPlanEngine.abschlussOf(grades), sop)
        XCTAssertEqual(StudyPlanEngine.currentLabel(["Technische Informatik (PO-Version 2017)", "Technische Informatik (PO-Version 2017)",
                                                     "Technische Informatik (PO-Version 2022)"]), "Technische Informatik (PO-Version 2022)")
        XCTAssertEqual(StudyPlanEngine.currentLabel(["A", "B", "B"]), "B", "ohne PO-Version: der haeufigste")
        let progs = StudyPlanEngine.programsOf(grades, university: "hildesheim")
        XCTAssertEqual(progs.compactMap { $0["program"]?.string }, ["Sozialpädagogik", "Erziehungswissenschaft"])
        XCTAssertEqual(progs.first?["code"]?.string, "sozialpaedagogik|b.a.|2025")
        XCTAssertEqual(progs.last?["grades"]?.int, 5)
    }

    func testGradesOfTheOldProgramDoNotCountInTheNewCatalog() {
        let grades = [g(ew, "Einführung in die Erziehungswissenschaft"), g(sop, "Grundlagen der Sozialpädagogik"),
                      ["abschluss": "", "text": "ohne Angabe", "note": "1,0", "status": "bestanden"],
                      g("Abschluss: Unbekannt PO-Version: 2020", "unbekannt")]
        let kept = StudyPlanEngine.gradesForCatalog(grades, catalog: ["program": "Sozialpädagogik"], university: "hildesheim")
        XCTAssertEqual(kept.compactMap { $0["text"]?.string }, ["Grundlagen der Sozialpädagogik", "ohne Angabe", "unbekannt"])
        XCTAssertEqual(StudyPlanEngine.gradesForCatalog(grades, catalog: nil, university: "hildesheim").count, 4)
    }

    /// Nur Leistungen aus Erziehungswissenschaft, gewaehlt ist Sozialpaedagogik: das Register findet deren Eintrag zuerst
    func testChosenCodeIsFoundBeforeTheGradesLabel() {
        let s = StudySources.bundled
        XCTAssertEqual(s.match(code: "sozialpaedagogik|b.a.|2025", university: "hildesheim", qisLabel: ew)?.program, "Sozialpädagogik")
        XCTAssertEqual(s.match(label: ew, university: "hildesheim")?.program, "Erziehungswissenschaft")
        XCTAssertNil(s.match(code: "2023", university: "hildesheim"), "eine PO-Jahreszahl ist kein Kuerzel")
    }

    /// Liste zum Waehlen wie `study_catalog.programs` (Werte aus der Python-Referenz)
    func testProgramListMatchesPython() async throws {
        let s = StudySources.bundled
        let hi = s.programs(university: "hildesheim")
        XCTAssertEqual(hi.count, 177, "113 Studiengaenge (mit Data Science) und 64 Neben-/Begleitfaecher aus der LSF-Uebersicht")
        XCTAssertEqual(hi.prefix(4).map { "\($0["program"]?.string ?? "") \($0["degree"]?.string ?? "")" },
                       ["Angewandte Informatik B.Sc.", "Angewandte Informatik M.Sc.", "Bachelor Internationales Informationsmanagement mit dem Schwerpunkt Angewandte Informationswissenschaften Nebenfach", "Bachelor Internationales Informationsmanagement mit dem Schwerpunkt Angewandte Sprachwissenschaften Nebenfach"])
        let sop = try XCTUnwrap(hi.first { $0["program"]?.string == "Sozialpädagogik" })
        XCTAssertEqual(sop["pos"]?.array?.first?["code"]?.string, "sozialpaedagogik|b.a.|2025")
        XCTAssertEqual(sop["pos"]?.array?.first?["catalog_terms"], ["SS 2025"])
        XCTAssertEqual(s.programs(university: "luh").count, 223)
        // Endpunkt mit Suche
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: .fixed(berlin: "2026-11-14T10:00:00")!, university: "hildesheim")
        let r = await b.handle(LocalRequest(method: "GET", url: URL(string: "uniflow-local://device/api/study-catalog/programs?q=sozialp")!))
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.json?["programs"]?.array?.compactMap { $0["program"]?.string }, ["Sozialpädagogik"])
    }

    /// Eingefuegter Link zum Modulhandbuch Sozialpaedagogik (Testkonto): Kuerzel aus dem Register, Katalog dieses Links
    /// gilt vor dem Studiengang aus dem Notenspiegel
    func testPastedLinkToAKnownCatalog() {
        let link = "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5273"
        XCTAssertEqual(StudySources.bundled.code(forCatalogURL: link, university: "hildesheim"), "sozialpaedagogik|b.a.|2025")
        XCTAssertNil(StudySources.bundled.code(forCatalogURL: "https://example.org/x.pdf", university: "hildesheim"))
        func cat(_ program: String, _ code: String, _ url: String) -> JSONValue {
            ["program": .string(program), "code": .string(code), "po": "2025", "modules": [], "source": ["url": .string(url)]]
        }
        let cats = [cat("Erziehungswissenschaft", "erziehungswissenschaft|b.a.|2023", "https://www.uni-hildesheim.de/qm/processmanagement/download.php?fileID=5003"),
                    cat("Sozialpädagogik", "sozialpaedagogik|b.a.|2025", link)]
        let grades = [g(ew, "Einführung")]
        XCTAssertEqual(StudyPlanEngine.pickCatalog(cats, settings: ["catalog_url": .string(link)], grades: grades).catalog?["program"]?.string,
                       "Sozialpädagogik")
        XCTAssertEqual(StudyPlanEngine.pickCatalog(cats, settings: [:], grades: grades).catalog?["program"]?.string,
                       "Erziehungswissenschaft", "ohne Link und ohne Wahl: Studiengang aus dem Notenspiegel")
    }

    /// Neben-/Begleitfaecher und "einmal nachfragen", wenn der Notenspiegel einen neueren Studiengang nennt
    func testMinorsAndAskOnce() {
        XCTAssertEqual(StudyPlanAPI.cleanMinors([" bwl|b.a.|2022 ", "bwl|b.a.|2022", "", 3, "a", "b", "c"]), ["bwl|b.a.|2022", "a", "b"])
        let progs = StudyPlanEngine.programsOf([g(sop, "x"), g(ew, "y")], university: "hildesheim")
        var s = StudyPlanAPI.Settings(po: "erziehungswissenschaft|b.a.|2023", startTerm: nil, electives: [])
        let m = StudyPlanAPI.programMismatch(progs, settings: s, university: "hildesheim")
        XCTAssertEqual(m["code"]?.string, "sozialpaedagogik|b.a.|2025")
        XCTAssertEqual(m["chosen"]?.string, "Erziehungswissenschaft")
        s.programAck = "sozialpaedagogik|b.a.|2025"
        XCTAssertEqual(StudyPlanAPI.programMismatch(progs, settings: s, university: "hildesheim"), .null, "schon abgelehnt")
        let old = StudyPlanEngine.programsOf([g(ew, "y")], university: "hildesheim")
        XCTAssertEqual(StudyPlanAPI.programMismatch(old, settings: .init(po: "sozialpaedagogik|b.a.|2025", startTerm: nil, electives: []),
                                                    university: "hildesheim"), .null, "alter Studiengang mit aelterer PO: nicht fragen")
    }

    /// Wechsel: alter Studiengang mit Noten, neuer ohne -> "Früheres Studium" je Studiengang, LP nur der bestandenen
    func testEarlierStudiesGroupByProgram() {
        var a = g(ew, "TM 1: Einführung"); a["credits"] = "6"
        var b = g(ew, "TM 2: Kindheit"); b["credits"] = "3"; b["status"] = "angemeldet"
        var c = g("Abschluss: [82] Bachelor Studiengang: [021] Betriebswirtschaftslehre (Begleitfach) PO-Version: 2022", "BWL"); c["credits"] = "7,5"
        let e = StudyPlanAPI.earlierStudies([a, b, c])
        XCTAssertEqual(e.compactMap { $0["program"]?.string }, ["Erziehungswissenschaft", "Betriebswirtschaftslehre (Begleitfach)"])
        XCTAssertEqual(e.compactMap { $0["count"]?.int }, [2, 1])
        XCTAssertEqual(e.compactMap { $0["lp"]?.double }, [6, 7.5])
        XCTAssertEqual(e.first?["rows"]?.array?.first?["text"]?.string, "TM 1: Einführung")
        // der neue Katalog nimmt nichts aus Erziehungswissenschaft; das Begleitfach kennt das Register nicht, es bleibt
        XCTAssertEqual(StudyPlanEngine.gradesForCatalog([a, b, c], catalog: ["program": "Sozialpädagogik"], university: "hildesheim")
            .compactMap { $0["text"]?.string }, ["BWL"])
    }

    /// Eigener Link zu einer Hildesheimer Studienordnung, die das Register nicht kennt: der Lauf liest sie mit dem Leser
    /// fuer dieses Format (Textstuecke mit Lage, nicht der rohe PDFKit-Text); erfundene Seiten wie in Python
    func testPastedLinkToAHildesheimStudyRegulationIsRead() async throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url.deleteLastPathComponent() }
        let fx = try JSONValue.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/study-catalog-hildesheim/lesefassung.json")))
        let pages = (fx["pages"]?.array ?? []).compactMap(\.string)
        let items = (fx["items"]?.array ?? []).map { page in
            (page.array ?? []).map { StudyPlanTextItem(x: $0.array?[0].double ?? 0, y: $0.array?[1].double ?? 0, text: $0.array?[2].string ?? "") }
        }
        let link = "https://example.org/studienordnung.pdf"
        let db = try SQLiteDatabase(path: SQLiteDatabase.inMemory)
        try await db.withConnection { c in
            try Migrations.migrate(c, university: "hildesheim")
            try c.execute("INSERT OR REPLACE INTO settings(key, value) VALUES ('study_plan', ?)", [.text(#"{"po": null, "catalog_url": "\#(link)"}"#)])
        }
        let loader = StudyCatalogPipelineTests.StubLoader()
        loader.responses[link] = StudyCatalogFetchResult(status: 200, data: Data("%PDF".utf8))
        let env = StudyCatalogPipeline.Environment(loader: loader, library: nil, pdfText: { _ in pages }, planText: { _ in items })
        let st = await StudyCatalogPipeline.run(db: db, env: env)
        XCTAssertEqual(st["state"]?.string, "ready", "\(st)")
        XCTAssertEqual(st["program"]?.string, fx["head"]?["program"]?.string)
        XCTAssertEqual(st["modules"]?.int, fx["catalog"]?["modules"]?.array?.count)
        XCTAssertEqual(st["catalog_term"]?.string, fx["head"]?["catalog_term"]?.string)
        XCTAssertEqual(st["code"]?.string?.hasPrefix("link-"), true)
    }

    /// Vorgaengerordnungen: Werte im Kern gleich packages/shared-contracts/study-orders.json; Vorschlag nur bei frueherem
    /// Studienbeginn, nicht ohne Beginn, nicht nach Ablehnung oder mit der alten schon gewaehlt
    func testOlderOrderSuggestion() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url.deleteLastPathComponent() }
        let file = try JSONValue.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/study-orders.json")))
        let fromFile = (file["orders"]?.array ?? []).map { o in
            StudyPlanAPI.Order(university: o["university"]?.string ?? "", code: o["code"]?.string ?? "", since: o["since"]?.string ?? "",
                               program: o["older"]?["program"]?.string ?? "", degree: o["older"]?["degree"]?.string ?? "",
                               po: o["older"]?["po"]?.string ?? "", url: o["older"]?["url"]?.string ?? "")
        }
        XCTAssertEqual(StudyPlanAPI.orders, fromFile)
        let code = "sozialpaedagogik|b.a.|2025"
        var s = StudyPlanAPI.Settings(po: code, startTerm: nil, electives: [])
        let sug = StudyPlanAPI.orderSuggestion(settings: s, code: code, startTerm: "WiSe 24/25", university: "hildesheim")
        XCTAssertEqual(sug["program"]?.string, "Sozial- und Organisationspädagogik")
        XCTAssertEqual(sug["po"]?.string, "2020")
        XCTAssertEqual(StudyPlanAPI.orderSuggestion(settings: s, code: code, startTerm: "WiSe 26/27", university: "hildesheim"), .null)
        XCTAssertEqual(StudyPlanAPI.orderSuggestion(settings: s, code: code, startTerm: nil, university: "hildesheim"), .null)
        s.orderAck = "order:" + code
        XCTAssertEqual(StudyPlanAPI.orderSuggestion(settings: s, code: code, startTerm: "WiSe 24/25", university: "hildesheim"), .null)
        s.orderAck = nil
        s.catalogURL = sug["url"]?.string
        XCTAssertEqual(StudyPlanAPI.orderSuggestion(settings: s, code: code, startTerm: "WiSe 24/25", university: "hildesheim"), .null)
    }
}

/// Suche "Was studierst du?": dieselben Treffer wie Python (fixtures/study-catalog/program-search.json), jede Anfrage
/// aus dem Studienangebot der Uni-Seiten findet mindestens einen Studiengang
final class StudyProgramSearchTests: XCTestCase {
    func testSameHitsAsPython() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { url.deleteLastPathComponent() }
        let fx = try JSONValue.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/study-catalog/program-search.json")))
        let progs = StudySources.bundled.programs(university: "hildesheim")
        XCTAssertEqual(progs.count, fx["programs"]?.int)
        for c in fx["cases"]?.array ?? [] {
            let q = c["query"]?.string ?? ""
            let hits = StudySources.filterPrograms(progs, query: q).map { "\($0["program"]?.string ?? "") | \($0["degree"]?.string ?? "")" }
            XCTAssertEqual(hits.sorted(), (c["hits"]?.array ?? []).compactMap(\.string).sorted(), q)
            XCTAssertFalse(hits.isEmpty, q)
        }
    }
}
