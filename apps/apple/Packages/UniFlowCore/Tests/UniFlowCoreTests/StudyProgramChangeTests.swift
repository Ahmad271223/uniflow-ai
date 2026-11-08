import Foundation
import XCTest
@testable import UniFlowCore

// Studiengangwechsel (07.11.2026): nennt der Notenspiegel mehrere Abschluesse (Uni Hildesheim: je Abschluss eine eigene
// Liste im LSF, `nodeID=auswahlBaum|abschluss:abschl=<n>,stgnr=<n>,...`; HsH: zwei Zeilen in "Meine Studiengaenge"),
// gewinnt der aktuelle Studiengang; der fruehere steht als "Frueheres Studium" daneben. Ohne erkannten Studiengang:
// "Studiengang waehlen" aus dem Register (Kuerzel als settings.study_plan.po). Nachgebaute Seiten, erfundene Daten.

private func repoURL() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return url
}

private func fixture(_ relative: String) throws -> String {
    try String(contentsOf: repoURL().appendingPathComponent("packages/shared-contracts/fixtures/\(relative)"), encoding: .utf8)
}

private var seedDir: URL { repoURL().appendingPathComponent("apps/apple/UniFlow/Resources/StudyCatalogSeed") }

final class StudyProgramChangeTests: XCTestCase {
    typealias StubLoader = StudyCatalogPipelineTests.StubLoader

    static let ewLabel = "Abschluss: [82] Bachelor Studiengang: [052] B.A. Erziehungswissenschaft PO-Version: 2022"
    static let spLabel = "Abschluss: [82] Bachelor Studiengang: [117] B.A. Sozialpädagogik PO-Version: 2025"
    static let spCode = "sozialpaedagogik|b.a.|2025"
    let noWait = UniRetry(attempts: 1, delayNanos: { _ in 0 })

    private func seeds() throws -> StudyCatalogSeeds {
        let index = try JSONValue.parse(Data(contentsOf: seedDir.appendingPathComponent("hildesheim-index.json")))
        return StudyCatalogSeeds([StudyCatalogSeed(index: index) { try? Data(contentsOf: seedDir.appendingPathComponent($0)) }])
    }

    private func env(_ loader: StubLoader = StubLoader()) throws -> StudyCatalogPipeline.Environment {
        StudyCatalogPipeline.Environment(loader: loader, library: nil, seed: try seeds(), pdfText: { _ in [] }, planText: { _ in nil },
                                         now: { Date(timeIntervalSince1970: 1_794_045_600) })
    }

    private func backend() async throws -> LocalBackend {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: .fixed(berlin: "2026-11-07T10:00:00")!)
        try await b.context.database.transaction { c in
            _ = try c.execute("INSERT OR REPLACE INTO settings(key, value) VALUES ('university', 'hildesheim')")
        }
        return b
    }

    private func get(_ b: LocalBackend, _ path: String) async -> JSONValue? {
        await b.handle(LocalRequest(method: "GET", url: URL(string: "uniflow-local://device" + path)!, headers: [:], body: nil)).json
    }

    private func post(_ b: LocalBackend, _ path: String, _ body: JSONValue) async -> JSONValue? {
        await b.handle(LocalRequest(method: "POST", url: URL(string: "uniflow-local://device" + path)!,
                                    headers: ["Content-Type": "application/json"], body: body.serialized())).json
    }

    /// LSF mit zwei Abschluessen: Menue springt in den frueheren, die Auswahl fuehrt zum aktuellen
    private func lsfTransport() throws -> FakeUniTransport {
        let t = FakeUniTransport()
        let list = "\(HildesheimCAS.lsfBase)/qisserver/rds?state=notenspiegelStudent&next=list.vm&nextdir=qispos/notenspiegel/student&createInfos=Y&struct=auswahlBaum&nodeID=auswahlBaum%7Cabschluss%3Aabschl%3D82%2Cstgnr%3D"
        t.on(LSFClient.startURL, ok(try fixture("hildesheim/lsf-notenspiegel-wechsel-start.html")))
        t.on(list + "1", ok(try fixture("hildesheim/lsf-notenspiegel-wechsel-ew.html")))
        t.on(list + "2", ok(try fixture("hildesheim/lsf-notenspiegel-wechsel-sozpaed.html")))
        return t
    }

    // MARK: LSF: alle Abschluesse lesen, jede Leistung mit ihrem Abschluss

    func testLSFReadsEveryAbschlussWithItsLabel() async throws {
        let t = try lsfTransport()
        let grades = try await LSFClient(transport: t, retry: noWait).grades()
        let by = Dictionary(grouping: grades, by: { $0.abschluss ?? "" })
        XCTAssertEqual(Set(by.keys), [Self.ewLabel, Self.spLabel], "Ueberschrift vor der Tabelle und Zeile in der Tabelle")
        XCTAssertEqual(by[Self.ewLabel]?.count, 5)
        XCTAssertEqual(by[Self.spLabel]?.map(\.text), ["Modul 1: Studieneingangsphase", "Modul 2: Sozialpädagogik I – Einführung",
                                                       "Modul 4: Psychologie"])
        XCTAssertFalse(grades.contains { $0.raw.contains("000000") || $0.text.contains("Matrikel") }, "Stammdaten nie")
        // jede Liste genau einmal, nur lesend (keine An-/Abmeldung)
        let urls = t.requests.map(\.url.absoluteString)
        XCTAssertEqual(urls.filter { $0.contains("stgnr%3D1") }.count, 1)
        XCTAssertEqual(urls.filter { $0.contains("stgnr%3D2") }.count, 1)
        XCTAssertFalse(urls.contains { $0.contains("prfAnm") || $0.contains("examsinfos") })
    }

    func testAbschlussHeadingsBeforeTables() {
        let html = """
            <p>Abschluss: [82] Bachelor Studiengang: [1] B.A. Eins PO-Version: 2020</p><table><tr><td>a</td></tr></table>
            <table><tr><td>b</td></tr></table>
            <h3>Abschluss: [88] Master Studiengang: [2] M.A. Zwei PO-Version: 2024</h3><table><tr><td>Abschluss: im Text</td></tr></table>
            """
        XCTAssertEqual(LSFClient.abschlussHeadings(html: html, tables: 3), [
            "Abschluss: [82] Bachelor Studiengang: [1] B.A. Eins PO-Version: 2020",
            "Abschluss: [82] Bachelor Studiengang: [1] B.A. Eins PO-Version: 2020",
            "Abschluss: [88] Master Studiengang: [2] M.A. Zwei PO-Version: 2024",
        ])
        XCTAssertEqual(LSFClient.abschlussHeadings(html: "<table></table>", tables: 1), [""])
    }

    // MARK: Aktueller Studiengang

    private func row(_ abschluss: String, _ text: String, datum: String = "", status: String = "bestanden", semester: String = "") -> [String: JSONValue] {
        ["abschluss": .string(abschluss), "text": .string(text), "datum": .string(datum), "status": .string(status),
         "semester": .string(semester), "note": "2,0", "credits": "6"]
    }

    func testCurrentAbschlussRules() {
        // juengstes Semester gewinnt, auch gegen mehr Leistungen (bis 07.11.2026: der haeufigste = der alte)
        let rows = (1...6).map { row(Self.ewLabel, "Alt \($0)", datum: "10.02.2025") } + [row(Self.spLabel, "Neu", datum: "13.02.2026")]
        XCTAssertEqual(StudyPlanEngine.currentAbschluss(rows), Self.spLabel)
        // die laufende Anmeldung zaehlt (Status "angemeldet (WiSe 26/27)") auch ohne Datum
        let reg = [row(Self.ewLabel, "Alt", datum: "10.07.2026"), row(Self.spLabel, "Neu", status: "angemeldet (WiSe 26/27)")]
        XCTAssertEqual(StudyPlanEngine.currentAbschluss(reg), Self.spLabel)
        // ohne Semester: hoehere PO-Version, dann die meisten Leistungen
        XCTAssertEqual(StudyPlanEngine.currentAbschluss([row(Self.ewLabel, "a"), row(Self.ewLabel, "b"), row(Self.spLabel, "c")]), Self.spLabel)
        let samePO = "Abschluss: [82] Bachelor Studiengang: [9] B.A. Philosophie PO-Version: 2025"
        XCTAssertEqual(StudyPlanEngine.currentAbschluss([row(samePO, "a"), row(Self.spLabel, "b"), row(Self.spLabel, "c")]), Self.spLabel)
        XCTAssertNil(StudyPlanEngine.currentAbschluss([row("", "x")]))
        // Semesterspalte (LUH) und Pruefungsdatum
        XCTAssertEqual(StudyPlanEngine.termOfDate("15.10.2025"), 2025 * 2 + 1)
        XCTAssertEqual(StudyPlanEngine.termOfDate("15.02.2026"), 2025 * 2 + 1)
        XCTAssertEqual(StudyPlanEngine.termOfDate("15.07.2026"), 2026 * 2)
        XCTAssertEqual(StudyPlanEngine.termOfRow(row("x", "y", semester: "SoSe 24")), StudyPlanEngine.parseTerm("SoSe 24"))
    }

    // MARK: Register: alle Hildesheimer Studiengaenge mit "Sozial..." oder "Erziehungswissenschaft"

    func testEverySozialAndErziehungswissenschaftProgramMatches() throws {
        let src = StudySources.bundled
        let uni = try XCTUnwrap(src.university("hildesheim"))
        let programs = (uni["programs"]?.array ?? []).filter {
            let n = StudySources.text($0["program"])
            return n.contains("Sozial") || n.contains("Erziehungswissenschaft")
        }
        XCTAssertGreaterThanOrEqual(programs.count, 5)
        for p in programs {
            let name = StudySources.text(p["program"]), degree = StudySources.text(p["degree"])
            let master = degree.uppercased().hasPrefix("M")
            let po = StudySources.newestPO(p).map { StudySources.text($0["po"]) } ?? "2025"
            let label = "Abschluss: [\(master ? "88] Master" : "82] Bachelor")) Studiengang: [123] \(degree) \(name) PO-Version: \(po)"
            let m = src.match(label: label, university: "hildesheim")
            if (p["pos"]?.array ?? []).isEmpty {
                XCTAssertNil(m, "\(name) \(degree): kein Katalog im Register")
                continue
            }
            let hit = try XCTUnwrap(m, "\(name) \(degree)")
            XCTAssertEqual(hit.programID, p["id"]?.string, label)
            XCTAssertEqual(hit.degree, degree, label)
            XCTAssertFalse(hit.needsConfirmation, "PO \(po) passt: \(label)")
        }
        // die Studentin: B.A. Sozialpaedagogik (PO 2025) und der fruehere B.A. Erziehungswissenschaft (PO 2022, Katalog 2023)
        let sp = try XCTUnwrap(src.match(label: Self.spLabel, university: "hildesheim"))
        XCTAssertEqual([sp.programID, sp.code], ["sozialpaedagogik-b-a", Self.spCode])
        XCTAssertFalse(sp.needsConfirmation)
        let ew = try XCTUnwrap(src.match(label: Self.ewLabel, university: "hildesheim"))
        XCTAssertEqual(ew.code, "erziehungswissenschaft|b.a.|2023")
        XCTAssertTrue(ew.needsConfirmation, "PO 2022 hat keinen eigenen Katalog")
        // Bachelor und Master gleichen Namens bleiben getrennt
        let soMA = try XCTUnwrap(src.match(label: "Abschluss: [88] Master Studiengang: [118] M.A. Sozial- und Organisationspädagogik PO-Version: 2025",
                                           university: "hildesheim"))
        XCTAssertEqual(soMA.programID, "sozial-und-organisationspaedagogik-m-a")
        let soBA = try XCTUnwrap(src.match(label: "Abschluss: [82] Bachelor Studiengang: [118] B.A. Sozial- und Organisationspädagogik PO-Version: 2022",
                                           university: "hildesheim"))
        XCTAssertEqual(soBA.programID, "sozialpaedagogik-b-a", "frueherer Name des Bachelors (geraten, mit Rueckfrage)")
        XCTAssertTrue(soBA.needsConfirmation)
        // Schreibweisen: Leerraum, ohne Kuerzel in Klammern, Umlaut ausgeschrieben
        for variant in ["Abschluss: Bachelor Studiengang: B.A.  Sozialpädagogik PO-Version: 2025",
                        "Abschluss: [82] Bachelor Studiengang: B.A. Sozialpaedagogik PO-Version: 2025",
                        "Abschluss: [82] Bachelor Studiengang: [117] BA Sozialpädagogik PO-Version: 2025"] {
            XCTAssertEqual(src.match(label: variant, university: "hildesheim")?.code, Self.spCode, variant)
        }
        XCTAssertNil(src.match(label: Self.spLabel, university: "luh"), "nur Hildesheim")
    }

    // MARK: Ganzer Ablauf: LSF -> Katalog -> Studienverlauf

    func testProgramChangePlansTheCurrentProgramAndKeepsTheOldOne() async throws {
        let b = try await backend()
        let grades = try await LSFClient(transport: try lsfTransport(), retry: noWait).grades()
        try await b.context.database.transaction { try UniStore.storeGrades($0, grades, now: "2026-11-07T10:00:00Z") }
        let label = try await b.context.database.withConnection { try StudyCatalogPipeline.qisLabel($0) }
        XCTAssertEqual(label, Self.spLabel, "nicht der haeufigste (alte) Abschluss")

        let s = await StudyCatalogPipeline.run(db: b.context.database, env: try env())
        XCTAssertEqual(s["state"]?.string, "seed", "\(s)")
        XCTAssertEqual(s["code"]?.string, Self.spCode)

        let planRaw = await get(b, "/api/study-plan")
        let plan = try XCTUnwrap(planRaw)
        XCTAssertEqual(plan["available"]?.bool, true, "\(plan)")
        XCTAssertEqual(plan["program"]?.string, "Sozialpädagogik")
        XCTAssertEqual(plan["qis_program"]?.string, Self.spLabel)
        let modules = (plan["semesters"]?.array ?? []).flatMap { $0["modules"]?.array ?? [] }
        func status(_ title: String) -> String? { modules.first { ($0["title"]?.string ?? "").hasPrefix(title) }?["status"]?.string }
        XCTAssertEqual(status("Modul 2: Sozialpädagogik I"), "bestanden")
        XCTAssertEqual(status("Modul 5: Soziologie"), "bestanden", "aus dem frueheren Studium, passt zu einem Modul")
        XCTAssertNotEqual(status("Modul 3: Erziehungswissenschaft"), "bestanden")
        let unmatched = (plan["unmatched"]?.array ?? []).compactMap(\.string).joined(separator: "|")
        XCTAssertFalse(unmatched.contains("Kindheit, Jugend"), "alte Leistungen stoeren den neuen Verlauf nicht")

        let previous = try XCTUnwrap(plan["previous_studies"]?.array)
        XCTAssertEqual(previous.count, 1)
        XCTAssertEqual(previous[0]["abschluss"]?.string, Self.ewLabel)
        XCTAssertEqual(previous[0]["program"]?.string, "Erziehungswissenschaft")
        XCTAssertEqual(previous[0]["po"]?.string, "2022")
        XCTAssertEqual(previous[0]["count"]?.int, 5)
        XCTAssertEqual(previous[0]["passed"]?.int, 4)
        XCTAssertEqual(previous[0]["counted"]?.int, 1)

        // eine frueher bestaetigte PO des alten Studiengangs ("2023", dessen Katalog noch auf dem Geraet liegt) macht
        // den neuen Verlauf nicht leer und zeigt nicht den alten Katalog
        _ = await post(b, "/api/study-plan/settings", ["po": "erziehungswissenschaft|b.a.|2023"])
        let old = await StudyCatalogPipeline.run(db: b.context.database, env: try env())
        XCTAssertEqual(old["code"]?.string, "erziehungswissenschaft|b.a.|2023")
        _ = await post(b, "/api/study-plan/settings", ["po": "2023"])
        let staleRaw = await get(b, "/api/study-plan")
        let stale = try XCTUnwrap(staleRaw)
        XCTAssertEqual(stale["available"]?.bool, true, "\(stale)")
        XCTAssertEqual(stale["program"]?.string, "Sozialpädagogik")
    }

    func testStalePOYearOnlyAppliesWithinTheCurrentProgram() {
        let ew: JSONValue = ["program": "Erziehungswissenschaft", "po": "2023", "code": "erziehungswissenschaft|b.a.|2023", "modules": []]
        let sp: JSONValue = ["program": "Sozialpädagogik", "po": "2025", "code": .string(Self.spCode), "modules": []]
        let grades = [row(Self.spLabel, "Neu", datum: "13.02.2026"), row(Self.ewLabel, "Alt", datum: "10.02.2024")]
        XCTAssertEqual(StudyPlanEngine.pickCatalog([ew, sp], settings: ["po": "2023"], grades: grades).catalog?["program"], "Sozialpädagogik")
        XCTAssertEqual(StudyPlanEngine.pickCatalog([ew, sp], settings: ["po": "2025"], grades: grades).catalog?["program"], "Sozialpädagogik")
        // ein Kuerzel gilt immer (selbst gewaehlt), auch gegen den Notenspiegel
        XCTAssertEqual(StudyPlanEngine.pickCatalog([ew, sp], settings: ["po": "erziehungswissenschaft|b.a.|2023"], grades: grades).catalog?["program"],
                       "Erziehungswissenschaft")
        // ohne Katalog des aktuellen Studiengangs bleibt es bei "keine Ordnung"
        XCTAssertEqual(StudyPlanEngine.pickCatalog([ew], settings: ["po": "2019"], grades: grades).reason, "no_catalog_po")
        XCTAssertEqual(StudyPlanEngine.pickCatalog([ew], settings: ["po": "2023"], grades: grades).catalog?["program"], "Erziehungswissenschaft")
    }

    // MARK: Studiengang waehlen (kein Studiengang erkannt)

    func testChooseProgramWhenNothingIsRecognised() async throws {
        let b = try await backend()
        // Notenspiegel mit einem Namen, den das Register nicht kennt
        try await b.context.database.transaction { c in
            _ = try c.execute("INSERT INTO grades(pruefungsnr, text, datum, status, abschluss) VALUES ('1', 'Modul 2: Sozialpädagogik I – Einführung', '16.02.2026', 'bestanden', ?)",
                              [.text("Abschluss: [82] Bachelor Studiengang: [999] B.A. Erfundenes Fach PO-Version: 2025")])
        }
        let first = await StudyCatalogPipeline.run(db: b.context.database, env: try env())
        XCTAssertEqual(first["state"]?.string, "not_found")
        XCTAssertEqual(first["reason"]?.string, "no_source")

        // Liste "Studiengang waehlen": Register der Hochschule des Containers, Suche, ladbare Kataloge
        let listRaw = await get(b, "/api/study-catalog/programs")
        let list = try XCTUnwrap(listRaw)
        XCTAssertEqual(list["university"]?.string, "hildesheim")
        XCTAssertEqual(list["chosen"], .null)
        let all = list["programs"]?.array ?? []
        XCTAssertGreaterThan(all.count, 100)
        let sp = try XCTUnwrap(all.first { $0["id"]?.string == "sozialpaedagogik-b-a" })
        XCTAssertEqual(sp["pos"]?.array?.first?["code"]?.string, Self.spCode)
        XCTAssertEqual(sp["pos"]?.array?.first?["loadable"]?.bool, true)
        let foundRaw = await get(b, "/api/study-catalog/programs?q=sozialp")
        let found = try XCTUnwrap(foundRaw)
        XCTAssertTrue((found["programs"]?.array ?? []).contains { $0["id"]?.string == "sozialpaedagogik-b-a" })
        XCTAssertFalse((found["programs"]?.array ?? []).contains { $0["id"]?.string == "angewandte-informatik-b-sc" })
        let noCatalog = try XCTUnwrap(all.first { $0["id"]?.string == "medieninformatik-b-sc" })
        XCTAssertEqual(noCatalog["pos"]?.array?.count, 0, "ohne Katalog in der Liste, nicht waehlbar")

        // Wahl merken (Kuerzel als PO), Katalog aus dem Grundstock, Verlauf mit den Leistungen
        _ = await post(b, "/api/study-plan/settings", ["po": .string(Self.spCode)])
        let chosen = await StudyCatalogPipeline.run(db: b.context.database, env: try env())
        XCTAssertEqual(chosen["state"]?.string, "seed", "\(chosen)")
        XCTAssertEqual(chosen["code"]?.string, Self.spCode)
        XCTAssertEqual(chosen["needs_confirmation"]?.bool, false)
        let againRaw = await get(b, "/api/study-catalog/programs")
        let again = try XCTUnwrap(againRaw)
        XCTAssertEqual(again["chosen"]?.string, Self.spCode)
        let planRaw = await get(b, "/api/study-plan")
        let plan = try XCTUnwrap(planRaw)
        XCTAssertEqual(plan["available"]?.bool, true, "\(plan)")
        XCTAssertEqual(plan["program"]?.string, "Sozialpädagogik")
        XCTAssertEqual(plan["po_confirmed"]?.bool, true)

        // auch ganz ohne Notenspiegel
        let empty = try await backend()
        _ = await post(empty, "/api/study-plan/settings", ["po": .string(Self.spCode)])
        let s = await StudyCatalogPipeline.run(db: empty.context.database, env: try env())
        XCTAssertEqual(s["state"]?.string, "seed", "\(s)")
        let p2Raw = await get(empty, "/api/study-plan")
        let p2 = try XCTUnwrap(p2Raw)
        XCTAssertEqual(p2["available"]?.bool, true)
        XCTAssertNil(p2["previous_studies"], "ohne frueheres Studium kein Schluessel (wie am PC)")
    }

    // MARK: HsH: zwei Studiengaenge im Studienservice

    func testHsHCurrentProgramRules() {
        typealias P = HISinOneStudyService.Program
        let old = P(group: "Bachelor - Erststudium (beendet)", subject: "Mediendesign", semester: 5, code: "Hauptfach", po: "2017")
        let new = P(group: "Bachelor - Erststudium", subject: "Angewandte Informatik", semester: 3, code: "Hauptfach", po: "2019")
        XCTAssertEqual(HISinOneStudyService.current([old, new])?.subject, "Angewandte Informatik", "nicht abgeschlossen vor Fachsemester")
        let minor = P(group: "Bachelor - Erststudium", subject: "Wirtschaft", semester: 7, code: "Nebenfach", po: "2022")
        XCTAssertEqual(HISinOneStudyService.current([minor, new])?.subject, "Angewandte Informatik", "Hauptfach vor Nebenfach")
        let higher = P(group: "Bachelor - Erststudium", subject: "Soziale Arbeit", semester: 4, code: "Hauptfach", po: "2018")
        XCTAssertEqual(HISinOneStudyService.current([new, higher])?.subject, "Soziale Arbeit", "dann das hoechste Fachsemester")
        let samePO = P(group: "Bachelor - Erststudium", subject: "Elektrotechnik", semester: 3, code: "Hauptfach", po: "2024")
        XCTAssertEqual(HISinOneStudyService.current([new, samePO])?.subject, "Elektrotechnik", "dann die neuere PO")
        XCTAssertNil(HISinOneStudyService.current([]))
    }

    func testHsHStudyServiceWithTwoProgramsLabelsOnlyTheCurrent() async throws {
        let html = try fixture("hsh/hisinone-studienservice-wechsel.html")
        let programs = HISinOneStudyService.programs(html: html)
        XCTAssertEqual(programs.map(\.subject), ["Mediendesign", "Angewandte Informatik"])
        let s = HISinOneStudyService(reregistration: HISinOneStudyService.reregistration(html: html), programs: programs, openPayments: 0, documents: 0)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hshwechsel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let db = try SQLiteDatabase(path: dir.appendingPathComponent("db.sqlite").path)
        try await db.migrate(clock: .fixed(Date(timeIntervalSince1970: 1_793_000_000)), university: "hsh")
        let old = "Bachelor Mediendesign (PO-Version 2017)"
        try await db.transaction { c in
            try UniStore.storeGrades(c, [
                QISGrade(pruefungsnr: "1", text: "Programmieren 1", semester: "WiSe 25/26", note: "1,7", status: "bestanden", abschluss: ""),
                QISGrade(pruefungsnr: "2", text: "Mathematik 1", semester: "WiSe 25/26", note: "2,3", status: "bestanden", abschluss: "Angewandte Informatik"),
                QISGrade(pruefungsnr: "3", text: "Typografie", semester: "SoSe 24", note: "1,3", status: "bestanden", abschluss: old),
            ], now: "t")
            try HISinOneStudyService.store(c, s, now: "t")
        }
        let rows = try await db.query("SELECT pruefungsnr, abschluss FROM grades ORDER BY pruefungsnr")
        let current = "Bachelor Angewandte Informatik (PO-Version 2019)"
        XCTAssertEqual(rows.map { $0["abschluss"]?.string }, [current, current, old], "der fruehere behaelt seine Bezeichnung")
        let stored = try await db.withConnection { try HISinOneStudyService.stored($0) }
        XCTAssertEqual(stored?["current"]?.string, current)
        let grades = rows.map { ["abschluss": $0["abschluss"]?.string.map(JSONValue.string) ?? .null] as [String: JSONValue] }
        XCTAssertEqual(StudyPlanEngine.currentAbschluss(grades), current)
    }
}
