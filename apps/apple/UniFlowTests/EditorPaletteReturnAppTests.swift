import PDFKit
import PencilKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Meldung des Inhabers 11.11.2026: "Er schreibt, die Palette ist da. Dann in den Chat und wieder zurueck: die Palette
/// ist weg. Datei verlassen und neu oeffnen: wieder da." Apples Palette stand nur, solange der Anker Erstantwortgeber
/// war. Seit der festen Leiste (11.11.2026, `EditorToolbar`) steht die Leiste unabhaengig vom Fokus; der Fokus muss
/// trotzdem zum Editor zurueck (Tastenbefehle, Rueckgaengig ueber die Responder-Kette). Nachgestellt werden die Wege, auf denen der Fokus
/// woandershin geht und beim Zurueckkommen nicht zum Anker kam: Eingabefeld der KI-Hilfe (bzw. eines Chats) behaelt den
/// Fokus, waehrend wieder auf der Seite geschrieben wird; ein Vollbild-Blatt bzw. eine Navigation, nach der die Ansicht
/// des Editors wieder erscheint. Was nur am Geraet geht (echter Stift, Scribble, Hardware-Tastatur), steht im Bericht.
@MainActor
final class EditorPaletteReturnAppTests: XCTestCase {

    private func pdf(pages: Int) -> Data {
        let raw = NSMutableData()
        let size = CGSize(width: 595, height: 842)
        UIGraphicsBeginPDFContextToData(raw, CGRect(origin: .zero, size: size), nil)
        for i in 1...pages {
            UIGraphicsBeginPDFPageWithInfo(CGRect(origin: .zero, size: size), nil)
            "Seite \(i)".draw(at: CGPoint(x: 100, y: 200), withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
        }
        UIGraphicsEndPDFContext()
        return raw as Data
    }

    private func openStore() async throws -> DocumentStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-palette-return-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let host = LocalBackendHost(directory: root.appendingPathComponent("db", isDirectory: true), clock: .fixed(berlin: "2026-11-11T09:00:00")!)
        let backend = try await host.backend()
        let fileID = "palret-" + UUID().uuidString.prefix(8).lowercased()
        try await backend.context.database.transaction { c in
            try c.execute("INSERT OR IGNORE INTO courses(id, title, semester, subject, kind, created_at) VALUES (?,?,?,?,?,?)",
                          [.text("k-test"), .text("Testkurs"), .text("WiSe 2026/27"), .text("Testkurs"), .text("vorlesung"),
                           .text("2026-10-01T08:00:00")])
            try c.execute("INSERT INTO files(id, course_id, name, chdate, status, kind, downloaded_at) VALUES (?,?,?,?, 'neu', 'pdf', ?)",
                          [.text(fileID), .text("k-test"), .text("Skript.pdf"), .integer(1_792_000_000), .text("2026-11-11T08:00:00")])
        }
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
        let pdfURL = AppPaths.pdf(fileID, namespace: api.namespace, root: root)
        try FileManager.default.createDirectory(at: pdfURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pdf(pages: 2).write(to: pdfURL)
        try DocumentStore.stamp(try await api.value("/api/files/\(fileID)")).write(to: pdfURL.appendingPathExtension("stand"), atomically: true, encoding: .utf8)
        let file = LibFile(id: fileID, name: "Skript.pdf", title: "Skript", kind: "pdf", module_id: nil, subject: "Testkurs",
                           doc_type: nil, ai_title: nil, sub_label: nil, downloaded_at: "2026-11-11T08:00:00", has_notes: nil,
                           page_count: 2, studip_folder: nil)
        let store = DocumentStore(file: file, api: api, root: root)
        await store.load()
        XCTAssertNil(store.errorMessage, store.errorMessage ?? "")
        addTeardownBlock { await store.close() }
        return store
    }

    /// Werkzeuge in eigenem Speicher (kein geteilter Stand mit anderen Tests)
    private func tools() -> EditorToolState {
        let suite = "toolbar-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return EditorToolState(defaults: defaults)
    }

    private func wait(_ what: String, timeout: Double = 5, _ cond: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline { if await cond() { return }; try await Task.sleep(nanoseconds: 30_000_000) }
        XCTFail("Zeit abgelaufen: \(what)")
    }

    /// Editor als Inhalt eines Fensters, daneben Platz fuer die KI-Hilfe (wie `DocumentView`: KI-Hilfe neben der PDF)
    private func show(_ editor: PDFEditorController) -> (UIWindow, UIViewController) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let frame = scene?.screen.bounds ?? CGRect(x: 0, y: 0, width: 834, height: 1210)
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        let root = UIViewController()
        root.addChild(editor)
        editor.view.frame = CGRect(x: 0, y: 0, width: frame.width * 0.65, height: frame.height)
        root.view.addSubview(editor.view)
        editor.didMove(toParent: root)
        window.rootViewController = root
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in
            editor.showToolPicker(false)
            window.endEditing(true)
            window.isHidden = true
            window.rootViewController = nil
        }
        return (window, root)
    }

    /// Eingabefeld der KI-Hilfe rechts neben der PDF (ausserhalb des Editors)
    private func chatField(in root: UIViewController) -> UITextView {
        let b = root.view.bounds
        let field = UITextView(frame: CGRect(x: b.width * 0.68, y: b.height - 120, width: b.width * 0.3, height: 60))
        field.text = "Was bedeutet das?"
        root.view.addSubview(field)
        return field
    }

    /// Leiste steht (fest, braucht keinen Fokus) und der Fokus ist beim Editor (Tastenbefehle, Rueckgaengig)
    private func paletteStands(_ editor: PDFEditorController) -> Bool {
        UIResponder.uf_current is ToolPickerAnchor && editor.toolbarMode.visible
    }

    /// Ablauf der Meldung: Schreiben (Palette da) → KI-Frage tippen (Palette weg, der Editor nimmt den Fokus nicht) →
    /// wieder mit dem Stift auf der Seite: das Feld gibt den Fokus ab, der Anker hat ihn, die Palette steht. Vorher blieb
    /// das Feld Erstantwortgeber (Stift/Scribble oder Hardware-Tastatur: keine Tastatur zum Schliessen), und die Palette
    /// kam erst nach dem Neuoeffnen der Datei zurueck. Ein Textobjekt auf der Seite verliert den Fokus dabei nicht.
    func testWritingOnThePageAgainAfterTheChatBringsThePaletteBack() async throws {
        let store = try await openStore()
        let editor = PDFEditorController(store: store, tools: tools())
        let (_, root) = show(editor)
        editor.showToolPicker(true)
        try await wait("Palette steht", timeout: 6) { paletteStands(editor) }

        // in den Chat: Frage tippen, die Palette geht weg und der Editor stiehlt den Fokus nicht
        let field = chatField(in: root)
        XCTAssertTrue(field.becomeFirstResponder())
        try await wait("Fokus im Feld") { !editor.editorHoldsFocus }
        XCTAssertTrue(editor.toolbarMode.visible, "die feste Leiste bleibt beim Tippen stehen")
        XCTAssertEqual(editor.paletteBlocker, .textInput)
        XCTAssertFalse(editor.restorePicker(), "tippt: nicht stehlen")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(field.isFirstResponder, "waehrend des Tippens bleibt der Fokus im Feld")

        // zurueck: der Stift setzt auf der Seite auf
        let overlay = try XCTUnwrap(editor.overlayForTesting(at: 0))
        try await wait("Seite geladen") { overlay.loaded }
        editor.canvasViewDidBeginUsingTool(overlay.canvas)
        editor.canvasViewDidEndUsingTool(overlay.canvas)
        try await wait("Palette wieder da", timeout: 6) { paletteStands(editor) }
        XCTAssertFalse(field.isFirstResponder)

        // Textobjekt auf der Seite (Text im PDF): Schreiben daneben nimmt ihm den Fokus nicht
        let onPage = UITextView(frame: CGRect(x: 40, y: 40, width: 200, height: 40))
        editor.pdfView.addSubview(onPage)
        XCTAssertTrue(onPage.becomeFirstResponder())
        editor.canvasViewDidBeginUsingTool(overlay.canvas)
        editor.canvasViewDidEndUsingTool(overlay.canvas)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(onPage.isFirstResponder, "Text im PDF wird weiter bearbeitet")
        onPage.resignFirstResponder()
        onPage.removeFromSuperview()
        try await wait("Palette nach dem Text im PDF wieder da", timeout: 6) { paletteStands(editor) }
    }

    /// KI-Leiste schliesst, waehrend ihr Eingabefeld den Fokus hat: die Palette kommt ohne Zutun zurueck
    func testClosingTheAIPanelWhileTypingBringsThePaletteBack() async throws {
        let store = try await openStore()
        let editor = PDFEditorController(store: store, tools: tools())
        let (_, root) = show(editor)
        editor.showToolPicker(true)
        try await wait("Palette steht", timeout: 6) { paletteStands(editor) }
        let field = chatField(in: root)
        XCTAssertTrue(field.becomeFirstResponder())
        try await wait("Fokus im Feld") { !editor.editorHoldsFocus }
        XCTAssertTrue(editor.toolbarMode.visible, "die feste Leiste bleibt beim Tippen stehen")
        field.removeFromSuperview()
        try await wait("Palette wieder da", timeout: 6) { paletteStands(editor) }
    }

    /// Chat, Nachrichten oder alte Fassung als Vollbild ueber dem Dokument (die Ansicht des Editors verschwindet und
    /// erscheint wieder, ohne neu zu entstehen): `viewWillDisappear` meldete den Anker bei der Palette ab, `viewDidAppear`
    /// gab ihm nur den Fokus zurueck. Der Anker war dann Erstantwortgeber, die Palette blieb aber weg, bis die Datei neu
    /// geoeffnet wurde.
    func testPaletteComesBackAfterAFullScreenDetour() async throws {
        let store = try await openStore()
        let editor = PDFEditorController(store: store, tools: tools())
        let (_, root) = show(editor)
        editor.showToolPicker(true)
        try await wait("Palette steht", timeout: 6) { paletteStands(editor) }

        let chat = UIViewController()
        chat.modalPresentationStyle = .fullScreen
        let field = UITextView(frame: CGRect(x: 40, y: 200, width: 400, height: 60))
        chat.view.addSubview(field)
        root.present(chat, animated: false)
        try await wait("Chat im Vollbild") { chat.view.window != nil && editor.view.window == nil }
        XCTAssertTrue(field.becomeFirstResponder())
        chat.dismiss(animated: false)
        try await wait("zurueck im Dokument") { editor.view.window != nil }
        try await wait("Palette wieder da", timeout: 6) { paletteStands(editor) }
    }
}
