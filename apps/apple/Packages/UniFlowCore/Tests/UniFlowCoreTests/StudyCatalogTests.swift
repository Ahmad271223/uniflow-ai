import Foundation
import XCTest
@testable import UniFlowCore

// Modulkatalog (docs/STUDIENVERLAUF-2026-11-04.md) gegen die Python-Referenz app/study_catalog.py: erfundene PDF im
// Aufbau der LUH-Kataloge (tools/gen-study-catalog-fixture.py), Zeilen aus PDFKit = Zeilen aus pypdf, Parser liefert
// byte-gleiches JSON, Validator dieselbe Fehlerliste, Register und Schluessel gleich; dazu Ablauf der Suche (lokal ->
// Bibliothek -> Laden) mit Attrappen fuer Bibliothek und Laden.

private func root() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return url
}

private func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: root().appendingPathComponent("packages/shared-contracts/fixtures/study-catalog/" + name))
}

private func json(_ name: String) throws -> JSONValue { try JSONValue.parse(fixture(name)) }

private func meta(_ v: JSONValue) -> StudyCatalogMeta {
    StudyCatalogMeta(university: v["university"]?.string ?? "", program: v["program"]?.string ?? "", degree: v["degree"]?.string ?? "",
                     po: v["po"]?.string ?? "", code: v["code"]?.string ?? "", catalogTerm: v["catalog_term"]?.string ?? "",
                     regularSemesters: v["regular_semesters"]?.int, totalLP: v["total_lp"]?.double,
                     sourceURL: v["source"]?["url"]?.string, fetchedAt: v["source"]?["fetched_at"]?.string, sha256: v["source"]?["sha256"]?.string)
}

/// Seiten der Fixture als Text (Zeilen aus pages.json), unabhaengig von PDFKit
private func fixturePages() throws -> [String] {
    try (json("pages.json").array ?? []).map { ($0.array ?? []).compactMap(\.string).joined(separator: "\n") }
}

final class StudyCatalogTextTests: XCTestCase {
    func testNormalizeAndSlugMatchPython() throws {
        let cases = try json("text-cases.json")
        for c in cases["normalize"]?.array ?? [] {
            XCTAssertEqual(StudyCatalogText.normalizeLines(c["text"]?.string ?? ""), (c["lines"]?.array ?? []).compactMap(\.string), c["text"]?.string ?? "")
        }
        for c in cases["slug"]?.array ?? [] {
            XCTAssertEqual(StudyCatalogText.slug(c["text"]?.string ?? ""), c["slug"]?.string, c["text"]?.string ?? "")
        }
    }

    func testRegistryMatchesKeysURLsAndTermsLikePython() throws {
        let cases = try json("registry-cases.json")
        let src = StudySources.bundled
        for c in cases["matches"]?.array ?? [] {
            let got = src.match(label: c["label"]?.string ?? "", university: c["university"]?.string ?? "luh", po: c["po"]?.string)
            XCTAssertEqual(got?.json ?? .null, c["result"], c["label"]?.string ?? "")
        }
        for c in cases["keys"]?.array ?? [] {
            XCTAssertEqual(StudyCatalogText.libraryKey(university: c["university"]!.string!, code: c["code"]!.string!, term: c["term"]!.string!), c["key"]?.string)
        }
        for c in cases["urls"]?.array ?? [] {
            XCTAssertEqual(src.sourceURLs(university: "luh", code: c["code"]!.string!, term: c["term"]!.string!), (c["urls"]?.array ?? []).compactMap(\.string))
        }
        for c in cases["terms"]?.array ?? [] {
            XCTAssertEqual(src.candidateTerms(university: "luh", code: c["code"]!.string!, today: c["today"]!.string!), (c["terms"]?.array ?? []).compactMap(\.string))
        }
        for c in cases["title_terms"]?.array ?? [] {
            XCTAssertEqual(StudyCatalogText.termFromTitle(c["text"]?.string ?? ""), c["term"]?.string)
        }
        for c in cases["study_plans"]?.array ?? [] {
            XCTAssertEqual(src.studyPlanURL(university: "luh", code: c["code"]!.string!), c["url"]?.string)
        }
        for c in cases["modkat_parts"]?.array ?? [] {
            let got = StudyCatalogPipeline.modkatParts(c["url"]!.string!)
            XCTAssertEqual(got.map { [$0.code, $0.term] }, c["parts"]?.array?.compactMap(\.string))
        }
        // Spec-Beispiel: "Technische Informatik (PO-Version 2017)" -> neueste PO (TIBSc25), Bestaetigung noetig
        let m = try XCTUnwrap(src.match(label: "Technische Informatik (PO-Version 2017)"))
        XCTAssertEqual(m.code, "TIBSc25")
        XCTAssertTrue(m.needsConfirmation)
    }

    func testEmbeddedRegistryEqualsSharedFile() throws {
        // gemischtes Register: study-sources.json + alle LUH-Studiengaenge (study-sources-luh.json)
        let file = try JSONValue.parse(Data(contentsOf: root().appendingPathComponent("packages/shared-contracts/study-sources-all.json")))
        XCTAssertEqual(StudySources.bundled.json, file, "tools/gen-study-catalog-fixture.py ausfuehren")
    }
}

final class StudyCatalogParserTests: XCTestCase {
    func testParserIsByteEqualToPythonOnFixtureLines() throws {
        let exp = try json("expected.json")
        let parsed = StudyCatalogParser.parse(pages: try fixturePages(), meta: meta(exp["meta"]!))
        XCTAssertEqual(parsed.catalogDumps, exp["dumps"]?.string)
        XCTAssertEqual(parsed.textsDumps, exp["texts_dumps"]?.string)
        XCTAssertEqual(StudyCatalogStore.key(of: parsed.catalog.json), exp["key"]?.string)
        XCTAssertEqual(StudyCatalogText.libraryKey(university: "luh", code: "TIBSc22", term: "WS 2025/26"), exp["key"]?.string)
        XCTAssertEqual(StudyCatalogValidator.validate(parsed.catalog.json), [])
    }

    #if canImport(PDFKit)
    func testPDFKitLinesEqualPypdfLinesAndParseByteEqual() throws {
        let pdf = try fixture("modkat-sample.pdf")
        let pages = try XCTUnwrap(StudyCatalogPDF.pages(pdf))
        let expectedLines = (try json("pages.json").array ?? []).map { ($0.array ?? []).compactMap(\.string) }
        XCTAssertEqual(pages.map(StudyCatalogText.normalizeLines), expectedLines)
        let exp = try json("expected.json")
        XCTAssertEqual(SolutionSHA256.hex(pdf), exp["meta"]?["source"]?["sha256"]?.string)
        let parsed = StudyCatalogParser.parse(pages: pages, meta: meta(exp["meta"]!))
        XCTAssertEqual(parsed.catalogDumps, exp["dumps"]?.string)
        XCTAssertEqual(parsed.textsDumps, exp["texts_dumps"]?.string)
    }
    #endif

    func testFullFormatParserIsByteEqualToPython() throws {
        let exp = try json("expected-full.json")
        let pages = try (json("pages-full.json").array ?? []).map { ($0.array ?? []).compactMap(\.string).joined(separator: "\n") }
        let parsed = StudyCatalogParser.parse(pages: pages, meta: meta(exp["meta"]!))
        XCTAssertEqual(parsed.catalogDumps, exp["dumps"]?.string)
        XCTAssertEqual(parsed.textsDumps, exp["texts_dumps"]?.string)
        #if canImport(PDFKit)
        let pdf = try fixture("modkat-full-sample.pdf")
        let kitPages = try XCTUnwrap(StudyCatalogPDF.pages(pdf))
        XCTAssertEqual(kitPages.map(StudyCatalogText.normalizeLines), (try json("pages-full.json").array ?? []).map { ($0.array ?? []).compactMap(\.string) })
        XCTAssertEqual(StudyCatalogParser.parse(pages: kitPages, meta: meta(exp["meta"]!)).catalogDumps, exp["dumps"]?.string)
        #endif
    }

    func testValidatorCasesMatchPython() throws {
        for c in try json("validator-cases.json").array ?? [] {
            XCTAssertEqual(StudyCatalogValidator.validate(c["catalog"]!), (c["errors"]?.array ?? []).compactMap(\.string), c["name"]?.string ?? "")
        }
    }

    func testSharedFactsHaveNoModuleTexts() throws {
        let exp = try json("expected.json")
        let parsed = StudyCatalogParser.parse(pages: try fixturePages(), meta: meta(exp["meta"]!))
        for m in parsed.catalog.json["modules"]?.array ?? [] {
            XCTAssertNil(m["content"]); XCTAssertNil(m["goals"]); XCTAssertNil(m["literature"])
        }
        XCTAssertFalse(parsed.catalogDumps.contains("Variablen, Schleifen"), "Inhalt nur lokal")
        XCTAssertTrue(parsed.textsDumps.contains("Variablen, Schleifen"))
    }
}

// MARK: - Studienverlaufsplan

private func planItems() throws -> [[StudyPlanTextItem]] {
    try (json("plan-items.json").array ?? []).map { page in
        (page.array ?? []).compactMap { it -> StudyPlanTextItem? in
            guard let a = it.array, a.count >= 3, let x = a[0].double, let y = a[1].double, let t = a[2].string else { return nil }
            return StudyPlanTextItem(x: x, y: y, text: t)
        }
    }
}

final class StudyPlanSheetTests: XCTestCase {
    func testParseAndMergeAreByteEqualToPython() throws {
        let exp = try json("plan-expected.json")
        let plan = StudyPlanSheet.parse(pages: try planItems())
        XCTAssertEqual(plan.dumps(ensureASCII: false), exp["plan_dumps"]?.string)
        let catalog = try PyJSON.parse(XCTUnwrap(json("expected.json")["dumps"]?.string))
        let src = exp["source"]!
        let (merged, unmatched) = StudyPlanSheet.merge(catalog: catalog, plan: plan,
                                                       source: (src["url"]!.string!, src["fetched_at"]?.string, src["sha256"]?.string))
        XCTAssertEqual(merged.dumps(ensureASCII: false), exp["catalog_dumps"]?.string)
        XCTAssertEqual(unmatched, (exp["unmatched"]?.array ?? []).compactMap(\.string))
        XCTAssertEqual(StudyCatalogValidator.validate(merged.json), [])
        for c in exp["merge_cases"]?.array ?? [] {
            let (got, um) = StudyPlanSheet.merge(catalog: try PyJSON.parse(c["catalog_dumps"]!.string!), plan: try PyJSON.parse(c["plan_dumps"]!.string!))
            XCTAssertEqual(got.dumps(ensureASCII: false), c["dumps"]?.string, c["name"]?.string ?? "")
            XCTAssertEqual(um, (c["unmatched"]?.array ?? []).compactMap(\.string), c["name"]?.string ?? "")
        }
    }

    #if canImport(PDFKit)
    /// PDFKit liefert andere Stuecke (Rahmen statt Grundlinie, "2V+2Ü | 5 ECTS" in einem) - der Plan ist derselbe
    func testPDFKitItemsGiveSamePlan() throws {
        let pdf = try fixture("plan-sample.pdf")
        let items = try XCTUnwrap(StudyCatalogPDF.planItems(pdf))
        XCTAssertEqual(StudyPlanSheet.parse(pages: items).dumps(ensureASCII: false), try json("plan-expected.json")["plan_dumps"]?.string)
    }
    #endif
}

// MARK: - Ablauf der Suche

final class StudyCatalogPipelineTests: XCTestCase {
    final class StubLoader: StudyCatalogLoader, @unchecked Sendable {
        let lock = NSLock()
        var responses: [String: StudyCatalogFetchResult] = [:]
        var calls: [(String, String?)] = []
        func fetch(url: String, etag: String?, lastModified: String?) async -> StudyCatalogFetchResult {
            lock.withLock {
                calls.append((url, etag))
                return responses[url] ?? StudyCatalogFetchResult(status: 404, error: "HTTP 404")
            }
        }
        var count: Int { lock.withLock { calls.count } }
    }

    final class MemoryLibrary: StudyCatalogLibrary, @unchecked Sendable {
        let lock = NSLock()
        var payloads: [String: [String]] = [:]
        var lookups = 0
        func lookup(key: String) async throws -> [String] { lock.withLock { lookups += 1; return payloads[key] ?? [] } }
        func publish(key: String, meta: StudyCatalogMeta, payload: String) async throws -> Bool {
            lock.withLock {
                guard (payloads[key]?.count ?? 0) < 3 else { return false }
                payloads[key, default: []].append(payload)
                return true
            }
        }
    }

    let primary = "https://modkat.fei.uni-hannover.de/material/modkat-full-TIBSc25-WS_2026_27.pdf"
    let mirror = "https://modkat.fei.uni-hannover.de/material/modkat-TIBSc25-WS_2026_27.pdf"
    let oldMirror = "https://modkat.fei.uni-hannover.de/material/modkat-TIBSc22-WS_2025_26.pdf"
    let planURL = "https://www.fei.uni-hannover.de/fileadmin/fei/Dateien-Studium/Studiengaenge_Technische_Informatik/B.Sc/"
        + "Studienverlaufsplan_Bachelor_Technische_Informatik_WS2026-27.pdf"
    let key = StudyCatalogText.libraryKey(university: "luh", code: "TIBSc25", term: "WS 2026/27")

    private func backend(label: String? = "Technische Informatik (PO-Version 2017)") async throws -> LocalBackend {
        let b = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: .fixed(berlin: "2026-11-04T10:00:00")!)
        if let label {
            try await b.context.database.transaction { c in
                _ = try c.execute("INSERT INTO grades(pruefungsnr, text, semester, status, abschluss) VALUES ('1', 'Programmieren I', 'WiSe 22/23', 'BE', ?)", [.text(label)])
            }
        }
        return b
    }

    private func env(_ loader: StubLoader, _ library: StudyCatalogLibrary?, now: Date = Date(timeIntervalSince1970: 1_793_786_400)) throws -> StudyCatalogPipeline.Environment {
        let pages = try fixturePages()
        let items = try planItems()
        return StudyCatalogPipeline.Environment(loader: loader, library: library, pdfText: { _ in pages }, planText: { _ in items }, now: { now })
    }

    private func status(_ b: LocalBackend) async -> JSONValue? {
        await b.handle(LocalRequest(method: "GET", url: URL(string: "uniflow-local://device/api/study-catalog/status")!, headers: [:], body: nil)).json
    }

    func testStatusIdleBeforeFirstRun() async throws {
        let b = try await backend()
        let s = await status(b)
        XCTAssertEqual(s?["state"]?.string, "idle")
    }

    func testStatusTriggersSearchOnlyWhenInputsChange() async throws {
        let b = try await backend()
        let path = b.context.database.path
        final class Count: @unchecked Sendable { var n = 0 }
        let fired = Count()
        StudyCatalogTriggers.register(databasePath: path) { _ in fired.n += 1 }
        defer { StudyCatalogTriggers.unregister(databasePath: path) }
        do { let st = await status(b); XCTAssertEqual(st?["state"]?.string, "searching", "noch nie gesucht: anstossen") }
        XCTAssertEqual(fired.n, 1)
        let loader = StubLoader()
        loader.responses[mirror] = StudyCatalogFetchResult(status: 200, data: try fixture("modkat-sample.pdf"))
        _ = await StudyCatalogPipeline.run(db: b.context.database, env: try env(loader, nil, now: Date()))
        do { let st = await status(b); XCTAssertEqual(st?["state"]?.string, "ready") }
        XCTAssertEqual(fired.n, 1, "gleiche Eingaben: nicht erneut")
        // PO bestaetigt -> neue Eingaben -> neue Suche
        try await b.context.database.transaction { c in
            _ = try c.execute("INSERT OR REPLACE INTO settings(key, value) VALUES ('study_plan', '{\"po\": \"TIBSc22\"}')")
        }
        do { let st = await status(b); XCTAssertEqual(st?["state"]?.string, "searching") }
        XCTAssertEqual(fired.n, 2)
    }

    func testDownloadOnceFromMirrorParseStoreAndShare() async throws {
        let b = try await backend()
        let loader = StubLoader()
        // nur auf dem Spiegel; Studienverlaufsplan 404 (wird gemerkt)
        loader.responses[mirror] = StudyCatalogFetchResult(status: 200, data: try fixture("modkat-sample.pdf"), etag: "\"e1\"")
        let lib = MemoryLibrary()
        let s = await StudyCatalogPipeline.run(db: b.context.database, env: try env(loader, lib))
        XCTAssertEqual(s["state"]?.string, "ready", "\(s)")
        XCTAssertEqual(s["origin"]?.string, "download")
        XCTAssertEqual(s["catalog_term"]?.string, "WS 2026/27")
        XCTAssertEqual(s["needs_confirmation"], .bool(true))
        XCTAssertEqual(s["modules"]?.int, 6)
        XCTAssertEqual(s["shared"], .bool(true))
        XCTAssertEqual(loader.calls.map(\.0).filter { $0.contains("WS_2026_27") }, [primary, mirror])
        XCTAssertEqual(s["study_plan"]?["state"]?.string, "missing")
        // Bibliothek: nur Fakten
        let shared = try XCTUnwrap(lib.payloads[key]?.first)
        XCTAssertFalse(shared.contains("Variablen, Schleifen"))
        // lokal: Fakten und Texte, Status-Endpunkt
        let text = try await b.context.database.transaction { try StudyCatalogStore.moduleText($0, key: self.key, moduleID: "beispielprogrammierung-1") }
        XCTAssertEqual(text?["content"]?.string, "Variablen, Schleifen und Funktionen\nEinfache Datenstrukturen")
        let st = await status(b)
        XCTAssertEqual(st?["state"]?.string, "ready")
        // zweiter Lauf: lokal, keine Anfrage
        let before = loader.count
        let again = await StudyCatalogPipeline.run(db: b.context.database, env: try env(loader, lib))
        XCTAssertEqual(again["origin"]?.string, "local")
        XCTAssertEqual(loader.count, before)
        // fehlende Adressen werden 30 Tage gemerkt
        let s3 = await StudyCatalogPipeline.run(db: b.context.database, env: try env(loader, lib), force: true)
        XCTAssertEqual(s3["state"]?.string, "ready")
        XCTAssertFalse(loader.calls.suffix(from: before).contains { $0.0 == primary || $0.0 == planURL })
        XCTAssertEqual(loader.calls.last?.1, "\"e1\"", "bedingtes Laden mit ETag")
    }

    /// Fakten des Fixture-Katalogs unter dem Schluessel von TIBSc25 / WS 2026/27 (wie aus der Bibliothek)
    private func libraryPayload() throws -> String {
        let exp = try json("expected.json")
        return try PyJSON.parse(XCTUnwrap(exp["dumps"]?.string)).planSetting("code", .string("TIBSc25"))
            .planSetting("po", .string("2025")).planSetting("catalog_term", .string("WS 2026/27")).dumps(ensureASCII: false)
    }

    func testLibraryAdoptedWithoutDownload() async throws {
        let lib = MemoryLibrary()
        lib.payloads[key] = ["{kaputt", try libraryPayload()]
        let b = try await backend()
        let loader = StubLoader()
        let s = await StudyCatalogPipeline.run(db: b.context.database, env: try env(loader, lib))
        XCTAssertEqual(s["state"]?.string, "library", "\(s)")
        XCTAssertEqual(loader.calls.filter { $0.0.contains("WS_2026_27") }.count, 0, "0 Downloads")
        let stored = try await b.context.database.transaction { try StudyCatalogStore.catalog($0, key: self.key) }
        XCTAssertEqual(stored?["modules"]?.array?.count, 6)
    }

    /// Aeltere Bibliotheksvariante ohne Verlaufsplan: uebernehmen, Plan einmal laden, mischen, als neue Variante teilen;
    /// das naechste Geraet nimmt die Variante mit Plan und laedt nichts
    func testLibraryVariantWithoutPlanGetsPlanAndIsSharedAgain() async throws {
        let lib = MemoryLibrary()
        lib.payloads[key] = [try libraryPayload()]
        let loader = StubLoader()
        loader.responses[planURL] = StudyCatalogFetchResult(status: 200, data: try fixture("plan-sample.pdf"), etag: "\"p1\"")
        let b = try await backend()
        let s = await StudyCatalogPipeline.run(db: b.context.database, env: try env(loader, lib))
        XCTAssertEqual(s["state"]?.string, "library", "\(s)")
        XCTAssertEqual(s["study_plan"]?["state"]?.string, "merged")
        XCTAssertEqual(s["study_plan"]?["unmatched"], ["Einführung in Beispielwerkzeuge"])
        XCTAssertEqual(lib.payloads[key]?.count, 2)
        let shared = try XCTUnwrap(JSONValue.parse(XCTUnwrap(lib.payloads[key]?.last)))
        XCTAssertEqual(shared["study_plan"]?["url"]?.string, planURL)
        XCTAssertEqual(shared["plan_slots"]?.array?.count, 5)
        XCTAssertEqual(StudyCatalogValidator.validate(shared), [])
        let other = try await backend()
        let loader2 = StubLoader()
        let s2 = await StudyCatalogPipeline.run(db: other.context.database, env: try env(loader2, lib))
        XCTAssertEqual(s2["state"]?.string, "library")
        XCTAssertNil(s2["study_plan"])
        XCTAssertEqual(loader2.count, 0, "Variante mit Plan: nichts laden")
    }

    func testDownloadMergesStudyPlanBeforeStoringAndSharing() async throws {
        let b = try await backend()
        let loader = StubLoader()
        loader.responses[mirror] = StudyCatalogFetchResult(status: 200, data: try fixture("modkat-sample.pdf"))
        loader.responses[planURL] = StudyCatalogFetchResult(status: 200, data: try fixture("plan-sample.pdf"))
        let lib = MemoryLibrary()
        let s = await StudyCatalogPipeline.run(db: b.context.database, env: try env(loader, lib))
        XCTAssertEqual(s["study_plan"]?["state"]?.string, "merged", "\(s)")
        XCTAssertEqual(s["study_plan"]?["slots"]?.int, 5)
        let stored = try await b.context.database.transaction { try StudyCatalogStore.catalog($0, key: self.key) }
        let sem = Dictionary(uniqueKeysWithValues: (stored?["modules"]?.array ?? []).map { ($0["id"]!.string!, $0["semester"]?.int) })
        XCTAssertEqual(sem["beispielprogrammierung-2"], 2)
        XCTAssertEqual(sem["bachelorarbeit"], 6)
        XCTAssertTrue(try XCTUnwrap(lib.payloads[key]?.first).contains("plan_slots"), "geteilt mit Plan")
        XCTAssertEqual(loader.calls.filter { $0.0 == self.planURL }.count, 1, "Plan einmal")
    }

    func testErrorsAreStatusAndRetriedAfter24Hours() async throws {
        let b = try await backend()
        let loader = StubLoader()
        loader.responses[primary] = StudyCatalogFetchResult(status: 0, error: "offline")
        loader.responses[mirror] = StudyCatalogFetchResult(status: 503, error: "HTTP 503")
        let t0 = Date(timeIntervalSince1970: 1_793_786_400)
        let s = await StudyCatalogPipeline.run(db: b.context.database, env: try env(loader, nil, now: t0))
        XCTAssertEqual(s["state"]?.string, "error")
        XCTAssertEqual(s["message"]?.string, "Der Modulkatalog ließ sich nicht laden. StudiNow versucht es in 24 Stunden erneut.")
        let n = loader.count
        _ = await StudyCatalogPipeline.run(db: b.context.database, env: try env(loader, nil, now: t0.addingTimeInterval(3600)))
        XCTAssertEqual(loader.count, n, "keine neue Anfrage vor Ablauf von 24 Stunden")
        loader.responses[mirror] = StudyCatalogFetchResult(status: 200, data: try fixture("modkat-sample.pdf"))
        let later = await StudyCatalogPipeline.run(db: b.context.database, env: try env(loader, nil, now: t0.addingTimeInterval(25 * 3600)))
        XCTAssertEqual(later["state"]?.string, "ready")
    }

    func testNoProgramAndUnknownProgram() async throws {
        let none = try await backend(label: nil)
        let s1 = await StudyCatalogPipeline.run(db: none.context.database, env: try env(StubLoader(), nil))
        XCTAssertEqual(s1["state"]?.string, "not_found")
        XCTAssertEqual(s1["reason"]?.string, "no_program")
        let other = try await backend(label: "Musterfach (PO-Version 2017)")
        let s2 = await StudyCatalogPipeline.run(db: other.context.database, env: try env(StubLoader(), nil))
        XCTAssertEqual(s2["message"]?.string, "Für deinen Studiengang gibt es noch keinen Katalog.")
    }

    func testConfirmedPOAndCustomLink() async throws {
        let b = try await backend(label: "Musterfach (PO-Version 2017)")
        let link = "https://example.org/handbuch.pdf"
        try await b.context.database.transaction { c in
            _ = try c.execute("INSERT OR REPLACE INTO settings(key, value) VALUES ('study_plan', ?)", [.text(#"{"po": "TIBSc22", "catalog_url": "\#(link)"}"#)])
        }
        let loader = StubLoader()
        loader.responses[link] = StudyCatalogFetchResult(status: 200, data: Data("kein katalog".utf8))
        let unknown = StudyCatalogPipeline.Environment(loader: loader, library: nil, pdfText: { _ in ["Irgendein Text"] })
        let s = await StudyCatalogPipeline.run(db: b.context.database, env: unknown)
        XCTAssertEqual(s["reason"]?.string, "unknown_format")
        XCTAssertEqual(s["message"]?.string, "Das Format dieses Modulhandbuchs kennt StudiNow noch nicht. Der Link ist gespeichert.")
        // derselbe Link mit Katalog im LUH-Format: gelesen (Kopf aus der Titelseite)
        loader.responses[link] = StudyCatalogFetchResult(status: 200, data: try fixture("modkat-sample.pdf"))
        let ok = await StudyCatalogPipeline.run(db: b.context.database, env: try env(loader, nil), force: true)
        XCTAssertEqual(ok["state"]?.string, "ready", "\(ok)")
        XCTAssertEqual(ok["program"]?.string, "Technische Informatik")
        XCTAssertEqual(ok["catalog_term"]?.string, "WS 2025/26")
        XCTAssertEqual(StudyCatalogPipeline.cleanCatalogURL("http://x.de/a.pdf"), nil)
        XCTAssertEqual(StudyCatalogPipeline.cleanCatalogURL("https://x.de/" + String(repeating: "a", count: 600)), nil)
        XCTAssertEqual(StudyCatalogPipeline.modkatParts(primary)?.term, "WS 2026/27")
        // ohne Link: bestaetigte PO (Kuerzel) reicht auch ohne passenden QIS-Namen
        try await b.context.database.transaction { c in
            _ = try c.execute("UPDATE settings SET value=? WHERE key='study_plan'", [.text(#"{"po": "TIBSc22"}"#)])
        }
        loader.responses[oldMirror] = StudyCatalogFetchResult(status: 200, data: try fixture("modkat-sample.pdf"))
        let po = await StudyCatalogPipeline.run(db: b.context.database, env: try env(loader, nil))
        XCTAssertEqual(po["code"]?.string, "TIBSc22")
        XCTAssertEqual(po["state"]?.string, "ready", "\(po)")
    }
}
