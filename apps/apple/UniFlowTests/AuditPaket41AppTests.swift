import PDFKit
import PencilKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Audit 08.11.2026, Paket 41 (PDF-Editor, Apple Pencil, Datensicherheit), Bericht
/// docs/audit/AUDIT-2026-11-08-PAKET-41.md. Echter Weg wie in `EditorHardeningStep2Tests`: `DocumentStore` mit lokalem
/// Backend (SQLite) im Temp-Ordner, Editor ohne Fenster. Was nur der Stift am Geraet zeigt (Latenz, iOS beendet den
/// Prozess), steht im Bericht als Geraetetest. Alle Daten sind erfunden.
@MainActor
final class AuditPaket41AppTests: XCTestCase {

    // MARK: Aufbau

    struct Fixture {
        let root: URL
        let host: LocalBackendHost
        let api: APIClient
        let file: LibFile
    }

    private func makeFixture(pages: Int = 3) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-p41-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let host = LocalBackendHost(directory: root.appendingPathComponent("db", isDirectory: true),
                                    clock: .fixed(berlin: "2026-11-08T09:00:00")!)
        let backend = try await host.backend()
        let fileID = "p41-" + UUID().uuidString.prefix(8).lowercased()
        try await backend.context.database.transaction { c in
            try c.execute("INSERT OR IGNORE INTO courses(id, title, semester, subject, kind, created_at) VALUES (?,?,?,?,?,?)",
                          [.text("k-test"), .text("Testkurs"), .text("WiSe 2026/27"), .text("Testkurs"), .text("vorlesung"),
                           .text("2026-10-01T08:00:00")])
            try c.execute("INSERT INTO files(id, course_id, name, chdate, status, kind, downloaded_at) VALUES (?,?,?,?, 'neu', 'pdf', ?)",
                          [.text(fileID), .text("k-test"), .text("Skript.pdf"), .integer(1_792_000_000), .text("2026-11-08T08:00:00")])
        }
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
        let pdfURL = AppPaths.pdf(fileID, namespace: api.namespace, root: root)
        try FileManager.default.createDirectory(at: pdfURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Skript.pdf(pages: pages, .schlicht).write(to: pdfURL)
        try DocumentStore.stamp(try await api.value("/api/files/\(fileID)"))
            .write(to: pdfURL.appendingPathExtension("stand"), atomically: true, encoding: .utf8)
        let file = LibFile(id: fileID, name: "Skript.pdf", title: "Skript", kind: "pdf", module_id: nil, subject: "Testkurs",
                           doc_type: nil, ai_title: nil, sub_label: nil, downloaded_at: "2026-11-08T08:00:00", has_notes: nil,
                           page_count: pages, studip_folder: nil)
        return Fixture(root: root, host: host, api: api, file: file)
    }

    private func openStore(_ fx: Fixture, timing: SaveTiming = .standard) async -> DocumentStore {
        let store = DocumentStore(file: fx.file, api: fx.api, root: fx.root)
        store.saveTiming = timing
        await store.load()
        XCTAssertNil(store.errorMessage, store.errorMessage ?? "")
        return store
    }

    /// Journal so, wie ein Neustart nach dem Beenden durch iOS es laese (Dateien auf der Platte)
    private func journalDocument(_ fx: Fixture) throws -> AnnotationDocument? {
        let blobs = FileBlobStore(root: DataContainerLayout.Folder.journal.url(in: fx.root))
        guard let snap = try LocalJournal(store: blobs, documentID: fx.file.id, namespace: fx.api.namespace).load() else { return nil }
        return AnnotationDocument(rootMeta: snap.rootMeta, pages: snap.pages.mapValues(\.page))
    }

    private func strokes(_ doc: AnnotationDocument?, _ key: String) -> Int {
        (doc?.objects(page: key) ?? []).filter { $0["type"]?.string == "stroke" }.count
    }

    private func stroke(_ n: Int, color: UIColor = .black, width: CGFloat = 2) -> PKStroke {
        let x = 40 + CGFloat(n % 20) * 25, y = 100 + CGFloat(n / 20) * 30
        let s = Handschrift.line(from: CGPoint(x: x, y: y), to: CGPoint(x: x + 18, y: y + 4),
                                 created: Date(timeIntervalSinceReferenceDate: 797_000_000 + Double(n)))
        guard color != .black || width != 2 else { return s }
        return PKStroke(ink: PKInk(.pen, color: color), path: PKStrokePath(controlPoints: s.path.map {
            PKStrokePoint(location: $0.location, timeOffset: $0.timeOffset, size: CGSize(width: width, height: width),
                          opacity: 1, force: $0.force, azimuth: $0.azimuth, altitude: $0.altitude)
        }, creationDate: s.path.creationDate))
    }

    private func wait(_ what: String, timeout: Double = 10, _ cond: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline { if try await cond() { return }; try await Task.sleep(nanoseconds: 30_000_000) }
        XCTFail("Zeit abgelaufen: \(what)")
    }

    /// Strich wie vom Stift: Aufsetzen, Zeichnung aendert sich, Absetzen (Reihenfolge wie PencilKit). Danach eine
    /// Runde der Ereignisschleife: der Verlauf fasst sonst alles einer Runde zu einem Schritt zusammen (`groupsByEvent`).
    private func draw(_ s: PKStroke, on overlay: PageInkView, in editor: PDFEditorController) async throws {
        editor.canvasViewDidBeginUsingTool(overlay.canvas)
        var d = overlay.canvas.drawing
        d.strokes.append(s)
        overlay.canvas.drawing = d
        editor.canvasViewDrawingDidChange(overlay.canvas)
        editor.canvasViewDidEndUsingTool(overlay.canvas)
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    // MARK: P41-01 Hintergrund: jeder fertige Strich steht im Journal, unabhaengig vom Upload

    /// Striche, die noch auf ihre Pause warten (Pause 30 s, keine Obergrenze: ohne Hintergrund bliebe alles im
    /// Speicher). Der Wechsel in den Hintergrund schreibt sie ins Journal auf der Platte, ohne dass das Dokument
    /// geschlossen wird: ein danach von iOS beendeter Prozess findet sie beim naechsten Start dort.
    func testP41_01_BackgroundWritesEveryFinishedStrokeToTheJournal() async throws {
        let fx = try await makeFixture()
        let store = await openStore(fx, timing: SaveTiming(pause: 30, maxDelay: nil))
        var d = PKDrawing()
        for n in 0..<7 { d.strokes.append(stroke(n)); store.canvasChanged(pageKey: "p1", drawing: d) }
        var other = PKDrawing()
        other.strokes.append(stroke(40))
        store.canvasChanged(pageKey: "p3", drawing: other)
        XCTAssertEqual(strokes(try journalDocument(fx), "p1"), 0, "Gegenprobe: vor dem Hintergrund nur im Speicher")

        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        try await wait("Journal nach Hintergrund") { self.strokes(try self.journalDocument(fx), "p1") == 7 }
        XCTAssertEqual(strokes(try journalDocument(fx), "p3"), 1, "auch die zweite Seite")
        // Stand eines neuen Prozesses (Journal + Backend), ohne dass der alte Store geschlossen wurde
        store.setShown(false)
        let restarted = DocumentStore(file: fx.file, api: fx.api, root: fx.root)
        await restarted.load()
        let doc = await restarted.pageStructureDocument()
        XCTAssertEqual(strokes(doc, "p1"), 7)
        XCTAssertEqual(strokes(doc, "p3"), 1)
        await restarted.close()
    }

    // MARK: P41-04 Rueckgaengig/Wiederholen ueber mehrere Seiten, Seite verschieben, Papierkorb

    func testP41_04_UndoRedoAcrossPagesFollowsPageKeysAfterMoveAndRestore() async throws {
        let fx = try await makeFixture()
        let store = await openStore(fx)
        let editor = PDFEditorController(store: store)
        editor.loadViewIfNeeded()
        let o1 = try XCTUnwrap(editor.overlayForTesting(at: 0)), o2 = try XCTUnwrap(editor.overlayForTesting(at: 1))
        try await wait("Seiten geladen") { o1.loaded && o2.loaded }
        XCTAssertEqual([o1.pageKey, o2.pageKey], ["p1", "p2"])
        try await draw(stroke(0), on: o1, in: editor)
        try await draw(stroke(1), on: o2, in: editor)
        try await draw(stroke(2), on: o2, in: editor)

        // Seite 1 ans Ende: neuer Seitenaufbau, der Verlauf haengt am Schluessel
        let moved = await editor.movePage(key: "p1", to: .last)
        XCTAssertTrue(moved)
        XCTAssertEqual(store.layout?.index(ofKey: "p1"), 2)
        editor.undo()                                                  // letzter Strich auf p2
        try await wait("p2 hat 1 Strich") { await store.drawing(forPageKey: "p2").strokes.count == 1 }
        let p1Count = await store.drawing(forPageKey: "p1").strokes.count
        XCTAssertEqual(p1Count, 1, "p1 unberuehrt")
        editor.undo()                                                  // erster Strich auf p2
        editor.undo()                                                  // Strich auf p1 (jetzt an Stelle 3)
        try await wait("alles zurueck") {
            let a = await store.drawing(forPageKey: "p1").strokes.count
            let b = await store.drawing(forPageKey: "p2").strokes.count
            return a == 0 && b == 0
        }
        editor.redo()
        try await wait("p1 wieder da") { await store.drawing(forPageKey: "p1").strokes.count == 1 }
        let p2Count = await store.drawing(forPageKey: "p2").strokes.count
        XCTAssertEqual(p2Count, 0, "Wiederholen trifft p1, nicht die Seite an Stelle 1")

        // Papierkorb und zurueck: der Verlauf der Seite wurde verworfen (kein unsichtbares Rueckgaengig), die Striche bleiben
        let trashed = await editor.trashPage(key: "p1")
        XCTAssertTrue(trashed)
        let restored = await editor.restorePage(key: "p1")
        XCTAssertTrue(restored)
        let afterRestore = await store.drawing(forPageKey: "p1").strokes.count
        XCTAssertEqual(afterRestore, 1)
        editor.redo()                                                  // Wiederholen fuer p2 bleibt gueltig
        try await wait("p2 wieder 1") { await store.drawing(forPageKey: "p2").strokes.count == 1 }

        // nach dem erneuten Oeffnen derselbe Stand an derselben Stelle
        await store.close()
        let reopened = await openStore(fx)
        XCTAssertEqual(reopened.layout?.index(ofKey: "p1"), 2)
        let doc = await reopened.pageStructureDocument()
        XCTAssertEqual(strokes(doc, "p1"), 1)
        XCTAssertEqual(strokes(doc, "p2"), 1)
        await reopened.close()
    }

    // MARK: P41-07 Seitenstruktur, waehrend ein Strich noch nicht gesichert ist

    /// Strich auf Seite 1 (noch nicht umgerechnet: Pause 30 s), sofort danach Seite 1 ans Ende verschieben. Der Strich
    /// bleibt auf p1, p1 steht am Ende, und der Export dieser Seite zeigt ihn; die Seite, die jetzt vorn steht, nicht.
    func testP41_07_PendingStrokeStaysOnItsPageWhenPageMovesAndIsExported() async throws {
        let fx = try await makeFixture()
        let store = await openStore(fx, timing: SaveTiming(pause: 30, maxDelay: nil))
        let editor = PDFEditorController(store: store)
        editor.loadViewIfNeeded()
        let o1 = try XCTUnwrap(editor.overlayForTesting(at: 0))
        try await wait("Seite geladen") { o1.loaded }
        try await draw(stroke(5, color: .red, width: 14), on: o1, in: editor)
        let moved = await editor.movePage(key: "p1", to: .last)
        XCTAssertTrue(moved)
        XCTAssertEqual(store.layout?.key(at: 0), "p2")
        XCTAssertEqual(store.layout?.key(at: 2), "p1")
        let doc = await store.pageStructureDocument()
        XCTAssertEqual(strokes(doc, "p1"), 1)
        XCTAssertEqual(strokes(doc, "p2"), 0)

        let last = try await store.sharePayload(.page(2), loadImage: nil)
        let first = try await store.sharePayload(.page(0), loadImage: nil)
        XCTAssertTrue(Self.hasReddish(try Self.raster(last.pdf)), "Export der verschobenen Seite enthaelt den Strich")
        XCTAssertFalse(Self.hasReddish(try Self.raster(first.pdf)), "die jetzt erste Seite nicht")
        await store.close()
    }

    private static func raster(_ pdf: Data) throws -> UIImage {
        let doc = try XCTUnwrap(PDFDocument(data: pdf)), page = try XCTUnwrap(doc.page(at: 0))
        return page.thumbnail(of: CGSize(width: 595, height: 842), for: .cropBox)
    }

    private static func hasReddish(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage, let data = cg.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return false }
        let bpp = cg.bitsPerPixel / 8, row = cg.bytesPerRow
        for y in stride(from: 0, to: cg.height, by: 1) {
            for x in stride(from: 0, to: cg.width, by: 1) {
                let o = y * row + x * bpp
                let (r, g, b) = cg.bitmapInfo.contains(.byteOrder32Little) ? (p[o + 2], p[o + 1], p[o]) : (p[o], p[o + 1], p[o + 2])
                if r > 180, g < 90, b < 90 { return true }
            }
        }
        return false
    }

    // MARK: P41-Z1 Neuaufbau der Seiten, waehrend der Stift aufliegt

    /// Ein Neuaufbau des Seitenaufbaus (Seitenliste vom Server oder anderen Geraet geaendert, eingefuegte Browser-Seite
    /// fertig geladen) setzt `pdfView.document` neu und wirft alle Overlays weg. Liegt der Stift dabei auf, verschwindet
    /// die Zeichenflaeche unter ihm: PencilKit bricht den laufenden Strich ab, er ist verloren. Der Neuaufbau muss bis
    /// zum Absetzen warten und danach von selbst kommen.
    func testP41_Z1_LayoutRebuildWaitsUntilPencilIsLifted() async throws {
        let fx = try await makeFixture()
        let store = await openStore(fx)
        let editor = PDFEditorController(store: store)
        editor.loadViewIfNeeded()
        let o1 = try XCTUnwrap(editor.overlayForTesting(at: 0))
        try await wait("Seite geladen") { o1.loaded }
        let shown = editor.shownLayoutVersion

        editor.canvasViewDidBeginUsingTool(o1.canvas)               // Stift liegt auf
        await store.addBlankPage(afterKey: nil, template: "lined")    // Seitenliste aendert sich (wie vom Server)
        XCTAssertNotEqual(store.layoutVersion, shown, "neuer Seitenaufbau im Store")
        editor.showLayout()                                           // wie `updateUIViewController`
        XCTAssertEqual(editor.shownLayoutVersion, shown, "kein Neuaufbau unter dem Stift")
        XCTAssertTrue(editor.boundOverlay(forKey: "p1") === o1, "die Zeichenflaeche unter dem Stift bleibt")

        var d = o1.canvas.drawing
        d.strokes.append(stroke(3))
        o1.canvas.drawing = d
        editor.canvasViewDrawingDidChange(o1.canvas)
        editor.canvasViewDidEndUsingTool(o1.canvas)                 // Absetzen: jetzt neu aufbauen
        XCTAssertEqual(editor.shownLayoutVersion, store.layoutVersion, "nach dem Absetzen neu aufgebaut")
        XCTAssertEqual(editor.pageCount, 4)
        let doc = await store.pageStructureDocument()
        XCTAssertEqual(strokes(doc, "p1"), 1, "der Strich ist gespeichert")
        await store.close()
    }

    /// Gegenprobe: ohne aufliegenden Stift baut `showLayout` sofort neu auf (keine Verzoegerung im Normalfall)
    func testP41_Z1_LayoutRebuildIsImmediateWithoutPencil() async throws {
        let fx = try await makeFixture()
        let store = await openStore(fx)
        let editor = PDFEditorController(store: store)
        editor.loadViewIfNeeded()
        let o1 = try XCTUnwrap(editor.overlayForTesting(at: 0))
        try await wait("Seite geladen") { o1.loaded }
        await store.addBlankPage(afterKey: nil, template: "lined")
        editor.showLayout()
        XCTAssertEqual(editor.shownLayoutVersion, store.layoutVersion)
        XCTAssertEqual(editor.pageCount, 4)
        await store.close()
    }
    // MARK: P41-08 Export grosser Skripte (viele Seiten mit Bildern)

    /// Spitzenspeicher waehrend eines Vorgangs (wie in `HardeningExportTests`)
    private final class PeakMemory: @unchecked Sendable {
        private let lock = NSLock()
        private var peak: UInt64 = 0
        private var running = true

        static func footprint() -> UInt64 {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            return kr == KERN_SUCCESS ? info.phys_footprint : 0
        }

        func start() {
            Thread.detachNewThread { [self] in
                while true {
                    lock.lock()
                    let go = running
                    peak = max(peak, Self.footprint())
                    lock.unlock()
                    if !go { return }
                    usleep(5_000)
                }
            }
        }

        func stop() -> UInt64 {
            lock.lock()
            running = false
            peak = max(peak, Self.footprint())
            defer { lock.unlock() }
            return peak
        }
    }

    /// Skript mit `n` Seiten, jede mit einem eigenen Foto (Rauschen, JPEG, nicht wiederverwendbar): so gross wie ein
    /// echtes Folienskript mit Bildern. In eine Datei geschrieben (der Editor oeffnet die PDF von der Platte).
    private func imageHeavyPDF(pages n: Int, to url: URL) throws {
        let a4 = CGRect(x: 0, y: 0, width: 595, height: 842)
        var rng = SystemRandomNumberGenerator()
        try UIGraphicsPDFRenderer(bounds: a4).writePDF(to: url) { ctx in
            for i in 0..<n {
                autoreleasepool {
                    ctx.beginPage()
                    let side = 500
                    var bytes = [UInt8](repeating: 0, count: side * side * 4)
                    for k in stride(from: 0, to: bytes.count, by: 4) {
                        let v = UInt8.random(in: 0...255, using: &rng)
                        bytes[k] = v; bytes[k + 1] = v &+ UInt8(i % 200); bytes[k + 2] = 255 - v; bytes[k + 3] = 255
                    }
                    let cs = CGColorSpaceCreateDeviceRGB()
                    let cgctx = CGContext(data: &bytes, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: cs,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    let jpeg = UIImage(cgImage: cgctx.makeImage()!).jpegData(compressionQuality: 0.85)!
                    UIImage(data: jpeg)!.draw(in: CGRect(x: 40, y: 120, width: 515, height: 515))
                    ("Folie \(i + 1)" as NSString).draw(at: CGPoint(x: 40, y: 40), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 22)])
                }
            }
        }
    }

    /// 400 Seiten mit je einem eigenen Bild (~110 MB): der Export ist vollstaendig (alle Seiten), und der Spitzenzuwachs
    /// des Speichers bleibt ein fester Vielfacher der Ausgabe. Gemessen 08.11.2026 im Simulator: Ausgabe 110 MB, Spitze
    /// +308 MB, 2,3 s; ein Autorelease-Pool je Seite aendert daran nichts (+309 MB, geprueft und verworfen). Der Rest ist
    /// die Ausgabe im Speicher (`NSMutableData` waechst durch Umkopieren); Hochrechnung und Entscheidung im Bericht
    /// (Designfrage D2). Die Grenze faengt eine Verschlechterung ab, nicht den heutigen Stand.
    func testP41_08_LargeImageScriptExportIsCompleteAndMemoryBounded() throws {
        let n = 400
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("p41-gross-\(UUID().uuidString).pdf")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try imageHeavyPDF(pages: n, to: url)
        let inputMB = Double((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0) / 1_048_576
        let original = try XCTUnwrap(PDFDocument(url: url))
        let lay = DisplayLayout.build(original: original, document: AnnotationDocument(root: try JSONValue.parse(#"{"version":2,"pages":{},"pageOrder":[]}"#)))
        XCTAssertEqual(lay.entries.count, n)
        var notes: [String: JSONValue] = [:]
        for i in 0..<n {
            let s = try JSONValue.parse(##"{"id":"s\##(i)","type":"stroke","tool":"pen","color":"#e5322d","width":6,"opacity":1,"points":[60,700,300,720,500,700],"x":0,"y":0,"rotation":0,"scaleX":1,"scaleY":1}"##)
            notes["p\(i + 1)"] = .object(["objects": .array([s])])
        }
        let before = PeakMemory.footprint()
        let peak = PeakMemory()
        peak.start()
        let start = Date()
        let data = PDFExporter.render(layout: lay, pages: notes, images: [:], title: "Grosses Skript")
        let seconds = Date().timeIntervalSince(start)
        let top = peak.stop()
        let outMB = Double(data.count) / 1_048_576
        let growthMB = Double(top > before ? top - before : 0) / 1_048_576
        print("[P41-08] \(n) Seiten, Eingabe \(String(format: "%.1f", inputMB)) MB, Ausgabe \(String(format: "%.1f", outMB)) MB, Spitzenzuwachs \(String(format: "%.1f", growthMB)) MB, \(String(format: "%.1f", seconds)) s")
        XCTAssertEqual(CGPDFDocument(CGDataProvider(data: data as CFData)!)?.numberOfPages, n)
        XCTAssertLessThan(growthMB, outMB * 3.5 + 50, "Spitzenspeicher waehrend des Exports hoeher als gemessen")
        XCTAssertLessThan(seconds, 30, "Export dauert zu lange")
    }
}
