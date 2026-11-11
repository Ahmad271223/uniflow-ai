import PDFKit
import PencilKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Verbesserungen am Editor vom 10.11.2026 (docs/EDITOR-VERBESSERUNGEN-2026-11-10.md): Laden beim schnellen Blaettern,
/// Suche in eigenen Notizen, Tasten und Menues, Sichern und Drucken, Bilder und Zwischenablage, ein Lasso,
/// Zoom-Fenster.
@MainActor
final class EditorVerbesserungTests: XCTestCase {

    // MARK: Aufbau

    static func pdf(pages: Int, text: (Int) -> String = { "Satz des Pythagoras \($0)" }) -> Data {
        let raw = NSMutableData()
        let size = CGSize(width: 595, height: 842)
        UIGraphicsBeginPDFContextToData(raw, CGRect(origin: .zero, size: size), nil)
        for i in 1...pages {
            UIGraphicsBeginPDFPageWithInfo(CGRect(origin: .zero, size: size), nil)
            text(i).draw(at: CGPoint(x: 100, y: 200), withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
        }
        UIGraphicsEndPDFContext()
        return raw as Data
    }

    func openStore(pages: Int = 3, pdfData: Data? = nil, withFiles: Bool = false) async throws -> DocumentStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-verb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let clock: UniFlowClock = .fixed(berlin: "2026-11-10T09:00:00")!
        let host: LocalBackendHost
        if withFiles {
            // mit Ablage fuer Dateien (Bilder der Notizen), wie in der App
            let layout = DataContainerLayout(base: root.appendingPathComponent("c", isDirectory: true),
                                             key: DataContainerKey(userID: "001234.erfunden.verb", university: .luh))
            try layout.prepare(clock: clock)
            host = LocalBackendHost(directory: layout.databaseDirectory, clock: clock, files: .container(layout), university: .luh)
        } else {
            host = LocalBackendHost(directory: root.appendingPathComponent("db", isDirectory: true), clock: clock)
        }
        let backend = try await host.backend()
        let fileID = "verb-" + UUID().uuidString.prefix(8).lowercased()
        try await backend.context.database.transaction { c in
            try c.execute("INSERT OR IGNORE INTO courses(id, title, semester, subject, kind, created_at) VALUES (?,?,?,?,?,?)",
                          [.text("k-test"), .text("Testkurs"), .text("WiSe 2026/27"), .text("Testkurs"), .text("vorlesung"),
                           .text("2026-10-01T08:00:00")])
            try c.execute("INSERT INTO files(id, course_id, name, chdate, status, kind, downloaded_at) VALUES (?,?,?,?, 'neu', 'pdf', ?)",
                          [.text(fileID), .text("k-test"), .text("Skript.pdf"), .integer(1_792_000_000), .text("2026-11-10T08:00:00")])
        }
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
        let pdfURL = AppPaths.pdf(fileID, namespace: api.namespace, root: root)
        try FileManager.default.createDirectory(at: pdfURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (pdfData ?? Self.pdf(pages: pages)).write(to: pdfURL)
        try DocumentStore.stamp(try await api.value("/api/files/\(fileID)")).write(to: pdfURL.appendingPathExtension("stand"), atomically: true, encoding: .utf8)
        let file = LibFile(id: fileID, name: "Skript.pdf", title: "Skript", kind: "pdf", module_id: nil, subject: "Testkurs",
                           doc_type: nil, ai_title: nil, sub_label: nil, downloaded_at: "2026-11-10T08:00:00", has_notes: nil,
                           page_count: pages, studip_folder: nil)
        let store = DocumentStore(file: file, api: api, root: root)
        await store.load()
        XCTAssertNil(store.errorMessage, store.errorMessage ?? "")
        addTeardownBlock { await store.close() }
        return store
    }

    func openEditor(pages: Int = 3) async throws -> (DocumentStore, PDFEditorController) {
        let store = try await openStore(pages: pages)
        let editor = PDFEditorController(store: store)
        editor.loadViewIfNeeded()
        return (store, editor)
    }

    func wait(_ what: String, timeout: Double = 5, _ cond: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline { if await cond() { return }; try await Task.sleep(nanoseconds: 30_000_000) }
        XCTFail("Zeit abgelaufen: \(what)")
    }

    static func line(from a: CGPoint, to b: CGPoint, ink: PKInk = PKInk(.pen, color: .blue)) -> PKStroke {
        let pts = (0...10).map { i -> PKStrokePoint in
            let t = CGFloat(i) / 10
            return PKStrokePoint(location: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), timeOffset: Double(i) * 0.01,
                                 size: CGSize(width: 3, height: 3), opacity: 1, force: 0.5, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: pts, creationDate: Date(timeIntervalSinceReferenceDate: 800_000_000)))
    }

    // MARK: Schnelles Blaettern (M4)

    /// Eine Seite, die schon wieder aus dem Bild ist, bevor ihr Laden begann, laedt nicht (spart das Dekodieren voller
    /// Seiten beim schnellen Blaettern); beim Wiederanzeigen laedt sie mit ihrem Stand.
    func testPageScrolledAwayBeforeLoadingLoadsWhenShownAgain() async throws {
        let (store, editor) = try await openEditor(pages: 3)
        let drawing = PKDrawing(strokes: [Self.line(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 300, y: 300))])
        store.canvasChanged(pageKey: "p2", drawing: drawing)
        let page = try XCTUnwrap(editor.pdfView.document?.page(at: 1))
        let overlay = try XCTUnwrap(editor.pdfView(editor.pdfView, overlayViewFor: page) as? PageInkView)
        editor.pdfView(editor.pdfView, willEndDisplayingOverlayView: overlay, for: page)   // gleich wieder weg
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(overlay.loaded, "weggescrollte Seite laedt nicht")
        XCTAssertNil(overlay.loadTask, "kein Laden mehr unterwegs")

        let again = try XCTUnwrap(editor.pdfView(editor.pdfView, overlayViewFor: page) as? PageInkView)
        XCTAssertTrue(again === overlay, "geparktes Overlay wird wiederverwendet")
        try await wait("Seite laedt beim Wiederanzeigen") { overlay.loaded }
        XCTAssertEqual(overlay.canvas.drawing.strokes.count, 1)
    }

    /// Gegenprobe: eine sichtbare Seite laedt wie bisher
    func testVisiblePageLoads() async throws {
        let (store, editor) = try await openEditor(pages: 2)
        store.canvasChanged(pageKey: "p1", drawing: PKDrawing(strokes: [Self.line(from: .zero, to: CGPoint(x: 100, y: 100))]))
        let overlay = try XCTUnwrap(editor.overlayForTesting(at: 0))
        try await wait("sichtbare Seite laedt") { overlay.loaded }
        XCTAssertEqual(overlay.canvas.drawing.strokes.count, 1)
    }

    // MARK: Suche in eigenen Notizen

    func testSnippetsIgnoreCaseAccentsAndLineBreaks() {
        let text = "Erste Zeile\nDer Satz des\nPYTHÁGORAS gilt im rechtwinkligen Dreieck"
        let s = NoteSearch.snippets(in: text, query: "satz des pythagoras")
        XCTAssertEqual(s.count, 1)
        XCTAssertTrue(s[0].contains("Satz des PYTHÁGORAS"), s[0])
        XCTAssertTrue(NoteSearch.snippets(in: text, query: "x").isEmpty, "ein Zeichen sucht nicht")
        XCTAssertTrue(NoteSearch.snippets(in: text, query: "Kreis").isEmpty)
    }

    func testTypedTextComesFromTextFieldsAndStickies() {
        let objects: [JSONValue] = [PageObjectEdit.text(id: "a", x: 1, y: 1, text: "Klausur am Freitag"),
                                    PageObjectEdit.sticky(id: "b", x: 5, y: 5, text: "Ableitung prüfen"),
                                    PageObjectEdit.text(id: "c", x: 9, y: 9, text: "   ")]
        XCTAssertEqual(NoteSearch.typedText(objects), "Klausur am Freitag\nAbleitung prüfen")
    }

    /// Textfelder werden sofort gefunden, Handschrift nach der Erkennung (hier ersetzt), PDF-Treffer bleiben getrennt
    func testIndexFindsTextFieldsAndHandwriting() async throws {
        let store = try await openStore(pages: 3)
        await store.editObjects(pageKey: "p2") { $0 + [PageObjectEdit.text(id: "t1", x: 50, y: 50, text: "Klausur am Freitag")] }
        store.canvasChanged(pageKey: "p3", drawing: PKDrawing(strokes: [Self.line(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 300, y: 60))]))
        let index = store.noteIndex
        var seen = 0
        index.recognize = { _ in seen += 1; return "Integral von\nnull bis eins" }
        index.refresh(store: store)
        try await wait("Erkennung fertig") { index.reading == nil && index.pages["p3"]?.handwriting.isEmpty == false }
        let typed = index.hits("klausur", layout: store.layout)
        XCTAssertEqual(typed.map(\.pageIndex), [1])
        XCTAssertEqual(typed.first?.source, .typed)
        XCTAssertNil(typed.first?.selection)
        let ink = index.hits("von null", layout: store.layout)
        XCTAssertEqual(ink.map(\.pageIndex), [2], "Zeilenumbruch der Erkennung stoert nicht")
        XCTAssertEqual(ink.first?.source, .handwriting)
        XCTAssertEqual(seen, 1, "nur die Seite mit Strichen wird gelesen (PDF-Seiten haben Text, kein Scan)")

        index.refresh(store: store)                                       // nichts geaendert: nicht erneut lesen
        try await Task.sleep(nanoseconds: 300_000_000)
        try await wait("zweiter Durchgang fertig") { index.reading == nil }
        XCTAssertEqual(seen, 1, "unveraenderte Handschrift wird nicht neu gelesen")
        XCTAssertFalse(store.search("Pythagoras").isEmpty, "PDF-Suche wie bisher")
    }

    /// Eingescannte Seite (nur Bild, keine Textebene): echte Texterkennung von Vision findet das Wort
    func testScannedPageIsReadWithVision() async throws {
        let raw = NSMutableData()
        let size = CGSize(width: 595, height: 842)
        let picture = UIGraphicsImageRenderer(size: CGSize(width: 500, height: 120)).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 500, height: 120))
            "Eigenwertproblem".draw(at: CGPoint(x: 20, y: 30), withAttributes: [.font: UIFont.systemFont(ofSize: 44), .foregroundColor: UIColor.black])
        }
        UIGraphicsBeginPDFContextToData(raw, CGRect(origin: .zero, size: size), nil)
        UIGraphicsBeginPDFPageWithInfo(CGRect(origin: .zero, size: size), nil)
        picture.draw(in: CGRect(x: 40, y: 100, width: 500, height: 120))
        UIGraphicsEndPDFContext()
        let store = try await openStore(pages: 1, pdfData: raw as Data)
        XCTAssertTrue(NoteSearch.needsScanOCR(try XCTUnwrap(store.layout?.pdf.page(at: 0))), "Seite ohne Textebene")
        XCTAssertTrue(store.search("Eigenwert").isEmpty, "PDF-Suche findet im Bild nichts")
        store.noteIndex.refresh(store: store)
        try await wait("Scan gelesen", timeout: 30) { store.noteIndex.reading == nil && store.noteIndex.pages["p1"]?.scan.isEmpty == false }
        let hits = store.noteIndex.hits("eigenwert", layout: store.layout)
        XCTAssertEqual(hits.first?.source, .scan, "\(store.noteIndex.pages)")
    }

    // MARK: Werkzeuge per Menue und Tastatur

    func testToolShortcutsAreCommandDigitsOneToEight() {
        XCTAssertEqual(EditorTool.allCases.map { String($0.shortcut.character) }, ["1", "2", "3", "4", "5", "6", "7", "8"])
        XCTAssertEqual(Set(EditorTool.allCases.map(\.title)).count, EditorTool.allCases.count)
    }

    func testChooseToolSwitchesInkAndObjectTools() async throws {
        let (_, editor) = try await openEditor(pages: 1)
        editor.choose(.marker)
        XCTAssertEqual(editor.chosenTool, .marker)
        XCTAssertFalse(editor.objects.isActive)
        editor.choose(.text)
        XCTAssertTrue(editor.objects.isActive, "Text ist ein Objektwerkzeug")
        XCTAssertEqual(editor.objects.tool, .text)
        XCTAssertEqual(editor.chosenTool, .text)
        editor.choose(.eraser)
        XCTAssertFalse(editor.objects.isActive, "Radierer verlaesst den Objektmodus")
        XCTAssertEqual(editor.chosenTool, .eraser)
        editor.choose(.pen)
        XCTAssertEqual(editor.chosenTool, .pen)
        editor.canEdit = false
        editor.choose(.text)
        XCTAssertFalse(editor.objects.isActive, "ohne Schreiben im Tarif keine Werkzeuge")
    }

    func testDeleteAndEscapeKeysOnlyWithSelectionOrObjectMode() async throws {
        let (store, editor) = try await openEditor(pages: 1)
        let titles = editor.editorKeyCommands.map(\.title)
        XCTAssertTrue(titles.contains("Auswahl löschen"))
        XCTAssertTrue(titles.contains("Objekte fertig"))
        XCTAssertFalse(editor.canPerformAction(#selector(PDFEditorController.deleteSelectedObjects(_:)), withSender: nil))
        XCTAssertFalse(editor.canPerformAction(#selector(PDFEditorController.finishObjectsKey(_:)), withSender: nil))
        XCTAssertFalse(editor.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil), "ohne Auswahl")
        await store.editObjects(pageKey: "p1") { $0 + [PageObjectEdit.text(id: "t1", x: 50, y: 50, text: "Hallo")] }
        editor.choose(.select)
        await editor.objects.selectForTesting(key: "p1", ids: ["t1"])
        XCTAssertTrue(editor.canPerformAction(#selector(PDFEditorController.deleteSelectedObjects(_:)), withSender: nil))
        XCTAssertTrue(editor.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil))
        editor.deleteSelectedObjects(nil)
        try await wait("Objekt geloescht") { await store.objects(forPageKey: "p1").isEmpty }
        editor.finishObjectsKey(nil)
        XCTAssertFalse(editor.objects.isActive, "Esc beendet den Objektmodus")
    }

    // MARK: Zwischenablage, ein Lasso, Bilder

    private func board() -> UIPasteboard {
        let pb = UIPasteboard(name: UIPasteboard.Name("verb-\(UUID().uuidString)"), create: true)!
        addTeardownBlock { UIPasteboard.remove(withName: pb.name) }
        return pb
    }

    func testCopyPasteDuplicateCutObjects() async throws {
        let (store, editor) = try await openEditor(pages: 2)
        let pb = board()
        await store.editObjects(pageKey: "p1") { $0 + [PageObjectEdit.text(id: "t1", x: 50, y: 50, text: "Merksatz")] }
        editor.choose(.select)
        await editor.objects.selectForTesting(key: "p1", ids: ["t1"])
        let copied = await editor.objects.copySelection(to: pb)
        XCTAssertTrue(copied)
        XCTAssertEqual(pb.string, "Merksatz", "Textfelder auch als einfacher Text")
        let pasted = await editor.objects.paste(on: "p2", at: CGPoint(x: 200, y: 300), pasteboard: pb)
        XCTAssertTrue(pasted)
        let p2 = await store.objects(forPageKey: "p2")
        XCTAssertEqual(p2.count, 1)
        XCTAssertNotEqual(p2.first?["id"]?.string, "t1", "neue Kennung")
        XCTAssertEqual(p2.first?["x"]?.double ?? 0, 200, accuracy: 0.5)
        XCTAssertEqual(p2.first?["y"]?.double ?? 0, 300, accuracy: 0.5)
        XCTAssertEqual(editor.objects.selection?.key, "p2", "Eingefuegtes ist ausgewaehlt")

        await editor.objects.selectForTesting(key: "p1", ids: ["t1"])
        await editor.objects.duplicateSelection()
        let p1 = await store.objects(forPageKey: "p1")
        XCTAssertEqual(p1.count, 2)
        XCTAssertEqual(p1.last?["x"]?.double ?? 0, (p1.first?["x"]?.double ?? 0) + 20, accuracy: 0.5)

        await editor.objects.selectForTesting(key: "p1", ids: ["t1"])
        await editor.objects.cutSelection(to: pb)
        try await wait("ausgeschnitten") { await store.objects(forPageKey: "p1").count == 1 }
    }

    func testPastePlainTextBecomesTextField() async throws {
        let (store, editor) = try await openEditor(pages: 1)
        let pb = board()
        pb.string = "aus einer anderen App"
        let ok = await editor.objects.paste(on: "p1", at: CGPoint(x: 80, y: 90), pasteboard: pb)
        XCTAssertTrue(ok)
        let text = await store.objects(forPageKey: "p1").first?["text"]?.string
        XCTAssertEqual(text, "aus einer anderen App")
    }

    func testLassoPicksStrokesInside() {
        let inside = Self.line(from: CGPoint(x: 110, y: 110), to: CGPoint(x: 180, y: 150))
        let outside = Self.line(from: CGPoint(x: 400, y: 400), to: CGPoint(x: 500, y: 500))
        let half = Self.line(from: CGPoint(x: 150, y: 150), to: CGPoint(x: 350, y: 150))       // nur ein Viertel drin
        let poly: [(x: Double, y: Double)] = [(100, 100), (200, 100), (200, 200), (100, 200)]
        XCTAssertEqual(ObjectEditing.strokes(of: PKDrawing(strokes: [inside, outside, half]), inLasso: poly), [0])
    }

    /// Lasso greift Handschrift und Textfeld; Verschieben bewegt beides, Loeschen entfernt beides
    func testOneSelectionMovesAndDeletesInkAndObjects() async throws {
        let (store, editor) = try await openEditor(pages: 1)
        await store.editObjects(pageKey: "p1") { $0 + [PageObjectEdit.text(id: "t1", x: 50, y: 50, text: "Notiz")] }
        let overlay = try XCTUnwrap(editor.overlayForTesting(at: 0))
        store.canvasChanged(pageKey: "p1", drawing: PKDrawing(strokes: [Self.line(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 120))]))
        try await wait("geladen") { overlay.loaded && !overlay.canvas.drawing.strokes.isEmpty }
        editor.choose(.select)
        editor.objects.select(key: "p1", ids: ["t1"], in: await store.objects(forPageKey: "p1"), ink: [0])
        XCTAssertTrue(editor.objects.hasSelection)
        let before = overlay.canvas.drawing.strokes[0].renderBounds
        editor.objects.finishMove(dx: 30, dy: 10)
        try await wait("verschoben") { abs(overlay.canvas.drawing.strokes[0].renderBounds.minX - before.minX - 30) < 0.5 }
        try await wait("Objekt verschoben") { await store.objects(forPageKey: "p1").first?["x"]?.double == 80 }
        let saved = await store.drawing(forPageKey: "p1")
        XCTAssertEqual(saved.strokes.first.map { $0.renderBounds.minY } ?? 0, before.minY + 10, accuracy: 0.5, "Store hat den neuen Stand")
        editor.objects.select(key: "p1", ids: ["t1"], in: await store.objects(forPageKey: "p1"), ink: [0])
        editor.objects.deleteSelection()
        try await wait("geloescht") { overlay.canvas.drawing.strokes.isEmpty }
        try await wait("Objekt geloescht") { await store.objects(forPageKey: "p1").isEmpty }
    }

    func testInsertImageUploadsAndPlacesImageObject() async throws {
        let store = try await openStore(pages: 1, withFiles: true)
        let editor = PDFEditorController(store: store)
        editor.loadViewIfNeeded()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 400)).image { ctx in
            UIColor.systemTeal.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 400))
        }
        let ok = await editor.objects.insertImage(image, on: "p1", at: CGPoint(x: 40, y: 60))
        XCTAssertTrue(ok)
        let first = await store.objects(forPageKey: "p1").first
        let o = try XCTUnwrap(first)
        XCTAssertEqual(o["type"]?.string, "image")
        let src = try XCTUnwrap(o["src"]?.string)
        XCTAssertTrue(src.hasPrefix("/api/assets/"), src)
        XCTAssertNotNil(store.images[src], "Bild liegt gleich im Zwischenspeicher")
        XCTAssertLessThanOrEqual(o["width"]?.double ?? 999, 595 * 0.5 + 0.5, "hoechstens halbe Seitenbreite")
        let (data, http) = try await store.api.data(src)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertNotNil(UIImage(data: data), "vom lokalen Server wieder lesbar")
    }

    // MARK: Rechtsklick und Mauszeiger

    func testContextMenuOffersPageOrObjectActions() async throws {
        let (store, editor) = try await openEditor(pages: 1)
        await store.editObjects(pageKey: "p1") { $0 + [PageObjectEdit.text(id: "t1", x: 50, y: 50, text: "Hallo")] }
        let overlay = try XCTUnwrap(editor.overlayForTesting(at: 0))
        try await wait("geladen") { overlay.loaded && !overlay.objectsView.shownObjects.isEmpty }
        func titles(_ m: UIMenu) -> [String] { m.children.flatMap { ($0 as? UIMenu)?.children ?? [$0] }.compactMap { ($0 as? UIAction)?.title } }
        let empty = titles(editor.mouseSupport.menu(on: overlay, at: CGPoint(x: 400, y: 600)))
        XCTAssertTrue(empty.contains("Text hier"), "\(empty)")
        XCTAssertTrue(empty.contains("Bild einfügen …"))
        XCTAssertTrue(empty.contains("Seite drehen"))
        let onObject = titles(editor.mouseSupport.menu(on: overlay, at: CGPoint(x: 55, y: 55)))
        XCTAssertTrue(onObject.contains("Kopieren"), "\(onObject)")
        XCTAssertTrue(onObject.contains("Nach vorne"))
        XCTAssertEqual(editor.objects.selection?.ids, ["t1"], "Rechtsklick waehlt das Objekt")
        editor.canEdit = false
        editor.objects.clearSelection()
        let viewOnly = titles(editor.mouseSupport.menu(on: overlay, at: CGPoint(x: 400, y: 600)))
        XCTAssertFalse(viewOnly.contains("Text hier"), "nur ansehen: nichts zum Schreiben")
    }

    func testCursorFollowsTool() async throws {
        let (_, editor) = try await openEditor(pages: 1)
        editor.choose(.text)
        XCTAssertEqual(EditorMouseSupport.cursor(for: editor), .beam)
        editor.choose(.shape)
        XCTAssertEqual(EditorMouseSupport.cursor(for: editor), .cross)
        editor.choose(.pen)
        XCTAssertNil(EditorMouseSupport.cursor(for: editor))
    }

    // MARK: Sichern und Drucken

    func testExportPurposesAndPrintInfo() {
        XCTAssertEqual(ExportPurpose.save.confirmTitle, "Sichern …")
        XCTAssertEqual(ExportPurpose.print.confirmTitle, "Drucken …")
        XCTAssertEqual(PDFPrinting.printInfo(title: "Skript").jobName, "Skript")
    }

    // MARK: Schreiblupe

    func testMagnifierGeometry() {
        let size = WritingMagnifier.regionSize(stripSize: CGSize(width: 900, height: 190))
        XCTAssertEqual(size.width, 300, accuracy: 0.01)
        XCTAssertEqual(size.height, 300 * 190 / 900, accuracy: 0.01)
        let t = WritingMagnifier.pageTransform(strip: CGSize(width: 900, height: 190), region: CGRect(x: 30, y: 100, width: 300, height: 63))
        let p = CGPoint(x: 450, y: 30).applying(t)
        XCTAssertEqual(p.x, 180, accuracy: 0.01)
        XCTAssertEqual(p.y, 110, accuracy: 0.01)
    }

    /// Im Streifen Geschriebenes landet verkleinert im Rahmen der Seite, ein Rueckgaengig-Schritt
    func testMagnifierTransfersStrokesIntoTheFrame() async throws {
        let (store, editor) = try await openEditor(pages: 1)
        let overlay = try XCTUnwrap(editor.overlayForTesting(at: 0))
        try await wait("geladen") { overlay.loaded }
        editor.choose(.pen)
        var opened: Bool?
        editor.onMagnifierChange = { opened = $0 }
        editor.setMagnifier(true)
        let m = try XCTUnwrap(editor.magnifier)
        XCTAssertEqual(opened, true)
        XCTAssertTrue(m.canvas.isUserInteractionEnabled, "Stift schreibt im Streifen")
        m.setRegion(CGRect(x: 30, y: 100, width: 200, height: 50))
        editor.view.layoutIfNeeded()
        let strip = m.canvas.bounds.size
        XCTAssertGreaterThan(strip.width, 100)
        m.canvas.drawing = PKDrawing(strokes: [Self.line(from: CGPoint(x: 10, y: 10), to: CGPoint(x: strip.width * 0.4, y: 20))])
        m.transfer()
        try await wait("uebertragen") { overlay.canvas.drawing.strokes.count == 1 }
        XCTAssertTrue(m.canvas.drawing.strokes.isEmpty, "Streifen wieder leer")
        let b = overlay.canvas.drawing.strokes[0].renderBounds
        XCTAssertTrue(CGRect(x: 25, y: 95, width: 210, height: 60).contains(b), "Strich liegt im Rahmen: \(b)")
        XCTAssertLessThan(b.width, strip.width * 0.4, "verkleinert")
        XCTAssertEqual(m.region.minX, 30, accuracy: 0.01, "nicht am rechten Rand: Rahmen bleibt")
        let saved = await store.drawing(forPageKey: "p1")
        XCTAssertEqual(saved.strokes.count, 1)

        // am rechten Rand rueckt der Rahmen weiter
        m.canvas.drawing = PKDrawing(strokes: [Self.line(from: CGPoint(x: strip.width * 0.5, y: 10), to: CGPoint(x: strip.width * 0.95, y: 20))])
        m.transfer()
        try await wait("weitergerueckt") { m.region.minX > 30 }

        editor.choose(.eraser)
        XCTAssertFalse(m.canvas.isUserInteractionEnabled, "Radierer: auf der Seite, nicht im Streifen")
        editor.setMagnifier(false)
        XCTAssertNil(editor.magnifier)
        XCTAssertEqual(opened, false)
    }

    // MARK: Texte am Mac

    func testDeviceWordingOnMac() {
        XCTAssertEqual(UFDevice.adapt("Bleibt auf diesem iPad.", mac: true), "Bleibt auf diesem Mac.")
        XCTAssertEqual(UFDevice.adapt("holt sie auf dieses iPad.", mac: true), "holt sie auf diesen Mac.")
        XCTAssertEqual(UFDevice.adapt("im Schlüsselbund dieses iPads", mac: true), "im Schlüsselbund dieses Macs")
        XCTAssertEqual(UFDevice.adapt("direkt auf dein iPad.", mac: true), "direkt auf deinen Mac.")
        XCTAssertEqual(UFDevice.adapt("Bleibt auf diesem iPad.", mac: false), "Bleibt auf diesem iPad.", "iPad unveraendert")
    }

    // MARK: Eigenes Fenster und Praesentation (11.11.2026)

    func testNewWindowRequestTravelsInActivityAndIsTakenOnce() {
        DocumentWindows.resetForTesting()
        let r = DocumentWindows.Request(id: "r1", fileID: "datei-7", page: 4)
        let a = DocumentWindows.activity(for: r)
        XCTAssertEqual(a.activityType, "de.studinow.openDocument")
        XCTAssertEqual(DocumentWindows.request(from: a), r)
        XCTAssertEqual(DocumentWindows.route(for: r), .doc("datei-7", page: 4))
        XCTAssertNotNil(DocumentWindows.take(r))
        XCTAssertNil(DocumentWindows.take(r), "dieselbe Anfrage oeffnet nicht zwei Fenster")
        XCTAssertNil(DocumentWindows.request(from: NSUserActivity(activityType: "anderes")))
        XCTAssertNil(DocumentWindows.takePending(), "ohne offene Anfrage nichts")
        let types = Bundle.main.object(forInfoDictionaryKey: "NSUserActivityTypes") as? [String]
        XCTAssertEqual(types, ["de.studinow.openDocument"], "Typ in der Info.plist angemeldet")
    }

    func testPresentationFitAndKeys() {
        XCTAssertEqual(PDFEditorController.pageFitScale(page: CGSize(width: 595, height: 842), in: CGSize(width: 1200, height: 800)),
                       800 / 842 * 0.98, accuracy: 0.0001, "Hochformat auf Querbildschirm: Hoehe bestimmt")
        XCTAssertEqual(PDFEditorController.presentationCommand(.screenDown), .right)
        XCTAssertEqual(PDFEditorController.presentationCommand(.lineUp), .left)
        XCTAssertEqual(PDFEditorController.presentationCommand(.zoomIn), .zoomIn)
    }

    /// Praesentation: Palette weg, ganze Seite im Bild, Leertaste blaettert eine Seite; danach wie vorher
    func testPresentationModeHidesPaletteFitsPageAndTurnsPages() async throws {
        let store = try await openStore(pages: 3)
        let editor = PDFEditorController(store: store)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 1210, height: 834))
        window.frame = CGRect(x: 0, y: 0, width: 1210, height: 834)
        window.rootViewController = editor
        window.makeKeyAndVisible()
        addTeardownBlock { window.isHidden = true }
        window.layoutIfNeeded()
        try await wait("eingepasst", timeout: 10) {
            editor.view.layoutIfNeeded()
            return editor.pdfView.bounds.height > 300 && abs(editor.pdfView.scaleFactor - 1) > 0.001 && editor.pdfView.currentPage != nil
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let widthFit = editor.pdfView.scaleFactor
        XCTAssertTrue(editor.pickerAllowed)
        editor.presentationMode = true
        XCTAssertFalse(editor.pickerAllowed, "keine Palette in der Praesentation")
        let page = try XCTUnwrap(editor.pdfView.currentPage)
        let shown = PageRenderer.size(of: page)
        XCTAssertLessThanOrEqual(shown.height * editor.pdfView.scaleFactor, editor.pdfView.bounds.height + 1, "ganze Seite im Bild")
        XCTAssertLessThan(editor.pdfView.scaleFactor, widthFit, "Querformat-Fenster: kleiner als Seitenbreite")
        let before = editor.currentPageIndex
        editor.perform(PDFEditorController.presentationCommand(.screenDown), animated: false)
        try await wait("naechste Seite") { editor.currentPageIndex == before + 1 }
        editor.presentationMode = false
        XCTAssertTrue(editor.pickerAllowed)
        XCTAssertEqual(editor.pdfView.scaleFactor, widthFit, accuracy: 0.01, "zurueck auf Seitenbreite")
    }
}
