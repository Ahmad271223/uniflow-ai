import PDFKit
import PencilKit
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Schreibgefuehl mit dem Apple Pencil (Auftrag des Inhabers 13.11.2026): vorher/nachher im selben Lauf, je Punkt mit
/// der Gegenprobe aus `PencilTuning` (Schalter aus = so war es vorher). Gemessen wird, was der Simulator ehrlich
/// zeigen kann: Arbeit auf dem Hauptthread und wie oft gesichert bzw. SwiftUI benachrichtigt wird. Latenz des Stifts,
/// Vorhersage, Handballen und das Gefuehl beim Pinchen sind nur am iPad mit Pencil pruefbar.
///
/// Zeilen "[Stift]" im Testprotokoll sind die Messwerte (docs/STARTSEITE-REITER-STIFT-2026-11-13.md).
@MainActor
final class PencilFeelTests: XCTestCase {

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: PencilSmoothing.key)
        PencilTuning.saveOnLift = true
        PencilTuning.rescaleVisibleOnly = true
        PencilTuning.throttleZoomPublish = true
    }

    // MARK: Radierer auf einer vollen Seite

    /// Radierer ueber eine Seite mit 300 Strichen, 40 Striche weg in einem Zug. Vorher: jede Zwischenmeldung sicherte
    /// die ganze Seite (umrechnen und auf die Platte, Hauptthread). Nachher: einmal beim Absetzen. Nichts geht verloren.
    func testEraserOnADensePageSavesOnceOnLift() async throws {
        var report: [String] = []
        for after in [false, true] {
            PencilTuning.saveOnLift = after
            let fx = try await makeFixture(pdf: Skript.pdf(pages: 3, .schlicht), pageCount: 3)
            let store = try await openStore(fx)
            let shown = show(store)
            defer { hide(shown) }
            let editor = shown.editor
            let overlay = try await waitForOverlay(editor, page: 0, timeout: 20)
            apply(Handschrift.page(0, strokes: 300), to: overlay)
            editor.canvasViewDrawingDidChange(overlay.canvas)               // ohne Stift: sofort gesichert
            await store.flush()

            let saves0 = editor.canvasSaves, writes0 = store.inkDraftWrites
            var mainSeconds = 0.0, longest = 0.0
            editor.canvasViewDidBeginUsingTool(overlay.canvas)
            for _ in 0..<40 {
                var d = overlay.canvas.drawing
                d.strokes.removeFirst()
                apply(d, to: overlay)
                let t = Uhr.now()
                editor.canvasViewDrawingDidChange(overlay.canvas)           // PencilKit meldet jede geloeschte Stelle
                let s = Uhr.since(t)
                mainSeconds += s
                longest = max(longest, s)
                try await Task.sleep(nanoseconds: 8_000_000)                // Radierer bewegt sich weiter
            }
            let t = Uhr.now()
            editor.canvasViewDidEndUsingTool(overlay.canvas)
            let lift = Uhr.since(t)
            let saves = editor.canvasSaves - saves0, writes = store.inkDraftWrites - writes0
            report.append(String(format: "%@: %d Sicherungen, %d Plattenschreibvorgaenge, Hauptthread waehrend des Radierens %.1f ms (laengste Meldung %.1f ms), Absetzen %.1f ms",
                                 after ? "nachher" : "vorher", saves, writes, mainSeconds * 1000, longest * 1000, lift * 1000))
            if after {
                XCTAssertEqual(saves, 1, "einmal beim Absetzen")
                XCTAssertLessThan(mainSeconds, 0.02, "waehrend des Radierens fast nichts auf dem Hauptthread")
            } else {
                XCTAssertEqual(saves, 40, "Gegenprobe: vorher jede Meldung")
            }
            // nichts verloren: nach dem Sichern stehen 260 Striche im Store, auch nach erneutem Oeffnen
            await store.flush()
            let objects = await store.objects(forPageKey: "p1")
            XCTAssertEqual(objects.filter { $0["type"]?.string == "stroke" }.count, 260, after ? "nachher" : "vorher")
            await store.close()
            let again = try await openStore(fx)
            let reopened = await again.objects(forPageKey: "p1")
            XCTAssertEqual(reopened.filter { $0["type"]?.string == "stroke" }.count, 260, "nach dem Neuoeffnen")
            await again.close()
        }
        print("[Stift] Radierer, 40 Striche auf einer Seite mit 300:\n  " + report.joined(separator: "\n  "))
    }

    /// Ein normaler Stiftstrich wird weiter genau einmal gesichert, sofort beim Absetzen (Audit P60/P61 unveraendert)
    func testPenStrokeIsSavedOnceAtTheLift() async throws {
        let fx = try await makeFixture(pdf: Skript.pdf(pages: 2, .schlicht), pageCount: 2)
        let store = try await openStore(fx)
        let shown = show(store)
        defer { hide(shown) }
        let editor = shown.editor
        let overlay = try await waitForOverlay(editor, page: 0, timeout: 20)
        let writes0 = store.inkDraftWrites
        editor.canvasViewDidBeginUsingTool(overlay.canvas)
        var d = overlay.canvas.drawing
        d.strokes.append(Handschrift.line(from: CGPoint(x: 80, y: 300), to: CGPoint(x: 300, y: 340)))
        apply(d, to: overlay)
        editor.canvasViewDrawingDidChange(overlay.canvas)
        XCTAssertEqual(store.inkDraftWrites, writes0, "Stift liegt noch auf: noch nicht gesichert")
        editor.canvasViewDidEndUsingTool(overlay.canvas)
        XCTAssertEqual(store.inkDraftWrites, writes0 + 1, "beim Absetzen sofort auf der Platte")
        await store.flush()
        let objects = await store.objects(forPageKey: "p1")
        XCTAssertEqual(objects.filter { $0["type"]?.string == "stroke" }.count, 1)
        await store.close()
    }

    // MARK: Glaettung "Aus"

    /// Glaettung "Aus": beim Absetzen wird der Strich aus den Messpunkten neu gebaut, einmal gesichert, ein
    /// Rueckgaengig-Schritt holt alles zurueck. Mit Lineal bleibt der Strich von PencilKit.
    func testSmoothingOffRebuildsTheStrokeFromRawPointsOnLift() async throws {
        UserDefaults.standard.set(PencilSmoothing.off.rawValue, forKey: PencilSmoothing.key)
        defer { UserDefaults.standard.removeObject(forKey: PencilSmoothing.key) }
        let fx = try await makeFixture(pdf: Skript.pdf(pages: 2, .schlicht), pageCount: 2)
        let store = try await openStore(fx)
        let shown = show(store)
        defer { hide(shown) }
        let editor = shown.editor
        let overlay = try await waitForOverlay(editor, page: 0, timeout: 20)
        var samples: [RawPencilSample] = []
        for i in 0..<90 {
            let t = CGFloat(i)
            let jitter: CGFloat = i % 2 == 0 ? 0.25 : -0.25
            let y: CGFloat = 300 + sin(t / 7) * 15 + jitter
            samples.append(RawPencilSample(location: CGPoint(x: 80 + t * 2, y: y), time: 500 + Double(i) / 240))
        }
        let pk = PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: stride(from: 0, to: 90, by: 5).map { i in
            PKStrokePoint(location: samples[i].location, timeOffset: Double(i) / 240, size: CGSize(width: 2.5, height: 2.5), opacity: 1,
                          force: 0.8, azimuth: 0.5, altitude: 1.2)
        }, creationDate: Date()))
        let writes0 = store.inkDraftWrites
        editor.canvasViewDidBeginUsingTool(overlay.canvas)
        var d = overlay.canvas.drawing
        d.strokes.append(pk)
        apply(d, to: overlay)
        overlay.rawRecorder.setSamplesForTesting(samples)
        editor.canvasViewDrawingDidChange(overlay.canvas)
        editor.canvasViewDidEndUsingTool(overlay.canvas)
        XCTAssertEqual(editor.rawRebuilds, 1)
        let stroke = try XCTUnwrap(overlay.canvas.drawing.strokes.last)
        XCTAssertEqual(stroke.path.count, 90, "ein Kontrollpunkt je Messpunkt")
        let p = stroke.path.interpolatedLocation(at: 45)
        XCTAssertEqual(p.y, samples[45].location.y, accuracy: 0.01, "genau durch den Messpunkt")
        XCTAssertEqual(store.inkDraftWrites, writes0 + 1, "einmal gesichert, beim Absetzen")
        await store.flush()
        let saved = await store.objects(forPageKey: "p1")
        XCTAssertEqual(saved.filter { $0["type"]?.string == "stroke" }.count, 1)
        editor.editUndo.undo()
        XCTAssertTrue(overlay.canvas.drawing.strokes.isEmpty, "ein Rueckgaengig-Schritt fuer Strich und Neubau")

        // mit Lineal: Strich von PencilKit bleibt (das Lineal macht ihn gerade)
        overlay.canvas.isRulerActive = true
        editor.canvasViewDidBeginUsingTool(overlay.canvas)
        var r = overlay.canvas.drawing
        r.strokes.append(pk)
        apply(r, to: overlay)
        overlay.rawRecorder.setSamplesForTesting(samples)
        editor.canvasViewDrawingDidChange(overlay.canvas)
        editor.canvasViewDidEndUsingTool(overlay.canvas)
        XCTAssertEqual(editor.rawRebuilds, 1, "mit Lineal kein Neubau")
        XCTAssertEqual(overlay.canvas.drawing.strokes.last?.path.count, pk.path.count)
        overlay.canvas.isRulerActive = false
        await store.close()
    }

    // MARK: Zoomen

    /// Pinchen wie mit zwei Fingern: 30 Bilder lang waechst der Zoom, danach Ruhe. Vorher: jede Aenderung an SwiftUI
    /// (Dokumentansicht neu) und nach dem Zoom auch die geparkten Seiten in Zoom-Schaerfe. Nachher: hoechstens alle
    /// 0,12 s eine Meldung plus eine am Ende, geparkte Seiten bleiben auf Bildschirmaufloesung.
    func testPinchZoomPublishesLessAndLeavesParkedPagesAlone() async throws {
        var report: [String] = []
        for after in [false, true] {
            PencilTuning.rescaleVisibleOnly = after
            PencilTuning.throttleZoomPublish = after
            let fx = try await makeFixture(pdf: Skript.pdf(pages: 12, .schlicht), pageCount: 12)
            let store = try await openStore(fx)
            let shown = show(store)
            defer { hide(shown) }
            let editor = shown.editor
            var published: [CGFloat] = []
            editor.onZoomChange = { published.append($0) }
            _ = try await waitForOverlay(editor, page: 0, timeout: 20)
            // bis Seite 6 und zurueck: Seiten werden geparkt
            editor.goToPage(5)
            try await Task.sleep(nanoseconds: 800_000_000)
            editor.goToPage(0)
            _ = try await waitForOverlay(editor, page: 0, timeout: 20)
            try await Task.sleep(nanoseconds: 600_000_000)
            let parked = editor.parkedOverlaysForTesting
            let fit = editor.pdfView.scaleFactor
            let main = Hauptthread()
            main.start()
            let publishes0 = editor.zoomPublishes
            for i in 1...30 {
                editor.pdfView.scaleFactor = fit * (1 + CGFloat(i) * 0.1)  // bis 4-fach
                try await Task.sleep(nanoseconds: 16_000_000)
            }
            try await Task.sleep(nanoseconds: 900_000_000)                  // Ruhe: Schaerfe und letzte Meldung
            let block = main.take()
            main.stop()
            let publishes = editor.zoomPublishes - publishes0
            let rescaledParked = parked.filter { $0.canvas.zoomScale > 1.001 && !editor.allOverlays.filter { $0.window != nil }.contains($0) }.count
            report.append(String(format: "%@: %d Meldungen an SwiftUI, %d von %d geparkten Seiten neu in Zoom-Schaerfe, Hauptthread laengste Blockade %.0f ms (p99 %.0f ms, %d ueber 50 ms)",
                                 after ? "nachher" : "vorher", publishes, rescaledParked, parked.count, block.max * 1000, block.p99 * 1000, block.over50))
            XCTAssertEqual(published.last.map { Double($0) } ?? 0, Double(editor.pdfView.scaleFactor / fit), accuracy: 0.02,
                           "die letzte Meldung hat den Endwert")
            if after {
                XCTAssertLessThanOrEqual(publishes, 10, "hoechstens alle 0,12 s plus Ende")
                XCTAssertEqual(rescaledParked, 0, "geparkte Seiten bleiben auf Bildschirmaufloesung")
            } else {
                XCTAssertGreaterThanOrEqual(publishes, 25, "Gegenprobe: vorher jede Aenderung")
            }
            editor.fitWidth()
            await store.close()
        }
        print("[Stift] Pinch-Zoom bis 4-fach in 30 Bildern:\n  " + report.joined(separator: "\n  "))
    }

    // MARK: Aufbau (wie EditorScaleTests)

    private func apply(_ d: PKDrawing, to overlay: PageInkView) {
        overlay.isApplyingDrawing = true
        overlay.canvas.drawing = d
        overlay.isApplyingDrawing = false
    }

    private struct Fixture {
        let root: URL
        let api: APIClient
        let file: LibFile
    }

    private struct Shown {
        let editor: PDFEditorController
        let window: UIWindow
    }

    private func makeFixture(pdf: Data, pageCount: Int) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-stift-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let host = LocalBackendHost(directory: root.appendingPathComponent("db", isDirectory: true),
                                    clock: .fixed(berlin: "2026-11-13T10:00:00")!)
        let backend = try await host.backend()
        let fileID = "stift-" + UUID().uuidString.prefix(8).lowercased()
        try await backend.context.database.transaction { c in
            try c.execute("INSERT INTO courses(id, title, semester, subject, kind, created_at) VALUES (?,?,?,?,?,?)",
                          [.text("k-stift"), .text("Stiftkurs"), .text("WiSe 2026/27"), .text("Stiftkurs"), .text("vorlesung"),
                           .text("2026-10-01T08:00:00")])
            try c.execute("INSERT INTO files(id, course_id, name, chdate, status, kind, downloaded_at) VALUES (?,?,?,?, 'neu', 'pdf', ?)",
                          [.text(fileID), .text("k-stift"), .text("Stift.pdf"), .integer(1_792_000_000), .text("2026-11-13T09:00:00")])
        }
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
        let pdfURL = AppPaths.pdf(fileID, namespace: api.namespace, root: root)
        try FileManager.default.createDirectory(at: pdfURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pdf.write(to: pdfURL)
        let meta = try await api.value("/api/files/\(fileID)")
        try DocumentStore.stamp(meta).write(to: pdfURL.appendingPathExtension("stand"), atomically: true, encoding: .utf8)
        let file = LibFile(id: fileID, name: "Stift.pdf", title: "Stift", kind: "pdf", module_id: nil, subject: "Stiftkurs",
                           doc_type: nil, ai_title: nil, sub_label: nil, downloaded_at: "2026-11-13T09:00:00", has_notes: nil,
                           page_count: pageCount, studip_folder: nil)
        return Fixture(root: root, api: api, file: file)
    }

    private func openStore(_ fx: Fixture) async throws -> DocumentStore {
        let store = DocumentStore(file: fx.file, api: fx.api, root: fx.root)
        await store.load()
        XCTAssertNil(store.errorMessage, store.errorMessage ?? "")
        return store
    }

    private func show(_ store: DocumentStore) -> Shown {
        let editor = PDFEditorController(store: store)
        editor.pencilOnly = true
        editor.ownNotesVisible = true
        editor.canEdit = true
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let frame = scene?.screen.bounds ?? CGRect(x: 0, y: 0, width: 834, height: 1210)
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        window.rootViewController = editor
        window.makeKeyAndVisible()
        return Shown(editor: editor, window: window)
    }

    private func hide(_ shown: Shown) {
        guard shown.window.rootViewController != nil else { return }
        shown.editor.showToolPicker(false)
        shown.window.isHidden = true
        shown.window.rootViewController = nil
    }

    private func waitForOverlay(_ editor: PDFEditorController, page: Int, timeout: Double) async throws -> PageInkView {
        let end = Uhr.now() + timeout
        while Uhr.now() < end {
            if let o = editor.allOverlays.first(where: { $0.pageIndex == page && $0.window != nil && $0.generation == editor.shownLayoutVersion }),
               o.loaded, o.bounds.width > 0 { return o }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw MessFehler("kein geladenes Overlay fuer Seite \(page + 1) nach \(Int(timeout)) s")
    }
}
