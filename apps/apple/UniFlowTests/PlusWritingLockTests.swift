import PDFKit
import PencilKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Tarif im Editor (docs/AUFTRAG-APPSTORE-V1.md, Abschnitt 4): Schreiben mit dem Pencil, Seiten und Lesezeichen nur
/// mit Plus. Free und nach dem Herabstufen: eigene Notizen sichtbar und exportierbar, aber nichts wird geschrieben.
/// Dazu: "Endgültig löschen" entfernt die Kopien des Dokuments auf dem Geraet. Nur erfundene Daten, lokales Backend
/// im Temp-Ordner.
@MainActor
final class PlusWritingLockTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-tarif-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func makePDFData() -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { ctx in
            for i in 1...3 {
                ctx.beginPage()
                ("Testblatt Seite \(i)" as NSString).draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
            }
        }
    }

    private struct Fixture {
        let store: DocumentStore
        let root: URL
        let api: APIClient
    }

    /// Eigenes Dokument im lokalen Backend mit der Test-PDF als Original-Datei im Zwischenspeicher
    private func makeStore() async throws -> Fixture {
        let root = try tempDir()
        let host = LocalBackendHost(directory: root.appendingPathComponent("db", isDirectory: true),
                                    clock: .fixed(berlin: "2026-10-25T14:30:05")!)
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
        let fileID = "tarif-" + UUID().uuidString.prefix(8).lowercased()
        let pdfURL = AppPaths.pdf(fileID, namespace: api.namespace, root: root)
        try FileManager.default.createDirectory(at: pdfURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makePDFData().write(to: pdfURL)
        let file = LibFile(id: fileID, name: "Blatt.pdf", title: "Blatt", kind: "pdf", module_id: nil, subject: nil, doc_type: nil,
                           ai_title: nil, sub_label: nil, downloaded_at: "2026-10-25", has_notes: nil, page_count: 3, studip_folder: nil)
        let store = DocumentStore(file: file, api: api, root: root)
        await store.load()
        XCTAssertNil(store.errorMessage)
        return Fixture(store: store, root: root, api: api)
    }

    private func serialized(_ store: DocumentStore) async -> Data {
        await store.flush()
        try? await Task.sleep(nanoseconds: 400_000_000)        // ausstehende Verarbeitung haette jetzt begonnen
        await store.flush()
        return (await store.pageStructureDocument()).root.serialized(sortedKeys: true)
    }

    /// Alle Dateien des Journals (relativer Pfad -> Bytes)
    private func journal(_ root: URL) -> [String: Data] {
        let dir = root.appendingPathComponent("journal", isDirectory: true).resolvingSymlinksInPath()
        var out: [String: Data] = [:]
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return out }
        for case let url as URL in e where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            out[String(url.resolvingSymlinksInPath().path.dropFirst(dir.path.count))] = try? Data(contentsOf: url)
        }
        return out
    }

    private func waitLoaded(_ overlay: PageInkView, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<300 where !overlay.loaded { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(overlay.loaded, "Overlay geladen", file: file, line: line)
    }

    /// Strich wie mit dem Stift: Canvas aendert sich, PencilKit meldet die Aenderung
    private func drawStroke(_ editor: PDFEditorController, on overlay: PageInkView, y: CGFloat) {
        let pts = (0..<20).map { i in
            PKStrokePoint(location: CGPoint(x: 80 + CGFloat(i) * 3, y: y), timeOffset: Double(i) * 0.01, size: CGSize(width: 3, height: 3),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        var d = overlay.canvas.drawing
        d.strokes.append(PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: pts, creationDate: Date())))
        overlay.isApplyingDrawing = true
        overlay.canvas.drawing = d
        overlay.isApplyingDrawing = false
        editor.canvasViewDrawingDidChange(overlay.canvas)
    }

    private func strokeCount(_ data: Data) -> Int {
        String(decoding: data, as: UTF8.self).components(separatedBy: "\"stroke\"").count - 1
    }

    // MARK: Free: nur ansehen

    /// Free: Strich wird nicht gespeichert, Seitenaktionen und Lesezeichen schreiben nichts, die vorhandenen Notizen
    /// bleiben sichtbar. Mit Plus geht Schreiben wieder.
    func testFreeEditorWritesNothingAndKeepsNotesVisible() async throws {
        let fx = try await makeStore()
        let store = fx.store
        await store.addText("Vorhandene Notiz", pageKey: "p1")
        let editor = PDFEditorController(store: store)
        editor.canEdit = UFFeatureMatrix.notes(plan: .free).canEdit
        editor.loadViewIfNeeded()
        XCTAssertFalse(editor.canEdit)
        XCTAssertFalse(store.isWritable)
        XCTAssertFalse(store.ownNotesReadOnly, "Notizen bleiben eingeblendet")
        let overlay = try XCTUnwrap(editor.overlayForTesting(at: 0))
        await waitLoaded(overlay)
        XCTAssertFalse(overlay.canvas.isHidden, "eigene Notizen sichtbar")
        XCTAssertFalse(overlay.objectsView.isHidden)
        XCTAssertFalse(overlay.canvas.isUserInteractionEnabled, "Stift schreibt nicht")
        let objects = await store.objects(forPageKey: "p1")
        XCTAssertEqual(objects.count, 1, "vorhandene Notiz bleibt lesbar")
        let before = await serialized(store)
        let journalBefore = journal(fx.root)

        // Stift auf Seite 2 (die Canvas nimmt keine Eingabe an; hier trotzdem wie von PencilKit gemeldet)
        let second = try XCTUnwrap(editor.overlayForTesting(at: 1))
        await waitLoaded(second)
        drawStroke(editor, on: second, y: 300)
        await store.addText("im Free-Tarif", pageKey: "p1")
        await store.addBlankPage(afterKey: "p1", template: "lined")
        await store.rotatePage(key: "p1")
        await store.toggleBookmark(pageKey: "p1", title: "Seite 1")
        let trashed = await store.applyPageStructure { doc in PageOrder.trash(&doc, key: "p2") }
        XCTAssertNil(trashed)
        let inserted = await editor.insertBlankPage(after: "p1", template: "grid")
        XCTAssertNil(inserted)
        let trashedByEditor = await editor.trashPage(key: "p3")
        XCTAssertFalse(trashedByEditor)
        editor.undo()
        XCTAssertFalse(editor.undoManager?.canUndo ?? false, "kein Rueckgaengig ohne Schreiben")
        let after = await serialized(store)
        XCTAssertEqual(after, before, "nichts ins eigene Dokument geschrieben")
        XCTAssertEqual(journal(fx.root), journalBefore, "Journal unveraendert")
        XCTAssertEqual(strokeCount(after), 0)

        // Plus (z. B. nach dem Kauf): Schreiben geht wieder
        editor.canEdit = UFFeatureMatrix.notes(plan: .plus).canEdit
        XCTAssertTrue(store.isWritable)
        XCTAssertTrue(overlay.canvas.isUserInteractionEnabled)
        drawStroke(editor, on: overlay, y: 400)
        let plus = await serialized(store)
        XCTAssertEqual(strokeCount(plus), 1, "mit Plus wird der Strich gespeichert")
        await store.close()
    }

    /// Herabstufen waehrend der Arbeit: der letzte Strich unter Plus wird noch gesichert, danach wird nichts mehr
    /// geschrieben, auch nicht ueber Rueckgaengig des Systems. Die Notizen bleiben vollstaendig erhalten.
    func testDowngradeKeepsNotesAndStopsWriting() async throws {
        let fx = try await makeStore()
        let store = fx.store
        let editor = PDFEditorController(store: store)
        editor.loadViewIfNeeded()
        let overlay = try XCTUnwrap(editor.overlayForTesting(at: 0))
        await waitLoaded(overlay)
        drawStroke(editor, on: overlay, y: 300)                 // Plus
        XCTAssertTrue(editor.undoManager?.canUndo ?? false)
        editor.canEdit = false                                   // Abo abgelaufen, noch bevor der Strich verarbeitet ist
        let kept = await serialized(store)
        XCTAssertEqual(strokeCount(kept), 1, "Strich von vorher wird gesichert")
        // Rueckgaengig ueber das System (Cmd-Z, drei Finger) nimmt nichts zurueck, weder gespeichert noch angezeigt
        if editor.undoManager?.canUndo == true { editor.undoManager?.undo() }
        editor.undo()
        XCTAssertEqual(overlay.canvas.drawing.strokes.count, 1, "Strich bleibt sichtbar")
        let afterUndo = await serialized(store)
        XCTAssertEqual(afterUndo, kept)
        drawStroke(editor, on: overlay, y: 500)
        let after = await serialized(store)
        XCTAssertEqual(after, kept, "nach dem Herabstufen nichts geschrieben")
        await store.close()

        // neu geoeffnet (Free): der gesicherte Strich ist da und sichtbar
        let reopened = DocumentStore(file: store.file, api: fx.api, root: fx.root)
        reopened.canEdit = false
        await reopened.load()
        let objects = await reopened.objects(forPageKey: "p1")
        XCTAssertEqual(objects.filter { $0["type"]?.string == "stroke" }.count, 1)
        await reopened.close()
    }

    /// Notizbuch und Whiteboard anlegen ist Plus (Schloss im Neu-Dialog), PDF- und Bild-Import zum Lesen bleiben Free
    func testNotebookCreationNeedsPlus() {
        XCTAssertEqual(NotebookDialog.feature, .pencilWriting)
        XCTAssertEqual(Entitlements(observe: false, plan: .free).access(NotebookDialog.feature), .locked(.plus))
        XCTAssertTrue(Entitlements(observe: false, plan: .plus).allows(NotebookDialog.feature))
        XCTAssertEqual(UFFeatureMatrix.access(.readDocuments, plan: .free), .allowed)
        XCTAssertEqual(Entitlements(observe: false, plan: .free).access(.splitView), .locked(.plus), "geteilte Ansicht: Schloss")
        XCTAssertTrue(UFLockedCard.message(.pencilWriting, access: .locked(.plus)).contains("Enthalten in Plus."))
    }

    // MARK: Endgueltig loeschen

    /// "Endgültig löschen": PDF-Kopie im Zwischenspeicher, Journal und Vorschauen dieses Dokuments verschwinden,
    /// die anderer Dokumente und Datenquellen bleiben.
    func testDeleteForeverRemovesCopiesOnDevice() async throws {
        let root = try tempDir()
        let fm = FileManager.default
        let local = DataSourceNamespace.local, server = DataSourceNamespace.server(host: "192.0.2.1", port: 8000)
        func touch(_ url: URL) throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        func pdf(_ id: String, _ ns: DataSourceNamespace) -> URL {
            AppPaths.pdf(id, namespace: ns, root: root)
        }
        func journalFile(_ id: String, _ ns: DataSourceNamespace) -> URL {
            root.appendingPathComponent("journal").appendingPathComponent(LocalJournal.directory(documentID: id, namespace: ns))
                .appendingPathComponent("pages/p1.json")
        }
        func thumb(_ id: String, _ ns: DataSourceNamespace, _ version: String) -> URL {
            root.appendingPathComponent("thumbs")
                .appendingPathComponent(LocalJournalName.safe(UFThumbnails.key(fileID: id, namespace: ns, version: version)) + ".jpg")
        }
        let gone = [pdf("u1", local), journalFile("u1", local), thumb("u1", local, "a"), thumb("u1", local, "b")]
        let kept = [pdf("u10", local), journalFile("u10", local), thumb("u10", local, "a"),          // Kennung mit gleichem Anfang
                    pdf("u1", server), journalFile("u1", server), thumb("u1", server, "a")]          // andere Datenquelle
        for u in gone + kept { try touch(u) }
        AppPaths.removeDocumentCopies(fileID: "u1", namespace: local, root: root)
        for u in gone { XCTAssertFalse(fm.fileExists(atPath: u.path), u.lastPathComponent) }
        for u in kept { XCTAssertTrue(fm.fileExists(atPath: u.path), u.path) }
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("journal")
            .appendingPathComponent(LocalJournal.directory(documentID: "u1", namespace: local)).path), "ganzer Journal-Ordner")
    }
}
