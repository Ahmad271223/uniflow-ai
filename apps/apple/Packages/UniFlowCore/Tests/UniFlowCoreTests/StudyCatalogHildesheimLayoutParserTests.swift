import Foundation
import XCTest
@testable import UniFlowCore

// Tabellen-Leser der Universitaet Hildesheim (Informatik im Lehramt 2026, Barrierefreie Kommunikation) gegen die
// Python-Referenz app/study_catalog_hildesheim_layout.py: erfundene Seitentexte im Aufbau der Ordnungen
// (tools/gen-study-catalog-hildesheim-layout-fixture.py), Katalog und Texte byte-gleich; Python prueft dieselben Dateien
// (tests/test_study_catalog_hildesheim_layout.py).

private func fixture(_ name: String) throws -> JSONValue {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return try JSONValue.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/study-catalog-hildesheim-layout/" + name)))
}

private func meta(_ v: JSONValue) -> StudyCatalogMeta {
    StudyCatalogMeta(university: v["university"]?.string ?? "", program: v["program"]?.string ?? "", degree: v["degree"]?.string ?? "",
                     po: v["po"]?.string ?? "", code: v["code"]?.string ?? "", catalogTerm: v["catalog_term"]?.string ?? "",
                     regularSemesters: v["regular_semesters"]?.int, totalLP: v["total_lp"]?.double,
                     sourceURL: v["source"]?["url"]?.string, fetchedAt: v["source"]?["fetched_at"]?.string, sha256: v["source"]?["sha256"]?.string)
}

private func strings(_ v: JSONValue?) -> [String] { (v?.array ?? []).compactMap(\.string) }

final class StudyCatalogHildesheimLayoutParserTests: XCTestCase {
    typealias Parser = StudyCatalogHildesheimLayoutParser

    private func parse(_ format: String?, _ pages: [String], _ meta: StudyCatalogMeta) -> ParsedStudyCatalog {
        format == Parser.kuerzelFormat ? Parser.parseKuerzel(pages: pages, meta: meta) : Parser.parseKennnummer(pages: pages, meta: meta)
    }

    /// Erkennung, Katalog und Texte eines Falls gegen die erwarteten kanonischen Texte
    private func check(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String: JSONValue] {
        let c = try fixture(name)
        let pages = strings(c["pages"])
        XCTAssertEqual(Parser.detectKuerzel(pages: pages), c["detect"]?["kuerzel"]?.bool, name, file: file, line: line)
        XCTAssertEqual(Parser.detectKennnummer(pages: pages), c["detect"]?["kennnummer"]?.bool, name, file: file, line: line)
        let parsed = parse(c["format"]?.string, pages, meta(c["meta"]!))
        XCTAssertEqual(parsed.catalogDumps, c["dumps"]?.string, name, file: file, line: line)
        XCTAssertEqual(parsed.textsDumps, c["texts_dumps"]?.string, name, file: file, line: line)
        XCTAssertEqual(StudyCatalogValidator.validate(parsed.catalog.json), [], name, file: file, line: line)
        // der andere Leser findet in diesem Format nichts
        let other = c["format"]?.string == Parser.kuerzelFormat ? Parser.kennnummerFormat : Parser.kuerzelFormat
        XCTAssertEqual(parse(other, pages, meta(c["meta"]!)).moduleCount, 0, name, file: file, line: line)
        var byCode: [String: JSONValue] = [:]
        for m in parsed.catalog.json["modules"]?.array ?? [] { byCode[m["code"]?.string ?? ""] = m }
        return byCode
    }

    func testKuerzelFachIsByteEqualToPythonAndRequiredOnlyIfInEveryVariant() throws {
        let m = try check("kuerzel-fach.json")
        XCTAssertEqual(m.keys.sorted(), ["GAR-A1", "GAR-A2", "GAR-B1", "GAR-B2", "GAR-V1"], "GAR-B9 steht nur im Modellstudienplan")
        XCTAssertEqual(["GAR-B1", "GAR-B2", "GAR-A1", "GAR-A2", "GAR-V1"].map { m[$0]?["kind"]?.string },
                       ["pflicht", "pflicht", "wahlpflicht", "pflicht", "wahlpflicht"])
        XCTAssertEqual(["GAR-B1", "GAR-B2", "GAR-A1", "GAR-A2", "GAR-V1"].map { m[$0]?["lp"]?.double }, [6, 6, 9, 3, 4.5])
        XCTAssertEqual(m["GAR-A1"]?["area"]?.string, "wahlpflichtmodule")
        XCTAssertEqual(m["GAR-A1"]?["exam"]?.string, "TM1: Mündliche Prüfung; TM2: Hausarbeit")
        XCTAssertEqual(m["GAR-A1"]?["coursework"]?.string, "TM1: Gießprotokolle; TM2: Referat mit Handout")
        XCTAssertEqual(m["GAR-B2"]?["exam"]?.string, "Projekt mit Bericht und mündliche Prüfung")
    }

    func testKuerzelMasterIsByteEqualToPython() throws {
        let m = try check("kuerzel-master.json")
        XCTAssertEqual(["GAR-M1", "LPS_Gar1", "LPS_Gar3"].map { m[$0]?["lp"]?.double }, [7, 13, 24])
        XCTAssertEqual(["GAR-M1", "LPS_Gar1", "LPS_Gar3"].map { m[$0]?["kind"]?.string }, ["pflicht", "pflicht", "wahlpflicht"])
        XCTAssertEqual(m["LPS_Gar3"]?["title"]?.string, "Mastermodul")
        XCTAssertEqual(m["LPS_Gar1"]?["coursework"], .null, "reiner Verweis auf die RStO")
    }

    func testKennnummerIsByteEqualToPython() throws {
        let m = try check("kennnummer.json")
        let codes = ["TG 1", "TG 2", "TG 5", "TG 7", "TG 10", "TG 11"]
        XCTAssertEqual(m.count, codes.count)
        XCTAssertEqual(codes.map { m[$0]?["lp"]?.double }, [13, 11, 10, 13, 10, 20])
        XCTAssertEqual(codes.map { m[$0]?["turnus"]?.string }, ["WS+SS", "WS", "SS", "WS", "unbekannt", "unbekannt"])
        XCTAssertEqual(m["TG 5"]?["title"]?.string, "Vertiefungsbereich Wasserbau I: Theorie", "Titel ueber zwei Zeilen")
        XCTAssertEqual(m["TG 7"]?["kind"]?.string, "wahlpflicht")
        XCTAssertEqual(m["TG 11"]?["kind"]?.string, "abschluss")
        XCTAssertEqual(m["TG 1"]?["exam"]?.string, "Klausur")
        XCTAssertEqual(m["TG 10"]?["exam"], .null)
    }

    func testValuesMatchPython() throws {
        let w = try fixture("werte.json")
        for c in w["lines"]?.array ?? [] {
            let lines = Parser.layoutLines([c["text"]?.string ?? ""])[0]
            XCTAssertEqual(PyJSON.array(lines.map { .array($0.map(\.json)) }).dumps(ensureASCII: false), c["dumps"]?.string, c["text"]?.string ?? "")
        }
        for c in w["join"]?.array ?? [] {
            XCTAssertEqual(Parser.join(strings(c["parts"])), c["text"]?.string, "\(strings(c["parts"]))")
        }
        for c in w["season"]?.array ?? [] {
            XCTAssertEqual(Parser.season(c["text"]?.string ?? ""), c["turnus"]?.string, c["text"]?.string ?? "")
        }
        for c in w["facts"]?.array ?? [] {
            let items = (c["items"]?.array ?? []).map { strings($0) }
            XCTAssertEqual(Parser.facts(items, references: c["references"]?.bool ?? true), c["text"]?.string, "\(items)")
        }
        for c in w["detect"]?.array ?? [] {
            let pages = strings(c["pages"])
            XCTAssertEqual(Parser.detectKuerzel(pages: pages), c["detect"]?["kuerzel"]?.bool, c["name"]?.string ?? "")
            XCTAssertEqual(Parser.detectKennnummer(pages: pages), c["detect"]?["kennnummer"]?.bool, c["name"]?.string ?? "")
        }
    }
}
