import PDFKit
import PencilKit
import SwiftUI
import UniFlowCore
import XCTest
@testable import UniFlow

/// Feste Werkzeugleiste oben im Dokument (Auftrag des Inhabers 11.11.2026: "Mach das Apple-Pencil-Kit oben fest, das darf
/// nicht schwebend sein"). Apples `PKToolPicker` laesst sich nicht andocken (SDK iPhoneOS 27.2: keine Lage, kein
/// Andocken, `frameObscuredInView:` liefert `CGRectNull`, "wenn die Palette beweglich ist"); der Editor zeigt sie nicht
/// mehr und fuehrt die Werkzeuge selbst (`EditorToolState`, `EditorToolbar`).
///
/// Geprueft: Leiste oben, volle Breite, fest (keine Palette von PencilKit, Lage bleibt bei Werkzeugwechsel, Drehen und
/// geteilter Ansicht); Werkzeugwahl setzt das Werkzeug aller Seiten; Farbe, Staerke, Radierer, Lineal; Objektmodus; Sperre
/// ohne Plus; Praesentation und Abpausen blenden aus; Korrektur nur Tinte; Apple Pencil (Doppeltippen/Druecken nach der
/// Einstellung des Nutzers); gemerkte Wahl je Geraet. Bildschirmfotos (iPad quer und hoch) mit
/// `TEST_RUNNER_UF_TOOLBAR_SHOTS=<Ordner>`.
@MainActor
final class EditorToolbarTests: XCTestCase {

    // MARK: Aufbau

    private func pdf(pages: Int) -> Data {
        let raw = NSMutableData()
        let size = CGSize(width: 595, height: 842)
        UIGraphicsBeginPDFContextToData(raw, CGRect(origin: .zero, size: size), nil)
        for i in 1...pages {
            UIGraphicsBeginPDFPageWithInfo(CGRect(origin: .zero, size: size), nil)
            "Übungsblatt 3, Aufgabe \(i)".draw(at: CGPoint(x: 72, y: 90), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 22)])
            "Zeigen Sie, dass für alle n ≥ 1 gilt: 1 + 2 + … + n = n(n+1)/2.".draw(
                at: CGPoint(x: 72, y: 140), withAttributes: [.font: UIFont.systemFont(ofSize: 15)])
        }
        UIGraphicsEndPDFContext()
        return raw as Data
    }

    private func defaults() -> UserDefaults {
        let suite = "toolbar-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        addTeardownBlock { d.removePersistentDomain(forName: suite) }
        return d
    }

    private func tools(_ d: UserDefaults? = nil) -> EditorToolState { EditorToolState(defaults: d ?? defaults()) }

    private func openStore(pages: Int = 3) async throws -> DocumentStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-toolbar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let host = LocalBackendHost(directory: root.appendingPathComponent("db", isDirectory: true), clock: .fixed(berlin: "2026-11-11T09:00:00")!)
        let backend = try await host.backend()
        let fileID = "toolbar-" + UUID().uuidString.prefix(8).lowercased()
        try await backend.context.database.transaction { c in
            try c.execute("INSERT OR IGNORE INTO courses(id, title, semester, subject, kind, created_at) VALUES (?,?,?,?,?,?)",
                          [.text("k-test"), .text("Testkurs"), .text("WiSe 2026/27"), .text("Testkurs"), .text("vorlesung"),
                           .text("2026-10-01T08:00:00")])
            try c.execute("INSERT INTO files(id, course_id, name, chdate, status, kind, downloaded_at) VALUES (?,?,?,?, 'neu', 'pdf', ?)",
                          [.text(fileID), .text("k-test"), .text("Blatt.pdf"), .integer(1_792_000_000), .text("2026-11-11T08:00:00")])
        }
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
        let pdfURL = AppPaths.pdf(fileID, namespace: api.namespace, root: root)
        try FileManager.default.createDirectory(at: pdfURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pdf(pages: pages).write(to: pdfURL)
        try DocumentStore.stamp(try await api.value("/api/files/\(fileID)")).write(to: pdfURL.appendingPathExtension("stand"), atomically: true, encoding: .utf8)
        let file = LibFile(id: fileID, name: "Blatt.pdf", title: "Blatt", kind: "pdf", module_id: nil, subject: "Testkurs",
                           doc_type: nil, ai_title: nil, sub_label: nil, downloaded_at: "2026-11-11T08:00:00", has_notes: nil,
                           page_count: pages, studip_folder: nil)
        let store = DocumentStore(file: file, api: api, root: root)
        await store.load()
        XCTAssertNil(store.errorMessage, store.errorMessage ?? "")
        addTeardownBlock { await store.close() }
        return store
    }

    private func editor(_ t: EditorToolState, pages: Int = 3) async throws -> PDFEditorController {
        let store = try await openStore(pages: pages)
        let e = PDFEditorController(store: store, tools: t)
        e.loadViewIfNeeded()
        return e
    }

    private func resetObjectChoices() {
        let keys = [EditorPalette.shapeKey, EditorPalette.selectKey, "uniflow.palette.syncedColors"]
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        addTeardownBlock { keys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }
    }

    // MARK: Werkzeuge der Zeichenflaeche

    /// Stift, Fineliner, Textmarker, Radierer (Pixel/Objekt), Lasso: das Werkzeug aller Seiten folgt der Leiste, auch
    /// das neu aufgebauter Seiten; das Lineal gilt auf allen Seiten
    func testChoosingAToolSetsTheToolOfEveryPage() async throws {
        let t = tools()
        let e = try await editor(t)
        let pages = try (0..<3).map { try XCTUnwrap(e.overlayForTesting(at: $0)) }
        func all(_ check: (PKTool) -> Bool) -> Bool { pages.allSatisfy { check($0.canvas.tool) } }

        XCTAssertTrue(all { ($0 as? PKInkingTool)?.inkType == .pen }, "Standard: Stift")
        t.select(.fineliner)
        XCTAssertTrue(all { ($0 as? PKInkingTool)?.inkType == .monoline }, "Fineliner auf allen Seiten")
        t.select(.marker)
        XCTAssertTrue(all { ($0 as? PKInkingTool)?.inkType == .marker })
        t.setEraser(.pixel)
        XCTAssertEqual(t.tool, .eraser)
        XCTAssertTrue(all { ($0 as? PKEraserTool)?.eraserType == .bitmap }, "Pixel-Radierer")
        t.setEraser(.object)
        XCTAssertTrue(all { ($0 as? PKEraserTool)?.eraserType == .vector }, "Objekt-Radierer (ganze Striche)")
        t.select(.lasso)
        XCTAssertTrue(all { $0 is PKLassoTool })
        XCTAssertEqual(e.chosenTool, .lasso)

        t.toggleRuler()
        XCTAssertTrue(pages.allSatisfy(\.canvas.isRulerActive), "Lineal auf allen Seiten")
        t.select(.pen)
        XCTAssertTrue(pages.allSatisfy(\.canvas.isRulerActive), "Lineal bleibt beim Werkzeugwechsel")
        t.toggleRuler()
        XCTAssertFalse(pages.contains(where: \.canvas.isRulerActive))

        // neu aufgebaute Seiten (Neuaufbau nach Seite einfuegen) bekommen dasselbe Werkzeug
        t.select(.marker)
        let inserted = await e.insertBlankPage(after: e.currentPageKey)
        XCTAssertNotNil(inserted)
        try await waitFor("Neuaufbau") { e.shownLayoutVersion == e.store.layoutVersion }
        let fresh = try XCTUnwrap(e.overlayForTesting(at: 1))
        XCTAssertEqual((fresh.canvas.tool as? PKInkingTool)?.inkType, .marker)
    }

    /// Farbe und Staerke wie in Apples Palette: einige Farben, Farbwaehler, 3 bis 5 Staerken; sie kommen auf der
    /// Zeichenflaeche an (Staerke in den Grenzen von PencilKit), jedes Werkzeug behaelt seine eigenen
    func testColorAndWidthReachTheCanvas() async throws {
        let t = tools()
        let e = try await editor(t, pages: 1)
        let canvas = try XCTUnwrap(e.overlayForTesting(at: 0)).canvas
        t.setColor("#e5322d")
        t.setWidth(6)
        var pen = try XCTUnwrap(canvas.tool as? PKInkingTool)
        XCTAssertTrue(PaletteSync.sameColor(pen.color.uniflowRGBA.hex, "#e5322d"), "Farbe kommt an")
        XCTAssertEqual(pen.width, 6, accuracy: 0.01, "Staerke kommt an")
        XCTAssertTrue(PaletteSync.sameColor(e.paletteSync.inkHex, "#e5322d"), "Objekte nehmen die Stiftfarbe")

        t.select(.marker)
        t.setColor(EditorToolState.markerColors[2].hex)
        let marker = try XCTUnwrap(canvas.tool as? PKInkingTool)
        XCTAssertTrue(PaletteSync.sameColor(marker.color.uniflowRGBA.hex, EditorToolState.markerColors[2].hex))
        XCTAssertTrue(PaletteSync.sameColor(e.paletteSync.markerHex, EditorToolState.markerColors[2].hex), "Text markieren")
        t.select(.pen)
        pen = try XCTUnwrap(canvas.tool as? PKInkingTool)
        XCTAssertTrue(PaletteSync.sameColor(pen.color.uniflowRGBA.hex, "#e5322d"), "Stift behaelt seine Farbe")
        XCTAssertEqual(pen.width, 6, accuracy: 0.01)

        // Farbwaehler: jede Farbe; Staerke ausserhalb von PencilKit wird begrenzt
        t.setColor("#123456")
        XCTAssertTrue(PaletteSync.sameColor(((canvas.tool as? PKInkingTool)?.color.uniflowRGBA.hex) ?? "", "#123456"))
        t.setWidth(500)
        XCTAssertLessThanOrEqual((canvas.tool as? PKInkingTool)?.width ?? 999, PKInkingTool.InkType.pen.validWidthRange.upperBound)
        // Radierer und Lasso haben keine Farbe: die Leiste zeigt dort die des letzten Stifts
        t.select(.eraser)
        XCTAssertEqual(t.styledTool, .pen)
    }

    /// Je Geraet gemerkt: Werkzeug, Farben, Staerken, Radierer. Ein Objektwerkzeug wird nie gemerkt (beim Oeffnen
    /// steht die Leiste auf dem letzten Stift), das Lineal ebenso nicht
    func testChoiceIsRememberedPerDevice() {
        let d = defaults()
        let a = tools(d)
        a.select(.fineliner)
        a.setColor("#2e9e5b")
        a.setWidth(4)
        a.setEraser(.pixel)
        a.select(.fineliner)
        a.toggleRuler()
        let b = tools(d)
        XCTAssertEqual(b.tool, .fineliner)
        XCTAssertEqual(b.style(.fineliner), .init(hex: "#2e9e5b", width: 4))
        XCTAssertEqual(b.eraserKind, .pixel)
        XCTAssertFalse(b.ruler)
        a.select(.text)
        XCTAssertEqual(tools(d).tool, .fineliner, "Objektwerkzeug nicht gemerkt")
        XCTAssertEqual(tools(defaults()).tool, .pen, "neues Geraet: Stift")
    }

    // MARK: Objektwerkzeuge

    /// Objektwerkzeuge in der Leiste: Objektmodus mit dem Werkzeug, Stift beendet ihn; Form- und Auswahlart aus der
    /// Leiste; ⌘1–⌘8 gehen ueber dieselbe Leiste
    func testObjectToolsAndShortcutsGoThroughTheToolbar() async throws {
        resetObjectChoices()
        let t = tools()
        let e = try await editor(t, pages: 1)
        let canvas = try XCTUnwrap(e.overlayForTesting(at: 0)).canvas
        t.select(.text)
        XCTAssertTrue(e.objects.isActive)
        XCTAssertEqual(e.objects.tool, .text)
        XCTAssertFalse(canvas.isUserInteractionEnabled)
        t.setShape(.arrow)
        XCTAssertEqual(e.objects.tool, .arrow)
        t.setSelectMode(.lasso)
        XCTAssertEqual(e.objects.tool, .lasso)
        t.select(.markup)
        XCTAssertEqual(e.objects.tool, .markup)
        t.select(.pen)
        XCTAssertFalse(e.objects.isActive)
        XCTAssertTrue(canvas.isUserInteractionEnabled)

        e.choose(.sticky)                                                  // ⌘6
        XCTAssertEqual(t.tool, .sticky, "die Leiste zeigt die Wahl aus der Tastatur")
        XCTAssertEqual(e.objects.tool, .sticky)
        e.choose(.eraser)                                                  // ⌘3
        XCTAssertEqual(t.tool, .eraser)
        XCTAssertFalse(e.objects.isActive)
        XCTAssertTrue(canvas.tool is PKEraserTool)
    }

    // MARK: Sichtbarkeit

    /// Leiste wie frueher die Palette: nur mit Schreiben (Plus), nicht in der Praesentation, nicht beim Abpausen; im
    /// Korrektur-Modus nur Tinte. Der Editor meldet jede Aenderung an die Dokumentansicht.
    func testToolbarFollowsPlusPresentationAndTracing() async throws {
        let t = tools()
        let store = try await openStore(pages: 1)
        let e = PDFEditorController(store: store, tools: t)
        var reported: [EditorToolbarMode] = []
        e.onToolbarChange = { reported.append($0) }
        e.loadViewIfNeeded()
        XCTAssertEqual(reported.last, EditorToolbarMode(visible: true, inkOnly: false), "Plus: Leiste da")

        e.canEdit = UFFeatureMatrix.notes(plan: .free).canEdit           // ohne Plus
        XCTAssertEqual(reported.last?.visible, false, "ohne Plus keine Leiste")
        XCTAssertFalse(e.toolbarMode.visible)
        // Doppeltippen ohne Leiste: nichts
        e.pencilGesture(.switchEraser)
        XCTAssertEqual(t.tool, .pen)
        e.choose(.marker)
        XCTAssertEqual(t.tool, .pen, "ohne Plus waehlen auch ⌘-Tasten nichts")
        e.canEdit = true
        XCTAssertEqual(reported.last?.visible, true)

        e.presentationMode = true
        XCTAssertEqual(reported.last?.visible, false, "Praesentieren blendet die Leiste aus")
        e.presentationMode = false
        XCTAssertEqual(reported.last?.visible, true)

        e.freezeMode = .trace
        XCTAssertEqual(reported.last?.visible, false, "Abpausen blendet die Leiste aus")
        e.freezeMode = .off
        XCTAssertEqual(reported.last?.visible, true)

        e.ownNotesVisible = false
        XCTAssertEqual(reported.last?.visible, false, "nur ansehen: keine Leiste")
        e.ownNotesVisible = true

        // geteilte Ansicht: nur der Editor, der die Leiste fuehrt, meldet sie
        let side = PDFEditorController(store: try await openStore(pages: 1), tools: t, ownsToolPicker: false)
        var sideReports = 0
        side.onToolbarChange = { _ in sideReports += 1 }
        side.loadViewIfNeeded()
        side.canEdit = false
        XCTAssertEqual(sideReports, 0)
        XCTAssertFalse(side.toolbarMode.visible)
    }

    /// Im Korrektur-Modus zeigt die Leiste nur Tinte (keine Objektwerkzeuge); die Leiste selbst laesst sie dann weg
    func testInkOnlyToolbarHidesObjectTools() throws {
        XCTAssertTrue(HostedEnvironment.accessibilityAutomation(true))
        defer { HostedEnvironment.accessibilityAutomation(false) }
        let t = tools()
        func identifiers(_ mode: EditorToolbarMode, ai: Bool = false) -> Set<String> {
            let host = UIHostingController(rootView: EditorToolbar(tools: t, mode: mode, undo: {}, redo: {}, askAI: ai ? {} : nil)
                .frame(width: 1180))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1180, height: 200))
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil }
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            host.view.layoutIfNeeded()
            return Self.identifiers(in: host.view)
        }
        let full = identifiers(.init(visible: true, inkOnly: false), ai: true)
        for tool in EditorToolState.Tool.allCases {
            XCTAssertTrue(full.contains("toolbar.tool.\(tool.rawValue)"), "\(tool.rawValue) fehlt: \(full.sorted())")
        }
        for id in ["toolbar.ruler", "toolbar.attributes", "toolbar.undo", "toolbar.redo", "toolbar.askAI"] {
            XCTAssertTrue(full.contains(id), id)
        }
        let ink = identifiers(.init(visible: true, inkOnly: true))
        XCTAssertTrue(ink.contains("toolbar.tool.pen") && ink.contains("toolbar.tool.eraser") && ink.contains("toolbar.ruler"))
        XCTAssertFalse(ink.contains("toolbar.tool.text"), "Korrektur: keine Objektwerkzeuge")
        XCTAssertFalse(ink.contains("toolbar.askAI"), "ohne KI kein 'KI fragen'")
    }

    // MARK: Apple Pencil

    /// Doppeltippen (Pencil 2, Pro) und Druecken (Pro) nach der Einstellung des Nutzers: Radierer hin und zurueck,
    /// vorheriges Werkzeug, Farbe und Staerke zeigen; im Korrektur-Modus nie zurueck auf ein Objektwerkzeug
    func testPencilDoubleTapAndSqueezeFollowTheUserSetting() async throws {
        XCTAssertEqual(EditorToolState.pencilAction(.switchEraser), .toggleEraser)
        XCTAssertEqual(EditorToolState.pencilAction(.switchPrevious), .togglePrevious)
        XCTAssertEqual(EditorToolState.pencilAction(.showColorPalette), .showAttributes)
        XCTAssertEqual(EditorToolState.pencilAction(.showInkAttributes), .showAttributes)
        XCTAssertEqual(EditorToolState.pencilAction(.ignore), .none)
        if #available(iOS 17.5, *) {
            XCTAssertEqual(EditorToolState.pencilAction(.showContextualPalette), .showAttributes)
            XCTAssertEqual(EditorToolState.pencilAction(.runSystemShortcut), .none, "Kurzbefehl des Systems: nicht unseres")
        }

        let t = tools()
        let e = try await editor(t, pages: 1)
        t.select(.marker)
        e.pencilGesture(.switchEraser)
        XCTAssertEqual(t.tool, .eraser)
        XCTAssertTrue(try XCTUnwrap(e.overlayForTesting(at: 0)).canvas.tool is PKEraserTool)
        e.pencilGesture(.switchEraser)
        XCTAssertEqual(t.tool, .marker, "zurueck zum Werkzeug davor")

        t.select(.fineliner)
        e.pencilGesture(.switchPrevious)
        XCTAssertEqual(t.tool, .marker)
        e.pencilGesture(.switchPrevious)
        XCTAssertEqual(t.tool, .fineliner)

        let before = t.attributesRequest
        e.pencilGesture(.showColorPalette)
        XCTAssertEqual(t.attributesRequest, before + 1, "Farbe und Staerke oeffnen")
        e.pencilGesture(.ignore)
        XCTAssertEqual(t.tool, .fineliner)

        // Objektwerkzeug, dann Radierer: zurueck geht es zum Objektwerkzeug, im Korrektur-Modus zum letzten Stift
        t.select(.text)
        t.perform(.toggleEraser)
        t.perform(.toggleEraser)
        XCTAssertEqual(t.tool, .text)
        t.perform(.toggleEraser)
        t.perform(.toggleEraser, inkOnly: true)
        XCTAssertEqual(t.tool, .fineliner, "Korrektur: kein Objektwerkzeug")
    }

    // MARK: Fest oben im Dokument

    /// Ganzes Dokument (DocumentView): die Leiste steht in der einen Kopfzeile ganz oben ueber der PDF; keine
    /// schwebende Palette von PencilKit; Lage bleibt bei Werkzeugwechsel, Objektmodus und Drehen. Bildschirmfotos quer
    /// und hoch mit `TEST_RUNNER_UF_TOOLBAR_SHOTS=<Ordner>`.
    func testToolbarIsFixedAtTheTopOfTheDocument() throws {
        XCTAssertTrue(HostedEnvironment.accessibilityAutomation(true))
        addTeardownBlock { @MainActor in HostedEnvironment.accessibilityAutomation(false) }
        Entitlements.shared.setPlanForTesting(.plus)
        addTeardownBlock { @MainActor in Entitlements.shared.setPlanForTesting(.free) }
        let t = AIViewsAppTests.Transport()
        let id = "f-leiste-\(UUID().uuidString.prefix(8))"
        t.answer("/api/files/\(id)/content", data: pdf(pages: 3), type: "application/pdf")
        t.answer("/api/files/\(id)/annotations", ["data": AnnotationDocument.emptyRoot, "version": 0, "updated_at": .null])
        t.answer("/api/related", ["results": []])                       // Skriptsuche: kein Vorschlag (kein Hinweis im Bild)
        let meta: JSONValue = ["id": .string(id), "name": "Übungsblatt 3.pdf", "title": "Übungsblatt 3", "kind": "pdf", "module_id": 1,
                               "downloaded_at": "2026-11-11T09:00:00", "page_count": 3, "doc_type": "uebung"]
        let file = try JSONDecoder().decode(LibFile.self, from: meta.serialized())
        let api = APIClient(base: URL(string: "http://erfunden.test/")!, transport: t)
        let env = try hostWithEnvironment(NavigationStack { DocumentView(file: file, api: api) }, api: api,
                                          size: CGSize(width: 1180, height: 820))
        env.window.overrideUserInterfaceStyle = .light

        func bar() -> CGRect? { Self.frame(of: "editor.toolbar", in: env.view) }
        func pdfFrame() -> CGRect? {
            Self.pdfViews(in: env.view).first.map { $0.convert($0.bounds, to: env.window) }
        }
        XCTAssertTrue(env.wait(timeout: 20) { bar() != nil && pdfFrame() != nil },
                      "Leiste fehlt (PDF \(pdfFrame().map { "\($0)" } ?? "-"), Kennungen \(Self.identifiers(in: env.view).sorted())):\n"
                      + env.labels().joined(separator: "\n"))
        env.pump(1.0)
        func checkFixed(_ what: String) throws -> CGRect {
            // Lage ueber die Knoepfe (der Hintergrund der Leiste reicht wie jede Flaeche unter die Kopfzeile)
            let b = try XCTUnwrap(Self.frame(of: "toolbar.tool.pen", in: env.view), what)
            let redo = try XCTUnwrap(Self.frame(of: "toolbar.redo", in: env.view), what)
            let p = try XCTUnwrap(pdfFrame(), what)
            let w = env.window.bounds.width
            // seit 12.11.2026 (Auftrag: "maximale Schreibflaeche") eine Kopfzeile: Zurueck und Reiter links, Werkzeuge,
            // rechts die Knoepfe bis an den Rand; keine Navigationsleiste mehr darueber
            let more = try XCTUnwrap(Self.frame(of: "doc.more", in: env.view), what)
            XCTAssertLessThan(b.minX, w * 0.4, "\(what): Werkzeuge links der Mitte")
            XCTAssertGreaterThan(more.maxX, w - 100, "\(what): Knoepfe bis rechts (volle Breite)")
            XCTAssertEqual(redo.midY, b.midY, accuracy: 1, "\(what): eine Reihe")
            XCTAssertEqual(more.midY, b.midY, accuracy: 1, "\(what): Knoepfe in derselben Reihe")
            XCTAssertEqual(p.minY - b.midY, EditorToolbar.height / 2, accuracy: 2, "\(what): PDF beginnt direkt unter der Leiste")
            XCTAssertEqual(b.minY, env.window.safeAreaInsets.top, accuracy: 1, "\(what): ganz oben (keine Kopfzeile darueber)")
            let floating = env.window.windowScene?.windows.contains { w in
                !w.isHidden && String(describing: type(of: w)).contains("ToolPicker")
            } ?? false
            XCTAssertFalse(floating, "\(what): keine schwebende Palette von PencilKit")
            return b
        }
        let landscape = try checkFixed("quer")
        try shoot(env, "werkzeugleiste-quer")

        // Werkzeugwechsel und Objektmodus: die Leiste bleibt, wo sie ist
        let editor = try XCTUnwrap(Self.pdfViews(in: env.view).first.flatMap(Self.editor(of:)))
        editor.tools.select(.marker)
        editor.tools.select(.shape)
        env.pump(0.5)
        XCTAssertEqual(try checkFixed("Objektmodus"), landscape)
        editor.tools.select(.pen)
        env.pump(0.3)

        // gedreht (hochkant)
        env.window.frame = CGRect(origin: .zero, size: CGSize(width: 820, height: 1180))
        env.view.frame = env.window.bounds
        env.pump(1.5)
        let portrait = try checkFixed("hoch")
        XCTAssertEqual(portrait.minY, landscape.minY, accuracy: 1, "gleiche Hoehe im Dokument")
        try shoot(env, "werkzeugleiste-hoch")
    }

    // MARK: Hilfen

    private func waitFor(_ what: String, timeout: Double = 5, _ cond: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline { if cond() { return }; try await Task.sleep(nanoseconds: 30_000_000) }
        XCTFail("Zeit abgelaufen: \(what)")
    }

    private func shoot(_ env: HostedEnvironment, _ name: String) throws {
        let w = env.window
        let img = UIGraphicsImageRenderer(bounds: w.bounds).image { _ in w.drawHierarchy(in: w.bounds, afterScreenUpdates: true) }
        let a = XCTAttachment(image: img)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        if let dir = ProcessInfo.processInfo.environment["UF_TOOLBAR_SHOTS"] {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")
            try XCTUnwrap(img.pngData()).write(to: url)
            print("[Leiste] Bild: \(url.path)")
        }
    }

    static func pdfViews(in v: UIView) -> [PDFView] {
        (v as? PDFView).map { [$0] } ?? v.subviews.flatMap { pdfViews(in: $0) }
    }

    /// Editor einer PDF-Ansicht (ueber die Responder-Kette)
    static func editor(of view: UIView) -> PDFEditorController? {
        var r: UIResponder? = view
        while let next = r { if let e = next as? PDFEditorController { return e }; r = next.next }
        return nil
    }

    /// Kennung eines Elements (SwiftUI-Elemente melden sie nur ueber die Bedienungshilfen-Methode)
    static func identifier(_ o: NSObject) -> String? {
        let sel = NSSelectorFromString("accessibilityIdentifier")
        guard o.responds(to: sel) else { return nil }
        return o.value(forKey: "accessibilityIdentifier") as? String
    }

    /// Kennungen aller Elemente im Bedienungshilfen-Baum
    static func identifiers(in view: UIView) -> Set<String> {
        var out = Set<String>()
        visit(view) { o in if let id = identifier(o), !id.isEmpty { out.insert(id) } }
        return out
    }

    /// Rahmen (Fensterkoordinaten) des Elements mit dieser Kennung
    static func frame(of identifier: String, in view: UIView) -> CGRect? {
        var found: CGRect?
        visit(view) { o in
            if found == nil, Self.identifier(o) == identifier {
                let f = o.accessibilityFrame                                     // Bildschirm = Fenster (Testfenster bei 0,0)
                if f.width > 0 { found = f }
            }
        }
        return found
    }

    private static func visit(_ root: UIView, _ body: (NSObject) -> Void) {
        func go(_ element: Any, depth: Int) {
            guard depth < 40 else { return }
            if let o = element as? NSObject {
                body(o)
                for e in o.accessibilityElements ?? [] { go(e, depth: depth + 1) }
                let n = o.accessibilityElementCount()
                if n != NSNotFound, n > 0 {
                    for i in 0..<min(n, 500) { if let e = o.accessibilityElement(at: i) { go(e, depth: depth + 1) } }
                }
            }
            if let v = element as? UIView { for s in v.subviews { go(s, depth: depth + 1) } }
        }
        root.layoutIfNeeded()
        go(root, depth: 0)
    }
}
