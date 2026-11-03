import PDFKit
import PencilKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Apples Palette als einziger Ort fuer alle Werkzeuge (EDITOR-GOODNOTES-PLAN-2026-11-03, Schritte A bis D):
/// eigene Eintraege ab iPadOS 18, Objektmodus ueber die Palette, Farben aus der Palette, "Mit dem Finger zeichnen" aus der
/// Palette, Rueckgaengig fuer eingefuegte Seiten im gemeinsamen Verlauf, Palette kommt nach Blaettern ohne Abfrage-
/// Schleife zurueck. Stift, Doppeltippen und Squeeze prueft die Abnahmeliste am Geraet.
@MainActor
final class EditorPaletteTests: XCTestCase {

    // MARK: Aufbau

    private func pdf(pages: Int) -> Data {
        let raw = NSMutableData()
        let size = CGSize(width: 595, height: 842)
        UIGraphicsBeginPDFContextToData(raw, CGRect(origin: .zero, size: size), nil)
        for i in 1...pages {
            UIGraphicsBeginPDFPageWithInfo(CGRect(origin: .zero, size: size), nil)
            "Satz des Pythagoras \(i)".draw(at: CGPoint(x: 100, y: 200), withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
        }
        UIGraphicsEndPDFContext()
        return raw as Data
    }

    private func openStore() async throws -> DocumentStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-palette-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let host = LocalBackendHost(directory: root.appendingPathComponent("db", isDirectory: true), clock: .fixed(berlin: "2026-10-29T09:00:00")!)
        let backend = try await host.backend()
        let fileID = "palette-" + UUID().uuidString.prefix(8).lowercased()
        try await backend.context.database.transaction { c in
            try c.execute("INSERT OR IGNORE INTO courses(id, title, semester, subject, kind, created_at) VALUES (?,?,?,?,?,?)",
                          [.text("k-test"), .text("Testkurs"), .text("WiSe 2026/27"), .text("Testkurs"), .text("vorlesung"),
                           .text("2026-10-01T08:00:00")])
            try c.execute("INSERT INTO files(id, course_id, name, chdate, status, kind, downloaded_at) VALUES (?,?,?,?, 'neu', 'pdf', ?)",
                          [.text(fileID), .text("k-test"), .text("Skript.pdf"), .integer(1_792_000_000), .text("2026-10-29T08:00:00")])
        }
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
        let pdfURL = AppPaths.pdf(fileID, namespace: api.namespace, root: root)
        try FileManager.default.createDirectory(at: pdfURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pdf(pages: 3).write(to: pdfURL)
        try DocumentStore.stamp(try await api.value("/api/files/\(fileID)")).write(to: pdfURL.appendingPathExtension("stand"), atomically: true, encoding: .utf8)
        let file = LibFile(id: fileID, name: "Skript.pdf", title: "Skript", kind: "pdf", module_id: nil, subject: "Testkurs",
                           doc_type: nil, ai_title: nil, sub_label: nil, downloaded_at: "2026-10-29T08:00:00", has_notes: nil,
                           page_count: 3, studip_folder: nil)
        let store = DocumentStore(file: file, api: api, root: root)
        await store.load()
        XCTAssertNil(store.errorMessage, store.errorMessage ?? "")
        addTeardownBlock { await store.close() }
        return store
    }

    private static let pen = "test.pen-\(UUID().uuidString)"
    private static let blue = UIColor(red: 0x2f / 255.0, green: 0x7f / 255.0, blue: 0xd1 / 255.0, alpha: 1)
    private static let green = UIColor(red: 0x2e / 255.0, green: 0x9e / 255.0, blue: 0x5b / 255.0, alpha: 1)

    /// Palette mit bekanntem Stift (blau, 3 pt) und Textmarker (gruen) vor unseren Eintraegen
    /// Palette mit eigenem Speichernamen: Paletten mit gleichem Namen (der Editor nimmt sonst "uniflow.toolpicker")
    /// teilen bei PencilKit Auswahl, Farben und Staerken, auch ueber Tests hinweg
    @available(iOS 18.0, *)
    private func testPicker() -> PKToolPicker {
        let p = PKToolPicker(toolItems: [PKToolPickerInkingItem(type: .pen, identifier: Self.pen),
                                         PKToolPickerInkingItem(type: .marker, identifier: "test.marker"),
                                         PKToolPickerEraserItem(type: .vector), PKToolPickerLassoItem()] + EditorPalette.customItems())
        p.stateAutosaveName = "test-" + UUID().uuidString
        p.selectedToolItemIdentifier = Self.pen
        return p
    }

    private func isolatedDefaultPicker() -> PKToolPicker {
        let p = EditorPalette.makePicker()
        p.stateAutosaveName = "test-" + UUID().uuidString
        return p
    }

    private func resetPaletteDefaults() {
        for k in [EditorPalette.shapeKey, EditorPalette.selectKey, "uniflow.palette.syncedColors"] {
            UserDefaults.standard.removeObject(forKey: k)
        }
        addTeardownBlock {
            for k in [EditorPalette.shapeKey, EditorPalette.selectKey, "uniflow.palette.syncedColors"] {
                UserDefaults.standard.removeObject(forKey: k)
            }
        }
    }

    private func wait(_ what: String, timeout: Double = 5, _ cond: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline { if await cond() { return }; try await Task.sleep(nanoseconds: 30_000_000) }
        XCTFail("Zeit abgelaufen: \(what)")
    }

    // MARK: A) Unsere Werkzeuge in Apples Palette

    /// Die Palette behaelt alle Werkzeuge von Apple (Stifte, Radierer, Lasso, Lineal) und zeigt dahinter unsere fuenf
    /// Eintraege; "Mit dem Finger zeichnen" steht in der Palette (iPad).
    func testPaletteKeepsAppleToolsAndAddsOurObjectTools() throws {
        let picker = EditorPalette.makePicker()
        XCTAssertEqual(picker.showsDrawingPolicyControls, !PDFEditorController.isMac)
        guard #available(iOS 18.0, *) else {
            XCTAssertFalse(EditorPalette.supportsCustomItems, "iPadOS 17: bisherige Objektleiste")
            return
        }
        XCTAssertTrue(EditorPalette.supportsCustomItems)
        let ids = picker.toolItems.map(\.identifier)
        let apple = PKToolPicker().toolItems.map(\.identifier)
        XCTAssertEqual(Array(ids.prefix(apple.count)), apple, "Apples Werkzeuge unveraendert und zuerst")
        for id in ["com.apple.ink.pen", "com.apple.ink.marker", "com.apple.tool.eraser", "com.apple.tool.lasso", "com.apple.tool.ruler"] {
            XCTAssertTrue(ids.contains(id), id)
        }
        XCTAssertEqual(Array(ids.suffix(EditorPalette.customIDs.count)), EditorPalette.customIDs)
        let custom = picker.toolItems.compactMap { $0 as? PKToolPickerCustomItem }
        XCTAssertEqual(custom.first { $0.identifier == EditorPalette.shapeID }?.allowsColorSelection, true, "Form mit Farbe")
        XCTAssertEqual(custom.first { $0.identifier == EditorPalette.textID }?.allowsColorSelection, true, "Text mit Farbe")
        XCTAssertEqual(custom.first { $0.identifier == EditorPalette.markupID }?.allowsColorSelection, false,
                       "Text markieren nimmt die Farbe des Textmarkers")
        for item in custom {
            let img = try XCTUnwrap(item.configuration.imageProvider?(item))
            XCTAssertGreaterThanOrEqual(img.size.height, 150, "Bild mindestens 150 pt hoch (PencilKit)")
            XCTAssertFalse((img.accessibilityLabel ?? "").isEmpty, "VoiceOver nennt das Werkzeug")
        }
    }

    /// Zuordnung Eintrag <-> Objektwerkzeug in beide Richtungen; Form und Auswahl folgen ihrer Option
    func testObjectToolMapping() {
        XCTAssertNil(EditorPalette.objectTool(for: "com.apple.ink.pen"))
        XCTAssertEqual(EditorPalette.objectTool(for: EditorPalette.textID), .text)
        XCTAssertEqual(EditorPalette.objectTool(for: EditorPalette.stickyID), .sticky)
        XCTAssertEqual(EditorPalette.objectTool(for: EditorPalette.markupID), .markup)
        XCTAssertEqual(EditorPalette.objectTool(for: EditorPalette.shapeID, shape: .arrow), .arrow)
        XCTAssertEqual(EditorPalette.objectTool(for: EditorPalette.selectID, select: .lasso), .lasso)
        for t in ObjectEditing.Tool.allCases {
            let id = EditorPalette.identifier(for: t)
            XCTAssertEqual(EditorPalette.objectTool(for: id, shape: EditorPalette.shapeChoices.contains(t) ? t : .rect,
                                                    select: t == .lasso ? .lasso : .select), t, t.rawValue)
        }
    }

    /// Text in der Palette waehlen: Objektmodus mit Text, die Canvas schreibt nicht. Stift waehlen: Objektmodus aus.
    /// Legt der Editor selbst ein anderes Werkzeug fest, zeigt die Palette es.
    func testChoosingOurPaletteItemSwitchesObjectModeAndBack() async throws {
        guard #available(iOS 18.0, *) else { throw XCTSkip("eigene Eintraege erst ab iPadOS 18") }
        resetPaletteDefaults()
        let store = try await openStore()
        let picker = testPicker()
        let editor = PDFEditorController(store: store, toolPicker: picker)
        var reported: [(Bool, ObjectEditing.Tool)] = []
        editor.onObjectModeChange = { reported.append(($0, $1)) }
        editor.loadViewIfNeeded()
        let overlay = try XCTUnwrap(editor.overlayForTesting(at: 0))
        XCTAssertTrue(overlay.canvas.isUserInteractionEnabled)

        picker.selectedToolItemIdentifier = EditorPalette.textID
        XCTAssertTrue(editor.objects.isActive)
        XCTAssertEqual(editor.objects.tool, .text)
        XCTAssertFalse(overlay.canvas.isUserInteractionEnabled, "Objektwerkzeug: der Stift schreibt nicht")
        XCTAssertEqual(reported.last?.0, true)
        XCTAssertEqual(reported.last?.1, .text)

        EditorPalette.shapeTool = .ellipse
        picker.selectedToolItemIdentifier = EditorPalette.shapeID
        XCTAssertEqual(editor.objects.tool, .ellipse, "Form nach ihrer Option")

        editor.setObjectTool(.lasso)                                    // Leiste bzw. Editor wechselt selbst
        XCTAssertEqual(picker.selectedToolItemIdentifier, EditorPalette.selectID, "Palette zeigt das Werkzeug")
        XCTAssertEqual(EditorPalette.selectTool, .lasso)

        picker.selectedToolItemIdentifier = Self.pen
        XCTAssertFalse(editor.objects.isActive, "Stift: Objektmodus aus")
        XCTAssertTrue(overlay.canvas.isUserInteractionEnabled)
        XCTAssertEqual(reported.last?.0, false)

        // "Fertig" in der Objektleiste geht ueber die Palette zum letzten Stift
        picker.selectedToolItemIdentifier = EditorPalette.stickyID
        XCTAssertTrue(editor.objects.isActive)
        editor.finishObjectTools()
        XCTAssertEqual(picker.selectedToolItemIdentifier, Self.pen)
        XCTAssertFalse(editor.objects.isActive)
    }

    /// Nur ansehen (Notizen ausgeblendet; ebenso Korrektur-Modus und Free): ein Objektwerkzeug in der Palette schaltet
    /// nichts ein, die Palette springt zum Stift zurueck. Beim Oeffnen steht die Palette nie auf einem Objektwerkzeug.
    func testObjectToolIsRefusedWhereNotesAreReadOnly() async throws {
        guard #available(iOS 18.0, *) else { throw XCTSkip("eigene Eintraege erst ab iPadOS 18") }
        resetPaletteDefaults()
        let store = try await openStore()
        let picker = testPicker()
        picker.selectedToolItemIdentifier = EditorPalette.textID          // gemerkter Stand von gestern
        let editor = PDFEditorController(store: store, toolPicker: picker)
        editor.loadViewIfNeeded()
        XCTAssertEqual(picker.selectedToolItemIdentifier, Self.pen, "Oeffnen: Palette auf dem Stift")
        XCTAssertFalse(editor.objects.isActive)

        editor.ownNotesVisible = false
        picker.selectedToolItemIdentifier = EditorPalette.shapeID
        XCTAssertFalse(editor.objects.isActive, "nur ansehen: kein Objektmodus")
        try await wait("zurueck zum Stift") { picker.selectedToolItemIdentifier == Self.pen }
    }

    /// Geteilte Ansicht: die andere Haelfte schreibt nicht, solange ein Objektwerkzeug gewaehlt ist (PencilKit liesse
    /// ihre Canvas sonst mit dem letzten Stift weiterschreiben), und schaltet selbst keinen Objektmodus ein
    func testCompanionCanvasPausesWhileObjectToolIsChosen() async throws {
        guard #available(iOS 18.0, *) else { throw XCTSkip("eigene Eintraege erst ab iPadOS 18") }
        resetPaletteDefaults()
        let store = try await openStore()
        let other = try await openStore()
        let picker = testPicker()
        let undo = UndoManager()
        let main = PDFEditorController(store: store, toolPicker: picker, ownsToolPicker: true, undoManager: undo)
        let side = PDFEditorController(store: other, toolPicker: picker, ownsToolPicker: false, undoManager: undo)
        main.loadViewIfNeeded()
        side.loadViewIfNeeded()
        let sideOverlay = try XCTUnwrap(side.overlayForTesting(at: 0))
        picker.selectedToolItemIdentifier = EditorPalette.textID
        XCTAssertTrue(main.objects.isActive)
        XCTAssertFalse(side.objects.isActive)
        XCTAssertFalse(sideOverlay.canvas.isUserInteractionEnabled)
        // neue Seite waehrend eines Objektwerkzeugs: PencilKit stuerzte mit dessen Werkzeug ab ("Unknown PKTool type")
        let fresh = try XCTUnwrap(side.overlayForTesting(at: 1))
        XCTAssertFalse(fresh.canvas.isUserInteractionEnabled, "auch neue Seiten")
        XCTAssertTrue(fresh.canvas.tool is PKInkingTool, "letztes Werkzeug von Apple")
        XCTAssertTrue(try XCTUnwrap(main.overlayForTesting(at: 1)).canvas.tool is PKInkingTool)
        picker.selectedToolItemIdentifier = Self.pen
        XCTAssertTrue(sideOverlay.canvas.isUserInteractionEnabled)
    }

    // MARK: C) Farben aus der Palette

    /// Formen und Text nehmen die Stiftfarbe, solange man im Eintrag keine eigene gewaehlt hat; die Formstaerke kommt
    /// aus dem Eintrag; "Text markieren" nimmt die Farbe des Textmarkers
    func testObjectsTakeColorAndWidthFromThePalette() async throws {
        guard #available(iOS 18.0, *) else { throw XCTSkip("eigene Eintraege erst ab iPadOS 18") }
        resetPaletteDefaults()
        let store = try await openStore()
        let picker = testPicker()
        let editor = PDFEditorController(store: store, toolPicker: picker)
        editor.loadViewIfNeeded()
        // PencilKit setzt Farbe und Staerke der Stifte aus seinem gespeicherten Stand: verglichen wird mit dem, was die
        // Palette meldet
        let pen = try XCTUnwrap(picker.toolItems.first { $0.identifier == Self.pen } as? PKToolPickerInkingItem).inkingTool
        let marker = try XCTUnwrap(picker.toolItems.first { $0.identifier == "test.marker" } as? PKToolPickerInkingItem).inkingTool
        let blueHex = pen.color.uniflowRGBA.hex
        XCTAssertEqual(editor.paletteSync.inkHex, blueHex, "Stift der Palette")
        XCTAssertEqual(editor.paletteSync.inkWidth, Double(pen.width), accuracy: 0.01)
        XCTAssertEqual(editor.paletteSync.markerHex, marker.color.uniflowRGBA.hex, "Textmarker der Palette")
        XCTAssertEqual(editor.paletteSync.markupColor(.highlight), marker.color.uniflowRGBA.hex)

        picker.selectedToolItemIdentifier = EditorPalette.shapeID
        let shape = try XCTUnwrap(picker.toolItems.first { $0.identifier == EditorPalette.shapeID } as? PKToolPickerCustomItem)
        XCTAssertFalse(PaletteSync.sameColor(blueHex, "#e5322d"), "Voraussetzung: Stift nicht in der Formfarbe")
        XCTAssertTrue(PaletteSync.sameColor(shape.color.uniflowRGBA.hex, blueHex), "Form uebernimmt die Stiftfarbe")
        XCTAssertTrue(PaletteSync.sameColor(editor.objects.color, blueHex))
        XCTAssertEqual(editor.objects.lineWidth, Double(shape.width), accuracy: 0.01)

        // eigene Farbe im Eintrag bleibt, auch nach dem naechsten Wechsel vom Stift
        picker.selectedToolItemIdentifier = Self.pen
        shape.color = UIColor(red: 0.18, green: 0.62, blue: 0.36, alpha: 1)
        let own = shape.color.uniflowRGBA.hex
        picker.selectedToolItemIdentifier = EditorPalette.shapeID
        XCTAssertTrue(PaletteSync.sameColor(shape.color.uniflowRGBA.hex, own), "eigene Farbe bleibt")
        XCTAssertTrue(PaletteSync.sameColor(editor.objects.color, own))
    }

    /// Objektmodus von aussen (iPadOS 17: Schalter "Tinte/Objekte"): Objekte nehmen Farbe und Staerke des letzten Stifts
    func testObjectModeFromOutsideTakesTheInkStyle() async throws {
        resetPaletteDefaults()
        let store = try await openStore()
        let editor = PDFEditorController(store: store, toolPicker: isolatedDefaultPicker())
        editor.loadViewIfNeeded()
        editor.paletteSync.note(PKInkingTool(.pen, color: Self.blue, width: 4.2))
        editor.setObjectMode(true)
        XCTAssertTrue(editor.objects.isActive)
        XCTAssertEqual(editor.objects.color, Self.blue.uniflowRGBA.hex)
        XCTAssertEqual(editor.objects.lineWidth, 4, accuracy: 0.01, "auf halbe Punkte gerundet")
        if #available(iOS 18.0, *) {
            XCTAssertEqual(editor.toolPicker.selectedToolItemIdentifier, EditorPalette.selectID, "Palette zeigt Auswaehlen")
        }
        editor.setObjectMode(false)
        XCTAssertFalse(editor.objects.isActive)
    }

    /// Unter- und Durchstreichen: dunkle Textmarker-Farbe bleibt, helle wird wie im Web zu Rot
    func testMarkupColorFollowsTheMarker() throws {
        let sync = PaletteSync(defaults: try XCTUnwrap(UserDefaults(suiteName: "palette-\(UUID().uuidString)")))
        sync.note(PKInkingTool(.marker, color: UIColor(red: 1, green: 0.85, blue: 0.1, alpha: 1)))
        XCTAssertEqual(sync.markupColor(.highlight), sync.markerHex)
        XCTAssertEqual(sync.markupColor(.underline), PageObjectEdit.markerColors[0], "hell: Rot ueber die Web-Regel")
        let lines = PageObjectEdit.markup(.strike, lines: [PageObjectEdit.Line(text: "a", x0: 0, y0: 0, x1: 10, y1: 10)],
                                          color: sync.markupColor(.strike)) { "x" }
        XCTAssertEqual(lines.first?["stroke"], "#e5322d")
        sync.note(PKInkingTool(.marker, color: Self.blue))
        XCTAssertEqual(sync.markupColor(.underline), Self.blue.uniflowRGBA.hex, "dunkel: Farbe des Textmarkers")
        XCTAssertNotEqual(sync.inkHex, Self.blue.uniflowRGBA.hex, "Textmarker aendert die Stiftfarbe nicht")
    }

    func testAdoptInkColorRespectsOwnChoice() throws {
        let sync = PaletteSync(defaults: try XCTUnwrap(UserDefaults(suiteName: "palette-\(UUID().uuidString)")))
        sync.note(PKInkingTool(.pen, color: Self.blue, width: 2))
        let blue = Self.blue.uniflowRGBA.hex
        XCTAssertEqual(sync.adoptInkColor(item: "x", current: "#e5322d"), blue, "erstes Mal: Stiftfarbe")
        XCTAssertNil(sync.adoptInkColor(item: "x", current: blue), "schon gleich")
        sync.note(PKInkingTool(.pen, color: Self.green, width: 2))
        XCTAssertEqual(sync.adoptInkColor(item: "x", current: blue), Self.green.uniflowRGBA.hex, "folgt dem Stift")
        XCTAssertNil(sync.adoptInkColor(item: "x", current: "#123456"), "eigene Farbe bleibt")
        XCTAssertTrue(PaletteSync.sameColor("#2f7fd1", "#307fd2"))
        XCTAssertFalse(PaletteSync.sameColor("#2f7fd1", "#2f7f00"))
    }

    // MARK: B) Schalter und Rueckgaengig der Palette

    /// "Mit dem Finger zeichnen" der Palette entscheidet: Canvas mit `.default`, Scrollen nach der iPadOS-Einstellung;
    /// ohne (Tests, Mac-Weg) bleibt der eigene Schalter
    func testDrawingPolicyFollowsThePalette() async throws {
        let store = try await openStore()
        let editor = PDFEditorController(store: store)
        editor.pencilOnly = true
        editor.loadViewIfNeeded()
        let overlay = try XCTUnwrap(editor.overlayForTesting(at: 0))
        XCTAssertEqual(overlay.canvas.drawingPolicy, PDFEditorController.isMac ? .anyInput : .pencilOnly)
        editor.followsPaletteDrawingPolicy = true
        guard !PDFEditorController.isMac else { return }
        XCTAssertEqual(overlay.canvas.drawingPolicy, .default, "PencilKit folgt der Palette")
        XCTAssertEqual(editor.effectivePencilOnly, UIPencilInteraction.prefersPencilOnlyDrawing)
        XCTAssertTrue(editor.pdfView.gestureRecognizers?.contains { $0 is TouchDownObserver } == true,
                      "liest den Schalter bei jeder Beruehrung neu")
        XCTAssertEqual(try XCTUnwrap(editor.overlayForTesting(at: 1)).canvas.drawingPolicy, .default, "auch neue Seiten")
        editor.followsPaletteDrawingPolicy = false
        XCTAssertEqual(overlay.canvas.drawingPolicy, .pencilOnly)
        XCTAssertFalse(editor.pdfView.gestureRecognizers?.contains { $0 is TouchDownObserver } == true)
    }

    /// Seite einfuegen landet im selben Verlauf wie Striche und Objekte (den nutzt auch die Palette): Rueckgaengig legt
    /// die Seite in den Papierkorb, Wiederholen holt sie zurueck
    func testPageInsertIsUndoneThroughTheSharedUndoManager() async throws {
        let store = try await openStore()
        let editor = PDFEditorController(store: store)
        editor.loadViewIfNeeded()
        XCTAssertTrue(editor.undoManager === editor.editUndo, "Palette und Leiste nutzen denselben Verlauf")
        let before = editor.pageCount
        let inserted = await editor.insertBlankPage()
        let key = try XCTUnwrap(inserted)
        XCTAssertEqual(editor.pageCount, before + 1)
        XCTAssertTrue(editor.editUndo.canUndo)
        XCTAssertEqual(editor.editUndo.undoActionName, "Seite einfügen")

        editor.editUndo.undo()
        try await wait("Seite weg") { editor.pageCount == before }
        let trashed = await editor.trashedPages()
        XCTAssertTrue(trashed.contains { $0.key == key }, "im Papierkorb, wie im Web wiederherstellbar")
        XCTAssertTrue(editor.editUndo.canRedo)

        editor.editUndo.redo()
        try await wait("Seite wieder da") { editor.pageCount == before + 1 && editor.store.layout?.index(ofKey: key) != nil }
        XCTAssertTrue(editor.editUndo.canUndo)

        // nur ansehen: Rueckgaengig nimmt nichts zurueck
        editor.canEdit = false
        XCTAssertFalse(editor.editUndo.canUndo, "Verlauf beim Sperren verworfen")
        let appended = await editor.appendBlankPage()
        XCTAssertNil(appended)
    }

    // MARK: D) Palette bleibt sichtbar

    func testBlockerOrder() {
        typealias P = EditorPalette
        XCTAssertEqual(P.blocker(wanted: false, inWindow: true, markup: true, textInput: true, presenting: true, otherWindow: true), .notWanted)
        XCTAssertEqual(P.blocker(wanted: true, inWindow: false, markup: false, textInput: false, presenting: false, otherWindow: false), .notWanted)
        XCTAssertEqual(P.blocker(wanted: true, inWindow: true, markup: true, textInput: true, presenting: true, otherWindow: true), .markup)
        XCTAssertEqual(P.blocker(wanted: true, inWindow: true, markup: false, textInput: true, presenting: true, otherWindow: true), .textInput)
        XCTAssertEqual(P.blocker(wanted: true, inWindow: true, markup: false, textInput: false, presenting: true, otherWindow: true), .presentation)
        XCTAssertEqual(P.blocker(wanted: true, inWindow: true, markup: false, textInput: false, presenting: false, otherWindow: true), .otherWindow)
        XCTAssertEqual(P.blocker(wanted: true, inWindow: true, markup: false, textInput: false, presenting: false, otherWindow: false), .none)
    }

    /// Nur echte Eingabefelder halten die Palette bis zum Schliessen der Tastatur zurueck; ein nicht bearbeitbarer Text
    /// und Elemente in der PDF-Ansicht nicht (sonst kaeme die Palette nach Antippen der PDF nie zurueck)
    func testOnlyTypingFieldsWaitForTheKeyboard() {
        XCTAssertTrue(PDFEditorController.isTypingField(UITextField()))
        XCTAssertTrue(PDFEditorController.isTypingField(UITextView()))
        let readOnly = UITextView()
        readOnly.isEditable = false
        XCTAssertFalse(PDFEditorController.isTypingField(readOnly))
        XCTAssertFalse(PDFEditorController.isTypingField(nil))
        XCTAssertFalse(PDFEditorController.isTypingField(UIView()))
        final class InputInPDF: UIView, UIKeyInput {
            var hasText: Bool { false }
            func insertText(_ text: String) {}
            func deleteBackward() {}
        }
        XCTAssertTrue(PDFEditorController.isTypingField(InputInPDF()), "eigene Eingabe ausserhalb der PDF")
        let pdf = PDFView()
        let inside = InputInPDF()
        pdf.addSubview(inside)
        XCTAssertFalse(PDFEditorController.isTypingField(inside), "PDFKit-Textauswahl: keine Tastatur")
        let editing = UITextView()
        pdf.addSubview(editing)
        XCTAssertTrue(PDFEditorController.isTypingField(editing), "Textobjekt auf der Seite: Tastatur")
    }

    /// Die Markierung meldet sich genau einmal, wenn ihr Blatt den Bildschirm verlaesst
    func testWindowExitSentinelFiresOnceWhenLeaving() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let host = UIView(frame: window.bounds)
        window.addSubview(host)
        window.isHidden = false
        var fired = 0
        let s = WindowExitSentinel()
        s.onLeave = { fired += 1 }
        host.addSubview(s)
        XCTAssertTrue(s.isHidden)
        XCTAssertFalse(s.isUserInteractionEnabled)
        host.removeFromSuperview()
        try await wait("gemeldet") { fired == 1 }
        window.addSubview(host)
        host.removeFromSuperview()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(fired, 1)
        window.isHidden = true
    }

    private func show(_ editor: PDFEditorController) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let frame = scene?.screen.bounds ?? CGRect(x: 0, y: 0, width: 834, height: 1210)
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        window.rootViewController = editor
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in
            editor.showToolPicker(false)
            window.isHidden = true
            window.rootViewController = nil
        }
        return window
    }

    /// Ein Blatt ueber dem Editor haelt die Palette zurueck; der Editor wartet auf das Verschwinden des Blatts (statt
    /// in Abstaenden nachzusehen) und holt den Fokus dann zurueck. Ein Blatt, in dem der Editor selbst steht, zaehlt nicht.
    func testPaletteComesBackWhenASheetLeaves() async throws {
        let store = try await openStore()
        let editor = PDFEditorController(store: store)
        _ = show(editor)
        editor.showToolPicker(true)
        try await wait("Editor im Fenster") { editor.view.window != nil }
        XCTAssertNil(editor.blockingPresentation())

        // Blatt mit eigenem Fokus (wie Teilen, Gliederung, Marker): die Palette geht weg
        let sheet = UIViewController()
        let focus = FocusView()
        sheet.view.addSubview(focus)
        editor.present(sheet, animated: false)
        try await wait("Blatt da") { sheet.view.window != nil }
        XCTAssertTrue(focus.becomeFirstResponder())
        XCTAssertTrue(editor.blockingPresentation() === sheet)
        XCTAssertEqual(editor.paletteBlocker, .presentation)
        XCTAssertFalse(editor.restorePicker(), "wartet auf das Blatt")
        let host = try XCTUnwrap(sheet.presentationController?.containerView ?? sheet.view)
        XCTAssertTrue(host.subviews.contains { $0 is WindowExitSentinel }, "Markierung im Blatt")

        sheet.dismiss(animated: false)
        try await wait("Blatt weg, Fokus zurueck") {
            editor.blockingPresentation() == nil && UIResponder.uf_current is ToolPickerAnchor
        }
        XCTAssertEqual(editor.paletteBlocker, .none)
    }

    /// Seite einfuegen baut alle Seiten neu auf (frueher: "Einfuegen schliesst die Leiste"): der Fokus bleibt beim
    /// Anker, die Palette bleibt. Hatte eine Zeichenflaeche den Fokus (am Geraet z. B. nach Apples Lasso), gibt
    /// `keepPaletteFocus` ihn vor dem Verwerfen an den Anker; im Simulator nimmt eine Canvas den Fokus nicht an.
    func testInsertingAPageKeepsThePaletteFocus() async throws {
        let store = try await openStore()
        let editor = PDFEditorController(store: store)
        _ = show(editor)
        editor.showToolPicker(true)
        try await wait("Anker hat den Fokus") { UIResponder.uf_current is ToolPickerAnchor }
        let before = editor.pageCount
        _ = await editor.insertBlankPage()
        XCTAssertEqual(editor.pageCount, before + 1, "neu aufgebaut")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(UIResponder.uf_current is ToolPickerAnchor, "Fokus beim Anker: die Palette schliesst sich nicht")
        XCTAssertEqual(editor.paletteBlocker, .none)
    }
}

/// Element mit eigenem Fokus (kein Textfeld), wie ein Blatt ohne Tastatur
private final class FocusView: UIView {
    override var canBecomeFirstResponder: Bool { true }
}

