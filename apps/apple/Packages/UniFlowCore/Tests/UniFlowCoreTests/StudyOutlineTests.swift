import Foundation
import XCTest
@testable import UniFlowCore

// Echte Lernaufgaben mit Lernschritten (Auftrag des Inhabers 14.11.2026): dieselbe erfundene PDF mit Lesezeichen wie
// tools/gen-outline-fixture.py; PDFKit muss dieselben Lesezeichen und Abschnitte lesen wie pypdf, die Aufgaben je
// Lernzeit und Seitenbereich und die Lernschritte muessen gleich sein.

private func fixtures() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return url.appendingPathComponent("packages/shared-contracts/fixtures/local-backend")
}

final class StudyOutlineTests: XCTestCase {
    private func fixture() throws -> JSONValue {
        try JSONValue.parse(Data(contentsOf: fixtures().appendingPathComponent("outline.json")))
    }

    func testPDFKitReadsTheSameBookmarksAndSectionsAsPypdf() throws {
        #if !canImport(PDFKit)
        throw XCTSkip("PDFKit gibt es nur auf Apple-Geraeten")
        #endif
        let fx = try fixture()
        let got = try XCTUnwrap(StudyOutline.readPDF(fixtures().appendingPathComponent("outline-sample.pdf")))
        XCTAssertEqual(got.pages, fx["pages"]?.int)
        let want = (fx["entries"]?.array ?? []).map { e -> String in
            let a = e.array ?? []
            return "\(a[0].int ?? -1)|\(a[1].string ?? "")|\(a[2].int ?? -1)"
        }
        XCTAssertEqual(got.entries.map { "\($0.level)|\($0.title)|\($0.page)" }, want)
        let secs = StudyOutline.sections(entries: got.entries, pageCount: got.pages)
        XCTAssertEqual(JSONValue.array(secs.map(\.json)), fx["sections"])
    }

    /// Gegenprobe mit einer echten Unterlage (nicht im Repository): UF_OUTLINE_PDF = PDF, UF_OUTLINE_EXPECT = JSON von
    /// app/outline.py ({"sections", "parts"} bei 60 Minuten Lernzeit); ohne beide uebersprungen
    func testRealDocumentMatchesPythonWhenGiven() throws {
        let env = ProcessInfo.processInfo.environment
        guard let pdf = env["UF_OUTLINE_PDF"], let expect = env["UF_OUTLINE_EXPECT"] else { throw XCTSkip("keine echte Unterlage angegeben") }
        let fx = try JSONValue.parse(Data(contentsOf: URL(fileURLWithPath: expect)))
        let got = try XCTUnwrap(StudyOutline.readPDF(URL(fileURLWithPath: pdf)))
        let secs = StudyOutline.sections(entries: got.entries, pageCount: got.pages)
        XCTAssertNil(jsonDiff(.array(secs.map(\.json)), fx["sections"]), jsonDiff(.array(secs.map(\.json)), fx["sections"]) ?? "")
        let parts = StudyOutline.parts(secs, pageCount: got.pages, total: StudyOutline.estTotal(60, pageCount: got.pages, kind: "skript"), budget: 60)
        let json = JSONValue.array(parts.map { ["title": .string($0.title), "est": .number(Double($0.est)), "from": .number(Double($0.from)), "to": .number(Double($0.to))] })
        XCTAssertNil(jsonDiff(json, fx["parts"]), jsonDiff(json, fx["parts"]) ?? "")
    }

    func testPartsAndStepsMatchPython() throws {
        let fx = try fixture()
        let pages = try XCTUnwrap(fx["pages"]?.int)
        let secs = (fx["sections"]?.array ?? []).compactMap(StudyOutline.Section.init)
        let cases = fx["cases"]?.array ?? []
        XCTAssertGreaterThanOrEqual(cases.count, 15)
        for (i, c) in cases.enumerated() {
            let empty = c["parts"]?.array?.first?["title"]?.string?.hasPrefix("Arbeitsblätter") == true
            let got = StudyOutline.parts(empty ? [] : secs, pageCount: pages, total: c["total"]?.int ?? 0, budget: c["budget"]?.int ?? 0,
                                         first: c["first"]?.int ?? 1, last: c["last"]?.int, name: empty ? "Arbeitsblätter" : "Beispielskript")
            let json = JSONValue.array(got.map { ["title": .string($0.title), "est": .number(Double($0.est)), "from": .number(Double($0.from)), "to": .number(Double($0.to))] })
            XCTAssertNil(jsonDiff(json, c["parts"]), "Fall \(i): \(jsonDiff(json, c["parts"]) ?? "")")
        }
        for k in ["vorlesung", "skript", "uebung", "loesung", "frei"] {
            XCTAssertEqual(JSONValue.array(StudyOutline.steps(k, 4, 9).map(JSONValue.string)), fx["steps"]?[k], k)
        }
        XCTAssertEqual(JSONValue.array(StudyOutline.steps("skript").map(JSONValue.string)), fx["steps"]?["ohne_seiten"])
    }
}
