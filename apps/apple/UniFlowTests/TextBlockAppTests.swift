import PDFKit
import PencilKit
import SwiftUI
import UniFlowCore
import XCTest
@testable import UniFlow

/// Textbloecke "wie Word" im Editor (Auftrag des Inhabers 25.11.2026): tippen auf blanko und liniert, mehrere Bloecke,
/// formatieren (fett, Schriftart, Groesse, markieren ...), auf linierten Seiten immer auf den Zeilen, langes Druecken
/// greift einen Block zum Verschieben. Im echten Weg: Dokument im Fenster, Beruehrungen wie am Geraet.
@MainActor
final class TextBlockAppTests: XCTestCase {

    struct Shown {
        let store: DocumentStore
        let editor: PDFEditorController
        let window: UIWindow
        /// Seiten: PDF-Seite, linierte Seite, leere Seite
        let lined: String
        let blank: String
    }

    private static func pdf() -> Data {
        let raw = NSMutableData()
        let size = CGSize(width: 595, height: 842)
        UIGraphicsBeginPDFContextToData(raw, CGRect(origin: .zero, size: size), nil)
        UIGraphicsBeginPDFPageWithInfo(CGRect(origin: .zero, size: size), nil)
        "Skript Seite 1".draw(at: CGPoint(x: 60, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
        UIGraphicsEndPDFContext()
        return raw as Data
    }

    /// Dokument (1 PDF-Seite, danach eine linierte und eine leere Seite) im Fenster, Tarif mit Schreiben
    private func open(canEdit: Bool = true, size: CGSize = CGSize(width: 1080, height: 810)) async throws -> Shown {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-textblock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let clock: UniFlowClock = .fixed(berlin: "2026-11-25T09:00:00")!
        let layout = DataContainerLayout(base: root.appendingPathComponent("c", isDirectory: true),
                                         key: DataContainerKey(userID: "001234.erfunden.text", university: .luh))
        try layout.prepare(clock: clock)
        let host = LocalBackendHost(directory: layout.databaseDirectory, clock: clock, files: .container(layout), university: .luh)
        let backend = try await host.backend()
        let fileID = "text-" + UUID().uuidString.prefix(8).lowercased()
        try await backend.context.database.transaction { c in
            try c.execute("INSERT OR IGNORE INTO courses(id, title, semester, subject, kind, created_at) VALUES (?,?,?,?,?,?)",
                          [.text("k-test"), .text("Testkurs"), .text("WiSe 2026/27"), .text("Testkurs"), .text("vorlesung"),
                           .text("2026-10-01T08:00:00")])
            try c.execute("INSERT INTO files(id, course_id, name, chdate, status, kind, downloaded_at) VALUES (?,?,?,?, 'neu', 'pdf', ?)",
                          [.text(fileID), .text("k-test"), .text("Skript.pdf"), .integer(1_792_000_000), .text("2026-11-25T08:00:00")])
        }
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
        let pdfURL = AppPaths.pdf(fileID, namespace: api.namespace, root: root)
        try FileManager.default.createDirectory(at: pdfURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.pdf().write(to: pdfURL)
        try DocumentStore.stamp(try await api.value("/api/files/\(fileID)")).write(to: pdfURL.appendingPathExtension("stand"), atomically: true, encoding: .utf8)
        let file = LibFile(id: fileID, name: "Skript.pdf", title: "Skript", kind: "pdf", module_id: nil, subject: "Testkurs",
                           doc_type: nil, ai_title: nil, sub_label: nil, downloaded_at: "2026-11-25T08:00:00", has_notes: nil,
                           page_count: 1, studip_folder: nil)
        let store = DocumentStore(file: file, api: api, root: root)
        await store.load()
        XCTAssertNil(store.errorMessage, store.errorMessage ?? "")
        await store.addBlankPage(afterKey: "p1", template: "lined", size: CGSize(width: 595, height: 842))
        let lined = try XCTUnwrap(store.pageKey(forPageIndex: 1))
        await store.addBlankPage(afterKey: lined, template: "blank", size: CGSize(width: 595, height: 842))
        let blank = try XCTUnwrap(store.pageKey(forPageIndex: 2))

        let suite = "uniflow.tests.textblock.\(UUID().uuidString)"
        let toolDefaults = UserDefaults(suiteName: suite) ?? .standard
        let editor = PDFEditorController(store: store, tools: EditorToolState(defaults: toolDefaults))
        editor.pencilOnly = true
        editor.ownNotesVisible = true
        editor.canEdit = canEdit
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let frame = CGRect(origin: .zero, size: size)
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        window.rootViewController = editor
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in
            toolDefaults.removePersistentDomain(forName: suite)
            editor.objects.endTextEditing()
            editor.showToolPicker(false)
            window.isHidden = true
            window.rootViewController = nil
            await store.close()
        }
        return Shown(store: store, editor: editor, window: window, lined: lined, blank: blank)
    }

    /// Seite zeigen und warten, bis sie mit Notizen geladen ist
    private func overlay(_ s: Shown, key: String) async throws -> PageInkView {
        let index = try XCTUnwrap(s.store.layout?.index(ofKey: key))
        var found: PageInkView?
        var jumped = false
        try await BildProbe.wait("Seite \(index + 1) geladen und im Fenster", timeout: 20) {
            // erst springen, wenn das Dokument steht; dann warten, bis der obere Teil der Seite im Fenster liegt
            if !jumped, s.editor.pdfView.document?.page(at: index) != nil, s.editor.allOverlays.contains(where: { $0.loaded }) {
                s.editor.goToPage(index)
                jumped = true
            }
            found = s.editor.allOverlays.first { $0.pageKey == key && $0.window != nil && $0.generation == s.editor.shownLayoutVersion && $0.loaded }
            guard jumped, let v = found else { return false }
            let top = v.content.convert(CGPoint(x: 100, y: 100), to: nil), low = v.content.convert(CGPoint(x: 100, y: 300), to: nil)
            return s.window.bounds.contains(top) && s.window.bounds.contains(low)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        return try XCTUnwrap(found)
    }

    private func object(_ s: Shown, _ key: String, _ id: String) async -> JSONValue? {
        await s.store.objects(forPageKey: key).first { $0["id"]?.string == id }
    }

    /// Grundlinie der ersten Zeile eines eingerasteten Blocks (Seitenpunkte)
    private func firstBaseline(_ o: JSONValue?) -> Double {
        (o?["y"]?.double ?? -1) + TextBlock.padding + TextBlock.lineStep - TextBlock.baselineDrop
    }

    private func onLine(_ y: Double) -> Bool {
        let n = (y - TextBlock.firstLine) / TextBlock.lineStep
        return n >= -0.001 && abs(n - n.rounded()) < 0.002
    }

    private func style(_ change: (inout TextBlock.Style) -> Void) -> TextBlock.Style {
        var s = TextBlock.Style(fontSize: 16)
        change(&s)
        return s
    }

    // MARK: Satz

    /// Jede Zeile eines Blocks auf einer linierten Seite sitzt mit der Grundlinie auf einer Linie (60, 84, 108 ...), auch
    /// mit gemischten Schriften und Groessen und nach dem Umbrechen; eine sehr grosse Zeile nimmt zwei Linien.
    /// Gegenprobe: derselbe Text ohne Einrasten sitzt nicht auf den Linien.
    func testZeilenSitzenAufDenLinien() throws {
        var o = TextBlock.block(id: "b", x: 60, y: 130, template: "lined", pageWidth: 300)
        let base = TextBlock.baseStyle(o)
        o = TextBlock.setting([
            TextBlock.Run(text: "Die Mitose ist die Teilung des Zellkerns. ", style: base),
            TextBlock.Run(text: "Wichtig: ", style: style { $0.bold = true; $0.fontFamily = "Georgia"; $0.fontSize = 20 }),
            TextBlock.Run(text: "Prophase, Metaphase, Anaphase und Telophase folgen aufeinander.\n", style: style { $0.fontSize = 12; $0.italic = true }),
            TextBlock.Run(text: "Merksatz", style: style { $0.fontSize = 34 }),
            TextBlock.Run(text: "\nund danach wieder normaler Text in der Grundschrift.", style: base),
        ], in: o)
        let view = TextBlockView(object: o)
        let lines = view.baselinesOnPage.map(Double.init)
        XCTAssertGreaterThanOrEqual(lines.count, 6, "der Text bricht in mehrere Zeilen um")
        for (i, y) in lines.enumerated() { XCTAssertTrue(onLine(y), "Zeile \(i + 1): Grundlinie \(y) sitzt nicht auf einer Linie") }
        XCTAssertEqual(lines[0], firstBaseline(o), accuracy: 0.01, "erste Zeile: wie der Kern rechnet")
        let steps = zip(lines.dropFirst(), lines).map { $0 - $1 }
        XCTAssertTrue(steps.contains { abs($0 - 48) < 0.01 }, "die 34-pt-Zeile nimmt zwei Linien: \(steps)")
        XCTAssertTrue(steps.allSatisfy { abs($0 - 24) < 0.01 || abs($0 - 48) < 0.01 }, "nur ganze Zeilenabstaende: \(steps)")
        let size = TextBlockRender.size(o)
        XCTAssertEqual(Double(size.height - 2 * ObjectGeometry.textPadding).truncatingRemainder(dividingBy: 24), 0, accuracy: 0.01)
        XCTAssertEqual(size, ObjectGeometry.textSize(o, ObjectGeometry.attributedText(o)), "Treffer und Rahmen messen denselben Satz")
        XCTAssertEqual(Double(size.height), ObjectEditing.textHeight(o), accuracy: 0.01)

        // Gegenprobe: frei gesetzt (blanko)
        var free = o
        free["snap"] = nil
        let loose = TextBlockView(object: free).baselinesOnPage.map(Double.init)
        XCTAssertFalse(loose.allSatisfy(onLine), "ohne Einrasten laege der Text nur zufaellig auf den Linien")
    }

    /// Leerer Block und Zeilenumbruch am Ende: immer ganze Zeilen
    func testLeererBlockUndLeereLetzteZeile() {
        let empty = TextBlock.block(id: "b", x: 60, y: 130, template: "lined")
        XCTAssertEqual(Double(TextBlockRender.size(empty).height), 24 + 8, accuracy: 0.01)
        let two = TextBlock.setting([TextBlock.Run(text: "eine Zeile\n", style: TextBlock.baseStyle(empty))], in: empty)
        XCTAssertEqual(Double(TextBlockRender.size(two).height), 48 + 8, accuracy: 0.01, "die leere Zeile nach dem Umbruch zaehlt")
        let plain = TextBlock.block(id: "p", x: 60, y: 130, template: "blank")
        XCTAssertGreaterThan(TextBlockRender.size(plain).height, 16, "leerer Block auf blanko: eine Zeile hoch, antippbar")
    }

    /// Die Seite zeigt Textbloecke mit dem eigenen Satz, einfache Textfelder (Web, Haftnotiz) wie bisher
    func testAnzeigeBlockUndAltesTextfeld() {
        let block = TextBlock.setting([TextBlock.Run(text: "Block", style: style { $0.bold = true })],
                                      in: TextBlock.block(id: "b", x: 60, y: 130, template: "lined"))
        let old = PageObjectEdit.text(id: "t", x: 60, y: 300, text: "Textfeld aus dem Web")
        let sticky = PageObjectEdit.sticky(id: "s", x: 300, y: 300, text: "Haftnotiz")
        let view = PageObjectsView(frame: CGRect(x: 0, y: 0, width: 595, height: 842))
        view.show(template: "lined", placeholder: nil, objects: [block, old, sticky], images: [:])
        let blocks = view.subviews.compactMap { $0 as? TextBlockView }
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.frame.origin.y ?? 0, CGFloat(block["y"]?.double ?? -1), accuracy: 0.01)
        XCTAssertEqual(view.subviews.filter { $0.subviews.first is UILabel }.count, 2, "Textfeld und Haftnotiz wie bisher")
        // beim Tippen ruht die Anzeige des Blocks, auch ueber einen Neuaufbau hinweg
        view.setHidden(["b"], true)
        XCTAssertEqual(blocks.first?.isHidden, true)
        view.show(template: "lined", placeholder: nil, objects: [block, old], images: [:])
        XCTAssertEqual(view.subviews.compactMap { $0 as? TextBlockView }.first?.isHidden, true)
        view.setHidden(["b"], false)
        XCTAssertEqual(view.subviews.compactMap { $0 as? TextBlockView }.first?.isHidden, false)
    }

    // MARK: Tippen und Formatieren

    /// Werkzeug "Text", auf die linierte Seite tippen, schreiben, ein Wort fett und markiert: Der Block steht danach
    /// mit der Formatierung auf der Linie unter dem Tippunkt. Ein Rueckgaengig nimmt ihn ganz weg.
    func testTippenAufLiniertMitFormatierung() async throws {
        try ContainerTestBed.requireEventGroupedUndo()
        let s = try await open()
        let page = try await overlay(s, key: s.lined)
        s.editor.choose(.text)
        XCTAssertTrue(s.editor.objects.isActive)
        XCTAssertEqual(s.editor.objects.tool, .text)
        try await BildProbe.tap(CGPoint(x: 80, y: 150), on: page, in: s.window)         // zwischen den Linien 132 und 156
        try await BildProbe.wait("Textansicht offen") { s.editor.objects.editingTextView != nil }
        let view = try XCTUnwrap(s.editor.objects.editingTextView)
        XCTAssertTrue(view.isFirstResponder, "die Tastatur gehoert dem Block")
        let before = await s.store.objects(forPageKey: s.lined)
        XCTAssertTrue(before.isEmpty, "gespeichert wird erst mit Text")
        XCTAssertEqual(s.editor.objects.textFormat?.editing, true, "die Leiste \"Text\" erscheint")
        XCTAssertEqual(s.editor.objects.textFormat?.lined, true)
        XCTAssertEqual(s.editor.objects.textFormat?.style.fontSize, 16)

        view.insertText("Hallo Welt")
        s.editor.objects.textViewDidChange(view)
        view.selectedRange = NSRange(location: 6, length: 4)
        s.editor.objects.format(.bold(true))
        s.editor.objects.format(.mark("#f5d90a"))
        XCTAssertEqual(s.editor.objects.textFormat?.style.bold, true, "die Leiste zeigt den Stand der Auswahl")
        XCTAssertEqual(s.editor.objects.textFormat?.style.mark, "#f5d90a")
        view.selectedRange = NSRange(location: 2, length: 0)
        s.editor.objects.textViewDidChangeSelection(view)
        XCTAssertEqual(s.editor.objects.textFormat?.style.bold, false, "Schreibmarke im normalen Wort")
        // waehrend des Tippens sitzt die Textansicht selbst auf den Linien
        let typed = try XCTUnwrap(s.editor.objects.editing)
        XCTAssertEqual(Double(view.frame.minY) + TextBlock.padding + Double(typed.layout.baselines[0]), 156, accuracy: 0.05)

        s.editor.objects.endTextEditing()
        try await BildProbe.wait("Block gespeichert") { await s.store.objects(forPageKey: s.lined).count == 1 }
        let found1 = await s.store.objects(forPageKey: s.lined).first
        let saved = try XCTUnwrap(found1)
        XCTAssertEqual(saved["type"], "text")
        XCTAssertEqual(saved["text"], "Hallo Welt")
        XCTAssertEqual(saved["snap"], "lines")
        XCTAssertEqual(firstBaseline(saved), 156, accuracy: 0.011, "auf der Linie unter dem Tippunkt")
        XCTAssertEqual(saved["runs"], [["text": "Hallo "], ["text": "Welt", "bold": true, "mark": "#f5d90a"]])
        XCTAssertNil(s.editor.objects.editingTextView)
        XCTAssertNil(s.editor.objects.textFormat, "nichts gewaehlt: Leiste weg")
        // die Seite zeigt den Block im selben Satz
        try await BildProbe.wait("Block auf der Seite") { page.objectsView.subviews.contains { $0 is TextBlockView } }
        let shown = try XCTUnwrap(page.objectsView.subviews.compactMap { $0 as? TextBlockView }.first)
        XCTAssertFalse(shown.isHidden)
        XCTAssertTrue(shown.baselinesOnPage.map(Double.init).allSatisfy(onLine))

        s.editor.editUndo.undo()
        try await BildProbe.wait("Rueckgaengig: Block weg") { await s.store.objects(forPageKey: s.lined).isEmpty }
        s.editor.editUndo.redo()
        try await BildProbe.wait("Wiederholen: Block wieder da") { await s.store.objects(forPageKey: s.lined).first?["text"] == "Hallo Welt" }
    }

    /// Ohne Auswahl gilt die Formatierung fuer das, was als Naechstes getippt wird; ein Block in nur einer Formatierung
    /// speichert sie als Grundformatierung (aeltere Apps zeigen ihn dann genauso). Auf der leeren Seite frei gesetzt.
    /// Ein leer gelassener neuer Block hinterlaesst nichts.
    func testFormatOhneAuswahlUndLeererBlock() async throws {
        let s = try await open()
        let page = try await overlay(s, key: s.blank)
        s.editor.choose(.text)
        try await BildProbe.tap(CGPoint(x: 100, y: 211), on: page, in: s.window)
        try await BildProbe.wait("Textansicht offen") { s.editor.objects.editingTextView != nil }
        var view = try XCTUnwrap(s.editor.objects.editingTextView)
        XCTAssertEqual(s.editor.objects.textFormat?.lined, false)
        s.editor.objects.format(.italic(true))
        s.editor.objects.format(.fontSize(24))
        s.editor.objects.format(.fontFamily("Georgia"))
        s.editor.objects.setAlignment("center")
        XCTAssertEqual(s.editor.objects.textFormat?.style.italic, true)
        XCTAssertEqual(s.editor.objects.textFormat?.align, "center")
        view.insertText("Überschrift")
        s.editor.objects.textViewDidChange(view)
        s.editor.objects.endTextEditing()
        try await BildProbe.wait("gespeichert") { await s.store.objects(forPageKey: s.blank).count == 1 }
        let found2 = await s.store.objects(forPageKey: s.blank).first
        let saved = try XCTUnwrap(found2)
        XCTAssertEqual(saved["text"], "Überschrift")
        XCTAssertEqual(saved["italic"], true)
        XCTAssertEqual(saved["fontSize"], 24)
        XCTAssertEqual(saved["fontFamily"], "Georgia")
        XCTAssertEqual(saved["align"], "center")
        XCTAssertNil(saved["runs"])
        XCTAssertNil(saved["snap"], "blanko: frei")
        XCTAssertEqual(saved["y"]?.double ?? 0, 211, accuracy: 0.011, "genau am Tippunkt")
        XCTAssertEqual(saved["block"], 1)

        // zweiter Block, leer gelassen: nichts kommt dazu, kein Rueckgaengig-Schritt
        s.editor.choose(.text)
        try await BildProbe.tap(CGPoint(x: 100, y: 330), on: page, in: s.window)
        try await BildProbe.wait("zweite Textansicht") { s.editor.objects.editingTextView != nil }
        view = try XCTUnwrap(s.editor.objects.editingTextView)
        view.insertText("   ")
        s.editor.objects.endTextEditing()
        try await Task.sleep(nanoseconds: 300_000_000)
        let after = await s.store.objects(forPageKey: s.blank)
        XCTAssertEqual(after.count, 1)
    }

    /// Mit "Text" auf einen vorhandenen Block tippen bearbeitet ihn (statt einen neuen darueberzulegen); mehrere Bloecke
    /// auf einer Seite; ein einfaches Textfeld ohne Formatierung bleibt ein einfaches Textfeld.
    func testVorhandenenBlockBearbeitenUndAltesTextfeld() async throws {
        let s = try await open()
        let page = try await overlay(s, key: s.lined)
        let a = TextBlock.setting([TextBlock.Run(text: "Erster Block", style: TextBlock.Style(fontSize: 16))],
                                  in: TextBlock.block(id: "a", x: 60, y: 100, template: "lined", pageWidth: 595))
        let old = PageObjectEdit.text(id: "old", x: 60, y: 400, text: "alt")
        await s.store.editObjects(pageKey: s.lined) { $0 + [a, old] }
        try await BildProbe.wait("gezeigt") { page.objectsView.shownObjects.count == 2 }

        s.editor.choose(.text)
        try await BildProbe.tap(CGPoint(x: 90, y: Double(a["y"]?.double ?? 0) + 14), on: page, in: s.window)
        try await BildProbe.wait("Block wird bearbeitet") { s.editor.objects.editing?.id == "a" }
        var view = try XCTUnwrap(s.editor.objects.editingTextView)
        XCTAssertEqual(view.text, "Erster Block")
        XCTAssertEqual(page.objectsView.subviews.compactMap { $0 as? TextBlockView }.first?.isHidden, true, "Anzeige ruht beim Tippen")
        view.selectedRange = NSRange(location: view.textStorage.length, length: 0)
        view.insertText(" geht weiter")
        s.editor.objects.endTextEditing()
        try await BildProbe.wait("Text gespeichert") { await self.object(s, s.lined, "a")?["text"] == "Erster Block geht weiter" }
        let count = await s.store.objects(forPageKey: s.lined).count
        XCTAssertEqual(count, 2, "kein neuer Block darueber")

        // einfaches Textfeld: Text aendern, nichts formatieren
        s.editor.objects.beginTextEditing(key: s.lined, id: "old", isNew: false)
        try await BildProbe.wait("Textfeld wird bearbeitet") { s.editor.objects.editing?.id == "old" }
        view = try XCTUnwrap(s.editor.objects.editingTextView)
        view.insertText(" und neu")
        s.editor.objects.endTextEditing()
        try await BildProbe.wait("Textfeld gespeichert") { await self.object(s, s.lined, "old")?["text"] == "alt und neu" }
        let kept = await object(s, s.lined, "old")
        XCTAssertNil(kept?["block"], "ohne Formatierung bleibt es das Textfeld des Web-Editors")
        XCTAssertNil(kept?["runs"])
        // ... erst mit Formatierung wird es ein Block
        s.editor.objects.beginTextEditing(key: s.lined, id: "old", isNew: false)
        try await BildProbe.wait("wieder offen") { s.editor.objects.editing?.id == "old" }
        view = try XCTUnwrap(s.editor.objects.editingTextView)
        view.selectedRange = NSRange(location: 0, length: 3)
        s.editor.objects.format(.underline(true))
        s.editor.objects.endTextEditing()
        try await BildProbe.wait("formatiert gespeichert") { await self.object(s, s.lined, "old")?["block"] == 1 }
        let now = await object(s, s.lined, "old")
        XCTAssertEqual(now?["runs"], [["text": "alt", "underline": true], ["text": " und neu"]])
        // Text ganz geloescht: der Block verschwindet
        s.editor.objects.beginTextEditing(key: s.lined, id: "a", isNew: false)
        try await BildProbe.wait("a offen") { s.editor.objects.editing?.id == "a" }
        view = try XCTUnwrap(s.editor.objects.editingTextView)
        view.selectedRange = NSRange(location: 0, length: view.textStorage.length)
        view.insertText("")
        view.textStorage.setAttributedString(NSAttributedString())
        s.editor.objects.endTextEditing()
        try await BildProbe.wait("leerer Block entfernt") { await self.object(s, s.lined, "a") == nil }
    }

    /// Ganze Bloecke formatieren (ausgewaehlt, ohne zu tippen): Schriftart, Groesse, Farbe, Ausrichtung; Rueckgaengig
    /// stellt den Stand davor her. Die Leiste erscheint nur fuer Text.
    func testGanzeBloeckeFormatieren() async throws {
        try ContainerTestBed.requireEventGroupedUndo()
        let s = try await open()
        _ = try await overlay(s, key: s.lined)
        let a = TextBlock.setting([TextBlock.Run(text: "fett", style: style { $0.bold = true }),
                                   TextBlock.Run(text: " und normal", style: TextBlock.Style(fontSize: 16))],
                                  in: TextBlock.block(id: "a", x: 60, y: 100, template: "lined", pageWidth: 595))
        let rect = try XCTUnwrap(PageObjectEdit.shape(id: "r", kind: "rect", from: (300, 400), to: (400, 460), color: "#1d2130", width: 2))
        await s.store.editObjects(pageKey: s.lined) { $0 + [a, rect] }
        s.editor.choose(.select)
        await s.editor.objects.selectForTesting(key: s.lined, ids: ["r"])
        XCTAssertNil(s.editor.objects.textFormat, "Form gewaehlt: keine Text-Leiste")
        await s.editor.objects.selectForTesting(key: s.lined, ids: ["a", "r"])
        XCTAssertNil(s.editor.objects.textFormat, "gemischte Auswahl: keine Text-Leiste")
        await s.editor.objects.selectForTesting(key: s.lined, ids: ["a"])
        let f = try XCTUnwrap(s.editor.objects.textFormat)
        XCTAssertFalse(f.editing)
        XCTAssertFalse(f.style.bold, "gemischt fett/normal: Schalter aus")
        XCTAssertTrue(f.lined)

        s.editor.objects.format(.fontFamily("Georgia"))
        try await BildProbe.wait("Schriftart") { await self.object(s, s.lined, "a")?["fontFamily"] == "Georgia" }
        s.editor.objects.format(.sizeDelta(2))
        try await BildProbe.wait("Groesse") { await self.object(s, s.lined, "a")?["fontSize"] == 18 }
        s.editor.objects.format(.fill("#2f7fd1"))
        s.editor.objects.setAlignment("right")
        try await BildProbe.wait("Ausrichtung") { await self.object(s, s.lined, "a")?["align"] == "right" }
        let found3 = await object(s, s.lined, "a")
        let now = try XCTUnwrap(found3)
        XCTAssertEqual(TextBlock.runs(now).map(\.style.fontFamily), ["Georgia", "Georgia"])
        XCTAssertEqual(TextBlock.runs(now).map(\.style.bold), [true, false], "fett bleibt, wo es war")
        XCTAssertEqual(TextBlock.runs(now).map(\.style.fill), ["#2f7fd1", "#2f7fd1"])
        XCTAssertEqual(s.editor.objects.textFormat?.style.fontFamily, "Georgia", "die Leiste zeigt den neuen Stand")
        XCTAssertEqual(s.editor.objects.textFormat?.style.fontSize, 18)
        XCTAssertEqual(firstBaseline(now), firstBaseline(a), accuracy: 0.011, "bleibt auf seiner Linie")
        // die alten Knoepfe der Objektleiste wirken auf alle Abschnitte
        s.editor.objects.resizeText(by: 2)
        try await BildProbe.wait("Schrift groesser") { await self.object(s, s.lined, "a")?["fontSize"] == 20 }
        s.editor.objects.recolorSelection("#e5322d")
        try await BildProbe.wait("Farbe") { await self.object(s, s.lined, "a")?["fill"] == "#e5322d" }
        let found4 = await object(s, s.lined, "a")
        let colored = try XCTUnwrap(found4)
        XCTAssertEqual(TextBlock.runs(colored).map(\.style.fill), ["#e5322d", "#e5322d"])

        s.editor.editUndo.undo()
        try await BildProbe.wait("Rueckgaengig") { await self.object(s, s.lined, "a")?["fill"] == "#2f7fd1" }
        let rectNow = await object(s, s.lined, "r")
        XCTAssertEqual(rectNow, rect, "die Form bleibt unberuehrt")
    }

    /// Aufzaehlung und Nummerierung: an und aus fuer die Zeilen der Auswahl; die Eingabetaste setzt die Liste fort und
    /// beendet sie auf einem leeren Punkt. Die Formatierung der Zeilen bleibt.
    func testListen() async throws {
        let s = try await open()
        _ = try await overlay(s, key: s.blank)
        let a = TextBlock.setting([TextBlock.Run(text: "eins\n", style: TextBlock.Style(bold: true, fontSize: 14)),
                                   TextBlock.Run(text: "zwei\ndrei", style: TextBlock.Style(fontSize: 14))],
                                  in: TextBlock.block(id: "a", x: 60, y: 100, template: "blank", pageWidth: 595))
        await s.store.editObjects(pageKey: s.blank) { $0 + [a] }
        s.editor.choose(.select)
        s.editor.objects.beginTextEditing(key: s.blank, id: "a", isNew: false)
        try await BildProbe.wait("offen") { s.editor.objects.editing?.id == "a" }
        let view = try XCTUnwrap(s.editor.objects.editingTextView)
        view.selectedRange = NSRange(location: 2, length: 6)                           // in Zeile 1 bis Zeile 2
        s.editor.objects.toggleList(.bullet)
        XCTAssertEqual(view.text, "• eins\n• zwei\ndrei")
        view.selectedRange = NSRange(location: 0, length: view.textStorage.length)
        s.editor.objects.toggleList(.number)
        XCTAssertEqual(view.text, "1. eins\n2. zwei\n3. drei")
        // Eingabetaste am Ende: naechste Nummer; noch einmal auf dem leeren Punkt: Liste endet
        let end = NSRange(location: view.textStorage.length, length: 0)
        view.selectedRange = end
        XCTAssertFalse(s.editor.objects.textView(view, shouldChangeTextIn: end, replacementText: "\n"))
        XCTAssertEqual(view.text, "1. eins\n2. zwei\n3. drei\n4. ")
        let end2 = NSRange(location: view.textStorage.length, length: 0)
        XCTAssertFalse(s.editor.objects.textView(view, shouldChangeTextIn: end2, replacementText: "\n"))
        XCTAssertEqual(view.text, "1. eins\n2. zwei\n3. drei\n")
        XCTAssertTrue(s.editor.objects.textView(view, shouldChangeTextIn: NSRange(location: 3, length: 0), replacementText: "x"), "andere Zeichen wie immer")
        s.editor.objects.endTextEditing()
        try await BildProbe.wait("gespeichert") { await self.object(s, s.blank, "a")?["text"] == "1. eins\n2. zwei\n3. drei\n" }
        let found5 = await object(s, s.blank, "a")
        let saved = try XCTUnwrap(found5)
        let bold = TextBlock.runs(saved).filter(\.style.bold).map(\.text).joined()
        XCTAssertEqual(bold, "1. eins\n", "die fette Zeile bleibt fett, samt ihrer Nummer")

        // ganzer Block gewaehlt: Liste fuer alle Zeilen wieder aus
        await s.editor.objects.selectForTesting(key: s.blank, ids: ["a"])
        s.editor.objects.toggleList(.number)
        try await BildProbe.wait("Liste aus") { await self.object(s, s.blank, "a")?["text"] == "eins\nzwei\ndrei\n" }
    }

    // MARK: Verschieben, Groesse, langes Druecken

    /// Ein eingerasteter Block bleibt beim Verschieben und beim Aendern der Breite auf den Linien - schon in der Vorschau
    /// beim Ziehen, und danach gespeichert. Waagerecht frei.
    func testVerschiebenUndGroesseBleibenAufDenLinien() async throws {
        let s = try await open()
        let page = try await overlay(s, key: s.lined)
        let a = TextBlock.setting([TextBlock.Run(text: "Ein Absatz, der ueber mehrere Zeilen laeuft, damit man beim Schmalerziehen sieht, wie er neu umbricht.",
                                                 style: TextBlock.Style(fontSize: 16))],
                                  in: TextBlock.block(id: "a", x: 80, y: 200, template: "lined", pageWidth: 595))
        await s.store.editObjects(pageKey: s.lined) { $0 + [a] }
        try await BildProbe.wait("gezeigt") { page.objectsView.subviews.contains { $0 is TextBlockView } }
        s.editor.choose(.select)
        await s.editor.objects.selectForTesting(key: s.lined, ids: ["a"])
        let y0 = try XCTUnwrap(a["y"]?.double), x0 = try XCTUnwrap(a["x"]?.double)
        let start = CGPoint(x: x0 + 60, y: y0 + 16)

        // Finger zieht 31 nach rechts und 55 nach unten (die ersten Punkte Weg braucht die Geste zum Erkennen): das sind
        // rund 48 pt = zwei Zeilen (24 pt)
        var seen: [CGFloat] = []
        try await BildProbe.drag(from: start, to: CGPoint(x: start.x + 31, y: start.y + 55), on: page, in: s.window) {
            if let v = page.objectsView.subviews.compactMap({ $0 as? TextBlockView }).first { seen.append((v.layer.presentation() ?? v.layer).frame.minY) }
        }
        try await BildProbe.wait("verschoben") { (await self.object(s, s.lined, "a")?["y"]?.double ?? 0) > y0 + 1 }
        let found6 = await object(s, s.lined, "a")
        var now = try XCTUnwrap(found6)
        XCTAssertEqual(now["y"]?.double ?? 0, y0 + 48, accuracy: 0.011)
        let dx = (now["x"]?.double ?? 0) - x0
        XCTAssertTrue(dx > 15 && dx < 31.5 && abs(dx - (dx / 24).rounded() * 24) > 0.2, "waagerecht frei (kein Raster): \(dx)")
        XCTAssertTrue(onLine(firstBaseline(now)))
        XCTAssertFalse(seen.isEmpty)
        for y in seen { XCTAssertEqual((Double(y) - y0).truncatingRemainder(dividingBy: 24), 0, accuracy: 0.05, "Vorschau beim Ziehen: nur ganze Zeilen") }

        // schmaler (Menue "Kleiner", wie die Anfasser): bricht neu um, bleibt auf den Linien
        let width0 = try XCTUnwrap(now["width"]?.double)
        let height0 = ObjectEditing.textHeight(now)
        s.editor.objects.scaleSelection(by: 0.6)
        try await BildProbe.wait("schmaler") { (await self.object(s, s.lined, "a")?["width"]?.double ?? width0) < width0 - 1 }
        let found7 = await object(s, s.lined, "a")
        now = try XCTUnwrap(found7)
        XCTAssertEqual(now["width"]?.double ?? 0, width0 * 0.6, accuracy: 0.6)
        XCTAssertTrue(onLine(firstBaseline(now)), "nach dem Aendern der Breite wieder auf der Linie: \(firstBaseline(now))")
        XCTAssertGreaterThan(ObjectEditing.textHeight(now), height0, "schmaler: mehr Zeilen")
        try await BildProbe.wait("neu umbrochen gezeigt") {
            (page.objectsView.subviews.compactMap { $0 as? TextBlockView }.first?.baselinesOnPage.count ?? 0) >= 3
        }
        let shown = try XCTUnwrap(page.objectsView.subviews.compactMap { $0 as? TextBlockView }.first)
        XCTAssertTrue(shown.baselinesOnPage.map(Double.init).allSatisfy(onLine))
        // Duplizieren (20 pt versetzt): die Kopie rastet ein
        await s.editor.objects.duplicateSelection()
        try await BildProbe.wait("Kopie") { await s.store.objects(forPageKey: s.lined).count == 2 }
        let found8 = await s.store.objects(forPageKey: s.lined).last
        let copy = try XCTUnwrap(found8)
        XCTAssertTrue(onLine(firstBaseline(copy)), "Kopie auf der Linie: \(firstBaseline(copy))")
        XCTAssertNotEqual(copy["y"], now["y"])
    }

    /// Langes Druecken auf einen Block (beim Schreiben mit dem Stift, Finger blaettert): Der Block ist gegriffen -
    /// ausgewaehlt mit Rahmen und Anfassern, Werkzeug "Auswählen", Leiste "Text" - und folgt dem Finger. Daneben
    /// gedrueckt passiert nichts. Bestellt sind 3 Sekunden; der Test stellt die Zeit kuerzer.
    func testLangesDrueckenGreiftDenBlock() async throws {
        XCTAssertEqual(ObjectEditing.holdSeconds, 3, "bestellt: 3 Sekunden")
        let s = try await open()
        let page = try await overlay(s, key: s.blank)
        XCTAssertEqual(s.editor.objects.hold.minimumPressDuration, 3)
        s.editor.objects.hold.minimumPressDuration = 0.5
        let a = TextBlock.setting([TextBlock.Run(text: "Greif mich", style: TextBlock.Style(fontSize: 14))],
                                  in: TextBlock.block(id: "a", x: 80, y: 200, template: "blank", pageWidth: 400))
        await s.store.editObjects(pageKey: s.blank) { $0 + [a] }
        try await BildProbe.wait("gezeigt") { page.objectsView.subviews.contains { $0 is TextBlockView } }
        XCTAssertFalse(s.editor.objects.isActive, "es wird mit dem Stift geschrieben")
        func w(_ p: CGPoint) -> CGPoint { page.content.convert(p, to: nil) }

        // daneben gedrueckt: nichts
        var finger = TestFinger(at: w(CGPoint(x: 300, y: 350)), in: s.window)
        try await Task.sleep(nanoseconds: 900_000_000)
        finger.lift()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(s.editor.objects.hasSelection)
        XCTAssertFalse(s.editor.objects.isActive)

        // kurz angetippt: nichts (zu kurz)
        finger = TestFinger(at: w(CGPoint(x: 110, y: 210)), in: s.window)
        try await Task.sleep(nanoseconds: 150_000_000)
        finger.lift()
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(s.editor.objects.hasSelection)

        // gedrueckt gehalten: gegriffen
        let start = CGPoint(x: 110, y: 210)
        finger = TestFinger(at: w(start), in: s.window)
        try await BildProbe.wait("gegriffen") { s.editor.objects.selection?.ids == ["a"] }
        XCTAssertTrue(s.editor.objects.isActive)
        XCTAssertEqual(s.editor.objects.tool, .select)
        XCTAssertNotNil(BildProbe.frameShown(page), "Rahmen um den Block")
        XCTAssertEqual(BildProbe.handles(page).count, 4, "Anfasser an den Ecken")
        XCTAssertEqual(s.editor.objects.textFormat?.editing, false, "Leiste \"Text\" fuer den ganzen Block")
        // derselbe Finger zieht den Block mit
        for i in 1...10 {
            try await Task.sleep(nanoseconds: 24_000_000)
            finger.move(to: w(CGPoint(x: start.x + CGFloat(i) * 5, y: start.y + CGFloat(i) * 7)))
        }
        try await Task.sleep(nanoseconds: 80_000_000)
        finger.lift()
        try await BildProbe.wait("verschoben") { (await self.object(s, s.blank, "a")?["y"]?.double ?? 0) > 201 }
        let found9 = await object(s, s.blank, "a")
        let now = try XCTUnwrap(found9)
        XCTAssertEqual(now["x"]?.double ?? 0, 80 + 50, accuracy: 1.5)
        XCTAssertEqual(now["y"]?.double ?? 0, 200 + 70, accuracy: 1.5, "blanko: frei verschoben")
        XCTAssertEqual(s.editor.objects.selection?.ids, ["a"], "bleibt gewaehlt: Anfasser fuer die Breite, Leiste fuer die Schrift")
    }

    /// Wann das lange Druecken greifen darf: mit Objektwerkzeug immer, beim Schreiben nur der Finger, wenn er nicht
    /// selbst schreibt; der Stift nie (er schreibt).
    func testLangesDrueckenRegeln() async throws {
        let s = try await open()
        _ = try await overlay(s, key: s.blank)
        let o = s.editor.objects
        XCTAssertTrue(o.holdAccepts(touchType: .direct), "Stift schreibt, Finger blaettert: Finger greift")
        XCTAssertFalse(o.holdAccepts(touchType: .pencil), "der Stift schreibt weiter")
        s.editor.pencilOnly = false
        XCTAssertFalse(o.holdAccepts(touchType: .direct), "Finger schreibt selbst: greift nicht")
        s.editor.pencilOnly = true
        s.editor.choose(.text)
        XCTAssertTrue(o.holdAccepts(touchType: .pencil), "mit Objektwerkzeug greift auch der Stift")
        XCTAssertTrue(o.holdAccepts(touchType: .direct))
        s.editor.choose(.shape)
        XCTAssertFalse(o.holdAccepts(touchType: .direct), "beim Zeichnen von Formen nicht")
    }

    // MARK: Tarif

    /// Ohne Schreiben im Tarif (Free, nach dem Herabstufen): kein Text-Werkzeug, kein neuer Block, kein Greifen, keine
    /// Formatierung - vorhandene Bloecke bleiben sichtbar. Mit Plus geht alles (die uebrigen Tests).
    func testOhnePlusKeinTippenUndKeinFormatieren() async throws {
        XCTAssertFalse(UFFeatureMatrix.notes(plan: .free).canEdit, "Free schreibt nicht")
        XCTAssertTrue(UFFeatureMatrix.notes(plan: .plus).canEdit, "ab Plus")
        XCTAssertTrue(UFFeatureMatrix.notes(plan: .proAI).canEdit)
        let s = try await open(canEdit: true)
        let page = try await overlay(s, key: s.lined)
        let a = TextBlock.setting([TextBlock.Run(text: "aus der Plus-Zeit", style: TextBlock.Style(fontSize: 16))],
                                  in: TextBlock.block(id: "a", x: 80, y: 200, template: "lined", pageWidth: 595))
        await s.store.editObjects(pageKey: s.lined) { $0 + [a] }
        try await BildProbe.wait("gezeigt") { page.objectsView.subviews.contains { $0 is TextBlockView } }

        s.editor.canEdit = false                                                       // herabgestuft
        XCTAssertFalse(s.editor.writable)
        s.editor.choose(.text)
        XCTAssertFalse(s.editor.objects.isActive, "Text-Werkzeug laesst sich nicht waehlen")
        XCTAssertFalse(s.editor.objects.holdAccepts(touchType: .direct), "langes Druecken greift nicht")
        s.editor.addText(on: s.lined, at: CGPoint(x: 100, y: 400), sticky: false)
        s.editor.objects.beginNewText(TextBlock.block(id: "neu", x: 100, y: 400, template: "lined"), key: s.lined)
        XCTAssertNil(s.editor.objects.editingTextView, "kein neuer Block")
        await s.editor.objects.selectForTesting(key: s.lined, ids: ["a"])
        s.editor.objects.format(.bold(true))
        s.editor.objects.toggleList(.bullet)
        s.editor.objects.setAlignment("center")
        try await Task.sleep(nanoseconds: 300_000_000)
        let now = await s.store.objects(forPageKey: s.lined)
        XCTAssertEqual(now, [a], "nichts geaendert")
        XCTAssertTrue(page.objectsView.subviews.contains { $0 is TextBlockView && !$0.isHidden }, "der Block bleibt zu sehen")
    }

    // MARK: Export, Drucken

    /// PDF-Export und Drucken zeichnen den Block im selben Satz: der Text steht als Text in der PDF, die Markierung ist
    /// zu sehen, und die Zeile sitzt auf der Linie.
    func testExportZeichnetDenBlock() async throws {
        let s = try await open()
        _ = try await overlay(s, key: s.lined)
        var a = TextBlock.block(id: "a", x: 80, y: 200, template: "lined", pageWidth: 595)
        a = TextBlock.setting([TextBlock.Run(text: "Export ", style: TextBlock.Style(fontSize: 16)),
                               TextBlock.Run(text: "markiert", style: TextBlock.Style(bold: true, mark: "#f5d90a", fontSize: 16))], in: a)
        await s.store.editObjects(pageKey: s.lined) { $0 + [a] }
        await s.store.flush()
        let layout = try XCTUnwrap(s.store.layout)
        let index = try XCTUnwrap(layout.index(ofKey: s.lined))
        let doc = await s.store.pageStructureDocument()
        let data = PDFExporter.render(layout: layout, pages: doc.pages, images: [:], pageIndices: [index])
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(pdf.pageCount, 1)
        XCTAssertTrue((pdf.page(at: 0)?.string ?? "").contains("Export markiert"), "Text bleibt Text (durchsuchbar): \(pdf.page(at: 0)?.string ?? "")")

        // Bild der Seite: gelbe Markierung hinter "markiert", knapp ueber der Linie; links davon kein Gelb
        let page = try XCTUnwrap(layout.pdf.page(at: index)), entry = try XCTUnwrap(layout.entry(at: index))
        let image = PageRenderer.thumbnail(page: page, entry: entry, objects: [a], images: [:], width: 595, scale: 2)
        let baseline = firstBaseline(a)
        XCTAssertTrue(onLine(baseline))
        let inner = TextBlockRender.layout(a)
        let glyph = inner.manager.glyphRange(forCharacterRange: NSRange(location: 8, length: 6), actualCharacterRange: nil)
        let rect = inner.manager.boundingRect(forGlyphRange: glyph, in: inner.container)
        let px = CGPoint(x: (a["x"]?.double ?? 0) + 4 + Double(rect.midX), y: baseline - 12)
        let marked = try XCTUnwrap(image.pixel(at: px))
        XCTAssertTrue(marked.r > 0.85 && marked.g > 0.75 && marked.b < 0.75, "Markierung gelb: \(marked)")
        let plain = try XCTUnwrap(image.pixel(at: CGPoint(x: (a["x"]?.double ?? 0) + 1, y: baseline - 12)))
        XCTAssertTrue(plain.b > 0.9, "daneben weisses Papier: \(plain)")
    }
}

extension UIImage {
    /// Farbe eines Bildpunkts (Punkt in Punkten des Bilds), 0 ... 1
    func pixel(at p: CGPoint) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        guard let cg = cgImage else { return nil }
        let x = Int(p.x * scale), y = Int(p.y * scale)
        guard x >= 0, y >= 0, x < cg.width, y < cg.height else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: -x, y: -(cg.height - 1 - y), width: cg.width, height: cg.height))
        return (CGFloat(px[0]) / 255, CGFloat(px[1]) / 255, CGFloat(px[2]) / 255)
    }
}
