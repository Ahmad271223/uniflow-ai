import PDFKit
import PencilKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Editor-Schritte E (Seitenleiste mit "+"), F ("KI fragen" an der Palette), H (Formerkennung) und K ("Als
/// Karteikarte") aus docs/EDITOR-GOODNOTES-PLAN-2026-11-03.md, Abschnitt 7. Was nur der Stift zeigt (Halten am Geraet,
/// das Bearbeitungsmenue der PDF-Auswahl), steht dort als Pruefanleitung.
@MainActor
final class EditorStepEFHKTests: XCTestCase {

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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-efhk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let host = LocalBackendHost(directory: root.appendingPathComponent("db", isDirectory: true), clock: .fixed(berlin: "2026-11-04T09:00:00")!)
        let backend = try await host.backend()
        let fileID = "efhk-" + UUID().uuidString.prefix(8).lowercased()
        try await backend.context.database.transaction { c in
            try c.execute("INSERT OR IGNORE INTO courses(id, title, semester, subject, kind, created_at) VALUES (?,?,?,?,?,?)",
                          [.text("k-test"), .text("Testkurs"), .text("WiSe 2026/27"), .text("Testkurs"), .text("vorlesung"),
                           .text("2026-10-01T08:00:00")])
            try c.execute("INSERT INTO files(id, course_id, name, chdate, status, kind, downloaded_at) VALUES (?,?,?,?, 'neu', 'pdf', ?)",
                          [.text(fileID), .text("k-test"), .text("Skript.pdf"), .integer(1_792_000_000), .text("2026-11-04T08:00:00")])
        }
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
        let pdfURL = AppPaths.pdf(fileID, namespace: api.namespace, root: root)
        try FileManager.default.createDirectory(at: pdfURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pdf(pages: 3).write(to: pdfURL)
        try DocumentStore.stamp(try await api.value("/api/files/\(fileID)")).write(to: pdfURL.appendingPathExtension("stand"), atomically: true, encoding: .utf8)
        let file = LibFile(id: fileID, name: "Skript.pdf", title: "Skript", kind: "pdf", module_id: nil, subject: "Testkurs",
                           doc_type: nil, ai_title: nil, sub_label: nil, downloaded_at: "2026-11-04T08:00:00", has_notes: nil,
                           page_count: 3, studip_folder: nil)
        let store = DocumentStore(file: file, api: api, root: root)
        await store.load()
        XCTAssertNil(store.errorMessage, store.errorMessage ?? "")
        addTeardownBlock { await store.close() }
        return store
    }

    private func wait(_ what: String, timeout: Double = 5, _ cond: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline { if await cond() { return }; try await Task.sleep(nanoseconds: 30_000_000) }
        XCTFail("Zeit abgelaufen: \(what)")
    }

    /// Strich wie vom Stift entlang `points` (leicht zittrig), 4 ms je Punkt; `hold`: so lange am Ende still (weitere
    /// Punkte im Umkreis von 2 pt)
    private func stroke(_ points: [CGPoint], jitter: CGFloat = 0.8, hold: TimeInterval = 0, ink: PKInk = PKInk(.pen, color: .blue),
                        created: Date = Date(timeIntervalSinceReferenceDate: 800_000_000)) -> PKStroke {
        var pts: [PKStrokePoint] = []
        var t = 0.0
        for (i, p) in points.enumerated() {
            let j = CGFloat(i % 3) * jitter - jitter
            pts.append(PKStrokePoint(location: CGPoint(x: p.x + j, y: p.y - j), timeOffset: t,
                                     size: CGSize(width: 2 + CGFloat(i % 4) * 0.5, height: 2 + CGFloat(i % 4) * 0.5),
                                     opacity: 1, force: 0.3 + CGFloat(i % 5) * 0.1, azimuth: 0.4, altitude: 1.1))
            t += 0.004
        }
        if hold > 0, let last = points.last {
            for k in 0..<10 {
                t += hold / 10
                pts.append(PKStrokePoint(location: CGPoint(x: last.x + CGFloat(k % 2), y: last.y), timeOffset: t,
                                         size: CGSize(width: 2, height: 2), opacity: 1, force: 0.3, azimuth: 0.4, altitude: 1.1))
            }
        }
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: pts, creationDate: created))
    }

    /// Punkte entlang eines Polygons (alle 3 pt), optional geschlossen
    private func along(_ vertices: [CGPoint], closed: Bool, step: CGFloat = 3) -> [CGPoint] {
        var out: [CGPoint] = []
        let v = closed ? vertices + [vertices[0]] : vertices
        for i in 0..<(v.count - 1) {
            let a = v[i], b = v[i + 1]
            let n = max(1, Int(hypot(b.x - a.x, b.y - a.y) / step))
            for k in 0..<n {
                let t = CGFloat(k) / CGFloat(n)
                out.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        out.append(v[v.count - 1])
        return out
    }

    private func ellipsePoints(center c: CGPoint, rx: CGFloat, ry: CGFloat, from: CGFloat = 0.3) -> [CGPoint] {
        (0...120).map { i in
            let t = from + CGFloat(i) / 120 * 2 * .pi
            return CGPoint(x: c.x + rx * cos(t), y: c.y + ry * sin(t))
        }
    }

    // MARK: H) Formerkennung

    func testRecognizesTheFiveShapesFromHandDrawnLikePoints() throws {
        // Linie (leicht schief: bleibt schief), waagerechte Linie (rastet ein)
        guard case .line(let a, let b)? = ShapeRecognizer.recognize(along([CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 160)], closed: false)) else {
            return XCTFail("Linie")
        }
        XCTAssertEqual(a.x, 100, accuracy: 2); XCTAssertEqual(b.y, 160, accuracy: 2)
        guard case .line(_, let h)? = ShapeRecognizer.recognize(along([CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 104)], closed: false)) else {
            return XCTFail("waagerechte Linie")
        }
        XCTAssertEqual(h.y, 100, accuracy: 1.5, "bis 5 Grad: waagerecht eingerastet")

        // Rechteck, gezeichnet ab Mitte der oberen Kante
        let rect = along([CGPoint(x: 200, y: 100), CGPoint(x: 300, y: 100), CGPoint(x: 300, y: 180), CGPoint(x: 100, y: 180),
                          CGPoint(x: 100, y: 100), CGPoint(x: 196, y: 100)], closed: false)
        guard case .rectangle(let c, let s, let angle)? = ShapeRecognizer.recognize(rect) else { return XCTFail("Rechteck") }
        XCTAssertEqual(c.x, 200, accuracy: 3); XCTAssertEqual(c.y, 140, accuracy: 3)
        XCTAssertEqual(s.width, 200, accuracy: 6); XCTAssertEqual(s.height, 80, accuracy: 6)
        XCTAssertEqual(angle, 0, accuracy: 0.001, "achsparallel")

        // gedrehtes Rechteck (30 Grad) bleibt gedreht
        let rot: CGFloat = .pi / 6
        let corners = [CGPoint(x: -80, y: -40), CGPoint(x: 80, y: -40), CGPoint(x: 80, y: 40), CGPoint(x: -80, y: 40)].map {
            CGPoint(x: 300 + $0.x * cos(rot) - $0.y * sin(rot), y: 300 + $0.x * sin(rot) + $0.y * cos(rot))
        }
        guard case .rectangle(_, let rs, let ra)? = ShapeRecognizer.recognize(along(corners, closed: true)) else { return XCTFail("gedrehtes Rechteck") }
        XCTAssertEqual(abs(ra), rot, accuracy: 0.08)
        XCTAssertEqual(max(rs.width, rs.height), 160, accuracy: 8)

        // Kreis und Ellipse
        guard case .ellipse(let cc, let cr)? = ShapeRecognizer.recognize(ellipsePoints(center: CGPoint(x: 200, y: 200), rx: 50, ry: 52)) else {
            return XCTFail("Kreis")
        }
        XCTAssertEqual(cr.width, cr.height, "fast gleiche Achsen: Kreis")
        XCTAssertEqual(cc.x, 200, accuracy: 2); XCTAssertEqual(cr.width, 51, accuracy: 2)
        guard case .ellipse(_, let er)? = ShapeRecognizer.recognize(ellipsePoints(center: CGPoint(x: 200, y: 200), rx: 90, ry: 40)) else {
            return XCTFail("Ellipse")
        }
        XCTAssertEqual(er.width, 90, accuracy: 2); XCTAssertEqual(er.height, 40, accuracy: 2)

        // Dreieck
        let tri = [CGPoint(x: 100, y: 200), CGPoint(x: 200, y: 50), CGPoint(x: 300, y: 200)]
        guard case .triangle(let t0, let t1, let t2)? = ShapeRecognizer.recognize(along(tri, closed: true)) else { return XCTFail("Dreieck") }
        let found = [t0, t1, t2]
        for v in tri { XCTAssertTrue(found.contains { hypot($0.x - v.x, $0.y - v.y) <= 8 }, "Ecke \(v) gefunden") }

        // Pfeil: Schaft, dann Haken zurueck und "V" ueber die Spitze
        let arrow = along([CGPoint(x: 100, y: 300), CGPoint(x: 300, y: 300), CGPoint(x: 275, y: 285), CGPoint(x: 300, y: 300),
                           CGPoint(x: 275, y: 315)], closed: false)
        guard case .arrow(let from, let tip)? = ShapeRecognizer.recognize(arrow) else { return XCTFail("Pfeil") }
        XCTAssertEqual(from.x, 100, accuracy: 2); XCTAssertEqual(tip.x, 300, accuracy: 3)
        // Pfeil mit nur einem Haken
        let half = along([CGPoint(x: 100, y: 400), CGPoint(x: 100, y: 200), CGPoint(x: 118, y: 222)], closed: false)
        guard case .arrow? = ShapeRecognizer.recognize(half) else { return XCTFail("Pfeil mit Haken") }
    }

    func testCurvesDotsAndScribblesStayAsTheyAre() {
        // Bogen (kein Strich, keine Form)
        let arc = (0...60).map { i -> CGPoint in
            let t = CGFloat(i) / 60 * .pi
            return CGPoint(x: 200 + 100 * cos(t), y: 200 - 100 * sin(t))
        }
        XCTAssertNil(ShapeRecognizer.recognize(arc), "Bogen bleibt")
        XCTAssertNil(ShapeRecognizer.recognize(along([CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 12)], closed: false)), "zu kurz")
        // Zickzack
        let zig = along([CGPoint(x: 100, y: 100), CGPoint(x: 140, y: 160), CGPoint(x: 180, y: 100), CGPoint(x: 220, y: 160),
                         CGPoint(x: 260, y: 100), CGPoint(x: 300, y: 160)], closed: false)
        XCTAssertNil(ShapeRecognizer.recognize(zig), "Zickzack bleibt")
        // Fuenfeck ist keine der fuenf Formen
        let penta = (0..<5).map { i -> CGPoint in
            let t = CGFloat(i) / 5 * 2 * .pi
            return CGPoint(x: 200 + 80 * cos(t), y: 200 + 80 * sin(t))
        }
        XCTAssertNil(ShapeRecognizer.recognize(along(penta, closed: true)), "Fuenfeck bleibt")
    }

    func testHoldingAtTheEndIsRequired() {
        let line = [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100)]
        let quick = stroke(along(line, closed: false))
        XCTAssertFalse(ShapeRecognizer.heldStill(quick.path), "ohne Halten keine Form")
        XCTAssertFalse(ShapeRecognizer.heldStill(quick.path, endedAt: quick.path.creationDate.addingTimeInterval(0.4)))
        // PencilKit legt beim stillen Stift nicht unbedingt Punkte an: dann zaehlt die Zeit bis zum Absetzen
        XCTAssertTrue(ShapeRecognizer.heldStill(quick.path, endedAt: quick.path.creationDate.addingTimeInterval(0.35 + 0.5)))
        let held = stroke(along(line, closed: false), hold: 0.6)
        XCTAssertTrue(ShapeRecognizer.heldStill(held.path), "Punkte im Umkreis ueber 0,5 s")
        XCTAssertNotNil(ShapeRecognizer.replacement(for: held))
    }

    func testIdealStrokeKeepsInkWidthAndStaysAnOrdinaryStroke() throws {
        let ink = PKInk(.marker, color: .systemGreen)
        let original = stroke(along([CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100), CGPoint(x: 300, y: 200), CGPoint(x: 100, y: 200)],
                                    closed: true), hold: 0.6, ink: ink)
        let ideal = try XCTUnwrap(ShapeRecognizer.replacement(for: original))
        XCTAssertEqual(ideal.ink.inkType, .marker)
        XCTAssertEqual(ideal.ink.color.uniflowRGBA.hex, ink.color.uniflowRGBA.hex)
        XCTAssertEqual(ideal.path.creationDate, original.path.creationDate)
        let widths = Set((0..<ideal.path.count).map { ideal.path[$0].size.width })
        XCTAssertEqual(widths.count, 1, "gleichmaessige Breite")
        XCTAssertEqual(widths.first ?? 0, 2.5, accuracy: 0.01, "mittlere Breite des Originals (2 ... 3,5 und die Haltepunkte mit 2)")
        XCTAssertTrue(ideal.transform.isIdentity); XCTAssertNil(ideal.mask)
        // Ecken scharf: die Form fuehrt (fast) genau durch die vier Ecken
        let pts = ideal.path.interpolatedPoints(by: .distance(1)).map(\.location)
        for corner in [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100), CGPoint(x: 300, y: 200), CGPoint(x: 100, y: 200)] {
            XCTAssertTrue(pts.contains { hypot($0.x - corner.x, $0.y - corner.y) <= 3 }, "Ecke \(corner)")
        }
        // Speicherformat unveraendert: ein gewoehnlicher Strich fuer das Web
        var d = PKDrawing()
        d.strokes = [ideal]
        let page = StrokeConverter.update(from: d, previous: nil, state: InkPageState()).page
        let objects = try XCTUnwrap(page["objects"]?.array)
        XCTAssertEqual(objects.count, 1)
        XCTAssertEqual(objects[0]["type"]?.string, "stroke")
        XCTAssertEqual(objects[0]["tool"]?.string, "marker")
    }

    /// Auf der Zeichenflaeche: der gehaltene Strich wird zur Form, als ein Schritt im Verlauf (Rueckgaengig bringt die
    /// leere Seite, nicht den krummen Strich); ohne Halten bleibt er
    func testHeldStrokeBecomesTheShapeInOneUndoStep() async throws {
        let store = try await openStore()
        let editor = PDFEditorController(store: store)
        editor.loadViewIfNeeded()
        let overlay = try XCTUnwrap(editor.overlayForTesting(at: 0))
        try await wait("Seite geladen") { overlay.loaded }
        let circle = stroke(ellipsePoints(center: CGPoint(x: 200, y: 300), rx: 60, ry: 60), hold: 0.6)
        // wie PencilKit: Strich kommt waehrend `isDrawing` an, dann Absetzen
        editor.canvasViewDidBeginUsingTool(overlay.canvas)
        var d = overlay.canvas.drawing
        d.strokes.append(circle)
        overlay.canvas.drawing = d
        editor.canvasViewDrawingDidChange(overlay.canvas)
        XCTAssertTrue(overlay.undoPending)
        editor.canvasViewDidEndUsingTool(overlay.canvas)
        XCTAssertEqual(overlay.canvas.drawing.strokes.count, 1)
        let shaped = try XCTUnwrap(overlay.canvas.drawing.strokes.first)
        XCTAssertNotEqual(shaped.path.count, circle.path.count, "durch die ideale Form ersetzt")
        let pts = shaped.path.interpolatedPoints(by: .distance(2)).map(\.location)
        let maxErr = pts.map { abs(hypot($0.x - 200, $0.y - 300) - 60) }.max() ?? 99
        XCTAssertLessThanOrEqual(maxErr, 1.5, "idealer Kreis")
        XCTAssertTrue(editor.editUndo.canUndo)
        editor.editUndo.undo()
        XCTAssertEqual(overlay.canvas.drawing.strokes.count, 0, "ein Schritt: Strich und Form zusammen weg")
        editor.editUndo.redo()
        XCTAssertEqual(overlay.canvas.drawing.strokes.count, 1)
        XCTAssertEqual(overlay.canvas.drawing.strokes.first?.path.count, shaped.path.count, "Wiederholen bringt die Form")
        // ohne Halten bleibt der Strich, wie er ist
        let quick = stroke(along([CGPoint(x: 100, y: 500), CGPoint(x: 300, y: 500)], closed: false), created: Date())
        editor.canvasViewDidBeginUsingTool(overlay.canvas)
        d = overlay.canvas.drawing
        d.strokes.append(quick)
        overlay.canvas.drawing = d
        editor.canvasViewDrawingDidChange(overlay.canvas)
        XCTAssertNil(editor.snapShape(on: overlay, endedAt: quick.path.creationDate.addingTimeInterval(0.3)))
        editor.canvasViewDidEndUsingTool(overlay.canvas)
        XCTAssertEqual(overlay.canvas.drawing.strokes.last?.path.count, quick.path.count, "nicht angefasst")
        // gespeichert wird die Form (Store kennt den getauschten Strich)
        let saved = await store.drawing(forPageKey: overlay.pageKey)
        XCTAssertEqual(saved.strokes.count, 2)
        XCTAssertEqual(saved.strokes.first?.path.count, shaped.path.count)
    }

    func testShapeSnapCanBeSwitchedOff() async throws {
        UserDefaults.standard.set(false, forKey: "uniflow.shapeSnap")
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: "uniflow.shapeSnap") }
        let store = try await openStore()
        let editor = PDFEditorController(store: store)
        editor.loadViewIfNeeded()
        XCTAssertFalse(editor.shapeSnapEnabled)
        let overlay = try XCTUnwrap(editor.overlayForTesting(at: 0))
        try await wait("Seite geladen") { overlay.loaded }
        let line = stroke(along([CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100)], closed: false), hold: 0.6)
        editor.canvasViewDidBeginUsingTool(overlay.canvas)
        var d = overlay.canvas.drawing
        d.strokes.append(line)
        overlay.canvas.drawing = d
        editor.canvasViewDrawingDidChange(overlay.canvas)
        XCTAssertNil(editor.snapShape(on: overlay, endedAt: Date()))
    }

    // MARK: E) Seitenleiste

    func testAppendTemplateFollowsTheLastPage() {
        XCTAssertEqual(PageSidebarActions.appendTemplate(lastEntry: nil), "blank")
        XCTAssertEqual(PageSidebarActions.appendTemplate(lastEntry: .init(key: "p3", kind: "pdf", template: nil, pdfIndex: 3)), "blank",
                       "nach einer PDF-Seite eine leere Seite")
        XCTAssertEqual(PageSidebarActions.appendTemplate(lastEntry: .init(key: "bx", kind: "blank", template: "lined", pdfIndex: nil)), "lined")
        XCTAssertEqual(PageSidebarActions.appendTemplate(lastEntry: .init(key: "bx", kind: "blank", template: "foo", pdfIndex: nil)), "blank",
                       "unbekannte Vorlage: leer")
    }

    func testSidebarMenuItems() {
        XCTAssertEqual(PageSidebarActions.items(hasOutline: false, pageCount: 3), [.insertBefore, .insertAfter, .rotate, .bookmark, .trash])
        XCTAssertEqual(PageSidebarActions.items(hasOutline: true, pageCount: 3), [.insertBefore, .insertAfter, .rotate, .bookmark, .outline, .trash])
        XCTAssertEqual(PageSidebarActions.items(hasOutline: true, pageCount: 1), [.insertBefore, .insertAfter, .rotate, .bookmark, .outline],
                       "die letzte Seite bleibt")
    }

    /// "+" haengt eine Seite wie die letzte an; Papierkorb aus der Leiste ist rueckgaengig machbar (Palette)
    func testAppendAndTrashFromTheSidebarAreUndoable() async throws {
        try ContainerTestBed.requireEventGroupedUndo()
        let store = try await openStore()
        let editor = PDFEditorController(store: store)
        editor.loadViewIfNeeded()
        let before = editor.pageCount
        let appended = await editor.appendBlankPage(template: PageSidebarActions.appendTemplate(lastEntry: store.layout?.entries.last))
        let added = try XCTUnwrap(appended)
        XCTAssertEqual(editor.pageCount, before + 1)
        XCTAssertEqual(store.layout?.entries.last?.key, added)
        XCTAssertEqual(store.layout?.entries.last?.template, "blank")
        let linedAppended = await editor.appendBlankPage(template: "lined")
        let lined = try XCTUnwrap(linedAppended)
        XCTAssertEqual(PageSidebarActions.appendTemplate(lastEntry: store.layout?.entries.last), "lined", "naechstes '+' wie die letzte")

        let trashed = await editor.trashPage(key: lined, undoable: true)
        XCTAssertTrue(trashed)
        XCTAssertEqual(editor.pageCount, before + 1)
        XCTAssertEqual(editor.editUndo.undoActionName, "Seite in den Papierkorb")
        editor.editUndo.undo()
        try await wait("Seite zurueck") { editor.pageCount == before + 2 && store.layout?.index(ofKey: lined) != nil }
        XCTAssertTrue(editor.editUndo.canRedo)
        editor.editUndo.redo()
        try await wait("wieder im Papierkorb") { editor.pageCount == before + 1 }
        let bin = await editor.trashedPages()
        XCTAssertTrue(bin.contains { $0.key == lined })
        // ohne `undoable` (Verlaufsschritte "Seite einfuegen") kein eigener Schritt: Rueckgaengig holt weiter `lined`
        let plain = await editor.trashPage(key: added)
        XCTAssertTrue(plain)
        XCTAssertEqual(editor.pageCount, before)
        editor.editUndo.undo()
        try await wait("lined zurueck, added bleibt im Papierkorb") {
            store.layout?.index(ofKey: lined) != nil && store.layout?.index(ofKey: added) == nil
        }
    }

    // MARK: K) Als Karteikarte

    func testFlashcardTextFromTheSelection() {
        XCTAssertNil(PDFEditorController.flashcardText(nil))
        XCTAssertNil(PDFEditorController.flashcardText("  \n "))
        XCTAssertEqual(PDFEditorController.flashcardText("Satz des\nPythagoras  "), "Satz des Pythagoras")
    }

    func testFlashcardPrefillUsesTheDocumentsModuleAndFile() {
        let modules: [JSONValue] = [["id": 7, "name": "Analysis"]]
        let files: [JSONValue] = [["id": "f1", "title": "Skript", "module_id": 7]]
        let p = FlashcardCreateDialog.prefill(question: " a² + b² = c² ", moduleID: 7, fileID: "f1", modules: modules, files: files)
        XCTAssertEqual(p.question, "a² + b² = c²")
        XCTAssertEqual(p.module, 7)
        XCTAssertEqual(p.file, "f1")
        // Datei unbekannt (noch nicht in der Bibliothek): nur das Modul
        let q = FlashcardCreateDialog.prefill(question: "x", moduleID: 7, fileID: "f9", modules: modules, files: files)
        XCTAssertEqual(q.module, 7); XCTAssertEqual(q.file, "")
        // weder Modul noch Datei bekannt: "– keins –"
        let r = FlashcardCreateDialog.prefill(question: "x", moduleID: 3, fileID: nil, modules: modules, files: files)
        XCTAssertEqual(r.module, 0); XCTAssertEqual(r.file, "")
    }

    func testFlashcardMenuAndBarNeedASelection() async throws {
        let store = try await openStore()
        let editor = PDFEditorController(store: store)
        editor.loadViewIfNeeded()
        let bridge = EditorBridge()
        bridge.controller = editor
        var received: [String] = []
        editor.onFlashcardFromSelection = { received.append($0) }
        XCTAssertNil(editor.flashcardAction(), "ohne Auswahl kein Menuepunkt")
        bridge.makeFlashcard()
        XCTAssertNil(bridge.flashcardRequest, "Leiste ohne Auswahl: nichts")

        let doc = try XCTUnwrap(editor.pdfView.document)
        editor.pdfView.currentSelection = try XCTUnwrap(doc.findString("Pythagoras", withOptions: []).first)
        XCTAssertTrue(editor.hasPDFSelection)
        let action = try XCTUnwrap(editor.flashcardAction())
        XCTAssertEqual(action.title, "Als Karteikarte")
        editor.flashcardFromSelection()                                  // was der Menuepunkt ausloest
        XCTAssertEqual(received, ["Pythagoras"], "Menuepunkt gibt den markierten Text weiter")
        bridge.makeFlashcard()
        XCTAssertEqual(bridge.flashcardRequest?.question, "Pythagoras", "Leiste 'Text markieren' ebenso")
        bridge.makeFlashcard("aus dem Menü")
        XCTAssertEqual(bridge.flashcardRequest?.question, "aus dem Menü")
    }

    // MARK: Text und Bereich an die KI-Hilfe (05.11.2026, Geraetetest des Inhabers)

    /// Markierter PDF-Text kommt als sichtbarer Anhang mit PDF-Seite in die KI-Hilfe: Menuepunkt "In KI-Hilfe einfügen"
    /// vor "Als Karteikarte", "KI fragen" an der Palette nimmt die Auswahl mit; ohne Auswahl oeffnen "KI fragen" und
    /// "KI erklärt" nur die KI-Hilfe (vorher geschah bei "KI erklärt" ohne Auswahl nichts)
    func testSelectionGoesIntoTheTutorWithItsPage() async throws {
        let store = try await openStore()
        let editor = PDFEditorController(store: store)
        editor.loadViewIfNeeded()
        let bridge = EditorBridge()
        bridge.controller = editor
        editor.onAskAI = { bridge.attachToTutor($0) }
        editor.onFlashcardFromSelection = { _ in }
        XCTAssertNil(editor.tutorAction(), "ohne Auswahl kein Menuepunkt")
        XCTAssertTrue(editor.selectionMenuActions().isEmpty)
        editor.askAIFromToolbar()
        XCTAssertEqual(bridge.askAIRequested, 1)
        XCTAssertNil(bridge.tutorAttachment)
        bridge.askTutor("explain")
        XCTAssertEqual(bridge.askAIRequested, 2, "KI erklärt ohne Auswahl oeffnet die KI-Hilfe")

        let doc = try XCTUnwrap(editor.pdfView.document)
        let hit = try XCTUnwrap(doc.findString("Pythagoras", withOptions: []).last)      // letzte Seite
        editor.pdfView.currentSelection = hit
        XCTAssertEqual(editor.selectionMenuActions().map(\.title), ["In KI-Hilfe einfügen", "Als Karteikarte"])
        editor.tutorFromSelection()                                      // was der Menuepunkt ausloest
        let a = try XCTUnwrap(bridge.tutorAttachment)
        XCTAssertEqual(a.kind, .selection)
        XCTAssertEqual(a.text, "Pythagoras")
        XCTAssertEqual(a.page, doc.pageCount, "Seite der Auswahl, nicht die angezeigte")
        XCTAssertEqual(a.title, "Markierter Text · Seite \(doc.pageCount)")
        bridge.tutorAttachment = nil
        editor.askAIFromToolbar()
        XCTAssertEqual(bridge.tutorAttachment?.text, "Pythagoras", "KI fragen nimmt die Auswahl mit")
        XCTAssertEqual(bridge.askAIRequested, 2)
        XCTAssertEqual(PDFEditorController.tutorText(String(repeating: "x", count: 5000))?.count, TutorAttachment.maxText)
    }

    /// Rahmen ziehen oder einkreisen: erster/letzter Punkt bzw. umschliessende Box
    func testAreaShapeRectangleOrLoop() {
        let drag = [CGPoint(x: 100, y: 100), CGPoint(x: 150, y: 140), CGPoint(x: 220, y: 180)]
        let r = ObjectEditing.areaShape(drag)
        XCTAssertFalse(r.loop)
        XCTAssertEqual(r.rect, CGRect(x: 100, y: 100, width: 120, height: 80))
        // Kreis um (300, 300) mit Radius 50, endet nahe am Anfang
        let circle = (0...20).map { i -> CGPoint in
            let t = Double(i) / 20 * 2 * .pi * 0.96
            return CGPoint(x: 300 + 50 * cos(t), y: 300 + 50 * sin(t))
        }
        let c = ObjectEditing.areaShape(circle)
        XCTAssertTrue(c.loop)
        XCTAssertEqual(c.rect.midX, 300, accuracy: 3)
        XCTAssertEqual(c.rect.width, 100, accuracy: 3)
        XCTAssertTrue(ObjectEditing.areaShape([]).rect.isNull)
    }

    /// Ausschnitt: Groesse = Bereich mal Faktor (hoechstens 4, laengste Seite hoechstens 1600 px), Inhalt aus PDF,
    /// Handschrift und Notizobjekten, Texterkennung; ganze Seite und gedrehte Seite ebenso
    func testAreaCaptureCropSizeContentAndText() async throws {
        let store = try await openStore()
        let editor = PDFEditorController(store: store)
        editor.loadViewIfNeeded()
        XCTAssertEqual(PDFEditorController.areaScale(CGSize(width: 300, height: 60)), 4)
        XCTAssertEqual(PDFEditorController.areaScale(CGSize(width: 595, height: 842)), 1600 / 842, accuracy: 0.0001)

        // Text "Satz des Pythagoras 1" steht bei (100, 200) in 20 pt
        let rect = CGRect(x: 80, y: 190, width: 320, height: 45)
        let a = try await XCTUnwrapAsync(await editor.captureArea(pageIndex: 0, rect: rect))
        XCTAssertEqual(a.kind, .area)
        XCTAssertEqual(a.page, 1)
        XCTAssertEqual(a.title, "Bereich · Seite 1")
        let img = try XCTUnwrap(a.image.flatMap(UIImage.init(data:)))
        XCTAssertEqual(img.size.width * img.scale, 1280, accuracy: 1, "320 pt mal 4")
        XCTAssertEqual(img.size.height * img.scale, 180, accuracy: 1)
        XCTAssertTrue(a.text.contains("Pythagoras"), "Texterkennung: \(a.text)")

        // ganze Seite: laengste Seite 1600 px
        let page = try await XCTUnwrapAsync(await editor.captureArea(pageIndex: 0, rect: nil, kind: .page))
        let full = try XCTUnwrap(page.image.flatMap(UIImage.init(data:)))
        XCTAssertEqual(full.size.height * full.scale, 1600, accuracy: 1)
        XCTAssertEqual(page.title, "Ganze Seite · Seite 1")

        // Notizobjekte gehoeren dazu (rote Form im Bereich) und Bereiche ausserhalb der Seite werden begrenzt
        let layout = try XCTUnwrap(store.layout)
        let pdfPage = try XCTUnwrap(layout.pdf.page(at: 0)), entry = try XCTUnwrap(layout.entry(at: 0))
        let shape = try XCTUnwrap(PageObjectEdit.shape(id: "s1", kind: "rect", from: (20, 20), to: (60, 60), color: "#e5322d", width: 6))
        let red = try XCTUnwrap(PDFEditorController.renderArea(page: pdfPage, entry: entry, objects: [shape], rect: CGRect(x: -40, y: -40, width: 100, height: 100)))
        XCTAssertEqual(red.size.width * red.scale, 240, accuracy: 1, "auf die Seite begrenzt: 60 pt mal 4")
        XCTAssertTrue(Self.hasReddish(red), "die Form ist im Bild")

        // gedrehte Seite: Breite und Hoehe getauscht
        let key = try XCTUnwrap(layout.key(at: 0))
        await store.rotatePage(key: key)
        try await wait("gedreht") { store.layout.map { PageRenderer.size(of: $0.pdf.page(at: 0)!).width > 800 } == true }
        editor.showLayout()
        let turned = try await XCTUnwrapAsync(await editor.captureArea(pageIndex: 0, rect: nil, kind: .page))
        let t = try XCTUnwrap(turned.image.flatMap(UIImage.init(data:)))
        XCTAssertEqual(t.size.width * t.scale, 1600, accuracy: 1, "quer: Breite ist die lange Seite")
        XCTAssertLessThan(t.size.height * t.scale, 1200)
    }

    private static func hasReddish(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage, let data = cg.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return false }
        let bpp = cg.bitsPerPixel / 8, row = cg.bytesPerRow
        for y in stride(from: 0, to: cg.height, by: 2) {
            for x in stride(from: 0, to: cg.width, by: 2) {
                let o = y * row + x * bpp
                let (r, g, b) = cg.bitmapInfo.contains(.byteOrder32Little) ? (p[o + 2], p[o + 1], p[o]) : (p[o], p[o + 1], p[o + 2])
                if r > 180, g < 90, b < 90 { return true }
            }
        }
        return false
    }

    private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }

    /// Leiste: "Bereich an KI" vorn unter unseren Objektwerkzeugen, "Auswählen" ohne Mauszeiger
    func testPaletteAreaItemAndClearSelectItem() {
        XCTAssertEqual(EditorPalette.customIDs.first, EditorPalette.areaID)
        XCTAssertEqual(EditorPalette.objectTool(for: EditorPalette.areaID), .area)
        XCTAssertEqual(EditorPalette.identifier(for: .area), EditorPalette.areaID)
        XCTAssertEqual(ObjectEditing.Tool.area.label, "Bereich an KI")
        XCTAssertNotEqual(ObjectEditing.Tool.select.systemImage, "cursorarrow", "kein Mauszeiger-Pfeil")
        XCTAssertNotNil(UIImage(systemName: ObjectEditing.Tool.select.systemImage))
        XCTAssertNotNil(UIImage(systemName: ObjectEditing.Tool.area.systemImage))
        XCTAssertEqual(EditorToolState.Tool.objectTools.first, .area)
        XCTAssertEqual(EditorToolState.Tool.select.title, "Auswählen")
        XCTAssertEqual(EditorToolState.Tool.area.title, "Bereich an KI")
    }

    /// "Bereich an KI" aus dem Menue geht auch ohne Schreiben im Tarif, ein Rahmen schickt den Ausschnitt in die Bruecke
    func testAreaToolWorksWithoutWritingAndSendsTheArea() async throws {
        let store = try await openStore()
        let editor = PDFEditorController(store: store)
        editor.loadViewIfNeeded()
        let bridge = EditorBridge()
        bridge.controller = editor
        editor.onAskAI = { bridge.attachToTutor($0) }
        var hints: [String] = []
        editor.onHint = { hints.append($0) }
        editor.canEdit = false
        editor.startAreaCapture()
        XCTAssertTrue(editor.objects.isActive, "auch ohne Schreiben")
        XCTAssertEqual(editor.objects.tool, .area)
        XCTAssertEqual(hints.last, ObjectEditing.areaHint)
        editor.sendArea(pageIndex: 0, rect: CGRect(x: 80, y: 190, width: 320, height: 45))
        try await wait("Anhang in der Bruecke") { bridge.tutorAttachment != nil }
        XCTAssertEqual(bridge.tutorAttachment?.kind, .area)
        XCTAssertNotNil(bridge.tutorAttachment?.image)
        editor.finishObjectTools()
        XCTAssertFalse(editor.objects.isActive)
    }
}
