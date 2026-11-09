import PDFKit
import PencilKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Bedienung mit Maus, Trackpad und Tastatur (Mac "Designed for iPad", iPad mit Tastatur), Befund des Inhabers am Mac
/// 09.11.2026: "es gibt kein Dokument links rechts wischen". Auf dem iPad blaettert der Finger, der Stift schreibt; am
/// Mac schrieb jede Mausbewegung, Ziehen verschob das Dokument nie, Tasten taten im Editor nichts.
/// docs/paritaet/MAC-BEDIENUNG-2026-11-09.md. Laeuft auf dem iPad-Simulator und auf dem Mac; die Logik ist fuer beide
/// Geraete geprueft, die Einstellung des Editors fuer das Geraet, auf dem der Test laeuft. Echte Maus- und
/// Trackpad-Ereignisse schickt der Test nicht.
@MainActor
final class MacBedienungTests: XCTestCase {

    // MARK: A) Wer schreibt, wer blaettert

    /// iPad unveraendert: Standard "Nur Stift" (ein Finger blaettert), "Finger zeichnet" (zwei Finger blaettern)
    func testIPadInputIsUnchanged() {
        XCTAssertEqual(EditorPointer.config(isMac: false, pencilOnly: true),
                       .init(drawingPolicy: .pencilOnly, panTouchTypes: [.direct], panMinimumTouches: 1))
        XCTAssertEqual(EditorPointer.config(isMac: false, pencilOnly: false),
                       .init(drawingPolicy: .anyInput, panTouchTypes: [.direct], panMinimumTouches: 2))
        XCTAssertEqual(EditorPointer.toggleLabel(isMac: false, pencilOnly: true).title, "Nur Stift")
        XCTAssertEqual(EditorPointer.toggleLabel(isMac: false, pencilOnly: false).title, "Finger zeichnet")
    }

    /// Mac: derselbe Schalter. Standard "Maus blättert" (Ziehen verschiebt das Dokument in alle Richtungen, die Maus
    /// schreibt nicht), "Maus schreibt" (Ziehen schreibt mit dem Werkzeug der Palette). Trackpad und Mausrad blaettern
    /// in beiden Faellen (eigene Ereignisse, keine Beruehrungen).
    func testMacMouseNavigatesByDefaultAndWritesOnlyWhenChosen() {
        let navigate = EditorPointer.config(isMac: true, pencilOnly: true)
        XCTAssertEqual(navigate.drawingPolicy, .pencilOnly, "Maus blaettert: Ziehen schreibt nicht")
        XCTAssertEqual(navigate.panMinimumTouches, 1, "Ziehen mit der Maus verschiebt das Dokument")
        XCTAssertTrue(navigate.panTouchTypes.contains(.direct), "Mausklick in iPad-Apps am Mac")
        XCTAssertTrue(navigate.panTouchTypes.contains(.indirectPointer), "Zeiger als indirekte Beruehrung")
        XCTAssertFalse(navigate.panTouchTypes.contains(.pencil))

        let write = EditorPointer.config(isMac: true, pencilOnly: false)
        XCTAssertEqual(write.drawingPolicy, .anyInput, "Maus schreibt")
        XCTAssertEqual(write.panMinimumTouches, 2, "Ziehen mit der Maus verschiebt dann nichts")

        XCTAssertEqual(EditorPointer.toggleLabel(isMac: true, pencilOnly: true).title, "Maus blättert")
        XCTAssertEqual(EditorPointer.toggleLabel(isMac: true, pencilOnly: false).title, "Maus schreibt")
    }

    /// Der Editor stellt Zeichenflaeche und Rollflaeche so ein, wie es fuer dieses Geraet vorgesehen ist; Mausrad und
    /// Trackpad bleiben an (`allowedScrollTypesMask`)
    func testEditorAppliesTheInputOfThisDevice() async throws {
        let shown = try await show(pages: 3)
        let editor = shown.editor
        let scroll = try XCTUnwrap(editor.firstScrollView(in: editor.pdfView))
        let overlay = try XCTUnwrap(editor.overlayForTesting(at: 0))
        XCTAssertTrue(editor.pencilOnly, "Standard auf beiden Geraeten")
        for pencilOnly in [false, true] {
            editor.pencilOnly = pencilOnly
            let c = EditorPointer.config(isMac: PDFEditorController.isMac, pencilOnly: pencilOnly)
            let types = c.panTouchTypes.map { NSNumber(value: $0.rawValue) }
            XCTAssertEqual(overlay.canvas.drawingPolicy, c.drawingPolicy, "pencilOnly \(pencilOnly)")
            XCTAssertEqual(scroll.panGestureRecognizer.allowedTouchTypes, types, "pencilOnly \(pencilOnly)")
            XCTAssertEqual(scroll.panGestureRecognizer.minimumNumberOfTouches, c.panMinimumTouches, "pencilOnly \(pencilOnly)")
            XCTAssertEqual(scroll.pinchGestureRecognizer?.allowedTouchTypes, types, "pencilOnly \(pencilOnly)")
            XCTAssertEqual(scroll.panGestureRecognizer.allowedScrollTypesMask, .all, "Mausrad und Trackpad")
            XCTAssertEqual(editor.effectivePencilOnly, pencilOnly)
        }
    }

    // MARK: B) Tastatur im Editor

    private typealias Nav = EditorNavigation
    private let fit = Nav.Viewport(offset: CGPoint(x: 0, y: 1000), contentSize: CGSize(width: 800, height: 5000),
                                   boundsSize: CGSize(width: 800, height: 600))

    private func step(_ c: Nav.Command, _ v: Nav.Viewport, page: Int = 2, count: Int = 5, scale: CGFloat = 1) -> Nav.Step? {
        Nav.step(c, viewport: v, page: page, pageCount: count, scale: scale, scaleRange: 0.5...6)
    }

    /// Pfeil links/rechts: Seite zurueck/weiter; gezoomt erst waagerecht bis zum Rand (wie Vorschau am Mac)
    func testLeftRightTurnPagesAndScrollSidewaysWhenZoomed() {
        XCTAssertEqual(step(.right, fit), .page(3))
        XCTAssertEqual(step(.left, fit), .page(1))
        XCTAssertNil(step(.left, fit, page: 0), "erste Seite")
        XCTAssertNil(step(.right, fit, page: 4), "letzte Seite")

        var zoomed = Nav.Viewport(offset: CGPoint(x: 100, y: 1000), contentSize: CGSize(width: 1600, height: 9000),
                                  boundsSize: CGSize(width: 800, height: 600))
        XCTAssertEqual(step(.right, zoomed), .scroll(CGPoint(x: 100 + Nav.sideStep, y: 1000)))
        XCTAssertEqual(step(.left, zoomed), .scroll(CGPoint(x: 0, y: 1000)), "nicht ueber den Rand")
        zoomed.offset.x = 800
        XCTAssertEqual(step(.right, zoomed), .page(3), "rechter Rand: naechste Seite")
        XCTAssertEqual(step(.left, zoomed), .scroll(CGPoint(x: 800 - Nav.sideStep, y: 1000)))
        zoomed.offset.x = 0
        XCTAssertEqual(step(.left, zoomed), .page(1), "linker Rand: vorige Seite")
    }

    /// Pfeil hoch/runter eine Zeile, Leertaste und Bild ab fast eine Bildschirmhoehe, Pos1/Ende und Cmd-Pfeil zur
    /// ersten/letzten Seite; am Rand nichts
    func testUpDownSpaceAndPageKeysScroll() {
        XCTAssertEqual(step(.lineDown, fit), .scroll(CGPoint(x: 0, y: 1000 + Nav.line)))
        XCTAssertEqual(step(.lineUp, fit), .scroll(CGPoint(x: 0, y: 1000 - Nav.line)))
        XCTAssertEqual(step(.screenDown, fit), .scroll(CGPoint(x: 0, y: 1000 + 600 * Nav.screenFraction)))
        XCTAssertEqual(step(.screenUp, fit), .scroll(CGPoint(x: 0, y: 1000 - 600 * Nav.screenFraction)))
        var top = fit
        top.offset.y = 0
        XCTAssertNil(step(.lineUp, top))
        XCTAssertNil(step(.screenUp, top))
        var bottom = fit
        bottom.offset.y = 4400
        XCTAssertNil(step(.lineDown, bottom))
        bottom.offset.y = 4300
        XCTAssertEqual(step(.screenDown, bottom), .scroll(CGPoint(x: 0, y: 4400)), "bis zum Ende, nicht darueber")
        var inset = fit
        inset.inset = UIEdgeInsets(top: 50, left: 0, bottom: 20, right: 0)
        inset.offset.y = 0
        XCTAssertEqual(step(.screenUp, inset), .scroll(CGPoint(x: 0, y: -50)), "Rand unter der Leiste")
        XCTAssertEqual(step(.first, fit), .page(0))
        XCTAssertEqual(step(.last, fit), .page(4))
        XCTAssertNil(step(.right, fit, page: 0, count: 0), "kein Dokument")
    }

    /// Cmd +/- in Stufen innerhalb der Grenzen des Editors, Cmd 0 auf Seitenbreite
    func testZoomKeys() {
        XCTAssertEqual(step(.zoomIn, fit, scale: 1), .zoom(Nav.zoomFactor))
        XCTAssertEqual(step(.zoomOut, fit, scale: 1), .zoom(1 / Nav.zoomFactor))
        XCTAssertEqual(step(.zoomIn, fit, scale: 5.9), .zoom(6), "Obergrenze")
        XCTAssertNil(step(.zoomIn, fit, scale: 6))
        XCTAssertEqual(step(.zoomOut, fit, scale: 0.55), .zoom(0.5), "Untergrenze")
        XCTAssertNil(step(.zoomOut, fit, scale: 0.5))
        XCTAssertEqual(step(.zoomFit, fit), .fit)
    }

    /// Im echten Editor: Tasten sind angemeldet, wechseln Seiten, rollen, zoomen; fixiert, waehrend getippt wird oder
    /// mit einem Blatt darueber nicht
    func testKeysDriveTheEditor() async throws {
        let shown = try await show(pages: 5)
        let editor = shown.editor
        let inputs = Set((editor.keyCommands ?? []).map { "\($0.input ?? "")|\($0.modifierFlags.rawValue)" })
        for (input, mods) in [(UIKeyCommand.inputRightArrow, UIKeyModifierFlags()), (UIKeyCommand.inputLeftArrow, []),
                              (UIKeyCommand.inputPageDown, []), (" ", []), (" ", .shift), ("+", .command), ("-", .command),
                              ("0", .command), (UIKeyCommand.inputUpArrow, .command)] {
            XCTAssertTrue(inputs.contains("\(input)|\(mods.rawValue)"), "Taste \(input) \(mods.rawValue)")
        }
        XCTAssertTrue(editor.acceptsEditorKeys)
        XCTAssertEqual(editor.currentPageIndex, 0)

        XCTAssertTrue(editor.perform(.right, animated: false))
        await pump(0.3)
        XCTAssertEqual(editor.currentPageIndex, 1, "Pfeil rechts: naechste Seite")
        XCTAssertTrue(editor.perform(.last, animated: false))
        await pump(0.3)
        XCTAssertEqual(editor.currentPageIndex, 4, "Ende: letzte Seite")
        XCTAssertTrue(editor.perform(.first, animated: false))
        await pump(0.3)
        XCTAssertEqual(editor.currentPageIndex, 0)

        let scroll = try XCTUnwrap(editor.firstScrollView(in: editor.pdfView))
        let y = scroll.contentOffset.y
        XCTAssertTrue(editor.perform(.screenDown, animated: false))
        XCTAssertGreaterThan(scroll.contentOffset.y, y + 100, "Leertaste rollt")

        let fitScale = editor.pdfView.scaleFactor
        XCTAssertTrue(editor.perform(.zoomIn, animated: false))
        await pump(0.2)
        XCTAssertGreaterThan(editor.pdfView.scaleFactor, fitScale * 1.1, "Cmd +")
        XCTAssertTrue(editor.perform(.zoomFit, animated: false))
        await pump(0.2)
        XCTAssertEqual(editor.pdfView.scaleFactor, fitScale, accuracy: 0.001, "Cmd 0")

        editor.freezeMode = .view
        XCTAssertFalse(editor.acceptsEditorKeys, "fixiert")
        XCTAssertFalse(editor.perform(.right, animated: false))
        editor.freezeMode = .off
        XCTAssertTrue(editor.acceptsEditorKeys)

        // Tippen in ein Feld (z. B. KI-Hilfe): Pfeile und Leertaste gehoeren dem Feld
        let field = UITextField(frame: CGRect(x: 10, y: 10, width: 200, height: 30))
        shown.window.addSubview(field)
        defer { field.removeFromSuperview() }
        if field.becomeFirstResponder() {
            XCTAssertFalse(editor.acceptsEditorKeys, "Feld hat den Fokus")
            XCTAssertFalse(editor.canPerformAction(#selector(PDFEditorController.editorKey(_:)), withSender: nil))
            field.resignFirstResponder()
        }
    }

    // MARK: C) Reiter der geoeffneten Dokumente

    func testDocumentTabsCycleWithTheKeyboard() {
        let tabs = ["a", "b", "c"]
        XCTAssertEqual(DocumentTabs.neighbor(of: "b", in: tabs, step: 1), "c")
        XCTAssertEqual(DocumentTabs.neighbor(of: "b", in: tabs, step: -1), "a")
        XCTAssertEqual(DocumentTabs.neighbor(of: "c", in: tabs, step: 1), "a", "nach dem letzten wieder vorn")
        XCTAssertEqual(DocumentTabs.neighbor(of: "a", in: tabs, step: -1), "c")
        XCTAssertEqual(DocumentTabs.neighbor(of: nil, in: tabs, step: 1), "a")
        XCTAssertNil(DocumentTabs.neighbor(of: "a", in: ["a"], step: 1), "ein Reiter: nichts zu wechseln")
        XCTAssertNil(DocumentTabs.neighbor(of: nil, in: [], step: 1))
    }

    // MARK: Aufbau

    private struct Shown {
        let editor: PDFEditorController
        let window: UIWindow
    }

    private func pump(_ seconds: Double = 0.4) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    private func show(pages: Int) async throws -> Shown {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mac-bedienung-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let host = LocalBackendHost(directory: root.appendingPathComponent("db", isDirectory: true),
                                    clock: .fixed(berlin: "2026-11-09T10:00:00")!)
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
        let fileID = "mac-bedienung-" + UUID().uuidString.prefix(8).lowercased()
        let pdfURL = AppPaths.pdf(fileID, namespace: api.namespace, root: root)
        try FileManager.default.createDirectory(at: pdfURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let raw = NSMutableData()
        let size = CGSize(width: 595, height: 842)
        UIGraphicsBeginPDFContextToData(raw, CGRect(origin: .zero, size: size), nil)
        for i in 1...pages {
            UIGraphicsBeginPDFPageWithInfo(CGRect(origin: .zero, size: size), nil)
            "Übungsblatt Seite \(i)".draw(at: CGPoint(x: 60, y: 60), withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
        }
        UIGraphicsEndPDFContext()
        try (raw as Data).write(to: pdfURL)
        let file = LibFile(id: fileID, name: "Blatt.pdf", title: "Blatt", kind: "pdf", module_id: nil, subject: "Mathe",
                           doc_type: nil, ai_title: nil, sub_label: nil, downloaded_at: "2026-11-09", has_notes: nil,
                           page_count: pages, studip_folder: nil)
        let store = DocumentStore(file: file, api: api, root: root)
        await store.load()
        XCTAssertNil(store.errorMessage, store.errorMessage ?? "")
        addTeardownBlock { await store.close() }

        let editor = PDFEditorController(store: store)
        editor.ownNotesVisible = true
        editor.canEdit = true
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        window.rootViewController = editor
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in
            editor.showToolPicker(false)
            window.isHidden = true
            window.rootViewController = nil
        }
        await pump(0.6)
        return Shown(editor: editor, window: window)
    }
}
