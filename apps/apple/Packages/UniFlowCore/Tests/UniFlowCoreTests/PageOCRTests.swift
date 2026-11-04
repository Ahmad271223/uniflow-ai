import Foundation
import XCTest
@testable import UniFlowCore
#if canImport(Vision) && canImport(CoreText)
import CoreGraphics
import CoreText
#endif

// Texterkennung fuer PDF-Seiten ohne Textebene (`PageOCR`, `PageOCRStore`): mit einer Fake-Erkennung gegen die
// Skriptsuche-Fixture (search.json), dazu ein Lauf mit echter Vision auf einer selbst erzeugten Bild-PDF.

private func searchFixture() throws -> JSONValue {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return try JSONValue.parse(Data(contentsOf: url.appendingPathComponent("packages/shared-contracts/fixtures/local-backend/search.json")))
}

private let clock = UniFlowClock.fixed(berlin: "2026-10-26T09:00:00")!

/// Erkennung mit festen Texten je Seite; zaehlt, welche Seiten erkannt werden sollten
final class FakeOCR: PageOCR, @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [Int: String]
    private var log: [[Int]] = []
    var failure: Error?

    init(_ texts: [Int: String]) { self.texts = texts }

    func set(_ t: [Int: String]) { lock.withLock { texts = t } }
    var calls: [[Int]] { lock.withLock { log } }
    var pagesRecognized: [Int] { calls.flatMap { $0 } }

    func recognize(pdf url: URL, pages: [Int]) async throws -> [Int: String] {
        try lock.withLock {
            log.append(pages)
            if let failure { throw failure }
            return texts.filter { pages.contains($0.key) }
        }
    }
}

final class PageOCRTests: XCTestCase {

    private func seeded(tools: LocalDocumentTools) async throws -> LocalBackend {
        let fx = try searchFixture()
        let container = try tempContainer(self)
        for f in fx["files"]?.array ?? [] {
            let url = container.appendingPathComponent(f["path"]?.string ?? "")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try XCTUnwrap(Data(base64Encoded: f["base64"]?.string ?? "")).write(to: url)
        }
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock,
                                                  files: LocalFiles(container: container, dataDirectory: "", tools: tools))
        try await backend.context.database.transaction { c in
            for s in fx["seed"]?.array ?? [] { try c.execute(s["sql"]?.string ?? "", (s["params"]?.array ?? []).map { SQLiteValue(json: $0) ?? .null }) }
        }
        // f-la-v1 neu lesen lassen (Textebene aus `TextTools`)
        try await backend.context.database.execute("DELETE FROM page_texts WHERE file_id='f-la-v1'")
        return backend
    }

    private let fullPage = "Eigenwerte einer Matrix\nDas charakteristische Polynom liefert die Eigenwerte."

    /// Leere Textebene: der erkannte Text gilt, steht in `page_texts` (mit Suchform, die globale Suche findet ihn) und
    /// in `page_ocr`; die Seite mit Text wird nicht erkannt; ein zweiter Aufruf erkennt nichts erneut
    func testSparsePageUsesOCRTextAndIsCached() async throws {
        let tools = TextTools(["VL01 Eigenwerte.pdf": [fullPage, "  3 ", ""]])
        let backend = try await seeded(tools: tools)
        let db = backend.context.database, files = backend.context.files
        let ocr = FakeOCR([2: "Kirchhoffsche Maschenregel: Summe der Spannungen ist null", 3: "Knotenregel"])
        let first = try await ScriptSearch.pageTexts(fileID: "f-la-v1", database: db, files: files, ocr: ocr)
        XCTAssertEqual(first, [fullPage, "Kirchhoffsche Maschenregel: Summe der Spannungen ist null", "Knotenregel"])
        XCTAssertEqual(ocr.pagesRecognized, [2, 3], "Seite 1 hat eine Textebene")
        let stored = try await db.rows("SELECT page, text, search FROM page_texts WHERE file_id='f-la-v1' ORDER BY page")
        XCTAssertEqual(stored.map { $0["text"]?.string ?? "" }, first)
        XCTAssertEqual(stored[1]["search"]?.string, ScriptSearch.searchForm(first[1]))
        let cache = try await db.rows("SELECT page, chdate, embedded, text FROM page_ocr WHERE file_id='f-la-v1' ORDER BY page")
        XCTAssertEqual(cache.map { $0["page"] }, [2, 3])
        XCTAssertEqual(cache.map { $0["chdate"] }, [1760256000, 1760256000])
        XCTAssertEqual(cache.first?["embedded"], "  3 ")
        // zweiter Aufruf: aus page_texts, keine Erkennung, kein neues Lesen der PDF
        let again = try await ScriptSearch.pageTexts(fileID: "f-la-v1", database: db, files: files, ocr: ocr)
        XCTAssertEqual(again, first)
        XCTAssertEqual(ocr.calls.count, 1)
        XCTAssertEqual(tools.readCount, 1)
        // globale Suche findet den erkannten Text
        let r = await backend.handle(LocalRequest(method: "GET", path: "/api/search", query: [.init("q", "maschenregel")]))
        XCTAssertEqual(r.json?["pages"]?.array?.map { $0["file_id"] }, ["f-la-v1"])
        XCTAssertEqual(r.json?["pages"]?.array?.first?["page"], 2)
        // Seitenzuordnung einer neuen Fassung vergleicht Textebene mit Textebene
        let embedded = try await db.withConnection { try PageOCRStore.embedded($0, fileID: "f-la-v1", pages: first) }
        XCTAssertEqual(embedded, [fullPage, "  3 ", ""])
    }

    /// Seiten mit Textebene: keine Erkennung, keine Tabelle, Texte wie ohne OCR
    func testPagesWithTextNeverCallOCR() async throws {
        let tools = TextTools(["VL01 Eigenwerte.pdf": [fullPage, "Diagonalmatrix mit Eigenwerten auf der Diagonale"]])
        let backend = try await seeded(tools: tools)
        let db = backend.context.database
        let ocr = FakeOCR([1: "falsch", 2: "falsch"])
        let pages = try await ScriptSearch.pageTexts(fileID: "f-la-v1", database: db, files: backend.context.files, ocr: ocr)
        XCTAssertEqual(pages, [fullPage, "Diagonalmatrix mit Eigenwerten auf der Diagonale"])
        XCTAssertEqual(ocr.calls.count, 0)
        let table = try await db.queryOne("SELECT 1 FROM sqlite_master WHERE name='page_ocr'")
        XCTAssertNil(table)
    }

    /// Ohne Erkennung (Standard, Kern ohne Vision) und mit `.none`: alles wie bisher
    func testWithoutOCRNothingChanges() async throws {
        let tools = TextTools(["VL01 Eigenwerte.pdf": [fullPage, ""]])
        let backend = try await seeded(tools: tools)
        let db = backend.context.database
        let plain = try await ScriptSearch.pageTexts(fileID: "f-la-v1", database: db, files: backend.context.files)
        XCTAssertEqual(plain, [fullPage, ""])
        let ocr = FakeOCR([2: "Maschenregel und Knotenregel im Netzwerk"])
        let none = try await ScriptSearch.pageTexts(fileID: "f-la-v1", database: db, files: backend.context.files, ocr: ocr, ocrScope: .none)
        XCTAssertEqual(none, [fullPage, ""])
        XCTAssertEqual(ocr.calls.count, 0)
        // Endpunkt ohne gesetzte Erkennung
        let r = await backend.handle(LocalRequest(method: "GET", path: "/api/files/f-la-v1/pagetext", query: [.init("page", "2")]))
        XCTAssertEqual(r.json, ["text": "", "pages": 2, "kind": "pdf"])
    }

    /// Nur die gefragte Seite (`/pagetext`), ein leeres Ergebnis wird gemerkt, eine neue Fassung erkennt neu,
    /// ein Fehler der Erkennung laesst die Texte und versucht es beim naechsten Mal wieder
    func testScopeEmptyResultNewVersionAndFailure() async throws {
        let tools = TextTools(["VL01 Eigenwerte.pdf": ["", "", ""]])
        let backend = try await seeded(tools: tools)
        let db = backend.context.database
        let ocr = FakeOCR([2: "Ohmsches Gesetz und Widerstand"])
        backend.context.ocr.set(ocr)
        let r = await backend.handle(LocalRequest(method: "GET", path: "/api/files/f-la-v1/pagetext", query: [.init("page", "2")]))
        XCTAssertEqual(r.json, ["text": "Ohmsches Gesetz und Widerstand", "pages": 3, "kind": "pdf"])
        XCTAssertEqual(ocr.calls, [[2]], "nur die gefragte Seite")
        // Seite 1: nichts erkannt -> gemerkt, kein zweiter Versuch
        _ = await backend.handle(LocalRequest(method: "GET", path: "/api/files/f-la-v1/pagetext", query: [.init("page", "1")]))
        _ = await backend.handle(LocalRequest(method: "GET", path: "/api/files/f-la-v1/pagetext", query: [.init("page", "1")]))
        XCTAssertEqual(ocr.calls, [[2], [1]])
        // Fehler: Texte bleiben, nichts gemerkt
        ocr.failure = CocoaError(.fileReadCorruptFile)
        let failed = try await ScriptSearch.pageTexts(fileID: "f-la-v1", database: db, files: backend.context.files, ocr: ocr, ocrScope: .pages([3]))
        XCTAssertEqual(failed, ["", "Ohmsches Gesetz und Widerstand", ""])
        ocr.failure = nil
        ocr.set([3: "Leistung ist Spannung mal Strom"])
        let retried = try await ScriptSearch.pageTexts(fileID: "f-la-v1", database: db, files: backend.context.files, ocr: ocr, ocrScope: .pages([3]))
        XCTAssertEqual(retried[2], "Leistung ist Spannung mal Strom")
        XCTAssertEqual(ocr.calls, [[2], [1], [3], [3]])
        // neue Fassung: Textebene neu gelesen, Ergebnisse verworfen, neu erkannt
        try await db.execute("UPDATE files SET chdate=1760300000 WHERE id='f-la-v1'")
        ocr.set([2: "Neue Fassung mit Thevenin-Ersatzschaltung"])
        let renewed = try await ScriptSearch.pageTexts(fileID: "f-la-v1", database: db, files: backend.context.files, ocr: ocr, ocrScope: .pages([2]))
        XCTAssertEqual(renewed, ["", "Neue Fassung mit Thevenin-Ersatzschaltung", ""])
        XCTAssertEqual(tools.readCount, 2)
        let left = try await db.rows("SELECT page, chdate FROM page_ocr WHERE file_id='f-la-v1' ORDER BY page")
        XCTAssertEqual(left.map { $0["page"] }, [2])
        XCTAssertEqual(left.first?["chdate"], 1760300000)
    }

    /// KI-Hilfe: ohne mitgeschickten Seitentext liest der Tutor die erkannte Seite (nur diese wird fuer den
    /// Seitentext erkannt; die Quellen der Skriptsuche erkennen die Vorlesungen und Skripte des Moduls)
    func testTutorUsesRecognizedPageText() async throws {
        let tools = TextTools(["VL01 Eigenwerte.pdf": [fullPage, "", ""]])
        let backend = try await seeded(tools: tools)
        let ocr = FakeOCR([2: "Kirchhoffsche Maschenregel im geschlossenen Umlauf"])
        backend.context.ocr.set(ocr)
        let ai = FakeAI("Erklaerung")
        backend.context.ai.set(ai)
        let r = await backend.handle(LocalRequest(method: "POST", url: URL(string: "uniflow-local://device/api/ai/tutor")!,
                                                  headers: ["Content-Type": "application/json"],
                                                  body: (["file_id": "f-la-v1", "page": 2, "mode": "explain"] as JSONValue).serialized()))
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(ai.prompts.count, 1)
        XCTAssertTrue(ai.prompts.first?.prompt.contains("Kirchhoffsche Maschenregel im geschlossenen Umlauf") == true)
        XCTAssertEqual(ocr.calls.first, [2], "zuerst nur die offene Seite")
    }

    #if canImport(Vision) && canImport(CoreText)
    /// Echte Vision: PDF, deren einzige Seite ein Bild mit Text ist (keine Textebene), wird erkannt
    func testVisionRecognizesTextInImagePDF() async throws {
        let dir = try tempContainer(self)
        let url = dir.appendingPathComponent("scan.pdf")
        try Self.imagePDF(lines: ["Kirchhoffsche Maschenregel", "Die Summe aller Spannungen ist null."], to: url)
        let found = try await VisionPageOCR().recognize(pdf: url, pages: [1, 2])
        let text = try XCTUnwrap(found[1])
        XCTAssertTrue(text.contains("Kirchhoffsche"), text)
        XCTAssertTrue(text.contains("Maschenregel"), text)
        XCTAssertNil(found[2], "Seite gibt es nicht")
        // durch die Seitentexte des Kerns (Textebene leer wie bei einem Scan)
        let container = try tempContainer(self)
        try FileManager.default.createDirectory(at: container.appendingPathComponent("files"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: container.appendingPathComponent("files/scan.pdf"))
        let backend = try await LocalBackend.open(path: SQLiteDatabase.inMemory, clock: clock,
                                                  files: LocalFiles(container: container, dataDirectory: "", tools: TextTools(["scan.pdf": [""]])))
        let db = backend.context.database
        try await db.execute("INSERT INTO courses(id, title) VALUES ('k1', 'Elektrotechnik')")
        try await db.execute("INSERT INTO files(id, course_id, name, chdate, local_path) VALUES ('scan', 'k1', 'scan.pdf', 5, 'files/scan.pdf')")
        let pages = try await ScriptSearch.pageTexts(fileID: "scan", database: db, files: backend.context.files, ocr: VisionPageOCR())
        XCTAssertEqual(pages.count, 1)
        XCTAssertTrue(pages[0].contains("Maschenregel"), pages[0])
    }

    /// Einseitige PDF (A4) mit dem Text als Bild (150 dpi), ohne Textebene
    static func imagePDF(lines: [String], to url: URL) throws {
        let w = 1240, h = 1754
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let font = CTFontCreateWithName("Helvetica" as CFString, 56, nil)
        for (i, line) in lines.enumerated() {
            let attr = NSAttributedString(string: line, attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
            ctx.textPosition = CGPoint(x: 100, y: CGFloat(h - 250 - i * 110))
            CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
        }
        let image = try XCTUnwrap(ctx.makeImage())
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let pdf = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        pdf.beginPDFPage(nil)
        pdf.draw(image, in: box)
        pdf.endPDFPage()
        pdf.closePDF()
    }
    #endif
}
