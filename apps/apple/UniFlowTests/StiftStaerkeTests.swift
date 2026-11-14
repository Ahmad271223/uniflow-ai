import PDFKit
import PencilKit
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Strichstaerke (Auftrag des Inhabers 14.11.2026: "Stift duenner machen, die duennste Stufe noch duenner").
/// Misst, was PencilKit erlaubt, wie breit ein Strich bei Seitenbreite auf dem Bildschirm erscheint und was die
/// Tinte daraus macht. Zeilen "[Staerke]" im Testprotokoll; Bilder mit `TEST_RUNNER_UF_STIFT_DIR=<Ordner>`.
@MainActor
final class StiftStaerkeTests: XCTestCase {

    /// Jede Schnellstufe wirkt: in den Grenzen von PencilKit (sonst still begrenzt) und alle verschieden
    func testEveryWidthStepIsInsidePencilKitLimitsAndDistinct() {
        for t in EditorToolState.Tool.canvasTools {
            guard let ink = t.inkType else { continue }
            let r = ink.validWidthRange
            for w in t.widths { XCTAssertTrue(r.contains(w), "\(t.title) \(w) ausserhalb \(r)") }
            XCTAssertEqual(Set(t.widths.map { min(max($0, r.lowerBound), r.upperBound) }).count, t.widths.count, "\(t.title): Stufen verschieden")
        }
        XCTAssertEqual(EditorToolState.Tool.pen.widths.first, 0.88, "duennster Stift = Untergrenze von PencilKit")
        XCTAssertEqual(EditorToolState.Tool.fineliner.widths.first, 0.5, "duennster Fineliner = Untergrenze von PencilKit")
        // Standard unveraendert und als Stufe vorhanden
        let tools = EditorToolState(defaults: UserDefaults(suiteName: "uniflow.tests.staerke.\(UUID().uuidString)")!)
        for t in [EditorToolState.Tool.pen, .fineliner, .marker] { XCTAssertTrue(t.widths.contains(tools.style(t).width), "\(t.title) Standard") }
    }

    func testMeasureWidthLimitsZoomAndRenderedThickness() async throws {
        var lines: [String] = []
        for (name, type) in [("Stift (.pen)", PKInkingTool.InkType.pen), ("Fineliner (.monoline)", .monoline),
                             ("Fueller (.fountainPen)", .fountainPen), ("Bleistift (.pencil)", .pencil), ("Textmarker (.marker)", .marker)] {
            let r = type.validWidthRange
            lines.append(String(format: "%@: erlaubt %.2f ... %.2f, Standard %.2f", name, r.lowerBound, r.upperBound, type.defaultWidth))
        }
        // gezeichnete Dicke: Strich mit Punktgroesse w, gerendert bei Seitenbreite (Massstab aus dem Editor)
        let zoom = try await fitZoom()
        let screen = UIScreen.main.scale
        lines.append(String(format: "Seitenbreite: 1 Seitenpunkt = %.2f Bildschirmpunkte (A4 hochkant im Editor), Bildschirm %.0fx", zoom, screen))
        for type in [PKInk.InkType.pen, .monoline] {
            for w in [0.3, 0.5, 0.8, 1.0, 1.5, 2.0, 5.0, 10.0] as [CGFloat] {
                let px = thickness(ink: type, size: w, scale: zoom * screen)
                lines.append(String(format: "  %@ Punktgroesse %.1f: %.1f px = %.2f Bildschirmpunkte (erwartet %.2f)",
                                    type.rawValue, w, px, px / screen, w * zoom))
            }
        }
        print("[Staerke]\n  " + lines.joined(separator: "\n  "))
    }

    /// Bild fuer den Inhaber: Seite in Seitenbreite mit kleiner Mitschrift je Stufe (alt oben, neu unten). Der Test
    /// legt `bereit` in den Ordner und haelt das Fenster 8 s offen; das Foto macht `xcrun simctl io … screenshot`
    /// (das Bild des Fensters zeigt die Tinte von PencilKit nicht).
    func testShowThinnestStepsForScreenshot() async throws {
        guard let dir = ProcessInfo.processInfo.environment["UF_STIFT_DIR"], !dir.isEmpty else { throw XCTSkip("nur fuer Bilder") }
        let (editor, window, store) = try await openEditor()
        defer { window.isHidden = true; window.rootViewController = nil }
        let end = Uhr.now() + 15
        var overlay: PageInkView?
        while Uhr.now() < end, overlay == nil {
            overlay = editor.allOverlays.first { $0.pageIndex == 0 && $0.loaded && $0.window != nil }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let o = try XCTUnwrap(overlay)
        let rows: [(String, PKInk.InkType, CGFloat)] = [
            ("alt: Stift dünnste Stufe 1,0", .pen, 1.0), ("alt: Fineliner dünnste Stufe 0,8", .monoline, 0.8),
            ("neu: Stift dünnste Stufe 0,88", .pen, 0.88), ("neu: Fineliner dünnste Stufe 0,5", .monoline, 0.5)]
        var strokes: [PKStroke] = []
        for (r, row) in rows.enumerated() {
            let base = Handschrift.page(r, strokes: 40)
            for (i, s) in base.strokes.enumerated() {
                let line = i / 20
                let dy = 150 + CGFloat(r) * 120 + CGFloat(line) * 34 - (70 + CGFloat(line % 16) * 45)
                let pts = (0..<s.path.count).map { k -> PKStrokePoint in
                    let p = s.path[k]
                    return PKStrokePoint(location: CGPoint(x: p.location.x * 0.8 + 40, y: (p.location.y + dy) * 1.0), timeOffset: p.timeOffset,
                                         size: CGSize(width: row.2, height: row.2), opacity: 1, force: 1, azimuth: p.azimuth, altitude: p.altitude)
                }
                strokes.append(PKStroke(ink: PKInk(row.1, color: .black), path: PKStrokePath(controlPoints: pts, creationDate: s.path.creationDate)))
            }
            let label = UILabel()
            label.text = row.0
            label.font = .systemFont(ofSize: 9, weight: .semibold)
            label.textColor = .systemRed
            label.frame = CGRect(x: 40, y: 128 + CGFloat(r) * 120, width: 300, height: 14)
            o.content.addSubview(label)
        }
        o.isApplyingDrawing = true
        o.canvas.drawing = PKDrawing(strokes: strokes)
        o.isApplyingDrawing = false
        try await Task.sleep(nanoseconds: 1_500_000_000)
        print("[Staerke] Seitenbreite: \(editor.pdfView.scaleFactor)")
        try? "bereit".write(toFile: dir + "/bereit", atomically: true, encoding: .utf8)
        try await Task.sleep(nanoseconds: 8_000_000_000)
        await store.close()
    }

    /// Feine und halbdurchsichtige Striche (Fineliner 0,5, Deckkraft 50 %) im echten Editor: schreiben, radieren,
    /// Rueckgaengig, mit dem Lasso verschieben, sichern und neu laden - Staerke und Deckkraft bleiben
    func testThinStrokesWorkWithUndoEraserLassoAndSaving() async throws {
        let (editor, window, store) = try await openEditor()
        defer { window.isHidden = true; window.rootViewController = nil }
        let end = Uhr.now() + 15
        var overlay: PageInkView?
        while Uhr.now() < end, overlay == nil {
            overlay = editor.allOverlays.first { $0.pageIndex == 0 && $0.loaded && $0.window != nil }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let o = try XCTUnwrap(overlay)
        func tick() async { try? await Task.sleep(nanoseconds: 40_000_000) }
        func set(_ d: PKDrawing) { o.isApplyingDrawing = true; o.canvas.drawing = d; o.isApplyingDrawing = false }
        let color = UIColor.systemBlue.withAlphaComponent(0.5)
        func thin(_ n: Int) -> PKStroke {
            let pts = (0..<25).map { PKStrokePoint(location: CGPoint(x: 60 + CGFloat($0) * 5, y: 200 + CGFloat(n) * 30), timeOffset: Double($0) * 0.01,
                                                   size: CGSize(width: 0.5, height: 0.5), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2) }
            return PKStroke(ink: PKInk(.monoline, color: color), path: PKStrokePath(controlPoints: pts, creationDate: Date(timeIntervalSince1970: 1_950_000_000 + Double(n))))
        }
        for n in 0..<3 {
            await tick()
            o.canvas.tool = PKInkingTool(.monoline, color: color, width: 0.5)
            editor.canvasViewDidBeginUsingTool(o.canvas)
            var d = o.canvas.drawing
            d.strokes.append(thin(n))
            set(d)
            editor.canvasViewDrawingDidChange(o.canvas)
            editor.canvasViewDidEndUsingTool(o.canvas)
        }
        await tick()
        XCTAssertEqual(o.canvas.drawing.strokes.count, 3)
        // radieren (Objekt-Radierer), Rueckgaengig holt ihn zurueck
        o.canvas.tool = PKEraserTool(.vector)
        editor.canvasViewDidBeginUsingTool(o.canvas)
        var e = o.canvas.drawing
        e.strokes.remove(at: 1)
        set(e)
        editor.canvasViewDrawingDidChange(o.canvas)
        editor.canvasViewDidEndUsingTool(o.canvas)
        await tick()
        XCTAssertEqual(o.canvas.drawing.strokes.count, 2)
        editor.undo()
        await tick()
        XCTAssertEqual(o.canvas.drawing.strokes.count, 3, "Rueckgaengig nach Radieren")
        // Lasso verschiebt (Transform), ein Rueckgaengig-Schritt
        await tick()
        var m = o.canvas.drawing
        m.strokes[0].transform = CGAffineTransform(translationX: 30, y: 10)
        editor.replaceInk(key: o.pageKey, before: o.canvas.drawing, after: m)
        await tick()
        XCTAssertEqual(o.canvas.drawing.strokes[0].transform.tx, 30)
        editor.undo()
        await tick()
        XCTAssertEqual(o.canvas.drawing.strokes[0].transform.tx, 0, "Lasso rueckgaengig")
        // sichern, neu laden: Staerke und Deckkraft wie gezeichnet
        await store.flush()
        let reloaded = await store.drawing(forPageKey: o.pageKey)
        XCTAssertEqual(reloaded.strokes.count, 3)
        for s in reloaded.strokes {
            XCTAssertEqual(s.path[0].size.width, 0.5, accuracy: 0.02)
            var a: CGFloat = 0
            s.ink.color.getRed(nil, green: nil, blue: nil, alpha: &a)
            XCTAssertEqual(a, 0.5, accuracy: 0.03)
        }
        await store.close()
    }

    /// Dicke der gerenderten Linie in Pixeln (Mitte, senkrecht gemessen, Deckung ab 50 %)
    private func thickness(ink: PKInk.InkType, size w: CGFloat, scale: CGFloat) -> CGFloat {
        let pts = (0...60).map { i in
            PKStrokePoint(location: CGPoint(x: 10 + CGFloat(i) * 2, y: 20), timeOffset: Double(i) * 0.01,
                          size: CGSize(width: w, height: w), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let d = PKDrawing(strokes: [PKStroke(ink: PKInk(ink, color: .black), path: PKStrokePath(controlPoints: pts, creationDate: Date()))])
        let rect = CGRect(x: 0, y: 0, width: 140, height: 40)
        var img = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent { img = d.image(from: rect, scale: scale) }
        if let dir = ProcessInfo.processInfo.environment["UF_STIFT_DIR"], !dir.isEmpty {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? img.pngData()?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("linie-\(ink.rawValue.split(separator: ".").last ?? "")-\(w).png"))
        }
        guard let cg = img.cgImage else { return 0 }
        let width = cg.width, height = cg.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        // groesste Deckungssumme ueber einige Spalten in der Mitte
        var best: CGFloat = 0
        for x in stride(from: width / 3, to: 2 * width / 3, by: max(1, width / 30)) {
            var cover: CGFloat = 0
            for y in 0..<height { cover += CGFloat(data[(y * width + x) * 4 + 3]) / 255 }
            best = max(best, cover)
        }
        return best                                                       // Summe der Deckung = wirksame Dicke
    }

    private func fitZoom() async throws -> CGFloat {
        let (editor, window, store) = try await openEditor()
        defer { window.isHidden = true; window.rootViewController = nil }
        let end = Uhr.now() + 15
        while Uhr.now() < end, editor.pdfView.scaleFactor <= 0.01 || editor.allOverlays.isEmpty { try await Task.sleep(nanoseconds: 50_000_000) }
        try await Task.sleep(nanoseconds: 500_000_000)
        let z = editor.pdfView.scaleFactor
        await store.close()
        return z
    }

    private func openEditor() async throws -> (PDFEditorController, UIWindow, DocumentStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-staerke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let host = LocalBackendHost(directory: root.appendingPathComponent("db", isDirectory: true), clock: .fixed(berlin: "2026-11-14T18:00:00")!)
        let backend = try await host.backend()
        let fileID = "staerke-" + UUID().uuidString.prefix(8).lowercased()
        try await backend.context.database.transaction { c in
            try c.execute("INSERT INTO courses(id, title, semester, subject, kind, created_at) VALUES (?,?,?,?,?,?)",
                          [.text("k-st"), .text("Kurs"), .text("WiSe 2026/27"), .text("Kurs"), .text("vorlesung"), .text("2026-10-01T08:00:00")])
            try c.execute("INSERT INTO files(id, course_id, name, chdate, status, kind, downloaded_at) VALUES (?,?,?,?, 'neu', 'pdf', ?)",
                          [.text(fileID), .text("k-st"), .text("S.pdf"), .integer(1_792_000_000), .text("2026-11-14T09:00:00")])
        }
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
        let pdfURL = AppPaths.pdf(fileID, namespace: api.namespace, root: root)
        try FileManager.default.createDirectory(at: pdfURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Skript.pdf(pages: 2, .schlicht).write(to: pdfURL)
        let meta = try await api.value("/api/files/\(fileID)")
        try DocumentStore.stamp(meta).write(to: pdfURL.appendingPathExtension("stand"), atomically: true, encoding: .utf8)
        let file = LibFile(id: fileID, name: "S.pdf", title: "S", kind: "pdf", module_id: nil, subject: "Kurs", doc_type: nil, ai_title: nil,
                           sub_label: nil, downloaded_at: "2026-11-14T09:00:00", has_notes: nil, page_count: 2, studip_folder: nil)
        let store = DocumentStore(file: file, api: api, root: root)
        await store.load()
        let editor = PDFEditorController(store: store)
        editor.canEdit = true
        editor.ownNotesVisible = true
        editor.pencilOnly = true
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: UIScreen.main.bounds)
        window.frame = scene?.screen.bounds ?? UIScreen.main.bounds
        window.rootViewController = editor
        window.makeKeyAndVisible()
        return (editor, window, store)
    }
}
