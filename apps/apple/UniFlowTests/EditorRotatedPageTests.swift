import PDFKit
import PencilKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Gedrehte PDF-Seiten im Editor (`/Rotate` 90/180/270 der PDF, dazu die Drehung aus `pageOrder`), Befund
/// 04.11.2026 (GDS_Kap_4.pdf: 65 Seiten 595 x 842 mit /Rotate 90, "Stift hoert ploetzlich auf zu schreiben").
///
/// Befund (Sonde im Simulator, iPadOS 26): PDFKit gibt dem Overlay einer gedrehten Seite den Rahmen der UNGEDREHTEN
/// Seitenbox (bounds 595 x 842, in Seitenpunkten ohne Zoom; den Zoom traegt die PDFDocumentView) und dreht das
/// Overlay selbst per `transform` (bei /Rotate 90: a 0, b 1, c -1, d 0 = 90 Grad im Uhrzeigersinn). Das Overlay
/// rechnete bisher in Punkten der ANGEZEIGTEN Seite (842 x 595) und legte den Inhalt ungedreht in den Rahmen:
/// Massstab 595/842, Inhalt mittig als Streifen 595 x 420 (ungedreht y 211...631). Auf dem Bildschirm deckte die
/// Canvas nur den Streifen x 211...631 der 842 breiten Seite; ein Strich, der ausserhalb begann, kam nie an
/// ("hoert auf zu schreiben"), ein Strich aus dem Streifen hinaus lief weiter und speicherte Punkte ausserhalb der
/// Seite (y -298...893 bei 595 Hoehe; im Journal des Besitzers -293...831). Jetzt dreht `PageInkView` den Inhalt
/// um die Drehung des Overlays zurueck und nimmt den Massstab aus der angezeigten Groesse.
/// Alle Daten sind selbst erzeugt; die Hochschul-PDF liegt nur lokal (`TEST_RUNNER_UNIFLOW_GDS_PDF`), nie im Repo.
@MainActor
final class EditorRotatedPageTests: XCTestCase {

    // MARK: Test-PDF

    /// Seiten `size` (MediaBox, ungedreht) mit `/Rotate`, schwarzes Quadrat 20...80 oben links der ungedrehten Seite.
    private func makePDFData(pages: Int, size: CGSize, rotate: Int) -> Data {
        let raw = NSMutableData()
        var first = CGRect(origin: .zero, size: size)
        let ctx = CGContext(consumer: CGDataConsumer(data: raw as CFMutableData)!, mediaBox: &first, nil)!
        for _ in 0..<pages {
            var box = CGRect(origin: .zero, size: size)
            let info = [kCGPDFContextMediaBox as String: NSData(bytes: &box, length: MemoryLayout<CGRect>.size)] as CFDictionary
            ctx.beginPDFPage(info)
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
            UIGraphicsPushContext(ctx)
            UIColor.black.setFill()
            UIRectFill(CGRect(x: 20, y: 20, width: 60, height: 60))
            UIGraphicsPopContext()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        guard rotate != 0 else { return raw as Data }
        let doc = PDFDocument(data: raw as Data)!
        for i in 0..<pages { doc.page(at: i)!.rotation = rotate }
        return doc.dataRepresentation()!
    }

    // MARK: Dokument und Editor

    private func makeStore(pdf: Data, pageCount: Int) async throws -> DocumentStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rotate-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let host = LocalBackendHost(directory: root.appendingPathComponent("db", isDirectory: true),
                                    clock: .fixed(berlin: "2026-11-04T10:00:00")!)
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
        let fileID = "rotate-test-" + UUID().uuidString.prefix(8).lowercased()
        let pdfURL = AppPaths.pdf(fileID, namespace: api.namespace, root: root)
        try FileManager.default.createDirectory(at: pdfURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pdf.write(to: pdfURL)
        let file = LibFile(id: fileID, name: "Folien.pdf", title: "Folien", kind: "pdf", module_id: nil, subject: "GDS",
                           doc_type: nil, ai_title: nil, sub_label: nil, downloaded_at: "2026-11-04", has_notes: nil,
                           page_count: pageCount, studip_folder: nil)
        let store = DocumentStore(file: file, api: api, root: root)
        store.saveTiming = SaveTiming(pause: 0.05, maxDelay: 0.5)
        await store.load()
        XCTAssertNil(store.errorMessage, store.errorMessage ?? "")
        return store
    }

    private struct Shown {
        let editor: PDFEditorController
        let window: UIWindow
    }

    /// Editor in einem Fenster 1000 x 800 (Querformat-Seiten passen mit Zoom ~1,18 hinein)
    private func show(_ store: DocumentStore) -> Shown {
        let editor = PDFEditorController(store: store)
        editor.pencilOnly = true
        editor.ownNotesVisible = true
        editor.canEdit = true
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        window.rootViewController = editor
        window.makeKeyAndVisible()
        return Shown(editor: editor, window: window)
    }

    private func hide(_ shown: Shown) {
        shown.editor.showToolPicker(false)
        shown.window.isHidden = true
        shown.window.rootViewController = nil
    }

    private func installedOverlay(_ editor: PDFEditorController, page: Int) -> PageInkView? {
        var out: PageInkView?
        func walk(_ v: UIView) {
            if let o = v as? PageInkView {
                if o.generation == editor.shownLayoutVersion, o.window != nil, o.pageIndex == page { out = o }
                return
            }
            v.subviews.forEach(walk)
        }
        walk(editor.pdfView)
        return out
    }

    private func waitForOverlay(_ editor: PDFEditorController, page: Int, timeout: Double = 10) async throws -> PageInkView {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            editor.view.layoutIfNeeded()
            if let o = installedOverlay(editor, page: page), o.loaded, o.bounds.width > 0 { return o }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw NSError(domain: "rotate-test", code: 1, userInfo: [NSLocalizedDescriptionKey: "kein geladenes Overlay fuer Seite \(page + 1)"])
    }

    private func scrollView(_ editor: PDFEditorController) -> UIScrollView? {
        func find(_ v: UIView) -> UIScrollView? {
            if let s = v as? UIScrollView, !(v is PKCanvasView) { return s }
            for sub in v.subviews { if let s = find(sub) { return s } }
            return nil
        }
        return find(editor.pdfView)
    }

    private func waitForObjects(_ store: DocumentStore, key: String, count: Int, timeout: Double = 5) async throws -> [JSONValue] {
        let end = Date().addingTimeInterval(timeout)
        var objects: [JSONValue] = []
        while Date() < end {
            objects = await store.objects(forPageKey: key)
            if objects.count == count { return objects }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw NSError(domain: "rotate-test", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(objects.count) statt \(count) Objekte auf \(key)"])
    }

    /// Punkt der angezeigten Seite (Ursprung oben links, mit Drehung) als Punkt im PDF-Seitenraum der CropBox
    /// (Ursprung unten links, ohne Drehung), wie `PDFView.convert(_:from:)` ihn erwartet. Unabhaengig vom Editor
    /// hergeleitet: /Rotate 90 dreht die Seite im Uhrzeigersinn, die linke obere Ecke der Anzeige ist die linke untere
    /// Ecke der ungedrehten Seite.
    private func pdfPoint(displayed d: CGPoint, page: PDFPage) -> CGPoint {
        let crop = page.bounds(for: .cropBox)
        let w = crop.width, h = crop.height
        let u: CGPoint     // in der ungedrehten Seite, Ursprung oben links
        switch ((page.rotation % 360) + 360) % 360 {
        case 90: u = CGPoint(x: d.y, y: h - d.x)
        case 180: u = CGPoint(x: w - d.x, y: h - d.y)
        case 270: u = CGPoint(x: w - d.y, y: d.x)
        default: u = d
        }
        return CGPoint(x: crop.minX + u.x, y: crop.minY + h - u.y)
    }

    private func line(_ a: CGPoint, _ b: CGPoint) -> PKStroke {
        let pts = (0..<40).map { i -> PKStrokePoint in
            let t = CGFloat(i) / 39
            return PKStrokePoint(location: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), timeOffset: Double(i) * 0.01,
                                 size: CGSize(width: 2.5, height: 2.5), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: pts, creationDate: Date()))
    }

    /// Strich wie mit dem Stift: Canvas aendert sich, der Editor bekommt die Meldung von PencilKit.
    private func drawStroke(_ editor: PDFEditorController, on overlay: PageInkView, _ stroke: PKStroke) {
        editor.canvasViewDidBeginUsingTool(overlay.canvas)
        var d = overlay.canvas.drawing
        d.strokes.append(stroke)
        overlay.isApplyingDrawing = true
        overlay.canvas.drawing = d
        overlay.isApplyingDrawing = false
        editor.canvasViewDrawingDidChange(overlay.canvas)
        editor.canvasViewDidEndUsingTool(overlay.canvas)
    }

    // MARK: Pruefungen

    /// (a) Abbildung: ein angezeigter Seitenpunkt liegt ueber `content` an derselben Stelle der PDFView wie ueber
    /// PDFKit (`convert(_:from: page)`); (b) jeder Punkt der Seite trifft die Canvas (Rahmen und Trefferpruefung).
    private func checkMapping(_ editor: PDFEditorController, overlay: PageInkView, page: PDFPage, label: String,
                              hitTest: Bool = true) {
        let size = overlay.geometry.pageSize
        XCTAssertEqual(size, PageGeometry(boxSize: page.bounds(for: .cropBox).size, rotation: page.rotation).pageSize, label)
        let inset: CGFloat = 6     // Trefferpruefung nicht genau auf der Kante
        let points = [CGPoint(x: inset, y: inset), CGPoint(x: size.width - inset, y: inset),
                      CGPoint(x: inset, y: size.height - inset), CGPoint(x: size.width - inset, y: size.height - inset),
                      CGPoint(x: size.width * 0.95, y: size.height * 0.84), CGPoint(x: size.width / 2, y: size.height / 2)]
        for d in points {
            let viaPDF = editor.pdfView.convert(pdfPoint(displayed: d, page: page), from: page)
            let viaOverlay = overlay.content.convert(d, to: editor.pdfView)
            XCTAssertEqual(viaOverlay.x, viaPDF.x, accuracy: 0.5, "\(label): x von \(d)")
            XCTAssertEqual(viaOverlay.y, viaPDF.y, accuracy: 0.5, "\(label): y von \(d)")
            let inCanvas = editor.pdfView.convert(viaPDF, to: overlay.canvas)
            XCTAssertTrue(overlay.canvas.bounds.insetBy(dx: -0.5, dy: -0.5).contains(inCanvas),
                          "\(label): \(d) liegt in der Canvas (\(inCanvas) in \(overlay.canvas.bounds))")
            // Trefferpruefung wie eine Beruehrung (nur Punkte, die im Fenster liegen)
            if hitTest, let window = editor.view.window {
                let inWindow = editor.pdfView.convert(viaPDF, to: window)
                guard window.bounds.insetBy(dx: 1, dy: 1).contains(inWindow) else { continue }
                let hit = window.hitTest(inWindow, with: nil)
                XCTAssertTrue(hit?.isDescendant(of: overlay.canvas) == true,
                              "\(label): Beruehrung bei \(d) (Fenster \(inWindow)) erreicht die Canvas, traf \(hit.map { "\(type(of: $0)) \($0.frame)" } ?? "nichts")")
            }
        }
    }

    /// Ein Strich nahe der rechten unteren Ecke der angezeigten Seite kommt als Objekt in angezeigten Seitenpunkten
    /// zurueck (Web-Vertrag) und liegt in der Seite.
    private func checkRoundTrip(_ editor: PDFEditorController, store: DocumentStore, overlay: PageInkView, label: String) async throws {
        let size = overlay.geometry.pageSize
        let a = CGPoint(x: size.width - 60, y: size.height - 100), b = CGPoint(x: size.width - 42, y: size.height - 95)
        drawStroke(editor, on: overlay, line(a, b))
        let objects = try await waitForObjects(store, key: overlay.pageKey, count: 1)
        let pts = try XCTUnwrap(objects[0]["points"]?.array?.compactMap(\.double), label)
        XCTAssertGreaterThanOrEqual(pts.count, 4, label)
        XCTAssertEqual(pts[0], Double(a.x), accuracy: 1, label)
        XCTAssertEqual(pts[1], Double(a.y), accuracy: 1, label)
        XCTAssertEqual(pts[pts.count - 2], Double(b.x), accuracy: 1, label)
        XCTAssertEqual(pts[pts.count - 1], Double(b.y), accuracy: 1, label)
        let xs = stride(from: 0, to: pts.count, by: 2).map { pts[$0] }, ys = stride(from: 1, to: pts.count, by: 2).map { pts[$0] }
        XCTAssertTrue(xs.allSatisfy { $0 >= 0 && $0 <= Double(size.width) }, "\(label): x in 0...\(size.width): \(xs.min()!)...\(xs.max()!)")
        XCTAssertTrue(ys.allSatisfy { $0 >= 0 && $0 <= Double(size.height) }, "\(label): y in 0...\(size.height): \(ys.min()!)...\(ys.max()!)")
    }

    /// Ganzer Durchlauf fuer eine Seitengroesse und Drehung: Abbildung, Trefferpruefung, Rundlauf, Zoom
    /// (`setRenderScale`) und Parken/Wiederanzeigen (weg- und zurueckblaettern).
    private func run(size: CGSize, rotate: Int, extra: Int = 0) async throws {
        let label = "\(Int(size.width))x\(Int(size.height)) /Rotate \(rotate) + \(extra)"
        let store = try await makeStore(pdf: makePDFData(pages: 8, size: size, rotate: rotate), pageCount: 8)
        if extra != 0 {
            for _ in 0..<(extra / 90) { await store.rotatePage(key: "p1") }
            XCTAssertEqual(store.layout?.entries.first?.rotation, extra, label)
        }
        let shown = show(store)
        defer { hide(shown) }
        let editor = shown.editor
        var overlay = try await waitForOverlay(editor, page: 0)
        var page = try XCTUnwrap(editor.pdfView.document?.page(at: 0))
        XCTAssertEqual(page.rotation, (rotate + extra) % 360, label)
        checkMapping(editor, overlay: overlay, page: page, label: label)
        try await checkRoundTrip(editor, store: store, overlay: overlay, label: label)

        // Zoom hinein und heraus: Canvas zoomt selbst, Transform bringt sie zurueck; Abbildung und Striche bleiben
        let before = overlay.canvas.drawing
        overlay.setRenderScale(6, screen: 2)
        XCTAssertEqual(overlay.canvas.zoomScale, 3, accuracy: 0.001, label)
        checkMapping(editor, overlay: overlay, page: page, label: label + " Zoom 3", hitTest: false)
        XCTAssertEqual(overlay.canvas.drawing, before, "\(label): Striche bleiben in Seitenpunkten")
        overlay.setRenderScale(2, screen: 2)
        XCTAssertEqual(overlay.canvas.zoomScale, 1, accuracy: 0.001, label)
        checkMapping(editor, overlay: overlay, page: page, label: label + " Zoom 1", hitTest: false)

        // wegblaettern (PDFKit nimmt das Overlay heraus, der Editor parkt es) und zurueck (wieder eingesetzt)
        let scroll = try XCTUnwrap(scrollView(editor), label)
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: scroll.contentSize.height - scroll.bounds.height), animated: false)
        _ = try await waitForOverlay(editor, page: 7)
        let end = Date().addingTimeInterval(5)
        while Date() < end, installedOverlay(editor, page: 0) != nil { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNil(installedOverlay(editor, page: 0), "\(label): Seite 1 ist aus dem Bild")
        XCTAssertGreaterThan(editor.parkedCountForTesting, 0, "\(label): Overlay geparkt")
        let parked = overlay
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: 0), animated: false)
        overlay = try await waitForOverlay(editor, page: 0)
        XCTAssertTrue(overlay === parked, "\(label): dasselbe Overlay wieder eingesetzt")
        page = try XCTUnwrap(editor.pdfView.document?.page(at: 0))
        checkMapping(editor, overlay: overlay, page: page, label: label + " nach Parken")
        XCTAssertEqual(overlay.canvas.drawing.strokes.count, 1, label)
    }

    // MARK: Regression (Seite 595 x 842 wie GDS; 0 = bisheriges Verhalten)

    func testRotate0() async throws { try await run(size: CGSize(width: 595, height: 842), rotate: 0) }
    func testRotate90() async throws { try await run(size: CGSize(width: 595, height: 842), rotate: 90) }
    func testRotate180() async throws { try await run(size: CGSize(width: 595, height: 842), rotate: 180) }
    func testRotate270() async throws { try await run(size: CGSize(width: 595, height: 842), rotate: 270) }
    /// Querformat-Folie (wie die Decks, die schon gingen) ohne /Rotate
    func testLandscapeWithoutRotate() async throws { try await run(size: CGSize(width: 960, height: 540), rotate: 0) }
    /// Drehung aus `pageOrder` (am iPad gedreht) allein und zusammen mit /Rotate
    func testExtraRotation90() async throws { try await run(size: CGSize(width: 595, height: 842), rotate: 0, extra: 90) }
    func testRotate90PlusExtra90() async throws { try await run(size: CGSize(width: 595, height: 842), rotate: 90, extra: 90) }
    func testRotate90PlusExtra270() async throws { try await run(size: CGSize(width: 595, height: 842), rotate: 90, extra: 270) }

    /// Nur ohne PDFView: Overlay im Rahmen der ungedrehten Box, gedreht wie von PDFKit; der Inhalt deckt die Seite.
    func testOverlayCountersPDFKitRotation() {
        for (turns, box, shown) in [(0, CGSize(width: 595, height: 842), CGSize(width: 595, height: 842)),
                                    (1, CGSize(width: 595, height: 842), CGSize(width: 842, height: 595)),
                                    (2, CGSize(width: 595, height: 842), CGSize(width: 595, height: 842)),
                                    (3, CGSize(width: 595, height: 842), CGSize(width: 842, height: 595))] {
            let overlay = PageInkView(pageIndex: 0, geometry: PageGeometry(boxSize: box, rotation: turns * 90))
            overlay.bounds = CGRect(origin: .zero, size: box)
            overlay.transform = CGAffineTransform(rotationAngle: CGFloat(turns) * .pi / 2)
            overlay.layoutIfNeeded()
            XCTAssertEqual(overlay.canvas.frame.size, shown, "Drehung \(turns * 90)")
            // die vier Ecken des Inhalts liegen auf den Ecken des Overlay-Rahmens
            let corners = [CGPoint.zero, CGPoint(x: shown.width, y: 0), CGPoint(x: 0, y: shown.height), CGPoint(x: shown.width, y: shown.height)]
                .map { overlay.content.convert($0, to: overlay) }
            for c in corners {
                XCTAssertTrue(abs(c.x) < 0.01 || abs(c.x - box.width) < 0.01, "Drehung \(turns * 90): Ecke \(c)")
                XCTAssertTrue(abs(c.y) < 0.01 || abs(c.y - box.height) < 0.01, "Drehung \(turns * 90): Ecke \(c)")
            }
            // oben links der Anzeige: bei 90 Grad die linke untere Ecke der ungedrehten Box
            let topLeft = overlay.content.convert(CGPoint.zero, to: overlay)
            let expected = [CGPoint.zero, CGPoint(x: 0, y: box.height), CGPoint(x: box.width, y: box.height), CGPoint(x: box.width, y: 0)][turns]
            XCTAssertEqual(topLeft.x, expected.x, accuracy: 0.01, "Drehung \(turns * 90)")
            XCTAssertEqual(topLeft.y, expected.y, accuracy: 0.01, "Drehung \(turns * 90)")
            if turns == 0 { XCTAssertEqual(overlay.content.transform, .identity) }
        }
        XCTAssertEqual(PageInkView.quarterTurns(of: CGAffineTransform(rotationAngle: -.pi / 2)), 3)
        XCTAssertEqual(PageInkView.quarterTurns(of: CGAffineTransform(scaleX: 2, y: 2)), 0)
    }

    // MARK: Echte Datei (nur lokal, nie im Repo)

    /// Die Hochschul-PDF des Besitzers, wenn `TEST_RUNNER_UNIFLOW_GDS_PDF` auf sie zeigt; sonst uebersprungen.
    func testRealGDSFileIfPresent() async throws {
        guard let path = ProcessInfo.processInfo.environment["UNIFLOW_GDS_PDF"], FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("UNIFLOW_GDS_PDF nicht gesetzt")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        let store = try await makeStore(pdf: data, pageCount: pdf.pageCount)
        let shown = show(store)
        defer { hide(shown) }
        let editor = shown.editor
        let overlay = try await waitForOverlay(editor, page: 0)
        let page = try XCTUnwrap(editor.pdfView.document?.page(at: 0))
        XCTAssertEqual(page.rotation, 90)
        XCTAssertEqual(overlay.geometry.pageSize.width, 842, accuracy: 0.5)
        XCTAssertEqual(overlay.geometry.pageSize.height, 595, accuracy: 0.5)
        checkMapping(editor, overlay: overlay, page: page, label: "GDS")
        try await checkRoundTrip(editor, store: store, overlay: overlay, label: "GDS")
    }
}
