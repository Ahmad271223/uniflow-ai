import PDFKit
import PencilKit
import SwiftUI
import UniFlowCore
import XCTest
@testable import UniFlow

/// Tabelle ("Excel", Auftrag des Inhabers 25./26.11.2026) im Editor: Kasten auf der Seite und im Export, Werkzeug
/// "Tabelle", grosse Ansicht (antippen, tippen, Formel mit angetippter Zelle), Sortieren/Filtern/Diagramm, Sperre ohne
/// Pro AI, Tabelle als eigene Datei. Im echten Weg: Dokument im Fenster, Beruehrungen wie am Geraet.
@MainActor
final class SheetAppTests: XCTestCase {

    struct Shown {
        let store: DocumentStore
        let editor: PDFEditorController
        let window: UIWindow
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

    /// Dokument (1 PDF-Seite, danach eine leere Seite) im Fenster
    private func open(proAI: Bool = true, size: CGSize = CGSize(width: 1080, height: 810)) async throws -> Shown {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-sheet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let clock: UniFlowClock = .fixed(berlin: "2026-11-26T09:00:00")!
        let layout = DataContainerLayout(base: root.appendingPathComponent("c", isDirectory: true),
                                         key: DataContainerKey(userID: "001234.erfunden.tabelle", university: .luh))
        try layout.prepare(clock: clock)
        let host = LocalBackendHost(directory: layout.databaseDirectory, clock: clock, files: .container(layout), university: .luh)
        let backend = try await host.backend()
        let fileID = "tab-" + UUID().uuidString.prefix(8).lowercased()
        try await backend.context.database.transaction { c in
            try c.execute("INSERT OR IGNORE INTO courses(id, title, semester, subject, kind, created_at) VALUES (?,?,?,?,?,?)",
                          [.text("k-test"), .text("Testkurs"), .text("WiSe 2026/27"), .text("Testkurs"), .text("vorlesung"),
                           .text("2026-10-01T08:00:00")])
            try c.execute("INSERT INTO files(id, course_id, name, chdate, status, kind, downloaded_at) VALUES (?,?,?,?, 'neu', 'pdf', ?)",
                          [.text(fileID), .text("k-test"), .text("Skript.pdf"), .integer(1_792_000_000), .text("2026-11-26T08:00:00")])
        }
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
        let pdfURL = AppPaths.pdf(fileID, namespace: api.namespace, root: root)
        try FileManager.default.createDirectory(at: pdfURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.pdf().write(to: pdfURL)
        try DocumentStore.stamp(try await api.value("/api/files/\(fileID)")).write(to: pdfURL.appendingPathExtension("stand"), atomically: true, encoding: .utf8)
        let file = LibFile(id: fileID, name: "Skript.pdf", title: "Skript", kind: "pdf", module_id: nil, subject: "Testkurs",
                           doc_type: nil, ai_title: nil, sub_label: nil, downloaded_at: "2026-11-26T08:00:00", has_notes: nil,
                           page_count: 1, studip_folder: nil)
        let store = DocumentStore(file: file, api: api, root: root)
        await store.load()
        XCTAssertNil(store.errorMessage, store.errorMessage ?? "")
        await store.addBlankPage(afterKey: "p1", template: "blank", size: CGSize(width: 595, height: 842))
        let blank = try XCTUnwrap(store.pageKey(forPageIndex: 1))

        let suite = "uniflow.tests.sheet.\(UUID().uuidString)"
        let toolDefaults = UserDefaults(suiteName: suite) ?? .standard
        let editor = PDFEditorController(store: store, tools: EditorToolState(defaults: toolDefaults))
        editor.pencilOnly = true
        editor.ownNotesVisible = true
        editor.canEdit = true
        editor.richNotesOverride = proAI
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let frame = CGRect(origin: .zero, size: size)
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        window.rootViewController = editor
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in
            toolDefaults.removePersistentDomain(forName: suite)
            editor.dismiss(animated: false)
            editor.objects.endTextEditing()
            editor.showToolPicker(false)
            window.isHidden = true
            window.rootViewController = nil
            await store.close()
        }
        return Shown(store: store, editor: editor, window: window, blank: blank)
    }

    /// Seite zeigen und warten, bis sie mit Notizen geladen ist
    private func overlay(_ s: Shown, key: String) async throws -> PageInkView {
        let index = try XCTUnwrap(s.store.layout?.index(ofKey: key))
        var found: PageInkView?
        var jumped = false
        try await BildProbe.wait("Seite \(index + 1) geladen und im Fenster", timeout: 20) {
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

    private func table() -> Sheet {
        var s = Sheet(rows: 4, cols: 3)
        for (k, v) in ["A1": "Fach", "B1": "Note", "C1": "LP", "A2": "Mathe", "B2": "1,7", "C2": "10",
                       "A3": "Physik", "B3": "2,3", "C3": "5", "A4": "Summe", "C4": "=SUMME(C2:C3)"] { s.set(v, at: SheetRef(k)!) }
        return s
    }

    /// Farbe eines Bildpunkts (0...255)
    private func pixel(_ image: UIImage, _ x: Int, _ y: Int) -> [Int] {
        guard let cg = image.cgImage else { return [] }
        var data = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(cg, in: CGRect(x: -x, y: -(cg.height - 1 - y), width: cg.width, height: cg.height))
        return data.map(Int.init)
    }

    private func near(_ a: [Int], _ hex: String, tolerance: Int = 6) -> Bool {
        guard a.count == 4, let c = UIColor(hex: hex) else { return false }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, al: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &al)
        return abs(a[0] - Int(r * 255)) <= tolerance && abs(a[1] - Int(g * 255)) <= tolerance && abs(a[2] - Int(b * 255)) <= tolerance
    }

    // MARK: Auf der Seite

    func testTabelleStehtAufDerSeiteUndImExport() async throws {
        let s = try await open()
        let page = try await overlay(s, key: s.blank)
        var t = table()
        t.restyle(SheetRange("A2")!) { $0.fill = "#d6f5c8" }
        t.charts = [SheetChart(id: "d", kind: "bar", range: SheetRange("A1:C3")!, title: "Noten")]
        let o = SheetObject.object(id: "t", x: 60, y: 100, sheet: t, page: (595, 842))
        await s.store.editObjects(pageKey: s.blank) { $0 + [o] }
        await s.store.flush()
        try await BildProbe.wait("Tabelle gezeigt") { page.objectsView.subviews.contains { $0 is SheetBoxView } }
        let box = try XCTUnwrap(page.objectsView.subviews.compactMap { $0 as? SheetBoxView }.first)
        XCTAssertFalse(page.objectsView.subviews.contains { $0 is TextBlockView }, "kein Textblock, kein Ersatztext auf der Seite")
        // Diagramm (300 breit) unter der Tabelle (4 Zeilen)
        XCTAssertEqual(box.bounds.width, 300, accuracy: 0.5)
        XCTAssertEqual(box.bounds.height, CGFloat(4 * Sheet.defaultRowHeight + Sheet.gap + SheetChart.height), accuracy: 0.5)
        XCTAssertEqual(box.frame.minX, 60, accuracy: 0.5)
        XCTAssertEqual(box.frame.minY, 100, accuracy: 0.5)
        XCTAssertEqual(ObjectEditing.textHeight(o), Double(box.bounds.height), accuracy: 0.5, "Treffer und Rahmen kennen die Groesse")
        XCTAssertEqual(PageObjectEdit.hit([o], x: 200, y: 300, textHeight: ObjectEditing.textHeight), "t", "auch das Diagramm trifft")

        // Bild: Kopfzeile grau, gefaerbte Zelle, Balken in der ersten Diagrammfarbe
        let image = try XCTUnwrap(SheetRender.image(o, scale: 1))
        XCTAssertTrue(near(pixel(image, 70, 12), "#f1f3f6"), "Kopfzeile: \(pixel(image, 70, 12))")
        XCTAssertTrue(near(pixel(image, 70, 36), "#d6f5c8"), "Zellfarbe: \(pixel(image, 70, 36))")
        XCTAssertTrue(near(pixel(image, 130, 60), "#ffffff"), "Zelle ohne Farbe ist weiss")
        var bar = false
        for y in stride(from: 130, to: 280, by: 3) { for x in stride(from: 30, to: 290, by: 3) where near(pixel(image, x, y), SheetChart.palette[0]) { bar = true } }
        XCTAssertTrue(bar, "das Diagramm zeigt Balken")

        // Export (PDF, geteilte Loesung): dieselbe Tabelle an ihrer Stelle
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let exported = UIGraphicsImageRenderer(size: CGSize(width: 595, height: 842), format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 595, height: 842))
            ObjectGeometry.draw(objects: [o], images: [:], in: ctx.cgContext)
        }
        XCTAssertTrue(near(pixel(exported, 60 + 70, 100 + 36), "#d6f5c8"), "im Export: \(pixel(exported, 130, 136))")
        XCTAssertTrue(near(pixel(exported, 30, 30), "#ffffff"))

        // sehr grosse Tabelle: die Aufloesung bleibt begrenzt (Speicher)
        let big = SheetBoxView(object: SheetObject.object(id: "g", x: 0, y: 0, sheet: Sheet(rows: 500, cols: 52)))
        big.contentScaleFactor = 8
        XCTAssertLessThanOrEqual(big.contentScaleFactor * big.contentScaleFactor * big.bounds.width * big.bounds.height, SheetBoxView.pixelBudget * 1.01)
        XCTAssertGreaterThan(big.contentScaleFactor, 0.1)
        let small = SheetBoxView(object: o)
        small.contentScaleFactor = 4
        XCTAssertEqual(small.contentScaleFactor, 4, "gewoehnliche Tabellen bleiben beim Zoomen scharf")
    }

    // MARK: Werkzeug

    func testWerkzeugLegtTabelleAnOeffnetDieGrosseAnsichtUndSichert() async throws {
        try ContainerTestBed.requireEventGroupedUndo()
        let s = try await open()
        let page = try await overlay(s, key: s.blank)
        s.editor.choose(.select)
        s.editor.tools.select(.sheet)
        XCTAssertTrue(s.editor.objects.isActive)
        XCTAssertEqual(s.editor.objects.tool, .sheet)

        try await BildProbe.tap(CGPoint(x: 120, y: 200), on: page, in: s.window)
        try await BildProbe.wait("Tabelle angelegt") { await s.store.objects(forPageKey: s.blank).count == 1 }
        let first = await s.store.objects(forPageKey: s.blank).first
        let o = try XCTUnwrap(first)
        let id = try XCTUnwrap(o["id"]?.string)
        XCTAssertTrue(SheetObject.isSheet(o))
        XCTAssertEqual(o["type"], "text")
        XCTAssertEqual(o["x"]?.double ?? 0, 120, accuracy: 1)
        XCTAssertEqual(o["y"]?.double ?? 0, 200, accuracy: 1)
        try await BildProbe.wait("grosse Ansicht offen") { s.editor.presentedViewController is UIHostingController<SheetEditorView> }
        XCTAssertEqual(s.editor.objects.tool, .select, "danach ist die Tabelle gewaehlt")
        XCTAssertEqual(s.editor.objects.selectedSheet?.id, id)
        let shown = await s.store.objects(forPageKey: s.blank)
        XCTAssertNil(s.editor.objects.selectionFormat(shown), "keine Text-Leiste fuer eine Tabelle")

        s.editor.dismiss(animated: false)
        try await BildProbe.wait("grosse Ansicht zu") { s.editor.presentedViewController == nil }

        // Sichern schreibt Tabelle und Ersatztext auf die Seite; ein Schritt zurueck stellt den alten Stand her
        var t = try XCTUnwrap(SheetObject.sheet(o))
        t.set("Fach", at: SheetRef("A1")!)
        t.set("=2*21", at: SheetRef("B1")!)
        let saved = await s.editor.objects.saveSheet(t, key: s.blank, id: id)
        XCTAssertTrue(saved)
        let after = await s.store.objects(forPageKey: s.blank).first
        XCTAssertEqual(after?["text"], "Fach\t42")
        XCTAssertEqual(after.flatMap(SheetObject.sheet)?.raw(SheetRef("B1")!), "=2*21")
        XCTAssertEqual(after?["width"], o["width"], "gleich breit auf der Seite")
        try await BildProbe.wait("Kasten zeigt den neuen Stand") { page.objectsView.shownObjects.first?["text"] == "Fach\t42" }

        // Farbe und Schriftgroesse der Objektleiste lassen die Tabelle in Ruhe
        s.editor.objects.recolorSelection("#d7263d")
        s.editor.objects.resizeText(by: 4)
        try await Task.sleep(nanoseconds: 400_000_000)
        let untouched = await s.store.objects(forPageKey: s.blank).first
        XCTAssertEqual(untouched, after)

        // Doppeltipp oeffnet die Tabelle wieder
        let p = page.content.convert(CGPoint(x: 150, y: 215), to: nil)
        for _ in 0..<2 {
            let finger = TestFinger(at: p, in: s.window)
            try await Task.sleep(nanoseconds: 40_000_000)
            finger.lift()
            try await Task.sleep(nanoseconds: 90_000_000)
        }
        try await BildProbe.wait("grosse Ansicht wieder offen") { s.editor.presentedViewController is UIHostingController<SheetEditorView> }
        s.editor.dismiss(animated: false)
        try await BildProbe.wait("zu") { s.editor.presentedViewController == nil }

        s.editor.editUndo.undo()
        try await BildProbe.wait("ein Schritt zurueck: leere Tabelle") { await s.store.objects(forPageKey: s.blank).first?["text"] == "" }
    }

    func testOhneProAIAnsehenAberNichtAnlegenOderBearbeiten() async throws {
        let s = try await open(proAI: false)
        let page = try await overlay(s, key: s.blank)
        var hints: [String] = []
        s.editor.onHint = { hints.append($0) }
        let o = SheetObject.object(id: "t", x: 60, y: 100, sheet: table(), page: (595, 842))
        await s.store.editObjects(pageKey: s.blank) { $0 + [o] }
        await s.store.flush()
        try await BildProbe.wait("Tabelle gezeigt (ansehen geht in jedem Tarif)") { page.objectsView.subviews.contains { $0 is SheetBoxView } }

        s.editor.objects.openSheet(key: s.blank, id: "t")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(hints.last, ObjectEditing.sheetLockedHint)
        XCTAssertNil(s.editor.presentedViewController)

        hints = []
        s.editor.choose(.select)
        s.editor.tools.select(.sheet)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(hints.last, ObjectEditing.sheetLockedHint)
        XCTAssertNotEqual(s.editor.objects.tool, .sheet, "das Werkzeug bleibt gesperrt")
        let list = await s.store.objects(forPageKey: s.blank)
        XCTAssertEqual(list.count, 1)
    }

    // MARK: Eigene Datei

    func testTabelleAlsEigeneDateiOeffnetSichGleichGross() async throws {
        let s = try await open()
        _ = try await overlay(s, key: "p1")
        s.editor.objects.openDocumentSheetIfNeeded()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(s.editor.presentedViewController, "ein gewoehnliches Dokument oeffnet keine Tabelle")
        let none = await s.store.objects(forPageKey: "p1")
        XCTAssertTrue(none.isEmpty)

        // frisch in der Bibliothek angelegt: die Tabelle kommt auf die erste Seite
        SheetDocuments.pending.insert(s.store.file.id)
        s.editor.objects.openDocumentSheetIfNeeded()
        try await BildProbe.wait("Tabelle der Datei angelegt") { await s.store.objects(forPageKey: "p1").count == 1 }
        let first = await s.store.objects(forPageKey: "p1").first
        let o = try XCTUnwrap(first)
        XCTAssertEqual(SheetObject.sheet(o)?.isDocument, true)
        XCTAssertEqual(SheetObject.sheet(o)?.cols, 6)
        XCTAssertEqual(o["width"]?.double ?? 0, 595 - 48, accuracy: 0.5, "fuellt die Breite der Seite")
        XCTAssertFalse(SheetDocuments.pending.contains(s.store.file.id))
        try await BildProbe.wait("grosse Ansicht offen") { s.editor.presentedViewController is UIHostingController<SheetEditorView> }
        s.editor.dismiss(animated: false)
        try await BildProbe.wait("zu") { s.editor.presentedViewController == nil }

        // beim naechsten Oeffnen: dieselbe Tabelle, keine zweite
        s.editor.objects.openDocumentSheetIfNeeded()
        try await BildProbe.wait("wieder offen") { s.editor.presentedViewController is UIHostingController<SheetEditorView> }
        let again = await s.store.objects(forPageKey: "p1")
        XCTAssertEqual(again.count, 1)
    }

    // MARK: Grosse Ansicht

    private func gridWindow(_ model: SheetEditorModel) -> (SheetGridView, UIWindow) {
        let frame = CGRect(x: 0, y: 0, width: 900, height: 600)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        let vc = UIViewController()
        let grid = SheetGridView(model: model)
        vc.view.backgroundColor = .white
        vc.view.addSubview(grid)
        grid.frame = CGRect(x: 0, y: 100, width: 900, height: 500)
        window.rootViewController = vc
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in
            window.isHidden = true
            window.rootViewController = nil
        }
        return (grid, window)
    }

    private func tap(_ r: SheetRef, _ grid: SheetGridView, _ window: UIWindow, times: Int = 1) async throws {
        let p = grid.convert(grid.center(of: r), to: nil)
        for _ in 0..<times {
            let finger = TestFinger(at: p, in: window)
            try await Task.sleep(nanoseconds: 40_000_000)
            finger.lift()
            try await Task.sleep(nanoseconds: 90_000_000)
        }
        try await Task.sleep(nanoseconds: 400_000_000)
    }

    func testGitterAntippenTippenUndFormelMitAngetippterZelle() async throws {
        let model = SheetEditorModel(sheet: table(), title: "Test")
        let (grid, window) = gridWindow(model)
        try await Task.sleep(nanoseconds: 300_000_000)

        try await tap(SheetRef("B2")!, grid, window)
        XCTAssertEqual(model.active, SheetRef("B2"))
        XCTAssertFalse(model.isEditing)
        try await tap(SheetRef("C4")!, grid, window, times: 2)
        XCTAssertEqual(model.active, SheetRef("C4"))
        XCTAssertEqual(model.editing, "=SUMME(C2:C3)", "Doppeltipp: die Formel steht zum Aendern bereit")
        model.cancelEditing()

        // Formel tippen und Zellen antippen: ihr Name kommt in die Formel
        model.select(SheetRef("B4")!)
        model.beginEditing("=")
        try await tap(SheetRef("B2")!, grid, window)
        XCTAssertEqual(model.editing, "=B2")
        XCTAssertEqual(model.active, SheetRef("B4"), "die Zelle, in der getippt wird, bleibt")
        model.editing = "=B2+"
        try await tap(SheetRef("B3")!, grid, window)
        XCTAssertEqual(model.editing, "=B2+B3")
        // Eingabe: uebernehmen und eine Zeile tiefer - am unteren Rand waechst die Tabelle
        model.commitEditing(dCol: 0, dRow: 1)
        XCTAssertEqual(model.calc.value(SheetRef("B4")!), .number(4))
        XCTAssertEqual(model.sheet.rows, 5)
        XCTAssertEqual(model.active, SheetRef("B5"))
        XCTAssertTrue(model.changed)
        model.undo()
        XCTAssertEqual(model.sheet.rows, 4)
        model.undo()
        XCTAssertEqual(model.sheet.raw(SheetRef("B4")!), "")
        XCTAssertFalse(model.changed)
        model.redo()
        XCTAssertEqual(model.sheet.raw(SheetRef("B4")!), "=B2+B3")

        // Kopf antippen waehlt die ganze Spalte
        let head = grid.convert(CGPoint(x: grid.center(of: SheetRef("C1")!).x, y: SheetGridView.headerHeight / 2), to: nil)
        let finger = TestFinger(at: head, in: window)
        try await Task.sleep(nanoseconds: 40_000_000)
        finger.lift()
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(model.selection.name, "C1:C4")
    }

    func testSortierenFilternDiagrammKopierenUndFormat() {
        let m = SheetEditorModel(sheet: table(), title: "T")
        func raw(_ n: String) -> String { m.sheet.raw(SheetRef(n)!) }

        m.select(SheetRef("B2")!)
        m.sort(ascending: false)
        XCTAssertEqual([raw("A2"), raw("A3"), raw("A4")], ["Physik", "Mathe", "Summe"], "Kopfzeile bleibt, Leeres unten")
        XCTAssertEqual(m.calc.value(SheetRef("C4")!), .number(15))
        m.undo()
        XCTAssertEqual(raw("A2"), "Mathe")
        XCTAssertTrue(m.canRedo)

        m.select(SheetRef("A2")!)
        XCTAssertEqual(m.filterValues, ["Mathe", "Physik", "Summe"])
        m.toggleFilter("Physik")
        XCTAssertEqual(m.hidden, [2])
        XCTAssertTrue(m.isFiltered(0))
        m.move(dCol: 0, dRow: 1)
        XCTAssertEqual(m.active, SheetRef("A4"), "die versteckte Zeile wird uebersprungen")
        m.filterOnly("Mathe")
        XCTAssertEqual(m.hidden, [2, 3])
        m.clearFilter(all: true)
        XCTAssertTrue(m.hidden.isEmpty)

        m.select(SheetRange("A1:B3")!)
        m.addChart("pie")
        XCTAssertEqual(m.sheet.charts.first?.range.name, "A1:B3")
        m.select(SheetRef("A1")!)
        m.addChart("bar")
        XCTAssertEqual(m.sheet.charts.last?.range.name, "A1:C4", "eine Zelle gewaehlt: alle gefuellten Zellen")
        let id = m.sheet.charts[0].id
        m.updateChart(id) { $0.title = "Noten"; $0.kind = "line" }
        XCTAssertEqual(m.sheet.charts[0].title, "Noten")
        XCTAssertEqual(m.sheet.charts[0].kind, "line")
        m.removeChart(id)
        XCTAssertEqual(m.sheet.charts.count, 1)
        m.setShow("chart")
        XCTAssertEqual(m.sheet.show, "chart")

        m.select(SheetRef("C4")!)
        m.copy()
        m.select(SheetRef("B4")!)
        m.paste()
        XCTAssertEqual(raw("B4"), "=SUMME(B2:B3)", "die Formel wandert beim Einfuegen mit")

        m.select(SheetRange("B2:B3")!)
        m.toggleBold()
        XCTAssertTrue(m.sheet.style(SheetRef("B3")!).bold)
        m.changeDecimals(1)
        XCTAssertEqual(m.sheet.display(SheetRef("B2")!, m.calc), "1,70")
        m.setFormat("e")
        XCTAssertEqual(m.sheet.display(SheetRef("B3")!, m.calc), "2,30 €")
        m.setBorder("outer")
        XCTAssertEqual(m.sheet.style(SheetRef("B2")!).border, 1 | 2 | 8)

        // Spalte breiter ziehen: viele Zwischenschritte, ein Schritt zurueck
        m.resizeLive(col: 0, row: nil, to: 100, begin: true)
        m.resizeLive(col: 0, row: nil, to: 130, begin: false)
        m.resizeLive(col: 0, row: nil, to: 150, begin: false)
        XCTAssertEqual(m.sheet.width(0), 150)
        m.undo()
        XCTAssertEqual(m.sheet.width(0), Sheet.defaultColWidth)

        m.select(m.sheet.bounds)
        m.deleteRows()
        XCTAssertEqual(m.sheet.rows, 4, "die letzte Zeile bleibt")
        XCTAssertNotNil(m.notice)
        m.select(SheetRef("A1")!)
        m.insertFunction("SUMME(A1:A5)")
        XCTAssertEqual(m.editing, "=SUMME(A1:A5)")
    }
}
