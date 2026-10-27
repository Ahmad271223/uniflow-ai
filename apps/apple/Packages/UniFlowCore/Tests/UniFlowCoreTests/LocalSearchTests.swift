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
        // mit der Suchform, die die Suche fuer Zeilen ohne sie nachgetragen hat (gleich wie search_form in Python)
        let after = try await backend.context.database.rows("SELECT file_id, page, text, chdate, search FROM page_texts ORDER BY file_id, page")
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
        // Suchform der Seitensuche: normalize, klein (auch "Ü", "İ", "ẞ", Schluss-Sigma), NFC
        let forms = fx["search_forms"]?.array ?? []
        XCTAssertGreaterThanOrEqual(forms.count, 15)
        for c in forms {
            let text = c["text"]?.string ?? ""
            XCTAssertEqual(Array(ScriptSearch.searchForm(text).unicodeScalars), Array((c["search"]?.string ?? "").unicodeScalars), text)
        }
    }

    /// `sum()` wie CPython ab 3.12 (Neumaier): die Schwelle der Skriptsuche (`mean * 1.6`) ist damit bitgleich; einfache
    /// Addition wich in den letzten Stellen ab (Werte aus Python 3.13 nachgerechnet)
    func testPythonSumIsCompensated() {
        XCTAssertEqual(PyMath.sum(Array(repeating: 0.1, count: 10)), 1.0)
        XCTAssertEqual(PyMath.sum([1e16, 1.0, -1e16]), 1.0)
        XCTAssertEqual(PyMath.sum([1e308, 1e308, -1e308]), .infinity)
        XCTAssertEqual(PyMath.sum([]), 0)
        let xs = [10.533658707664273, 8.111888434943026, 15.113082622557952, 7.014108013345599, 13.502348060293649,
                  11.119644836776198, 6.811984946845895, 13.104100264651883, 6.5249392181877885, 12.071039571273403,
                  6.977975930044665, 7.269982186814111, 11.943268647995195, 17.575929745408533, 7.7332274560950385,
                  9.125345504498203, 14.78406511367825, 19.26792519439808, 14.079441280644982, 11.553526645110923,
                  19.66757147830088, 6.652157528648588, 18.018558426681516, 10.054530008643468, 8.019571167004125,
                  7.649091333097157, 10.31874553742708, 17.42576902768044, 8.530169318935124, 14.142402291274527]
        XCTAssertEqual(PyMath.sum(xs), 344.69604849892056)
        XCTAssertEqual(xs.reduce(0, +), 344.6960484989206, "einfache Addition: anders in der letzten Stelle")
    }

    /// Codepunkte wie Python: `s[a:b]` und `s.find(t)` (die eine Fassung fuer Skriptsuche und Stundenplan-Import)
    func testCodepointSliceAndFind() {
        let s = "Unabha\u{308}ngig ü"
        XCTAssertEqual(PyText.slice(s, 0, 6), "Unabha")
        XCTAssertEqual(Array(PyText.slice(s, 6, 7).unicodeScalars), ["\u{308}"])
        XCTAssertEqual(PyText.slice(s, 5, 100), "a\u{308}ngig ü")
        XCTAssertEqual(PyText.slice(s, 9, 3), "")
        XCTAssertEqual(PyText.slice("20261026T0930", 0, 8), "20261026")
        XCTAssertEqual(PyText.find(Array(s.unicodeScalars), Array("ngig".unicodeScalars)), 7)
        XCTAssertNil(PyText.find(Array(s.unicodeScalars), Array("ä".unicodeScalars)), "zerlegt ist nicht gleich")
        XCTAssertEqual(PyText.find(Array("abc".unicodeScalars), []), 0)
        XCTAssertTrue(PyText.contains(s, "ig ü"))
        XCTAssertFalse(PyText.contains("ab", "abc"))
    }

    /// Aeltere Datenbank: page_texts ohne Suchform bekommt die Spalte (wie ensure_table in Python), ihre Zeilen die
    /// Suchform bei der ersten Suche
    func testMigrationAddsSearchFormToOldPageTexts() async throws {
        let db = try SQLiteDatabase(path: SQLiteDatabase.inMemory)
        try await db.execute("CREATE TABLE page_texts (file_id TEXT NOT NULL, page INTEGER NOT NULL, text TEXT, chdate INTEGER, PRIMARY KEY (file_id, page))")
        try await db.execute("INSERT INTO page_texts(file_id, page, text, chdate) VALUES ('alt', 1, 'Übung', 0)")
        try await db.migrate(clock: clock)
        try await db.migrate(clock: clock)
        let cols = try await db.withConnection { try $0.columnNames("page_texts") }
        XCTAssertTrue(cols.contains("search"))
        let rows = try await db.rows("SELECT text, search FROM page_texts")
        XCTAssertEqual(rows.first?["search"], .null)
        _ = try await db.transaction { try ScriptSearch.findPages($0, "übung") }
        let filled = try await db.rows("SELECT search FROM page_texts")
        XCTAssertEqual(filled.first?["search"], "übung")
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
        // nicht lesbar: leer, nichts gespeichert, Endpunkt 404 ohne Seitentext (wie page_text seit b718cfb)
        try await db.execute("UPDATE files SET chdate=1760400000 WHERE id='f-la-v1'")
        tools.set("VL01 Eigenwerte.pdf", nil)
        let none = try await ScriptSearch.pageTexts(fileID: "f-la-v1", database: db, files: files)
        XCTAssertEqual(none, [])
        let broken = await backend.handle(LocalRequest(method: "GET", path: "/api/files/f-la-v1/pagetext"))
        XCTAssertEqual(broken.status, 404)
        XCTAssertEqual(broken.json, ["detail": "Kein Seitentext vorhanden.", "code": "no_content"])
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

    /// Gespeicherte Seitentexte einer Datei, die nicht mehr auf dem Geraet liegt (nach "Dateien loeschen"), gelten wie
    /// am PC (`page_texts` seit b718cfb): `/pagetext` liefert sie, die Skriptsuche zaehlt sie mit (Punktzahlen der
    /// Fixture); die globale Suche zeigt die Seite nicht (`find_pages` verlangt die Datei). Ohne Texte 404 no_content.
    func testStoredTextsOfDeletedFileStillCount() async throws {
        let fx = try fixture()
        let tools = TextTools()
        let backend = try await seeded(fx, tools: tools)
        let r = await backend.handle(LocalRequest(method: "GET", path: "/api/files/f-la-weg/pagetext"))
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.json?["pages"], 1)
        XCTAssertEqual(r.json?["text"]?.string?.hasPrefix("Spektralzerlegung"), true)
        let search = await backend.handle(LocalRequest(method: "GET", path: "/api/search", query: [.init("q", "spektralzerlegung")]))
        XCTAssertEqual(search.json?["pages"], [])
        XCTAssertEqual(tools.readCount, 0)
        try await backend.context.database.execute("DELETE FROM page_texts WHERE file_id='f-la-weg'")
        let gone = await backend.handle(LocalRequest(method: "GET", path: "/api/files/f-la-weg/pagetext"))
        XCTAssertEqual(gone.status, 404)
        XCTAssertEqual(gone.json, ["detail": "Kein Seitentext vorhanden.", "code": "no_content"])
        let unknown = await backend.handle(LocalRequest(method: "GET", path: "/api/files/gibtsnicht/pagetext"))
        XCTAssertEqual(unknown.status, 404)
        XCTAssertEqual(unknown.json, ["detail": "Datei nicht gefunden"])
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

    /// Seitentexte wie PDFKit, aber langsam (grosse Skripte): zaehlt die Lesevorgaenge
    final class SlowTools: LocalDocumentTools, @unchecked Sendable {
        private let lock = NSLock()
        private let texts: [String: [String]]
        private var log: [String] = []
        init(_ texts: [String: [String]]) { self.texts = texts }
        var reads: [String] { lock.withLock { log } }
        func pdfPageCount(_ data: Data) -> Int? { nil }
        func pdfFromImage(_ data: Data) -> Data? { nil }
        func pdfPageTexts(_ url: URL) -> [String]? {
            Thread.sleep(forTimeInterval: 0.15)
            return lock.withLock {
                log.append(url.lastPathComponent)
                return texts[url.lastPathComponent]
            }
        }
    }

    private func related(_ backend: LocalBackend, _ body: JSONValue) async -> LocalResponse {
        await backend.handle(LocalRequest(method: "POST", path: "/api/related", headers: ["Content-Type": "application/json"], body: body.serialized()))
    }

    /// Zwei Anfragen zugleich bauen den Index eines Moduls nur einmal (die zweite wartet auf den laufenden Aufbau, jede
    /// PDF wird einmal gelesen); bricht die einzige wartende Anfrage ab, endet der Aufbau zwischen zwei Dateien, und die
    /// naechste Anfrage baut neu
    func testIndexBuildIsSharedAndStopsWhenNobodyWaits() async throws {
        let fx = try fixture()
        let texts = (fx["seed"]?.array ?? []).reduce(into: [String: [String]]()) { out, s in
            guard s["sql"]?.string?.contains("page_texts") == true, let p = s["params"]?.array, let id = p.first?.string else { return }
            out[id, default: []].append(p[2].string ?? "")
        }
        let names = ["f-la-v1": "VL01 Eigenwerte.pdf", "f-la-v2": "VL02 Determinanten.pdf", "f-la-v2d": "VL02 Determinanten Druckfassung.pdf",
                     "f-la-s": "Skript Lineare Algebra.pdf", "f-la-e": "Ergänzungen zur Vorlesung.pdf"]
        let tools = SlowTools(Dictionary(uniqueKeysWithValues: names.map { ($0.value, texts[$0.key] ?? []) }))
        let backend = try await seeded(fx, tools: tools)
        // nur die Texte der Dateien auf dem Geraet: die gespeicherten Texte von f-la-weg (Datei geloescht) zaehlen im
        // Index mit wie am PC und liessen sich nicht neu lesen
        let readable = "DELETE FROM page_texts WHERE file_id IN (" + names.keys.sorted().map { "'\($0)'" }.joined(separator: ",") + ")"
        try await backend.context.database.execute(readable)
        let body: JSONValue = ["file_id": "f-la-u1", "text": "Spektralsatz symmetrische Matrizen reelle Eigenwerte orthogonale Diagonalisierung"]
        let expected = try XCTUnwrap(fx["steps"]?.array?.first { $0["body"] == body }?["response"])

        // abgebrochen, waehrend die erste PDF gelesen wird: der Aufbau endet, ohne alle Skripte zu lesen
        let cancelled = Task { await self.related(backend, body) }
        try await Task.sleep(nanoseconds: 50_000_000)
        cancelled.cancel()
        _ = await cancelled.value
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertLessThan(tools.reads.count, names.count, "\(tools.reads)")
        let afterCancel = tools.reads.count

        // zwei Anfragen zugleich: ein Aufbau, jede noch fehlende PDF einmal gelesen
        try await backend.context.database.execute(readable)
        let builds = backend.context.scriptIndex.builds
        async let a = related(backend, body)
        async let b = related(backend, body)
        let (ra, rb) = await (a, b)
        XCTAssertNil(jsonDiff(ra.json, expected), jsonDiff(ra.json, expected) ?? "")
        XCTAssertNil(jsonDiff(rb.json, expected), jsonDiff(rb.json, expected) ?? "")
        XCTAssertEqual(backend.context.scriptIndex.builds, builds + 1)
        XCTAssertEqual(tools.reads.count - afterCancel, names.count, "\(tools.reads)")
    }
}
