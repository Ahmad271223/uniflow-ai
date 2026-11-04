import PDFKit
import PencilKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Notizen und Blaetter mitschicken (Wunsch des Inhabers 05.11.2026, docs/NOTIZEN-MITSCHICKEN-2026-11-05.md): Skript mit
/// 5 Folien, Seitennotiz (eingefuegtes Blatt) hinter Folie 2, leere Seitennotiz hinter Folie 3 und ein Blatt daneben,
/// auf dem neben Folie 4 geschrieben wurde. PDF-Export ("Abgeben" ruft dieselbe Funktion), Loesung und KI-Kontext
/// ueber den echten DocumentStore im lokalen Backend.
@MainActor
final class NotesExportAppTests: XCTestCase {

    private struct Env {
        let root: URL
        let api: APIClient
    }

    private func env() throws -> Env {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notizen-mit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let host = LocalBackendHost(directory: root.appendingPathComponent("db", isDirectory: true),
                                    clock: .fixed(berlin: "2026-11-05T10:00:00")!)
        return Env(root: root, api: APIClient(base: APIClient.localBase, transport: LocalTransport(host: host)))
    }

    private static let slide = CGSize(width: 960, height: 540)

    /// Folien 960 x 540, jede mit einer hellen Flaechenfarbe (Notizseiten bleiben weiss)
    private func slides(_ n: Int) -> Data {
        let raw = NSMutableData()
        var box = CGRect(origin: .zero, size: Self.slide)
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

    private func mainStore(_ e: Env) async throws -> DocumentStore {
        let fileID = "folien-" + UUID().uuidString.prefix(8).lowercased()
        let pdfURL = AppPaths.pdf(fileID, namespace: e.api.namespace, root: e.root)
        try FileManager.default.createDirectory(at: pdfURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try slides(5).write(to: pdfURL)
        let file = LibFile(id: fileID, name: "Folien.pdf", title: "Folien", kind: "pdf", module_id: nil, subject: "Lineare Algebra",
                           doc_type: nil, ai_title: nil, sub_label: nil, downloaded_at: "2026-11-05", has_notes: nil,
                           page_count: 5, studip_folder: nil)
        let store = DocumentStore(file: file, api: e.api, root: e.root)
        await store.load()
        XCTAssertNil(store.errorMessage)
        return store
    }

    /// "Daneben öffnen -> Leeres Blatt": Notizbuch im lokalen Backend, wie `CompanionPicker.createBlank`
    private func sheetStore(_ e: Env) async throws -> DocumentStore {
        let fields = NotebookDialog.fields(kind: "notebook", title: "Notizen – Folien", template: "grid",
                                           format: PageFormats.defaultNotebook, orientation: .portrait)
        let r = try await e.api.form("/api/notebooks", fields: fields)
        let id = try XCTUnwrap(r.s("id"))
        let file = try await e.api.json("/api/files/\(id)", as: LibFile.self)
        XCTAssertTrue(file.isNotebook)
        let store = DocumentStore(file: file, api: e.api, root: e.root)
        await store.load()
        XCTAssertNil(store.errorMessage)
        return store
    }

    private func ink(_ y: CGFloat) -> PKDrawing {
        let pts = (0..<12).map { i in
            PKStrokePoint(location: CGPoint(x: 60 + CGFloat(i) * 30, y: y), timeOffset: Double(i) * 0.01,
                          size: CGSize(width: 8, height: 8), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: pts, creationDate: Date()))])
    }

    /// Szene: Seitennotiz mit Tinte hinter Folie 2, leere Seitennotiz hinter Folie 3, Blatt daneben: Seite 1 neben
    /// Folie 4 beschrieben (Tinte und Text), Seite 2 leer
    private func scene(_ e: Env) async throws -> (main: DocumentStore, sheet: DocumentStore, bridge: EditorBridge) {
        let main = try await mainStore(e)
        await main.addBlankPage(afterKey: "p2", template: "lined")
        await main.addBlankPage(afterKey: "p3", template: "grid")
        let doc = await main.pageStructureDocument()
        let keys = doc.pageOrder.compactMap { $0["key"]?.string }
        XCTAssertEqual(keys.count, 7)
        let noteKey = keys[2], emptyNote = keys[4]
        XCTAssertTrue(doc.pageOrder[2]["type"]?.string == "blank" && doc.pageOrder[4]["type"]?.string == "blank")
        main.canvasChanged(pageKey: noteKey, drawing: ink(200))
        await main.flush()
        XCTAssertTrue(main.isWritable)
        _ = emptyNote

        let sheet = try await sheetStore(e)
        let firstSheetPage = try XCTUnwrap(sheet.pageKey(forPageIndex: 0))
        await sheet.addBlankPage(afterKey: firstSheetPage, template: "grid")
        let bridge = EditorBridge()
        bridge.pageKey = "p4"                                         // Folie 4 ist im Hauptdokument zu sehen
        DocumentView.linkSideSheet(sheet, shown: true, main: main, bridge: bridge)
        sheet.canvasChanged(pageKey: firstSheetPage, drawing: ink(300))
        await sheet.addText("Eigenwert = Nullstelle", pageKey: firstSheetPage)
        await sheet.flush()
        bridge.pageKey = "p5"                                         // weitergeblaettert: die erste Folie gilt
        sheet.canvasChanged(pageKey: firstSheetPage, drawing: ink(400))
        await sheet.flush()
        for _ in 0..<50 where SideNotes.links(await main.pageStructureDocument())[sheet.file.id]?[firstSheetPage] == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let links = SideNotes.links(await main.pageStructureDocument())
        XCTAssertEqual(links, [sheet.file.id: [firstSheetPage: "p4"]], "Blattseite mit Folie 4 verknuepft, nur einmal")
        return (main, sheet, bridge)
    }

    // MARK: PDF

    private struct Raster {
        let size: CGSize
        let pixels: [UInt8]
        let width: Int
        func rgb(_ x: CGFloat, _ y: CGFloat) -> (r: Double, g: Double, b: Double) {
            let px = min(width - 1, max(0, Int(x))), py = min(Int(size.height) - 1, max(0, Int(y)))
            let i = (py * width + px) * 4
            return (Double(pixels[i]) / 255, Double(pixels[i + 1]) / 255, Double(pixels[i + 2]) / 255)
        }
        var darkPixels: Int { stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] < 80 && pixels[$0 + 1] < 80 && pixels[$0 + 2] < 80 }.count }
    }

    private func raster(_ page: CGPDFPage) -> Raster {
        let box = page.getBoxRect(.cropBox)
        let w = Int(box.width), h = Int(box.height)
        var data = [UInt8](repeating: 255, count: w * h * 4)
        data.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.drawPDFPage(page)
        }
        // Zeilenrichtung spielt keine Rolle: Folien sind ganz gefaerbt, Notizseiten weiss
        return Raster(size: CGSize(width: w, height: h), pixels: data, width: w)
    }

    /// Ganzes Dokument: Folie 1, Folie 2, Seitennotiz, Folie 3, Folie 4, Blattseite, Folie 5. Die leere Seitennotiz
    /// hinter Folie 3 und die leere Blattseite fehlen; die Tinte steht auf den Notizseiten. Dasselbe, wenn das Blatt
    /// nicht mehr offen ist ("Abgeben" spaeter aus der Bibliothek).
    func testPDFHasNotesDirectlyBehindTheirSlide() async throws {
        let e = try env()
        let (main, sheet, _) = try await scene(e)
        let result = try await NotesExport.pdf(for: main, api: e.api, options: .init(folder: "notizen-test"))
        XCTAssertEqual(result.notePages, 2)
        XCTAssertTrue(result.url.lastPathComponent == "Folien.pdf")
        let pdf = try XCTUnwrap(CGPDFDocument(result.url as CFURL))
        XCTAssertEqual(pdf.numberOfPages, 7)
        let pages = (1...pdf.numberOfPages).map { raster(pdf.page(at: $0)!) }
        let colored = pages.map { r -> Bool in let c = r.rgb(r.size.width / 2, 20); return c.b > c.r + 0.1 }
        XCTAssertEqual(colored, [true, true, false, true, true, false, true], "Folie, Folie, Notiz, Folie, Folie, Blatt, Folie")
        XCTAssertEqual(pages[2].size, Self.slide, "Seitennotiz in der Groesse der Folie davor")
        XCTAssertEqual(pages[5].size, CGSize(width: 595, height: 842), "Blattseite in ihrer eigenen Groesse (A4)")
        XCTAssertGreaterThan(pages[2].darkPixels, 200, "Tinte der Seitennotiz gerendert")
        XCTAssertGreaterThan(pages[5].darkPixels, 400, "Tinte und Text der Blattseite gerendert")
        XCTAssertEqual(pages[1].darkPixels, 0, "Folie 2 ohne Notizen")

        // "Diese Seite" auf Folie 4: Folie und ihre Blattseite
        let page4 = try XCTUnwrap(main.layout?.index(ofKey: "p4"))
        let one = try await NotesExport.pdf(for: main, api: e.api, options: .init(scope: .page(page4), folder: "notizen-test"))
        XCTAssertEqual(CGPDFDocument(one.url as CFURL)?.numberOfPages, 2)
        XCTAssertEqual(one.notePages, 1)
        // ohne Blaetter: nur das eigene Dokument (leere Seitennotiz weiterhin weggelassen)
        let without = try await NotesExport.pdf(for: main, api: e.api, options: .init(includeSideNotes: false, folder: "notizen-test"))
        XCTAssertEqual(CGPDFDocument(without.url as CFURL)?.numberOfPages, 6)

        // Blatt geschlossen: wird aus demselben Datenordner gelesen und wieder freigegeben
        await sheet.close()
        XCTAssertNil(OpenDocuments.shared.openStore(fileID: sheet.file.id, namespace: e.api.namespace))
        let later = try await NotesExport.pdf(for: main, api: e.api, options: .init(fileStem: "Abgabe Blatt 4", folder: "abgabe"))
        XCTAssertEqual(CGPDFDocument(later.url as CFURL)?.numberOfPages, 7)
        XCTAssertEqual(later.url.lastPathComponent, "Abgabe Blatt 4.pdf")
        XCTAssertEqual(later.notePages, 2)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(OpenDocuments.shared.openStore(fileID: sheet.file.id, namespace: e.api.namespace), "kurz geoeffnet, wieder frei")
        await main.close()
    }

    // MARK: Loesung

    func testSolutionSendsNotesNextToTheirSlideAndTitlesThem() async throws {
        let e = try env()
        let (main, sheet, _) = try await scene(e)
        let loader = ShareExport.serverImageLoader(e.api)
        var source = try await main.solutionSource(loadImage: loader)
        let parts = await SideSheetLoader.sheets(for: main, api: e.api, open: sheet, loadImage: loader)
        XCTAssertEqual(parts.map(\.sheet.fileID), [sheet.file.id])
        source = await source.withSideNotes(parts)
        let draft = try SolutionSharing.draft(source)
        let preview = try XCTUnwrap(draft.content)
        let keys = preview.pages.map(\.key)
        let sheetKey = try XCTUnwrap(keys.first(where: SideNotes.isSheetKey))
        XCTAssertEqual(keys.firstIndex(of: sheetKey), try XCTUnwrap(keys.firstIndex(of: "p4")) + 1, "Blattseite direkt hinter Folie 4")
        XCTAssertEqual(keys.filter(SideNotes.isSheetKey).count, 1, "leere Blattseite fehlt")
        // Standard "Notizen und Blätter mitschicken": Seitennotiz und Blattseite sind gewaehlt
        let selected = SolutionShareSheet.applyNotes(true, to: draft.selection, preview: preview)
        XCTAssertTrue(selected.contains(sheetKey))
        XCTAssertTrue(selected.contains(keys[keys.firstIndex(of: "p2")! + 1]), "Seitennotiz hinter Folie 2")
        XCTAssertTrue(draft.canShare(selected))
        XCTAssertTrue(selected.contains("p4") && selected.contains("p2"), "die Folien der Notizen gehen mit")
        XCTAssertTrue(SolutionShareSheet.applyNotes(false, to: selected, preview: preview).isDisjoint(with: SolutionShareSheet.notePages(preview)))
        // Folie 4 abwaehlen nimmt ihre Blattseite mit heraus, die Blattseite waehlen bringt die Folie zurueck
        let off = SolutionShareSheet.toggled("p4", in: selected, preview: preview)
        XCTAssertFalse(off.contains("p4") || off.contains(sheetKey))
        XCTAssertTrue(SolutionShareSheet.toggled(sheetKey, in: off, preview: preview).isSuperset(of: ["p4", sheetKey]))
        // Paket bauen, oeffnen: beim Empfaenger "Notiz zu Folie 4"
        let content = try SolutionSharing.content(source, keys: Array(selected), displayName: "")
        let i = try XCTUnwrap(content.pages.firstIndex { $0.key == sheetKey })
        XCTAssertEqual(SolutionBuilder.pageTitle(content.pages, at: i), "Notiz zu Folie 4")
        XCTAssertEqual(content.pages[i].kind, .blank)
        XCTAssertEqual(content.pages[i].template, "grid")
        XCTAssertTrue(content.pages[i].objects.contains { $0["type"]?.string == "text" })
        XCTAssertEqual(SolutionBuilder.pageTitle(content.pages, at: content.pages.firstIndex { $0.key == "p4" } ?? 0), "PDF-Seite 4")
        await sheet.close()
        await main.close()
    }

    // MARK: KI

    func testTutorGetsTheNotesOfTheSlide() async throws {
        let e = try env()
        let (main, sheet, _) = try await scene(e)
        let p4 = await AttachedNotes.text(for: main, pageKey: "p4", api: e.api, open: sheet)
        XCTAssertTrue(p4.hasPrefix("[Blatt daneben 1]"), p4)
        XCTAssertTrue(p4.contains("Eigenwert = Nullstelle"), p4)
        XCTAssertLessThanOrEqual(p4.count, SideNotes.aiNotesChars)
        let p1 = await AttachedNotes.text(for: main, pageKey: "p1", api: e.api, open: sheet)
        XCTAssertEqual(p1, "", "Folie 1 hat keine Notizseiten")
        // auf der Seitennotiz hinter Folie 2 gilt Folie 2; ohne Text bleibt nur die (hier leere) Handschrift-Erkennung
        let noteKey = try XCTUnwrap(main.pageKey(forPageIndex: 2))
        let p2 = await AttachedNotes.text(for: main, pageKey: noteKey, api: e.api, open: sheet)
        XCTAssertFalse(p2.contains("Eigenwert"), "Blatt gehoert zu Folie 4")
        await sheet.close()
        await main.close()
    }
}
