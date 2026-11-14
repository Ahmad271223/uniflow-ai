import Foundation
import XCTest
@testable import UniFlowCore

// Leser fuer "Studienordnung inklusive Modulhandbuch" (Uni Hildesheim) gegen die Python-Referenz
// app/study_catalog_hildesheim.py: erfundene Seitentexte im Aufbau der Studienordnungen
// (tools/gen-study-catalog-hildesheim-fixture.py), Katalog, Texte, Teilmodule und Kopf byte-gleich; Python prueft
// dieselben Dateien (tests/test_study_catalog_hildesheim.py).

private func fixture(_ name: String) throws -> JSONValue {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return try JSONValue.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/study-catalog-hildesheim/" + name)))
}

private func meta(_ v: JSONValue) -> StudyCatalogMeta {
    StudyCatalogMeta(university: v["university"]?.string ?? "", program: v["program"]?.string ?? "", degree: v["degree"]?.string ?? "",
                     po: v["po"]?.string ?? "", code: v["code"]?.string ?? "", catalogTerm: v["catalog_term"]?.string ?? "",
                     regularSemesters: v["regular_semesters"]?.int, totalLP: v["total_lp"]?.double,
                     sourceURL: v["source"]?["url"]?.string, fetchedAt: v["source"]?["fetched_at"]?.string, sha256: v["source"]?["sha256"]?.string)
}

private func strings(_ v: JSONValue?) -> [String] { (v?.array ?? []).compactMap(\.string) }

final class StudyCatalogHildesheimParserTests: XCTestCase {
    typealias Parser = StudyCatalogHildesheimParser

    /// Erkennung, Kopf, Katalog, Texte und Teilmodule eines Falls gegen die erwarteten kanonischen Texte
    private func check(_ name: String, pages: [String]? = nil, file: StaticString = #filePath, line: UInt = #line) throws -> JSONValue {
        let c = try fixture(name)
        let pages = pages ?? strings(c["pages"])
        XCTAssertEqual(Parser.detect(pages: pages), c["detect"]?.bool, name, file: file, line: line)
        XCTAssertEqual(Parser.head(pages: pages).json.dumps(ensureASCII: false), c["head_dumps"]?.string, name, file: file, line: line)
        let parsed = Parser.parse(pages: pages, meta: meta(c["meta"]!))
        XCTAssertEqual(parsed.catalogDumps, c["dumps"]?.string, name, file: file, line: line)
        XCTAssertEqual(parsed.textsDumps, c["texts_dumps"]?.string, name, file: file, line: line)
        XCTAssertEqual(Parser.details(pages: pages).dumps(ensureASCII: false), c["details_dumps"]?.string, name, file: file, line: line)
        XCTAssertEqual(StudyCatalogValidator.validate(parsed.catalog.json), [], name, file: file, line: line)
        return c
    }

    func testVerkuendungsblattIsByteEqualToPython() throws {
        let c = try check("verkuendungsblatt.json")
        let mods = c["catalog"]?["modules"]?.array ?? []
        XCTAssertEqual(mods.compactMap { $0["title"]?.string },
                       ["Einstieg in den Garten", "Gartenpädagogik II – Handeln in Gemeinschaftsgärten", "Teichrecht I", "Abschlussmodul"])
        XCTAssertEqual(mods.compactMap { $0["lp"]?.double }, [6, 15, 9, 15])
        XCTAssertEqual(mods.last?["kind"]?.string, "abschluss")
    }

    func testLesefassungFromPositionedItemsIsByteEqualToPython() throws {
        let c = try fixture("lesefassung.json")
        let items = (c["items"]?.array ?? []).map { page in
            (page.array ?? []).map { StudyPlanTextItem(x: $0.array?[0].double ?? 0, y: $0.array?[1].double ?? 0, text: $0.array?[2].string ?? "") }
        }
        let pages = Parser.rowPages(items)
        XCTAssertEqual(pages, strings(c["pages"]), "Zeilen aus Textstuecken mit Lage")
        _ = try check("lesefassung.json", pages: pages)
        let head = Parser.head(pages: pages)
        XCTAssertEqual(head.program, "Wald- und Wiesenpädagogik")
        XCTAssertEqual(head.degree, "M.A.")
        XCTAssertEqual(head.stand, "2032-03-02")
        XCTAssertEqual(head.catalogTerm, "SS 2031")
    }

    func testRawPDFKitTextKeepsOnlyWhatIsCertain() throws {
        let c = try check("pdfkit-roh.json")
        for m in c["catalog"]?["modules"]?.array ?? [] {
            XCTAssertEqual(m["semester"], .null)
            XCTAssertEqual(m["turnus"]?.string, "unbekannt")
            XCTAssertEqual(m["exam"], .null)
        }
    }

    func testValuesMatchPython() throws {
        let w = try fixture("werte.json")
        for c in w["semester"]?.array ?? [] {
            XCTAssertEqual(Parser.semester(c["text"]?.string ?? ""), c["semester"]?.int, c["text"]?.string ?? "")
        }
        for c in w["season"]?.array ?? [] {
            XCTAssertEqual(Parser.season(c["text"]?.string ?? ""), c["turnus"]?.string, c["text"]?.string ?? "")
        }
        for c in w["lp"]?.array ?? [] {
            XCTAssertEqual(Parser.lp(strings(c["lines"])), c["lp"]?.double, "\(strings(c["lines"]))")
        }
        for c in w["parts"]?.array ?? [] {
            XCTAssertEqual(PyJSON.array(Parser.parts(strings(c["lines"])).map(\.json)).dumps(ensureASCII: false), c["dumps"]?.string,
                           "\(strings(c["lines"]))")
        }
        for c in w["clip"]?.array ?? [] {
            XCTAssertEqual(Parser.clip(c["text"]?.string ?? "", c["limit"]?.int ?? 500), c["clip"]?.string, c["text"]?.string ?? "")
        }
        for c in w["detect"]?.array ?? [] {
            let pages = strings(c["pages"])
            XCTAssertEqual(Parser.detect(pages: pages), c["detect"]?.bool, c["name"]?.string ?? "")
            XCTAssertEqual(Parser.head(pages: pages).json.dumps(ensureASCII: false), c["head_dumps"]?.string, c["name"]?.string ?? "")
        }
    }

    /// Der modkat-Leser findet in diesem Format nichts (deshalb der eigene Leser), und umgekehrt
    func testLuhParserFindsNoModulesHere() throws {
        let c = try fixture("verkuendungsblatt.json")
        XCTAssertEqual(StudyCatalogParser.parse(pages: strings(c["pages"]), meta: meta(c["meta"]!)).moduleCount, 0)
        XCTAssertFalse(Parser.detect(pages: ["Modulkatalog\nfür den Studiengang\nTechnische Informatik - Bachelor", "Programmieren ........ 3"]))
    }
}
