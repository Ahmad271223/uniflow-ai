import PDFKit
import PencilKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Absturz Build 30 (TestFlight, iPad 9 / iPad12,1 mit 3 GB, iPadOS 26.5, 11.11.2026): EXC_BREAKPOINT in
/// `CFRelease` <- `-[PDFTileSurface releaseSurface]` <- `-[PDFPageLayerTile dealloc]` <- `-[UIScrollView setContentOffset:]`
/// beim Scrollen, kurz nachdem eine noch nicht geladene Datei geholt und geoeffnet war. Der Fehler sitzt in PDFKit
/// (Ueberfreigabe einer Kachel-Oberflaeche, fast nur iPad 9 mit iPadOS 26.4/26.5); die App reizt PDFKit nicht mehr:
/// - Miniaturen, Scans der Suche und "Loesung daneben" zeichnen im Hintergrund nur aus einer eigenen PDF-Instanz,
///   nie aus der PDF der PDFView (vorher Kopien der angezeigten Seiten, gleichzeitig mit den Kacheln der PDFView);
/// - der Tausch von `pdfView.document` (neuer Seitenaufbau) wartet, bis die Ansicht nicht mehr scrollt oder zoomt;
/// - eine Speicherwarnung gibt geparkte Seiten-Overlays und die Miniaturen-Instanz frei.
/// Echter Weg wie in `AuditPaket41AppTests`: `DocumentStore` mit lokalem Backend im Temp-Ordner. Alle Daten erfunden.
@MainActor
final class PDFTileCrashGuardTests: XCTestCase {

    struct Fixture {
        let root: URL
        let api: APIClient
        let file: LibFile
    }

    /// PDF mit `pages` A4-Seiten; jede Seite traegt oben links ein schwarzes Feld (in der Miniatur leicht zu finden)
    private static func pdf(pages: Int) -> Data {
        let a4 = CGRect(x: 0, y: 0, width: 595, height: 842)
        return UIGraphicsPDFRenderer(bounds: a4).pdfData { ctx in
            for i in 0..<pages {
                ctx.beginPage()
                UIColor.black.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 420))
                ("Folie \(i + 1)" as NSString).draw(at: CGPoint(x: 340, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
            }
        }
    }

    private func makeFixture(pages: Int = 3) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-tile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let host = LocalBackendHost(directory: root.appendingPathComponent("db", isDirectory: true),
                                    clock: .fixed(berlin: "2026-11-11T09:00:00")!)
        let backend = try await host.backend()
        let fileID = "tile-" + UUID().uuidString.prefix(8).lowercased()
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
        try Self.pdf(pages: pages).write(to: pdfURL)
        try DocumentStore.stamp(try await api.value("/api/files/\(fileID)"))
            .write(to: pdfURL.appendingPathExtension("stand"), atomically: true, encoding: .utf8)
        let file = LibFile(id: fileID, name: "Skript.pdf", title: "Skript", kind: "pdf", module_id: nil, subject: "Testkurs",
                           doc_type: nil, ai_title: nil, sub_label: nil, downloaded_at: "2026-11-11T08:00:00", has_notes: nil,
                           page_count: pages, studip_folder: nil)
        return Fixture(root: root, api: api, file: file)
    }

    private func openStore(_ fx: Fixture) async -> DocumentStore {
        let store = DocumentStore(file: fx.file, api: fx.api, root: fx.root)
        await store.load()
        XCTAssertNil(store.errorMessage, store.errorMessage ?? "")
        return store
    }

    private func wait(_ what: String, timeout: Double = 10, _ cond: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline { if try await cond() { return }; try await Task.sleep(nanoseconds: 30_000_000) }
        XCTFail("Zeit abgelaufen: \(what)")
    }

    /// Helligkeit (0 schwarz ... 1 weiss) eines Bildpunkts in Punkten des Bildes
    private func brightness(_ img: UIImage, at p: CGPoint) -> CGFloat {
        guard let cg = img.cgImage else { return -1 }
        var px = [UInt8](repeating: 0, count: 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            let s = img.scale
            // Bildpunkt (oben links gezaehlt) auf den 1x1-Kontext legen (CoreGraphics zaehlt von unten)
            ctx.draw(cg, in: CGRect(x: -p.x * s, y: -(CGFloat(cg.height) - p.y * s - 1), width: CGFloat(cg.width), height: CGFloat(cg.height)))
            return true
        }
        guard ok else { return -1 }
        return (CGFloat(px[0]) + CGFloat(px[1]) + CGFloat(px[2])) / (3 * 255)
    }

    // MARK: Miniaturen nie aus der Instanz der PDFView

    /// Die Miniatur zeigt die PDF-Seite (schwarzes Feld), gezeichnet aus der eigenen Instanz; die ist weder die PDF
    /// der PDFView noch das Original im Store. Nach einer Speicherwarnung entsteht sie neu (wieder eine eigene).
    func testThumbnailsDrawFromOwnPDFInstanceNeverFromPDFView() async throws {
        let fx = try await makeFixture()
        let store = await openStore(fx)
        let editor = PDFEditorController(store: store)
        editor.loadViewIfNeeded()
        let layout = try XCTUnwrap(store.layout)
        let shownPDF = try XCTUnwrap(editor.pdfView.document)
        XCTAssertTrue(shownPDF === layout.pdf)

        let opened = await store.offscreenPDF.documentForTesting()
        let own = try XCTUnwrap(opened, "eigene Instanz aus der Datei")
        XCTAssertFalse(own === shownPDF, "nie die PDF der PDFView")
        XCTAssertFalse(own === store.originalPDF, "nie das Original (dessen Seiten teilen die PDFView-Seiten)")
        for i in 0..<layout.pdf.pageCount {
            XCTAssertFalse(own.page(at: i) === layout.pdf.page(at: i))
        }

        let page = try XCTUnwrap(layout.pdf.page(at: 0))
        let entry = try XCTUnwrap(layout.entry(at: 0))
        let cache = ThumbnailCache()
        let drawn = await cache.refresh(key: entry.key, shape: OffscreenPDF.Shape(page: page, entry: entry), entry: entry,
                                        objects: [], images: [:], source: store.offscreenPDF, layoutVersion: store.layoutVersion,
                                        width: 140, scale: 1)
        XCTAssertTrue(drawn)
        let img = try XCTUnwrap(cache.images[entry.key])
        XCTAssertLessThan(brightness(img, at: CGPoint(x: 20, y: 20)), 0.2, "PDF-Inhalt (schwarzes Feld) aus der eigenen Instanz")
        XCTAssertGreaterThan(brightness(img, at: CGPoint(x: 120, y: 180)), 0.9, "Rest der Seite weiss")
        let drawnFromOwn = await store.offscreenPDF.pdfPagesDrawn
        XCTAssertEqual(drawnFromOwn, 1)

        // Speicherwarnung gibt die Instanz frei; danach wieder eine eigene, neue
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        try await wait("Instanz nach der Speicherwarnung neu") {
            let again = await store.offscreenPDF.documentForTesting()
            return again != nil && again !== own
        }
        let again = await store.offscreenPDF.documentForTesting()
        XCTAssertFalse(again === editor.pdfView.document)
        await store.close()
    }

    /// Gedrehte Seite (Drehung aus `pageOrder`): die Miniatur aus der eigenen Instanz uebernimmt die angezeigte Drehung
    func testThumbnailFromOwnInstanceKeepsShownRotation() async throws {
        let fx = try await makeFixture()
        let store = await openStore(fx)
        let layout = try XCTUnwrap(store.layout)
        let page = try XCTUnwrap(layout.pdf.page(at: 0))
        let entry = try XCTUnwrap(layout.entry(at: 0))
        let shape = OffscreenPDF.Shape(cropBox: page.bounds(for: .cropBox), rotation: 90, pdfIndex: entry.pdfIndex)
        let img = await store.offscreenPDF.thumbnail(shape: shape, entry: entry, objects: [], images: [:], width: 140, scale: 1)
        XCTAssertEqual(img.size.width, 140)
        XCTAssertEqual(img.size.height, 99, accuracy: 1, "quer wie die angezeigte Seite")
        await store.close()
    }

    // MARK: Kein Dokumenttausch waehrend des Scrollens

    /// Neuer Seitenaufbau (z. B. Seitenliste vom Server, nachgeladene Browser-Seite), waehrend der Finger scrollt oder
    /// die Ansicht ausrollt: `pdfView.document` bleibt, bis die Ansicht steht; danach kommt der Neuaufbau von selbst.
    func testLayoutSwapWaitsWhileScrollingAndFollowsWhenSettled() async throws {
        let fx = try await makeFixture()
        let store = await openStore(fx)
        let editor = PDFEditorController(store: store)
        editor.loadViewIfNeeded()
        let shown = editor.shownLayoutVersion
        let shownPDF = editor.pdfView.document

        editor.scrollGestureOverrideForTesting = true                  // Finger scrollt
        await store.addBlankPage(afterKey: nil, template: "lined")
        XCTAssertNotEqual(store.layoutVersion, shown)
        editor.showLayout()                                             // wie `updateUIViewController`
        XCTAssertEqual(editor.shownLayoutVersion, shown, "kein Tausch waehrend der Geste")
        XCTAssertTrue(editor.pdfView.document === shownPDF, "dieselbe PDF in der PDFView")
        XCTAssertTrue(editor.layoutWaitsForGesture)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(editor.shownLayoutVersion, shown, "solange gescrollt wird, bleibt es")

        editor.scrollGestureOverrideForTesting = false                 // Ansicht steht
        try await wait("Neuaufbau nach der Geste", timeout: 3) { editor.shownLayoutVersion == store.layoutVersion }
        XCTAssertFalse(editor.layoutWaitsForGesture)
        XCTAssertEqual(editor.pageCount, 4)
        XCTAssertFalse(editor.pdfView.document === shownPDF)
        await store.close()
    }

    /// Gegenprobe: ohne Geste tauscht `showLayout` sofort (keine Verzoegerung im Normalfall)
    func testLayoutSwapIsImmediateWithoutGesture() async throws {
        let fx = try await makeFixture()
        let store = await openStore(fx)
        let editor = PDFEditorController(store: store)
        editor.loadViewIfNeeded()
        editor.scrollGestureOverrideForTesting = false
        await store.addBlankPage(afterKey: nil, template: "lined")
        editor.showLayout()
        XCTAssertEqual(editor.shownLayoutVersion, store.layoutVersion)
        XCTAssertFalse(editor.layoutWaitsForGesture)
        await store.close()
    }

    // MARK: Speicherwarnung

    /// Speicherwarnung: geparkte Overlays (PencilKit-Flaechen) werden freigegeben; eines mit fruehen, noch nicht
    /// gesicherten Strichen bleibt. Beim Zurueckscrollen entsteht die Seite neu und laedt ihren Stand.
    func testMemoryWarningReleasesParkedOverlaysButKeepsUnsavedStrokes() async throws {
        let fx = try await makeFixture(pages: 3)
        let store = await openStore(fx)
        let editor = PDFEditorController(store: store)
        editor.loadViewIfNeeded()
        let pdf = try XCTUnwrap(editor.pdfView.document)
        let o1 = try XCTUnwrap(editor.overlayForTesting(at: 0))
        try await wait("Seite 1 geladen") { o1.loaded }
        let o2 = try XCTUnwrap(editor.overlayForTesting(at: 1))
        o2.loadTask?.cancel()                                           // noch nicht geladen ...
        o2.loadTask = nil
        var d = PKDrawing()
        d.strokes.append(Handschrift.line(from: CGPoint(x: 40, y: 100), to: CGPoint(x: 80, y: 120)))
        o2.canvas.drawing = d                                           // ... aber schon beschrieben
        editor.pdfView(editor.pdfView, willEndDisplayingOverlayView: o1, for: try XCTUnwrap(pdf.page(at: 0)))
        editor.pdfView(editor.pdfView, willEndDisplayingOverlayView: o2, for: try XCTUnwrap(pdf.page(at: 1)))
        XCTAssertEqual(editor.parkedCountForTesting, 2)

        editor.didReceiveMemoryWarning()
        XCTAssertEqual(editor.parkedCountForTesting, 1, "nur das Overlay mit ungesicherten Strichen bleibt")

        let back = try XCTUnwrap(editor.overlayForTesting(at: 0))
        XCTAssertFalse(back === o1, "Seite 1 wird neu aufgebaut")
        try await wait("Seite 1 wieder geladen") { back.loaded }
        XCTAssertTrue(try XCTUnwrap(editor.overlayForTesting(at: 1)) === o2, "das beschriebene Overlay kommt zurueck")
        await store.close()
    }

    // MARK: Belastung wie am Geraet (Simulator)

    /// Wie der Tester: Dokument im Fenster, Finger-Scrollen in vielen Schritten, dabei neue Seitenaufbauten,
    /// Miniaturen im Hintergrund und Speicherwarnungen. Im Simulator (iOS 27) stuerzt PDFKit nicht ab; der Test
    /// sichert, dass die Schutzregeln dabei halten (kein Tausch unter der Geste, alle Seiten am Ende da).
    func testScrollWithSwapsThumbnailsAndMemoryWarningsStaysConsistent() async throws {
        let fx = try await makeFixture(pages: 12)
        let store = await openStore(fx)
        let editor = PDFEditorController(store: store)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let frame = scene?.screen.bounds ?? CGRect(x: 0, y: 0, width: 820, height: 1180)
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        window.rootViewController = editor
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(nanoseconds: 300_000_000)
        let scroll = try XCTUnwrap(editor.firstScrollView(in: editor.pdfView))
        let cache = ThumbnailCache(limit: 8)

        var swapsUnderGesture = 0
        for step in 0..<60 {
            let gesture = step % 10 < 7                                 // 7 Schritte "Finger scrollt", 3 Schritte Ruhe
            editor.scrollGestureOverrideForTesting = gesture
            let maxY = max(0, scroll.contentSize.height - scroll.bounds.height)
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: CGFloat(step % 20) / 19 * maxY), animated: false)
            if step % 6 == 0 {
                let before = editor.shownLayoutVersion
                await store.addBlankPage(afterKey: nil, template: "squared")
                editor.showLayout()
                if gesture, editor.shownLayoutVersion != before { swapsUnderGesture += 1 }
            }
            if let layout = store.layout {
                let i = step % layout.pdf.pageCount
                if let page = layout.pdf.page(at: i), let entry = layout.entry(at: i) {
                    Task {
                        await cache.refresh(key: entry.key, shape: OffscreenPDF.Shape(page: page, entry: entry), entry: entry,
                                            objects: [], images: [:], source: store.offscreenPDF,
                                            layoutVersion: store.layoutVersion, width: 140, scale: 2)
                    }
                }
            }
            if step % 15 == 14 {
                NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
                editor.didReceiveMemoryWarning()
            }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertEqual(swapsUnderGesture, 0, "nie ein Tausch, waehrend gescrollt wird")
        editor.scrollGestureOverrideForTesting = false
        try await wait("letzter Seitenaufbau gezeigt", timeout: 3) { editor.shownLayoutVersion == store.layoutVersion }
        XCTAssertEqual(editor.pageCount, 12 + 10)
        await store.close()
    }
}
