import PDFKit
import PencilKit
import SwiftUI
import UIKit
import XCTest
import UniFlowCore
@testable import UniFlow

/// Seitenformate A6 ... A2 und Whiteboards bis A0 quer (app/static/formats.js, PC-Stand 27.10.2026, Grenzen
/// 100-3400 pt) im iPad-Editor: Notizseiten mit beliebigem `w`/`h` aus `pageOrder` werden angelegt und angezeigt
/// (Anzeige-PDF, Overlay, Canvas, Vorlage, Miniatur), "Leere Seite danach" und das neue Notizbuch bieten dieselben
/// Formate an, sehr grosse Seiten bleiben im Speicher beherrschbar. Lokales Backend in einem Temp-Ordner.
@MainActor
final class PageFormatsAppTests: XCTestCase {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-formate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private struct Fixture {
        let api: APIClient
        let root: URL
    }

    private func backend() throws -> Fixture {
        let root = try tempDir()
        let host = LocalBackendHost(directory: root.appendingPathComponent("db", isDirectory: true),
                                    clock: .fixed(berlin: "2026-10-25T14:30:05")!,
                                    files: LocalFiles(container: root, dataDirectory: "Library/Application Support/UniFlow",
                                                      tools: AppDocumentTools()))
        return Fixture(api: APIClient(base: APIClient.localBase, transport: LocalTransport(host: host)), root: root)
    }

    private func libFile(_ id: String, kind: String) -> LibFile {
        LibFile(id: id, name: "Formate", title: "Formate", kind: kind, module_id: nil, subject: nil, doc_type: nil, ai_title: nil,
                sub_label: nil, downloaded_at: nil, has_notes: 1, page_count: nil, studip_folder: nil)
    }

    /// Notizbuch ueber POST /api/notebooks, danach die Seiten (Schluessel b1, b2 ...) mit diesen Groessen und Vorlagen
    private func notebook(_ fx: Fixture, kind: String = "notebook", pages: [(w: Double, h: Double, template: String)]) async throws -> DocumentStore {
        let created = try await fx.api.form("/api/notebooks", fields: ["kind": kind, "title": "Formate"])
        let id = try XCTUnwrap(created["id"]?.string)
        var objects: [String: JSONValue] = [:]
        var order: [JSONValue] = []
        for (i, p) in pages.enumerated() {
            objects["b\(i + 1)"] = ["objects": []]
            order.append(["key": .string("b\(i + 1)"), "type": "blank", "template": .string(p.template), "w": .number(p.w), "h": .number(p.h)])
        }
        let root: JSONValue = ["version": 2, "zoom": 1.2, "pages": .object(objects), "pageOrder": .array(order), "bookmarks": [], "outline": []]
        let saved = try await HTTPAnnotationTransport(api: fx.api).put(documentID: id, root: root, baseVersion: 1)
        XCTAssertEqual(saved, .saved(version: 2))
        let store = DocumentStore(file: libFile(id, kind: kind), api: fx.api, root: fx.root)
        await store.load()
        XCTAssertNil(store.errorMessage)
        return store
    }

    private func waitLoaded(_ overlay: PageInkView, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<300 where !overlay.loaded { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(overlay.loaded, "Overlay geladen", file: file, line: line)
    }

    // MARK: Neues Notizbuch

    /// Felder wie notebookDialog im Web: w/h aus Format und Ausrichtung, Whiteboards immer quer; das lokale Backend
    /// legt die erste Seite in diesem Format an
    func testNotebookDialogSendsChosenFormat() async throws {
        let fx = try backend()
        XCTAssertEqual(NotebookDialog.fields(kind: "notebook", title: "", template: "grid", format: "a3", orientation: .landscape),
                       ["kind": "notebook", "title": "Notizen", "template": "grid", "w": "1191", "h": "842"])
        XCTAssertEqual(NotebookDialog.fields(kind: "whiteboard", title: "Tafel", template: "lined", format: PageFormats.defaultWhiteboard,
                                             orientation: .portrait)["w"], "1191", "Whiteboard Mittel, quer")
        XCTAssertNil(NotebookDialog.fields(kind: "notebook", title: "x", template: "blank", format: "", orientation: .portrait)["w"])
        for (kind, format, orientation, size) in [("notebook", "a6", PageFormats.Orientation.portrait, [298.0, 420.0]),
                                                  ("notebook", "a2", .landscape, [1684, 1191]),
                                                  ("whiteboard", "wb_a0", .portrait, [3370, 2384])] {
            let fields = NotebookDialog.fields(kind: kind, title: "Format", template: "dotted", format: format, orientation: orientation)
            let created = try await fx.api.form("/api/notebooks", fields: fields)
            let id = try XCTUnwrap(created["id"]?.string)
            let ann = try await fx.api.value("/api/files/\(id)/annotations")
            let first = ann["data"]?["pageOrder"]?.array?.first
            XCTAssertEqual([first?["w"]?.double ?? 0, first?["h"]?.double ?? 0], size, format)
            XCTAssertEqual(first?["template"], "dotted")
        }
    }

    private static func accessibilityAutomation(_ on: Bool) -> Bool {
        guard let h = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW), let f = dlsym(h, "_AXSSetAutomationEnabled") else { return false }
        typealias SetEnabled = @convention(c) (Int32) -> Void
        unsafeBitCast(f, to: SetEnabled.self)(on ? 1 : 0)
        return true
    }

    private func buttons(in view: UIView) -> [NSObject] {
        view.layoutIfNeeded()
        var out: [NSObject] = []
        func visit(_ element: Any, depth: Int) {
            guard depth < 40 else { return }
            if let o = element as? NSObject {
                if o.accessibilityTraits.contains(.button), o.accessibilityLabel?.isEmpty == false { out.append(o) }
                for e in o.accessibilityElements ?? [] { visit(e, depth: depth + 1) }
                let n = o.accessibilityElementCount()
                if n != NSNotFound, n > 0 { for i in 0..<min(n, 500) { if let e = o.accessibilityElement(at: i) { visit(e, depth: depth + 1) } } }
            }
            if let v = element as? UIView { for s in v.subviews { visit(s, depth: depth + 1) } }
        }
        visit(view, depth: 0)
        return out
    }

    private func tap(_ label: String, in view: UIView) -> Bool {
        buttons(in: view).first { $0.accessibilityLabel == label }?.accessibilityActivate() == true
    }

    /// Dialog "Neues Notizbuch" in einem Fenster: Formate A6 ... A2 und Hoch/Quer sind waehlbar, "Erstellen" legt die
    /// erste Seite im gewaehlten Format an; das Whiteboard bietet die vier Whiteboard-Groessen ohne Hoch/Quer an
    func testNotebookDialogOffersFormatsAndCreatesChosenOne() async throws {
        let fx = try backend()
        let plan = Entitlements.shared.plan
        Entitlements.shared.setPlanForTesting(.plus)
        addTeardownBlock { @MainActor in Entitlements.shared.setPlanForTesting(plan) }
        XCTAssertTrue(Self.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
        defer { _ = Self.accessibilityAutomation(false) }
        let suite = "uniflow-formate-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let router = UFRouter()

        func show(_ kind: String) async throws -> (UIWindow, UIView) {
            let root = NotebookDialog(kind: kind, lib: ["modules": []], moduleID: nil, folderID: nil)
                .environmentObject(Session(local: fx.api, defaults: defaults))
                .environmentObject(UFToastCenter())
                .environmentObject(router)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 760, height: 900)
            let hosting = UIHostingController(rootView: root)
            window.rootViewController = hosting
            window.makeKeyAndVisible()
            for _ in 0..<10 { try await Task.sleep(nanoseconds: 50_000_000) }
            return (window, hosting.view)
        }

        let (w1, notebook) = try await show("notebook")
        let labels = Set(buttons(in: notebook).compactMap(\.accessibilityLabel))
        for f in PageFormats.paper { XCTAssertTrue(labels.contains(f.name), "Format \(f.name) fehlt: \(labels.sorted())") }
        XCTAssertTrue(labels.isSuperset(of: ["Hoch", "Quer"]))
        XCTAssertFalse(labels.contains("Riesig (A0 quer)"), "Whiteboards nur beim Whiteboard")
        XCTAssertTrue(tap("A5", in: notebook))
        XCTAssertTrue(tap("Quer", in: notebook))
        for _ in 0..<5 { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(tap("Erstellen", in: notebook))
        for _ in 0..<100 { if case .doc = router.route { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        guard case .doc(let id, _, _) = router.route else { return XCTFail("Dokument nicht geoeffnet: \(router.route)") }
        let ann = try await fx.api.value("/api/files/\(id)/annotations")
        let first = ann["data"]?["pageOrder"]?.array?.first
        XCTAssertEqual([first?["w"]?.double ?? 0, first?["h"]?.double ?? 0], [595, 420], "A5 quer")
        XCTAssertEqual(first?["template"], "lined", "Vorlage wie vorgewaehlt")
        w1.isHidden = true

        let (w2, board) = try await show("whiteboard")
        let boardLabels = Set(buttons(in: board).compactMap(\.accessibilityLabel))
        for f in PageFormats.whiteboards { XCTAssertTrue(boardLabels.contains(f.name), "Whiteboard \(f.name) fehlt: \(boardLabels.sorted())") }
        XCTAssertFalse(boardLabels.contains("Quer"), "Whiteboards sind immer quer")
        XCTAssertFalse(boardLabels.contains("A4"))
        w2.isHidden = true
    }

    // MARK: Anzeige beliebiger Groessen

    /// Jede Groesse im Bereich 100-3400 pt (auch sehr schmal oder sehr hoch) erscheint mit genau diesem Mass: Seite
    /// der Anzeige-PDF, Overlay, Canvas und Vorlage in Seitenpunkten, Miniatur in der Breite der Seitenleiste
    func testArbitraryPageSizesAreShown() async throws {
        let fx = try backend()
        let sizes: [(w: Double, h: Double, template: String)] = [
            (100, 100, "grid"), (298, 420, "lined"), (420, 298, "dotted"), (100, 3400, "mm"), (3400, 100, "lined"),
            (3370, 2384, "mm"), (2384, 3370, "cornell"), (3400, 3400, "dotted"), (1191, 1684, "grid"), (777, 333, "blank"),
        ]
        let store = try await notebook(fx, pages: sizes)
        let layout = try XCTUnwrap(store.layout)
        XCTAssertEqual(layout.entries.map(\.key), (1...sizes.count).map { "b\($0)" })
        let editor = PDFEditorController(store: store)
        editor.loadViewIfNeeded()
        for (i, s) in sizes.enumerated() {
            let page = try XCTUnwrap(layout.pdf.page(at: i))
            XCTAssertEqual(page.bounds(for: .mediaBox).size, CGSize(width: s.w, height: s.h), "Seite \(i + 1)")
            let overlay = try XCTUnwrap(editor.overlayForTesting(at: i), "Seite \(i + 1)")
            await waitLoaded(overlay)
            XCTAssertEqual(overlay.geometry.pageSize, CGSize(width: s.w, height: s.h), "Seite \(i + 1)")
            XCTAssertEqual(overlay.canvas.frame.size, CGSize(width: s.w, height: s.h), "Canvas in Seitenpunkten")
            XCTAssertEqual(overlay.objectsView.layer.sublayers?.isEmpty == false, s.template != "blank", "Vorlage \(s.template)")
            let thumb = PageRenderer.thumbnail(page: page, entry: try XCTUnwrap(layout.entry(at: i)), objects: [], images: [:],
                                               width: ThumbnailStrip.width, scale: 1)
            XCTAssertLessThanOrEqual(thumb.size.width, ThumbnailStrip.width + 0.5)
            XCTAssertLessThanOrEqual(thumb.size.height, ThumbnailStrip.width * 1.5 + 0.5, "Miniatur bleibt klein (\(s.w) x \(s.h))")
            XCTAssertGreaterThanOrEqual(thumb.size.height, 1)
        }
        // A-Formate behalten die volle Breite der Seitenleiste
        let a2 = try XCTUnwrap(layout.pdf.page(at: 8))
        XCTAssertEqual(PageRenderer.thumbnail(page: a2, entry: try XCTUnwrap(layout.entry(at: 8)), objects: [], images: [:],
                                              width: ThumbnailStrip.width, scale: 1).size.width, ThumbnailStrip.width)
        await store.close()
    }

    // MARK: Leere Seite danach mit Format

    func testInsertBlankPageWithChosenFormat() async throws {
        let fx = try backend()
        let store = try await notebook(fx, pages: [(595, 842, "lined")])
        let editor = PDFEditorController(store: store)
        editor.loadViewIfNeeded()
        let a2q = try XCTUnwrap(PageFormats.size("a2", .landscape))
        let added = await editor.insertBlankPage(after: "b1", template: "grid", size: CGSize(width: a2q.width, height: a2q.height))
        let key = try XCTUnwrap(added)
        let wb = try XCTUnwrap(PageFormats.size("wb_a0"))
        let boardKey = await editor.insertBlankPage(after: key, template: "dotted", size: CGSize(width: wb.width, height: wb.height))
        let board = try XCTUnwrap(boardKey)
        // ausserhalb der Grenzen: Groesse der Seite davor (wie addBlankPage im Web)
        let fallbackKey = await editor.insertBlankPage(after: "b1", template: "blank", size: CGSize(width: 50, height: 5000))
        let fallback = try XCTUnwrap(fallbackKey)
        let sameKey = await editor.insertBlankPage(after: "b1", template: "mm")
        let same = try XCTUnwrap(sameKey)
        let doc = await store.pageStructureDocument()
        func size(_ k: String) -> [Double]? {
            doc.pageOrder.first { $0["key"]?.string == k }.map { [$0["w"]?.double ?? 0, $0["h"]?.double ?? 0] }
        }
        XCTAssertEqual(size(key), [1684, 1191])
        XCTAssertEqual(size(board), [3370, 2384])
        XCTAssertEqual(size(fallback), [595, 842])
        XCTAssertEqual(size(same), [595, 842])
        XCTAssertEqual(doc.pageOrder.first { $0["key"]?.string == key }?["template"], "grid")
        editor.showLayout()
        let layout = try XCTUnwrap(store.layout)
        let i = try XCTUnwrap(layout.index(ofKey: board))
        XCTAssertEqual(layout.pdf.page(at: i)?.bounds(for: .mediaBox).size, CGSize(width: 3370, height: 2384))
        await store.close()
    }

    // MARK: Sehr grosse Seiten

    /// Speicherbedarf des Prozesses (phys_footprint, wie Xcode und der Jetsam-Waechter ihn zaehlen), in MB
    private func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        let words = MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(words)
        let kr: kern_return_t = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: words) { raw in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), raw, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    private func nativeStroke(from p: CGPoint, length: CGFloat) -> PKStroke {
        var pts: [PKStrokePoint] = []
        for i in 0..<40 {
            let x: CGFloat = p.x + CGFloat(i) * length / 40
            let y: CGFloat = p.y + CGFloat(i % 5) * 4
            pts.append(PKStrokePoint(location: CGPoint(x: x, y: y), timeOffset: Double(i) * 0.01, size: CGSize(width: 3, height: 3),
                                     opacity: 1, force: 1, azimuth: 0, altitude: CGFloat.pi / 2))
        }
        return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: pts, creationDate: Date()))
    }

    /// Editor in einem Fenster in iPad-Groesse, eingepasst und bei hoechstem Zoom: Speicherzuwachs (MB)
    private func shownFootprint(_ store: DocumentStore, strokes: Int) async throws -> (fit: Double, zoomed: Double) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1024, height: 1366)
        let editor = PDFEditorController(store: store)
        let before = footprintMB()
        window.rootViewController = editor
        window.isHidden = false
        window.layoutIfNeeded()
        let overlay = try XCTUnwrap(editor.overlayForTesting(at: 0))
        await waitLoaded(overlay)
        var d = overlay.canvas.drawing
        let size = overlay.geometry.pageSize
        for i in 0..<strokes {
            let y: CGFloat = size.height * CGFloat(i + 1) / CGFloat(strokes + 1)
            d.strokes.append(nativeStroke(from: CGPoint(x: size.width * 0.05, y: y), length: size.width * 0.9))
        }
        overlay.isApplyingDrawing = true
        overlay.canvas.drawing = d
        overlay.isApplyingDrawing = false
        editor.canvasViewDrawingDidChange(overlay.canvas)
        for _ in 0..<10 { window.layoutIfNeeded(); try await Task.sleep(nanoseconds: 100_000_000) }
        let fit = footprintMB() - before
        editor.pdfView.scaleFactor = editor.pdfView.maxScaleFactor
        for _ in 0..<10 { window.layoutIfNeeded(); try await Task.sleep(nanoseconds: 100_000_000) }
        let zoomed = footprintMB() - before
        // die Striche sind gespeichert (Zeichnen auf der grossen Seite geht)
        await store.flush()
        let objects = await store.objects(forPageKey: overlay.pageKey)
        XCTAssertEqual(objects.filter { $0["type"]?.string == "stroke" }.count, strokes, "Striche gespeichert (\(size))")
        window.isHidden = true
        window.rootViewController = nil
        await store.close()
        return (fit, zoomed)
    }

    /// Whiteboard A0 quer mit dem dichtesten Raster (Millimeterpapier, 1.189 + 841 Linien) und vielen Strichen: oeffnet,
    /// zeichnet und zoomt bis zum hoechsten Zoom ohne Absturz. Im Simulator rendert der Mac (GPU-Speicher zaehlt nur
    /// teilweise mit); die Grenze faengt nur einen groben Ausbruch, die Zahlen stehen im Protokoll.
    func testHugeWhiteboardOpensDrawsAndZooms() async throws {
        let fx = try backend()
        let a4 = try await notebook(fx, pages: [(595, 842, "mm")])
        let small = try await shownFootprint(a4, strokes: 40)
        let a0 = try await notebook(fx, kind: "whiteboard", pages: [(3370, 2384, "mm")])
        let huge = try await shownFootprint(a0, strokes: 40)
        print("Speicher A4: eingepasst \(small.fit) MB, gezoomt \(small.zoomed) MB; A0 quer: eingepasst \(huge.fit) MB, gezoomt \(huge.zoomed) MB")
        XCTAssertLessThan(huge.fit, 400, "A0 eingepasst: \(huge.fit) MB")
        XCTAssertLessThan(huge.zoomed, 400, "A0 gezoomt: \(huge.zoomed) MB")
    }

    /// Weggescrollte Seiten bleiben nur bis zu sechs A4-Flaechen auf Vorrat (`PDFEditorController.parkedAreaLimit`):
    /// A4 wie bisher sechs, A0-Whiteboards keine (je etwa 140 MB PencilKit-Kacheln). Zurueckgescrollt entsteht die
    /// Seite neu, mit ihren Strichen.
    func testLargePagesAreNotKeptWhenScrolledAway() async throws {
        let fx = try backend()
        let a4 = try await notebook(fx, pages: Array(repeating: (595.0, 842.0, "lined"), count: 9))
        let small = PDFEditorController(store: a4)
        small.loadViewIfNeeded()
        let smallDoc = try XCTUnwrap(small.pdfView.document)
        for i in 0..<9 {
            let o = try XCTUnwrap(small.overlayForTesting(at: i))
            small.pdfView(small.pdfView, willEndDisplayingOverlayView: o, for: try XCTUnwrap(smallDoc.page(at: i)))
        }
        XCTAssertEqual(small.parkedCountForTesting, 6, "A4: wie bisher sechs auf Vorrat")
        await a4.close()

        let boards = try await notebook(fx, kind: "whiteboard", pages: [(3370, 2384, "blank"), (3370, 2384, "grid"), (1191, 842, "dotted")])
        let editor = PDFEditorController(store: boards)
        editor.loadViewIfNeeded()
        let doc = try XCTUnwrap(editor.pdfView.document)
        let first = try XCTUnwrap(editor.overlayForTesting(at: 0))
        await waitLoaded(first)
        var d = first.canvas.drawing
        d.strokes.append(nativeStroke(from: CGPoint(x: 200, y: 300), length: 2500))
        first.isApplyingDrawing = true
        first.canvas.drawing = d
        first.isApplyingDrawing = false
        editor.canvasViewDrawingDidChange(first.canvas)
        editor.pdfView(editor.pdfView, willEndDisplayingOverlayView: first, for: try XCTUnwrap(doc.page(at: 0)))
        XCTAssertEqual(editor.parkedCountForTesting, 0, "A0 nicht auf Vorrat")
        let second = try XCTUnwrap(editor.overlayForTesting(at: 1))
        editor.pdfView(editor.pdfView, willEndDisplayingOverlayView: second, for: try XCTUnwrap(doc.page(at: 1)))
        XCTAssertEqual(editor.parkedCountForTesting, 0)
        let third = try XCTUnwrap(editor.overlayForTesting(at: 2))
        editor.pdfView(editor.pdfView, willEndDisplayingOverlayView: third, for: try XCTUnwrap(doc.page(at: 2)))
        XCTAssertEqual(editor.parkedCountForTesting, 1, "A3 quer passt in den Vorrat")
        // zurueck zur ersten Seite: neues Overlay mit dem Strich
        let again = try XCTUnwrap(editor.overlayForTesting(at: 0))
        XCTAssertFalse(again === first, "neu aufgebaut")
        await waitLoaded(again)
        for _ in 0..<100 where again.canvas.drawing.strokes.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(again.canvas.drawing.strokes.count, 1, "Strich nach dem Zurueckscrollen da")
        await boards.close()
    }
}
