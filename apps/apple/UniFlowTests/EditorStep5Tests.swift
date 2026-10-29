import PDFKit
import PencilKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Editor, Schritt 5 (docs/PENCILKIT-ANALYSE-PLAN.md P1-1 bis P1-3) im echten Weg: Store mit lokalem Backend, Editor
/// geladen. Seitenwerkzeuge wie im Web-Editor (kopieren, verschieben, leeren, Vorlage, Format, Leerseite davor/am
/// Ende, Gliederung), im Browser eingefuegte PDF-Seiten mit Inhalt. Alle Daten sind erfunden.
@MainActor
final class EditorStep5Tests: XCTestCase {

    private func pdf(pages: Int, size: CGSize = CGSize(width: 595, height: 842), marker: String) -> Data {
        let raw = NSMutableData()
        UIGraphicsBeginPDFContextToData(raw, CGRect(origin: .zero, size: size), nil)
        for i in 1...pages {
            UIGraphicsBeginPDFPageWithInfo(CGRect(origin: .zero, size: size), nil)
            "\(marker) \(i)".draw(at: CGPoint(x: 40, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }
        UIGraphicsEndPDFContext()
        return raw as Data
    }

    private struct Fixture {
        let store: DocumentStore
        let editor: PDFEditorController
        let api: APIClient
        let fileID: String
    }

    private func open(pages: Int = 3) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-schritt5-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let clock = UniFlowClock.fixed(berlin: "2026-10-29T09:00:00")!
        // mit Dateiablage (Bilder und PDFs eingefuegter Seiten)
        let layout = DataContainerLayout(base: root, key: DataContainerKey(userID: "001234.erfunden.s5", university: .luh))
        try layout.prepare(clock: clock)
        let host = LocalBackendHost(directory: layout.databaseDirectory, clock: clock, files: .container(layout), university: .luh)
        let backend = try await host.backend()
        let fileID = "schritt5-" + UUID().uuidString.prefix(8).lowercased()
        try await backend.context.database.transaction { c in
            try c.execute("INSERT OR IGNORE INTO courses(id, title, semester, subject, kind, created_at) VALUES (?,?,?,?,?,?)",
                          [.text("k-test"), .text("Testkurs"), .text("WiSe 2026/27"), .text("Testkurs"), .text("vorlesung"),
                           .text("2026-10-01T08:00:00")])
            try c.execute("INSERT INTO files(id, course_id, name, chdate, status, kind, downloaded_at) VALUES (?,?,?,?, 'neu', 'pdf', ?)",
                          [.text(fileID), .text("k-test"), .text("Skript.pdf"), .integer(1_792_000_000), .text("2026-10-29T08:00:00")])
        }
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
        let pdfURL = AppPaths.pdf(fileID, namespace: api.namespace, root: root)
        try FileManager.default.createDirectory(at: pdfURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pdf(pages: pages, marker: "Skript").write(to: pdfURL)
        try DocumentStore.stamp(try await api.value("/api/files/\(fileID)")).write(to: pdfURL.appendingPathExtension("stand"), atomically: true, encoding: .utf8)
        let file = LibFile(id: fileID, name: "Skript.pdf", title: "Skript", kind: "pdf", module_id: nil, subject: "Testkurs",
                           doc_type: nil, ai_title: nil, sub_label: nil, downloaded_at: "2026-10-29T08:00:00", has_notes: nil,
                           page_count: pages, studip_folder: nil)
        let store = DocumentStore(file: file, api: api, root: root)
        await store.load()
        XCTAssertNil(store.errorMessage, store.errorMessage ?? "")
        let editor = PDFEditorController(store: store)
        editor.loadViewIfNeeded()
        return Fixture(store: store, editor: editor, api: api, fileID: fileID)
    }

    private func keys(_ fx: Fixture) -> [String] { fx.store.layout?.entries.map(\.key) ?? [] }

    // MARK: P1-1 Seitenwerkzeuge

    /// Kopieren, verschieben, Leerseite davor und am Ende, wieder verschieben: Reihenfolge wie im Web, die Kopie traegt
    /// die Notizen mit neuen IDs. Gegenprobe: Verschieben ueber den Rand und unbekannte Seiten aendern nichts.
    func testDuplicateMoveAndInsertPages() async throws {
        let fx = try await open()
        await fx.store.addText("Original", pageKey: "p1")
        let copied = await fx.editor.duplicatePage(key: "p1")
        XCTAssertTrue(copied)
        let afterCopy = keys(fx)
        XCTAssertEqual(afterCopy.count, 4)
        let copy = afterCopy[1]
        XCTAssertTrue(copy.hasPrefix("p1c"))
        let objects = await fx.store.objects(forPageKey: copy)
        XCTAssertEqual(objects.first?["text"], "Original")
        let originalID = await fx.store.objects(forPageKey: "p1").first?["id"]
        XCTAssertNotEqual(objects.first?["id"], originalID, "neue ID")

        let moved = await fx.editor.movePage(key: copy, to: .last)
        XCTAssertTrue(moved)
        XCTAssertEqual(keys(fx), ["p1", "p2", "p3", copy])
        let movedFirst = await fx.editor.movePage(key: "p3", to: .first)
        XCTAssertTrue(movedFirst)
        XCTAssertEqual(keys(fx), ["p3", "p1", "p2", copy])
        let back = await fx.editor.movePage(key: "p3", to: .backward)
        XCTAssertTrue(back)
        XCTAssertEqual(keys(fx), ["p1", "p3", "p2", copy])
        let outside = await fx.editor.movePage(key: "p1", to: .forward)
        XCTAssertFalse(outside, "erste Seite nicht weiter nach vorn")
        let unknown = await fx.editor.duplicatePage(key: "fehlt")
        XCTAssertFalse(unknown)

        let before = await fx.editor.insertBlankPage(before: "p2", template: "grid")
        XCTAssertNotNil(before)
        XCTAssertEqual(keys(fx).firstIndex(of: before ?? ""), keys(fx).firstIndex(of: "p2").map { $0 - 1 })
        let end = await fx.editor.appendBlankPage(template: "dotted")
        XCTAssertEqual(keys(fx).last, end)
        XCTAssertEqual(fx.store.layout?.entries.last?.template, "dotted")
        await fx.store.close()
    }

    /// Leeren entfernt Text und Striche der Seite (mit Gegenprobe auf der Nachbarseite); Vorlage und Format nur fuer
    /// Leerseiten, PDF-Seiten bleiben unveraendert.
    func testClearTemplateAndFormat() async throws {
        let fx = try await open(pages: 2)
        await fx.store.addText("weg damit", pageKey: "p1")
        await fx.store.addText("bleibt", pageKey: "p2")
        var d = PKDrawing()
        d.strokes.append(Handschrift.line(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 150, y: 80),
                                          created: Date(timeIntervalSinceReferenceDate: 797_000_000)))
        fx.store.canvasChanged(pageKey: "p1", drawing: d)
        let cleared = await fx.editor.clearPage(key: "p1")
        XCTAssertTrue(cleared)
        let p1 = await fx.store.objects(forPageKey: "p1")
        let p2 = await fx.store.objects(forPageKey: "p2")
        XCTAssertTrue(p1.isEmpty, "Text und Strich weg")
        XCTAssertEqual(p2.first?["text"], "bleibt")
        let again = await fx.editor.clearPage(key: "p1")
        XCTAssertFalse(again, "schon leer")

        let appended = await fx.editor.appendBlankPage(template: "lined")
        let blank = try XCTUnwrap(appended)
        let templ = await fx.editor.setTemplate("grid", key: blank)
        XCTAssertTrue(templ)
        XCTAssertEqual(fx.store.layout?.entries.last?.template, "grid")
        let a5 = try XCTUnwrap(PageFormats.size("a5", .landscape))
        let format = await fx.editor.setFormat(CGSize(width: a5.width, height: a5.height), key: blank)
        XCTAssertTrue(format)
        let shown = try XCTUnwrap(fx.store.layout?.pdf.page(at: (fx.store.layout?.entries.count ?? 1) - 1)).bounds(for: .cropBox).size
        XCTAssertEqual(Double(shown.width), Double(a5.width), accuracy: 0.5)
        XCTAssertEqual(Double(shown.height), Double(a5.height), accuracy: 0.5)
        let pdfTemplate = await fx.editor.setTemplate("grid", key: "p2")
        XCTAssertFalse(pdfTemplate, "PDF-Seite bleibt PDF-Seite")
        XCTAssertEqual(fx.store.layout?.entries[1].kind, "pdf")
        await fx.store.close()
    }

    // MARK: P1-2 Gliederung

    func testOutlineAddJumpAndRemove() async throws {
        let fx = try await open()
        let added = await fx.editor.addOutline(title: "Kapitel 3", key: "p3")
        XCTAssertTrue(added)
        let empty = await fx.editor.addOutline(title: "  ", key: "p1")
        XCTAssertFalse(empty)
        var entries = await fx.editor.outlineEntries()
        XCTAssertEqual(entries.map(\.title), ["Kapitel 3"])
        XCTAssertEqual(entries.first?.index, 2)
        // die Gliederung wird mit der Seitenliste gespeichert (wie im Web)
        let doc = await fx.store.pageStructureDocument()
        XCTAssertEqual(doc.root["outline"]?.array?.first?["key"], "p3")
        let removed = await fx.editor.removeOutline(at: 0)
        XCTAssertTrue(removed)
        entries = await fx.editor.outlineEntries()
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(fx.editor.pageCount, 3)
        await fx.store.close()
    }

    // MARK: P1-3 eingefuegte PDF-Seiten aus dem Web

    /// Im Browser eingefuegte PDF-Seite (`type: "asset"`): das iPad laedt die Datei und zeigt die echte Seite (Groesse
    /// der Asset-Seite, Text darin) statt eines Platzhalters. Gegenprobe: ein fehlendes Asset bleibt Platzhalter.
    func testAssetPagesFromTheWebShowTheirContent() async throws {
        let fx = try await open(pages: 1)
        let asset = pdf(pages: 2, size: CGSize(width: 842, height: 595), marker: "Eingefuegt")
        let up = try await fx.api.upload("/api/files/\(fx.fileID)/assets", fields: [:], fileField: "upload", fileName: "anhang.pdf",
                                         mimeType: "application/pdf", data: asset)
        let url = try XCTUnwrap(up["url"]?.string)
        let change = await fx.store.applyPageStructure { doc in
            var order = doc.pageOrder
            order.append(["key": "aEins", "type": "asset", "assetUrl": .string(url), "index": 2, "w": 842, "h": 595])
            order.append(["key": "aFehlt", "type": "asset", "assetUrl": .string("/api/assets/\(fx.fileID)/gibtsnicht.pdf"), "index": 1, "w": 595, "h": 842])
            doc.root["pageOrder"] = .array(order)
            doc.pages["aEins"] = ["objects": []]
            doc.pages["aFehlt"] = ["objects": []]
            return PageOrder.Change(focusKey: "aEins", changedPageKeys: ["aEins", "aFehlt"])
        }
        XCTAssertNotNil(change)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, fx.store.layout?.entries.first(where: { $0.key == "aEins" })?.assetShown != true {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let layout = try XCTUnwrap(fx.store.layout)
        let i = try XCTUnwrap(layout.index(ofKey: "aEins"))
        XCTAssertEqual(layout.entry(at: i)?.assetShown, true)
        let page = try XCTUnwrap(layout.pdf.page(at: i))
        XCTAssertEqual(page.bounds(for: .cropBox).size.width, 842, accuracy: 0.5)
        XCTAssertTrue(page.string?.contains("Eingefuegt 2") == true, "zweite Seite der Datei, nicht die erste")
        let missing = try XCTUnwrap(layout.index(ofKey: "aFehlt"))
        XCTAssertEqual(layout.entry(at: missing)?.assetShown, false, "fehlende Datei: Platzhalter")
        await fx.store.close()
    }
}
