import PDFKit
import PencilKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Wunsch des Inhabers (13.11.2026): Die Loesung eines anderen erscheint neben dem eigenen Dokument genau so, wie sie
/// geschrieben wurde. Auf Folien liegt die eigene PDF-Seite darunter; auf eigenen Blaettern des Absenders (liniert,
/// kariert ...) genau dieses Papier. Mitgeschickt wird nur der Name des Musters, keine Datei und keine PDF.
/// Zwei getrennte Konten (eigener Datenordner je Konto), echtes Paket (versiegelt und wieder geoeffnet).
@MainActor
final class CommunityPaperAppTests: XCTestCase {

    private struct Account {
        let root: URL
        let api: APIClient
    }

    private func account(_ name: String) throws -> Account {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("papier-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let host = LocalBackendHost(directory: root.appendingPathComponent("db", isDirectory: true), clock: .fixed(berlin: "2026-11-13T10:00:00")!)
        return Account(root: root, api: APIClient(base: APIClient.localBase, transport: LocalTransport(host: host)))
    }

    /// Folien 960 x 540, hellblau
    static func slides(_ n: Int) -> Data {
        let raw = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 960, height: 540)
        let ctx = CGContext(consumer: CGDataConsumer(data: raw as CFMutableData)!, mediaBox: &box, nil)!
        for _ in 0..<n {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(red: 0.75, green: 0.85, blue: 1, alpha: 1)
            ctx.fill(box)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return raw as Data
    }

    private func pdfStore(_ a: Account, _ data: Data, id: String) async throws -> DocumentStore {
        let url = AppPaths.pdf(id, namespace: a.api.namespace, root: a.root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        let file = LibFile(id: id, name: "Uebung.pdf", title: "Übung 4", kind: "pdf", module_id: nil, subject: "Lineare Algebra",
                           doc_type: nil, ai_title: nil, sub_label: nil, downloaded_at: "2026-11-13", has_notes: nil,
                           page_count: 3, studip_folder: nil)
        let s = DocumentStore(file: file, api: a.api, root: a.root)
        await s.load()
        XCTAssertNil(s.errorMessage)
        return s
    }

    static func ink(_ y: CGFloat) -> PKDrawing {
        let pts = (0..<12).map { i in
            PKStrokePoint(location: CGPoint(x: 60 + CGFloat(i) * 30, y: y), timeOffset: Double(i) * 0.01,
                          size: CGSize(width: 6, height: 6), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .red), path: PKStrokePath(controlPoints: pts, creationDate: Date()))])
    }

    /// Absenderin: Notiz auf Folie 3, Blatt daneben mit Seite 1 liniert (neben Folie 1) und Seite 2 kariert (neben
    /// Folie 2). Liefert die Loesung als versiegeltes Paket und die PDF-Bytes.
    static func authorPackage(_ a: (root: URL, api: APIClient), pdf: Data, test: XCTestCase) async throws -> (package: Data, solutionID: String) {
        let url = AppPaths.pdf("folien-mia", namespace: a.api.namespace, root: a.root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pdf.write(to: url)
        let file = LibFile(id: "folien-mia", name: "Uebung.pdf", title: "Übung 4", kind: "pdf", module_id: nil, subject: nil,
                           doc_type: nil, ai_title: nil, sub_label: nil, downloaded_at: "2026-11-13", has_notes: nil,
                           page_count: 3, studip_folder: nil)
        let main = DocumentStore(file: file, api: a.api, root: a.root)
        await main.load()
        main.canvasChanged(pageKey: "p3", drawing: ink(300))
        await main.flush()

        let fields = NotebookDialog.fields(kind: "notebook", title: "Notizen – Übung 4", template: "lined",
                                           format: PageFormats.defaultNotebook, orientation: .portrait)
        let created = try await a.api.form("/api/notebooks", fields: fields)
        let sheetFile = try await a.api.json("/api/files/\(created.s("id") ?? "")", as: LibFile.self)
        let sheet = DocumentStore(file: sheetFile, api: a.api, root: a.root)
        await sheet.load()
        let first = sheet.pageKey(forPageIndex: 0) ?? ""
        await sheet.addBlankPage(afterKey: first, template: "grid")
        let second = sheet.pageKey(forPageIndex: 1) ?? ""
        let bridge = EditorBridge()
        DocumentView.linkSideSheet(sheet, shown: true, main: main, bridge: bridge)
        bridge.pageKey = "p1"
        sheet.canvasChanged(pageKey: first, drawing: ink(200))
        await sheet.flush()
        for _ in 0..<50 where SideNotes.links(await main.pageStructureDocument())[sheet.file.id]?[first] == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        bridge.pageKey = "p2"
        sheet.canvasChanged(pageKey: second, drawing: ink(400))
        await sheet.flush()
        for _ in 0..<50 where SideNotes.links(await main.pageStructureDocument())[sheet.file.id]?[second] == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let loader = ShareExport.serverImageLoader(a.api)
        var source = try await main.solutionSource(loadImage: loader)
        source = await source.withSideNotes(await SideSheetLoader.sheets(for: main, api: a.api, open: sheet, loadImage: loader))
        let draft = try SolutionSharing.draft(source)
        let preview = try XCTUnwrap(draft.content)
        let selected = SolutionShareSheet.applyNotes(true, to: draft.selection, preview: preview)
        let content = try SolutionSharing.content(source, keys: Array(selected), displayName: "Mia")
        let sealed = try SolutionSharing.package(content, originalPDF: pdf)
        DocumentView.linkSideSheet(sheet, shown: false, main: main, bridge: bridge)
        await sheet.close()
        await main.close()
        return (try sealed.encoded(), content.solutionID)
    }

    /// Mehrseitige Loesung: Folie 1, liniertes Blatt, Folie 2, kariertes Blatt, Folie 3 - jede Seite auf ihrem
    /// Hintergrund. Im Paket steht nur der Name des Musters, keine PDF.
    func testEachPageKeepsItsPaperAndOwnPDFBelowSlides() async throws {
        let pdf = Self.slides(3)
        let mia = try account("mia")
        let (blob, _) = try await Self.authorPackage((mia.root, mia.api), pdf: pdf, test: self)
        for marker in ["%PDF", "JVBERi0"] { XCTAssertNil(blob.range(of: Data(marker.utf8)), "keine PDF im Paket") }

        // Betrachter mit eigenem Konto und eigener Kopie derselben PDF
        let ben = try account("ben")
        let own = try await pdfStore(ben, pdf, id: "folien-ben")
        let content = try SolutionPackage.decode(blob).open(originalPDF: pdf, cipher: CryptoKitSolutionCipher())
        let kinds = content.pages.map { $0.kind == .pdf ? "pdf\($0.pdfIndex ?? 0)" : ($0.template ?? "?") }
        XCTAssertEqual(kinds, ["pdf1", "lined", "pdf2", "grid", "pdf3"], "Seiten untereinander, Blattseite hinter ihrer Folie")
        XCTAssertEqual(content.pages.map { SolutionPaper.title(content.pages, at: content.pages.firstIndex(of: $0)!) },
                       ["PDF-Seite 1", "Notiz zu Folie 1 · Liniert", "PDF-Seite 2", "Notiz zu Folie 2 · Kariert", "PDF-Seite 3"])
        let plain = String(decoding: content.json.serialized(sortedKeys: true), as: UTF8.self)
        XCTAssertTrue(plain.contains("\"template\":\"lined\"") && plain.contains("\"template\":\"grid\""), "nur der Name des Musters")

        // so zeigt es die Spalte daneben (SolutionSidePane): eigene PDF-Seite bzw. Papier des Absenders
        let layer = try SolutionSharing.layer(content, visible: true, pdf: try XCTUnwrap(own.originalPDF))
        var images: [UIImage] = []
        for p in layer.pages { images.append(await own.offscreenPDF.solutionPreview(p, images: [:], width: 400, scale: 3)) }
        let stats = images.map(Self.stats)
        XCTAssertTrue(stats[0].blue > 0.8 && stats[2].blue > 0.8 && stats[4].blue > 0.8, "Folien auf der eigenen PDF")
        XCTAssertLessThan(stats[1].blue, 0.01, "Blattseite nicht auf einer Folie")
        XCTAssertGreaterThan(stats[1].lineRows, 10, "liniert: viele waagerechte Linien")
        XCTAssertEqual(stats[1].lineColumns, 0, "liniert: keine senkrechten Linien")
        XCTAssertGreaterThan(stats[3].lineRows, 10, "kariert: waagerechte Linien")
        XCTAssertGreaterThan(stats[3].lineColumns, 10, "kariert: senkrechte Linien")
        XCTAssertGreaterThan(stats[1].red + stats[3].red + stats[4].red, 0, "Schrift der Absenderin")

        // ohne eigene PDF (Lese-Ansicht): Folien weiss, Blaetter weiterhin auf ihrem Papier
        let blank = layer.pages.map { Self.stats(SolutionPreview.image($0, images: [:], width: 400, scale: 3)) }
        XCTAssertEqual(blank[0].blue, 0)
        XCTAssertGreaterThan(blank[1].lineRows, 10)
        XCTAssertGreaterThan(blank[3].lineColumns, 10)
        XCTAssertTrue(SolutionPaper.hasPDFPages(content.pages))
        XCTAssertFalse(SolutionPaper.hasPDFPages(content.pages.filter { $0.kind == .blank }))
        await own.close()
    }

    /// Anteil blauer Pixel, roter Pixel und Zahl der Zeilen bzw. Spalten mit einer durchgehenden grauen Linie
    static func stats(_ image: UIImage) -> (blue: Double, red: Int, lineRows: Int, lineColumns: Int) {
        guard let cg = image.cgImage else { return (0, 0, 0, 0) }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 255, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        func at(_ x: Int, _ y: Int) -> (Int, Int, Int) { let i = (y * w + x) * 4; return (Int(px[i]), Int(px[i + 1]), Int(px[i + 2])) }
        func grey(_ c: (Int, Int, Int)) -> Bool { c.0 < 245 && abs(c.0 - c.1) < 25 && abs(c.1 - c.2) < 40 && c.2 >= c.0 - 5 }
        var blue = 0, red = 0
        for y in 0..<h { for x in 0..<w {
            let c = at(x, y)
            if c.2 > c.0 + 25 && c.2 > 200 { blue += 1 }
            if c.0 > 150 && c.1 < 90 && c.2 < 90 { red += 1 }
        } }
        let rows = (0..<h).filter { y in (w / 5..<(4 * w / 5)).filter { grey(at($0, y)) }.count > (3 * w / 5) * 7 / 10 }.count
        let cols = (0..<w).filter { x in (h / 5..<(4 * h / 5)).filter { grey(at(x, $0)) }.count > (3 * h / 5) * 7 / 10 }.count
        return (Double(blue) / Double(w * h), red, rows, cols)
    }
}
