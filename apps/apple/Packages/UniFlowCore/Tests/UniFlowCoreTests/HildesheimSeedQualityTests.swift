import Foundation
import XCTest
@testable import UniFlowCore

/// Grundstock der Universitaet Hildesheim aus den Dateien der App (Resources/StudyCatalogSeed), wie ihn das Geraet
/// benutzt (14.11.2026): jeder Katalog laedt, besteht die Pruefung, gehoert zu einem Registereintrag und zeigt im
/// Studienverlauf Module (Semesterplan oder Wahl) und LP. Gleiche Liste der Auffaelligkeiten wie
/// tests/test_hildesheim_seed_quality.py. Dazu jeder Registereintrag: per Name zu finden und waehlbar.
final class HildesheimSeedQualityTests: XCTestCase {

    /// Module ohne LP je Kuerzel (Lesefehler des Grundstocks vom 05.11.2026), gleich der Python-Liste
    static let knownNoLP: [String: Int] = [
        "inklusive-paedagogik-und-kommunikation|m.a.|unbekannt": 1,
        "politikwissenschaft-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2026": 2,
        "sportwissenschaft-mit-dem-schwerpunkt-sport-gesundheit-und-leistung-in-der-lebensspanne|m.sc.|2021": 1,
        "kunst-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2022": 1,
        "literarisches-schreiben-und-lektorieren|m.a.|2024": 2,
        "deutsch-als-zweitsprache-deutsch-als-fremdsprache|m.a.|2018": 1,
        "internationale-kommunikation-und-uebersetzen|b.a.|2024": 2,
        "internationales-informationsmanagement|b.a.|2024": 10,
        "internationales-informationsmanagement-digitale-sozialwissenschaften|b.a.|2024": 10,
        "internationales-informationsmanagement-interkulturelle-sprachwissenschaft|b.a.|2024": 10,
        "internationales-informationsmanagement-informationswissenschaft|m.a.|2024": 2,
        "internationales-informationsmanagement-informationswissenschaft-und-interkulturelle-kommunikation|b.a.|2024": 10,
        "internationales-informationsmanagement-linguistik|b.a.|2024": 10,
        "internationales-informationsmanagement-sprachwissenschaft-und-interkulturelle-kommunikation|m.a.|2024": 1,
        "medientext-und-medienuebersetzung|m.a.|2024": 8,
        "mathematik-im-polyvalenten-zwei-faecher-bachelor|b.a.-b.sc.|2025": 1,
        "physik-im-master-lehramt-an-haupt-und-realschulen|m.ed.|2017": 1,
        "physik-im-master-lehramt-an-haupt-und-realschulen|m.ed.|2026": 1,
        "wirtschaft-plus|b.sc.|2026": 6,
    ]
    static let knownOnlyChoice: Set<String> = ["umwelt-naturschutz-und-nachhaltigkeit|m.sc.|2021", "wirtschaftsinformatik|m.sc.|2024"]

    private func seed() throws -> StudyCatalogSeed {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }        // .../apps/apple
        let dir = url.appendingPathComponent("UniFlow/Resources/StudyCatalogSeed")
        let index = try JSONValue.parse(Data(contentsOf: dir.appendingPathComponent("hildesheim-index.json")))
        return StudyCatalogSeed(index: index) { name in try? Data(contentsOf: dir.appendingPathComponent(name)) }
    }

    func testEverySeedCatalogLoadsMapsAndShowsModulesWithLP() throws {
        let s = try seed()
        XCTAssertGreaterThanOrEqual(s.entries.count, 108)
        var problems: [String] = [], noLP: [String: Int] = [:], onlyChoice = Set<String>()
        for e in s.entries {
            guard let text = s.payload(key: e.libraryKey), let cat = try? JSONValue.parse(Data(text.utf8)) else {
                problems.append("\(e.code): laedt nicht"); continue
            }
            let errs = StudyCatalogValidator.validate(cat)
            if !errs.isEmpty { problems.append("\(e.code): \(errs.prefix(2))") }
            if StudySources.bundled.entry(university: "hildesheim", code: e.code) == nil { problems.append("\(e.code): nicht im Register") }
            let plan = StudyPlanEngine.compute(catalog: cat, grades: [], settings: [:], today: "2026-11-14").plan
            if (plan["lp_total"]?.double ?? 0) <= 0 { problems.append("\(e.code): 0 LP") }
            let placed = (plan["semesters"]?.array ?? []).reduce(0) { $0 + ($1["modules"]?.array?.count ?? 0) }
            let choice = plan["electives"]?.array?.count ?? 0
            if placed + choice == 0 { problems.append("\(e.code): keine Module sichtbar") }
            if placed == 0 && choice > 0 { onlyChoice.insert(e.code) }
            let n = (cat["modules"]?.array ?? []).filter { StudyPlanEngine.lpOf($0.object ?? [:]) == 0 }.count
            if n > 0 { noLP[e.code] = n }
        }
        XCTAssertEqual(problems, [], problems.joined(separator: "\n"))
        XCTAssertEqual(noLP, Self.knownNoLP, "Module ohne LP geaendert")
        XCTAssertEqual(onlyChoice, Self.knownOnlyChoice)
    }

    func testEveryRegisterEntryIsFindableAndSelectable() {
        let progs = StudySources.bundled.programs(university: "hildesheim")
        XCTAssertGreaterThanOrEqual(progs.count, 112)
        let without = progs.filter { $0["pos"]?.array?.isEmpty ?? true }
        XCTAssertEqual(without.filter { $0["kind"]?.string == "nebenfach" }.count, 64, "Neben-/Begleitfaecher aus der LSF-Uebersicht")
        XCTAssertEqual(without.filter { $0["kind"]?.string != "nebenfach" }.count, 11)
        for p in progs {
            let name = p["program"]?.string ?? ""
            XCTAssertTrue(StudySources.programMatches(p, query: name), name)
            let key = p["pos"]?.array?.first?["code"]?.string ?? p["id"]?.string
            XCTAssertNotNil(StudyPlanAPI.chosenProgramName(key, university: "hildesheim"), name)
        }
    }

    /// Studiengang ohne Katalog gewaehlt: ehrlicher Hinweis mit Namen statt leerer Seite (auch ohne jeden Katalog)
    func testChosenProgramWithoutCatalogSaysSo() async throws {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: .fixed(berlin: "2026-11-14T10:00:00")!, university: "hildesheim")
        let p = try XCTUnwrap(StudySources.bundled.programs(university: "hildesheim").first { $0["program"]?.string == "Rechtspsychologie" })
        let id = try XCTUnwrap(p["id"]?.string)
        _ = await b.handle(LocalRequest(method: "POST", url: URL(string: "uniflow-local://device/api/study-plan/settings")!,
                                        body: JSONValue.object(["po": .string(id)]).serialized()))
        let r = await b.handle(LocalRequest(method: "GET", url: URL(string: "uniflow-local://device/api/study-plan")!))
        XCTAssertEqual(r.json?["available"]?.bool, false)
        XCTAssertEqual(r.json?["message"]?.string, "Für Rechtspsychologie (M.Sc.) gibt es noch keinen Modulkatalog.")
        XCTAssertEqual(r.json?["program"]?.string, "Rechtspsychologie (M.Sc.)")
    }

    /// LSF-Uebersicht: Link je Studiengang, Schreibweisen fuer die Suche, Begleitfach des Testkontos waehlbar (wie Python)
    func testLSFOverviewLinkNamesAndMinors() throws {
        let progs = StudySources.bundled.programs(university: "hildesheim")
        let ew = try XCTUnwrap(progs.first { $0["program"]?.string == "Erziehungswissenschaft" && $0["degree"]?.string == "B.A." })
        XCTAssertTrue((ew["lsf_names"]?.array ?? []).contains("B.A. Erziehungswissenschaft"))
        let plan = StudyPlanAPI.lsfPlan("erziehungswissenschaft|b.a.|2023", university: "hildesheim")
        XCTAssertEqual(plan["url"]?.string?.hasSuffix("idval=174&purge=n&getglobal=n"), true)
        XCTAssertEqual(plan["label"]?.string, "Veranstaltungen dieses Semesters im LSF")
        let bwl = progs.filter { $0["kind"]?.string == "nebenfach" && StudySources.programMatches($0, query: "Betriebswirtschaftslehre Begleitfach") }
        XCTAssertFalse(bwl.isEmpty)
        XCTAssertEqual(StudyPlanAPI.lsfPlan(bwl.first?["id"]?.string, university: "hildesheim")["url"]?.string?.hasPrefix("https://lsf.uni-hildesheim.de/"), true)
        XCTAssertEqual(StudyPlanAPI.lsfPlan("gibt-es-nicht", university: "hildesheim"), .null)
    }
}
