import Foundation
import XCTest
@testable import UniFlowCore

// Grundstock der Modulkataloge (tools/build-luh-seed.py, docs/STUDIENGAENGE-LUH-2026-11-04.md "Grundstock"):
// Reihenfolge der Suche lokal -> Grundstock -> Bibliothek -> Laden, Modultexte erst beim Oeffnen eines Moduls (einmal
// je Katalog), gemischtes Register fuer die QIS-Zuordnung aller LUH-Studiengaenge, die mitgelieferte Ressource.

private func repo() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return url
}

private func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: repo().appendingPathComponent("packages/shared-contracts/fixtures/study-catalog/" + name))
}

private func fixturePages() throws -> [String] {
    try (JSONValue.parse(fixture("pages.json")).array ?? []).map { ($0.array ?? []).compactMap(\.string).joined(separator: "\n") }
}

/// Grundstock aus dem Speicher (Schluessel -> Fakten)
final class MemorySeed: StudyCatalogSeedSource, @unchecked Sendable {
    let lock = NSLock()
    var catalogs: [String: String] = [:]
    var lookups = 0
    init(_ payloads: [String] = []) {
        for p in payloads { if let j = try? JSONValue.parse(p) { catalogs[StudyCatalogStore.key(of: j)] = p } }
    }
    func terms(university: String, code: String) -> [String] {
        lock.withLock {
            catalogs.values.compactMap { try? JSONValue.parse($0) }
                .filter { $0["university"]?.string == university && $0["code"]?.string == code }.compactMap { $0["catalog_term"]?.string }
        }
    }
    func payload(key: String) -> String? { lock.withLock { lookups += 1; return catalogs[key] } }
}

final class StudyCatalogSeedTests: XCTestCase {
    typealias StubLoader = StudyCatalogPipelineTests.StubLoader
    typealias MemoryLibrary = StudyCatalogPipelineTests.MemoryLibrary

    let key = StudyCatalogText.libraryKey(university: "luh", code: "TIBSc25", term: "WS 2026/27")
    /// Quelle der Fixture-Fakten (modkat-Link von TIBSc22, WS 2025/26): dort liegen die Texte
    var textURL: String { (try? JSONValue.parse(fixture("expected.json")))?["meta"]?["source"]?["url"]?.string ?? "" }

    private func backend(label: String? = "Technische Informatik (PO-Version 2017)") async throws -> LocalBackend {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: .fixed(berlin: "2026-11-04T10:00:00")!)
        if let label {
            try await b.context.database.transaction { c in
                _ = try c.execute("INSERT INTO grades(pruefungsnr, text, semester, status, abschluss) VALUES ('1', 'Programmieren I', 'WiSe 22/23', 'BE', ?)", [.text(label)])
            }
        }
        return b
    }

    private func env(_ loader: StubLoader, library: StudyCatalogLibrary? = nil, seed: StudyCatalogSeedSource?) throws -> StudyCatalogPipeline.Environment {
        let pages = try fixturePages()
        return StudyCatalogPipeline.Environment(loader: loader, library: library, seed: seed, pdfText: { _ in pages }, planText: { _ in nil },
                                                now: { Date(timeIntervalSince1970: 1_793_786_400) })
    }

    /// Fixture-Fakten unter einem anderen Kuerzel/Semester (wie im Grundstock)
    private func payload(code: String = "TIBSc25", po: String = "2025", term: String = "WS 2026/27", program: String? = nil) throws -> String {
        let exp = try JSONValue.parse(fixture("expected.json"))
        var p = try PyJSON.parse(XCTUnwrap(exp["dumps"]?.string)).planSetting("code", .string(code))
            .planSetting("po", .string(po)).planSetting("catalog_term", .string(term))
        if let program { p = p.planSetting("program", .string(program)) }
        return p.dumps(ensureASCII: false)
    }

    // MARK: Reihenfolge

    func testSeedBeforeLibraryAndDownloadThenLocal() async throws {
        let b = try await backend()
        let loader = StubLoader()
        let lib = MemoryLibrary()
        lib.payloads[key] = [try payload()]
        let seed = MemorySeed([try payload()])
        let s = await StudyCatalogPipeline.run(db: b.context.database, env: try env(loader, library: lib, seed: seed))
        XCTAssertEqual(s["state"]?.string, "seed", "\(s)")
        XCTAssertEqual(s["origin"]?.string, "seed")
        XCTAssertEqual(s["message"]?.string, "Aus dem StudiNow-Grundstock")
        XCTAssertEqual(s["code"]?.string, "TIBSc25")
        XCTAssertEqual(s["needs_confirmation"], .bool(true), "QIS PO-Version 2017 -> TIBSc25 mit Bestaetigung")
        XCTAssertEqual(s["modules"]?.int, 6)
        XCTAssertEqual(lib.lookups, 0, "Grundstock vor der Bibliothek")
        XCTAssertFalse(loader.calls.contains { $0.0.contains("modkat") }, "kein Download")
        XCTAssertEqual(lib.payloads[key]?.count, 1, "Grundstock wird nicht geteilt")
        let origin = try await b.context.database.transaction { try StudyCatalogStore.payload($0, key: self.key)?.origin }
        XCTAssertEqual(origin, "seed")
        // Status-Endpunkt: "seed" ist ein fertiger Stand (kein neuer Anstoss)
        let path = b.context.database.path
        final class Count: @unchecked Sendable { var n = 0 }
        let fired = Count()
        StudyCatalogTriggers.register(databasePath: path) { _ in fired.n += 1 }
        defer { StudyCatalogTriggers.unregister(databasePath: path) }
        let st = await b.handle(LocalRequest(method: "GET", url: URL(string: "uniflow-local://device/api/study-catalog/status")!, headers: [:], body: nil)).json
        XCTAssertEqual(st?["state"]?.string, "seed")
        XCTAssertEqual(fired.n, 0)
        // zweiter Lauf: lokal
        let again = await StudyCatalogPipeline.run(db: b.context.database, env: try env(loader, library: lib, seed: seed))
        XCTAssertEqual(again["origin"]?.string, "local")
        XCTAssertEqual(lib.lookups, 0)
    }

    func testLibraryThenDownloadWhenSeedMisses() async throws {
        let b = try await backend()
        let loader = StubLoader()
        let lib = MemoryLibrary()
        lib.payloads[key] = [try payload()]
        let seed = MemorySeed([try payload(code: "ETBSc25", po: "2025")])
        let s = await StudyCatalogPipeline.run(db: b.context.database, env: try env(loader, library: lib, seed: seed))
        XCTAssertEqual(s["state"]?.string, "library", "\(s)")
        XCTAssertEqual(seed.lookups, 1)
        // weder Grundstock noch Bibliothek: Download (hier 404 -> nicht gefunden)
        let b2 = try await backend()
        let loader2 = StubLoader()
        let s2 = await StudyCatalogPipeline.run(db: b2.context.database, env: try env(loader2, library: MemoryLibrary(), seed: MemorySeed()))
        XCTAssertEqual(s2["state"]?.string, "not_found")
        XCTAssertTrue(loader2.calls.contains { $0.0.contains("modkat-full-TIBSc25") })
    }

    /// Kataloge ausserhalb von modkat (Quelle luh-grundstock): nur aus dem Grundstock, Semester aus dem Grundstock, nie
    /// ein Download; auch erzwungen bleibt der lokale Katalog
    func testGrundstockOnlyCodeNeverDownloads() async throws {
        let m = try XCTUnwrap(StudySources.bundled.match(label: "Mathematik (PO-Version 2020)"))
        XCTAssertEqual(m.program, "Mathematik")
        XCTAssertEqual(m.degree, "B.Sc.")
        XCTAssertFalse(m.needsConfirmation)
        XCTAssertEqual(StudySources.bundled.sourceURLs(university: "luh", code: m.code, term: "WS 2026/27"), [])
        XCTAssertEqual(StudySources.bundled.candidateTerms(university: "luh", code: m.code, today: "2026-11-04"), [], "Semester nur im Grundstock")
        let b = try await backend(label: "Mathematik (PO-Version 2020)")
        let loader = StubLoader()
        let none = await StudyCatalogPipeline.run(db: b.context.database, env: try env(loader, seed: MemorySeed()))
        XCTAssertEqual(none["state"]?.string, "not_found")
        XCTAssertEqual(loader.count, 0)
        let seed = MemorySeed([try payload(code: m.code, po: m.po, term: "SS 2026", program: "Mathematik")])
        let s = await StudyCatalogPipeline.run(db: b.context.database, env: try env(loader, seed: seed))
        XCTAssertEqual(s["state"]?.string, "seed", "\(s)")
        XCTAssertEqual(s["catalog_term"]?.string, "SS 2026")
        let forced = await StudyCatalogPipeline.run(db: b.context.database, env: try env(loader, seed: seed), force: true)
        XCTAssertEqual(forced["origin"]?.string, "local")
        XCTAssertEqual(loader.count, 0)
    }

    func testTermsMergeRegistryAndSeedNewestFirst() throws {
        let seed = MemorySeed([try payload(code: "ETMSc17", term: "WS 2025/26"), try payload(code: "ETMSc17", term: "SS 2027")])
        let e = try env(StubLoader(), seed: seed)
        XCTAssertEqual(StudyCatalogPipeline.terms(env: e, university: "luh", code: "ETMSc17", today: "2026-11-04"),
                       ["SS 2027", "WS 2026/27", "WS 2025/26"])
    }

    // MARK: Modultexte erst beim Oeffnen

    /// Anfragen ausser dem Studienverlaufsplan (den laedt der Ablauf fuer TIBSc25 einmal nach, weil das Register ihn kennt)
    private func pdfCalls(_ loader: StubLoader) -> [String] {
        loader.calls.map(\.0).filter { !$0.contains("Studienverlaufsplan") }
    }

    func testModuleTextsLoadedLazilyOncePerCatalog() async throws {
        let b = try await backend()
        let loader = StubLoader()
        _ = await StudyCatalogPipeline.run(db: b.context.database, env: try env(loader, seed: MemorySeed([try payload()])))
        XCTAssertEqual(pdfCalls(loader).count, 0, "Grundstock: kein Katalog-Download (nur der Studienverlaufsplan des Registers)")
        let path = b.context.database.path
        final class Keys: @unchecked Sendable { var keys: [String] = [] }
        let fired = Keys()
        StudyCatalogTriggers.registerTexts(databasePath: path) { fired.keys.append($0) }
        defer { StudyCatalogTriggers.unregister(databasePath: path) }
        func module() async -> JSONValue? {
            await b.handle(LocalRequest(method: "GET", url: URL(string: "uniflow-local://device/api/study-plan/module/beispielprogrammierung-1")!,
                                        headers: [:], body: nil)).json
        }
        let first = await module()
        XCTAssertEqual(first?["available"], .bool(true), "\(String(describing: first))")
        XCTAssertEqual(first?["texts"], .null)
        XCTAssertEqual(first?["texts_loading"], .bool(true))
        XCTAssertEqual(fired.keys, [key])
        // die App laedt: einmal die oeffentliche PDF der Quelle, nur Texte
        loader.responses[textURL] = StudyCatalogFetchResult(status: 200, data: try fixture("modkat-sample.pdf"), etag: "\"t1\"")
        let e = try env(loader, seed: nil)
        let r = await StudyCatalogPipeline.loadTexts(db: b.context.database, env: e, key: key)
        XCTAssertEqual(r["state"]?.string, "loaded", "\(r)")
        XCTAssertEqual(r["modules"]?.int, 6)
        XCTAssertEqual(pdfCalls(loader), [textURL])
        let text = try await b.context.database.transaction { try StudyCatalogStore.moduleText($0, key: self.key, moduleID: "beispielprogrammierung-1") }
        XCTAssertEqual(text?["content"]?.string, "Variablen, Schleifen und Funktionen\nEinfache Datenstrukturen")
        let facts = try await b.context.database.transaction { try StudyCatalogStore.payload($0, key: self.key) }
        XCTAssertEqual(facts?.payload, try payload(), "Fakten unveraendert")
        XCTAssertEqual(facts?.origin, "seed")
        // danach: Texte im Modul, kein neuer Anstoss, kein neuer Download
        let second = await module()
        XCTAssertEqual(second?["texts"]?["content"]?.string, "Variablen, Schleifen und Funktionen\nEinfache Datenstrukturen")
        XCTAssertNil(second?["texts_loading"])
        XCTAssertEqual(fired.keys.count, 1)
        let r2 = await StudyCatalogPipeline.loadTexts(db: b.context.database, env: e, key: key)
        XCTAssertEqual(r2["state"]?.string, "have")
        XCTAssertEqual(pdfCalls(loader).count, 1)
    }

    func testModuleTextsErrorPausesAndUnsupportedSourceNeverLoads() async throws {
        let b = try await backend()
        let loader = StubLoader()
        _ = await StudyCatalogPipeline.run(db: b.context.database, env: try env(loader, seed: MemorySeed([try payload()])))
        loader.responses[textURL] = StudyCatalogFetchResult(status: 503, error: "HTTP 503")
        let e = try env(loader, seed: nil)
        let r = await StudyCatalogPipeline.loadTexts(db: b.context.database, env: e, key: key)
        XCTAssertEqual(r["state"]?.string, "error")
        let wanted = try await b.context.database.transaction { try StudyCatalogPipeline.textsWanted($0, key: self.key, now: Date(timeIntervalSince1970: 1_793_786_400 + 3600)) }
        XCTAssertFalse(wanted, "24 Stunden Pause")
        _ = await StudyCatalogPipeline.loadTexts(db: b.context.database, env: e, key: key)
        XCTAssertEqual(pdfCalls(loader).count, 1)
        // Quelle ohne modkat-Link (andere Formate): nie laden
        let b2 = try await backend(label: "Mathematik (PO-Version 2020)")
        let m = try XCTUnwrap(StudySources.bundled.match(label: "Mathematik (PO-Version 2020)"))
        let other = try PyJSON.parse(try payload(code: m.code, po: m.po, term: "SS 2026"))
            .planSetting("source", .object([PyJSON.Member("url", .string("https://www.maphy.uni-hannover.de/katalog.pdf"))])).dumps(ensureASCII: false)
        let otherKey = StudyCatalogText.libraryKey(university: "luh", code: m.code, term: "SS 2026")
        _ = await StudyCatalogPipeline.run(db: b2.context.database, env: try env(loader, seed: MemorySeed([other])))
        let u = await StudyCatalogPipeline.loadTexts(db: b2.context.database, env: e, key: otherKey)
        XCTAssertEqual(u["state"]?.string, "unsupported")
        XCTAssertEqual(pdfCalls(loader).count, 1)
    }

    // MARK: Register und Ressource

    func testQISMatchingAcrossFullLUHRegistry() throws {
        let src = StudySources.bundled
        let ti = try XCTUnwrap(src.match(label: "Technische Informatik (PO-Version 2017)"))
        XCTAssertEqual(ti.code, "TIBSc25")
        XCTAssertTrue(ti.needsConfirmation)
        let et = try XCTUnwrap(src.match(label: "Elektrotechnik und Informationstechnik (PO-Version 2017)"))
        XCTAssertEqual(et.code, "ETBSc17")
        XCTAssertFalse(et.needsConfirmation)
        XCTAssertEqual(src.match(label: "Elektrotechnik und Informationstechnik (PO-Version 2025)")?.code, "ETBSc25")
        XCTAssertEqual(src.match(label: "Informatik Master (PO-Version 2017)")?.degree, "M.Sc.")
        XCTAssertEqual(src.match(label: "Maschinenbau (PO-Version 2017)")?.program, "Maschinenbau")
        XCTAssertNil(src.match(label: "Musterfach (PO-Version 2017)"))
        // jeder Katalog der Erhebung ist ueber sein Kuerzel erreichbar
        let luh = try JSONValue.parse(Data(contentsOf: repo().appendingPathComponent("packages/shared-contracts/study-sources-luh.json")))
        var urls = 0
        for e in luh["programs"]?.array ?? [] {
            for c in [e["catalog"]].compactMap({ $0 }) + (e["more_catalogs"]?.array ?? []) {
                guard let url = c["url"]?.string, !["none", "overview-only"].contains(c["format"]?.string ?? "none") else { continue }
                urls += 1
                if let parts = StudyCatalogPipeline.modkatParts(url) {
                    XCTAssertNotNil(src.entry(university: "luh", code: parts.code), url)
                }
            }
        }
        XCTAssertGreaterThan(urls, 140)
        let codes = (src.json["universities"]?.array?.first?["programs"]?.array ?? []).flatMap { $0["pos"]?.array ?? [] }.compactMap { $0["code"]?.string }
        XCTAssertGreaterThan(Set(codes).count, 120)
    }

    func testBundledResourceDecodesAndValidates() throws {
        let dir = repo().appendingPathComponent("apps/apple/UniFlow/Resources/StudyCatalogSeed")
        let index = try JSONValue.parse(Data(contentsOf: dir.appendingPathComponent("luh-index.json")))
        let seed = StudyCatalogSeed(index: index) { try? Data(contentsOf: dir.appendingPathComponent($0)) }
        XCTAssertGreaterThan(seed.entries.count, 20)
        XCTAssertEqual(seed.terms(university: "luh", code: "TIBSc25"), ["WS 2026/27"])
        XCTAssertEqual(seed.terms(university: "tuhh", code: "TIBSc25"), [])
        let ti = try XCTUnwrap(seed.payload(key: key))
        let j = try JSONValue.parse(ti)
        XCTAssertEqual(StudyCatalogValidator.validate(j), [])
        XCTAssertNotNil(j["study_plan"]?.object, "TIBSc25 mit Studienverlaufsplan")
        XCTAssertNil(seed.payload(key: "0000"))
        var checked = Set<String>()
        for e in seed.entries where checked.insert(e.libraryKey).inserted {
            let p = try XCTUnwrap(seed.payload(key: e.libraryKey), e.code)
            let c = try JSONValue.parse(p)
            XCTAssertEqual(StudyCatalogValidator.validate(c), [], e.code)
            XCTAssertEqual(c["modules"]?.array?.count, e.modules, e.code)
            XCTAssertNotNil(StudySources.bundled.entry(university: "luh", code: e.code), "Kuerzel im Register: \(e.code)")
            XCTAssertFalse(p.contains("\"content\""), e.code)
        }
        XCTAssertGreaterThanOrEqual(checked.count, 21)
        // kaputte Daten: leer statt Absturz
        XCTAssertNil(StudyCatalogSeed.gunzip(Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9])))
        XCTAssertNil(StudyCatalogSeed.gunzip(Data("kein gzip".utf8)))
        let broken = StudyCatalogSeed(index: index) { _ in Data("x".utf8) }
        XCTAssertNil(broken.payload(key: key))
    }
}
