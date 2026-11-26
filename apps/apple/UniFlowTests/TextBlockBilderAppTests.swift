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
    /// Mitte des Verweises ueber dem Wort "Mitose" (Seitenpunkte), in `test7IPadVerweise` berechnet
    private var wordSpot = CGPoint(x: 100, y: 147)

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

    /// Lernseite zum Abfragen (vierte Seite, liniert): Fragen mit Antworten, die Antworten unter Klappkarten
    private func quiz() -> [JSONValue] {
        func block(_ id: String, y: Double, _ runs: [TextBlock.Run]) -> JSONValue {
            TextBlock.saving(runs, in: TextBlock.block(id: id, x: 48, y: y, template: "lined", pageWidth: 560))
        }
        let cols = FlipCover.colors.map(\.hex)
        // Zeilen bei 84, 132, 180, 228 (Grundlinien); Antworten jeweils rechts
        return [
            block("q0", y: 70, [run("Abfragen: Mitose") { $0.bold = true; $0.fontSize = 20 }]),
            block("q1", y: 118, [run("Wie viele Tochterzellen entstehen?   "), run("Zwei, genetisch gleich") { $0.bold = true }]),
            block("q2", y: 166, [run("In welcher Phase wird die DNA verdoppelt?   "), run("Interphase") { $0.bold = true }]),
            block("q3", y: 214, [run("Reihenfolge der Phasen?   "), run("Pro-, Meta-, Ana-, Telophase") { $0.bold = true }]),
            block("q4", y: 262, [run("Skizze der Metaphase (Handschrift):")]),
            FlipCover.cover(id: "k1", x: 300, y: 116, width: 190, height: 26, choice: FlipCover.Choice(color: cols[0], pattern: "stripes")),
            FlipCover.cover(id: "k2", x: 356, y: 164, width: 100, height: 26, choice: FlipCover.Choice(color: cols[1], pattern: "question")),
            FlipCover.cover(id: "k3", x: 232, y: 212, width: 250, height: 26, choice: FlipCover.Choice(color: cols[4], pattern: "dots")),
            FlipCover.cover(id: "k4", x: 60, y: 300, width: 300, height: 110, choice: FlipCover.Choice(color: cols[2], pattern: "grid")),
            FlipCover.cover(id: "k5", x: 400, y: 320, width: 130, height: 60, choice: FlipCover.Choice(color: cols[5], pattern: "plain")),
        ]
    }

    private func sketch() -> PKDrawing {
        func stroke(_ pts: [CGPoint], _ color: UIColor) -> PKStroke {
            PKStroke(ink: PKInk(.pen, color: color), path: PKStrokePath(controlPoints: pts.enumerated().map { i, p in
                PKStrokePoint(location: p, timeOffset: Double(i) * 0.01, size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }, creationDate: Date()))
        }
        var circle: [CGPoint] = []
        for i in 0...40 {
            let a = CGFloat(i) / 40 * 2 * CGFloat.pi
            circle.append(CGPoint(x: 210 + cos(a) * 120, y: 355 + sin(a) * 42))
        }
        var line: [CGPoint] = []
        for i in 0...10 { line.append(CGPoint(x: 210, y: 320 + CGFloat(i) * 7)) }
        var upper: [CGPoint] = [], lower: [CGPoint] = []
        for i in 0...6 {
            let x: CGFloat = 195 + CGFloat(i) * 5, wobble: CGFloat = CGFloat(i % 2) * 6
            upper.append(CGPoint(x: x, y: 340 + wobble))
            lower.append(CGPoint(x: x, y: 362 + wobble))
        }
        var note: [CGPoint] = []
        for i in 0...30 {
            let t = CGFloat(i)
            note.append(CGPoint(x: 410 + t * 3.6, y: 350 + sin(t / 2.2) * 12))
        }
        let strokes: [PKStroke] = [stroke(circle, .black), stroke(line, .systemBlue), stroke(upper, .systemRed), stroke(lower, .systemRed),
                                   stroke(note, .systemPurple)]
        return PKDrawing(strokes: strokes)
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
        if let third = store.pageKey(forPageIndex: 2) {
            await store.editObjects(pageKey: third) { $0 + self.notes() }
            await store.addBlankPage(afterKey: third, template: "lined")
            if let fourth = store.pageKey(forPageIndex: 3) {
                await store.editObjects(pageKey: fourth) { $0 + self.quiz() }
                store.canvasChanged(pageKey: fourth, drawing: sketch())
            }
        }
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

    /// iPad: Klappkarten ueber Text und Handschrift - alle verdeckt, zwei durch Antippen aufgedeckt, eine gewaehlt
    func test6IPadKlappkarten() throws {
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
        editor.goToPage(3)
        var page: PageInkView?
        XCTAssertTrue(env.wait(timeout: 20) {
            page = editor.allOverlays.first { $0.pageIndex == 3 && $0.loaded && $0.window != nil }
            return (page?.coversView.subviews.filter { $0 is CoverView }.count ?? 0) == 5 && (page?.canvas.drawing.strokes.count ?? 0) > 0
        }, "fuenf Klappkarten und die Skizze")
        let overlay = try XCTUnwrap(page)
        env.pump(1.0)
        Entitlements.shared.setPlanForTesting(.proAI)
        shot(env.window, "14-ipad-klappkarten-verdeckt")
        // echtes Antippen: zwei Karten klappen auf
        for p in [CGPoint(x: 400, y: 177), CGPoint(x: 200, y: 350)] {
            let finger = TestFinger(at: overlay.content.convert(p, to: nil), in: env.window)
            env.pump(0.06)
            finger.lift()
            env.pump(0.6)
        }
        XCTAssertEqual(overlay.coversView.revealed, ["k2", "k4"], "zwei Karten aufgedeckt")
        shot(env.window, "15-ipad-klappkarten-zwei-aufgedeckt")
        editor.choose(.select)
        try run { await editor.objects.selectForTesting(key: overlay.pageKey, ids: ["k3"]) }
        XCTAssertTrue(env.wait(timeout: 10) { self.button("Klappkarte gestalten", in: env.window) }, "Menue \"Klappkarte\" in der Objektleiste")
        env.pump(0.5)
        shot(env.window, "16-ipad-klappkarte-gewaehlt")
        let host = try hostWithEnvironment(CoverOptions().padding(16).background(UF.surface), api: s.api, size: CGSize(width: 360, height: 300))
        host.pump(0.6)
        shot(host.view, "17-klappkarten-auswahl")
    }

    /// Skript (PDF, 6 Seiten) als Ziel der Verweise
    private func skript() -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { ctx in
            for i in 1...6 {
                ctx.beginPage()
                ("Skript Zellbiologie – Seite \(i)" as NSString).draw(at: CGPoint(x: 60, y: 60), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 22)])
                let body = i == 4 ? "4.2 Mitose\nDie Mitose verläuft in vier Phasen: Prophase, Metaphase, Anaphase, Telophase.\nIn der Metaphase ordnen sich die Chromosomen in der Äquatorialebene an."
                                  : "Kapitel \(i): Text des Skripts auf Seite \(i)."
                (body as NSString).draw(in: CGRect(x: 60, y: 130, width: 470, height: 300), withAttributes: [.font: UIFont.systemFont(ofSize: 15)])
            }
        }
    }

    private func editors(in env: HostedEnvironment) -> [PDFEditorController] {
        var out: [PDFEditorController] = []
        func walk(_ v: UIView) {
            if let pdf = v as? PDFView {
                var r: UIResponder? = pdf
                while let x = r { if let e = x as? PDFEditorController { if !out.contains(where: { $0 === e }) { out.append(e) }; break }; r = x.next }
                return
            }
            v.subviews.forEach(walk)
        }
        walk(env.window)
        return out
    }

    /// iPad: Verweise - ein Punkt und ein Wort auf der Mitschrift zeigen auf Seite 4 des Skripts. Antippen oeffnet das
    /// Skript daneben auf der Seite; ein zweiter Verweis (Seite 2) schickt das offene Skript dorthin.
    func test7IPadVerweise() throws {
        let s = try run { try await self.scene() }
        let skriptID = try run { () -> String in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("skript-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let src = dir.appendingPathComponent("Skript Zellbiologie.pdf")
            try self.skript().write(to: src)
            return try await ExternalFileImport.create(try ExternalFileImport.stage(src, container: nil), api: s.api)
        }
        // Verweise auf der linierten Seite: Bereich ueber "Mitose" (Seite 4, Stelle der Ueberschrift), Punkt (Seite 2)
        let t4 = PageLink.Target(file: skriptID, title: "Skript Zellbiologie", pageKey: "p4", pdfPage: 4, pageNumber: 4, x: 100, y: 140)
        let t2 = PageLink.Target(file: skriptID, title: "Skript Zellbiologie", pageKey: "p2", pdfPage: 2, pageNumber: 2, x: 100, y: 70)
        try run {
            let store = DocumentStore(file: s.file, api: s.api)
            await store.load()
            // Bereich genau ueber dem Wort "Mitose" im Absatz (Zeichen 4 bis 9)
            let absatz = await store.objects(forPageKey: s.lined).first { $0["id"]?.string == "absatz" }
            var word = CGRect(x: 79, y: 136, width: 52, height: 22)
            if let absatz {
                let l = TextBlockRender.layout(absatz)
                let glyphs = l.manager.glyphRange(forCharacterRange: NSRange(location: 4, length: 6), actualCharacterRange: nil)
                let r = l.manager.boundingRect(forGlyphRange: glyphs, in: l.container)
                word = CGRect(x: (absatz["x"]?.double ?? 0) + 4 + Double(r.minX) - 1, y: (absatz["y"]?.double ?? 0) + 4 + Double(r.minY) + 2,
                              width: Double(r.width) + 2, height: Double(r.height) - 2)
            }
            await store.editObjects(pageKey: s.lined) {
                $0 + [PageLink.area(id: "v-wort", x: Double(word.minX), y: Double(word.minY), width: Double(word.width), height: Double(word.height), target: t4),
                      PageLink.point(id: "v-punkt", x: 330, y: 276, target: t2)]
            }
            self.wordSpot = CGPoint(x: word.midX, y: word.midY)
            await store.flush()
            await store.close()
        }
        let previous = UserDefaults.standard.object(forKey: "UFDocPanel")
        addTeardownBlock { @MainActor in UserDefaults.standard.set(previous, forKey: "UFDocPanel") }
        let env = try hostWithEnvironment(NavigationStack { DocumentView(file: s.file, api: s.api) }, api: s.api, size: CGSize(width: 1180, height: 820))
        env.pump(1.0)
        Entitlements.shared.setPlanForTesting(.proAI)
        var main: PDFEditorController?
        var page: PageInkView?
        XCTAssertTrue(env.wait(timeout: 20) {
            main = self.editors(in: env).first
            page = main?.allOverlays.first { $0.pageKey == s.lined && $0.loaded && $0.window != nil }
            return (page?.coversView.subviews.filter { $0 is LinkView }.count ?? 0) == 2
        }, "zwei Verweise auf der Seite")
        let overlay = try XCTUnwrap(page)
        env.pump(1.0)
        Entitlements.shared.setPlanForTesting(.proAI)
        shot(env.window, "20-ipad-verweise-auf-der-seite")

        // Verweis ueber dem Wort antippen: das Skript oeffnet sich daneben auf Seite 4
        func tap(_ p: CGPoint, on overlay: PageInkView) {
            let finger = TestFinger(at: overlay.content.convert(p, to: nil), in: env.window)
            env.pump(0.06)
            finger.lift()
            env.pump(0.5)
        }
        XCTAssertEqual(editors(in: env).count, 1, "noch nichts daneben")
        tap(wordSpot, on: overlay)
        var side: PDFEditorController?
        XCTAssertTrue(env.wait(timeout: 25) {
            side = self.editors(in: env).first { $0.store.file.id == skriptID }
            return side?.currentPageIndex == 3
        }, "Skript daneben auf Seite 4: \(self.editors(in: env).map { $0.store.file.id }) Seite \(String(describing: side?.currentPageIndex))")
        Entitlements.shared.setPlanForTesting(.proAI)
        env.pump(0.5)
        shot(env.window, "21-ipad-verweis-oeffnet-skript-daneben")

        // zweiter Verweis (Punkt): das offene Skript springt auf Seite 2 (kein neues Laden)
        let sideBefore = try XCTUnwrap(side)
        // das Hauptdokument ist jetzt schmaler (geteilte Ansicht): seine Seite neu suchen
        var again: PageInkView?
        XCTAssertTrue(env.wait(timeout: 10) {
            again = self.editors(in: env).first { $0.store.file.id == s.file.id }?
                .allOverlays.first { $0.pageKey == s.lined && $0.loaded && $0.window != nil }
            return again != nil
        }, "Seite des Hauptdokuments")
        let mainPage = try XCTUnwrap(again)
        let punkt = mainPage.content.convert(CGPoint(x: 330, y: 276), to: nil)
        XCTAssertTrue(env.window.bounds.contains(punkt), "Punkt-Verweis im Bild: \(punkt)")
        tap(CGPoint(x: 330, y: 276), on: mainPage)
        XCTAssertTrue(env.wait(timeout: 15) { sideBefore.currentPageIndex == 1 }, "offenes Skript springt auf Seite 2: \(sideBefore.currentPageIndex)")
        XCTAssertTrue(editors(in: env).contains { $0 === sideBefore }, "dasselbe Dokument daneben, nicht neu geoeffnet")
        env.pump(0.4)
        shot(env.window, "22-ipad-verweis-springt-im-offenen-skript")
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
            return (pdf?.document?.pageCount ?? 0) == 4
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

        // Klappkarten in der Leseansicht: Seite 4, eine Karte per Antippen aufdecken und wieder verdecken
        guard let quizPage = pdfView.document?.page(at: 3) else { return XCTFail("Seite 4 fehlt") }
        pdfView.go(to: quizPage)
        var quiz: PageInkView?
        XCTAssertTrue(env.wait(timeout: 20) {
            quiz = pdfView.pageOverlayViewProvider?.pdfView(pdfView, overlayViewFor: quizPage) as? PageInkView
            return quiz?.loaded == true && quiz?.window != nil && (quiz?.coversView.subviews.filter { $0 is CoverView }.count ?? 0) == 5
        }, "Klappkarten in der Leseansicht")
        let q = try XCTUnwrap(quiz)
        env.pump(1.0)
        let spot = q.content.convert(CGPoint(x: 395, y: 129), to: nil)
        XCTAssertTrue(env.window.bounds.contains(spot), "Karte im Bild: \(spot)")
        var finger = TestFinger(at: spot, in: env.window)
        env.pump(0.06)
        finger.lift()
        env.pump(0.6)
        XCTAssertEqual(q.coversView.revealed, ["k1"], "am iPhone klappt die Karte beim Antippen auf")
        shot(env.window, "18-iphone-klappkarte-aufgedeckt")
        finger = TestFinger(at: spot, in: env.window)
        env.pump(0.06)
        finger.lift()
        env.pump(0.6)
        XCTAssertTrue(q.coversView.revealed.isEmpty, "und wieder zu")
    }

    // MARK: Tabelle ("Excel", 26.11.2026)

    /// Notenuebersicht mit Formeln, Farben, Rahmen und einem Balkendiagramm
    private func gradeSheet() -> Sheet {
        var t = Sheet(rows: 7, cols: 5)
        let cells: [String: String] = [
            "A1": "Fach", "B1": "Note", "C1": "LP", "D1": "Note × LP", "E1": "Bestanden",
            "A2": "Mathe 2", "B2": "1,7", "C2": "10", "A3": "Physik", "B3": "2,3", "C3": "5",
            "A4": "Informatik", "B4": "1,3", "C4": "10", "A5": "Chemie", "B5": "3,7", "C5": "5",
            "A6": "Statistik", "B6": "5,0", "C6": "5",
            "A7": "Schnitt / Summe", "B7": "=RUNDEN(SUMME(D2:D6)/SUMME(C2:C6);2)", "C7": "=SUMME(C2:C6)", "D7": "=SUMME(D2:D6)",
            "E7": "=ZÄHLENWENN(E2:E6;\"ja\")&\" von 5\"",
        ]
        for (k, v) in cells { t.set(v, at: SheetRef(k)!) }
        for r in 2...6 {
            t.set("=B\(r)*C\(r)", at: SheetRef("D\(r)")!)
            t.set("=WENN(B\(r)<=4;\"ja\";\"nein\")", at: SheetRef("E\(r)")!)
        }
        t.setWidth(120, col: 0)
        t.restyle(SheetRange("A1:E1")!) { $0.fill = "#cfe8ff" }
        t.restyle(SheetRange("B2:B7")!) { $0.format = "n"; $0.decimals = 1 }
        t.restyle(SheetRange("B7")!) { $0.decimals = 2 }
        t.restyle(SheetRange("A7:E7")!) { $0.bold = true; $0.fill = "#fff7a8" }
        t.restyle(SheetRange("E6")!) { $0.color = "#d7263d"; $0.bold = true }
        t.restyle(SheetRange("E2:E7")!) { $0.align = "c" }
        t.setBorder(SheetRange("A1:E7")!, "outer")
        t.setBorder(SheetRange("A6:E6")!, "bottom")
        t.charts = [SheetChart(id: "d1", kind: "bar", range: SheetRange("A1:B6")!, title: "Noten in diesem Semester")]
        return t
    }

    private func sheetScene() async throws -> (api: APIClient, file: LibFile, page: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tabelle-bilder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let host = LocalBackendHost(directory: root.appendingPathComponent("db", isDirectory: true), clock: .fixed(berlin: "2026-11-26T10:00:00")!,
                                    files: LocalFiles(container: root, dataDirectory: "Library/Application Support/UniFlow", tools: AppDocumentTools()))
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
        let fields = NotebookDialog.fields(kind: "notebook", title: "Noten – Übersicht", template: "blank",
                                           format: PageFormats.defaultNotebook, orientation: .portrait)
        let created = try await api.form("/api/notebooks", fields: fields)
        let id = try XCTUnwrap(created.s("id"))
        let file = try await api.json("/api/files/\(id)", as: LibFile.self)
        let store = DocumentStore(file: file, api: api)
        await store.load()
        let page = try XCTUnwrap(store.pageKey(forPageIndex: 0))
        let title = TextBlock.saving([run("Meine Noten im 3. Semester") { $0.fontSize = 24; $0.bold = true; $0.fontFamily = "Georgia" }],
                                     in: TextBlock.block(id: "titel", x: 48, y: 50, template: "blank", pageWidth: 560))
        var table = SheetObject.object(id: "tabelle", x: 48, y: 110, sheet: gradeSheet(), page: (595, 842))
        table["width"] = 500
        await store.editObjects(pageKey: page) { $0 + [title, table] }
        await store.flush()
        try await Task.sleep(nanoseconds: 300_000_000)
        await store.close()
        return (api, file, page)
    }

    /// iPad: Tabelle mit Diagramm auf der Seite (gewaehlt: Knopf "Bearbeiten"), dann die grosse Ansicht
    func test8IPadTabelle() throws {
        let s = try run { try await self.sheetScene() }
        let env = try hostWithEnvironment(NavigationStack { DocumentView(file: s.file, api: s.api) }, api: s.api, size: CGSize(width: 1180, height: 820))
        env.pump(1.0)
        Entitlements.shared.setPlanForTesting(.proAI)
        var found: PDFEditorController?
        XCTAssertTrue(env.wait(timeout: 20) {
            found = self.editor(in: env)
            return found?.allOverlays.contains { $0.pageKey == s.page && $0.loaded && $0.window != nil } == true
        })
        let editor = try XCTUnwrap(found)
        XCTAssertTrue(env.wait(timeout: 10) { editor.allOverlays.contains { $0.objectsView.subviews.contains { $0 is SheetBoxView } } }, "Tabelle auf der Seite")
        editor.choose(.select)
        try run { await editor.objects.selectForTesting(key: s.page, ids: ["tabelle"]) }
        env.pump(0.8)
        XCTAssertTrue(button("Tabelle bearbeiten", in: env.window), "Objektleiste: Bearbeiten")
        shot(env.window, "23-ipad-tabelle-auf-der-seite")

        editor.objects.openSheet(key: s.page, id: "tabelle", title: "Noten – Übersicht")
        XCTAssertTrue(env.wait(timeout: 10) { editor.presentedViewController is UIHostingController<SheetEditorView> }, "grosse Ansicht")
        env.pump(1.2)
        let big = try XCTUnwrap(editor.presentedViewController?.view)
        XCTAssertNotNil(find(SheetGridView.self, in: big))
        shot(big, "24-ipad-tabelle-grosse-ansicht")
        editor.dismiss(animated: false)
        env.pump(0.5)

        // Formel beim Tippen (die gelesenen Zellen sind farbig), Filter und Kreisdiagramm
        let model = SheetEditorModel(sheet: gradeSheet(), title: "Noten – Übersicht")
        model.select(SheetRef("A2")!)
        model.toggleFilter("Statistik")
        model.select(SheetRange("A1:C5")!)
        model.addChart("pie")
        if let id = model.sheet.charts.last?.id { model.updateChart(id) { $0.title = "Leistungspunkte je Fach"; $0.range = SheetRange("A1:C5")! } }
        model.select(SheetRef("D7")!)
        let view = SheetEditorView(model: model, onSave: { _ in }, onClose: {})
        let env2 = try hostWithEnvironment(view, api: s.api, size: CGSize(width: 1180, height: 820))
        env2.pump(1.0)
        model.beginEditing()
        env2.pump(1.2)
        XCTAssertEqual(model.editing, "=SUMME(D2:D6)")
        shot(env2.window, "25-ipad-tabelle-formel-filter-kreis")
        model.cancelEditing()
        env2.pump(0.3)
    }

    /// iPhone: Tabelle und Diagramm in der Leseansicht
    func test9IPhoneTabelle() throws {
        let s = try run { try await self.sheetScene() }
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
            return (pdf?.document?.pageCount ?? 0) == 1
        }, "Leseansicht geladen")
        let pdfView = try XCTUnwrap(pdf)
        var overlay: PageInkView?
        XCTAssertTrue(env.wait(timeout: 20) {
            guard let p = pdfView.document?.page(at: 0) else { return false }
            overlay = pdfView.pageOverlayViewProvider?.pdfView(pdfView, overlayViewFor: p) as? PageInkView
            return overlay?.loaded == true && overlay?.objectsView.subviews.contains { $0 is SheetBoxView } == true
        }, "Tabelle in der Leseansicht")
        let box = try XCTUnwrap(overlay?.objectsView.subviews.compactMap { $0 as? SheetBoxView }.first)
        XCTAssertEqual(box.bounds.width, 500, accuracy: 0.5)
        env.pump(1.0)
        shot(env.window, "26-iphone-tabelle-lesen")
    }

    /// Exportierte Seiten (wie PDF-Export und Drucken) als Bild
    func test4Export() throws {
        let s = try run { try await self.scene() }
        let store = DocumentStore(file: s.file, api: s.api)
        try run { await store.load() }
        let layout = try XCTUnwrap(store.layout)
        let doc = try run { await store.pageStructureDocument() }
        for (i, name) in [(0, "6-export-liniert"), (1, "7-export-blanko"), (2, "13-export-notizzettel"), (3, "19-export-klappkarten")] {
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
