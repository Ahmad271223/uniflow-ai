import PDFKit
import PencilKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Fehlerbericht des Inhabers (13.11.2026): Ein leeres Blatt, das er neben einem Dokument geoeffnet und beschrieben
/// hatte, war nach dem Schliessen nirgends mehr zu sehen. Beim "Drucken" des Dokuments erschien dafuer ein ganz anderes,
/// altes Blatt, das er in der App sonst nicht fand. Ursache: Druck und Export nahmen jedes jemals verknuepfte Blatt mit,
/// auch eins im Papierkorb, und nicht das gerade offene; wiederfinden liess sich ein Blatt nur ueber die Bibliothek.
/// Ausserdem: fremde Loesung 1:1 auf der eigenen PDF-Seite (gleicher Fingerabdruck).
@MainActor
final class SideSheetFoundAgainAppTests: XCTestCase {

    private struct Env {
        let root: URL
        let host: LocalBackendHost
        let api: APIClient
    }

    private func env() throws -> Env {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nebenblatt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let host = LocalBackendHost(directory: root.appendingPathComponent("db", isDirectory: true),
                                    clock: .fixed(berlin: "2026-11-13T10:00:00")!,
                                    files: LocalFiles(container: root, dataDirectory: "Library/Application Support/UniFlow", tools: AppDocumentTools()))
        return Env(root: root, host: host, api: APIClient(base: APIClient.localBase, transport: LocalTransport(host: host)))
    }

    private static let slide = CGSize(width: 960, height: 540)

    /// Folien 960 x 540, hellblau gefuellt (Notizseiten bleiben weiss)
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
        try slides(3).write(to: pdfURL)
        let file = LibFile(id: fileID, name: "Folien.pdf", title: "Folien", kind: "pdf", module_id: nil, subject: "Lineare Algebra",
                           doc_type: nil, ai_title: nil, sub_label: nil, downloaded_at: "2026-11-13", has_notes: nil,
                           page_count: 3, studip_folder: nil)
        let store = DocumentStore(file: file, api: e.api, root: e.root)
        await store.load()
        XCTAssertNil(store.errorMessage)
        return store
    }

    /// "Daneben öffnen -> Leeres Blatt", wie `CompanionPicker.createBlank`
    private func newSheet(_ e: Env, title: String = CompanionPicker.sheetTitle(for: "Folien")) async throws -> DocumentStore {
        let fields = NotebookDialog.fields(kind: "notebook", title: title, template: "grid",
                                           format: PageFormats.defaultNotebook, orientation: .portrait)
        let r = try await e.api.form("/api/notebooks", fields: fields)
        let file = try await e.api.json("/api/files/\(try XCTUnwrap(r.s("id")))", as: LibFile.self)
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

    /// Blatt neben Folie `slide` beschreiben (wie die geteilte Ansicht: `linkSideSheet`), sichern
    private func write(on sheet: DocumentStore, beside slide: String, main: DocumentStore, y: CGFloat = 300) async throws {
        let bridge = EditorBridge()
        bridge.pageKey = slide
        DocumentView.linkSideSheet(sheet, shown: true, main: main, bridge: bridge)
        let page = try XCTUnwrap(sheet.pageKey(forPageIndex: 0))
        sheet.canvasChanged(pageKey: page, drawing: ink(y))
        await sheet.flush()
        for _ in 0..<50 where SideNotes.links(await main.pageStructureDocument())[sheet.file.id] == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let doc = await main.pageStructureDocument()
        XCTAssertNotNil(SideNotes.links(doc)[sheet.file.id], "Blatt mit der Folie verknuepft")
        DocumentView.linkSideSheet(sheet, shown: false, main: main, bridge: bridge)
    }

    private func pageCount(_ r: NotesExport.Result) -> Int { CGPDFDocument(r.url as CFURL)?.numberOfPages ?? -1 }

    // MARK: Drucken

    /// Altes Blatt im Papierkorb: geht beim Drucken nicht mehr mit (vorher erschien es im Druck, war aber in der App
    /// nirgends zu sehen). Wiederhergestellt geht es wieder mit.
    func testTrashedOldSheetIsNotPrinted() async throws {
        let e = try env()
        let main = try await mainStore(e)
        let old = try await newSheet(e)
        try await write(on: old, beside: "p1", main: main)
        await old.close()

        let before = try await NotesExport.pdf(for: main, api: e.api, options: .init(folder: "druck-test"))
        XCTAssertEqual(pageCount(before), 4, "3 Folien und die Blattseite hinter Folie 1")

        _ = try await e.api.value("/api/library/files/\(old.file.id)", method: "PATCH", body: ["trash": true])
        let trashed = try await NotesExport.pdf(for: main, api: e.api, options: .init(folder: "druck-test"))
        XCTAssertEqual(pageCount(trashed), 3, "Blatt im Papierkorb geht nicht mit in den Druck")
        let entries = await SideSheetLoader.entries(for: main, api: e.api)
        XCTAssertEqual(entries.map(\.id), [old.file.id])
        XCTAssertEqual(entries.first?.trashed, true, "als Blatt im Papierkorb bekannt (wiederherstellbar)")

        _ = try await e.api.value("/api/library/files/\(old.file.id)", method: "PATCH", body: ["restore": true])
        let restored = try await NotesExport.pdf(for: main, api: e.api, options: .init(folder: "druck-test"))
        XCTAssertEqual(pageCount(restored), 4, "wiederhergestellt: geht wieder mit")
        await main.close()
    }

    /// Das gerade daneben offene Blatt geht mit, auch wenn noch nichts verknuepft ist; ein im Hinweis abgewaehltes
    /// altes Blatt nicht. Der Druck nimmt also genau das Dokument und die Blaetter, die der Hinweis nennt.
    func testPrintTakesTheOpenSheetAndLeavesOutDeselectedOnes() async throws {
        let e = try env()
        let main = try await mainStore(e)
        let old = try await newSheet(e)
        try await write(on: old, beside: "p1", main: main)
        await old.close()

        // neues Blatt, beschrieben, aber (noch) nicht verknuepft - z. B. gerade fuer die Community geloest
        let current = try await newSheet(e)
        let page = try XCTUnwrap(current.pageKey(forPageIndex: 0))
        current.canvasChanged(pageKey: page, drawing: ink(500))
        await current.flush()

        let names = await SideSheetLoader.entries(for: main, api: e.api, open: current)
        XCTAssertEqual(names.map(\.id), [old.file.id, current.file.id], "der Hinweis nennt beide Blaetter")
        XCTAssertTrue(names.allSatisfy { $0.title == "Notizen – Folien" && !$0.trashed })

        let all = try await NotesExport.pdf(for: main, api: e.api, options: .init(folder: "druck-test"), open: current)
        XCTAssertEqual(pageCount(all), 5, "3 Folien, altes Blatt hinter Folie 1, offenes Blatt am Ende")

        var options = NotesExport.Options(folder: "druck-test")
        options.excludedSheets = [old.file.id]
        let onlyCurrent = try await NotesExport.pdf(for: main, api: e.api, options: options, open: current)
        XCTAssertEqual(pageCount(onlyCurrent), 4, "abgewaehltes altes Blatt bleibt draussen, das offene geht mit")
        let pdf = try XCTUnwrap(PDFDocument(url: onlyCurrent.url))
        XCTAssertEqual(pdf.page(at: 3)?.bounds(for: .cropBox).size, CGSize(width: 595, height: 842), "letzte Seite ist das Blatt (A4)")
        await current.close()
        await main.close()
    }

    // MARK: Wiederfinden

    /// Beschriebenes Blatt geschlossen: nichts geht verloren, und es taucht wieder auf - unter "Daneben öffnen" bei
    /// "Deine Blätter zu diesem Dokument", in der Bibliothek und unter "Zuletzt benutzt".
    func testClosedSheetIsKeptAndFoundAgain() async throws {
        let e = try env()
        let main = try await mainStore(e)
        let sheet = try await newSheet(e)
        try await write(on: sheet, beside: "p2", main: main)
        // wie CompanionView beim Oeffnen
        _ = try await e.api.value("/api/files/\(sheet.file.id)/opened", method: "POST", body: [:])
        let sheetID = sheet.file.id
        await sheet.close()

        // nichts verloren: neu geoeffnet stehen die Striche noch da
        let file = try await e.api.json("/api/files/\(sheetID)", as: LibFile.self)
        let again = DocumentStore(file: file, api: e.api, root: e.root)
        await again.load()
        let key = try XCTUnwrap(again.pageKey(forPageIndex: 0))
        let reopened = await again.pageStructureDocument()
        XCTAssertFalse(reopened.objects(page: key).isEmpty, "Striche nach dem Schliessen noch da")
        await again.close()

        // "Daneben öffnen": oben unter "Deine Blätter zu diesem Dokument", dazu ein nur angelegtes Blatt gleichen Namens
        let unlinked = try await newSheet(e)
        await unlinked.close()
        let other = try await newSheet(e, title: "Notizen – Analysis")
        await other.close()
        let library = try await e.api.json("/api/library", as: LibraryResponse.self).files
        XCTAssertTrue(library.contains { $0.id == sheetID }, "in der Bibliothek")
        let own = await CompanionPicker.ownSheets(linked: main.sideSheetFileIDs, named: CompanionPicker.sheetTitle(for: "Folien"),
                                                  library: library, excluding: main.file.id, api: e.api)
        XCTAssertEqual(own.map(\.id), [sheetID, unlinked.file.id], "verknuepftes zuerst, Blatt eines anderen Dokuments nicht")

        // "Zuletzt benutzt" auf der Uebersicht
        let recent = try await e.api.value("/api/recent?limit=20")
        XCTAssertTrue(recent.list("items").contains { $0.s("id") == sheetID }, "unter „Zuletzt benutzt“")

        // im Papierkorb: weiter in der Liste, mit "Wiederherstellen"
        _ = try await e.api.value("/api/library/files/\(sheetID)", method: "PATCH", body: ["trash": true])
        let afterTrash = await CompanionPicker.ownSheets(linked: main.sideSheetFileIDs, named: CompanionPicker.sheetTitle(for: "Folien"),
                                                         library: [], excluding: main.file.id, api: e.api)
        XCTAssertEqual(afterTrash.first?.id, sheetID)
        XCTAssertEqual(afterTrash.first?.trashed, true)
        await main.close()
    }

    /// Hinweis nach dem Schliessen nennt, wo das Blatt wieder auftaucht
    func testClosedHintSaysWhereTheSheetIs() {
        let text = DocumentView.sheetClosedHint("Notizen – Folien")
        XCTAssertTrue(text.contains("„Notizen – Folien“ ist gespeichert"))
        XCTAssertTrue(text.contains("Deine Blätter"))
        XCTAssertTrue(text.contains("Eigene Notizen"))
    }

    // MARK: Seiten im Blatt daneben

    /// "+" im Kopf des Blatts daneben: Vorlage der angezeigten Leerseite, sonst "blank"
    func testAddPageBelowUsesTemplateOfShownPage() async throws {
        let e = try env()
        let sheet = try await newSheet(e)
        let entries = sheet.layout?.entries
        XCTAssertEqual(CompanionAddPageButton.template(entries, at: 0), "grid")
        XCTAssertEqual(CompanionAddPageButton.template(entries, at: 9), "grid", "ausserhalb: wie die letzte Seite")
        XCTAssertEqual(CompanionAddPageButton.template(nil, at: 0), "blank")
        await sheet.close()
    }

    // MARK: Loesung anderer auf der eigenen PDF

    /// Eigene Kopie derselben PDF (gleicher Fingerabdruck): die Seite der fremden Loesung steht auf der eigenen
    /// PDF-Seite; ein anderer Fingerabdruck findet nichts (leere Seite mit Hinweis). Nichts wird hochgeladen.
    func testForeignSolutionUsesOwnCopyOfThePDF() async throws {
        let e = try env()
        let data = slides(3)
        let source = e.root.appendingPathComponent("Folien.pdf")
        try data.write(to: source)
        let staged = try ExternalFileImport.stage(source, container: nil)
        let id = try await ExternalFileImport.create(staged, api: e.api, moduleID: nil, folderID: nil)
        let sha = SolutionSHA256.hex(data)
        let backend = try await e.host.backend()
        try await backend.context.database.withConnection { try $0.execute("UPDATE files SET content_sha256=? WHERE id=?", [.text(sha), .text(id)]) }

        let own = try await XCTUnwrapAsync(await CommunityCourses.localPDF(fingerprint: sha, host: e.host))
        XCTAssertEqual(own.id, id)
        let missing = await CommunityCourses.localPDF(fingerprint: String(repeating: "0", count: 64), host: e.host)
        XCTAssertNil(missing, "andere PDF: keine eigene Kopie")

        let pdf = OffscreenPDF(url: own.url)
        let count = await pdf.pageCount()
        XCTAssertEqual(count, 3)
        let stroke: JSONValue = ["type": "stroke", "points": [60, 60, 300, 60], "color": "#000000", "width": 6]
        let page = SolutionPage(key: "p2", kind: .pdf, pdfIndex: 2, width: 960, height: 540, rotation: 0, objects: [stroke])
        let withPDF = await pdf.solutionPreview(page, images: [:], width: 480, scale: 1)
        let blank = SolutionPreview.image(page, images: [:], width: 480, scale: 1)
        XCTAssertTrue(isBlue(withPDF, at: CGPoint(x: 240, y: 200)), "eigene PDF-Seite als Hintergrund")
        XCTAssertFalse(isBlue(blank, at: CGPoint(x: 240, y: 200)), "ohne eigene PDF: weiss")
    }

    private func XCTUnwrapAsync<T>(_ v: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
        try XCTUnwrap(v, file: file, line: line)
    }

    private func isBlue(_ image: UIImage, at p: CGPoint) -> Bool {
        guard let cg = image.cgImage else { return false }
        let scale = CGFloat(cg.width) / image.size.width
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: -p.x * scale, y: -(CGFloat(cg.height) - p.y * scale - 1), width: CGFloat(cg.width), height: CGFloat(cg.height)))
        return Int(px[2]) - Int(px[0]) > 25
    }
}
