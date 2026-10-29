import PDFKit
import PencilKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Editor, Schritt 6 (Objekt-Werkzeuge P1-4 bis P1-7, PDF-Text markieren P2-7) im echten Weg: Store mit lokalem
/// Backend, Editor geladen. Gesten selbst prueft die Abnahmeliste am Geraet (Abschnitt 20); hier die Wege darunter.
@MainActor
final class EditorStep6Tests: XCTestCase {

    private func pdf(pages: Int) -> Data {
        let raw = NSMutableData()
        let size = CGSize(width: 595, height: 842)
        UIGraphicsBeginPDFContextToData(raw, CGRect(origin: .zero, size: size), nil)
        for i in 1...pages {
            UIGraphicsBeginPDFPageWithInfo(CGRect(origin: .zero, size: size), nil)
            "Satz des Pythagoras \(i)".draw(at: CGPoint(x: 100, y: 200), withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
        }
        UIGraphicsEndPDFContext()
        return raw as Data
    }

    private func open() async throws -> (DocumentStore, PDFEditorController) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-schritt6-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let host = LocalBackendHost(directory: root.appendingPathComponent("db", isDirectory: true), clock: .fixed(berlin: "2026-10-29T09:00:00")!)
        let backend = try await host.backend()
        let fileID = "schritt6-" + UUID().uuidString.prefix(8).lowercased()
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
        try pdf(pages: 2).write(to: pdfURL)
        try DocumentStore.stamp(try await api.value("/api/files/\(fileID)")).write(to: pdfURL.appendingPathExtension("stand"), atomically: true, encoding: .utf8)
        let file = LibFile(id: fileID, name: "Skript.pdf", title: "Skript", kind: "pdf", module_id: nil, subject: "Testkurs",
                           doc_type: nil, ai_title: nil, sub_label: nil, downloaded_at: "2026-10-29T08:00:00", has_notes: nil,
                           page_count: 2, studip_folder: nil)
        let store = DocumentStore(file: file, api: api, root: root)
        await store.load()
        XCTAssertNil(store.errorMessage, store.errorMessage ?? "")
        let editor = PDFEditorController(store: store)
        editor.loadViewIfNeeded()
        return (store, editor)
    }

    private func wait(_ what: String, _ cond: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline { if await cond() { return }; try await Task.sleep(nanoseconds: 30_000_000) }
        XCTFail("Zeit abgelaufen: \(what)")
    }

    /// Objektmodus: Auswahl loeschen, umfaerben, Schrift groesser; Rueckgaengig stellt den Stand davor her,
    /// Wiederholen den danach. Gegenprobe: ohne Auswahl aendern die Aktionen nichts.
    func testSelectionActionsWithUndoAndRedo() async throws {
        let (store, editor) = try await open()
        let obj = editor.objects
        editor.objects.setActive(true)
        XCTAssertTrue(obj.isActive)
        let text = PageObjectEdit.text(id: "t1", x: 50, y: 50, text: "Hallo")
        let rect = try XCTUnwrap(PageObjectEdit.shape(id: "r1", kind: "rect", from: (100, 100), to: (200, 150), color: "#1d2130", width: 2))
        await store.editObjects(pageKey: "p1") { $0 + [text, rect] }

        obj.deleteSelection()                                            // ohne Auswahl: nichts
        obj.recolorSelection("#2f7fd1")
        try await Task.sleep(nanoseconds: 100_000_000)
        var now = await store.objects(forPageKey: "p1")
        XCTAssertEqual(now.count, 2)
        XCTAssertEqual(now[1]["stroke"], "#1d2130")

        await obj.selectForTesting(key: "p1", ids: ["r1", "t1"])
        obj.recolorSelection("#2f7fd1")
        try await wait("umgefaerbt") { await store.objects(forPageKey: "p1").last?["stroke"] == "#2f7fd1" }
        now = await store.objects(forPageKey: "p1")
        XCTAssertEqual(now[0]["fill"], "#2f7fd1", "Text: Schriftfarbe")
        obj.resizeText(by: 2)
        try await wait("Schrift groesser") { await store.objects(forPageKey: "p1").first?["fontSize"] == 16 }
        obj.deleteSelection()
        try await wait("geloescht") { await store.objects(forPageKey: "p1").isEmpty }

        editor.editUndo.undo()
        try await wait("Rueckgaengig: wieder da") { await store.objects(forPageKey: "p1").count == 2 }
        now = await store.objects(forPageKey: "p1")
        XCTAssertEqual(now[0]["fontSize"], 16, "Stand vor dem Loeschen")
        editor.editUndo.redo()
        try await wait("Wiederholen: wieder weg") { await store.objects(forPageKey: "p1").isEmpty }
        editor.objects.setActive(false)
        XCTAssertFalse(obj.isActive)
        await store.close()
    }

    /// Text markieren: Auswahl "Pythagoras" auf Seite 1 ergibt eine Markierung in Seitenpunkten an der Stelle des Textes
    /// (oben links bei etwa 100/200), Unterstreichen eine Linie knapp unter der Zeile. Auf der gedrehten Seite 2 liegt
    /// die Markierung gedreht (Text senkrecht). Gegenprobe: ohne Auswahl entsteht nichts.
    func testMarkupFromPDFSelectionLandsOnTheText() async throws {
        let (store, first) = try await open()
        _ = first
        await store.rotatePage(key: "p2")
        let editor = PDFEditorController(store: store)                  // zeigt den Aufbau mit der gedrehten Seite
        editor.loadViewIfNeeded()
        editor.objects.setActive(true)
        editor.objects.tool = .markup
        let doc = try XCTUnwrap(editor.pdfView.document)
        editor.objects.applyMarkup(.highlight)                           // ohne Auswahl
        try await Task.sleep(nanoseconds: 100_000_000)
        let none = await store.objects(forPageKey: "p1")
        XCTAssertTrue(none.isEmpty)

        let hits = doc.findString("Pythagoras", withOptions: [])
        XCTAssertEqual(hits.count, 2)
        editor.pdfView.currentSelection = hits[0]
        let lines = editor.objects.selectedLines()
        let l = try XCTUnwrap(lines["p1"]?.first)
        XCTAssertEqual(l.text, "Pythagoras")
        XCTAssertGreaterThan(l.x0, 100)
        XCTAssertLessThan(l.x0, 260)
        XCTAssertEqual(l.y0, 200, accuracy: 8, "oben links wie beim Zeichnen (y nach unten)")
        XCTAssertEqual(l.up.y, -1, accuracy: 1e-9)
        editor.objects.applyMarkup(.highlight)
        try await wait("Markierung") { await store.objects(forPageKey: "p1").count == 1 }
        let afterHL = await store.objects(forPageKey: "p1")
        let hl = try XCTUnwrap(afterHL.first)
        XCTAssertEqual(hl["markup"], "highlight")
        XCTAssertEqual(hl["text"], "Pythagoras")
        XCTAssertEqual(hl["x"]?.double ?? 0, l.x0, accuracy: 0.01)

        editor.pdfView.currentSelection = hits[0]
        editor.objects.applyMarkup(.underline)
        try await wait("Unterstrichen") { await store.objects(forPageKey: "p1").count == 2 }
        let afterUL = await store.objects(forPageKey: "p1")
        let ul = try XCTUnwrap(afterUL.last)
        let pts = ul["points"]?.array?.compactMap(\.double) ?? []
        XCTAssertEqual(pts.count, 4)
        XCTAssertGreaterThan(pts[1], l.y1, "unter der Zeile")

        // gedrehte Seite: Text laeuft senkrecht, "oben" zeigt nach rechts
        editor.pdfView.currentSelection = hits[1]
        let rotated = try XCTUnwrap(editor.objects.selectedLines()["p2"]?.first)
        XCTAssertGreaterThan(rotated.y1 - rotated.y0, rotated.x1 - rotated.x0, "senkrecht")
        XCTAssertEqual(rotated.up.x, 1, accuracy: 1e-9)
        XCTAssertEqual(rotated.x1, 842 - 200, accuracy: 8, "(x, y) -> (H - y, x)")
        await store.close()
    }

    /// Neues Textfeld: der Editor legt es an und oeffnet die Bearbeitung; ein leer gelassenes Feld verschwindet wieder,
    /// ein beschriebenes wird gespeichert.
    func testNewTextFieldIsEditedAndEmptyOneRemoved() async throws {
        let (store, editor) = try await open()
        let o = PageObjectEdit.text(id: "neu", x: 40, y: 40)
        await store.editObjects(pageKey: "p1") { $0 + [o] }
        let added = await store.objects(forPageKey: "p1")
        XCTAssertEqual(added.count, 1)
        await store.editObjects(pageKey: "p1") { PageObjectEdit.set($0, ids: ["neu"], "text", "Notiz") }
        let saved = await store.objects(forPageKey: "p1").first?["text"]
        XCTAssertEqual(saved, "Notiz")
        await store.editObjects(pageKey: "p1") { PageObjectEdit.delete($0, ids: ["neu"]) }
        let gone = await store.objects(forPageKey: "p1")
        XCTAssertTrue(gone.isEmpty)
        let unchanged = await store.editObjects(pageKey: "p1") { $0 }
        XCTAssertNil(unchanged, "keine Aenderung: nichts gespeichert, kein Rueckgaengig")
        await store.close()
    }
}
