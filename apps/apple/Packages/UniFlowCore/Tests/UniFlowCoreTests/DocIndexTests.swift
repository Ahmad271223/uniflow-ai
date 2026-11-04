import Foundation
import XCTest
@testable import UniFlowCore
#if canImport(CoreGraphics) && canImport(ImageIO) && canImport(CoreText)
import CoreGraphics
import CoreText
import ImageIO
#endif

// Gemeinsamer Dokument-Index ("Bibliothek", docs/DOKUMENT-INDEX-2026-11-04.md): Schema byte-gleich mit dem Vertrag,
// Erwartungswerte aus Python (Fingerabdruecke, Prompt), Pruefer, Verschluesselung (Rundlauf, fremde Datei kann nicht
// lesen), Erkennung von Bildseiten, Aufbau mit Fake-KI und Fake-Dienst (Datensaetze entstehen, der zweite Nutzer
// uebernimmt ohne KI, "bereits bekannt"), Wiederholungen, Vorwaermen mit Deckel 3 und Wiederaufnahme, Regal,
// Querverweise und eigene Notizen. Kein Netz, keine echte KI.

private func contractsDir() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return url.appendingPathComponent("packages/shared-contracts")
}

/// Dienst im Speicher: ein Datensatz je Name, `fileKey` abfragbar
final class FakeDocIndexCloud: DocIndexCloud, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: DocIndexRecord] = [:]
    var failure: Error?
    private(set) var saves = 0

    var all: [DocIndexRecord] { lock.withLock { store.values.sorted { ($0.fileKey, $0.page) < ($1.fileKey, $1.page) } } }

    func records(fileKey: String) async throws -> [DocIndexRecord] {
        if let failure { throw failure }
        return lock.withLock { store.values.filter { $0.fileKey == fileKey }.sorted { $0.page < $1.page } }
    }

    func record(fileKey: String, page: Int) async throws -> DocIndexRecord? {
        if let failure { throw failure }
        return lock.withLock { store[DocIndexFingerprint.recordName(fileKey: fileKey, page: page)] }
    }

    func save(_ record: DocIndexRecord) async throws {
        if let failure { throw failure }
        lock.withLock { store[record.recordName] = record; saves += 1 }
    }
}

/// KI mit festen Antworten: gueltiger Eintrag je Seite (Seite aus dem Prompt), oder Unsinn
final class FakeDocIndexAI: DocIndexAI, @unchecked Sendable {
    struct Call: Equatable { let page: Int; let image: Bool; let small: Bool }
    private let lock = NSLock()
    private(set) var calls: [Call] = []
    var garbage = false
    var failure: AIError?
    /// Titel des ersten Elements je Seite (fuer Querverweise)
    var titles: [Int: String] = [:]

    static let pageRegex = try! NSRegularExpression(pattern: "Seite (\\d+) von")

    func index(system: String, prompt: String, imageJPEG: Data?, schema: JSONValue, small: Bool) async throws -> String {
        let page = Self.pageRegex.firstMatch(in: prompt, range: NSRange(prompt.startIndex..., in: prompt))
            .flatMap { Range($0.range(at: 1), in: prompt) }.flatMap { Int(prompt[$0]) } ?? 0
        try lock.withLock {
            calls.append(Call(page: page, image: imageJPEG != nil, small: small))
            if let failure { throw failure }
        }
        if garbage { return "```json\n{\"kaputt\": true}\n```" }
        let title = titles[page] ?? "Eigenwert einer Matrix"
        return """
        ```json
        {"summary": "Seite \(page): Eigenwerte und das charakteristische Polynom.", "terms": ["Eigenwert", " eigenwert", "Polynom"],
         "elements": [
           {"order": 2, "type": "formel", "title": "charakteristisches Polynom", "explanation": "det(A - λI) = 0.", "position": "mitte", "task": null, "uncertain": true},
           {"order": 1, "type": "definition", "title": "\(title)", "explanation": "λ mit A v = λ v.", "position": "oben", "task": "Aufgabe 1", "uncertain": false}],
         "tasks": [{"label": "Aufgabe 1", "asks": "Eigenwerte bestimmen.", "solution": null}]}
        ```
        """
    }

    var modelName: String { get async { "fake-modell" } }
}

final class DocIndexTests: XCTestCase {
    private let clock = UniFlowClock.fixed(berlin: "2026-10-28T09:00:00")!
    private let cipher = TestHMACCipher()

    // MARK: Vertrag

    func testSchemaMatchesContractByteForByte() throws {
        let file = try String(contentsOf: contractsDir().appendingPathComponent("doc-index.schema.json"), encoding: .utf8)
        XCTAssertEqual(DocIndexSchema.json, file, "DocIndexSchema.json aus der Vertragsdatei uebernehmen")
        XCTAssertEqual(DocIndexSchema.schema["version"]?.int, DocIndexSchema.version)
        XCTAssertEqual(DocIndexSchema.version, 1)
        XCTAssertNotNil(DocIndexSchema.summarySchema.object)
        XCTAssertNotNil(DocIndexSchema.catalogSchema.object)
        XCTAssertNil(DocIndexSchema.aiSchema["$defs"])
        XCTAssertNotNil(DocIndexSchema.aiSchema["properties"])
    }

    func testFixtureCasesMatchPython() throws {
        let cases = try JSONValue.parse(Data(contentsOf: contractsDir().appendingPathComponent("fixtures/doc-index/cases.json")))
        XCTAssertEqual(cases["schema_version"]?.int, DocIndexSchema.version)
        for c in cases["file_key"]?.array ?? [] {
            XCTAssertEqual(DocIndexFingerprint.fileKey(fileSHA: c["sha"]?.string ?? ""), c["key"]?.string, c["sha"]?.string ?? "")
        }
        for c in cases["page_hash"]?.array ?? [] {
            let text = c["text"]?.string ?? ""
            XCTAssertEqual(DocIndexFingerprint.normalize(text), c["normalized"]?.string, text)
            XCTAssertEqual(DocIndexFingerprint.letters(text), c["letters"]?.int, text)
            XCTAssertEqual(DocIndexFingerprint.pageHash(text: text, fileSHA: c["sha"]?.string ?? "", page: c["page"]?.int ?? 0), c["hash"]?.string, text)
        }
        for c in cases["record_name"]?.array ?? [] {
            XCTAssertEqual(DocIndexFingerprint.recordName(fileKey: c["key"]?.string ?? "", page: c["page"]?.int ?? -1), c["name"]?.string)
            XCTAssertEqual(DocIndexFingerprint.parse(recordName: c["name"]?.string ?? "")?.page, c["page"]?.int)
        }
        for c in cases["catalog_kind"]?.array ?? [] {
            let k = DocIndexCatalog.kind(docType: c["doc_type"]?.string, subLabel: c["sub_label"]?.string)
            XCTAssertEqual(k.kind, c["kind"]?.string, "\(c)")
            XCTAssertEqual(k.label, c["label"]?.string, "\(c)")
        }
        XCTAssertEqual(DocIndexCatalog.kindOrder, cases["kind_order"]?.array?.compactMap(\.string))
        XCTAssertEqual(DocIndexPrompts.system, cases["system"]?.string)
        for c in cases["prompt"]?.array ?? [] {
            let i = c["in"] ?? .null
            let p = DocIndexPrompts.page(course: i["course"]?.string ?? "", fileName: i["file_name"]?.string ?? "", page: i["page"]?.int ?? 0,
                                         pageCount: i["page_count"]?.int ?? 0, text: i["text"]?.string ?? "", withImage: i["with_image"]?.bool ?? false,
                                         withSolutions: i["with_solutions"]?.bool ?? false)
            XCTAssertTrue(p.unicodeScalars.elementsEqual((c["out"]?.string ?? "").unicodeScalars), "Prompt \(i["file_name"]?.string ?? "")")
        }
        XCTAssertNil(DocIndexFingerprint.fileKey(fileSHA: "abc"))
        XCTAssertEqual(DocIndexFingerprint.fileKey(fileSHA: String(repeating: "A", count: 64)), DocIndexFingerprint.fileKey(fileSHA: String(repeating: "a", count: 64)))
    }

    // MARK: Pruefer

    private func goodEntry() -> JSONValue {
        ["summary": "Eigenwerte.", "terms": ["Eigenwert"],
         "elements": [["order": 1, "type": "definition", "title": "Eigenwert", "explanation": "λ mit A v = λ v.", "position": "oben", "task": .null, "uncertain": false],
                      ["order": 2, "type": "formel", "title": "charakteristisches Polynom", "explanation": "det(A − λI) = 0.", "position": "mitte", "task": .null, "uncertain": true]],
         "tasks": [["label": "Aufgabe 1", "asks": "Eigenwerte bestimmen.", "solution": .null]]]
    }

    func testValidatorListsErrorsLikePython() {
        XCTAssertEqual(DocIndexEntry.check(goodEntry()), [])
        var bad = goodEntry()
        bad["summary"] = .string(String(repeating: "x", count: 501))
        bad["terms"] = .array(Array(repeating: .string("a"), count: 13))
        bad["extra"] = .number(1)
        var elements = bad["elements"]!.array!
        elements[0]["type"] = "bild"
        var second = elements[1].object!
        second.removeValue(forKey: "position")
        elements[1] = .object(second)
        bad["elements"] = .array(elements)
        let errors = JSONSchemaLite.validate(bad, schema: DocIndexSchema.schema)
        XCTAssertTrue(errors.contains("$.summary: 501 Zeichen, hoechstens 500"), "\(errors)")
        XCTAssertTrue(errors.contains("$.terms: 13 Eintraege, hoechstens 12"), "\(errors)")
        XCTAssertTrue(errors.contains("$.extra: unbekanntes Feld"), "\(errors)")
        XCTAssertTrue(errors.contains("$.elements[0].type: 'bild' nicht erlaubt"), "\(errors)")
        XCTAssertTrue(errors.contains("$.elements[1].position: fehlt"), "\(errors)")
        XCTAssertEqual(JSONSchemaLite.validate(.string("kein Objekt"), schema: DocIndexSchema.schema), ["$: Typ str, erwartet object"])
        let summary: JSONValue = ["v": 2, "fileName": "a", "pageCount": -1, "pageHashes": [], "catalog": [:], "createdAt": ""]
        XCTAssertEqual(Array(JSONSchemaLite.validate(summary, schema: DocIndexSchema.summarySchema).prefix(2)), ["$.v: 2 statt 1", "$.pageCount: -1 unter 0"])
        // Ordnung: order 1..n lueckenlos, Aufgaben eindeutig
        var gap = goodEntry()
        var g = gap["elements"]!.array!
        g[1]["order"] = 3
        gap["elements"] = .array(g)
        XCTAssertEqual(DocIndexEntry.check(gap), ["$.elements: order muss 1..n ohne Luecken sein"])
        var dup = goodEntry()
        dup["tasks"] = [["label": "A", "asks": "x"], ["label": "A", "asks": "y"]]
        XCTAssertEqual(DocIndexEntry.check(dup), ["$.tasks: Aufgaben doppelt"])
    }

    func testEntryParsingIsDeterministic() throws {
        let answer = "```json\n" + goodEntry().jsonString() + "\n```"
        let e = try DocIndexEntry.parse(answer: answer)
        XCTAssertEqual(e.elements.map(\.order), [1, 2])
        XCTAssertEqual(e.elements[1].typeLabel, "Formel")
        XCTAssertEqual(e.tasks.first?.label, "Aufgabe 1")
        var shuffled = goodEntry()
        shuffled["elements"] = .array(shuffled["elements"]!.array!.reversed())
        shuffled["terms"] = [" Eigenwert ", "eigenwert", "Polynom"]
        let f = try XCTUnwrap(DocIndexEntry(validating: shuffled))
        XCTAssertEqual(f.elements.map(\.order), [1, 2])
        XCTAssertEqual(f.terms, ["Eigenwert", "Polynom"])
        XCTAssertEqual(f.json["elements"]?.array?.first?["title"]?.string, "Eigenwert")
        XCTAssertThrowsError(try DocIndexEntry.parse(answer: "{\"kaputt\": true}")) { e in
            XCTAssertEqual((e as? AIError)?.code, "ai_invalid_index")
        }
        XCTAssertThrowsError(try DocIndexEntry.parse(answer: "kein json")) { e in XCTAssertEqual((e as? AIError)?.code, "ai_invalid_json") }
        // Datensatz der Seite und Zusammenfassung: Rundlauf ueber JSON
        let rec = DocIndexPageRecord(page: 3, pageHash: String(repeating: "b", count: 64), entry: e, withImage: true, model: "m", createdAt: "2026-10-28T09:00:00")
        XCTAssertEqual(DocIndexPageRecord(json: rec.json), rec)
        let catalog = DocIndexCatalog(university: "luh", semester: "WiSe 2026/27", moduleKey: "k", moduleName: "Analysis I", week: 3, date: "2026-10-26",
                                      kind: "vorlesung", kindLabel: "Vorlesung")
        let sum = DocIndexFileSummary(fileName: "vl03.pdf", title: "Eigenwerte", pageCount: 2, pageHashes: ["a", "b"], overview: "o", catalog: catalog, createdAt: "t")
        XCTAssertEqual(DocIndexFileSummary(json: sum.json), sum)
        XCTAssertNil(DocIndexFileSummary(json: ["v": 1]))
    }

    // MARK: Verschluesselung

    func testCryptoRoundTripAndWrongFileCannotDecrypt() throws {
        let sha = String(repeating: "a", count: 64), other = String(repeating: "b", count: 64)
        let key = DocIndexFingerprint.fileKey(fileSHA: sha)!, otherKey = DocIndexFingerprint.fileKey(fileSHA: other)!
        let hash = DocIndexFingerprint.pageHash(text: "Eigenwerte einer Matrix und das charakteristische Polynom", fileSHA: sha, page: 2)
        let content = goodEntry()
        let payload = try DocIndexCrypto.seal(content, fileSHA: sha, pageHash: hash, fileKey: key, page: 2, cipher: cipher)
        XCTAssertEqual(try DocIndexCrypto.open(payload, fileSHA: sha, pageHash: hash, fileKey: key, page: 2, cipher: cipher), content)
        // zweites Versiegeln: anderes Salz, anderes Chiffrat, gleicher Inhalt
        let again = try DocIndexCrypto.seal(content, fileSHA: sha, pageHash: hash, fileKey: key, page: 2, cipher: cipher)
        XCTAssertNotEqual(again, payload)
        XCTAssertEqual(try DocIndexCrypto.open(again, fileSHA: sha, pageHash: hash, fileKey: key, page: 2, cipher: cipher), content)
        // andere Datei (anderer SHA), andere Seite, anderer Seiten-Abdruck, anderer Datensatzname, veraendertes Chiffrat: nichts lesbar
        XCTAssertThrowsError(try DocIndexCrypto.open(payload, fileSHA: other, pageHash: hash, fileKey: otherKey, page: 2, cipher: cipher))
        XCTAssertThrowsError(try DocIndexCrypto.open(payload, fileSHA: sha, pageHash: hash, fileKey: key, page: 3, cipher: cipher))
        XCTAssertThrowsError(try DocIndexCrypto.open(payload, fileSHA: sha, pageHash: String(repeating: "c", count: 64), fileKey: key, page: 2, cipher: cipher))
        XCTAssertThrowsError(try DocIndexCrypto.open(payload, fileSHA: sha, pageHash: hash, fileKey: otherKey, page: 2, cipher: cipher))
        var raw = Data(base64Encoded: payload)!
        raw[raw.count - 5] ^= 0x01
        XCTAssertThrowsError(try DocIndexCrypto.open(raw.base64EncodedString(), fileSHA: sha, pageHash: hash, fileKey: key, page: 2, cipher: cipher))
        XCTAssertThrowsError(try DocIndexCrypto.open("kein base64!", fileSHA: sha, pageHash: hash, fileKey: key, page: 2, cipher: cipher))
        XCTAssertNotEqual(DocIndexCrypto.summaryHash(pageHashes: ["a", "b"]), DocIndexCrypto.summaryHash(pageHashes: ["b", "a"]))
    }

    // MARK: Bildseiten

    func testPageRuleDecidesFromMeasurements() {
        typealias P = DocIndexPageRule.Probe
        XCTAssertEqual(P(letters: 900, images: 0, pathOps: 3, mathSymbols: 1).kind, .text)
        XCTAssertEqual(P(letters: 900, images: 1, pathOps: 0, mathSymbols: 0).kind, .figure, "eingebettetes Bild")
        XCTAssertEqual(P(letters: 5, images: 0, pathOps: 0, mathSymbols: 0).kind, .figure, "Scan ohne Textebene")
        XCTAssertEqual(P(letters: 900, images: 0, pathOps: 40, mathSymbols: 0).kind, .figure, "Diagramm oder Tabelle")
        XCTAssertEqual(P(letters: 900, images: 0, pathOps: 39, mathSymbols: 5).kind, .text)
        XCTAssertEqual(P(letters: 900, images: 0, pathOps: 0, mathSymbols: 6).kind, .figure, "Formelseite")
        XCTAssertEqual(DocIndexPageRule.mathSymbols(in: "P(A ∩ B) = P(A) · P(B), ∑ x_i = ∫ f"), 6)
    }

    #if canImport(CoreGraphics) && canImport(ImageIO) && canImport(CoreText)
    /// PDF mit drei Seiten: Text (CoreText), eingebettetes Bild, Vektorgrafik (60 Rechtecke)
    static func fixturePDF(to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let pdf = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        pdf.beginPDFPage(nil)
        for i in 0..<20 {
            let attr = NSAttributedString(string: "Eigenwerte einer Matrix, Zeile \(i): das charakteristische Polynom liefert die Eigenwerte.",
                                          attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
            pdf.textPosition = CGPoint(x: 40, y: CGFloat(800 - i * 30))
            CTLineDraw(CTLineCreateWithAttributedString(attr), pdf)
        }
        pdf.endPDFPage()
        let w = 200, h = 120
        let bmp = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        bmp.setFillColor(gray: 0.3, alpha: 1)
        bmp.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let image = try XCTUnwrap(bmp.makeImage())
        pdf.beginPDFPage(nil)
        pdf.draw(image, in: CGRect(x: 100, y: 300, width: 400, height: 240))
        pdf.endPDFPage()
        pdf.beginPDFPage(nil)
        pdf.setStrokeColor(gray: 0, alpha: 1)
        for i in 0..<60 {
            pdf.stroke(CGRect(x: 40 + CGFloat(i % 10) * 50, y: 300 + CGFloat(i / 10) * 60, width: 40, height: 40))
        }
        pdf.endPDFPage()
        pdf.closePDF()
    }

    func testFigurePageDetectionAndRenderingOnFixturePDF() throws {
        let dir = try tempContainer(self)
        let url = dir.appendingPathComponent("fixture.pdf")
        try Self.fixturePDF(to: url)
        XCTAssertEqual(DocIndexPages.pageCount(pdf: url), 3)
        let textPage = String(repeating: "Eigenwerte einer Matrix, das charakteristische Polynom liefert die Eigenwerte. ", count: 20)
        let p1 = try XCTUnwrap(DocIndexPages.probe(pdf: url, page: 1, text: textPage))
        XCTAssertEqual(p1.kind, .text, "\(p1)")
        XCTAssertEqual(p1.images, 0)
        XCTAssertLessThan(p1.pathOps, DocIndexPageRule.minPathOps)
        let p2 = try XCTUnwrap(DocIndexPages.probe(pdf: url, page: 2, text: textPage))
        XCTAssertEqual(p2.kind, .figure, "\(p2)")
        XCTAssertGreaterThanOrEqual(p2.images, 1)
        let p3 = try XCTUnwrap(DocIndexPages.probe(pdf: url, page: 3, text: textPage))
        XCTAssertEqual(p3.kind, .figure, "\(p3)")
        XCTAssertGreaterThanOrEqual(p3.pathOps, 60)
        XCTAssertEqual(DocIndexPages.probe(pdf: url, page: 2, text: "")?.kind, .figure)
        XCTAssertNil(DocIndexPages.probe(pdf: url, page: 4, text: ""))
        let jpeg = try XCTUnwrap(DocIndexPages.renderJPEG(pdf: url, page: 2))
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8], "JPEG")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        XCTAssertEqual(props?[kCGImagePropertyPixelWidth] as? Int, DocIndexPages.imageWidth)
        XCTAssertNil(DocIndexPages.renderJPEG(pdf: url, page: 9))
    }
    #endif

    // MARK: Aufbau

    struct Seed {
        var id: String
        var name: String
        var course: String
        var pages: [String]
        var chdate: String = "2026-10-26T10:00:00"
        var folder: String = ""
    }

    /// Backend im Speicher mit Kursen eines Moduls und Dateien auf der Platte (Inhalt je Datei verschieden); Seitentexte
    /// liefert `TextTools` nach Dateiname
    private func seeded(_ seeds: [Seed], courses: [(id: String, title: String, module: String)] = [("c-ana", "Analysis I", "Analysis I")],
                        container: URL? = nil) async throws -> (LocalBackend, TextTools, URL) {
        let dir = try container ?? tempContainer(self)
        let tools = TextTools(Dictionary(uniqueKeysWithValues: seeds.map { ($0.name, $0.pages) }))
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock,
                                                  files: LocalFiles(container: dir, dataDirectory: "", tools: tools))
        try await backend.context.database.transaction { c in
            var modules: [String: Int64] = [:]
            for co in courses {
                if modules[co.module] == nil {
                    try c.execute("INSERT INTO modules(name, semester, color, sort, created_at) VALUES (?, 'WiSe 2026/27', '#123456', 0, ?)", [.text(co.module), .text(self.clock.nowISO)])
                    modules[co.module] = c.lastInsertRowID
                }
                try c.execute("INSERT INTO courses(id, title, kind, active, module_id, semester, created_at) VALUES (?, ?, 'vorlesung', 1, ?, 'WiSe 2026/27', ?)",
                              [.text(co.id), .text(co.title), .integer(modules[co.module]!), .text(self.clock.nowISO)])
            }
            for s in seeds {
                let path = "StudIP/\(s.name)"
                let url = dir.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: url.path) { try Data("%PDF-1.4 fake \(s.id) \(s.name)".utf8).write(to: url) }
                let sha = ContentHash.file(url)!
                try c.execute("""
                    INSERT INTO files(id, course_id, name, mime, chdate, local_path, downloaded_at, kind, status, content_sha256, studip_folder, download_url, page_count)
                    VALUES (?, ?, ?, 'application/pdf', ?, ?, ?, 'pdf', 'neu', ?, ?, 'https://studip.example/file', ?)
                    """, [.text(s.id), .text(s.course), .text(s.name), .integer(Int64(BerlinClock.utcSeconds(localISO: s.chdate)!)), .text(path),
                          .text(self.clock.nowISO), .text(sha), .text(s.folder), .integer(Int64(s.pages.count))])
            }
        }
        return (backend, tools, dir)
    }

    private func json(_ r: LocalResponse) throws -> JSONValue { try JSONValue.parse(r.body) }

    private let twoPages = ["Eigenwerte einer Matrix. Das charakteristische Polynom liefert die Eigenwerte und ihre Vielfachheit.",
                            "Diagonalisierbarkeit: eine Matrix ist diagonalisierbar, wenn eine Basis aus Eigenvektoren existiert."]

    func testBuildProducesRecordsAndSecondUserAdoptsWithoutAI() async throws {
        let (first, _, dir) = try await seeded([Seed(id: "f-vl1", name: "VL01 Eigenwerte.pdf", course: "c-ana", pages: twoPages, folder: "Vorlesung")])
        let cloud = FakeDocIndexCloud(), ai = FakeDocIndexAI()
        let r = try await DocIndexBuilder.build(fileID: "f-vl1", ctx: first.context, cloud: cloud, ai: ai, cipher: cipher)
        XCTAssertEqual(r.built, 2)
        XCTAssertEqual(r.aiCalls, 2)
        XCTAssertTrue(r.complete)
        XCTAssertEqual(ai.calls.map(\.page), [1, 2])
        XCTAssertFalse(ai.calls[0].image, "ohne CoreGraphics-Messung an einer Fake-PDF kein Bild")
        // Datensaetze: Seite 0 (Zusammenfassung) und zwei Seiten, nur Chiffrat, fileKey statt SHA, Fassung 1
        let records = cloud.all
        XCTAssertEqual(records.map(\.page), [0, 1, 2])
        XCTAssertEqual(records.map(\.fileKey), Array(repeating: r.fileKey, count: 3))
        XCTAssertFalse(records.contains { $0.payload.contains("Eigenwert") || $0.fileKey == r.fileSHA })
        XCTAssertTrue(records.allSatisfy { $0.version == 1 && $0.recordName.hasPrefix(r.fileKey + "#") })
        // Zusammenfassung lesbar mit Datei und Katalog aus den Kursdaten
        let hashes = twoPages.enumerated().map { DocIndexFingerprint.pageHash(text: $0.element, fileSHA: r.fileSHA, page: $0.offset + 1) }
        let summaryJSON = try DocIndexCrypto.open(records[0].payload, fileSHA: r.fileSHA, pageHash: DocIndexCrypto.summaryHash(pageHashes: hashes),
                                                  fileKey: r.fileKey, page: 0, cipher: cipher)
        let summary = try XCTUnwrap(DocIndexFileSummary(json: summaryJSON))
        XCTAssertEqual(summary.fileName, "VL01 Eigenwerte.pdf")
        XCTAssertEqual(summary.pageHashes, hashes)
        XCTAssertEqual(summary.catalog.kind, "vorlesung")
        XCTAssertEqual(summary.catalog.kindLabel, "Vorlesung")
        XCTAssertEqual(summary.catalog.moduleName, "Analysis I")
        XCTAssertEqual(summary.catalog.semester, "WiSe 2026/27")
        XCTAssertEqual(summary.catalog.studyProgram, "Allgemein")
        XCTAssertEqual(summary.catalog.week, 1)
        XCTAssertEqual(summary.catalog.date, "2026-10-26")
        XCTAssertEqual(summary.catalog.university, "luh")
        XCTAssertEqual(summary.catalog.moduleKey, CommunityKeys.moduleKey(university: "luh", courseTitle: "Analysis I"))
        XCTAssertEqual(summary.overview, "Seite 1: Eigenwerte und das charakteristische Polynom.")
        // lokal: drei Zeilen, geteilt, Quelle ai
        let rows = try await first.context.database.withConnection { try DocIndexStore.rows($0, fileSHA: r.fileSHA) }
        XCTAssertEqual(rows.map(\.page), [0, 1, 2])
        XCTAssertTrue(rows.allSatisfy { $0.shared && $0.source == "ai" && $0.isOK })
        XCTAssertNil(rows[1].content?["entry"]?["summary"]?.string?.range(of: "Diagonal"))

        // derselbe Nutzer noch einmal: nichts zu tun, "bereits bekannt (lokal)", keine KI
        let again = try await DocIndexBuilder.build(fileID: "f-vl1", ctx: first.context, cloud: cloud, ai: ai, cipher: cipher)
        XCTAssertEqual(again.aiCalls, 0)
        XCTAssertEqual(again.known, 2)
        XCTAssertTrue(again.log.contains("bereits bekannt: VL01 Eigenwerte.pdf (lokal)"), "\(again.log)")

        // zweiter Nutzer mit derselben Datei, ohne KI: uebernimmt alles aus der Bibliothek
        let (second, _, _) = try await seeded([Seed(id: "f-x", name: "VL01 Eigenwerte.pdf", course: "c-ana", pages: twoPages)], container: dir)
        let adopted = try await DocIndexBuilder.build(fileID: "f-x", ctx: second.context, cloud: cloud, ai: nil, cipher: cipher)
        XCTAssertEqual(adopted.adopted, 2)
        XCTAssertEqual(adopted.aiCalls, 0)
        XCTAssertFalse(adopted.needsAI)
        XCTAssertTrue(adopted.complete)
        XCTAssertTrue(adopted.log.contains("bereits bekannt: VL01 Eigenwerte.pdf (Bibliothek)"), "\(adopted.log)")
        XCTAssertTrue(adopted.log.contains("Seite 1 bereits bekannt (Bibliothek)"), "\(adopted.log)")
        XCTAssertEqual(cloud.saves, 3, "der zweite Nutzer speichert nichts erneut")
        let view = try json(await second.handle(LocalRequest(method: "GET", path: "/api/index/file/f-x/page/2")))
        XCTAssertEqual(view["status"]?.string, "ready")
        XCTAssertEqual(view["known"]?.bool, true)
        XCTAssertEqual(view["source"]?.string, "cloud")
        XCTAssertEqual(view["entry"]?["elements"]?.array?.count, 2)
        XCTAssertEqual(view["file_complete"]?.bool, true)
        XCTAssertEqual(view["pages_total"]?.int, 2)
        XCTAssertEqual(view["shelf_path"]?.array?.compactMap(\.string), ["Leibniz Universität Hannover", "Allgemein", "WiSe 2026/27", "Analysis I", "Woche 1 · 26.10. – 01.11.", "Vorlesung"])

        // eine andere Datei (anderer Inhalt) findet nichts und kann die Datensaetze nicht lesen
        let (third, _, _) = try await seeded([Seed(id: "f-other", name: "VL02 Fremd.pdf", course: "c-ana", pages: twoPages)], container: dir)
        let other = try await DocIndexBuilder.build(fileID: "f-other", ctx: third.context, cloud: cloud, ai: nil, cipher: cipher)
        XCTAssertEqual(other.adopted, 0)
        XCTAssertTrue(other.needsAI)
        XCTAssertNotEqual(other.fileKey, r.fileKey)
        XCTAssertThrowsError(try DocIndexCrypto.open(records[1].payload, fileSHA: other.fileSHA, pageHash: hashes[0], fileKey: r.fileKey, page: 1, cipher: cipher))
    }

    func testRetriesAtMostTwiceThenMarksFailedAndSkipsAfterThreeRuns() async throws {
        let (b, _, _) = try await seeded([Seed(id: "f-vl1", name: "VL01.pdf", course: "c-ana", pages: [twoPages[0]])])
        let cloud = FakeDocIndexCloud(), ai = FakeDocIndexAI()
        ai.garbage = true
        for run in 1...3 {
            let r = try await DocIndexBuilder.build(fileID: "f-vl1", ctx: b.context, cloud: cloud, ai: ai, cipher: cipher)
            XCTAssertEqual(r.aiCalls, 3, "Lauf \(run): ein Versuch, zwei Wiederholungen")
            XCTAssertEqual(r.failed, 1)
            XCTAssertFalse(r.complete)
            let row = try await b.context.database.withConnection { try DocIndexStore.row($0, fileSHA: r.fileSHA, page: 1) }
            XCTAssertEqual(row?.status, "failed")
            XCTAssertEqual(row?.attempts, run)
        }
        XCTAssertTrue(cloud.all.isEmpty, "nichts Ungeprueftes beim Dienst")
        let fourth = try await DocIndexBuilder.build(fileID: "f-vl1", ctx: b.context, cloud: cloud, ai: ai, cipher: cipher)
        XCTAssertEqual(fourth.aiCalls, 0)
        XCTAssertEqual(fourth.skipped, 1)
        XCTAssertTrue(fourth.log.contains { $0.contains("nach 3 Fehlversuchen ausgelassen") }, "\(fourth.log)")
        let view = try json(await b.handle(LocalRequest(method: "GET", path: "/api/index/file/f-vl1/page/1")))
        XCTAssertEqual(view["status"]?.string, "failed")
        // "Neu erklaeren lassen" (force) versucht es trotzdem; mit guter Antwort kommt der Eintrag und der Datensatz
        ai.garbage = false
        let forced = try await DocIndexBuilder.build(fileID: "f-vl1", ctx: b.context, cloud: cloud, ai: ai, cipher: cipher, options: DocIndexBuildOptions(force: true, pages: [1]))
        XCTAssertEqual(forced.built, 1)
        XCTAssertTrue(forced.complete)
        XCTAssertEqual(cloud.all.map(\.page), [0, 1])
        // Kontingent erschoepft: der Lauf endet sofort mit dem Fehler, nichts wird als gescheitert gezaehlt
        let (c, _, _) = try await seeded([Seed(id: "f-vl2", name: "VL02.pdf", course: "c-ana", pages: twoPages)])
        ai.failure = AIError("chatgpt_limit", "aufgebraucht")
        do {
            _ = try await DocIndexBuilder.build(fileID: "f-vl2", ctx: c.context, cloud: cloud, ai: ai, cipher: cipher)
            XCTFail("muss werfen")
        } catch let e as AIError {
            XCTAssertEqual(e.code, "chatgpt_limit")
        }
        let r = await c.handle(LocalRequest(method: "POST", path: "/api/index/file/f-vl2/page/1", body: Data("{}".utf8)))
        XCTAssertEqual(r.status, 404, "ohne KI im Backend wie die anderen KI-Endpunkte")
    }

    func testPrewarmCapsAtThreeFilesPerRunAndResumes() async throws {
        // Namen ohne Nummer (aus "VL03" liest die Bibliothek die Lehrwoche 3); laufende Woche 2 = 26.10.-01.11.
        let letters = ["A", "B", "C", "D", "E"]
        var seeds = (1...5).map { Seed(id: "f-\($0)", name: "Folien \(letters[$0 - 1]).pdf", course: "c-ana", pages: twoPages, chdate: "2026-\(["10-26", "10-27", "10-28", "10-29", "10-30"][$0 - 1])T10:00:00") }
        seeds.append(Seed(id: "f-old", name: "Folien alt.pdf", course: "c-ana", pages: twoPages, chdate: "2026-10-19T10:00:00"))   // Vorwoche: nicht dran
        let (b, _, _) = try await seeded(seeds)
        let cloud = FakeDocIndexCloud(), ai = FakeDocIndexAI()
        b.context.docIndex.configure(cloud: cloud, cipher: cipher)
        let first = await DocIndexBuilder.prewarm(ctx: b.context, cloud: cloud, ai: ai, cipher: cipher)
        XCTAssertEqual(first.candidates, 5)
        XCTAssertEqual(first.started.count, 3, "Deckel: hoechstens 3 Dateien je Lauf")
        XCTAssertEqual(first.started.map(\.fileID), ["f-5", "f-4", "f-3"], "neueste zuerst, feste Reihenfolge")
        XCTAssertTrue(first.started.allSatisfy(\.complete))
        XCTAssertTrue(ai.calls.allSatisfy { $0.small && !$0.image }, "sparsames Modell, nur Text")
        XCTAssertEqual(ai.calls.count, 6)
        // zweiter Lauf: die beiden uebrigen; mit Abbruch nach dem ersten KI-Aufruf bleibt der Rest offen
        let stopAfter = ai.calls.count + 1
        let second = await DocIndexBuilder.prewarm(ctx: b.context, cloud: cloud, ai: ai, cipher: cipher, shouldStop: { ai.calls.count >= stopAfter })
        XCTAssertEqual(second.candidates, 2)
        XCTAssertTrue(second.stopped)
        XCTAssertEqual(second.started.count, 1)
        XCTAssertEqual(second.started.first?.built, 1)
        XCTAssertEqual(second.started.first?.skipped, 1)
        XCTAssertEqual(ai.calls.count, 7)
        // dritter Lauf nimmt dort wieder auf: nur die fehlende Seite, dann die letzte Datei
        let third = await DocIndexBuilder.prewarm(ctx: b.context, cloud: cloud, ai: ai, cipher: cipher)
        XCTAssertEqual(third.candidates, 2)
        XCTAssertEqual(third.started.map(\.built), [1, 2])
        XCTAssertEqual(ai.calls.count, 10)
        XCTAssertEqual(cloud.all.filter { $0.page == 0 }.count, 5)
        let fourth = await DocIndexBuilder.prewarm(ctx: b.context, cloud: cloud, ai: ai, cipher: cipher)
        XCTAssertEqual(fourth.candidates, 0)
        XCTAssertEqual(ai.calls.count, 10)
        let status = try json(await b.handle(LocalRequest(method: "GET", path: "/api/index/status")))
        XCTAssertEqual(status["files"]?.int, 5)
        XCTAssertEqual(status["pages"]?.int, 10)
        XCTAssertEqual(status["library"]?.bool, true)
    }

    func testShelfTreeIsOrderedAndUsesLibraryKinds() async throws {
        let seeds = [Seed(id: "f-vl2", name: "VL02 Folgen.pdf", course: "c-ana", pages: twoPages, chdate: "2026-10-27T10:00:00", folder: "Vorlesung"),
                     Seed(id: "f-ue2", name: "Blatt 2.pdf", course: "c-ana-ue", pages: twoPages, chdate: "2026-10-27T11:00:00", folder: "Gruppenübung"),
                     Seed(id: "f-hu2", name: "Hoersaaluebung 2.pdf", course: "c-ana-ue", pages: twoPages, chdate: "2026-10-27T12:00:00", folder: "Hörsaalübung"),
                     Seed(id: "f-vl1", name: "VL01 Mengen.pdf", course: "c-ana", pages: twoPages, chdate: "2026-10-20T10:00:00"),
                     Seed(id: "f-alt", name: "Altklausur WS24.pdf", course: "c-ana", pages: twoPages, chdate: "2026-10-20T10:00:00", folder: "Altklausuren"),
                     Seed(id: "f-lin", name: "LA Vorlesung 1.pdf", course: "c-lin", pages: twoPages, chdate: "2026-10-20T10:00:00")]
        let (b, _, _) = try await seeded(seeds, courses: [("c-ana", "Analysis I", "Analysis I"), ("c-ana-ue", "Übung zu Analysis I", "Analysis I"),
                                                           ("c-lin", "Lineare Algebra I", "Lineare Algebra I")])
        let cloud = FakeDocIndexCloud(), ai = FakeDocIndexAI()
        _ = try await DocIndexBuilder.build(fileID: "f-ue2", ctx: b.context, cloud: cloud, ai: ai, cipher: cipher)
        _ = try await DocIndexBuilder.build(fileID: "f-vl1", ctx: b.context, cloud: cloud, ai: ai, cipher: cipher, options: DocIndexBuildOptions(pages: [1]))
        let shelf = try json(await b.handle(LocalRequest(method: "GET", path: "/api/index/shelf")))
        XCTAssertEqual(shelf["university"]?["name"]?.string, "Leibniz Universität Hannover")
        XCTAssertEqual(shelf["files"]?.int, 6)
        let programs = shelf["programs"]?.array ?? []
        XCTAssertEqual(programs.map { $0["name"]?.string }, ["Allgemein"])
        let semesters = programs[0]["semesters"]?.array ?? []
        XCTAssertEqual(semesters.map { $0["name"]?.string }, ["WiSe 2026/27"])
        let modules = semesters[0]["modules"]?.array ?? []
        XCTAssertEqual(modules.map { $0["name"]?.string }, ["Analysis I", "Lineare Algebra I"], "Module nach Name")
        let weeks = modules[0]["weeks"]?.array ?? []
        XCTAssertEqual(weeks.map { $0["week"]?.int }, [1, 2, -2], "Lehrwochen, dann Klausuren")
        XCTAssertEqual(weeks[1]["label"]?.string, "Woche 2 · 26.10. – 01.11.")
        XCTAssertEqual(weeks[1]["from"]?.string, "2026-10-27")
        let kinds = weeks[1]["kinds"]?.array ?? []
        XCTAssertEqual(kinds.map { $0["label"]?.string }, ["Vorlesung", "Hörsaalübung", "Gruppenübung"], "Arten in fester Reihenfolge")
        XCTAssertEqual(kinds[2]["files"]?.array?.first?["status"]?.string, "ready")
        XCTAssertEqual(kinds[2]["files"]?.array?.first?["indexed_pages"]?.int, 2)
        XCTAssertEqual(kinds[0]["files"]?.array?.first?["status"]?.string, "none")
        XCTAssertEqual(weeks[0]["kinds"]?.array?.first?["files"]?.array?.first?["status"]?.string, "partial")
        XCTAssertEqual(weeks[2]["kinds"]?.array?.map { $0["kind"]?.string }, ["altklausur"])
        // Filter nach Modul
        let linID = modules[1]["module_id"]?.int ?? -1
        let only = try json(await b.handle(LocalRequest(method: "GET", path: "/api/index/shelf", query: [.init("module", "\(linID)")])))
        XCTAssertEqual(only["files"]?.int, 1)
        XCTAssertEqual(only["programs"]?.array?.first?["semesters"]?.array?.first?["modules"]?.array?.map { $0["name"]?.string }, ["Lineare Algebra I"])
        // dieselbe Reihenfolge bei jedem Aufruf
        let again = try json(await b.handle(LocalRequest(method: "GET", path: "/api/index/shelf")))
        XCTAssertEqual(shelf, again)
    }

    /// KI-Hilfe oeffnet eine Seite (?lookup=1): ohne KI aus der Bibliothek uebernommen; ohne lookup nur der Zwischenspeicher
    func testPageLookupAdoptsFromLibraryWithoutAI() async throws {
        let dir = try tempContainer(self)
        let cloud = FakeDocIndexCloud(), ai = FakeDocIndexAI()
        let (first, _, _) = try await seeded([Seed(id: "f-a", name: "Skript.pdf", course: "c-ana", pages: twoPages)], container: dir)
        _ = try await DocIndexBuilder.build(fileID: "f-a", ctx: first.context, cloud: cloud, ai: ai, cipher: cipher)
        let calls = ai.calls.count
        let (second, _, _) = try await seeded([Seed(id: "f-b", name: "Skript.pdf", course: "c-ana", pages: twoPages)], container: dir)
        second.context.docIndex.configure(cloud: cloud, cipher: cipher)
        let plain = try json(await second.handle(LocalRequest(method: "GET", path: "/api/index/file/f-b/page/2")))
        XCTAssertEqual(plain["status"]?.string, "none", "ohne lookup keine Anfrage an die Bibliothek")
        let looked = try json(await second.handle(LocalRequest(method: "GET", path: "/api/index/file/f-b/page/2", query: [.init("lookup", "1")])))
        XCTAssertEqual(looked["status"]?.string, "ready")
        XCTAssertEqual(looked["source"]?.string, "cloud")
        XCTAssertEqual(ai.calls.count, calls, "keine KI")
    }

    func testPageViewLinksCrossReferencesAndOwnNotes() async throws {
        let seeds = [Seed(id: "f-vl1", name: "VL01.pdf", course: "c-ana", pages: twoPages, chdate: "2026-10-20T10:00:00", folder: "Vorlesung"),
                     Seed(id: "f-vl2", name: "VL02.pdf", course: "c-ana", pages: twoPages, chdate: "2026-10-27T10:00:00", folder: "Vorlesung"),
                     Seed(id: "f-la", name: "LA01.pdf", course: "c-lin", pages: twoPages, chdate: "2026-10-27T10:00:00")]
        let (b, _, _) = try await seeded(seeds, courses: [("c-ana", "Analysis I", "Analysis I"), ("c-lin", "Lineare Algebra I", "Lineare Algebra I")])
        let cloud = FakeDocIndexCloud(), ai = FakeDocIndexAI()
        ai.titles = [1: "Eigenwert einer Matrix", 2: "Satz von Bolzano-Weierstraß"]
        for id in ["f-vl1", "f-vl2", "f-la"] { _ = try await DocIndexBuilder.build(fileID: id, ctx: b.context, cloud: cloud, ai: ai, cipher: cipher) }
        // eigene Notizen: Seite 2 mit Objekten, Seite 1 leer; Versionsverlauf mit dem Stand vom 31.10.
        let pages: JSONValue = ["p1": ["objects": []], "p2": ["objects": [["type": "ink", "id": "o1"]]]]
        let root: JSONValue = ["version": 2, "zoom": 1.2, "pages": pages,
                               "pageOrder": [["key": "p1", "type": "pdf", "index": 1], ["key": "p2", "type": "pdf", "index": 2]]]
        try await b.context.database.transaction { c in
            try c.execute("INSERT INTO annotations(file_id, data, updated_at, version) VALUES ('f-vl2', ?, '2026-11-02T08:00:00', 3)", [.text(root.jsonString())])
            var older = root
            older["pages"] = ["p1": ["objects": []], "p2": ["objects": []]]
            try c.execute("INSERT INTO annotation_versions(file_id, version, data, created_at) VALUES ('f-vl2', 1, ?, '2026-10-30T09:00:00')", [.text(older.jsonString())])
            try c.execute("INSERT INTO annotation_versions(file_id, version, data, created_at) VALUES ('f-vl2', 2, ?, '2026-10-31T17:30:00')", [.text(root.jsonString())])
            try c.execute("INSERT INTO annotation_versions(file_id, version, data, created_at) VALUES ('f-vl2', 3, ?, '2026-11-01T10:00:00')", [.text(root.jsonString())])
        }
        let view = try json(await b.handle(LocalRequest(method: "GET", path: "/api/index/file/f-vl2/page/1")))
        XCTAssertEqual(view["status"]?.string, "ready")
        let refs = view["cross_refs"]?.array ?? []
        // Element 1 ("Eigenwert einer Matrix") steht auch in VL01 (Woche 1) auf Seite 1 und auf Seite 2 derselben Datei
        // ("Eigenwert einer Matrix" ist der Titel von Seite 1 in jeder Datei; Seite 2 hat "Satz von Bolzano-Weierstraß"),
        // nicht aber in Lineare Algebra (anderes Modul). Das Polynom-Element steht ueberall.
        let first = refs.filter { $0["order"]?.int == 1 }
        XCTAssertEqual(first.map { $0["text"]?.string }, ["auch in Vorlesung 1, Seite 1"], "\(refs)")
        XCTAssertEqual(first.first?["file_id"]?.string, "f-vl1")
        let second = refs.filter { $0["order"]?.int == 2 }
        XCTAssertEqual(second.map { $0["text"]?.string }, ["auch in Vorlesung 1, Seite 1", "auch in Vorlesung 1, Seite 2", "auch auf Seite 2"], "hoechstens drei, feste Reihenfolge")
        XCTAssertFalse(refs.contains { $0["file_id"]?.string == "f-la" }, "kein anderes Modul")
        let notes = view["own_notes"]?.array ?? []
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0]["page"]?.int, 2)
        XCTAssertEqual(notes[0]["date"]?.string, "2026-10-31", "aelteste Fassung in Folge mit demselben Inhalt")
        XCTAssertEqual(notes[0]["label"]?.string, "31.10.")
        XCTAssertEqual(notes[0]["current"]?.bool, false)
        let page2 = try json(await b.handle(LocalRequest(method: "GET", path: "/api/index/file/f-vl2/page/2")))
        XCTAssertEqual(page2["own_notes"]?.array?.first?["current"]?.bool, true)
        // unbekannte Datei, unbekannte Seite
        let unknown = await b.handle(LocalRequest(method: "GET", path: "/api/index/file/nix/page/1"))
        XCTAssertEqual(unknown.status, 404)
        let page9 = try json(await b.handle(LocalRequest(method: "GET", path: "/api/index/file/f-vl2/page/9")))
        XCTAssertEqual(page9["status"]?.string, "none")
        XCTAssertEqual(DocIndexStore.shortDate("2026-11-04T10:00:00"), "04.11.")
        XCTAssertEqual(DocIndexStore.shortDate(""), "")
    }

    func testPostBuildsSinglePageWithTextAIFromBackend() async throws {
        let (b, _, _) = try await seeded([Seed(id: "f-vl1", name: "VL01.pdf", course: "c-ana", pages: twoPages)])
        let cloud = FakeDocIndexCloud()
        b.context.docIndex.configure(cloud: cloud, cipher: cipher)
        /// Text-KI wie `ChatGPTSession` im Backend: wird ueber `TextDocIndexAI` angeschlossen
        struct TextAI: AIProvider {
            let inner = FakeDocIndexAI()
            func answer(system: String, prompt: String) async throws -> String { try await inner.index(system: system, prompt: prompt, imageJPEG: nil, schema: .null, small: false) }
        }
        b.context.ai.set(TextAI())
        let r = await b.handle(LocalRequest(method: "POST", path: "/api/index/file/f-vl1/page/2", body: Data("{\"image\": true}".utf8)))
        XCTAssertEqual(r.status, 200, String(decoding: r.body, as: UTF8.self))
        let view = try json(r)
        XCTAssertEqual(view["status"]?.string, "ready")
        XCTAssertEqual(view["report"]?["built"]?.int, 1)
        XCTAssertEqual(view["report"]?["complete"]?.bool, false, "Seite 1 fehlt noch")
        XCTAssertEqual(view["source"]?.string, "ai")
        XCTAssertEqual(cloud.all.map(\.page), [2])
        XCTAssertEqual(view["pages_known"]?.int, 1)
        XCTAssertEqual(view["can_build"]?.bool, true)
        let pre = try json(await b.handle(LocalRequest(method: "POST", path: "/api/index/file/f-vl1/prewarm")))
        XCTAssertEqual(pre["built"]?.int, 1)
        XCTAssertEqual(pre["known"]?.int, 1)
        XCTAssertEqual(pre["complete"]?.bool, true)
        XCTAssertEqual(cloud.all.map(\.page), [0, 1, 2])
    }
}
