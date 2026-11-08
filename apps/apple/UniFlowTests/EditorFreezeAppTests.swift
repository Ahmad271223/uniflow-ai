import PDFKit
import PencilKit
import SwiftUI
import UniFlowCore
import XCTest
@testable import UniFlow

/// Bildschirm fixieren im Editor (Wunsch des Inhabers 05.11.2026, docs/FIXIEREN-ABPAUSEN-2026-11-05.md) im echten
/// Editor mit lokalem Backend: "Ansicht fixieren" haelt Zoom und Stelle fest, der Stift schreibt weiter; "Zum
/// Abpausen einfrieren" nimmt keine Beruehrung mehr an und entsperrt nur nach zwei Sekunden Halten. Echte Finger und
/// Stifte gibt es im Test nicht: Gesten werden ueber ihren Zustand und die Trefferpruefung (hitTest) geprueft, Zoom
/// und Seitenwechsel ueber dieselben Wege wie Pinch, Seitenleiste und Fensterbreite. Alle Daten sind erfunden.
@MainActor
final class EditorFreezeAppTests: XCTestCase {

    private final class FakeScreen: EditorFreezeScreen {
        var idleTimerDisabled = false
        let supportsBrightness = true
        var brightness = 0.42
    }

    // MARK: Dokument und Editor

    private func makePDF(pages: Int, size: CGSize = CGSize(width: 595, height: 842), rotate: Int = 0) -> Data {
        let raw = NSMutableData()
        UIGraphicsBeginPDFContextToData(raw, CGRect(origin: .zero, size: size), nil)
        for i in 1...pages {
            UIGraphicsBeginPDFPageWithInfo(CGRect(origin: .zero, size: size), nil)
            "Technische Zeichnung \(i)".draw(at: CGPoint(x: 40, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
            UIColor.black.setStroke()
            UIBezierPath(rect: CGRect(x: 60, y: 120, width: 300, height: 200)).stroke()
        }
        UIGraphicsEndPDFContext()
        guard rotate != 0, let doc = PDFDocument(data: raw as Data) else { return raw as Data }
        for i in 0..<pages { doc.page(at: i)?.rotation = rotate }
        return doc.dataRepresentation() ?? raw as Data
    }

    private func makeStore(pages: Int, rotate: Int = 0) async throws -> DocumentStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fixieren-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let host = LocalBackendHost(directory: root.appendingPathComponent("db", isDirectory: true),
                                    clock: .fixed(berlin: "2026-11-05T10:00:00")!)
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
        let fileID = "fixieren-" + UUID().uuidString.prefix(8).lowercased()
        let pdfURL = AppPaths.pdf(fileID, namespace: api.namespace, root: root)
        try FileManager.default.createDirectory(at: pdfURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makePDF(pages: pages, rotate: rotate).write(to: pdfURL)
        let file = LibFile(id: fileID, name: "Zeichnung.pdf", title: "Zeichnung", kind: "pdf", module_id: nil, subject: "TM",
                           doc_type: nil, ai_title: nil, sub_label: nil, downloaded_at: "2026-11-05", has_notes: nil,
                           page_count: pages, studip_folder: nil)
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

    private func show(_ store: DocumentStore, in container: ((PDFEditorController) -> UIViewController)? = nil) -> Shown {
        let editor = PDFEditorController(store: store)
        editor.pencilOnly = true
        editor.ownNotesVisible = true
        editor.canEdit = true
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        window.rootViewController = container?(editor) ?? editor
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in
            editor.showToolPicker(false)
            window.isHidden = true
            window.rootViewController = nil
        }
        return Shown(editor: editor, window: window)
    }

    /// Warten, waehrend die Hauptschlange weiterlaeuft (in async-Tests blockierte ein verschachteltes RunLoop.run sie)
    private func pump(_ seconds: Double = 0.4) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    private func scroll(_ e: PDFEditorController) throws -> UIScrollView { try XCTUnwrap(e.firstScrollView(in: e.pdfView)) }

    /// Punkt der Seite `index` an der linken oberen Ecke der PDF-Ansicht (in Seitenpunkten)
    private func corner(_ e: PDFEditorController, page index: Int) throws -> CGPoint {
        let page = try XCTUnwrap(e.pdfView.document?.page(at: index))
        return e.pdfView.convert(CGPoint(x: e.pdfView.bounds.minX, y: e.pdfView.bounds.minY), to: page)
    }

    /// Wo der Seitenpunkt jetzt in der PDF-Ansicht liegt: fixiert bleibt er an der linken oberen Ecke. Senkrecht immer;
    /// waagerecht nur, wenn die Seite breiter als die Ansicht ist (schmaler legt PDFKit sie in die Mitte, siehe Doku)
    private func assertStays(_ e: PDFEditorController, page index: Int, point: CGPoint, horizontal: Bool = true, _ what: String,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let page = try XCTUnwrap(e.pdfView.document?.page(at: index))
        let now = e.pdfView.convert(point, from: page)
        XCTAssertEqual(now.y, e.pdfView.bounds.minY, accuracy: 1, "\(what): senkrecht", file: file, line: line)
        if horizontal { XCTAssertEqual(now.x, e.pdfView.bounds.minX, accuracy: 1, "\(what): waagerecht", file: file, line: line) }
    }

    /// Overlay der Seite, sobald sein Inhalt geladen ist (vorher nimmt der Editor Striche erst beim Laden an)
    private func loadedOverlay(_ editor: PDFEditorController, page: Int) async throws -> PageInkView {
        let end = Date().addingTimeInterval(5)
        while Date() < end {
            if let o = installedOverlay(editor, page: page), o.loaded { return o }
            await pump(0.05)
        }
        return try XCTUnwrap(installedOverlay(editor, page: page).flatMap { $0.loaded ? $0 : nil }, "Overlay \(page) geladen")
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

    private func line(_ a: CGPoint, _ b: CGPoint) -> PKStroke {
        let pts = (0..<30).map { i -> PKStrokePoint in
            let t = CGFloat(i) / 29
            return PKStrokePoint(location: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), timeOffset: Double(i) * 0.01,
                                 size: CGSize(width: 2, height: 2), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: pts, creationDate: Date()))
    }

    /// Strich wie mit dem Stift: Canvas aendert sich, der Editor bekommt die Meldungen von PencilKit
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

    /// Trifft eine Beruehrung in der Mitte der Seite die Zeichenflaeche (wie ein Stift)?
    private func touchReachesCanvas(_ shown: Shown, overlay: PageInkView) -> Bool {
        let mid = overlay.canvas.convert(CGPoint(x: overlay.canvas.bounds.midX, y: overlay.canvas.bounds.midY), to: shown.window)
        let visible = shown.editor.pdfView.convert(shown.editor.pdfView.bounds, to: shown.window)
        let p = visible.contains(mid) ? mid : CGPoint(x: visible.midX, y: visible.midY)
        guard let hit = shown.window.hitTest(p, with: nil) else { return false }
        return hit.isDescendant(of: overlay.canvas)
    }

    private func enabledZoomTaps(_ e: PDFEditorController) -> Int {
        PDFEditorController.zoomTapGestures(in: e.pdfView).filter(\.isEnabled).count
    }

    // MARK: Ansicht fixieren

    /// Fixiert: Scroll- und Pinch-Gesten aus, Doppeltippen aus; Seitenleiste/Gehe zu Seite, Einpassen, ein
    /// durchgerutschter Zoom und eine neue Fensterbreite (geteilte Ansicht) aendern Zoom und Stelle nicht. Der Stift
    /// trifft weiter die Zeichenflaeche und der Strich kommt im Store an. Gegenprobe nach dem Loesen.
    func testViewLockKeepsVisibleRectWhilePencilStillDraws() async throws {
        let store = try await makeStore(pages: 4)
        let shown = show(store)
        let e = shown.editor
        await pump()
        e.goToPage(1)
        await pump()
        let scrollView = try scroll(e)
        XCTAssertTrue(scrollView.isScrollEnabled)
        let tapsBefore = enabledZoomTaps(e)
        let index = e.currentPageIndex
        let scale = e.pdfView.scaleFactor
        let before = try corner(e, page: index)

        e.freezeMode = .view
        XCTAssertNotNil(e.freezeAnchor)
        XCTAssertFalse(scrollView.isScrollEnabled, "kein Scrollen (Finger, Trackpad)")
        XCTAssertFalse(scrollView.panGestureRecognizer.isEnabled)
        XCTAssertEqual(scrollView.pinchGestureRecognizer?.isEnabled, false, "kein Pinch-Zoom")
        XCTAssertEqual(enabledZoomTaps(e), 0, "kein Doppeltippen zum Zoomen")
        XCTAssertFalse(scrollView.scrollsToTop)
        XCTAssertTrue(e.pdfView.isUserInteractionEnabled, "Stift und Werkzeuge bleiben")
        XCTAssertTrue(e.pickerAllowed, "Palette bleibt")

        // Versuche, die Ansicht zu bewegen
        e.goToPage(3)                                       // Seitenleiste, Suche, Gehe zu Seite
        e.fitWidth()                                        // "100 %" antippen
        e.pdfView.scaleFactor = scale * 1.8                 // Zoom, der doch durchkommt
        await pump()
        shown.window.frame = CGRect(x: 0, y: 0, width: 760, height: 800)   // geteilte Ansicht schmaler
        shown.window.layoutIfNeeded()
        await pump()
        XCTAssertEqual(e.pdfView.scaleFactor, scale, accuracy: 0.001, "Zoom bleibt")
        XCTAssertEqual(e.currentPageIndex, index, "Seite bleibt")
        try assertStays(e, page: index, point: before, "geteilte Ansicht schmaler")

        // Stift schreibt weiter
        let overlay = try await loadedOverlay(e, page: index)
        XCTAssertTrue(touchReachesCanvas(shown, overlay: overlay), "Stift trifft die Zeichenflaeche")
        XCTAssertTrue(overlay.canvas.drawingGestureRecognizer.isEnabled)
        XCTAssertTrue(overlay.canvas.isUserInteractionEnabled)
        let key = try XCTUnwrap(e.shownLayout?.key(at: index))
        drawStroke(e, on: overlay, line(CGPoint(x: 80, y: 140), CGPoint(x: 340, y: 300)))
        await pump(0.3)
        let saved = await store.drawing(forPageKey: key)
        XCTAssertEqual(saved.strokes.count, 1, "Strich gespeichert")
        XCTAssertEqual(e.pdfView.scaleFactor, scale, accuracy: 0.001)
        try assertStays(e, page: index, point: before, "nach dem Strich")

        // Loesen: alles wie vorher
        e.freezeMode = .off
        XCTAssertNil(e.freezeAnchor)
        XCTAssertTrue(scrollView.isScrollEnabled)
        XCTAssertEqual(scrollView.pinchGestureRecognizer?.isEnabled, true)
        XCTAssertEqual(enabledZoomTaps(e), tapsBefore)
        XCTAssertTrue(scrollView.scrollsToTop)
        e.goToPage(3)
        await pump()
        XCTAssertEqual(e.currentPageIndex, 3, "Gegenprobe: ohne Fixieren springt die Ansicht")
        await store.close()
    }

    /// Audit Paket 41, P41-09: fixiert und dann ein neuer Seitenaufbau (Seite eingefuegt, wie vom Server oder einem
    /// anderen Geraet): Gesten bleiben aus, Zoom und Stelle bleiben; nach dem Loesen ist alles wieder an.
    func testViewLockSurvivesLayoutRebuild() async throws {
        let store = try await makeStore(pages: 4)
        let shown = show(store)
        let e = shown.editor
        await pump()
        e.goToPage(1)
        await pump()
        let scrollView = try scroll(e)
        let tapsBefore = enabledZoomTaps(e)
        let index = e.currentPageIndex
        let scale = e.pdfView.scaleFactor
        let before = try corner(e, page: index)
        e.freezeMode = .view
        let version = e.shownLayoutVersion

        await store.addBlankPage(afterKey: nil, template: "grid")       // ans Ende, die fixierte Seite bleibt Index 1
        e.showLayout()
        await pump()
        XCTAssertNotEqual(e.shownLayoutVersion, version, "neu aufgebaut")
        XCTAssertEqual(e.pageCount, 5)
        let scrollNow = try scroll(e)
        XCTAssertFalse(scrollNow.isScrollEnabled, "kein Scrollen nach dem Neuaufbau")
        XCTAssertEqual(scrollNow.pinchGestureRecognizer?.isEnabled, false, "kein Pinch-Zoom nach dem Neuaufbau")
        XCTAssertEqual(enabledZoomTaps(e), 0, "kein Doppeltippen nach dem Neuaufbau")
        XCTAssertEqual(e.pdfView.scaleFactor, scale, accuracy: 0.001, "Zoom bleibt")
        XCTAssertEqual(e.currentPageIndex, index, "Seite bleibt")
        try assertStays(e, page: index, point: before, "nach dem Neuaufbau")

        e.freezeMode = .off
        XCTAssertTrue(scrollNow.isScrollEnabled)
        XCTAssertEqual(scrollNow.pinchGestureRecognizer?.isEnabled, true)
        XCTAssertGreaterThanOrEqual(enabledZoomTaps(e), min(1, tapsBefore), "Doppeltippen wieder an")
        _ = scrollView
        await store.close()
    }

    /// Gedrehte Seiten (/Rotate 90): fixiert bleibt die Stelle bei neuer Fensterbreite, der Strich landet auf der Seite
    func testViewLockOnRotatedPages() async throws {
        let store = try await makeStore(pages: 3, rotate: 90)
        let shown = show(store)
        let e = shown.editor
        await pump()
        // mitten im Dokument (am oberen Rand des Dokuments begrenzt der Scrollbereich die Stelle)
        e.goToPage(1)
        await pump()
        let index = e.currentPageIndex
        let scale = e.pdfView.scaleFactor
        let before = try corner(e, page: index)
        e.freezeMode = .view
        shown.window.frame = CGRect(x: 0, y: 0, width: 820, height: 950)
        shown.window.layoutIfNeeded()
        await pump()
        XCTAssertEqual(e.pdfView.scaleFactor, scale, accuracy: 0.001)
        try assertStays(e, page: index, point: before, horizontal: false, "gedrehte Seite, Fenster schmaler und hoeher")
        let overlay = try await loadedOverlay(e, page: index)
        XCTAssertTrue(touchReachesCanvas(shown, overlay: overlay))
        drawStroke(e, on: overlay, line(CGPoint(x: 100, y: 100), CGPoint(x: 400, y: 260)))
        await pump(0.3)
        let saved = await store.drawing(forPageKey: try XCTUnwrap(e.shownLayout?.key(at: index)))
        XCTAssertEqual(saved.strokes.count, 1)
        e.freezeMode = .off
        await store.close()
    }

    /// Zurueck-Wischen der Navigation ist fixiert aus und danach wieder an
    func testViewLockDisablesEdgeSwipeBack() async throws {
        let store = try await makeStore(pages: 2)
        var nav: UINavigationController?
        let shown = show(store) { editor in
            let n = UINavigationController(rootViewController: UIViewController())
            n.pushViewController(editor, animated: false)
            nav = n
            return n
        }
        await pump()
        let pop = try XCTUnwrap(nav?.interactivePopGestureRecognizer)
        XCTAssertTrue(pop.isEnabled)
        shown.editor.freezeMode = .view
        XCTAssertFalse(pop.isEnabled, "kein Zurueck-Wischen vom Rand")
        shown.editor.freezeMode = .trace
        XCTAssertFalse(pop.isEnabled)
        shown.editor.freezeMode = .off
        XCTAssertTrue(pop.isEnabled)
        await store.close()
    }

    // MARK: Zum Abpausen einfrieren

    /// Abpausen: keine Beruehrung erreicht PDF oder Zeichenflaeche (kein Strich, kein Scrollen), Palette weg, weisser
    /// Hintergrund; Leisten aus (hoeheres Fenster) verschiebt nichts. Entsperren nur nach zwei Sekunden Halten.
    func testTraceIgnoresTouchesAndUnlocksOnlyAfterLongPress() async throws {
        let store = try await makeStore(pages: 3)
        let shown = show(store)
        let e = shown.editor
        await pump()
        e.goToPage(1)
        await pump()
        let index = e.currentPageIndex
        let scale = e.pdfView.scaleFactor
        let before = try corner(e, page: index)
        let overlay = try await loadedOverlay(e, page: index)
        XCTAssertTrue(touchReachesCanvas(shown, overlay: overlay), "vorher trifft der Stift die Seite")

        let screen = FakeScreen()
        let freeze = EditorFreezeSession(screen: screen)
        freeze.startTracing(.init(maxBrightness: true, highContrast: true))
        XCTAssertTrue(screen.idleTimerDisabled, "Bildschirm bleibt an")
        XCTAssertEqual(screen.brightness, 1)
        e.traceContrast = true
        e.freezeMode = freeze.mode

        XCTAssertFalse(e.pdfView.isUserInteractionEnabled)
        XCTAssertFalse(touchReachesCanvas(shown, overlay: overlay), "Papier, Hand und Stift erreichen die Seite nicht")
        if let hit = shown.window.hitTest(CGPoint(x: 500, y: 400), with: nil) {
            XCTAssertFalse(hit.isDescendant(of: e.pdfView), "keine Beruehrung in der PDF-Ansicht")
        }
        XCTAssertFalse(e.pickerAllowed, "keine Palette")
        XCTAssertFalse(try scroll(e).isScrollEnabled)
        XCTAssertEqual(e.pdfView.backgroundColor, .white, "Kontrast: weisser Hintergrund")
        XCTAssertFalse(e.pdfView.pageShadowsEnabled)

        // Leisten verschwinden (Fenster hoeher): Zoom und Stelle bleiben
        shown.window.frame = CGRect(x: 0, y: 0, width: 1000, height: 900)
        shown.window.layoutIfNeeded()
        e.goToPage(2)
        await pump()
        XCTAssertEqual(e.pdfView.scaleFactor, scale, accuracy: 0.001, "aktueller Zoom")
        try assertStays(e, page: index, point: before, "Leisten aus")
        // Seitenleiste zu (breiter): Zoom und Hoehe bleiben, die Seite steht mittig
        shown.window.frame = CGRect(x: 0, y: 0, width: 1100, height: 900)
        shown.window.layoutIfNeeded()
        await pump()
        XCTAssertEqual(e.pdfView.scaleFactor, scale, accuracy: 0.001)
        try assertStays(e, page: index, point: before, horizontal: false, "Seitenleiste zu")
        let key = try XCTUnwrap(e.shownLayout?.key(at: index))
        let strokes = await store.drawing(forPageKey: key).strokes.count
        XCTAssertEqual(strokes, 0, "kein Strich")

        // kurz gehalten: bleibt gesperrt
        let t0 = Date()
        freeze.holdBegan(at: t0)
        XCTAssertTrue(freeze.holding)
        freeze.holdEnded(at: t0.addingTimeInterval(1.2))
        XCTAssertEqual(freeze.mode, .trace)
        XCTAssertFalse(freeze.holding)
        // zwei Sekunden gehalten: entsperrt
        freeze.holdBegan(at: t0)
        freeze.holdCheck(at: t0.addingTimeInterval(EditorFreeze.unlockHoldDuration + 0.05))
        XCTAssertEqual(freeze.mode, .off)
        XCTAssertFalse(screen.idleTimerDisabled, "Ruhezustand wie vorher")
        XCTAssertEqual(screen.brightness, 0.42, accuracy: 0.0001, "Helligkeit wie vorher")
        e.freezeMode = freeze.mode
        XCTAssertTrue(e.pdfView.isUserInteractionEnabled)
        XCTAssertTrue(touchReachesCanvas(shown, overlay: overlay), "danach schreibt der Stift wieder")
        XCTAssertTrue(e.pickerAllowed)
        XCTAssertTrue(e.pdfView.pageShadowsEnabled)
        XCTAssertNotEqual(e.pdfView.backgroundColor, .white)
        XCTAssertTrue(try scroll(e).isScrollEnabled)
        await store.close()
    }

    /// Echter Zeitgeber der Sitzung: gehalten -> nach etwa zwei Sekunden entsperrt; frueher losgelassen -> gesperrt
    func testHoldTimerUnlocksAfterTwoSeconds() async throws {
        let freeze = EditorFreezeSession(screen: FakeScreen())
        freeze.startTracing(.init())
        freeze.holdBegan()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(freeze.mode, .trace, "nach einer Sekunde noch gesperrt")
        try await Task.sleep(nanoseconds: 1_400_000_000)
        XCTAssertEqual(freeze.mode, .off, "nach gut zwei Sekunden entsperrt")

        freeze.startTracing(.init())
        freeze.holdBegan()
        try await Task.sleep(nanoseconds: 500_000_000)
        freeze.holdEnded()
        try await Task.sleep(nanoseconds: 2_200_000_000)
        XCTAssertEqual(freeze.mode, .trace, "losgelassen: bleibt gesperrt")
        freeze.end()
    }

    // MARK: Oberflaeche

    /// Bedienungshilfen-Baum von SwiftUI einschalten (wie AusfallMarkAppTests)
    @discardableResult
    private static func accessibilityAutomation(_ on: Bool) -> Bool {
        guard let h = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW), let f = dlsym(h, "_AXSSetAutomationEnabled") else { return false }
        typealias SetEnabled = @convention(c) (Int32) -> Void
        unsafeBitCast(f, to: SetEnabled.self)(on ? 1 : 0)
        return true
    }

    private func host<V: View>(_ view: V) -> UIView {
        let frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        let hosting = UIHostingController(rootView: view)
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in window.isHidden = true }
        return hosting.view
    }

    private func elements(in view: UIView) -> [NSObject] {
        view.layoutIfNeeded()
        var out: [NSObject] = []
        func visit(_ element: Any, depth: Int) {
            guard depth < 40 else { return }
            if let o = element as? NSObject {
                if o.accessibilityLabel?.isEmpty == false { out.append(o) }
                for e in o.accessibilityElements ?? [] { visit(e, depth: depth + 1) }
                let n = o.accessibilityElementCount()
                if n != NSNotFound, n > 0 {
                    for i in 0..<min(n, 500) { if let e = o.accessibilityElement(at: i) { visit(e, depth: depth + 1) } }
                }
            }
            if let v = element as? UIView { for s in v.subviews { visit(s, depth: depth + 1) } }
        }
        visit(view, depth: 0)
        return out
    }

    /// VoiceOver: das Schloss heisst "Abpausen-Sperre" und hat die Aktion "Entsperren"; die Flaeche darunter ist
    /// fuer VoiceOver verborgen
    func testTraceLockOverlayOffersVoiceOverUnlock() throws {
        XCTAssertTrue(Self.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
        defer { Self.accessibilityAutomation(false) }
        let freeze = EditorFreezeSession(screen: FakeScreen())
        freeze.startTracing(.init())
        let view = host(TraceLockOverlay(freeze: freeze))
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let lock = try XCTUnwrap(elements(in: view).first { $0.accessibilityLabel == FreezeTexts.lockLabel }, "Schloss als Element")
        XCTAssertEqual(lock.accessibilityHint, FreezeTexts.lockHint)
        let action = try XCTUnwrap(lock.accessibilityCustomActions?.first { $0.name == FreezeTexts.unlockAction }, "Aktion Entsperren")
        if let handler = action.actionHandler {
            XCTAssertTrue(handler(action))
        } else if let target = action.target as? NSObject {
            _ = target.perform(action.selector, with: action)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(freeze.mode, .off)
    }

    /// Abzeichen "Ansicht fixiert" mit "Lösen"
    func testBadgeReleases() throws {
        XCTAssertTrue(Self.accessibilityAutomation(true), "Bedienungshilfen-Automation nicht verfügbar")
        defer { Self.accessibilityAutomation(false) }
        var released = 0
        let view = host(FreezeBadge { released += 1 })
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let all = elements(in: view)
        XCTAssertTrue(all.contains { ($0.accessibilityLabel ?? "").contains(FreezeTexts.badge) })
        let badge = try XCTUnwrap(all.first { ($0.accessibilityLabel ?? "").contains(FreezeTexts.badge) })
        let action = try XCTUnwrap(badge.accessibilityCustomActions?.first { $0.name == FreezeTexts.release })
        if let handler = action.actionHandler { _ = handler(action) }
        XCTAssertEqual(released, 1)
    }

    // MARK: Ganzes Dokument (SwiftUI-Ansicht mit Leisten)

    private func hostedDocument(freeze start: String) throws -> HostedEnvironment {
        HostedEnvironment.accessibilityAutomation(true)
        addTeardownBlock { @MainActor in HostedEnvironment.accessibilityAutomation(false) }
        let previous = UserDefaults.standard.object(forKey: "UFDocFreeze")
        UserDefaults.standard.set(start, forKey: "UFDocFreeze")
        addTeardownBlock { @MainActor in UserDefaults.standard.set(previous, forKey: "UFDocFreeze") }
        let t = AIViewsAppTests.Transport()
        let id = "f-fix-\(UUID().uuidString.prefix(8))"
        t.answer("/api/files/\(id)/content", data: makePDF(pages: 3), type: "application/pdf")
        t.answer("/api/files/\(id)/annotations", ["data": AnnotationDocument.emptyRoot, "version": 0, "updated_at": .null])
        let meta: JSONValue = ["id": .string(id), "name": "Zeichnung.pdf", "title": "Zeichnung.pdf", "kind": "pdf", "module_id": 1,
                               "downloaded_at": "2026-11-05T09:00:00", "page_count": 3, "doc_type": "uebung"]
        let file = try JSONDecoder().decode(LibFile.self, from: meta.serialized())
        let api = APIClient(base: URL(string: "http://erfunden.test/")!, transport: t)
        return try hostWithEnvironment(NavigationStack { DocumentView(file: file, api: api) }, api: api)
    }

    private func pdfViews(in v: UIView) -> [PDFView] {
        (v as? PDFView).map { [$0] } ?? v.subviews.flatMap { pdfViews(in: $0) }
    }

    private func customAction(_ env: HostedEnvironment, label: String, action: String) -> UIAccessibilityCustomAction? {
        var found: UIAccessibilityCustomAction?
        func visit(_ element: Any, depth: Int) {
            guard depth < 40, found == nil else { return }
            if let o = element as? NSObject {
                if (o.accessibilityLabel ?? "").contains(label) {
                    found = o.accessibilityCustomActions?.first { $0.name == action }
                }
                for e in o.accessibilityElements ?? [] { visit(e, depth: depth + 1) }
                let n = o.accessibilityElementCount()
                if n != NSNotFound, n > 0 {
                    for i in 0..<min(n, 500) { if let e = o.accessibilityElement(at: i) { visit(e, depth: depth + 1) } }
                }
            }
            if let v = element as? UIView { for s in v.subviews { visit(s, depth: depth + 1) } }
        }
        env.view.layoutIfNeeded()
        visit(env.view, depth: 0)
        return found
    }

    /// Im ganzen Dokument: Abpausen blendet Leisten und Seitenanzeige aus, die PDF nimmt keine Beruehrung an, nur das
    /// Schloss bleibt; "Entsperren" bringt alles zurueck
    func testDocumentTraceHidesChromeAndUnlocks() throws {
        let env = try hostedDocument(freeze: "trace")
        XCTAssertTrue(env.wait(timeout: 15) { env.labels().contains(FreezeTexts.lockLabel) }, env.labels().joined(separator: "\n"))
        let labels = env.labels()
        XCTAssertFalse(labels.contains("Mehr"), "keine Leiste")
        XCTAssertFalse(labels.contains("Seiten"))
        XCTAssertFalse(labels.contains { $0.hasPrefix("Seite 1 / ") }, "keine Seitenanzeige")
        let pdf = try XCTUnwrap(pdfViews(in: env.view).first)
        XCTAssertFalse(pdf.isUserInteractionEnabled, "keine Eingabe in der PDF")
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled, "Bildschirm bleibt an")

        let unlock = try XCTUnwrap(customAction(env, label: FreezeTexts.lockLabel, action: FreezeTexts.unlockAction))
        _ = unlock.actionHandler?(unlock)
        XCTAssertTrue(env.wait { env.labels().contains("Mehr") }, "Leisten zurueck\n" + env.labels().joined(separator: "\n"))
        XCTAssertFalse(env.labels().contains(FreezeTexts.lockLabel))
        XCTAssertTrue(pdf.isUserInteractionEnabled)
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled, "Ruhezustand wie vorher")
    }

    /// Im ganzen Dokument: "Ansicht fixiert" mit "Lösen", Leisten bleiben, die PDF nimmt Eingaben an (Stift)
    func testDocumentViewLockShowsBadge() throws {
        let env = try hostedDocument(freeze: "view")
        XCTAssertTrue(env.wait(timeout: 15) { env.labels().contains { $0.contains(FreezeTexts.badge) } }, env.labels().joined(separator: "\n"))
        XCTAssertTrue(env.labels().contains("Mehr"), "Leisten bleiben")
        let pdf = try XCTUnwrap(pdfViews(in: env.view).first)
        XCTAssertTrue(pdf.isUserInteractionEnabled)
        let release = try XCTUnwrap(customAction(env, label: FreezeTexts.badge, action: FreezeTexts.release))
        _ = release.actionHandler?(release)
        XCTAssertTrue(env.wait { !env.labels().contains { $0.contains(FreezeTexts.badge) } })
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled, "Ansicht fixieren laesst den Ruhezustand in Ruhe")
    }
}
