import Combine
import PDFKit
import PencilKit
import SwiftUI
import UIKit.UIGestureRecognizerSubclass
import UniFlowCore
import XCTest
@testable import UniFlow

// Meldung des Inhabers am iPad (21.11.2026): "Wenn man das Hauptdokument auf hat und daneben eine Notiz öffnet, was
// schreibt und ein Bild einfügen will, dann kann man das Bild nur aufs Hauptdokument packen und verschieben, aber nicht
// kleiner machen. Auf die Notiz geht kein Bild drauf, das geht nicht rüber, das verschwindet dann. Und wenn man das
// zieht, ist außen ein blauer Kasten, der verzerrt mitgeht."
//
// Nachgestellt mit echter Beruehrung (`TestFinger`): ein Finger zieht am Bild bzw. an der Ecke des Auswahlrahmens, zwei
// Finger pinchen. Geprueft wird, was man sieht (Lage von Rahmen und Bild auf dem Bildschirm) und was gespeichert ist.

/// Hilfen fuer beide Testklassen: Bild, Auswahlrahmen und Anfasser auf einer Seite, Ziehen mit dem Finger
@MainActor
enum BildProbe {
    nonisolated static func foto(_ size: CGSize = CGSize(width: 800, height: 400)) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor.systemOrange.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: size.width / 2, height: size.height / 2))
        }
    }

    /// Rechteck um ein Objekt in Seitenpunkten
    static func bounds(_ o: JSONValue?) -> CGRect {
        guard let o, let b = PageObjectEdit.bounds(o, textHeight: ObjectEditing.textHeight) else { return .null }
        return CGRect(x: b.minX, y: b.minY, width: b.maxX - b.minX, height: b.maxY - b.minY)
    }

    private static func find(_ layer: CALayer, _ match: (CALayer) -> Bool) -> [CALayer] {
        (match(layer) ? [layer] : []) + (layer.sublayers ?? []).flatMap { find($0, match) }
    }

    /// Ebene des blau gestrichelten Auswahlrahmens auf einer Seite
    static func selectionLayer(_ overlay: PageInkView) -> CAShapeLayer? {
        let own = (overlay.content.layer.sublayers ?? []).filter { l in !overlay.content.subviews.contains { $0.layer === l } }
        for l in own.flatMap({ find($0) { $0 is CAShapeLayer } }) {
            if let s = l as? CAShapeLayer, s.lineDashPattern != nil, s.path != nil { return s }
        }
        return nil
    }

    /// Auswahlrahmen, wie er gerade auf dem Bildschirm steht (Seitenpunkte), ohne seinen Abstand von 4 pt zum Objekt
    static func frameShown(_ overlay: PageInkView) -> CGRect? {
        guard let l = selectionLayer(overlay) else { return nil }
        let p = l.presentation() ?? l
        guard let path = p.path else { return nil }
        var box = path.boundingBoxOfPath.applying(p.affineTransform())
        if let sup = l.superlayer, sup !== overlay.content.layer { box = overlay.content.layer.convert(box, from: sup) }
        return box.insetBy(dx: 4, dy: 4)
    }

    /// Bild, wie es gerade auf dem Bildschirm steht (Seitenpunkte)
    static func imageShown(_ overlay: PageInkView) -> CGRect? {
        guard let v = overlay.objectsView.subviews.compactMap({ $0 as? UIImageView }).last else { return nil }
        return (v.layer.presentation() ?? v.layer).frame
    }

    /// Groesster Abstand zwischen Rahmen und Bild auf dem Bildschirm (Seitenpunkte); nil, wenn eines fehlt
    static func deviation(_ overlay: PageInkView) -> CGFloat? {
        guard let f = frameShown(overlay), let i = imageShown(overlay) else { return nil }
        return max(abs(f.minX - i.minX), abs(f.minY - i.minY), abs(f.maxX - i.maxX), abs(f.maxY - i.maxY))
    }

    /// Sichtbare Anfasser an den Ecken des Auswahlrahmens (Mittelpunkte in Seitenpunkten)
    static func handles(_ overlay: PageInkView) -> [CGPoint] {
        find(overlay.content.layer) { $0.name == "objects.handle" && !$0.isHidden && $0.opacity > 0 }.map {
            overlay.content.layer.convert(CGPoint(x: $0.bounds.midX, y: $0.bounds.midY), from: $0)
        }
    }

    /// Ein Finger zieht von `a` nach `b` (Seitenpunkte der Seite von `overlay`); `each` laeuft nach jedem Schritt,
    /// sobald der Bildschirm ihn zeigt
    static func drag(from a: CGPoint, to b: CGPoint, on overlay: PageInkView, in window: UIWindow, steps: Int = 14,
                     each: (() -> Void)? = nil) async throws {
        func w(_ p: CGPoint) -> CGPoint { overlay.content.convert(p, to: nil) }
        let finger = TestFinger(at: w(a), in: window)
        for i in 1...steps {
            try await Task.sleep(nanoseconds: 24_000_000)
            let t = CGFloat(i) / CGFloat(steps)
            finger.move(to: w(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)))
            try await Task.sleep(nanoseconds: 24_000_000)
            each?()
        }
        try await Task.sleep(nanoseconds: 60_000_000)
        finger.lift()
        try await Task.sleep(nanoseconds: 150_000_000)
    }

    /// Ein Finger zieht von `a` nach `b` in Punkten des Fensters (auch ueber die Trennlinie ins andere Dokument)
    static func dragWindow(from a: CGPoint, to b: CGPoint, in window: UIWindow, steps: Int = 24, each: ((CGPoint) -> Void)? = nil) async throws {
        let finger = TestFinger(at: a, in: window)
        for i in 1...steps {
            try await Task.sleep(nanoseconds: 24_000_000)
            let t = CGFloat(i) / CGFloat(steps)
            let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            finger.move(to: p)
            try await Task.sleep(nanoseconds: 24_000_000)
            each?(p)
        }
        try await Task.sleep(nanoseconds: 60_000_000)
        finger.lift()
        try await Task.sleep(nanoseconds: 150_000_000)
    }

    /// Schwebendes Bild beim Hinueberziehen (im Fenster), nil ohne
    static func floating(in window: UIWindow) -> UIView? {
        window.subviews.first { $0.accessibilityIdentifier == ObjectEditing.transferViewID }
    }

    /// Rahmen "hier landet das Bild" auf einer Seite (Seitenpunkte), nil ohne
    static func dropFrame(_ overlay: PageInkView) -> CGRect? {
        find(overlay.content.layer) { $0.name == ObjectEditing.transferFrameName }.compactMap { ($0 as? CAShapeLayer)?.path?.boundingBoxOfPath }.first
    }

    /// Kurzer Tipp mit dem Finger auf einen Punkt der Seite
    static func tap(_ p: CGPoint, on overlay: PageInkView, in window: UIWindow) async throws {
        let finger = TestFinger(at: overlay.content.convert(p, to: nil), in: window)
        try await Task.sleep(nanoseconds: 50_000_000)
        finger.lift()
        try await Task.sleep(nanoseconds: 450_000_000)                 // laenger als die Wartezeit auf einen Doppeltipp
    }

    static func wait(_ what: String, timeout: Double = 8, file: StaticString = #filePath, line: UInt = #line,
                     _ cond: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline { if await cond() { return }; try await Task.sleep(nanoseconds: 30_000_000) }
        XCTFail("Zeit abgelaufen: \(what)", file: file, line: line)
    }
}

/// Ein Dokument im Fenster: Bild einfuegen, verschieben, Groesse aendern
@MainActor
final class BildGroesseTests: XCTestCase {

    struct Shown {
        let store: DocumentStore
        let editor: PDFEditorController
        let window: UIWindow
    }

    private static func pdf(pages: Int) -> Data {
        let raw = NSMutableData()
        let size = CGSize(width: 595, height: 842)
        UIGraphicsBeginPDFContextToData(raw, CGRect(origin: .zero, size: size), nil)
        for i in 1...pages {
            UIGraphicsBeginPDFPageWithInfo(CGRect(origin: .zero, size: size), nil)
            "Seite \(i)".draw(at: CGPoint(x: 60, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
        }
        UIGraphicsEndPDFContext()
        return raw as Data
    }

    /// Dokument mit Ablage fuer Bilder (wie in der App), im Fenster gezeigt. `width`: Breite des Fensters (schmal = wie
    /// die Spalte der Notiz daneben)
    private func open(width: CGFloat = 1080, pages: Int = 2) async throws -> Shown {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-bild-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let clock: UniFlowClock = .fixed(berlin: "2026-11-21T09:00:00")!
        let layout = DataContainerLayout(base: root.appendingPathComponent("c", isDirectory: true),
                                         key: DataContainerKey(userID: "001234.erfunden.bild", university: .luh))
        try layout.prepare(clock: clock)
        let host = LocalBackendHost(directory: layout.databaseDirectory, clock: clock, files: .container(layout), university: .luh)
        let backend = try await host.backend()
        let fileID = "bild-" + UUID().uuidString.prefix(8).lowercased()
        try await backend.context.database.transaction { c in
            try c.execute("INSERT OR IGNORE INTO courses(id, title, semester, subject, kind, created_at) VALUES (?,?,?,?,?,?)",
                          [.text("k-test"), .text("Testkurs"), .text("WiSe 2026/27"), .text("Testkurs"), .text("vorlesung"),
                           .text("2026-10-01T08:00:00")])
            try c.execute("INSERT INTO files(id, course_id, name, chdate, status, kind, downloaded_at) VALUES (?,?,?,?, 'neu', 'pdf', ?)",
                          [.text(fileID), .text("k-test"), .text("Skript.pdf"), .integer(1_792_000_000), .text("2026-11-21T08:00:00")])
        }
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
        let pdfURL = AppPaths.pdf(fileID, namespace: api.namespace, root: root)
        try FileManager.default.createDirectory(at: pdfURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.pdf(pages: pages).write(to: pdfURL)
        try DocumentStore.stamp(try await api.value("/api/files/\(fileID)")).write(to: pdfURL.appendingPathExtension("stand"), atomically: true, encoding: .utf8)
        let file = LibFile(id: fileID, name: "Skript.pdf", title: "Skript", kind: "pdf", module_id: nil, subject: "Testkurs",
                           doc_type: nil, ai_title: nil, sub_label: nil, downloaded_at: "2026-11-21T08:00:00", has_notes: nil,
                           page_count: pages, studip_folder: nil)
        let store = DocumentStore(file: file, api: api, root: root)
        await store.load()
        XCTAssertNil(store.errorMessage, store.errorMessage ?? "")

        let suite = "uniflow.tests.bild.\(UUID().uuidString)"
        let toolDefaults = UserDefaults(suiteName: suite) ?? .standard
        let editor = PDFEditorController(store: store, tools: EditorToolState(defaults: toolDefaults))
        editor.pencilOnly = true
        editor.ownNotesVisible = true
        editor.canEdit = true
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let frame = CGRect(x: 0, y: 0, width: width, height: 810)
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        window.rootViewController = editor
        window.makeKeyAndVisible()
        addTeardownBlock { @MainActor in
            toolDefaults.removePersistentDomain(forName: suite)
            editor.showToolPicker(false)
            window.isHidden = true
            window.rootViewController = nil
            await store.close()
        }
        return Shown(store: store, editor: editor, window: window)
    }

    private func overlay(_ s: Shown, page: Int = 0) async throws -> PageInkView {
        var found: PageInkView?
        try await BildProbe.wait("Seite \(page + 1) geladen", timeout: 20) {
            found = s.editor.allOverlays.first { $0.pageIndex == page && $0.window != nil && $0.generation == s.editor.shownLayoutVersion && $0.loaded }
            return found != nil
        }
        return try XCTUnwrap(found)
    }

    /// Bild einfuegen wie ueber "Bild aus Fotos …" und warten, bis es mit Rahmen auf der Seite steht
    private func insert(_ s: Shown, _ image: UIImage = BildProbe.foto(), at point: CGPoint) async throws -> (overlay: PageInkView, id: String) {
        let overlay = try await overlay(s)
        let ok = await s.editor.objects.insertImage(image, on: overlay.pageKey, at: point)
        XCTAssertTrue(ok, "Bild eingefuegt")
        let listed = await s.store.objects(forPageKey: overlay.pageKey)
        let id = try XCTUnwrap(listed.last?["id"]?.string)
        try await BildProbe.wait("Bild und Rahmen zu sehen") { BildProbe.imageShown(overlay) != nil && BildProbe.frameShown(overlay) != nil }
        return (overlay, id)
    }

    private func object(_ s: Shown, _ key: String, _ id: String) async -> JSONValue? {
        await s.store.objects(forPageKey: key).first { $0["id"]?.string == id }
    }

    private func page(_ overlay: PageInkView) -> CGRect { CGRect(origin: .zero, size: overlay.geometry.pageSize) }

    // MARK: "nicht kleiner machen"

    /// An der Ecke des Auswahlrahmens sitzt ein sichtbarer Anfasser; ein Finger zieht dort das Bild kleiner und wieder
    /// groesser. Das Seitenverhaeltnis bleibt, die gegenueberliegende Ecke bleibt stehen, jede Aenderung ist ein
    /// Rueckgaengig-Schritt.
    func testEckeZiehenAendertGroesseMitSeitenverhaeltnis() async throws {
        try XCTSkipUnless(TestFinger.verfuegbar, "Beruehrung laesst sich in dieser iOS-Version nicht nachstellen")
        try ContainerTestBed.requireEventGroupedUndo()
        let s = try await open()
        let (overlay, id) = try await insert(s, at: CGPoint(x: 120, y: 150))
        let o0 = await object(s, overlay.pageKey, id)
        let start = BildProbe.bounds(o0)
        XCTAssertEqual(start.width, 297.5, accuracy: 0.5)
        XCTAssertEqual(start.height, 148.75, accuracy: 0.5)
        XCTAssertEqual(s.editor.objects.selection?.ids, [id], "das neue Bild ist ausgewaehlt")
        let frame = try XCTUnwrap(BildProbe.frameShown(overlay)).insetBy(dx: -4, dy: -4)
        let corner = CGPoint(x: frame.maxX, y: frame.maxY)
        let handles = BildProbe.handles(overlay)
        XCTAssertTrue(handles.contains { hypot($0.x - corner.x, $0.y - corner.y) < 3 }, "sichtbarer Anfasser unten rechts am Rahmen: \(handles)")

        // kleiner: Ecke 80/40 pt nach innen (entlang der Diagonale)
        try await BildProbe.drag(from: corner, to: CGPoint(x: corner.x - 80, y: corner.y - 40), on: overlay, in: s.window)
        try await BildProbe.wait("gespeichert") { await BildProbe.bounds(self.object(s, overlay.pageKey, id)).width < start.width - 1 || s.editor.editUndo.canUndo }
        let small = BildProbe.bounds(await object(s, overlay.pageKey, id))
        XCTAssertEqual(small.width, start.width - 80, accuracy: 12 / ObjectEditing.screenScale(of: overlay) + 4, "kleiner gezogen (vorher \(start.width))")
        XCTAssertEqual(small.width / small.height, start.width / start.height, accuracy: 0.02, "Seitenverhaeltnis bleibt")
        XCTAssertEqual(small.minX, start.minX, accuracy: 0.6, "die Ecke gegenueber bleibt stehen")
        XCTAssertEqual(small.minY, start.minY, accuracy: 0.6)
        XCTAssertEqual(BildProbe.deviation(overlay) ?? 99, 0, accuracy: 0.8, "Rahmen liegt nach dem Loslassen auf dem Bild")

        // groesser: von der neuen Ecke nach aussen
        let frame2 = try XCTUnwrap(BildProbe.frameShown(overlay)).insetBy(dx: -4, dy: -4)
        let corner2 = CGPoint(x: frame2.maxX, y: frame2.maxY)
        try await BildProbe.drag(from: corner2, to: CGPoint(x: corner2.x + 120, y: corner2.y + 60), on: overlay, in: s.window)
        try await BildProbe.wait("groesser gespeichert") { await BildProbe.bounds(self.object(s, overlay.pageKey, id)).width > small.width + 40 }
        let big = BildProbe.bounds(await object(s, overlay.pageKey, id))
        XCTAssertEqual(big.width, small.width + 120, accuracy: 16)
        XCTAssertEqual(big.width / big.height, start.width / start.height, accuracy: 0.02)

        // ein Rueckgaengig je Aktion: groesser -> kleiner -> Ausgang
        s.editor.undo()
        try await BildProbe.wait("Rueckgaengig: wieder klein") { await abs(BildProbe.bounds(self.object(s, overlay.pageKey, id)).width - small.width) < 0.6 }
        s.editor.undo()
        try await BildProbe.wait("Rueckgaengig: Ausgangsgroesse") { await abs(BildProbe.bounds(self.object(s, overlay.pageKey, id)).width - start.width) < 0.6 }
        s.editor.redo()
        try await BildProbe.wait("Wiederholen: wieder klein") { await abs(BildProbe.bounds(self.object(s, overlay.pageKey, id)).width - small.width) < 0.6 }
    }

    /// Grenzen: nie kleiner als rund 24 pt, nie groesser als die Seite
    func testGroesseHatGrenzen() async throws {
        try XCTSkipUnless(TestFinger.verfuegbar, "Beruehrung laesst sich in dieser iOS-Version nicht nachstellen")
        let s = try await open()
        let (overlay, id) = try await insert(s, at: CGPoint(x: 120, y: 150))
        var frame = try XCTUnwrap(BildProbe.frameShown(overlay)).insetBy(dx: -4, dy: -4)
        // weit ueber die Ecke gegenueber hinaus nach innen
        try await BildProbe.drag(from: CGPoint(x: frame.maxX, y: frame.maxY), to: CGPoint(x: frame.minX - 60, y: frame.minY - 30), on: overlay, in: s.window)
        try await BildProbe.wait("klein gespeichert") { await BildProbe.bounds(self.object(s, overlay.pageKey, id)).width < 100 }
        let tiny = BildProbe.bounds(await object(s, overlay.pageKey, id))
        XCTAssertGreaterThanOrEqual(max(tiny.width, tiny.height), 23.5, "nie kleiner als rund 24 pt: \(tiny)")
        XCTAssertLessThanOrEqual(max(tiny.width, tiny.height), 30)
        XCTAssertEqual(tiny.width / tiny.height, 2, accuracy: 0.05)

        // Menue "Größer" (Maus) so oft, bis nichts mehr waechst: hoechstens so gross wie die Seite, und ganz auf der Seite
        var width = tiny.width
        for _ in 0..<40 {
            s.editor.objects.scaleSelection(by: 1.25)
            let until = Date().addingTimeInterval(0.6)
            var now = width
            while Date() < until, now <= width + 0.01 {
                try await Task.sleep(nanoseconds: 20_000_000)
                now = BildProbe.bounds(await object(s, overlay.pageKey, id)).width
            }
            if now <= width + 0.01 { break }
            width = now
        }
        XCTAssertGreaterThan(width, 500, "waechst bis zur Seitenbreite")
        try await Task.sleep(nanoseconds: 400_000_000)
        let huge = BildProbe.bounds(await object(s, overlay.pageKey, id))
        XCTAssertLessThanOrEqual(huge.width, page(overlay).width + 0.6, "nie breiter als die Seite: \(huge)")
        XCTAssertTrue(page(overlay).insetBy(dx: -0.6, dy: -0.6).contains(huge), "ganz auf der Seite: \(huge)")
        frame = try XCTUnwrap(BildProbe.frameShown(overlay))
        XCTAssertEqual(BildProbe.deviation(overlay) ?? 99, 0, accuracy: 0.8)
    }

    /// Ein abgebrochenes oder beendetes Ziehen (ein Finger) beendet keine laufende Zwei-Finger-Geste: die Vorschau
    /// bleibt, und beim Loslassen wird die Groesse gespeichert
    func testAbgebrochenesZiehenBeendetKeinenPinch() async throws {
        try XCTSkipUnless(TestFinger.verfuegbar, "Beruehrung laesst sich in dieser iOS-Version nicht nachstellen")
        let s = try await open()
        let (overlay, id) = try await insert(s, at: CGPoint(x: 120, y: 150))
        let start = BildProbe.bounds(await object(s, overlay.pageKey, id))
        let c = overlay.content.convert(CGPoint(x: start.midX, y: start.midY), to: nil)
        func pts(_ d: CGFloat) -> (CGPoint, CGPoint) { (CGPoint(x: c.x - d / 2, y: c.y - d * 0.15), CGPoint(x: c.x + d / 2, y: c.y + d * 0.15)) }
        let fingers = TestFinger.Zwei(pts(220).0, pts(220).1, in: s.window)
        for i in 1...12 {
            try await Task.sleep(nanoseconds: 17_000_000)
            let p = pts(220 - CGFloat(i) * 5)
            fingers.move(p.0, p.1)
        }
        try await Task.sleep(nanoseconds: 40_000_000)
        let mid = try XCTUnwrap(BildProbe.imageShown(overlay)).width
        XCTAssertLessThan(mid, start.width - 20, "die Zwei-Finger-Geste laeuft, das Bild ist schon kleiner")

        s.editor.objects.panned(GestellterZug(.cancelled))
        XCTAssertEqual(BildProbe.imageShown(overlay)?.width ?? 0, mid, accuracy: 0.5, "abgebrochenes Ziehen: Vorschau bleibt")
        s.editor.objects.panned(GestellterZug(.changed))
        s.editor.objects.panned(GestellterZug(.ended))
        XCTAssertEqual(BildProbe.imageShown(overlay)?.width ?? 0, mid, accuracy: 0.5, "beendetes Ziehen: Vorschau bleibt")

        for i in 13...20 {
            try await Task.sleep(nanoseconds: 17_000_000)
            let p = pts(220 - CGFloat(i) * 5)
            fingers.move(p.0, p.1)
        }
        try await Task.sleep(nanoseconds: 17_000_000)
        fingers.lift()
        try await BildProbe.wait("kleiner gespeichert") { await BildProbe.bounds(self.object(s, overlay.pageKey, id)).width < start.width - 20 }
        let small = BildProbe.bounds(await object(s, overlay.pageKey, id))
        XCTAssertEqual(small.width / start.width, 120.0 / 220, accuracy: 0.15)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(BildProbe.deviation(overlay) ?? 99, 0, accuracy: 0.8)
    }

    /// Schreiben wird durch den Berührungs-Melder nicht langsamer: je Beruehrung genau ein Aufruf beim Aufsetzen (nicht
    /// je Punkt des Strichs), der nur einen Verweis vergleicht - nichts geht an SwiftUI, solange der Editor derselbe
    /// bleibt. Die Striche kommen an wie immer.
    func testBeruehrungsMelderKostetBeimSchreibenNichts() async throws {
        try XCTSkipUnless(TestFinger.verfuegbar, "Beruehrung laesst sich in dieser iOS-Version nicht nachstellen")
        let s = try await open()
        s.editor.pencilOnly = false                                        // der Finger schreibt
        let overlay = try await overlay(s)
        s.editor.tools.select(.pen)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertTrue(s.editor.tools.activeEditor === s.editor, "ein Dokument: es ist von Anfang an das, in dem gearbeitet wird")
        let probe = try XCTUnwrap(MelderProbe(s.editor), "Melder haengt an der PDF-Ansicht")
        var published = 0, selections = 0
        let watch = s.editor.tools.objectWillChange.sink { published += 1 }
        defer { watch.cancel() }
        s.editor.tools.onActiveSelection = { _ in selections += 1 }
        for n in 0..<5 {
            let y = 120 + CGFloat(n) * 40
            let line = (0...40).map { overlay.content.convert(CGPoint(x: 80 + CGFloat($0) * 6, y: y + sin(CGFloat($0) / 4) * 8), to: nil) }
            try await TestFinger.strich(line, in: s.window, step: 0.008)
            try await Task.sleep(nanoseconds: 350_000_000)
        }
        try await BildProbe.wait("fuenf Striche auf der Seite") { overlay.canvas.drawing.strokes.count == 5 }
        XCTAssertEqual(probe.calls, 5, "ein Aufruf je Beruehrung (41 Punkte je Strich)")
        XCTAssertEqual(published, 0, "nichts an SwiftUI gemeldet")
        XCTAssertEqual(selections, 0, "keine Meldung an die Objektleiste")
        XCTAssertLessThan(probe.median, 0.0005, "Aufruf des Melders (Median) in Sekunden: \(probe.seconds)")
        print("[Bild] Melder je Beruehrung (s): \(probe.seconds.map { String(format: "%.6f", $0) })")
    }

    // MARK: Regeln dahinter (ohne Fenster)

    private func bild(_ id: String, _ r: CGRect) -> JSONValue {
        .object(["id": .string(id), "type": "image", "src": "/api/assets/x", "x": .number(Double(r.minX)), "y": .number(Double(r.minY)),
                 "width": .number(Double(r.width)), "height": .number(Double(r.height)), "rotation": 0, "scaleX": 1, "scaleY": 1, "opacity": 1])
    }

    /// Groesse aendern: Grenzen, fester Punkt, mehrere Objekte bleiben zueinander, das Speicherformat bleibt
    func testGroessenRegeln() throws {
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        let a = bild("a", CGRect(x: 100, y: 100, width: 200, height: 100)), b = bild("b", CGRect(x: 340, y: 240, width: 100, height: 60))
        let text = PageObjectEdit.text(id: "t", x: 20, y: 700, text: "bleibt")

        // ein Bild um seine rechte untere Ecke auf die Haelfte: die Ecke bleibt, nur x/y/scaleX/scaleY aendern sich
        var r = ObjectEditing.resized([a, text], ids: ["a"], inkBox: .null, by: 0.5, about: CGPoint(x: 300, y: 200), page: page)
        XCTAssertEqual(r.factor, 0.5)
        XCTAssertEqual(r.box, CGRect(x: 200, y: 150, width: 100, height: 50))
        XCTAssertEqual(r.objects[1], text, "nicht ausgewaehlte Objekte bleiben unberuehrt")
        let changed = try XCTUnwrap(r.objects[0].object), before = try XCTUnwrap(a.object)
        XCTAssertEqual(Set(changed.keys), Set(before.keys), "keine neuen Felder")
        XCTAssertEqual(Set(changed.keys.filter { changed[$0] != before[$0] }), ["x", "y", "scaleX", "scaleY"])
        XCTAssertEqual(changed["width"], 200, "Breite und Hoehe des Bildes bleiben, der Massstab traegt die Groesse (wie im Web)")

        // zwei Bilder um die linke obere Ecke um ein Fuenftel groesser: Groessen und Abstand wachsen gleich
        r = ObjectEditing.resized([a, b], ids: ["a", "b"], inkBox: .null, by: 1.2, about: CGPoint(x: 100, y: 100), page: page)
        XCTAssertEqual(BildProbe.bounds(r.objects[0]), CGRect(x: 100, y: 100, width: 240, height: 120))
        XCTAssertEqual(BildProbe.bounds(r.objects[1]).minX, 100 + 240 * 1.2, accuracy: 0.01, "das zweite rueckt mit")
        XCTAssertEqual(BildProbe.bounds(r.objects[1]).width, 120, accuracy: 0.01)

        // Grenzen: nie groesser als die Seite, nie kleiner als 24 pt an der laengeren Seite, danach ganz auf der Seite
        r = ObjectEditing.resized([a], ids: ["a"], inkBox: .null, by: 50, about: CGPoint(x: 100, y: 100), page: page)
        XCTAssertEqual(r.box.width, 595, accuracy: 0.3)
        XCTAssertTrue(page.insetBy(dx: -0.3, dy: -0.3).contains(r.box), "\(r.box)")
        r = ObjectEditing.resized([a], ids: ["a"], inkBox: .null, by: 0.0001, about: CGPoint(x: 100, y: 100), page: page)
        XCTAssertEqual(r.box.width, 24, accuracy: 0.2)
        XCTAssertEqual(r.box.height, 12, accuracy: 0.2)
        // ein Objekt, das (aus dem Web oder von frueher) ueber den Rand ragt, kommt beim Anfassen auf die Seite
        let outside = bild("o", CGRect(x: 500, y: -40, width: 200, height: 100))
        r = ObjectEditing.resized([outside], ids: ["o"], inkBox: .null, by: 1, about: CGPoint(x: 500, y: -40), page: page)
        XCTAssertEqual(r.box, CGRect(x: 395, y: 0, width: 200, height: 100))
        // Handschrift in der Auswahl geht mit derselben Abbildung mit
        r = ObjectEditing.resized([a], ids: ["a"], inkBox: CGRect(x: 100, y: 220, width: 50, height: 20), by: 2, about: CGPoint(x: 100, y: 100), page: page)
        XCTAssertEqual(CGRect(x: 100, y: 220, width: 50, height: 20).applying(r.inkTransform), CGRect(x: 100, y: 340, width: 100, height: 40))
        XCTAssertEqual(r.box, CGRect(x: 100, y: 100, width: 400, height: 280))

        // Verschieben: bleibt auf der Seite
        XCTAssertEqual(ObjectEditing.clampedOffset(CGRect(x: 100, y: 100, width: 200, height: 100), by: CGPoint(x: 900, y: -900), in: page), CGPoint(x: 295, y: -100))
        XCTAssertEqual(ObjectEditing.clampedOffset(CGRect(x: 100, y: 100, width: 200, height: 100), by: CGPoint(x: 30, y: 40), in: page), CGPoint(x: 30, y: 40))
    }

    /// Anfasser treffen: aussen im ganzen Umkreis, innen nur nahe der Ecke - ein kleines Objekt bleibt verschiebbar
    func testAnfasserTreffen() throws {
        let box = CGRect(x: 100, y: 100, width: 200, height: 100)
        let se = try XCTUnwrap(ObjectEditing.corner(at: CGPoint(x: 310, y: 206), of: box, reach: 14))
        XCTAssertEqual(se.corner, CGPoint(x: 300, y: 200))
        XCTAssertEqual(se.anchor, CGPoint(x: 100, y: 100), "die Ecke gegenueber bleibt stehen")
        XCTAssertEqual(ObjectEditing.corner(at: CGPoint(x: 97, y: 97), of: box, reach: 14)?.anchor, CGPoint(x: 300, y: 200))
        XCTAssertNil(ObjectEditing.corner(at: CGPoint(x: 200, y: 150), of: box, reach: 14), "Mitte: verschieben")
        XCTAssertNil(ObjectEditing.corner(at: CGPoint(x: 330, y: 230), of: box, reach: 14), "zu weit weg")
        let small = CGRect(x: 100, y: 100, width: 24, height: 12)
        XCTAssertNil(ObjectEditing.corner(at: CGPoint(x: 112, y: 106), of: small, reach: 30), "kleines Objekt: Mitte verschiebt")
        XCTAssertNotNil(ObjectEditing.corner(at: CGPoint(x: 130, y: 118), of: small, reach: 30), "aussen an der Ecke: Groesse")
        // Ecke 80/40 nach innen gezogen: Faktor entlang der Diagonale
        XCTAssertEqual(ObjectEditing.cornerFactor(anchor: CGPoint(x: 100, y: 100), corner: CGPoint(x: 300, y: 200), translation: CGPoint(x: -80, y: -40)), 0.6, accuracy: 0.001)
        XCTAssertEqual(ObjectEditing.anchoredLimit(box, anchor: CGPoint(x: 100, y: 100), corner: CGPoint(x: 300, y: 200), in: CGRect(x: 0, y: 0, width: 595, height: 842)), 2.475, accuracy: 0.001)
    }

    /// Wohin ein neues Bild kommt: halbe Seitenbreite, nie hoeher als die Seite, im sichtbaren Teil, immer auf der Seite
    func testLageEinesNeuenBildes() {
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        // ganze Seite zu sehen: wie bisher oben (y = 60), waagerecht mittig
        XCTAssertEqual(ObjectEditing.imageFrame(CGSize(width: 800, height: 400), page: page, visible: page, at: nil), CGRect(x: 148.75, y: 60, width: 297.5, height: 148.75))
        XCTAssertEqual(ObjectEditing.imageFrame(CGSize(width: 800, height: 400), page: page, visible: nil, at: nil).minY, 60)
        // hineingezoomt, unten auf der Seite: dort, verkleinert auf den sichtbaren Teil
        let visible = CGRect(x: 300, y: 600, width: 200, height: 150)
        let r = ObjectEditing.imageFrame(CGSize(width: 800, height: 400), page: page, visible: visible, at: nil)
        XCTAssertTrue(visible.contains(r), "\(r)")
        XCTAssertEqual(r.width / r.height, 2, accuracy: 0.001)
        // hohes Bild (Bildschirmfoto): nie hoeher als die Seite
        let tall = ObjectEditing.imageFrame(CGSize(width: 300, height: 3000), page: page, visible: page, at: nil)
        XCTAssertTrue(page.contains(tall), "\(tall)")
        // abgelegt nahe am Rand: an der Stelle, aber ganz auf der Seite
        let dropped = ObjectEditing.imageFrame(CGSize(width: 200, height: 100), page: page, visible: visible, at: CGPoint(x: 560, y: 800))
        XCTAssertEqual(dropped, CGRect(x: 395, y: 742, width: 200, height: 100))
        XCTAssertEqual(ObjectEditing.imageFrame(CGSize(width: 200, height: 100), page: page, visible: nil, at: CGPoint(x: 40, y: 60)).origin, CGPoint(x: 40, y: 60))
    }

    /// Hinueberziehen: Lage und Groesse im Ziel; ein einzelnes Dokument hat kein "anderes"
    func testLandenImAnderenDokument() async throws {
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        var l = ObjectEditing.landing(CGSize(width: 200, height: 100), at: CGPoint(x: 300, y: 400), page: page)
        XCTAssertEqual(l.rect, CGRect(x: 200, y: 350, width: 200, height: 100), "um den Finger, gleiche Groesse")
        l = ObjectEditing.landing(CGSize(width: 200, height: 100), at: CGPoint(x: 580, y: 10), page: page)
        XCTAssertEqual(l.rect, CGRect(x: 395, y: 0, width: 200, height: 100), "am Rand: ganz auf der Seite")
        l = ObjectEditing.landing(CGSize(width: 1190, height: 300), at: CGPoint(x: 300, y: 400), page: page)
        XCTAssertEqual(l.factor, 0.5, accuracy: 0.0001, "groesser als die Zielseite: passend verkleinert")
        XCTAssertEqual(l.rect, CGRect(x: 0, y: 325, width: 595, height: 150))

        let o = bild("a", CGRect(x: 700, y: 20, width: 400, height: 200))
        let moved = ObjectEditing.transferred(o, id: "neu", src: "/api/assets/ziel/x.png", to: CGPoint(x: 300, y: 400), page: page)
        XCTAssertEqual(BildProbe.bounds(moved), CGRect(x: 100, y: 300, width: 400, height: 200))
        XCTAssertEqual(moved["id"], "neu")
        XCTAssertEqual(moved["src"], "/api/assets/ziel/x.png")
        XCTAssertEqual(Set(moved.object?.keys.map { $0 } ?? []), Set((o.object?.keys.map { $0 } ?? []) + ["source"]), "gleiche Felder wie beim Einfuegen")
        let wide = ObjectEditing.transferred(bild("b", CGRect(x: 0, y: 0, width: 900, height: 300)), id: "n2", src: "/s", to: CGPoint(x: 10, y: 10), page: page)
        XCTAssertEqual(BildProbe.bounds(wide).width, 595, accuracy: 0.6)
        XCTAssertTrue(page.insetBy(dx: -0.6, dy: -0.6).contains(BildProbe.bounds(wide)))

        let s = try await open()
        XCTAssertNil(s.editor.tools.otherEditor(than: s.editor), "nur ein Dokument offen: kein Hinueberziehen")
    }

    // MARK: "das verschwindet dann"

    /// Ein Finger zieht das Bild ueber den Seitenrand hinaus (zur Notiz daneben hin): es bleibt ganz auf der Seite
    func testVerschiebenHaeltBildAufDerSeite() async throws {
        try XCTSkipUnless(TestFinger.verfuegbar, "Beruehrung laesst sich in dieser iOS-Version nicht nachstellen")
        let s = try await open()
        let (overlay, id) = try await insert(s, BildProbe.foto(CGSize(width: 200, height: 100)), at: CGPoint(x: 370, y: 150))
        let start = BildProbe.bounds(await object(s, overlay.pageKey, id))
        XCTAssertEqual(start.width, 200, accuracy: 0.5)
        // am linken Teil des Bildes greifen und bis an den rechten Fensterrand ziehen (200 pt der Seite nach rechts)
        let grab = CGPoint(x: start.minX + 14, y: start.midY)
        var worst: CGFloat = 0
        try await BildProbe.drag(from: grab, to: CGPoint(x: grab.x + 200, y: grab.y + 20), on: overlay, in: s.window) {
            if let i = BildProbe.imageShown(overlay) { worst = max(worst, i.maxX - overlay.geometry.pageSize.width) }
        }
        try await BildProbe.wait("verschoben gespeichert") { await BildProbe.bounds(self.object(s, overlay.pageKey, id)).minX > start.minX + 5 }
        let moved = BildProbe.bounds(await object(s, overlay.pageKey, id))
        XCTAssertTrue(page(overlay).insetBy(dx: -0.6, dy: -0.6).contains(moved), "Bild ganz auf der Seite, nicht ueber den Rand: \(moved)")
        XCTAssertEqual(moved.maxX, page(overlay).maxX, accuracy: 1, "am Rand angehalten")
        XCTAssertLessThanOrEqual(worst, 1, "auch waehrend des Ziehens nie ueber den Rand")

        // und ohne Finger (Menue, Tastatur): weit hinaus geschoben bleibt es auf der Seite
        s.editor.objects.finishMove(dx: -5000, dy: 9000)
        try await BildProbe.wait("in die Ecke geschoben") { await BildProbe.bounds(self.object(s, overlay.pageKey, id)).minX < 5 }
        let corner = BildProbe.bounds(await object(s, overlay.pageKey, id))
        XCTAssertTrue(page(overlay).insetBy(dx: -0.6, dy: -0.6).contains(corner), "\(corner)")
        s.editor.undo()
        try await BildProbe.wait("Rueckgaengig: ein Schritt zurueck") { await abs(BildProbe.bounds(self.object(s, overlay.pageKey, id)).minX - moved.minX) < 0.6 }
    }

    /// Hineingezoomt und nach unten gescrollt: ein neues Bild liegt ganz im sichtbaren Teil der Seite und ist ausgewaehlt
    /// (vorher immer oben auf der Seite bei y = 60, also ausserhalb des Bildschirms)
    func testNeuesBildLiegtImSichtbarenTeilUndIstAusgewaehlt() async throws {
        let s = try await open()
        let overlay = try await overlay(s)
        let page1 = try XCTUnwrap(s.editor.pdfView.document?.page(at: 0))
        s.editor.pdfView.scaleFactor *= 1.6
        // unterer Teil von Seite 1 (PDF-Koordinaten: Ursprung unten links)
        s.editor.pdfView.go(to: CGRect(x: 150, y: 120, width: 10, height: 10), on: page1)
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(s.editor.currentPageIndex, 0)
        let visible = try XCTUnwrap(overlay.viewportInPage()).intersection(page(overlay))
        XCTAssertGreaterThan(visible.minY, 150, "nach unten gescrollt: \(visible)")
        let ok = await s.editor.insertPickedImage(BildProbe.foto())
        XCTAssertTrue(ok)
        let listed = await s.store.objects(forPageKey: overlay.pageKey)
        let o = try XCTUnwrap(listed.last)
        let b = BildProbe.bounds(o)
        XCTAssertTrue(visible.insetBy(dx: -0.6, dy: -0.6).contains(b), "Bild \(b) ganz im sichtbaren Teil \(visible)")
        XCTAssertEqual(s.editor.objects.selection?.ids, [try XCTUnwrap(o["id"]?.string)], "gleich ausgewaehlt")
        XCTAssertTrue(s.editor.objects.isActive, "Auswaehlen ist an: gleich verschieben und Groesse aendern")
        s.editor.undo()
        try await BildProbe.wait("Rueckgaengig nimmt das Bild wieder weg") { await s.store.objects(forPageKey: overlay.pageKey).isEmpty }
    }

    // MARK: "blauer Kasten, der verzerrt mitgeht"

    /// Waehrend ein Finger das Bild zieht, liegt der Rahmen in jedem Moment auf dem Bild (vorher lief der Rahmen dem
    /// Bild hinterher). Bei Seitenbreite, hineingezoomt und in einer schmalen Spalte wie die Notiz daneben.
    func testRahmenLiegtBeimZiehenAufDemBild() async throws {
        try XCTSkipUnless(TestFinger.verfuegbar, "Beruehrung laesst sich in dieser iOS-Version nicht nachstellen")
        for (name, width, zoom) in [("Seitenbreite", CGFloat(1080), CGFloat(1)), ("gezoomt", 1080, 1.7), ("schmale Spalte", 430, 1)] {
            let s = try await open(width: width)
            if zoom != 1 {
                s.editor.pdfView.scaleFactor *= zoom
                try await Task.sleep(nanoseconds: 600_000_000)
            }
            let (overlay, id) = try await insert(s, BildProbe.foto(CGSize(width: 240, height: 120)), at: CGPoint(x: 40, y: 60))
            let start = BildProbe.bounds(await object(s, overlay.pageKey, id))
            var worst: CGFloat = 0
            var samples = 0
            try await BildProbe.drag(from: CGPoint(x: start.midX, y: start.midY), to: CGPoint(x: start.midX + 90, y: start.midY + 70), on: overlay, in: s.window) {
                if let d = BildProbe.deviation(overlay) { worst = max(worst, d); samples += 1 }
            }
            XCTAssertGreaterThan(samples, 8, name)
            XCTAssertLessThanOrEqual(worst, 1.5, "\(name): Rahmen weicht beim Ziehen bis zu \(worst) pt vom Bild ab")
            try await BildProbe.wait("\(name): verschoben gespeichert") { await BildProbe.bounds(self.object(s, overlay.pageKey, id)).minX > start.minX + 40 }
            let moved = BildProbe.bounds(await object(s, overlay.pageKey, id))
            // die Geste beginnt nach 10 Bildschirmpunkten Weg (wie ueberall in iPadOS); um die bleibt das Bild zurueck
            let slop = 12 / ObjectEditing.screenScale(of: overlay) + 4
            XCTAssertEqual(moved.minX - start.minX, 90, accuracy: slop, name)
            XCTAssertEqual(moved.minY - start.minY, 70, accuracy: slop, name)
            XCTAssertEqual(moved.size.width, start.size.width, accuracy: 0.01, "\(name): Verschieben aendert die Groesse nicht")
            try await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertEqual(BildProbe.deviation(overlay) ?? 99, 0, accuracy: 0.8, "\(name): Rahmen nach dem Loslassen auf dem Bild")
            s.window.isHidden = true
        }
    }

    /// Zwei Finger auf dem ausgewaehlten Bild: Bild und Rahmen werden zusammen kleiner (vorher nur der Rahmen, das Bild
    /// sprang erst beim Loslassen); die Seite zoomt dabei nicht
    func testPinchZeigtBildUndRahmenGleich() async throws {
        try XCTSkipUnless(TestFinger.verfuegbar, "Beruehrung laesst sich in dieser iOS-Version nicht nachstellen")
        let s = try await open()
        let (overlay, id) = try await insert(s, at: CGPoint(x: 120, y: 150))
        let start = BildProbe.bounds(await object(s, overlay.pageKey, id))
        let zoom = s.editor.pdfView.scaleFactor
        let center = overlay.content.convert(CGPoint(x: start.midX, y: start.midY), to: nil)
        var worst: CGFloat = 0
        var smallest = start.width
        try await TestFinger.Zwei.pinch(center: center, from: 220, to: 120, steps: 24, in: s.window) {
            if let d = BildProbe.deviation(overlay) { worst = max(worst, d) }
            if let i = BildProbe.imageShown(overlay) { smallest = min(smallest, i.width) }
        }
        try await BildProbe.wait("kleiner gespeichert") { await BildProbe.bounds(self.object(s, overlay.pageKey, id)).width < start.width - 20 }
        let small = BildProbe.bounds(await object(s, overlay.pageKey, id))
        XCTAssertEqual(small.width / small.height, start.width / start.height, accuracy: 0.02)
        XCTAssertEqual(small.width / start.width, 120.0 / 220, accuracy: 0.15, "etwa so viel kleiner, wie die Finger zusammengingen")
        XCTAssertLessThan(smallest, start.width - 20, "das Bild selbst wird schon waehrend der Geste kleiner")
        XCTAssertLessThanOrEqual(worst, 1.5, "Rahmen und Bild gehen zusammen (groesste Abweichung \(worst) pt)")
        XCTAssertEqual(s.editor.pdfView.scaleFactor, zoom, accuracy: 0.001, "die Seite zoomt nicht mit")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(BildProbe.deviation(overlay) ?? 99, 0, accuracy: 0.8)
        s.editor.undo()
        try await BildProbe.wait("Rueckgaengig: Ausgangsgroesse") { await abs(BildProbe.bounds(self.object(s, overlay.pageKey, id)).width - start.width) < 0.6 }
    }
}

/// Geste mit vorgegebenem Zustand: ruft im Test die Ziel-Methode so auf, wie UIKit es bei einem abgebrochenen bzw.
/// beendeten Ziehen tut
private final class GestellterZug: UIPanGestureRecognizer {
    private var gestellt: UIGestureRecognizer.State
    init(_ state: UIGestureRecognizer.State) {
        gestellt = state
        super.init(target: nil, action: nil)
    }
    override var state: UIGestureRecognizer.State {
        get { gestellt }
        set { gestellt = newValue }
    }
}

/// Zaehlt und misst den Berührungs-Melder eines Editors (`EditorTouchMarker`)
@MainActor
final class MelderProbe {
    private(set) var calls = 0
    private(set) var seconds: [Double] = []

    init?(_ editor: PDFEditorController) {
        guard let marker = editor.pdfView.gestureRecognizers?.compactMap({ $0 as? EditorTouchMarker }).first else { return nil }
        let old = marker.onTouch
        marker.onTouch = { [weak self] in
            let t = CACurrentMediaTime()
            old?()
            self?.calls += 1
            self?.seconds.append(CACurrentMediaTime() - t)
        }
    }

    var median: Double { seconds.sorted()[seconds.count / 2] }
}

/// Hauptdokument und Notiz daneben wie in der App (`DocumentView` mit `CompanionView`)
@MainActor
final class BildInNotizAppTests: XCTestCase {

    override func setUpWithError() throws {
        let before = Entitlements.shared.plan
        Entitlements.shared.setPlanForTesting(.plus)
        addTeardownBlock { @MainActor in Entitlements.shared.setPlanForTesting(before) }
        HostedEnvironment.accessibilityAutomation(true)
        addTeardownBlock { @MainActor in HostedEnvironment.accessibilityAutomation(false) }
    }

    private func folien(_ n: Int) -> Data {
        let raw = NSMutableData()
        let size = CGSize(width: 960, height: 540)
        UIGraphicsBeginPDFContextToData(raw, CGRect(origin: .zero, size: size), nil)
        for i in 1...n {
            UIGraphicsBeginPDFPageWithInfo(CGRect(origin: .zero, size: size), nil)
            "Übung \(i): Eigenwerte".draw(at: CGPoint(x: 30, y: 20), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 34)])
        }
        UIGraphicsEndPDFContext()
        return raw as Data
    }

    /// Uebungsblatt (PDF) und ein eigenes Notizblatt dazu
    private func scene() async throws -> (api: APIClient, main: LibFile, sheetID: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bild-notiz-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let host = LocalBackendHost(directory: root.appendingPathComponent("db", isDirectory: true), clock: .fixed(berlin: "2026-11-21T10:00:00")!,
                                    files: LocalFiles(container: root, dataDirectory: "Library/Application Support/UniFlow", tools: AppDocumentTools()))
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
        let src = root.appendingPathComponent("Übungsblatt 4.pdf")
        try folien(2).write(to: src)
        let mainID = try await ExternalFileImport.create(try ExternalFileImport.stage(src, container: nil), api: api)
        let main = try await api.json("/api/files/\(mainID)", as: LibFile.self)
        let fields = NotebookDialog.fields(kind: "notebook", title: CompanionPicker.sheetTitle(for: main.displayTitle), template: "grid",
                                           format: PageFormats.defaultNotebook, orientation: .portrait)
        let created = try await api.form("/api/notebooks", fields: fields)
        let sheetID = try XCTUnwrap(created.s("id"))
        let sheetFile = try await api.json("/api/files/\(sheetID)", as: LibFile.self)
        let mainStore = DocumentStore(file: main, api: api)
        await mainStore.load()
        let sheet = DocumentStore(file: sheetFile, api: api)
        await sheet.load()
        let bridge = EditorBridge()
        bridge.pageKey = mainStore.pageKey(forPageIndex: 0)
        DocumentView.linkSideSheet(sheet, shown: true, main: mainStore, bridge: bridge)
        await sheet.addText("λ = 1, λ = 3", pageKey: try XCTUnwrap(sheet.pageKey(forPageIndex: 0)))
        await sheet.flush()
        try await Task.sleep(nanoseconds: 300_000_000)
        DocumentView.linkSideSheet(sheet, shown: false, main: mainStore, bridge: bridge)
        await sheet.close()
        await mainStore.close()
        return (api, main, sheetID)
    }

    /// Bild des Fensters fuer die Sichtpruefung, nur mit UF_SCREENSHOT_DIR (sonst nichts)
    static func shot(_ view: UIView, _ name: String) {
        guard let d = ProcessInfo.processInfo.environment["UF_SCREENSHOT_DIR"], !d.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let png = UIGraphicsImageRenderer(bounds: view.bounds, format: format).pngData { _ in
            _ = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        try? png.write(to: URL(fileURLWithPath: d).appendingPathComponent(name + ".png"))
    }

    @discardableResult
    private func run<T>(timeout: Double = 90, _ body: @escaping @MainActor () async throws -> T) throws -> T {
        var result: Result<T, Error>?
        Task { @MainActor in
            do { result = .success(try await body()) } catch { result = .failure(error) }
        }
        let end = Date().addingTimeInterval(timeout)
        while result == nil, Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return try XCTUnwrap(result, "Zeitlimit").get()
    }

    private func elements(in root: Any) -> [NSObject] {
        var out: [NSObject] = []
        func visit(_ element: Any, depth: Int) {
            guard depth < 60 else { return }
            if let o = element as? NSObject {
                out.append(o)
                for e in o.accessibilityElements ?? [] { visit(e, depth: depth + 1) }
                let n = o.accessibilityElementCount()
                if n != NSNotFound, n > 0 { for i in 0..<min(n, 500) { if let e = o.accessibilityElement(at: i) { visit(e, depth: depth + 1) } } }
            }
            if let v = element as? UIView { for s in v.subviews { visit(s, depth: depth + 1) } }
        }
        visit(root, depth: 0)
        return out
    }

    private func tapButton(_ text: String, in root: UIView) -> Bool {
        for e in elements(in: root) where e.accessibilityTraits.contains(.button) {
            guard let l = e.accessibilityLabel, l.contains(text) else { continue }
            if e.accessibilityActivate() { return true }
        }
        return false
    }

    private func tapIdentified(_ id: String, in root: UIView) -> Bool {
        for e in elements(in: root) {
            guard (e as? UIAccessibilityIdentification)?.accessibilityIdentifier == id else { continue }
            if e.accessibilityActivate() { return true }
        }
        return false
    }

    private func shows(_ text: String, in root: UIView) -> Bool {
        elements(in: root).contains { ($0.accessibilityLabel ?? "").contains(text) }
    }

    /// Editoren im Fenster (Hauptdokument fuehrt die Leiste, das Dokument daneben nicht)
    private func editors(in root: UIView) -> [PDFEditorController] {
        var out: [PDFEditorController] = []
        func visit(_ v: UIView) {
            if v is PDFView {
                var r: UIResponder? = v
                while let x = r { if let c = x as? PDFEditorController { if !out.contains(where: { $0 === c }) { out.append(c) }; break }; r = x.next }
            }
            v.subviews.forEach(visit)
        }
        visit(root)
        return out
    }

    private func shownOverlay(_ editor: PDFEditorController) -> PageInkView? {
        editor.allOverlays.first { $0.pageIndex == editor.currentPageIndex && $0.window != nil && $0.generation == editor.shownLayoutVersion && $0.loaded }
    }

    private func images(_ editor: PDFEditorController) async -> [JSONValue] {
        var out: [JSONValue] = []
        for i in 0..<editor.pageCount {
            guard let key = editor.store.pageKey(forPageIndex: i) else { continue }
            out += await editor.store.objects(forPageKey: key).filter { $0["type"]?.string == "image" }
        }
        return out
    }

    /// Wunsch des Inhabers (21.11.2026): ein ausgewaehltes Bild ueber die Trennlinie ins andere Dokument ziehen. Haupt ->
    /// Notiz und zurueck, Rueckgaengig/Wiederholen als EIN Schritt, Loslassen auf der Trennlinie, Ziel nur zum Ansehen,
    /// und das Bild gehoert danach der Zieldatei (eigene Adresse, dieselben Bytes, nach erneutem Oeffnen noch da).
    func testBildInsAndereDokumentZiehen() throws {
        let x = try openSplit()
        let main = x.main, side = x.side, mainPage = x.mainPage, sidePage = x.sidePage, window = x.env.window, api = x.api
        func pageRect(_ o: PageInkView) -> CGRect { CGRect(origin: .zero, size: o.geometry.pageSize) }
        func center(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }
        /// Bilder im Hauptdokument und in der Notiz
        func counts() async -> [Int] {
            let m = await self.images(main).count, n = await self.images(side).count
            return [m, n]
        }
        try run {
            // Bild im Hauptdokument (noch nirgends gearbeitet), ausgewaehlt
            let inserted = await main.insertPickedImage(BildProbe.foto())
            XCTAssertTrue(inserted)
            var inMain = await self.images(main), inSide = await self.images(side)
            XCTAssertEqual([inMain.count, inSide.count], [1, 0])
            let original = try XCTUnwrap(inMain.first), id0 = try XCTUnwrap(original["id"]?.string), src0 = try XCTUnwrap(original["src"]?.string)
            XCTAssertTrue(src0.hasPrefix("/api/assets/\(x.mainID)/"), src0)
            let b0 = BildProbe.bounds(original)
            try await BildProbe.wait("Bild mit Rahmen im Hauptdokument") { BildProbe.imageShown(mainPage) != nil && BildProbe.frameShown(mainPage) != nil }

            // 1. Haupt -> Notiz: ziehen, bis der Finger ueber der Notizseite liegt, und loslassen
            let sideFree = try XCTUnwrap(sidePage.viewportInPage()).intersection(pageRect(sidePage))
            let drop = CGPoint(x: sideFree.midX, y: sideFree.minY + 250)
            var sawFloating = false, sawFrame = false, floatOff: CGFloat = 0, sourceOverEdge: CGFloat = 0
            try await BildProbe.dragWindow(from: mainPage.content.convert(center(b0), to: nil), to: sidePage.content.convert(drop, to: nil), in: window) { p in
                if let f = BildProbe.floating(in: window) {
                    sawFloating = true
                    if let frame = BildProbe.dropFrame(sidePage) {
                        if !sawFrame { Self.shot(window, "ziehen-ueber-der-notiz") }
                        sawFrame = true
                        // ueber der Zielseite: das schwebende Bild liegt genau dort, wo es landet
                        let land = sidePage.content.convert(frame.insetBy(dx: 4, dy: 4), to: nil)
                        floatOff = max(floatOff, abs(f.frame.midX - land.midX), abs(f.frame.midY - land.midY), abs(f.frame.width - land.width))
                    } else {
                        floatOff = max(floatOff, abs(f.frame.midX - p.x), abs(f.frame.midY - p.y))
                    }
                }
                if let i = BildProbe.imageShown(mainPage) { sourceOverEdge = max(sourceOverEdge, -i.minX, i.maxX - mainPage.geometry.pageSize.width) }
            }
            XCTAssertTrue(sawFloating, "schwebendes Bild folgt dem Finger ausserhalb des eigenen Dokuments")
            XCTAssertTrue(sawFrame, "die Notizseite zeigt, wo das Bild landet")
            XCTAssertLessThanOrEqual(floatOff, 2, "schwebendes Bild liegt am Finger bzw. an der Landestelle")
            XCTAssertLessThanOrEqual(sourceOverEdge, 1, "im Hauptdokument bleibt die Vorschau auf der Seite")
            try await BildProbe.wait("Bild liegt in der Notiz") { await counts() == [0, 1] }
            inSide = await self.images(side)
            let moved = try XCTUnwrap(inSide.first), id1 = try XCTUnwrap(moved["id"]?.string), src1 = try XCTUnwrap(moved["src"]?.string)
            XCTAssertNotEqual(id1, id0)
            XCTAssertTrue(src1.hasPrefix("/api/assets/\(x.sheetID)/"), "eigenes Bild der Notiz-Datei: \(src1)")
            let b1 = BildProbe.bounds(moved)
            XCTAssertEqual(b1.width, b0.width, accuracy: 0.6, "gleiche Groesse in Seitenpunkten")
            XCTAssertEqual(b1.height, b0.height, accuracy: 0.6)
            XCTAssertEqual(b1.midX, drop.x, accuracy: 2, "liegt um den Finger")
            XCTAssertEqual(b1.midY, drop.y, accuracy: 2)
            XCTAssertTrue(pageRect(sidePage).insetBy(dx: -0.6, dy: -0.6).contains(b1))
            try await BildProbe.wait("in der Notiz ausgewaehlt, mit Rahmen") { side.objects.selection?.ids == [id1] && BildProbe.frameShown(sidePage) != nil }
            XCTAssertNil(main.objects.selection)
            XCTAssertTrue(main.tools.activeEditor === side, "in der Notiz wird weitergearbeitet")
            XCTAssertNil(BildProbe.floating(in: window), "schwebendes Bild ist weg")
            XCTAssertNil(BildProbe.dropFrame(sidePage))
            // dieselben Bytes, nichts neu kodiert
            let (data0, _) = try await api.data(src0), (data1, http1) = try await api.data(src1)
            XCTAssertEqual(http1.statusCode, 200)
            XCTAssertEqual(data1, data0, "dieselben Bilddaten in der Zieldatei")

            // 2. Rueckgaengig: EIN Schritt holt es zurueck (gleiche Stelle, gleiches Bild), der naechste nimmt das Einfuegen
            main.undo()
            try await BildProbe.wait("Rueckgaengig: zurueck im Hauptdokument") { await counts() == [1, 0] }
            inMain = await self.images(main)
            XCTAssertEqual(inMain.first?["id"]?.string, id0)
            XCTAssertEqual(inMain.first?["src"]?.string, src0)
            XCTAssertEqual(BildProbe.bounds(inMain.first), b0, "an seiner alten Stelle")
            main.undo()
            try await BildProbe.wait("zweites Rueckgaengig: das Einfuegen") { await self.images(main).isEmpty }
            inSide = await self.images(side)
            XCTAssertTrue(inSide.isEmpty)
            main.redo()
            try await BildProbe.wait("Wiederholen: eingefuegt") { await self.images(main).count == 1 }
            main.redo()
            try await BildProbe.wait("Wiederholen: wieder in der Notiz") { await counts() == [0, 1] }
            inSide = await self.images(side)
            XCTAssertEqual(inSide.first?["id"]?.string, id1)
            XCTAssertEqual(BildProbe.bounds(inSide.first), b1)

            // 3. Notiz -> Hauptdokument
            try await BildProbe.wait("Bild in der Notiz zu sehen") { BildProbe.imageShown(sidePage) != nil }
            try await BildProbe.tap(center(b1), on: sidePage, in: window)
            try await BildProbe.wait("in der Notiz ausgewaehlt") { side.objects.selection?.ids == [id1] }
            let mainFree = try XCTUnwrap(mainPage.viewportInPage()).intersection(pageRect(mainPage))
            let back = CGPoint(x: mainFree.midX, y: mainFree.minY + 200)
            try await BildProbe.dragWindow(from: sidePage.content.convert(center(b1), to: nil), to: mainPage.content.convert(back, to: nil), in: window)
            try await BildProbe.wait("Bild liegt im Hauptdokument") { await counts() == [1, 0] }
            inMain = await self.images(main)
            let home = try XCTUnwrap(inMain.first), id2 = try XCTUnwrap(home["id"]?.string), src2 = try XCTUnwrap(home["src"]?.string)
            XCTAssertTrue(src2.hasPrefix("/api/assets/\(x.mainID)/"), "eigenes Bild des Hauptdokuments: \(src2)")
            let b2 = BildProbe.bounds(home)
            XCTAssertEqual(b2.width, b0.width, accuracy: 0.6)
            XCTAssertEqual(b2.midX, back.x, accuracy: 2)
            XCTAssertEqual(b2.midY, back.y, accuracy: 2)
            try await BildProbe.wait("im Hauptdokument ausgewaehlt") { main.objects.selection?.ids == [id2] && BildProbe.frameShown(mainPage) != nil }
            XCTAssertTrue(main.tools.activeEditor === main)

            // 4. auf der Trennlinie losgelassen: bleibt im Hauptdokument, ganz auf der Seite
            let a = main.pdfView.convert(main.pdfView.bounds, to: nil), b = side.pdfView.convert(side.pdfView.bounds, to: nil)
            let gapX = a.minX > b.maxX ? (a.minX + b.maxX) / 2 : (b.minX + a.maxX) / 2
            let start = mainPage.content.convert(center(b2), to: nil)
            try await BildProbe.dragWindow(from: start, to: CGPoint(x: gapX, y: start.y), in: window)
            try await Task.sleep(nanoseconds: 500_000_000)
            inMain = await self.images(main); inSide = await self.images(side)
            XCTAssertEqual([inMain.count, inSide.count], [1, 0], "Trennlinie: nichts geht hinueber")
            XCTAssertEqual(inMain.first?["id"]?.string, id2)
            let b3 = BildProbe.bounds(inMain.first)
            XCTAssertTrue(pageRect(mainPage).insetBy(dx: -0.6, dy: -0.6).contains(b3), "ganz auf der Seite: \(b3)")
            XCTAssertNil(BildProbe.floating(in: window))
            XCTAssertEqual(main.objects.selection?.ids, [id2], "bleibt ausgewaehlt")
            try await BildProbe.wait("Rahmen wieder auf dem Bild") { (BildProbe.deviation(mainPage) ?? 99) < 0.8 }

            // 5. Ziel nur zum Ansehen: nichts wird verschoben, Hinweis
            side.canEdit = false
            var frameOnReadOnly = false
            try await BildProbe.dragWindow(from: mainPage.content.convert(center(b3), to: nil), to: sidePage.content.convert(drop, to: nil), in: window) { _ in
                if BildProbe.dropFrame(sidePage) != nil { frameOnReadOnly = true }
            }
            XCTAssertFalse(side.writable, "Notiz war beim Loslassen nur zum Ansehen")
            try await Task.sleep(nanoseconds: 500_000_000)
            inMain = await self.images(main); inSide = await self.images(side)
            XCTAssertEqual([inMain.count, inSide.count], [1, 0], "nur ansehen: nichts geht hinueber")
            XCTAssertEqual(BildProbe.bounds(inMain.first), b3, "das Bild bleibt, wo es war")
            XCTAssertFalse(frameOnReadOnly, "eine Seite, die nichts annimmt, zeigt keinen Rahmen")
            XCTAssertNil(BildProbe.floating(in: window))
            try await BildProbe.wait("Hinweis zu sehen", timeout: 4) { self.shows("nur zum Ansehen", in: window) }
            side.canEdit = true

            // 5b. das Anlegen in der Zieldatei scheitert (sie nimmt gerade nichts an): nichts geht verloren, nichts doppelt
            side.store.canEdit = false
            try await BildProbe.dragWindow(from: mainPage.content.convert(center(b3), to: nil), to: sidePage.content.convert(drop, to: nil), in: window)
            try await BildProbe.wait("Hinweis zu sehen", timeout: 4) { self.shows("ließ sich nicht ins andere Dokument", in: window) }
            inMain = await self.images(main); inSide = await self.images(side)
            XCTAssertEqual([inMain.count, inSide.count], [1, 0], "gescheitert: das Bild bleibt im Hauptdokument")
            XCTAssertEqual(BildProbe.bounds(inMain.first), b3, "an seinem Platz")
            XCTAssertNil(BildProbe.floating(in: window))
            try await BildProbe.wait("Bild wieder deckend und ausgewaehlt") { main.objects.selection?.ids == [id2] && (BildProbe.deviation(mainPage) ?? 99) < 0.8 }
            let shownAlpha = mainPage.objectsView.subviews.compactMap { $0 as? UIImageView }.last?.alpha ?? 0
            XCTAssertEqual(shownAlpha, 1, accuracy: 0.01, "nicht mehr blass")
            side.store.canEdit = true
            XCTAssertFalse(main.editUndo.undoActionName == "Bild verschieben", "ein gescheitertes Hinueberziehen steht nicht im Verlauf")

            // 6. hinueber und die Notiz neu oeffnen: das Bild ist da und gehoert der Notiz-Datei
            try await BildProbe.dragWindow(from: mainPage.content.convert(center(b3), to: nil), to: sidePage.content.convert(drop, to: nil), in: window)
            try await BildProbe.wait("wieder in der Notiz") { await counts() == [0, 1] }
            inSide = await self.images(side)
            let kept = try XCTUnwrap(inSide.first), id3 = try XCTUnwrap(kept["id"]?.string), src3 = try XCTUnwrap(kept["src"]?.string)
            await side.store.flush()
            let sheetFile = try await api.json("/api/files/\(x.sheetID)", as: LibFile.self)
            let again = DocumentStore(file: sheetFile, api: api)
            await again.load()
            XCTAssertNil(again.errorMessage, again.errorMessage ?? "")
            var found: JSONValue?
            for i in 0..<(again.layout?.entries.count ?? 0) {
                guard let key = again.pageKey(forPageIndex: i) else { continue }
                if let o = await again.objects(forPageKey: key).first(where: { $0["id"]?.string == id3 }) { found = o }
            }
            XCTAssertEqual(found?["src"]?.string, src3, "nach erneutem Oeffnen liegt das Bild in der Notiz")
            XCTAssertTrue(src3.hasPrefix("/api/assets/\(x.sheetID)/"))
            let (stored, http) = try await api.data(src3)
            XCTAssertEqual(http.statusCode, 200)
            XCTAssertNotNil(UIImage(data: stored), "Bild der Notiz-Datei ist lesbar")
            await again.close()
        }
    }

    /// Ganzer Weg der Meldung: Notiz daneben oeffnen, dort arbeiten, Bild einfuegen -> es liegt in der Notiz, sichtbar
    /// und ausgewaehlt, laesst sich dort mit dem Finger verschieben und an der Ecke kleiner ziehen. Wer danach wieder im
    /// Hauptdokument arbeitet, bekommt das naechste Bild dort; ist die Notiz zu, immer das Hauptdokument.
    func testBildLandetImZuletztBenutztenDokument() throws {
        let x = try openSplit()
        let env = x.env, main = x.main, side = x.side, mainPage = x.mainPage, sidePage = x.sidePage, window = x.env.window
        try landetImZuletztBenutzten(env, main, side, mainPage, sidePage, window)
    }

    struct Split {
        let env: HostedEnvironment
        let api: APIClient
        let main: PDFEditorController
        let side: PDFEditorController
        let mainPage: PageInkView
        let sidePage: PageInkView
        let mainID: String
        let sheetID: String
    }

    /// Dokument oeffnen, "Daneben öffnen" und das eigene Notizblatt waehlen: beide Editoren geladen
    private func openSplit() throws -> Split {
        try XCTSkipUnless(TestFinger.verfuegbar, "Beruehrung laesst sich in dieser iOS-Version nicht nachstellen")
        let s = try run { try await self.scene() }
        let previous = UserDefaults.standard.object(forKey: "UFDocPanel")
        UserDefaults.standard.set("companion", forKey: "UFDocPanel")
        addTeardownBlock { @MainActor in UserDefaults.standard.set(previous, forKey: "UFDocPanel") }
        let env = try hostWithEnvironment(NavigationStack { DocumentView(file: s.main, api: s.api) }, api: s.api, size: CGSize(width: 1180, height: 820))
        env.pump(1.0)
        Entitlements.shared.setPlanForTesting(.plus)
        XCTAssertTrue(env.wait(timeout: 20) { self.shows("Deine Blätter", in: env.window) }, "Auswahl „Daneben öffnen“")
        env.pump(0.5)
        XCTAssertTrue(tapButton("Notizen – Übungsblatt 4", in: env.window), "eigenes Blatt antippen")
        UserDefaults.standard.set(previous, forKey: "UFDocPanel")
        Entitlements.shared.setPlanForTesting(.plus)
        XCTAssertTrue(env.wait(timeout: 20) {
            let e = self.editors(in: env.window)
            return e.count == 2 && e.allSatisfy { self.shownOverlay($0) != nil }
        }, "Hauptdokument und Notiz daneben sind geladen")
        env.pump(1.0)
        let all = editors(in: env.window)
        let main = try XCTUnwrap(all.first { $0.ownsToolPicker }), side = try XCTUnwrap(all.first { !$0.ownsToolPicker })
        XCTAssertTrue(main.writable && side.writable, "beide schreibbar")
        let mainPage = try XCTUnwrap(shownOverlay(main)), sidePage = try XCTUnwrap(shownOverlay(side))
        return Split(env: env, api: s.api, main: main, side: side, mainPage: mainPage, sidePage: sidePage, mainID: s.main.id, sheetID: s.sheetID)
    }

    private func landetImZuletztBenutzten(_ env: HostedEnvironment, _ main: PDFEditorController, _ side: PDFEditorController,
                                          _ mainPage: PageInkView, _ sidePage: PageInkView, _ window: UIWindow) throws {
        try run {
            // 1. noch nirgends gearbeitet: wie bisher ins Hauptdokument
            var ok = await main.insertPickedImage(BildProbe.foto())
            XCTAssertTrue(ok)
            var inMain = await self.images(main), inSide = await self.images(side)
            XCTAssertEqual([inMain.count, inSide.count], [1, 0], "ohne Arbeit in der Notiz: Hauptdokument")

            // 2. in der Notiz gearbeitet (Finger tippt hinein), dann "Bild aus Fotos …"
            let free = try XCTUnwrap(sidePage.viewportInPage()).intersection(CGRect(origin: .zero, size: sidePage.geometry.pageSize))
            try await BildProbe.tap(CGPoint(x: free.midX, y: free.maxY - 40), on: sidePage, in: window)
            ok = await main.insertPickedImage(BildProbe.foto())
            XCTAssertTrue(ok)
            inMain = await self.images(main); inSide = await self.images(side)
            XCTAssertEqual([inMain.count, inSide.count], [1, 1], "nach Arbeit in der Notiz landet das Bild in der Notiz")
            guard let placed = inSide.last, let id = placed["id"]?.string else { return }
            let b0 = BildProbe.bounds(placed)
            XCTAssertTrue(free.insetBy(dx: -0.6, dy: -0.6).contains(b0), "ganz im sichtbaren Teil der Notiz: \(b0) in \(free)")
            XCTAssertLessThanOrEqual(b0.width, sidePage.geometry.pageSize.width * 0.5 + 0.6)
            try await BildProbe.wait("Bild mit Rahmen in der Notiz zu sehen") { BildProbe.imageShown(sidePage) != nil && BildProbe.frameShown(sidePage) != nil }
            XCTAssertEqual(side.objects.selection?.ids, [id], "in der Notiz ausgewaehlt")
            XCTAssertTrue(side.objects.isActive, "in der Notiz laesst es sich anfassen")
            XCTAssertNil(main.objects.selection, "im Hauptdokument ist nichts ausgewaehlt")

            // 3. Einfuegen aus der Zwischenablage (Cmd-V): auch in die Notiz
            let pb = UIPasteboard(name: UIPasteboard.Name("bild-notiz-\(UUID().uuidString)"), create: true)!
            defer { UIPasteboard.remove(withName: pb.name) }
            pb.image = BildProbe.foto(CGSize(width: 120, height: 120))
            ok = await main.pasteClipboard(from: pb)
            XCTAssertTrue(ok)
            inMain = await self.images(main); inSide = await self.images(side)
            XCTAssertEqual([inMain.count, inSide.count], [1, 2], "Einfuegen geht ebenfalls in die Notiz")

            // 4. das erste Bild in der Notiz antippen und mit dem Finger verschieben: Rahmen bleibt auf dem Bild
            func object() async -> JSONValue? { await self.images(side).first { $0["id"]?.string == id } }
            // (das eingefuegte zweite liegt mittig darueber: am linken Rand des ersten greifen)
            let grabAt = CGPoint(x: b0.minX + 22, y: b0.midY)
            let slop = 12 / ObjectEditing.screenScale(of: sidePage) + 4
            try await BildProbe.tap(grabAt, on: sidePage, in: window)
            try await BildProbe.wait("erstes Bild ausgewaehlt") { side.objects.selection?.ids == [id] }
            var worst: CGFloat = 0
            try await BildProbe.drag(from: grabAt, to: CGPoint(x: grabAt.x + 60, y: grabAt.y + 80), on: sidePage, in: window) {
                if let f = BildProbe.frameShown(sidePage) {
                    let shown = sidePage.objectsView.subviews.compactMap { $0 as? UIImageView }.map { ($0.layer.presentation() ?? $0.layer).frame }
                    let d = shown.map { max(abs($0.minX - f.minX), abs($0.minY - f.minY), abs($0.maxX - f.maxX), abs($0.maxY - f.maxY)) }.min() ?? 99
                    worst = max(worst, d)
                }
            }
            try await BildProbe.wait("in der Notiz verschoben") { await BildProbe.bounds(object()).minY > b0.minY + 20 }
            let b1 = BildProbe.bounds(await object())
            XCTAssertEqual(b1.minX - b0.minX, 60, accuracy: slop)
            XCTAssertEqual(b1.minY - b0.minY, 80, accuracy: slop)
            XCTAssertLessThanOrEqual(worst, 1.5, "Rahmen bleibt in der schmalen Spalte auf dem Bild (\(worst) pt)")

            Self.shot(window, "notiz-bild-ausgewaehlt")

            // 5. an der Ecke kleiner ziehen
            let frame = try XCTUnwrap(BildProbe.frameShown(sidePage)).insetBy(dx: -4, dy: -4)
            let corner = CGPoint(x: frame.maxX, y: frame.maxY)
            XCTAssertTrue(BildProbe.handles(sidePage).contains { hypot($0.x - corner.x, $0.y - corner.y) < 3 }, "Anfasser auch in der Notiz")
            try await BildProbe.drag(from: corner, to: CGPoint(x: corner.x - 80, y: corner.y - 40), on: sidePage, in: window)
            try await BildProbe.wait("in der Notiz kleiner") { await BildProbe.bounds(object()).width < b1.width - 20 }
            let b2 = BildProbe.bounds(await object())
            XCTAssertEqual(b2.width, b1.width - 80, accuracy: slop)
            XCTAssertEqual(b2.width / b2.height, b1.width / b1.height, accuracy: 0.02)

            // 6. Rueckgaengig der gemeinsamen Leiste: erst die Groesse, dann das Verschieben
            main.undo()
            try await BildProbe.wait("Rueckgaengig: Groesse") { await abs(BildProbe.bounds(object()).width - b1.width) < 0.6 }
            main.undo()
            try await BildProbe.wait("Rueckgaengig: Lage") { await abs(BildProbe.bounds(object()).minY - b0.minY) < 0.6 }

            // 6b. Papierkorb der Objektleiste (gehoert zum Hauptdokument) loescht die Auswahl in der Notiz
            try await BildProbe.tap(grabAt, on: sidePage, in: window)
            try await BildProbe.wait("wieder ausgewaehlt") { side.objects.selection?.ids == [id] }
            XCTAssertTrue(self.tapButton("Auswahl löschen", in: window), "Papierkorb der Objektleiste ist da und an")
            try await BildProbe.wait("Bild in der Notiz geloescht") { await self.images(side).count == 1 }
            inMain = await self.images(main)
            XCTAssertEqual(inMain.count, 1, "im Hauptdokument bleibt alles")
            main.undo()
            try await BildProbe.wait("Rueckgaengig: Bild wieder in der Notiz") { await self.images(side).count == 2 }

            // 6c. Wechsel zwischen den Dokumenten ohne Auswahl (schreiben, scrollen): der Melder setzt nur einen Verweis -
            // nichts geht an SwiftUI oder an die Objektleiste, und je Beruehrung meldet er sich einmal
            try await BildProbe.tap(CGPoint(x: free.midX, y: free.maxY - 40), on: sidePage, in: window)
            XCTAssertNil(side.objects.selection)
            let mainProbe = MelderProbe(main), sideProbe = MelderProbe(side)
            var published = 0, selections = 0
            let watch = main.tools.objectWillChange.sink { published += 1 }
            let forward = main.tools.onActiveSelection
            main.tools.onActiveSelection = { n in selections += 1; forward?(n) }
            let mainSpot = try XCTUnwrap(mainPage.viewportInPage()).intersection(CGRect(origin: .zero, size: mainPage.geometry.pageSize))
            for _ in 0..<3 {
                // (ein kurzes Wischen wie beim Blaettern, kein Tipp)
                try await BildProbe.drag(from: CGPoint(x: mainSpot.midX, y: mainSpot.maxY - 60), to: CGPoint(x: mainSpot.midX, y: mainSpot.maxY - 84), on: mainPage, in: window, steps: 6)
                XCTAssertTrue(main.tools.activeEditor === main)
                try await BildProbe.drag(from: CGPoint(x: free.midX, y: free.maxY - 60), to: CGPoint(x: free.midX, y: free.maxY - 84), on: sidePage, in: window, steps: 6)
                XCTAssertTrue(main.tools.activeEditor === side)
            }
            XCTAssertEqual([mainProbe?.calls, sideProbe?.calls], [3, 3], "ein Aufruf je Beruehrung")
            XCTAssertEqual(published, 0, "Wechsel des Editors meldet nichts an SwiftUI")
            XCTAssertEqual(selections, 0, "ohne Auswahl keine Meldung an die Objektleiste")
            watch.cancel()
            main.tools.onActiveSelection = forward

            // 7. wieder im Hauptdokument gearbeitet: das naechste Bild liegt dort
            let mainFree = try XCTUnwrap(mainPage.viewportInPage()).intersection(CGRect(origin: .zero, size: mainPage.geometry.pageSize))
            try await BildProbe.tap(CGPoint(x: mainFree.midX, y: mainFree.maxY - 30), on: mainPage, in: window)
            XCTAssertNil(side.objects.selection, "Auswahl in der Notiz ist aufgehoben, sobald im Hauptdokument gearbeitet wird")
            ok = await main.insertPickedImage(BildProbe.foto())
            inMain = await self.images(main); inSide = await self.images(side)
            XCTAssertEqual([inMain.count, inSide.count], [2, 2], "nach Arbeit im Hauptdokument landet das Bild wieder dort")
        }

        // 8. Notiz daneben schliessen: immer das Hauptdokument, auch wenn zuletzt in der Notiz gearbeitet wurde
        try run {
            let free = try XCTUnwrap(sidePage.viewportInPage()).intersection(CGRect(origin: .zero, size: sidePage.geometry.pageSize))
            try await BildProbe.tap(CGPoint(x: free.midX, y: free.maxY - 40), on: sidePage, in: window)
        }
        XCTAssertTrue(tapIdentified("companion.close", in: env.window) || tapButton("Schließen", in: env.window), "Notiz schliessen")
        XCTAssertTrue(env.wait(timeout: 10) { self.editors(in: env.window).count == 1 }, "Notiz ist zu")
        try run {
            let ok = await main.insertPickedImage(BildProbe.foto())
            XCTAssertTrue(ok)
            let inMain = await self.images(main)
            XCTAssertEqual(inMain.count, 3, "Notiz zu: Hauptdokument")
        }
    }
}
