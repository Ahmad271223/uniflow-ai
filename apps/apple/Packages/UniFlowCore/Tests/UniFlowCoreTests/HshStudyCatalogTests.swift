import Foundation
import XCTest
@testable import UniFlowCore

// Studienverlauf fuer die Hochschule Hannover (docs/STUDIENGAENGE-HSH-2026-11-05.md): Grundstock hsh-index.json +
// hsh.json.gz (tools/build-hsh-seed.py), Register aller HsH-Studiengaenge (study-sources-hsh.json im gemischten
// Register, Quelle hsh-grundstock), Ablauf mit settings.university = hsh ohne Download.

private func repo() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return url
}

private var seedDir: URL { repo().appendingPathComponent("apps/apple/UniFlow/Resources/StudyCatalogSeed") }

final class HshStudyCatalogTests: XCTestCase {
    typealias StubLoader = StudyCatalogPipelineTests.StubLoader

    private func seed(_ university: String) throws -> StudyCatalogSeed {
        let index = try JSONValue.parse(Data(contentsOf: seedDir.appendingPathComponent("\(university)-index.json")))
        return StudyCatalogSeed(index: index) { try? Data(contentsOf: seedDir.appendingPathComponent($0)) }
    }

    func testHshResourceDecodesValidatesAndMatchesRegister() throws {
        let s = try seed("hsh")
        XCTAssertEqual(s.university, "hsh")
        var checked = Set<String>()
        for e in s.entries where checked.insert(e.libraryKey).inserted {
            XCTAssertEqual(e.libraryKey, StudyCatalogText.libraryKey(university: "hsh", code: e.code, term: e.term), e.code)
            let p = try XCTUnwrap(s.payload(key: e.libraryKey), e.code)
            let c = try JSONValue.parse(p)
            XCTAssertEqual(StudyCatalogValidator.validate(c), [], e.code)
            XCTAssertEqual(c["university"]?.string, "hsh")
            XCTAssertEqual(c["modules"]?.array?.count, e.modules, e.code)
            XCTAssertNotNil(StudySources.bundled.entry(university: "hsh", code: e.code), "Kuerzel im Register: \(e.code)")
            XCTAssertFalse(p.contains("\"content\""), e.code)
        }
        XCTAssertGreaterThanOrEqual(checked.count, 80)
        // Hochschulen getrennt
        let code = try XCTUnwrap(s.entries.first { $0.key.hasPrefix("hsh|angewandte-informatik|b.sc.|bin") }?.code)
        XCTAssertFalse(s.terms(university: "hsh", code: code).isEmpty)
        XCTAssertEqual(s.terms(university: "luh", code: code), [])
        XCTAssertEqual(StudySources.bundled.sourceURLs(university: "hsh", code: code, term: "WS 2026/27"), [], "nur aus dem Grundstock")
    }

    func testRegisterMatchesHshProgramNamesOnlyForHsh() throws {
        let src = StudySources.bundled
        let m = try XCTUnwrap(src.match(label: "Angewandte Informatik", university: "hsh"))
        XCTAssertEqual(m.program, "Angewandte Informatik")
        XCTAssertTrue(m.code.hasPrefix("angewandte-informatik|b.sc.|bin"), m.code)
        let master = try XCTUnwrap(src.match(label: "Master Angewandte Informatik", university: "hsh"))
        XCTAssertEqual(master.degree, "M.Sc.")
        XCTAssertNotNil(src.json["universities"]?.array?.first { $0["id"]?.string == "hsh" })
        XCTAssertNil(src.match(label: "Mediendesigninformatik", university: "hildesheim"))
    }

    func testPipelineUsesHshSeedWithoutDownload() async throws {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: .fixed(berlin: "2026-11-05T10:00:00")!)
        try await b.context.database.transaction { c in
            _ = try c.execute("INSERT INTO grades(pruefungsnr, text, semester, status, abschluss) VALUES ('1', 'Mathematik 1', 'WiSe 25/26', 'BE', ?)",
                              [.text("Angewandte Informatik")])
            _ = try c.execute("INSERT OR REPLACE INTO settings(key, value) VALUES ('university', 'hsh')")
        }
        let seeds = StudyCatalogSeeds([try seed("luh"), try seed("hsh")])
        let loader = StubLoader()
        let env = StudyCatalogPipeline.Environment(loader: loader, library: nil, seed: seeds, pdfText: { _ in [] }, planText: { _ in nil },
                                                   now: { Date(timeIntervalSince1970: 1_793_872_800) })
        let s = await StudyCatalogPipeline.run(db: b.context.database, env: env)
        XCTAssertEqual(s["state"]?.string, "seed", "\(s)")
        XCTAssertEqual(s["program"]?.string, "Angewandte Informatik")
        XCTAssertGreaterThan(s["modules"]?.int ?? 0, 30)
        XCTAssertEqual(loader.count, 0, "nichts geladen")
        let key = try XCTUnwrap(s["key"]?.string)
        let stored = try await b.context.database.transaction { try StudyCatalogStore.catalog($0, key: key) }
        XCTAssertEqual(stored?["university"]?.string, "hsh")
        // Plan fuer die Person: Mathematik 1 bestanden, Semester mit Modulen
        let plan = await b.handle(LocalRequest(method: "GET", url: URL(string: "uniflow-local://device/api/study-plan")!,
                                               headers: [:], body: nil)).json
        XCTAssertEqual(plan?["available"], .bool(true), "\(String(describing: plan))")
        XCTAssertFalse(plan?["semesters"]?.array?.isEmpty ?? true)
    }
}
