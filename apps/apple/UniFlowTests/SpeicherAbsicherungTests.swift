import PDFKit
import PencilKit
import UniFlowCore
import XCTest
@testable import UniFlow

// Absicherung des Arbeitsspeichers auf kleinen iPads (Auftrag des Inhabers 20.11.2026, docs/SPEICHER-STAND.md):
// Geraeteklasse (`MemoryBudget`), ganze Seite auf der Zeichenflaeche nur bis zu einer Flaechengrenze, Bilder der Notizen
// mit Obergrenze und bei Speicherwarnung. Geprueft wird jeweils auch: Auf grossen Geraeten aendert sich nichts.

final class SpeicherAbsicherungTests: XCTestCase {

    private static let gib: UInt64 = 1024 * 1024 * 1024

    func testGeraeteklasseNachArbeitsspeicher() {
        // gemeldeter Arbeitsspeicher liegt etwas unter der Nenngroesse
        XCTAssertEqual(MemoryBudget.forDevice(physicalMemory: 2 * Self.gib), .small, "2 GB")
        XCTAssertEqual(MemoryBudget.forDevice(physicalMemory: 2_950_000_000), .small, "iPad 9 (3 GB)")
        XCTAssertEqual(MemoryBudget.forDevice(physicalMemory: 3 * Self.gib), .small)
        XCTAssertEqual(MemoryBudget.forDevice(physicalMemory: 3_900_000_000), .small, "iPad 10, iPad Air 4 (4 GB)")
        XCTAssertEqual(MemoryBudget.forDevice(physicalMemory: 4 * Self.gib), .small)
        XCTAssertEqual(MemoryBudget.forDevice(physicalMemory: 5_600_000_000), .standard, "iPad (A16) mit 6 GB: wie bisher")
        XCTAssertEqual(MemoryBudget.forDevice(physicalMemory: 6 * Self.gib), .standard)
        XCTAssertEqual(MemoryBudget.forDevice(physicalMemory: 8 * Self.gib), .standard)
        XCTAssertEqual(MemoryBudget.forDevice(physicalMemory: 16 * Self.gib), .standard)
        // grosse Geraete: keine der Grenzen greift
        XCTAssertEqual(MemoryBudget.standard.wholePageInkArea, .infinity)
        XCTAssertEqual(MemoryBudget.standard.idleNoteImageBytes, .max)
        XCTAssertEqual(MemoryBudget.current, MemoryBudget.forDevice(physicalMemory: ProcessInfo.processInfo.physicalMemory),
                       "ausserhalb eines Tests gilt die Klasse des Geraets")
    }

    // MARK: Zeichenflaeche

    /// Stand bis 21.11.2026 (release/1.0.7 @ 0688baa1), woertlich: Bezug fuer "auf grossen Geraeten unveraendert"
    private static func before(pageSize size: CGSize, viewport: CGRect?, zoom wanted: CGFloat, screen: CGFloat,
                               keeping size0: CGSize? = nil) -> InkLayout? {
        let budget = PageInkView.inkPixelBudget, margin = PageInkView.windowMargin
        let wholePageZoom = PageInkView.wholePageZoom
        let page = CGRect(origin: .zero, size: size)
        func pixels(_ r: CGRect, _ z: CGFloat) -> CGFloat { r.width * r.height * z * z * screen * screen }
        let z0 = min(max(1, wanted.isFinite ? wanted : 1), PageInkView.maxCanvasZoom)
        if z0 <= wholePageZoom + 0.001 || pixels(page, z0) <= budget { return InkLayout(zoom: z0, window: page) }
        guard let v = viewport, !v.isNull, v.width > 0, v.height > 0,
              let near = PageInkView.window(around: v, in: page, margin: margin, keeping: size0) else { return nil }
        var z = z0
        while z > wholePageZoom + 0.001, pixels(near, z) > budget { z = PageInkView.zoomSteps.last { $0 < z - 0.001 } ?? 1 }
        if z <= wholePageZoom + 0.001 || pixels(page, z) <= budget { return InkLayout(zoom: z, window: page) }
        return InkLayout(zoom: z, window: near)
    }

    private static let formats: [(name: String, size: CGSize)] = [
        ("A6", CGSize(width: 298, height: 420)), ("A5", CGSize(width: 420, height: 595)), ("A4", CGSize(width: 595, height: 842)),
        ("A4 quer", CGSize(width: 842, height: 595)), ("Letter", CGSize(width: 612, height: 792)),
        ("Folie 4:3", CGSize(width: 720, height: 540)), ("Folie 16:9", CGSize(width: 960, height: 540)),
        ("A3", CGSize(width: 842, height: 1191)), ("A2", CGSize(width: 1191, height: 1684)),
        ("A1 quer", CGSize(width: 2384, height: 1684)), ("A0 quer", CGSize(width: 3370, height: 2384)),
    ]
    private static let zooms: [CGFloat] = [0.5, 1, 1.2, 1.5, 2, 2.5, 3, 3.9, 4, 4.5, 6, 8, 10, 12, .infinity]

    /// Sichtbarer Teil der Seite bei `zoom`-fachem PDF-Zoom auf einem iPad hoch (834 x 1210 Punkte), an mehreren Stellen
    private static func viewports(_ size: CGSize, zoom: CGFloat) -> [CGRect?] {
        let z = zoom.isFinite ? max(zoom, 0.25) : 10
        let w = min(size.width, 834 / z), h = min(size.height, 1210 / z)
        return [nil, CGRect(x: 0, y: 0, width: w, height: h),
                CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h),
                CGRect(x: size.width - w, y: size.height - h * 0.6, width: w, height: h),
                CGRect(x: size.width * 3, y: size.height * 3, width: w, height: h)]
    }

    /// Geraete ab 6 GB: fuer jedes Format, jeden Zoom, jede Lage und beide Bildschirmfaktoren genau das Ergebnis wie
    /// vor der Absicherung - mit der Klasse des Geraets (Vorgabe) wie mit der ausdruecklich grossen.
    func testGrosseGeraeteZeichenflaecheUnveraendert() throws {
        try XCTSkipUnless(MemoryBudget.current == .standard, "Simulator auf einem Mac mit mehr als 4 GB erwartet")
        var checked = 0
        for f in Self.formats {
            for zoom in Self.zooms {
                for screen: CGFloat in [2, 3] {
                    for v in Self.viewports(f.size, zoom: zoom) {
                        for keep in [nil, CGSize(width: 300, height: 400)] as [CGSize?] {
                            let want = Self.before(pageSize: f.size, viewport: v, zoom: zoom, screen: screen, keeping: keep)
                            let what = "\(f.name) Zoom \(zoom) Bildschirm \(screen) sichtbar \(String(describing: v))"
                            XCTAssertEqual(PageInkView.inkLayout(pageSize: f.size, viewport: v, zoom: zoom, screen: screen, keeping: keep),
                                           want, what)
                            XCTAssertEqual(PageInkView.inkLayout(pageSize: f.size, viewport: v, zoom: zoom, screen: screen, keeping: keep,
                                                                 wholePageArea: MemoryBudget.standard.wholePageInkArea), want, what)
                            checked += 1
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 3000)
    }

    /// Geraete bis 4 GB: A4, Letter und Folien wie bisher (auch auf 3x-Bildschirmen); groessere Seiten zeigen ueber der
    /// Flaechengrenze nur den sichtbaren Teil, und keine Zeichenflaeche ist groesser als A4 beim 4-fachen plus Rand.
    func testKleineGeraeteGanzeSeiteNurBisZurFlaechengrenze() throws {
        let area = MemoryBudget.small.wholePageInkArea
        func small(_ size: CGSize, _ v: CGRect?, _ zoom: CGFloat, _ screen: CGFloat) -> InkLayout? {
            PageInkView.inkLayout(pageSize: size, viewport: v, zoom: zoom, screen: screen, wholePageArea: area)
        }
        // 1. uebliche Formate: nichts aendert sich
        for f in Self.formats.prefix(7) {
            for zoom in Self.zooms {
                for screen: CGFloat in [2, 3] {
                    for v in Self.viewports(f.size, zoom: zoom) {
                        XCTAssertEqual(small(f.size, v, zoom, screen), Self.before(pageSize: f.size, viewport: v, zoom: zoom, screen: screen),
                                       "\(f.name) Zoom \(zoom) Bildschirm \(screen): wie bisher")
                    }
                }
            }
        }
        // 2. grosse Formate auf dem iPad (2x): hoechstens 36 Mio. Bildpunkte je Zeichenflaeche (144 MB), der sichtbare
        //    Teil liegt ganz darauf, die Zoomstufe bleibt (scharf wie bisher)
        let limit = area * 4
        var windows = 0
        for f in Self.formats.suffix(4) {
            let page = CGRect(origin: .zero, size: f.size)
            for zoom in Self.zooms {
                let wanted = min(max(1, zoom.isFinite ? zoom : 1), PageInkView.maxCanvasZoom)
                for v in Self.viewports(f.size, zoom: zoom).dropLast() {
                    guard let l = small(f.size, v, zoom, 2) else {
                        XCTAssertNil(v, "\(f.name) Zoom \(zoom): ohne Ergebnis nur, solange der sichtbare Teil unbekannt ist")
                        XCTAssertGreaterThan(f.size.width * f.size.height * wanted * wanted, area)
                        continue
                    }
                    let pixels = l.window.width * l.window.height * l.zoom * l.zoom * 4
                    XCTAssertLessThanOrEqual(pixels, max(limit, PageInkView.inkPixelBudget), "\(f.name) Zoom \(zoom): \(l)")
                    if let v {
                        XCTAssertTrue(l.window.insetBy(dx: -1, dy: -1).contains(v.intersection(page)), "\(f.name) Zoom \(zoom): sichtbarer Teil auf der Zeichenflaeche")
                    }
                    XCTAssertEqual(l.zoom, wanted, accuracy: 0.001, "\(f.name) Zoom \(zoom): Zoomstufe bleibt")
                    if l.window != page { windows += 1 }
                    // was vorher schon ein Ausschnitt war, bleibt derselbe
                    if let old = Self.before(pageSize: f.size, viewport: v, zoom: zoom, screen: 2), old.window != page { XCTAssertEqual(l, old) }
                }
            }
        }
        XCTAssertGreaterThan(windows, 40, "grosse Seiten zeigen den Ausschnitt")
        // 3. feste Beispiele
        let a0 = CGSize(width: 3370, height: 2384), a3 = CGSize(width: 842, height: 1191)
        let view = CGRect(x: 1000, y: 800, width: 278, height: 403)                 // iPad hoch bei PDF-Zoom 3
        XCTAssertEqual(small(a0, view, 1, 2), InkLayout(zoom: 1, window: CGRect(origin: .zero, size: a0)), "A0 ohne Zoom: ganze Seite (128 MB)")
        let l3 = try XCTUnwrap(small(a0, view, 3, 2))
        XCTAssertEqual(l3.zoom, 3)
        XCTAssertEqual(l3.window.size, CGSize(width: 417, height: 605), "sichtbarer Teil mit einem Viertel Rand je Seite")
        XCTAssertNil(small(a0, nil, 3, 2), "sichtbarer Teil noch unbekannt: spaeter (wie ueber dem 4-fachen)")
        XCTAssertEqual(Self.before(pageSize: a0, viewport: view, zoom: 3, screen: 2)?.window.size, a0, "bisher: ganze A0-Seite, 289 Mio. Bildpunkte")
        XCTAssertEqual(small(a3, view, 2, 2)?.window.size, a3, "A3 beim 2-fachen: ganze Seite")
        XCTAssertNotEqual(small(a3, CGRect(x: 100, y: 100, width: 209, height: 303), 4, 2)?.window.size, a3, "A3 beim 4-fachen: Ausschnitt")
    }

    // MARK: Bilder der Notizen

    func testDekodierteGroesseEinesBildes() {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        // farbiger Inhalt wie ein Foto (ein leeres Bild legt UIKit sparsamer ab)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2400, height: 1800), format: format).image { ctx in
            UIColor.systemRed.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1200, height: 900))
            UIColor.systemGreen.setFill()
            ctx.fill(CGRect(x: 1200, y: 900, width: 1200, height: 900))
        }
        XCTAssertEqual(Double(DocumentStore.decodedBytes(image)) / 1_048_576, 16.5, accuracy: 0.5, "2400 x 1800 x 4 Byte")
    }
}

// MARK: - Im Editor (Hilfen aus EditorScaleTests.swift)

extension EditorScaleTests {

    /// Geraet bis 4 GB (Klasse im Test gesetzt): eine voll beschriebene A0-Seite zeigt beim Hineinzoomen nur den
    /// sichtbaren Teil - scharf wie bisher, der Stift schreibt ueberall, wo die Seite zu sehen ist, und die Kacheln der
    /// Tinte bleiben unter 200 MB (vorher 1154 MB bei Stufe 3, 2052 MB bei Stufe 4). Gegenprobe im selben Test: mit der
    /// Klasse der grossen Geraete liegt wie bisher die ganze Seite auf der Zeichenflaeche (auf der noch leeren Seite
    /// geprueft, damit der Testlauf nicht selbst 2 GB Kacheln anlegt).
    func testKleinesGeraetGrosseSeiteNurAusschnitt() async throws {
        let m = Messwerte("Kleines Geraet, A0")
        let size = CGSize(width: 3370, height: 2384)
        let fx = try await makeFixture(pdf: Skript.pdf(pages: 2), pageCount: 2)
        let store = try await openStore(fx)
        let change = await store.applyPageStructure { doc in
            PageOrder.insertBlank(&doc, after: "p1", template: "grid", width: size.width, height: size.height, key: "bgross")
        }
        XCTAssertNotNil(change)
        let device = MemoryBudget.current
        defer { MemoryBudget.current = device }

        // Gegenprobe "gross" zuerst und auf der noch leeren Seite: ohne Striche legt PencilKit keine Kacheln an
        for (name, budget) in [("gross", MemoryBudget.standard), ("klein", MemoryBudget.small)] {
            MemoryBudget.current = budget
            if budget == .small {
                store.canvasChanged(pageKey: "bgross", drawing: Self.spread(size: size, columns: 24, rows: 30))
                _ = await store.pageStructureDocument()
                await store.flush()
            }
            let shown = show(store)
            defer { hide(shown) }
            let editor = shown.editor, window = shown.window, screen = window.screen.scale
            _ = try await waitForOverlay(editor, page: 0, timeout: 30)
            editor.goToPage(1)
            _ = try await waitForCanvas(editor, page: 1, strokes: budget == .small ? 24 * 30 : 0, timeout: 30)
            for scale: CGFloat in [3, 4] {
                editor.pdfView.scaleFactor = scale
                try await Task.sleep(nanoseconds: 1_000_000_000)
                var o = try await waitForOverlay(editor, page: 1, timeout: 30)
                let scroll = try XCTUnwrap(scrollView(editor))
                let q = o.content.convert(CGPoint(x: size.width / 2, y: size.height / 2), to: scroll)
                scroll.setContentOffset(CGPoint(x: q.x - scroll.bounds.width / 2, y: q.y - scroll.bounds.height / 2), animated: false)
                try await Task.sleep(nanoseconds: 2_500_000_000)
                o = try await waitForOverlay(editor, page: 1, timeout: 30)
                let canvas = o.canvas
                let pixels = canvas.bounds.width * canvas.bounds.height * screen * screen
                let tiles = Self.surfaceMB([canvas])
                m.add("\(name), Zoom \(Int(scale)): Zeichenflaeche", Double(pixels) / 1e6, "Mio. Bildpunkte")
                m.add("\(name), Zoom \(Int(scale)): Kacheln der Tinte (IOSurface)", tiles, "MB")
                m.text("\(name), Zoom \(Int(scale)): Ausschnitt", "\(o.inkWindow) Stufe \(canvas.zoomScale)")
                XCTAssertEqual(canvas.zoomScale, scale, accuracy: 0.01, "\(name): Zeichenflaeche so fein wie bisher")
                if budget == .small {
                    XCTAssertLessThan(o.inkWindow.width, size.width / 2, "klein: nur der sichtbare Teil")
                    XCTAssertLessThanOrEqual(pixels, MemoryBudget.small.wholePageInkArea * screen * screen)
                    XCTAssertLessThan(tiles, 200, "klein: Kacheln der Tinte")
                    // der sichtbare Teil der Seite liegt ganz auf der Zeichenflaeche
                    let pageInWindow = o.content.convert(CGRect(origin: .zero, size: size), to: window)
                    let visible = pageInWindow.intersection(editor.pdfView.convert(editor.pdfView.bounds, to: window))
                    let onCanvas = canvas.convert(canvas.bounds, to: window).insetBy(dx: -1, dy: -1)
                    XCTAssertTrue(onCanvas.contains(visible), "klein: Stift schreibt ueberall auf der sichtbaren Seite: \(visible) in \(onCanvas)")
                    // ein Strich in der Bildmitte landet an seiner Stelle im Dokument
                    let before = canvas.drawing.strokes.count
                    let c = CGPoint(x: size.width / 2, y: size.height / 2 + scale)
                    drawStroke(editor, on: o, Handschrift.line(from: CGPoint(x: c.x - 20, y: c.y), to: CGPoint(x: c.x + 20, y: c.y)))
                    XCTAssertEqual(o.canvas.drawing.strokes.count, before + 1)
                } else {
                    XCTAssertEqual(o.inkWindow.width, size.width, accuracy: 1, "gross: ganze Seite wie bisher")
                    XCTAssertEqual(o.inkWindow.height, size.height, accuracy: 1, "gross: ganze Seite wie bisher")
                }
            }
            hide(shown)
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        await store.flush()
        let strokes = await store.objects(forPageKey: "bgross").filter { $0["type"]?.string == "stroke" }
        XCTAssertEqual(strokes.count, 24 * 30 + 2, "beide Striche des kleinen Geraets gespeichert")
        await store.close()
        m.finish()
    }

    /// Bilder der Notizen: Was keine Seite mehr zeigt, faellt bei einer Speicherwarnung aus dem Speicher (auf kleinen
    /// Geraeten schon ueber der Obergrenze) und laedt beim Zurueckblaettern neu. Die sichtbare Seite behaelt ihr Bild.
    /// Auf grossen Geraeten faellt ohne Speicherwarnung nichts heraus.
    func testBilderDerNotizenFallenHerausUndLadenNeu() async throws {
        let pages = 14
        let fx = try await makeFixtureMitAblage(pages: pages)
        let store = try await openStore(fx)
        let shown = show(store)
        defer { hide(shown) }
        let editor = shown.editor
        _ = try await waitForOverlay(editor, page: 0, timeout: 30)
        let device = MemoryBudget.current
        defer { MemoryBudget.current = device }
        MemoryBudget.current = .standard

        // Bilder auf Seite 1 und auf den Seiten 11 bis 14 (weit weg von Seite 1)
        let withImage = [1, 11, 12, 13, 14]
        for n in withImage {
            let ok = await editor.objects.insertImage(Self.foto(n, size: CGSize(width: 400, height: 300)), on: "p\(n)", at: CGPoint(x: 40, y: 80))
            XCTAssertTrue(ok, "Bild auf Seite \(n)")
        }
        await store.flush()
        XCTAssertEqual(store.images.count, 5)
        let one = DocumentStore.decodedBytes(try XCTUnwrap(store.images.values.first))
        func imageViews(_ page: Int) -> [UIImageView] {
            installedOverlay(editor, page: page)?.objectsView.subviews.compactMap { $0 as? UIImageView } ?? []
        }
        func waitImage(_ page: Int) async throws {
            let end = Uhr.now() + 20
            while Uhr.now() < end {
                if let v = imageViews(page).first, v.image != nil { return }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTFail("Seite \(page + 1) zeigt ihr Bild nicht")
        }
        editor.goToPage(0)
        try await waitImage(0)
        editor.releaseParkedOverlays()
        let source1 = try XCTUnwrap(installedOverlay(editor, page: 0)?.objectsView.shownObjects.first { $0["type"]?.string == "image" }?["src"]?.string)
        XCTAssertTrue(editor.imageSourcesInUse.contains(source1))
        XCTAssertEqual(editor.imageSourcesInUse.count, 1, "nur Seite 1 zeigt ein Bild: \(editor.imageSourcesInUse)")

        // grosses Geraet: ohne Speicherwarnung bleibt alles
        XCTAssertEqual(store.trimImages(), 0, "gross: keine Obergrenze")
        XCTAssertEqual(store.images.count, 5)
        // kleines Geraet: Obergrenze fuer Bilder, die keine Seite zeigt (hier: Platz fuer zwei)
        XCTAssertEqual(store.trimImages(limit: one * 2), 2, "die beiden aeltesten unbenutzten fallen heraus")
        XCTAssertEqual(store.images.count, 3)
        XCTAssertNotNil(store.images[source1], "das Bild der sichtbaren Seite bleibt")
        XCTAssertEqual(store.trimImages(limit: one * 2), 0, "unter der Grenze: nichts")
        MemoryBudget.current = .small
        XCTAssertEqual(store.trimImages(), 0, "klein: 96 MB sind hier nicht erreicht")
        MemoryBudget.current = .standard

        // Speicherwarnung: alles, was keine Seite zeigt
        editor.didReceiveMemoryWarning()
        XCTAssertEqual(store.images.count, 1)
        XCTAssertNotNil(store.images[source1])
        XCTAssertNotNil(imageViews(0).first?.image, "die sichtbare Seite zeigt ihr Bild weiter")
        // die Meldung des Systems erreicht auch den Store selbst (Editor schon weg, z. B. Dokument daneben)
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: UIApplication.shared)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(store.images.count, 1)

        // zurueckblaettern: die Bilder laden neu
        for n in [11, 13] {
            editor.goToPage(n - 1)
            try await waitImage(n - 1)
        }
        XCTAssertGreaterThanOrEqual(store.images.count, 2)
        // ohne Editor, der sagt, was im Bild ist, faellt nichts heraus
        store.imagesInUse = nil
        XCTAssertEqual(store.trimImages(limit: 0), 0)
        await store.close()
    }
}
