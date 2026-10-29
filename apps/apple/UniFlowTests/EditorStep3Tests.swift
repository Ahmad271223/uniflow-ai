import PDFKit
import PencilKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Editor, Schritt 3 (docs/PENCILKIT-ANALYSE-PLAN.md P0-7, P0-8):
/// - P0-7 Drehen ohne Verrutschen: Notizen und native Zeichnung drehen mit der Seite mit (gleiche Regel wie
///   app/static/pagerotate.js, Faelle in packages/shared-contracts/fixtures/rotate/cases.json).
/// - P0-8 Eine native Zeichnung, die dieses Geraet nicht lesen kann, wird beim Speichern nicht ueberschrieben.
/// Jede Pruefung hat eine Gegenprobe; alle Daten sind erfunden.
@MainActor
final class EditorStep3Tests: XCTestCase {

    private func line(_ a: CGPoint, _ b: CGPoint, _ n: Int = 0) -> PKStroke {
        Handschrift.line(from: a, to: b, created: Date(timeIntervalSinceReferenceDate: 797_000_000 + Double(n)))
    }

    private func center(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }

    private func cg(_ t: SolutionAffine) -> CGAffineTransform { CGAffineTransform(a: t.a, b: t.b, c: t.c, d: t.d, tx: t.tx, ty: t.ty) }

    // MARK: P0-7 native Zeichnung

    /// Ein Stift-Strich (mit `pkdrawing`) auf A4 hoch, Seite um 90 Grad gedreht: die Objekte liegen gedreht, die
    /// native Zeichnung ist mitgedreht und bleibt gueltig (Pinselbild, echte Erstellzeit statt Neuaufbau), und beide
    /// liegen an derselben Stelle. Gegenprobe: ohne Mitdrehen der Zeichnung passt sie nicht mehr und wird verworfen.
    func testRotatedNativeDrawingStaysValidAndOnTheObjects() throws {
        var d = PKDrawing()
        d.strokes.append(line(CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 150)))
        let page = StrokeConverter.page(from: d, previous: ["objects": []], state: InkPageState()).0
        var doc = AnnotationDocument.empty()
        doc.pages = ["p1": page]
        doc.root["pageOrder"] = [["key": "p1", "type": "pdf", "index": 1]]
        let before = doc.objects(page: "p1")
        XCTAssertEqual(PageOrder.rotate(&doc, key: "p1", shownWidth: 595, shownHeight: 842)?.changedPageKeys, ["p1"])
        let t = cg(PageRotation.transform(width: 595, height: 842))
        let rotated = StrokeConverter.rotatedNative(page: try XCTUnwrap(doc.page("p1")), objectsBefore: before, transform: t)

        let (loaded, state) = StrokeConverter.drawing(fromPage: rotated)
        XCTAssertEqual(loaded.strokes.count, 1)
        XCTAssertFalse(CreationSlots.isSynthetic(loaded.strokes[0].path.creationDate), "native Zeichnung verwendet")
        XCTAssertFalse(state.keepsForeignNative)
        let expected = center(d.transformed(using: t).bounds)
        XCTAssertEqual(center(loaded.bounds).x, expected.x, accuracy: 0.5)
        XCTAssertEqual(center(loaded.bounds).y, expected.y, accuracy: 0.5)
        // die gedrehten Objekte zeigen dieselbe Stelle (aus dem JSON aufgebaut)
        let fromObjects = StrokeConverter.rebuild(objects: rotated["objects"]?.array ?? []).0
        XCTAssertEqual(center(fromObjects.bounds).x, expected.x, accuracy: 3)
        XCTAssertEqual(center(fromObjects.bounds).y, expected.y, accuracy: 3)
        XCTAssertEqual(expected.x, 842 - 125, accuracy: 3, "(x, y) -> (H - y, x)")
        XCTAssertEqual(expected.y, 150, accuracy: 3)

        // Gegenprobe: Objekte gedreht, Zeichnung nicht -> Signatur passt nicht, Aufbau aus dem JSON
        let stale = StrokeConverter.drawing(fromPage: try XCTUnwrap(doc.page("p1"))).0
        XCTAssertTrue(CreationSlots.isSynthetic(stale.strokes[0].path.creationDate))
    }

    /// Ein schon vor dem Drehen veralteter nativer Strich (im Browser geaendert) wird durch das Drehen nicht wieder
    /// gueltig: seine Signatur bleibt die alte, der Strich wird aus dem JSON aufgebaut.
    func testStaleNativeStrokeStaysStaleAfterRotation() throws {
        var d = PKDrawing()
        d.strokes.append(line(CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 150)))
        var page = StrokeConverter.page(from: d, previous: ["objects": []], state: InkPageState()).0
        var objects = page["objects"]?.array ?? []
        objects[0]["color"] = "#00ff00"                                         // Browser hat die Farbe geaendert
        page["objects"] = .array(objects)
        var doc = AnnotationDocument.empty()
        doc.pages = ["p1": page]
        doc.root["pageOrder"] = [["key": "p1", "type": "pdf", "index": 1]]
        let before = doc.objects(page: "p1")
        PageOrder.rotate(&doc, key: "p1", shownWidth: 595, shownHeight: 842)
        let rotated = StrokeConverter.rotatedNative(page: try XCTUnwrap(doc.page("p1")), objectsBefore: before,
                                                    transform: cg(PageRotation.transform(width: 595, height: 842)))
        let loaded = StrokeConverter.drawing(fromPage: rotated).0
        XCTAssertTrue(CreationSlots.isSynthetic(loaded.strokes[0].path.creationDate), "veraltet bleibt veraltet")
    }

    // MARK: P0-8 fremde native Zeichnung

    /// Native Zeichnung eines neueren Formats, die dieses Geraet nicht lesen kann: angezeigt wird der Aufbau aus
    /// den Objekten, und beim Speichern eines neuen Strichs bleibt das Feld `pkdrawing` bytegleich. Gegenprobe: eine
    /// lesbare Zeichnung wird wie bisher durch die neue ersetzt.
    func testUnreadableNativeDrawingIsPassedThroughOnSave() throws {
        var browser = PKDrawing()
        browser.strokes.append(line(CGPoint(x: 50, y: 50), CGPoint(x: 90, y: 60)))
        let objects = StrokeConverter.page(from: browser, previous: ["objects": []], state: InkPageState()).0["objects"] ?? []
        let foreign: JSONValue = ["data": "bmV1ZXJlcyBGb3JtYXQ=", "objectsSig": "x", "format": "pkdrawing-v9", "zukunft": ["a": 1]]
        let page: JSONValue = ["objects": objects, "pkdrawing": foreign]

        let (shown, state) = StrokeConverter.drawing(fromPage: page)
        XCTAssertTrue(state.keepsForeignNative)
        XCTAssertEqual(shown.strokes.count, 1, "aus den Objekten aufgebaut")
        var next = shown
        next.strokes.append(line(CGPoint(x: 300, y: 300), CGPoint(x: 350, y: 320), 1))
        let saved = StrokeConverter.update(from: next, previous: page, state: state)
        XCTAssertEqual(saved.page["pkdrawing"], foreign, "fremde Zeichnung unveraendert")
        XCTAssertEqual(saved.page["objects"]?.array?.count, 2, "neuer Strich als Objekt gespeichert")
        XCTAssertTrue(saved.state.keepsForeignNative, "bleibt fuer die naechste Runde")

        // Kaputte Daten im bekannten Format sind nicht fremd: sie werden ersetzt (AuditRunde11PencilTests)
        let broken: JSONValue = ["objects": objects, "pkdrawing": ["data": "QUJD", "objectsSig": "x", "format": "pkdrawing-v2",
                                                                   "strokeIds": [["a"]], "strokeSigs": ["b"]]]
        let (brokenShown, brokenState) = StrokeConverter.drawing(fromPage: broken)
        XCTAssertFalse(brokenState.keepsForeignNative)
        XCTAssertNotEqual(StrokeConverter.update(from: brokenShown, previous: broken, state: brokenState).page["pkdrawing"], broken["pkdrawing"])
        XCTAssertFalse(StrokeConverter.isForeign(["data": "", "objectsSig": "x"]), "v1 ohne Daten: kaputt, nicht fremd")
        XCTAssertTrue(StrokeConverter.isForeign(["format": "pkdrawing-v3"]), "unbekanntes Format: fremd")

        // Gegenprobe: lesbare Zeichnung wird ersetzt
        let own = StrokeConverter.page(from: browser, previous: ["objects": []], state: InkPageState()).0
        let (ownShown, ownState) = StrokeConverter.drawing(fromPage: own)
        XCTAssertFalse(ownState.keepsForeignNative)
        var more = ownShown
        more.strokes.append(line(CGPoint(x: 300, y: 300), CGPoint(x: 350, y: 320), 1))
        let replaced = StrokeConverter.update(from: more, previous: own, state: ownState)
        XCTAssertNotEqual(replaced.page["pkdrawing"], own["pkdrawing"])
        XCTAssertEqual(StoredDrawing(page: replaced.page)?.strokeIDs.count, 2)
    }

    /// Eine Seite ohne `pkdrawing` (nur im Browser beschrieben) ist nicht fremd: die erste Runde legt die Zeichnung an.
    func testPageWithoutNativeDrawingIsNotForeign() {
        let (_, state) = StrokeConverter.drawing(fromPage: ["objects": []])
        XCTAssertFalse(state.keepsForeignNative)
        var d = PKDrawing()
        d.strokes.append(line(CGPoint(x: 10, y: 10), CGPoint(x: 40, y: 20)))
        XCTAssertNotNil(StrokeConverter.update(from: d, previous: ["objects": []], state: state).page["pkdrawing"])
    }

    /// Lesbar ist hoechstens die Inhaltsversion des laufenden iPadOS, nicht die des SDK.
    func testSupportedContentVersionFollowsTheRunningSystem() {
        let v = StrokeConverter.supportedContentVersion
        XCTAssertGreaterThanOrEqual(v, 2)
        XCTAssertLessThanOrEqual(v, PKContentVersion.latest.rawValue)
        if #available(iOS 27.0, *) { XCTAssertEqual(v, 5) }
    }

    // MARK: P0-7 im echten Weg

    /// Text und Stift-Strich auf Seite 1, Seite im Editor gedreht: im gespeicherten Stand drehen Text und Strich mit,
    /// die Seite steht auf 90 Grad, und die native Zeichnung ist weiter gueltig. Zweimal gedreht = 180 Grad.
    func testRotatePageInTheStoreTurnsNotesAndDrawing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-schritt3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let host = LocalBackendHost(directory: root.appendingPathComponent("db", isDirectory: true), clock: .fixed(berlin: "2026-10-29T09:00:00")!)
        let backend = try await host.backend()
        let fileID = "schritt3-" + UUID().uuidString.prefix(8).lowercased()
        try await backend.context.database.transaction { c in
            try c.execute("INSERT OR IGNORE INTO courses(id, title, semester, subject, kind, created_at) VALUES (?,?,?,?,?,?)",
                          [.text("k-test"), .text("Testkurs"), .text("WiSe 2026/27"), .text("Testkurs"), .text("vorlesung"),
                           .text("2026-10-01T08:00:00")])
            try c.execute("INSERT INTO files(id, course_id, name, chdate, status, kind, downloaded_at) VALUES (?,?,?,?, 'neu', 'pdf', ?)",
                          [.text(fileID), .text("k-test"), .text("Testblatt.pdf"), .integer(1_792_000_000), .text("2026-10-29T08:00:00")])
        }
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
        let pdfURL = AppPaths.pdf(fileID, namespace: api.namespace, root: root)
        try FileManager.default.createDirectory(at: pdfURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Skript.pdf(pages: 2, .schlicht).write(to: pdfURL)
        try DocumentStore.stamp(try await api.value("/api/files/\(fileID)")).write(to: pdfURL.appendingPathExtension("stand"), atomically: true, encoding: .utf8)
        let file = LibFile(id: fileID, name: "Testblatt.pdf", title: "Testblatt", kind: "pdf", module_id: nil, subject: "Testkurs",
                           doc_type: nil, ai_title: nil, sub_label: nil, downloaded_at: "2026-10-29T08:00:00", has_notes: nil,
                           page_count: 2, studip_folder: nil)
        let store = DocumentStore(file: file, api: api, root: root)
        await store.load()
        XCTAssertNil(store.errorMessage, store.errorMessage ?? "")
        let shown = try XCTUnwrap(store.layout?.pdf.page(at: 0)).bounds(for: .cropBox).size

        await store.addText("Notiz", pageKey: "p1")
        var d = PKDrawing()
        d.strokes.append(line(CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 150)))
        store.canvasChanged(pageKey: "p1", drawing: d)
        await store.rotatePage(key: "p1")                                   // verarbeitet den ausstehenden Strich zuerst
        await store.close()

        let row = try await backend.context.database.rows("SELECT data FROM annotations WHERE file_id=?", [.text(fileID)]).first
        let doc = AnnotationDocument(root: try JSONValue.parse(Data(try XCTUnwrap(row?["data"]?.string).utf8)))
        XCTAssertEqual(doc.pageOrder.first?["rotation"]?.int, 90)
        XCTAssertEqual(doc.pageOrder.dropFirst().first?["rotation"]?.int ?? 0, 0, "Gegenprobe: Seite 2 unveraendert")
        let objects = doc.objects(page: "p1")
        let text = try XCTUnwrap(objects.first { $0["type"]?.string == "text" })
        XCTAssertEqual(text["x"]?.double, Double(shown.height) - 40, "(x, y) -> (H - y, x)")
        XCTAssertEqual(text["y"]?.double, 40)
        XCTAssertEqual(text["rotation"]?.double, 90)
        let stroke = try XCTUnwrap(objects.first { $0["type"]?.string == "stroke" })
        XCTAssertEqual(stroke["rotation"]?.double, 90)
        let (loaded, state) = StrokeConverter.drawing(fromPage: doc.page("p1"))
        XCTAssertFalse(state.keepsForeignNative)
        XCTAssertEqual(loaded.strokes.count, 1)
        XCTAssertFalse(CreationSlots.isSynthetic(loaded.strokes[0].path.creationDate), "native Zeichnung mitgedreht")
        XCTAssertEqual(center(loaded.bounds).x, Double(shown.height) - 125, accuracy: 3)
        XCTAssertEqual(center(loaded.bounds).y, 150, accuracy: 3)
    }
}
