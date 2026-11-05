import Foundation
import XCTest
@testable import UniFlowCore

// Studienverlauf fuer die Universitaet Hildesheim (docs/STUDIENGAENGE-HILDESHEIM-2026-11-05.md): Grundstock je
// Hochschule (luh-index.json + hildesheim-index.json, `StudyCatalogSeed.bundledAll`), Register mit allen Hildesheimer
// Studiengaengen (study-sources-hildesheim.json im gemischten Register), LSF-Zeile "Abschluss: ... Studiengang: ..."
// als QIS-Bezeichnung, Ablauf mit settings.university = hildesheim ohne Download.

private func repo() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return url
}

private var seedDir: URL { repo().appendingPathComponent("apps/apple/UniFlow/Resources/StudyCatalogSeed") }

final class HildesheimStudyCatalogTests: XCTestCase {
    typealias StubLoader = StudyCatalogPipelineTests.StubLoader

    static let aiLabel = "Abschluss: [82] Bachelor Studiengang: [079] B.Sc. Angewandte Informatik PO-Version: 2024"

    /// Grundstock einer Hochschule aus dem Repo (wie im App-Bundle)
    private func seed(_ university: String) throws -> StudyCatalogSeed {
        let index = try JSONValue.parse(Data(contentsOf: seedDir.appendingPathComponent("\(university)-index.json")))
        return StudyCatalogSeed(index: index) { try? Data(contentsOf: seedDir.appendingPathComponent($0)) }
    }

    /// Nachgebildetes Bundle mit beiden Verzeichnissen und Dateien im Unterordner StudyCatalogSeed
    private func stubBundle(universities: [String] = ["luh", "hildesheim"]) throws -> Bundle {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("seeds-\(UUID().uuidString).bundle", isDirectory: true)
        let sub = dir.appendingPathComponent("StudyCatalogSeed", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        for u in universities {
            let index = try JSONValue.parse(Data(contentsOf: seedDir.appendingPathComponent("\(u)-index.json")))
            try FileManager.default.copyItem(at: seedDir.appendingPathComponent("\(u)-index.json"), to: sub.appendingPathComponent("\(u)-index.json"))
            for (file, _) in index["files"]?.object ?? [:] {
                try FileManager.default.copyItem(at: seedDir.appendingPathComponent(file), to: sub.appendingPathComponent(file))
            }
        }
        return try XCTUnwrap(Bundle(url: dir))
    }

    // MARK: Grundstock je Hochschule

    func testHildesheimResourceDecodesValidatesAndMatchesRegister() throws {
        let s = try seed("hildesheim")
        XCTAssertEqual(s.university, "hildesheim")
        XCTAssertGreaterThan(s.entries.count, 60)
        var checked = Set<String>()
        for e in s.entries where checked.insert(e.libraryKey).inserted {
            XCTAssertEqual(e.libraryKey, StudyCatalogText.libraryKey(university: "hildesheim", code: e.code, term: e.term), e.code)
            let p = try XCTUnwrap(s.payload(key: e.libraryKey), e.code)
            let c = try JSONValue.parse(p)
            XCTAssertEqual(StudyCatalogValidator.validate(c), [], e.code)
            XCTAssertEqual(c["university"]?.string, "hildesheim")
            XCTAssertEqual(c["modules"]?.array?.count, e.modules, e.code)
            XCTAssertNotNil(StudySources.bundled.entry(university: "hildesheim", code: e.code), "Kuerzel im Register: \(e.code)")
            XCTAssertFalse(p.contains("\"content\""), e.code)
            XCTAssertEqual(s.terms(university: "hildesheim", code: e.code).first.map { StudyCatalogText.termNumber($0) != nil }, true)
        }
        XCTAssertGreaterThanOrEqual(checked.count, 60)
        // die Hochschule gehoert zum Grundstock: ein LUH-Kuerzel gibt es hier nicht, die Semester nur fuer "hildesheim"
        XCTAssertEqual(s.terms(university: "hildesheim", code: "TIBSc25"), [])
        XCTAssertEqual(s.terms(university: "luh", code: "angewandte-informatik|b.sc.|2024"), [])
        XCTAssertFalse(s.terms(university: "hildesheim", code: "angewandte-informatik|b.sc.|2024").isEmpty)
    }

    func testBundledPerUniversityAndAllTogether() throws {
        let bundle = try stubBundle()
        // bisheriger Aufruf bleibt der LUH-Grundstock
        let luh = try XCTUnwrap(StudyCatalogSeed.bundled(bundle))
        XCTAssertEqual(luh.university, "luh")
        XCTAssertEqual(luh.terms(university: "luh", code: "TIBSc25"), ["WS 2026/27"])
        let hi = try XCTUnwrap(StudyCatalogSeed.bundled(bundle, university: "hildesheim"))
        XCTAssertEqual(hi.university, "hildesheim")
        XCTAssertNil(StudyCatalogSeed.bundled(bundle, university: "tuhh"))

        let all = try XCTUnwrap(StudyCatalogSeed.bundledAll(bundle))
        XCTAssertEqual(all.universities, ["luh", "hildesheim"])
        XCTAssertEqual(all.entries.count, luh.entries.count + hi.entries.count)
        XCTAssertEqual(all.terms(university: "luh", code: "TIBSc25"), ["WS 2026/27"])
        let code = "angewandte-informatik|b.sc.|2024"
        let terms = all.terms(university: "hildesheim", code: code)
        XCTAssertEqual(terms, hi.terms(university: "hildesheim", code: code))
        XCTAssertEqual(all.terms(university: "tuhh", code: code), [])
        let key = StudyCatalogText.libraryKey(university: "hildesheim", code: code, term: try XCTUnwrap(terms.first))
        let p = try XCTUnwrap(all.payload(key: key))
        XCTAssertEqual(try JSONValue.parse(p)["program"]?.string, "Angewandte Informatik")
        XCTAssertNotNil(all.payload(key: StudyCatalogText.libraryKey(university: "luh", code: "TIBSc25", term: "WS 2026/27")))
        XCTAssertNil(all.payload(key: "0000"))
        XCTAssertEqual(all.seed(university: "hildesheim")?.university, "hildesheim")

        // nur ein Verzeichnis im Bundle: die anderen fehlen einfach
        let onlyLUH = try XCTUnwrap(StudyCatalogSeed.bundledAll(try stubBundle(universities: ["luh"])))
        XCTAssertEqual(onlyLUH.universities, ["luh"])
        XCTAssertEqual(onlyLUH.terms(university: "hildesheim", code: code), [])
    }

    // MARK: Register und LSF-Bezeichnung

    func testLSFLabelParsingAndMatching() throws {
        let a = StudySources.parseAbschluss(Self.aiLabel)
        XCTAssertEqual(a, StudySources.Abschluss(name: "Angewandte Informatik", po: "2024", degree: "B"))
        XCTAssertEqual(StudySources.parseAbschluss("Abschluss: [Ed] Master of Education Studiengang: [026] M.Ed. Biologie PO-Version: 2026"),
                       StudySources.Abschluss(name: "Biologie", po: "2026", degree: "M"))
        XCTAssertEqual(StudySources.parseAbschluss("Abschluss: [88] Master Studiengang: [079] Informatik PO-Version: 2019"),
                       StudySources.Abschluss(name: "Informatik", po: "2019", degree: "M"))
        // LUH-Formen unveraendert
        XCTAssertEqual(StudySources.parseAbschluss("Technische Informatik (PO-Version 2017)"),
                       StudySources.Abschluss(name: "Technische Informatik", po: "2017", degree: nil))
        XCTAssertEqual(StudySources.parseAbschluss("Abschluss: Bachelor Informatik PO-Version: 2017"),
                       StudySources.Abschluss(name: "Informatik", po: "2017", degree: "B"))

        let src = StudySources.bundled
        let m = try XCTUnwrap(src.match(label: Self.aiLabel, university: "hildesheim"))
        XCTAssertEqual(m.program, "Angewandte Informatik")
        XCTAssertEqual(m.degree, "B.Sc.")
        XCTAssertEqual(m.code, "angewandte-informatik|b.sc.|2024")
        XCTAssertFalse(m.needsConfirmation, "PO-Version 2024 passt")
        XCTAssertEqual(src.sourceURLs(university: "hildesheim", code: m.code, term: "WS 2026/27"), [], "nur aus dem Grundstock")
        let master = try XCTUnwrap(src.match(label: "Abschluss: [88] Master Studiengang: [079] M.Sc. Angewandte Informatik PO-Version: 2024",
                                             university: "hildesheim"))
        XCTAssertEqual(master.degree, "M.Sc.")
        // Fach im Zwei-Faecher-Bachelor bzw. im Master Lehramt
        let bio = try XCTUnwrap(src.match(label: "Abschluss: [82] Bachelor Studiengang: [026] B.A. Biologie PO-Version: 2025", university: "hildesheim"))
        XCTAssertEqual(bio.program, "Biologie im Polyvalenten Zwei-Fächer-Bachelor")
        let bioMEd = try XCTUnwrap(src.match(label: "Abschluss: [Ed] Master of Education Studiengang: [026] M.Ed. Biologie PO-Version: 2026",
                                             university: "hildesheim"))
        XCTAssertEqual(bioMEd.degree, "M.Ed.")
        // Hochschulen getrennt: Hildesheimer Name bei der LUH nicht (und umgekehrt)
        XCTAssertNil(src.match(label: Self.aiLabel, university: "luh"))
        XCTAssertNil(src.match(label: "Technische Informatik (PO-Version 2017)", university: "hildesheim"))
        XCTAssertNil(src.match(label: "Abschluss: [82] Bachelor Studiengang: [052] B.A. Testfach PO-Version: 2022", university: "hildesheim"))
        // gemischtes Register: LUH bleibt die erste Hochschule
        XCTAssertEqual(src.json["universities"]?.array?.first?["id"]?.string, "luh")
        XCTAssertNotNil(src.json["universities"]?.array?.first { $0["id"]?.string == "hildesheim" })
    }

    // MARK: Ablauf

    func testPipelineUsesSeedOfContainerUniversity() async throws {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: .fixed(berlin: "2026-11-05T10:00:00")!)
        try await b.context.database.transaction { c in
            _ = try c.execute("INSERT INTO grades(pruefungsnr, text, semester, status, abschluss) VALUES ('1', 'Einführung in die Informatik', 'WiSe 24/25', 'BE', ?)",
                              [.text(Self.aiLabel)])
            _ = try c.execute("INSERT OR REPLACE INTO settings(key, value) VALUES ('university', 'hildesheim')")
        }
        let seeds = StudyCatalogSeeds([try seed("luh"), try seed("hildesheim")])
        let loader = StubLoader()
        let env = StudyCatalogPipeline.Environment(loader: loader, library: nil, seed: seeds, pdfText: { _ in [] }, planText: { _ in nil },
                                                   now: { Date(timeIntervalSince1970: 1_793_872_800) })
        let s = await StudyCatalogPipeline.run(db: b.context.database, env: env)
        XCTAssertEqual(s["state"]?.string, "seed", "\(s)")
        XCTAssertEqual(s["program"]?.string, "Angewandte Informatik")
        XCTAssertEqual(s["code"]?.string, "angewandte-informatik|b.sc.|2024")
        XCTAssertGreaterThan(s["modules"]?.int ?? 0, 50)
        XCTAssertEqual(loader.count, 0, "nichts geladen")
        let key = try XCTUnwrap(s["key"]?.string)
        let stored = try await b.context.database.transaction { try StudyCatalogStore.catalog($0, key: key) }
        XCTAssertEqual(stored?["university"]?.string, "hildesheim")
    }
}
