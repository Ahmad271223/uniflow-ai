import PDFKit
import PencilKit
import SwiftUI
import UniFlowCore
import XCTest
@testable import UniFlow

/// Bilder fuer den Inhaber (Textbloecke "wie Word", 25.11.2026): linierte Seite mit formatierten Bloecken im echten
/// Dokument (iPad), die Leiste "Text" bei gewaehltem Block und beim Tippen, eine leere Seite, die Leseansicht am
/// iPhone und die exportierte Seite. Laeuft nur mit UF_SCREENSHOT_DIR (sonst uebersprungen); prueft dabei den Weg
/// vom Editor bis zur Leiste (`EditorBridge.textFormat`) und dass alles auf den Linien sitzt.
@MainActor
final class TextBlockBilderAppTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        guard let d = ProcessInfo.processInfo.environment["UF_SCREENSHOT_DIR"], !d.isEmpty else {
            throw XCTSkip("nur mit UF_SCREENSHOT_DIR")
        }
        dir = URL(fileURLWithPath: d)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let before = Entitlements.shared.plan
        Entitlements.shared.setPlanForTesting(.proAI)
        addTeardownBlock { @MainActor in Entitlements.shared.setPlanForTesting(before) }
        HostedEnvironment.accessibilityAutomation(true)
        addTeardownBlock { @MainActor in HostedEnvironment.accessibilityAutomation(false) }
    }

    // MARK: Daten

    private func run(_ text: String, _ change: (inout TextBlock.Style) -> Void = { _ in }) -> TextBlock.Run {
        var s = TextBlock.Style(fontSize: 16)
        change(&s)
        return TextBlock.Run(text: text, style: s)
    }

    /// Bloecke der linierten Seite: Ueberschrift, Absatz mit Markierungen, nummerierte Liste, Merksatz in Handschrift
    private func linedBlocks() -> [JSONValue] {
        func block(_ id: String, x: Double, y: Double, width: Double, _ runs: [TextBlock.Run], align: String = "left") -> JSONValue {
            var o = TextBlock.block(id: id, x: x, y: y, template: "lined", pageWidth: x + width + 36 - TextBlock.padding)
            o["align"] = .string(align)
            return TextBlock.saving(runs, in: o)
        }
        return [
            block("titel", x: 48, y: 70, width: 500, [run("Zellbiologie – Mitose") { $0.fontSize = 26; $0.bold = true; $0.fontFamily = "Georgia" }]),
            block("absatz", x: 48, y: 130, width: 500, [
                run("Die "), run("Mitose") { $0.bold = true },
                run(" ist die Teilung des Zellkerns. Aus einer Mutterzelle entstehen "),
                run("zwei genetisch gleiche Tochterzellen") { $0.mark = "#f5d90a" },
                run(". Davor wird die DNA in der "), run("Interphase") { $0.italic = true; $0.fill = "#2f7fd1" },
                run(" verdoppelt; "), run("ohne Verdopplung") { $0.underline = true }, run(" gäbe es danach nur die halbe Erbinformation."),
            ]),
            block("liste", x: 48, y: 260, width: 300, [
                run("Phasen der Mitose\n") { $0.bold = true },
                run("1. Prophase\n2. Metaphase\n3. Anaphase\n4. Telophase"),
            ]),
            block("merke", x: 370, y: 284, width: 180, [
                run("Merke: ") { $0.fontFamily = "Noteworthy"; $0.bold = true; $0.fill = "#e5322d" },
                run("PMAT – so heißt die Reihenfolge.") { $0.fontFamily = "Noteworthy" },
            ]),
            block("rechts", x: 48, y: 420, width: 500, [
                run("Meiose kommt in der nächsten Vorlesung.") { $0.strike = true },
                run(" Stoff bis Seite 48.") { $0.mark = "#7ee081" },
            ], align: "right"),
        ]
    }

    private func blankBlocks() -> [JSONValue] {
        func block(_ id: String, x: Double, y: Double, width: Double, _ runs: [TextBlock.Run], align: String = "left") -> JSONValue {
            var o = TextBlock.block(id: id, x: x, y: y, template: "blank", pageWidth: x + width + 36)
            o["align"] = .string(align)
            // Grundschrift auf der leeren Seite: 14 pt
            let sized = runs.map { r -> TextBlock.Run in
                var style = r.style
                if style.fontSize == 16 { style.fontSize = 14 }
                return TextBlock.Run(text: r.text, style: style)
            }
            return TextBlock.saving(sized, in: o)
        }
        return [
            block("b-titel", x: 60, y: 60, width: 470, [run("Zusammenfassung Kapitel 3") { $0.fontSize = 28; $0.bold = true; $0.fontFamily = "Avenir Next" }], align: "center"),
            block("b-links", x: 60, y: 130, width: 220, [
                run("Definition\n") { $0.bold = true; $0.fill = "#7a4fd6" },
                run("Ein "), run("Eigenwert") { $0.mark = "#7cc4ff" }, run(" λ einer Matrix A erfüllt A·v = λ·v für einen Vektor v ≠ 0."),
            ]),
            block("b-rechts", x: 310, y: 130, width: 220, [
                run("Vorgehen\n") { $0.bold = true; $0.fill = "#7a4fd6" },
                run("• det(A − λE) = 0 lösen\n• Eigenwerte einsetzen\n• Eigenvektoren bestimmen"),
            ]),
            block("b-code", x: 60, y: 300, width: 470, [run("A = (2 1; 1 2)  →  λ₁ = 1, λ₂ = 3") { $0.fontFamily = "Courier New"; $0.fontSize = 18 }], align: "center"),
        ]
    }

    /// Notizzettel fuer die dritte Seite: alle Farben, Aussehen, Papiere und Groessen
    private func notes() -> [JSONValue] {
        func note(_ id: String, x: Double, y: Double, _ c: StickyNote.Choice, _ runs: [TextBlock.Run]) -> JSONValue {
            let o = StickyNote.note(id: id, x: x, y: y, choice: c, page: (595, 842))
            let base = TextBlock.baseStyle(o)
            return TextBlock.saving(runs.map { r in
                var s = r.style
                s.fontFamily = base.fontFamily
                if s.fontSize == 16 { s.fontSize = base.fontSize }
                return TextBlock.Run(text: r.text, style: s)
            }, in: o)
        }
        let col = StickyNote.colors.map(\.hex)
        return [
            note("z1", x: 110, y: 60, StickyNote.Choice(color: col[0], look: "glue", paper: "plain", size: "m"),
                 [run("Klausur\n") { $0.bold = true }, run("12.02., 9 Uhr\nRaum F102")]),
            note("z2", x: 300, y: 60, StickyNote.Choice(color: col[1], look: "tape", paper: "lined", size: "m"),
                 [run("Bis Freitag:\n") { $0.bold = true }, run("• Blatt 7 abgeben\n• Kap. 4 lesen")]),
            note("z3", x: 490, y: 60, StickyNote.Choice(color: col[3], look: "pin", paper: "grid", size: "m"),
                 [run("det(A − λE) = 0") { $0.mark = "#f5d90a" }, run("\nnicht vergessen!")]),
            note("z4", x: 80, y: 270, StickyNote.Choice(color: col[2], look: "fold", paper: "dots", size: "s"), [run("Frag Tim")]),
            note("z5", x: 215, y: 270, StickyNote.Choice(color: col[4], look: "tape", paper: "plain", size: "s"), [run("Seite 48!") { $0.fill = "#e5322d"; $0.bold = true }]),
            note("z6", x: 420, y: 270, StickyNote.Choice(color: col[5], look: "fold", paper: "lined", size: "l"),
                 [run("Lernplan\n") { $0.bold = true; $0.fontSize = 22 }, run("Mo  Analysis\nDi  Lineare Algebra\nMi  Übung + Karteikarten\nDo  frei")]),
        ]
    }

    /// Notizbuch (liniert) mit einer zweiten, leeren Seite und den Bloecken; dazu etwas Handschrift
    private func scene() async throws -> (api: APIClient, file: LibFile, lined: String, blank: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("textblock-bilder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let host = LocalBackendHost(directory: root.appendingPathComponent("db", isDirectory: true), clock: .fixed(berlin: "2026-11-25T10:00:00")!,
                                    files: LocalFiles(container: root, dataDirectory: "Library/Application Support/UniFlow", tools: AppDocumentTools()))
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
        let fields = NotebookDialog.fields(kind: "notebook", title: "Biologie – Mitschrift", template: "lined",
                                           format: PageFormats.defaultNotebook, orientation: .portrait)
        let created = try await api.form("/api/notebooks", fields: fields)
        let id = try XCTUnwrap(created.s("id"))
        let file = try await api.json("/api/files/\(id)", as: LibFile.self)
        let store = DocumentStore(file: file, api: api)
        await store.load()
        let lined = try XCTUnwrap(store.pageKey(forPageIndex: 0))
        await store.addBlankPage(afterKey: lined, template: "blank")
        let blank = try XCTUnwrap(store.pageKey(forPageIndex: 1))
        await store.editObjects(pageKey: lined) { $0 + self.linedBlocks() }
        await store.editObjects(pageKey: blank) { $0 + self.blankBlocks() }
        await store.addBlankPage(afterKey: blank, template: "blank")
        if let third = store.pageKey(forPageIndex: 2) { await store.editObjects(pageKey: third) { $0 + self.notes() } }
        let pts = (0..<40).map { i -> PKStrokePoint in
            let t = CGFloat(i)
            return PKStrokePoint(location: CGPoint(x: 380 + t * 4, y: 392 + sin(t / 3) * 6), timeOffset: Double(i) * 0.01,
                                 size: CGSize(width: 2.5, height: 2.5), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        store.canvasChanged(pageKey: lined, drawing: PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .systemRed),
                                                                                    path: PKStrokePath(controlPoints: pts, creationDate: Date()))]))
        await store.flush()
        try await Task.sleep(nanoseconds: 300_000_000)
        await store.close()
        return (api, file, lined, blank)
    }

    @discardableResult
    private func run<T>(_ body: @escaping @MainActor () async throws -> T) throws -> T {
        var result: Result<T, Error>?
        Task { @MainActor in
            do { result = .success(try await body()) } catch { result = .failure(error) }
        }
        let end = Date().addingTimeInterval(60)
        while result == nil, Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return try XCTUnwrap(result, "Zeitlimit").get()
    }

    private func shot(_ view: UIView, _ name: String) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let png = UIGraphicsImageRenderer(bounds: view.bounds, format: format).pngData { _ in
            _ = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        try? png.write(to: dir.appendingPathComponent(name + ".png"))
    }

    private func find<T: UIView>(_ type: T.Type, in root: UIView) -> T? {
        if let v = root as? T { return v }
        for s in root.subviews { if let v = find(type, in: s) { return v } }
        return nil
    }

    /// Knopf mit dieser Beschriftung im Fenster (auch in SwiftUI-Ansichten)
    private func button(_ label: String, in root: UIView) -> Bool {
        var out = false
        func visit(_ e: Any, _ depth: Int) {
            guard depth < 60, !out else { return }
            if let o = e as? NSObject {
                if o.accessibilityLabel == label, o.accessibilityTraits.contains(.button) { out = true; return }
                for x in o.accessibilityElements ?? [] { visit(x, depth + 1) }
                let n = o.accessibilityElementCount()
                if n != NSNotFound, n > 0 { for i in 0..<min(n, 500) { if let x = o.accessibilityElement(at: i) { visit(x, depth + 1) } } }
            }
            if let v = e as? UIView { for s in v.subviews { visit(s, depth + 1) } }
        }
        visit(root, 0)
        return out
    }

    private func editor(in env: HostedEnvironment) -> PDFEditorController? {
        guard let pdf = find(PDFView.self, in: env.window) else { return nil }
        var r: UIResponder? = pdf
        while let x = r { if let e = x as? PDFEditorController { return e }; r = x.next }
        return nil
    }

    private func onLine(_ y: CGFloat) -> Bool {
        let n = (Double(y) - TextBlock.firstLine) / TextBlock.lineStep
        return n >= -0.001 && abs(n - n.rounded()) < 0.002
    }

    // MARK: Bilder

    /// iPad: linierte Seite mit Bloecken; ein Block gewaehlt (Rahmen, Anfasser, Leiste "Text"); dann beim Tippen
    func test1IPadLiniert() throws {
        let s = try run { try await self.scene() }
        let env = try hostWithEnvironment(NavigationStack { DocumentView(file: s.file, api: s.api) }, api: s.api, size: CGSize(width: 1180, height: 820))
        env.pump(1.0)
        Entitlements.shared.setPlanForTesting(.proAI)
        var found: PDFEditorController?
        XCTAssertTrue(env.wait(timeout: 20) {
            found = self.editor(in: env)
            return found?.allOverlays.contains { $0.pageKey == s.lined && $0.loaded && $0.window != nil } == true
        }, "Editor mit der linierten Seite")
        let editor = try XCTUnwrap(found)
        Entitlements.shared.setPlanForTesting(.proAI)
        env.pump(1.0)
        let page = try XCTUnwrap(editor.allOverlays.first { $0.pageKey == s.lined && $0.loaded })
        XCTAssertTrue(env.wait(timeout: 10) { page.objectsView.subviews.filter { $0 is TextBlockView }.count == 5 }, "fuenf Bloecke gezeigt")
        for v in page.objectsView.subviews.compactMap({ $0 as? TextBlockView }) {
            XCTAssertTrue(v.baselinesOnPage.allSatisfy(onLine), "Block \(v.object["id"]?.string ?? "?") sitzt auf den Linien: \(v.baselinesOnPage)")
        }
        shot(env.window, "1-ipad-liniert-textbloecke")

        // Block waehlen: Rahmen mit Anfassern und die Leiste "Text" (Weg Editor -> Leiste)
        XCTAssertTrue(editor.richNotes, "Pro AI: Textbloecke erlaubt")
        editor.choose(.select)
        env.pump(0.3)
        XCTAssertFalse(button("Durchgestrichen", in: env.window), "ohne Auswahl keine Leiste")
        try run { await editor.objects.selectForTesting(key: s.lined, ids: ["absatz"]) }
        XCTAssertTrue(env.wait(timeout: 10) { self.button("Durchgestrichen", in: env.window) && self.button("Nummerierung", in: env.window) },
                      "Leiste \"Text\" erscheint")
        env.pump(0.6)
        shot(env.window, "2-ipad-block-gewaehlt-leiste")

        // Tippen: die Textansicht steht genau auf dem Block, die Leiste zeigt den Stand an der Schreibmarke
        editor.objects.beginTextEditing(key: s.lined, id: "absatz", isNew: false)
        XCTAssertTrue(env.wait(timeout: 10) { editor.objects.editingTextView != nil })
        let view = try XCTUnwrap(editor.objects.editingTextView)
        view.selectedRange = NSRange(location: 4, length: 6)                     // "Mitose" (fett)
        editor.objects.textViewDidChangeSelection(view)
        XCTAssertEqual(editor.objects.textFormat?.style.bold, true)
        env.pump(0.6)
        shot(env.window, "3-ipad-tippen-wort-markiert")
        editor.objects.endTextEditing()
        env.pump(0.5)

        // Plus (ohne Pro AI): dieselbe Auswahl zeigt die Knoepfe wie bisher und die Leiste mit Schloss
        Entitlements.shared.setPlanForTesting(.plus)
        env.pump(0.5)
        XCTAssertFalse(editor.richNotes)
        XCTAssertTrue(env.wait(timeout: 10) { self.button(UFRichNotes.title, in: env.window) }, "Schloss-Leiste in Plus")
        XCTAssertFalse(button("Durchgestrichen", in: env.window), "keine Formatknoepfe in Plus")
        env.pump(0.5)
        shot(env.window, "9-ipad-plus-leiste-mit-schloss")
        Entitlements.shared.setPlanForTesting(.proAI)
    }

    /// iPad: leere Seite (frei gesetzt), Ueberschrift gewaehlt
    func test2IPadBlanko() throws {
        let s = try run { try await self.scene() }
        let env = try hostWithEnvironment(NavigationStack { DocumentView(file: s.file, api: s.api) }, api: s.api, size: CGSize(width: 1180, height: 820))
        env.pump(1.0)
        Entitlements.shared.setPlanForTesting(.proAI)
        var found: PDFEditorController?
        XCTAssertTrue(env.wait(timeout: 20) {
            found = self.editor(in: env)
            return found?.allOverlays.contains { $0.loaded && $0.window != nil } == true
        })
        let editor = try XCTUnwrap(found)
        editor.goToPage(1)
        XCTAssertTrue(env.wait(timeout: 20) { editor.allOverlays.contains { $0.pageKey == s.blank && $0.loaded && $0.window != nil } })
        env.pump(1.0)
        Entitlements.shared.setPlanForTesting(.proAI)
        editor.choose(.select)
        try run { await editor.objects.selectForTesting(key: s.blank, ids: ["b-rechts"]) }
        env.pump(0.8)
        shot(env.window, "4-ipad-blanko-textbloecke")
    }

    /// iPad: Notizzettel (Farben, Klebestreifen, Pinnnadel, geknickte Ecke, Papiere, Groessen), einer gewaehlt
    func test5IPadNotizzettel() throws {
        let s = try run { try await self.scene() }
        let env = try hostWithEnvironment(NavigationStack { DocumentView(file: s.file, api: s.api) }, api: s.api, size: CGSize(width: 1180, height: 820))
        env.pump(1.0)
        Entitlements.shared.setPlanForTesting(.proAI)
        var found: PDFEditorController?
        XCTAssertTrue(env.wait(timeout: 20) {
            found = self.editor(in: env)
            return found?.allOverlays.contains { $0.loaded && $0.window != nil } == true
        })
        let editor = try XCTUnwrap(found)
        editor.goToPage(2)
        var page: PageInkView?
        XCTAssertTrue(env.wait(timeout: 20) {
            page = editor.allOverlays.first { $0.pageIndex == 2 && $0.loaded && $0.window != nil }
            return (page?.objectsView.subviews.filter { $0 is TextBlockView }.count ?? 0) == 6
        }, "sechs Zettel gezeigt")
        env.pump(1.0)
        Entitlements.shared.setPlanForTesting(.proAI)
        shot(env.window, "10-ipad-notizzettel")
        editor.choose(.select)
        let key = try XCTUnwrap(page?.pageKey)
        try run { await editor.objects.selectForTesting(key: key, ids: ["z2"]) }
        XCTAssertTrue(env.wait(timeout: 10) { self.button("Zettel gestalten", in: env.window) }, "Menue \"Zettel\" in der Leiste")
        env.pump(0.6)
        shot(env.window, "11-ipad-notizzettel-gewaehlt")
        // Einstellungen des Werkzeugs (Auswahl fuer neue Zettel)
        let options = StickyNoteOptions().padding(16).background(UF.surface)
        let host = try hostWithEnvironment(options, api: s.api, size: CGSize(width: 360, height: 330))
        host.pump(0.6)
        shot(host.view, "12-notizzettel-auswahl")
    }

    /// iPhone: Leseansicht zeigt die Bloecke vom iPad (dort wird nicht geschrieben)
    func test3IPhoneLesen() throws {
        let s = try run { try await self.scene() }
        let size = CGSize(width: 402, height: 874)
        let before = UFEditorAvailability.forcedReaderOnlyForTesting
        UFEditorAvailability.forcedReaderOnlyForTesting = true
        addTeardownBlock { @MainActor in UFEditorAvailability.forcedReaderOnlyForTesting = before }
        let view = NavigationStack { PhoneDocumentReader(file: s.file, api: s.api) }
            .environment(\.ufWindowWidth, size.width).environment(\.ufCompact, true)
        let env = try hostWithEnvironment(view, api: s.api, size: size)
        env.hosting.traitOverrides.horizontalSizeClass = .compact
        var pdf: PDFView?
        XCTAssertTrue(env.wait(timeout: 20) {
            pdf = self.find(PDFView.self, in: env.window)
            return (pdf?.document?.pageCount ?? 0) == 3
        }, "Leseansicht geladen")
        let pdfView = try XCTUnwrap(pdf)
        var overlay: PageInkView?
        XCTAssertTrue(env.wait(timeout: 20) {
            guard let p = pdfView.document?.page(at: 0) else { return false }
            overlay = pdfView.pageOverlayViewProvider?.pdfView(pdfView, overlayViewFor: p) as? PageInkView
            return overlay?.loaded == true && (overlay?.objectsView.subviews.filter { $0 is TextBlockView }.count ?? 0) == 5
        }, "Bloecke in der Leseansicht")
        for v in overlay?.objectsView.subviews.compactMap({ $0 as? TextBlockView }) ?? [] {
            XCTAssertTrue(v.baselinesOnPage.allSatisfy(onLine), "auch am iPhone auf den Linien")
        }
        XCTAssertEqual(overlay?.isUserInteractionEnabled, false, "am iPhone wird nicht geschrieben")
        env.pump(1.0)
        shot(env.window, "5-iphone-lesen-textbloecke")
    }

    /// Exportierte Seiten (wie PDF-Export und Drucken) als Bild
    func test4Export() throws {
        let s = try run { try await self.scene() }
        let store = DocumentStore(file: s.file, api: s.api)
        try run { await store.load() }
        let layout = try XCTUnwrap(store.layout)
        let doc = try run { await store.pageStructureDocument() }
        for (i, name) in [(0, "6-export-liniert"), (1, "7-export-blanko"), (2, "13-export-notizzettel")] {
            let page = try XCTUnwrap(layout.pdf.page(at: i)), entry = try XCTUnwrap(layout.entry(at: i))
            let image = PageRenderer.thumbnail(page: page, entry: entry, objects: doc.objects(page: entry.key), images: [:], width: 595, scale: 2)
            try image.pngData()?.write(to: dir.appendingPathComponent(name + ".png"))
        }
        let data = PDFExporter.render(layout: layout, pages: doc.pages, images: [:])
        try data.write(to: dir.appendingPathComponent("8-export.pdf"))
        XCTAssertTrue((PDFDocument(data: data)?.page(at: 0)?.string ?? "").contains("Mitose"))
        try run { await store.close() }
    }
}
