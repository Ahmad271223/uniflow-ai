import Foundation
import XCTest
@testable import UniFlowCore

// Suche und Skriptsuche (S7) gegen die Python-Referenz: search.json (tools/gen-search-fixture.py) mit erfundenen
// Modulen, Kursen, Dateien (PDFs auf der Platte), Analysen, Lernpaketen und festen Seitentexten in page_texts.

private func fixture() throws -> JSONValue {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return try JSONValue.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/local-backend/search.json")))
}

private let clock = UniFlowClock.fixed(berlin: "2026-10-26T09:00:00")!

/// Seitentexte wie PDFKit, hier aus einer festen Tabelle je Datei (Dateiname); zaehlt die Lesevorgaenge
final class TextTools: LocalDocumentTools, @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String: [String]]
    private(set) var reads: [String] = []

    init(_ texts: [String: [String]] = [:]) { self.texts = texts }

    func set(_ name: String, _ pages: [String]?) { lock.withLock { texts[name] = pages } }

    var readCount: Int { lock.withLock { reads.count } }

    func pdfPageCount(_ data: Data) -> Int? { nil }
    func pdfFromImage(_ data: Data) -> Data? { nil }
    func pdfPageTexts(_ url: URL) -> [String]? {
        lock.withLock {
            reads.append(url.lastPathComponent)
            return texts[url.lastPathComponent]
        }
    }
}

final class LocalSearchTests: XCTestCase {

    private func request(_ s: JSONValue) -> LocalRequest {
        let url = URL(string: "uniflow-local://device" + (s["path"]?.string ?? ""))!
        let body = s["body"].map { $0.serialized() }
        return LocalRequest(method: s["method"]?.string ?? "GET", url: url, headers: body == nil ? [:] : ["Content-Type": "application/json"], body: body)
    }

    /// Lokales Backend mit dem Seed und den Dateien des Generators (Pfade relativ zum Container wie local_path)
    private func seeded(_ fx: JSONValue, tools: LocalDocumentTools = NoDocumentTools()) async throws -> LocalBackend {
        let container = try tempContainer(self)
        for f in fx["files"]?.array ?? [] {
            let url = container.appendingPathComponent(f["path"]?.string ?? "")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try XCTUnwrap(Data(base64Encoded: f["base64"]?.string ?? "")).write(to: url)
        }
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock,
                                                  files: LocalFiles(container: container, dataDirectory: "", tools: tools))
        let seed = fx["seed"]?.array ?? []
        try await backend.context.database.transaction { c in
            for s in seed { try c.execute(s["sql"]?.string ?? "", (s["params"]?.array ?? []).map { SQLiteValue(json: $0) ?? .null }) }
        }
        return backend
    }

    /// Dieselben Anfragen wie gegen app/server.py: Status und Antwort exakt gleich (Dateien, Module, Aufgaben und
    /// Seiten der Suche; Skriptsuche mit Mindestguete, Druckfassung, gekuerztem Text, Seite statt Text, ohne Modul;
    /// Seitentext), page_texts danach unveraendert (nichts neu gelesen)
    func testStepsMatchPythonServer() async throws {
        let fx = try fixture()
        let backend = try await seeded(fx)
        let steps = fx["steps"]?.array ?? []
        XCTAssertGreaterThanOrEqual(steps.count, 40)
        var problems: [String] = []
        for (i, s) in steps.enumerated() {
            let label = "\(i) \(s["method"]?.string ?? "") \(s["path"]?.string ?? "") \(s["body"]?.jsonString().prefix(60) ?? "")"
            let r = await backend.handle(request(s))
            if r.status != s["status"]?.int {
                problems.append("\(label): Status \(r.status) statt \(s["status"]?.int ?? 0) – \(String(decoding: r.body.prefix(300), as: UTF8.self))")
                continue
            }
            if let d = jsonDiff(r.json, s["response"]) { problems.append("\(label): \(d)") }
        }
        XCTAssertEqual(problems, [], problems.joined(separator: "\n"))
        let after = try await backend.context.database.rows("SELECT file_id, page, text, chdate FROM page_texts ORDER BY file_id, page")
        XCTAssertNil(jsonDiff(.array(after.map(JSONValue.object)), fx["tables_after"]?["page_texts"]))
        // mit Ergebnissen, nicht nur leer: Skriptsuche, Seiten der Suche, Aufgaben
        XCTAssertGreaterThanOrEqual(steps.filter { !($0["response"]?["results"]?.array ?? []).isEmpty }.count, 5)
        XCTAssertGreaterThanOrEqual(steps.filter { !($0["response"]?["pages"]?.array ?? []).isEmpty }.count, 5)
        XCTAssertGreaterThanOrEqual(steps.filter { !($0["response"]?["tasks"]?.array ?? []).isEmpty }.count, 3)
    }

    /// `tokens`, `normalize` und `_snippet` wie Python (zerlegte Umlaute, Stoppwoerter, Wortstaemme, Zeilenumbrueche,
    /// Kleinschreibung, die die Laenge aendert)
    func testTextFunctionsMatchPython() throws {
        let fx = try fixture()
        for c in fx["tokens"]?.array ?? [] {
            let text = c["text"]?.string ?? ""
            XCTAssertEqual(ScriptSearch.tokens(text), (c["tokens"]?.array ?? []).compactMap(\.string), text)
        }
        for c in fx["normalize"]?.array ?? [] {
            let text = c["text"]?.string ?? ""
            XCTAssertEqual(Array(ScriptSearch.normalize(text).unicodeScalars), Array((c["normalized"]?.string ?? "").unicodeScalars), text)
        }
        let snippets = fx["snippets"]?.array ?? []
        XCTAssertEqual(snippets.count, 6)
        for c in snippets {
            let text = c["text"]?.string ?? ""
            let got = ScriptSearch.snippet(text, terms: (c["terms"]?.array ?? []).compactMap(\.string))
            XCTAssertEqual(Array(got.unicodeScalars), Array((c["snippet"]?.string ?? "").unicodeScalars), String(text.prefix(40)))
        }
    }

    /// Seitentexte wie `page_texts`: einmal mit PDFKit gelesen und mit der Aenderungszeit gespeichert, danach aus
    /// der Tabelle; eine neue Fassung (andere Aenderungszeit) wird neu gelesen; ohne lokale PDF oder unlesbar leer
    func testPageTextsAreReadOnceAndRenewedWithNewVersion() async throws {
        let fx = try fixture()
        let tools = TextTools(["VL01 Eigenwerte.pdf": ["Erste Seite Eigenwerte", "Zweite Seite"]])
        let backend = try await seeded(fx, tools: tools)
        let db = backend.context.database, files = backend.context.files
        try await db.execute("DELETE FROM page_texts WHERE file_id='f-la-v1'")
        let first = try await ScriptSearch.pageTexts(fileID: "f-la-v1", database: db, files: files)
        XCTAssertEqual(first, ["Erste Seite Eigenwerte", "Zweite Seite"])
        let again = try await ScriptSearch.pageTexts(fileID: "f-la-v1", database: db, files: files)
        XCTAssertEqual(again, first)
        XCTAssertEqual(tools.readCount, 1, "zweites Mal aus page_texts")
        let stored = try await db.rows("SELECT page, text, chdate FROM page_texts WHERE file_id='f-la-v1' ORDER BY page")
        XCTAssertEqual(stored.map { $0["chdate"] }, [1760256000, 1760256000])
        // neue Fassung: andere Aenderungszeit -> neu gelesen
        tools.set("VL01 Eigenwerte.pdf", ["Neue Seite eins", "Neue Seite zwei", "Neue Seite drei"])
        try await db.execute("UPDATE files SET chdate=1760300000 WHERE id='f-la-v1'")
        let renewed = try await ScriptSearch.pageTexts(fileID: "f-la-v1", database: db, files: files)
        XCTAssertEqual(renewed.count, 3)
        XCTAssertEqual(tools.readCount, 2)
        // Seitentext ueber den Endpunkt aus der Tabelle
        let r = await backend.handle(LocalRequest(method: "GET", path: "/api/files/f-la-v1/pagetext", query: [.init("page", "3")]))
        XCTAssertEqual(r.json, ["text": "Neue Seite drei", "pages": 3])
        // nicht lesbar: leer, nichts gespeichert, Endpunkt mit Meldung
        try await db.execute("UPDATE files SET chdate=1760400000 WHERE id='f-la-v1'")
        tools.set("VL01 Eigenwerte.pdf", nil)
        let none = try await ScriptSearch.pageTexts(fileID: "f-la-v1", database: db, files: files)
        XCTAssertEqual(none, [])
        let broken = await backend.handle(LocalRequest(method: "GET", path: "/api/files/f-la-v1/pagetext"))
        XCTAssertEqual(broken.json?["text"], "")
        XCTAssertNotNil(broken.json?["error"]?.string)
        // keine PDF (Bild) und ohne lokale Datei: keine Seitentexte
        let png = try await ScriptSearch.pageTexts(fileID: "f-la-png", database: db, files: files)
        XCTAssertEqual(png, [])
        let missing = try await ScriptSearch.pageTexts(fileID: "f-la-v4", database: db, files: files)
        XCTAssertEqual(missing, [])
    }

    /// Suche offline: Text einer eben gelesenen PDF wird gefunden (Seite mit Ausschnitt), eine veraltete Fassung der
    /// Seitentexte nicht
    func testSearchFindsTextOfIndexedPDF() async throws {
        let fx = try fixture()
        let tools = TextTools(["Tafelbild.png": ["nie gelesen"], "Seminar.pdf": ["Organisation", "Referate zur Quantenchromodynamik und mehr"]])
        let backend = try await seeded(fx, tools: tools)
        let db = backend.context.database
        try await db.execute("DELETE FROM page_texts WHERE file_id='f-frei1'")
        let before = await backend.handle(LocalRequest(method: "GET", path: "/api/search", query: [.init("q", "quantenchromo")]))
        XCTAssertEqual(before.json?["pages"], [])
        _ = try await ScriptSearch.pageTexts(fileID: "f-frei1", database: db, files: backend.context.files)
        let after = await backend.handle(LocalRequest(method: "GET", path: "/api/search", query: [.init("q", "Quantenchromo")]))
        let pages = after.json?["pages"]?.array ?? []
        XCTAssertEqual(pages.map { $0["file_id"] }, ["f-frei1"])
        XCTAssertEqual(pages.first?["page"], 2)
        XCTAssertEqual(pages.first?["snippet"], "Referate zur Quantenchromodynamik und mehr")
        XCTAssertEqual(pages.first?["module_id"], .null)
        // Datei neuer als die Seitentexte: nicht mehr gefunden, bis sie neu gelesen sind
        try await db.execute("UPDATE files SET chdate=chdate+1 WHERE id='f-frei1'")
        let stale = await backend.handle(LocalRequest(method: "GET", path: "/api/search", query: [.init("q", "quantenchromo")]))
        XCTAssertEqual(stale.json?["pages"], [])
    }

    /// Skriptsuche liest die Skripte eines Moduls bei der ersten Anfrage (nicht vorher gelesene Seitentexte) und
    /// danach aus dem Zwischenspeicher
    func testRelatedReadsScriptsOnceThenUsesIndex() async throws {
        let fx = try fixture()
        let skript = try XCTUnwrap(fx["seed"]?.array?.compactMap { s -> String? in
            guard s["sql"]?.string?.contains("page_texts") == true, let p = s["params"]?.array, p.first == "f-la-s" else { return nil }
            return p[2].string
        })
        let tools = TextTools(["Skript Lineare Algebra.pdf": skript])
        let backend = try await seeded(fx, tools: tools)
        try await backend.context.database.execute("DELETE FROM page_texts WHERE file_id='f-la-s'")
        let body: JSONValue = ["file_id": "f-la-u1", "text": "Spektralsatz symmetrische Matrizen reelle Eigenwerte orthogonale Diagonalisierung"]
        let expected = try XCTUnwrap(fx["steps"]?.array?.first { $0["body"] == body }?["response"])
        for _ in 0..<2 {
            let r = await backend.handle(LocalRequest(method: "POST", path: "/api/related", headers: ["Content-Type": "application/json"], body: body.serialized()))
            XCTAssertNil(jsonDiff(r.json, expected), jsonDiff(r.json, expected) ?? "")
        }
        XCTAssertEqual(tools.readCount, 1)
    }
}
