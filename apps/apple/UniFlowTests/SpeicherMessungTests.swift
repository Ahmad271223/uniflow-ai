import IOSurface
import PDFKit
import PencilKit
import UniFlowCore
import XCTest
@testable import UniFlow

// Messung des Arbeitsspeichers fuer kleine iPads (Auftrag des Inhabers 20.11.2026: "iPads duerfen nie wegen
// Arbeitsspeicher abstuerzen"; Werte und Folgerungen in docs/SPEICHER-STAND.md). Nur auf Anforderung:
//
//   TEST_RUNNER_UNIFLOW_EDITOR_MESSUNG=speicher xcodebuild test ... -only-testing:UniFlowTests/EditorScaleTests/<Test>
//
// Gemessen wird `phys_footprint` des Testprozesses (Simulator = Mac-Prozess: Groessenordnung, keine Jetsam-Grenze) und,
// unabhaengig davon, die Flaeche der Zeichenflaechen und ihrer Kacheln in Bildpunkten (x 4 Byte = Speicher der Tinte
// auf dem Geraet). Hilfen (`makeFixture`, `show`, `scrollThrough`, `Speicher`, `Spitze`) aus EditorScaleTests.swift.

extension EditorScaleTests {

    static var speicherMessung: Bool { ProcessInfo.processInfo.environment["UNIFLOW_EDITOR_MESSUNG"] == "speicher" }

    private func nurSpeicherMessung() throws {
        try XCTSkipUnless(Self.speicherMessung, "nur auf Anforderung (UNIFLOW_EDITOR_MESSUNG=speicher), siehe docs/SPEICHER-STAND.md")
    }

    // MARK: Hilfen

    /// Bildpunkte aller Ebenen mit Inhalt unter `view` (Kacheln von PencilKit, Bilder): Flaeche x contentsScale^2
    static func layerPixels(_ view: UIView) -> (layers: Int, pixels: Double) {
        var n = 0, px = 0.0
        func walk(_ l: CALayer) {
            if let c = l.contents {
                n += 1
                px += Double(l.bounds.width * l.bounds.height * l.contentsScale * l.contentsScale)
                // Art des Inhalts (IOSurface = Bildspeicher, der auf dem Geraet zum Speicher der App zaehlt) und seine Groesse
                let cf = c as CFTypeRef
                if CFGetTypeID(cf) == IOSurfaceGetTypeID() {
                    let surface = unsafeBitCast(cf, to: IOSurfaceRef.self)
                    surfaceBytes += Double(IOSurfaceGetAllocSize(surface))
                    surfaces += 1
                } else {
                    otherContents.insert(String(describing: CFCopyTypeIDDescription(CFGetTypeID(cf))))
                }
            }
            l.sublayers?.forEach(walk)
        }
        walk(view.layer)
        return (n, px)
    }

    /// Bildspeicher (IOSurface) aller Ebenen unter `views` in MB: Kacheln der Tinte UND der PDF-Seiten, Deckbilder.
    /// Im Simulator zaehlt er nicht zum `phys_footprint` (von aussen gemessen: `footprint <pid>` zeigt 0 B bei 2,1 GB
    /// belegtem IOSurface), auf dem Geraet schon.
    static func surfaceMB(_ views: [UIView]) -> Double {
        var seen = Set<UInt32>()
        var bytes = 0.0
        func walk(_ l: CALayer) {
            if let c = l.contents {
                let cf = c as CFTypeRef
                if CFGetTypeID(cf) == IOSurfaceGetTypeID() {
                    let surface = unsafeBitCast(cf, to: IOSurfaceRef.self)
                    if seen.insert(IOSurfaceGetID(surface)).inserted { bytes += Double(IOSurfaceGetAllocSize(surface)) }
                }
            }
            l.sublayers?.forEach(walk)
        }
        views.forEach { walk($0.layer) }
        return bytes / 1_048_576
    }

    /// Seit dem letzten Zuruecksetzen in `layerPixels` gesehen: IOSurface-Inhalte (Anzahl, belegte Bytes) und andere Arten
    static var surfaces = 0
    static var surfaceBytes = 0.0
    static var otherContents = Set<String>()

    /// Zeichenflaechen einer Seite: eigene, fremde Striche, Korrektur
    private func canvases(of o: PageInkView) -> [PKCanvasView] {
        [o.canvas.superview != nil ? o.canvas : nil, o.foreignInk, o.correctionView?.ink].compactMap { $0 }
    }

    struct SpeicherStand {
        var footprint: Double
        var peak: Double
        var canvasMio: Double
        var tileMio: Double
        var tiles: Int
        var text: String
        /// IOSurface der Zeichenflaechen bzw. aller Ebenen der Fenster (MB)
        var inkSurfaceMB = 0.0
        var windowSurfaceMB = 0.0
    }

    /// Stand jetzt: Speicher, Flaeche der Zeichenflaechen (Rahmen x Bildschirm^2) und ihrer Kacheln
    private func stand(_ overlays: [PageInkView], screen: CGFloat, peak: Spitze, windows: [UIWindow] = []) -> SpeicherStand {
        var canvasPx = 0.0, tilePx = 0.0, tiles = 0
        var parts: [String] = []
        Self.surfaces = 0
        Self.surfaceBytes = 0
        Self.otherContents = []
        for o in overlays.sorted(by: { $0.pageIndex < $1.pageIndex }) {
            for c in canvases(of: o) {
                canvasPx += Double(c.bounds.width * c.bounds.height * screen * screen)
                let t = Self.layerPixels(c)
                tilePx += t.pixels
                tiles += t.layers
            }
            let w = o.inkWindow
            parts.append("S\(o.pageIndex + 1) z\(o.canvas.zoomScale) \(Int(w.width))x\(Int(w.height))" + (o.foreignInk != nil ? "+fremd" : ""))
        }
        var out = SpeicherStand(footprint: Double(Speicher.footprintBytes()) / 1_048_576, peak: Double(peak.current().footprint) / 1_048_576,
                                canvasMio: canvasPx / 1e6, tileMio: tilePx / 1e6, tiles: tiles, text: parts.joined(separator: " | "))
        out.inkSurfaceMB = Self.surfaceBytes / 1_048_576
        out.windowSurfaceMB = Self.surfaceMB(windows)
        return out
    }

    private func report(_ m: Messwerte, _ name: String, _ s: SpeicherStand, base: Double) {
        m.add("\(name): phys_footprint", s.footprint, "MB")
        m.add("\(name): Zuwachs seit Bezug", s.footprint - base, "MB")
        m.add("\(name): Spitze phys_footprint", s.peak, "MB")
        m.add("\(name): Zeichenflaechen", s.canvasMio, "Mio. Bildpunkte")
        m.add("\(name): Zeichenflaechen x 4 Byte", s.canvasMio * 4e6 / 1_048_576, "MB")
        m.add("\(name): Kacheln mit Inhalt", Double(s.tiles), "")
        m.add("\(name): Kacheln x 4 Byte", s.tileMio * 4e6 / 1_048_576, "MB")
        m.add("\(name): Tinte IOSurface (IOSurfaceGetAllocSize)", s.inkSurfaceMB, "MB")
        if s.windowSurfaceMB > 0 {
            m.add("\(name): alle Ebenen der Fenster IOSurface (Tinte + PDF-Kacheln)", s.windowSurfaceMB, "MB")
            m.add("\(name): SUMME phys_footprint + IOSurface (Schaetzung Geraet)", s.footprint + s.windowSurfaceMB, "MB")
        }
        m.text("\(name): Seiten", s.text)
    }

    /// Striche ueber die ganze Seite verteilt (Raster), fuer grosse Formate
    static func spread(size: CGSize, columns: Int, rows: Int) -> PKDrawing {
        var strokes: [PKStroke] = []
        for r in 0..<rows {
            for c in 0..<columns {
                let x = size.width * (CGFloat(c) + 0.2) / CGFloat(columns), y = size.height * (CGFloat(r) + 0.5) / CGFloat(rows)
                strokes.append(Handschrift.line(from: CGPoint(x: x, y: y), to: CGPoint(x: x + size.width * 0.5 / CGFloat(columns), y: y + 6),
                                                created: Date(timeIntervalSinceReferenceDate: 797_000_000 + Double(r * columns + c))))
            }
        }
        return PKDrawing(strokes: strokes)
    }

    /// Scroll-Ansicht so stellen, dass der Punkt `p` (Seitenpunkte von `overlay`) in der Fenstermitte liegt
    private func center(_ shown: Shown, on overlay: PageInkView, at p: CGPoint) throws {
        let scroll = try XCTUnwrap(scrollView(shown.editor))
        let q = overlay.content.convert(p, to: scroll)
        let maxX = max(0, scroll.contentSize.width - scroll.bounds.width), maxY = max(0, scroll.contentSize.height - scroll.bounds.height)
        scroll.setContentOffset(CGPoint(x: min(max(0, q.x - scroll.bounds.width / 2), maxX),
                                        y: min(max(0, q.y - scroll.bounds.height / 2), maxY)), animated: false)
    }

    private func settle(_ seconds: Double) async throws { try await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }

    // MARK: (a) 300 volle Seiten

    /// 300 Seiten mit je 300 Strichen (90 000 Striche): Umrechnen, eine Speicherrunde, durchblaettern, erneut oeffnen.
    /// Dieselbe Messung wie `testScrollThroughFullPagesAndReopen50PagesWith300Strokes`, sechsfach groesser.
    func testSpeicher300VolleSeitenOnRequest() async throws {
        try nurSpeicherMessung()
        try await denseScript(pages: 300, perPage: 300, checkpoints: [300], breakdownAt: nil, scroll: true, reopen: true,
                              limits: DenseLimits(convert: 900, round: 900, reopen: 900))
    }

    /// 300 Seiten Vorlesungsskript (Text, Diagramm, jede dritte Seite ein Foto) mit wenig Handschrift (30 Striche je
    /// Seite): der uebliche Fall. Blaettern bis zum Ende, Speicherwarnung, zurueck an den Anfang.
    func testSpeicher300SeitenSkriptOnRequest() async throws {
        try nurSpeicherMessung()
        let m = Messwerte("Speicher 300 Seiten Skript")
        let pages = 300
        let fx = try await makeFixture(pdf: Skript.pdf(pages: pages), pageCount: pages)
        let store = try await openStore(fx)
        for i in 0..<pages { store.canvasChanged(pageKey: "p\(i + 1)", drawing: Handschrift.page(i, strokes: 30)) }
        _ = await store.pageStructureDocument()
        let peak = Spitze()
        peak.start()
        await store.pause()
        m.add("Speicherrunde 9000 Striche: Spitze phys_footprint", Double(peak.current().footprint) / 1_048_576, "MB")
        let base = Double(Speicher.footprintBytes()) / 1_048_576
        m.add("Bezug vor dem Anzeigen: phys_footprint", base, "MB")
        let shown = show(store)
        defer { hide(shown) }
        _ = try await waitForOverlay(shown.editor, page: 0, timeout: 30)
        try await settle(1)
        peak.reset()
        // Bildspeicher (IOSurface: Kacheln der Tinte und der PDF) waehrend des Blaetterns, sichtbare und geparkte Seiten
        var surfacePeak = 0.0
        let sampler = Task { @MainActor in
            while !Task.isCancelled {
                surfacePeak = max(surfacePeak, Self.surfaceMB([shown.window] + shown.editor.parkedOverlaysForTesting))
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        let r = try await scrollThrough(shown, timeLimit: 200, drain: 30)
        sampler.cancel()
        m.scroll(r)
        m.add("nach dem Blaettern: phys_footprint", Double(Speicher.footprintBytes()) / 1_048_576, "MB")
        m.add("Blaettern: Spitze (alle 5 ms)", Double(peak.current().footprint) / 1_048_576, "MB")
        m.add("Blaettern: Spitze IOSurface (sichtbar + geparkt, alle 100 ms)", surfacePeak, "MB")
        m.add("nach dem Blaettern: IOSurface sichtbar", Self.surfaceMB([shown.window]), "MB")
        m.add("nach dem Blaettern: IOSurface geparkt", Self.surfaceMB(shown.editor.parkedOverlaysForTesting), "MB")
        m.add("nach dem Blaettern: geparkte Overlays", Double(shown.editor.parkedCountForTesting), "")
        // Speicherwarnung wie vom System
        let before = Double(Speicher.footprintBytes()) / 1_048_576
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: UIApplication.shared)
        shown.editor.didReceiveMemoryWarning()
        try await settle(1.5)
        m.add("Speicherwarnung: freigegeben", before - Double(Speicher.footprintBytes()) / 1_048_576, "MB")
        m.add("Speicherwarnung: geparkt danach", Double(shown.editor.parkedCountForTesting), "")
        m.add("Speicherwarnung: IOSurface danach (sichtbar + geparkt)", Self.surfaceMB([shown.window] + shown.editor.parkedOverlaysForTesting), "MB")
        peak.reset()
        shown.editor.goToPage(0)
        _ = try await waitForOverlay(shown.editor, page: 0, timeout: 30)
        try await settle(1)
        m.add("zurueck am Anfang: phys_footprint", Double(Speicher.footprintBytes()) / 1_048_576, "MB")
        _ = peak.stop()
        XCTAssertTrue(r.reachedEnd)
        XCTAssertLessThanOrEqual(r.aliveAfterDrain, Self.aliveLimit)
        await store.close()
        m.finish()
    }

    /// Wo der Speicher einer Speicherrunde hingeht (100 volle Seiten, 30 000 Striche, 43,5 MB JSON): dieselben Schritte wie
    /// Geraet und lokales Backend (`Messwerte.roundParts`), je Schritt die Spitze. Dazu das erneute Oeffnen.
    func testSpeicherRundeAufteilungOnRequest() async throws {
        try nurSpeicherMessung()
        let m = Messwerte("Speicher einer Runde")
        let pages = 100
        let fx = try await makeFixture(pdf: Skript.pdf(pages: pages, .schlicht), pageCount: pages)
        var store: DocumentStore? = try await openStore(fx)
        let empty = Double(Speicher.footprintBytes()) / 1_048_576
        m.add("Dokument offen, leer: phys_footprint", empty, "MB")
        for i in 0..<pages { store?.canvasChanged(pageKey: "p\(i + 1)", drawing: Handschrift.page(i, strokes: 300)) }
        var doc: AnnotationDocument? = await store?.pageStructureDocument()
        let peak = Spitze()
        peak.start()
        func mb() -> Double { Double(Speicher.footprintBytes()) / 1_048_576 }
        func step(_ name: String, _ before: Double) {
            m.add("\(name): bleibt", mb() - before, "MB")
            m.add("\(name): Spitze", Double(peak.current().footprint) / 1_048_576 - before, "MB")
            peak.reset()
        }
        m.add("30 000 Striche im Speicher (Zuwachs)", mb() - empty, "MB")
        peak.reset()
        var t = mb()
        var data: Data? = doc?.root.serialized()
        doc = nil
        m.add("JSON einer Runde", Double(data?.count ?? 0) / 1_048_576, "MB")
        step("1 serialisieren (Geraet)", t)
        t = mb()
        var py: PyJSON? = try data.map { try PyJSON.parse($0) }
        step("2 PyJSON.parse (lokales Backend)", t)
        t = mb()
        var text: String? = py?.dumps(ensureASCII: false)
        step("3 dumps (lokales Backend)", t)
        m.add("alle drei zusammen im Speicher", mb() - empty, "MB")
        text = nil; py = nil; data = nil
        _ = (text, py, data)
        t = mb()
        await store?.pause()
        step("ganze Runde (DocumentStore.pause)", t)
        await store?.close()
        store = nil
        try await settle(1)
        t = mb()
        peak.reset()
        let again = try await openStore(fx)
        step("erneut oeffnen (DocumentStore.load)", t)
        _ = peak.stop()
        await again.close()
        m.finish()
    }

    // MARK: (c) Zoomstufen, Ausschnitt auf einer Seitengrenze

    /// Vier volle A4-Seiten (je 300 Striche ueber die ganze Seite). Je Zoom (100 bis 600 % der Einpassung): mitten auf
    /// der Seite und auf der Grenze zwischen Seite 1 und 2 (zwei Zeichenflaechen im Bild). Gemessen: Speicher, Flaeche
    /// der Zeichenflaechen, Kacheln mit Inhalt.
    func testSpeicherZoomStufenOnRequest() async throws {
        try nurSpeicherMessung()
        let m = Messwerte("Speicher Zoomstufen")
        let fx = try await makeFixture(pdf: Skript.pdf(pages: 4, .schlicht), pageCount: 4)
        let store = try await openStore(fx)
        for i in 0..<4 { store.canvasChanged(pageKey: "p\(i + 1)", drawing: Handschrift.page(i, strokes: 300)) }
        _ = await store.pageStructureDocument()
        await store.flush()
        let before = Double(Speicher.footprintBytes()) / 1_048_576
        m.add("Bezug vor dem Anzeigen: phys_footprint", before, "MB")
        let shown = show(store)
        defer { hide(shown) }
        let editor = shown.editor, screen = shown.window.screen.scale
        _ = try await waitForCanvas(editor, page: 0, strokes: 300, timeout: 30)
        try await settle(1.5)
        let fit = editor.pdfView.scaleFactor
        m.add("Einpassung (scaleFactor)", Double(fit), "")
        m.add("Bildschirmfaktor", Double(screen), "")
        let peak = Spitze()
        peak.start()
        for percent in [100, 200, 285, 300, 400, 600] {
            peak.reset()
            editor.pdfView.scaleFactor = fit * CGFloat(percent) / 100
            try await settle(1.0)
            var o = try await waitForOverlay(editor, page: 0, timeout: 20)
            try center(shown, on: o, at: CGPoint(x: 297, y: 421))
            try await settle(2.0)
            report(m, "\(percent) % Seitenmitte", stand(installedOverlays(editor), screen: screen, peak: peak, windows: [shown.window]), base: before)
            peak.reset()
            o = try await waitForOverlay(editor, page: 0, timeout: 20)
            try center(shown, on: o, at: CGPoint(x: 297, y: 842 + 4))
            try await settle(2.5)
            let s = stand(installedOverlays(editor), screen: screen, peak: peak, windows: [shown.window])
            report(m, "\(percent) % Seitengrenze", s, base: before)
            m.add("\(percent) % Seitengrenze: Overlays im Bild / geparkt", Double(installedOverlays(editor).count), "/ \(editor.parkedCountForTesting)")
            if percent > 300 {
                XCTAssertLessThanOrEqual(s.canvasMio * 1e6, Double(PageInkView.inkPixelBudget) * Double(installedOverlays(editor).count) + 1,
                                         "\(percent) %: je Zeichenflaeche hoechstens das Budget")
            }
        }
        _ = peak.stop()
        await store.close()
        m.finish()
    }

    // MARK: (b) A0

    /// A0 quer (Whiteboard) zwischen zwei A4-Seiten, Striche ueber die ganze A0-Seite. Die Einpassung gilt der
    /// mittleren Seitenbreite (A4), der Zoom reicht darum auf der A0-Seite bis zum Maximum der Zeichenflaeche.
    func testSpeicherA0OnRequest() async throws {
        try nurSpeicherMessung()
        try await grossesFormat(name: "A0 quer", width: 3370, height: 2384, mitA4: true)
    }

    /// Dokument nur aus einer A0-Seite (reines Whiteboard): Einpassung 0,25, Zoom bis 1,5
    func testSpeicherNurA0OnRequest() async throws {
        try nurSpeicherMessung()
        try await grossesFormat(name: "nur A0 quer", width: 3370, height: 2384, mitA4: false)
    }

    private func grossesFormat(name: String, width: Double, height: Double, mitA4: Bool) async throws {
        let m = Messwerte("Speicher \(name)")
        let size = CGSize(width: width, height: height)
        let fx: Fixture
        let key: String
        if mitA4 {
            fx = try await makeFixture(pdf: Skript.pdf(pages: 2), pageCount: 2)
            key = "bgross"
        } else {
            let pdf = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData { $0.beginPage() }
            fx = try await makeFixture(pdf: pdf, pageCount: 1)
            key = "p1"
        }
        let store = try await openStore(fx)
        if mitA4 {
            let change = await store.applyPageStructure { doc in
                PageOrder.insertBlank(&doc, after: "p1", template: "grid", width: width, height: height, key: key)
            }
            XCTAssertNotNil(change)
        }
        store.canvasChanged(pageKey: key, drawing: Self.spread(size: size, columns: 24, rows: 30))
        _ = await store.pageStructureDocument()
        await store.flush()
        let before = Double(Speicher.footprintBytes()) / 1_048_576
        m.add("Bezug vor dem Anzeigen: phys_footprint", before, "MB")
        let shown = show(store)
        defer { hide(shown) }
        let editor = shown.editor, screen = shown.window.screen.scale
        _ = try await waitForOverlay(editor, page: 0, timeout: 30)
        let index = mitA4 ? 1 : 0
        editor.goToPage(index)
        _ = try await waitForCanvas(editor, page: index, strokes: 24 * 30, timeout: 30)
        try await settle(1.5)
        let fit = editor.pdfView.scaleFactor
        m.add("Einpassung (scaleFactor)", Double(fit), "")
        m.add("Zoom erlaubt bis (maxScaleFactor)", Double(editor.pdfView.maxScaleFactor), "")
        let peak = Spitze()
        peak.start()
        // Zoom der PDFView (Bildschirmpunkte je Seitenpunkt), nicht relativ: die Stufen der Zeichenflaeche haengen daran
        let scales: [CGFloat] = [fit, 1, 1.5, 2, 3, 4, 6, editor.pdfView.maxScaleFactor]
        var done = Set<Int>()
        for wanted in scales {
            let s = min(max(wanted, editor.pdfView.minScaleFactor), editor.pdfView.maxScaleFactor)
            guard done.insert(Int((s * 1000).rounded())).inserted else { continue }
            peak.reset()
            editor.pdfView.scaleFactor = s
            try await settle(1.0)
            let o = try await waitForOverlay(editor, page: index, timeout: 30)
            try center(shown, on: o, at: CGPoint(x: width / 2, y: height / 2))
            try await settle(3.0)
            let only = installedOverlays(editor).filter { $0.pageIndex == index }
            report(m, "Zoom \(String(format: "%.2f", Double(s)))", stand(only, screen: screen, peak: peak, windows: [shown.window]), base: before)
            // Messung von aussen (`footprint <pid>` am Mac): bei dieser Stufe so viele Sekunden stehen bleiben
            if let hold = ProcessInfo.processInfo.environment["UNIFLOW_SPEICHER_HALT"].flatMap(Double.init), abs(s - 4) < 0.01 || abs(s - 1) < 0.01 {
                m.text("HALT", "pid \(ProcessInfo.processInfo.processIdentifier) Zoom \(s) fuer \(hold) s")
                try await settle(hold)
            }
        }
        _ = peak.stop()
        await store.close()
        m.finish()
    }

    // MARK: (d) Loesung daneben, Einblendung, zwei Dokumente nebeneinander

    private func loesung(pages: Int, strokes: Int) -> ForeignSolutionLayer {
        let list = (0..<pages).map { i -> SolutionPage in
            let objects = Handschrift.page(100 + i, strokes: strokes).strokes.enumerated().flatMap { n, s in
                StrokeConverter.objects(for: s, ids: ["l\(i)-\(n)"])
            }
            return SolutionPage(key: "p\(i + 1)", kind: .pdf, pdfIndex: i + 1, width: 595, height: 842, rotation: 0, objects: objects)
        }
        return ForeignSolutionLayer(id: "mess-loesung", displayName: "", createdAt: "2026-11-20T10:00:00Z", visible: true, pages: list,
                                    images: [:], missingImages: 0)
    }

    /// Sechs volle Seiten, dazu eine fremde Loesung mit ebenso vollen Seiten: (1) eingeblendet ueber den eigenen Notizen,
    /// (2) in der Spalte daneben (`SolutionSideController`), (3) zweites Dokument daneben (zweiter Editor). Jeweils
    /// eingepasst und bei 285 % (ganze Seite 4-fach: der groesste Fall je Zeichenflaeche).
    func testSpeicherLoesungDanebenOnRequest() async throws {
        try nurSpeicherMessung()
        let m = Messwerte("Speicher Loesung daneben")
        let fx = try await makeFixture(pdf: Skript.pdf(pages: 6, .schlicht), pageCount: 6)
        let store = try await openStore(fx)
        for i in 0..<6 { store.canvasChanged(pageKey: "p\(i + 1)", drawing: Handschrift.page(i, strokes: 300)) }
        _ = await store.pageStructureDocument()
        await store.flush()
        let before = Double(Speicher.footprintBytes()) / 1_048_576
        m.add("Bezug vor dem Anzeigen: phys_footprint", before, "MB")
        let shown = show(store)
        defer { hide(shown) }
        let editor = shown.editor, screen = shown.window.screen.scale
        _ = try await waitForCanvas(editor, page: 0, strokes: 300, timeout: 30)
        try await settle(1.5)
        let fit = editor.pdfView.scaleFactor
        let peak = Spitze()
        peak.start()

        func boundary(_ name: String, _ percent: Int) async throws {
            peak.reset()
            editor.pdfView.scaleFactor = fit * CGFloat(percent) / 100
            try await settle(1.0)
            let o = try await waitForOverlay(editor, page: 0, timeout: 20)
            try center(shown, on: o, at: CGPoint(x: 297, y: 842 + 4))
            try await settle(2.5)
            report(m, "\(name) \(percent) % Seitengrenze", stand(installedOverlays(editor), screen: screen, peak: peak, windows: [shown.window]), base: before)
        }
        try await boundary("nur eigene Notizen", 100)
        try await boundary("nur eigene Notizen", 285)

        // (1) Einblendung
        editor.pdfView.scaleFactor = fit
        try await settle(1.0)
        let layer = loesung(pages: 6, strokes: 300)
        editor.foreignLayers = [layer]
        try await settle(1.5)
        try await boundary("Loesung eingeblendet", 100)
        try await boundary("Loesung eingeblendet", 285)
        try await boundary("Loesung eingeblendet", 600)
        editor.foreignLayers = []
        editor.pdfView.scaleFactor = fit
        try await settle(2.0)
        m.add("Einblendung wieder aus: phys_footprint", Double(Speicher.footprintBytes()) / 1_048_576, "MB")

        // (2) Spalte daneben
        let pdfURL = AppPaths.pdf(fx.file.id, namespace: fx.api.namespace, root: fx.root)
        var side: SolutionSideController? = SolutionSideController(layer: layer, pdfURL: pdfURL)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var sideWindow: UIWindow? = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        sideWindow?.frame = CGRect(x: 0, y: 0, width: 420, height: 1100)
        sideWindow?.rootViewController = side
        sideWindow?.makeKeyAndVisible()
        for _ in 0..<60 where side?.overlays[0] == nil || side?.fitScale == 0 { try await settle(0.05) }
        try await settle(2.0)
        peak.reset()
        func sideStand(_ name: String) {
            guard let side else { return }
            let all = Array(side.overlays.values)
            report(m, name, stand(all, screen: screen, peak: peak, windows: [shown.window] + (sideWindow.map { [$0] } ?? [])), base: before)
            m.add("\(name): Overlays der Spalte", Double(all.count), "")
        }
        sideStand("Spalte daneben eingepasst")
        if let side {
            for percent in [285, 571, 600] {
                peak.reset()
                side.pdfView.scaleFactor = min(side.pdfView.maxScaleFactor, side.fitScale * CGFloat(percent) / 100)
                try await settle(3.0)
                sideStand("Spalte daneben \(percent) %")
            }
            // durch die Spalte blaettern: weggescrollte Overlays werden freigegeben
            side.pdfView.scaleFactor = side.fitScale
            try await settle(1.0)
            if let scroll = SolutionSideController.firstScrollView(in: side.pdfView) {
                let maxY = max(0, scroll.contentSize.height - scroll.bounds.height)
                var y: CGFloat = 0
                while y < maxY { y = min(maxY, y + 300); scroll.setContentOffset(CGPoint(x: 0, y: y), animated: false); try await settle(0.05) }
            }
            try await settle(1.5)
            sideStand("Spalte daneben nach dem Blaettern")
        }
        weak var weakSide = side
        sideWindow?.isHidden = true
        sideWindow?.rootViewController = nil
        sideWindow = nil
        side = nil
        try await settle(1.5)
        m.add("Spalte geschlossen: phys_footprint", Double(Speicher.footprintBytes()) / 1_048_576, "MB")
        m.text("Spalte geschlossen: Controller freigegeben", weakSide == nil ? "ja" : "NEIN")

        // (3) zweites Dokument daneben
        let fx2 = try await makeFixture(pdf: Skript.pdf(pages: 6, .schlicht), pageCount: 6)
        let store2 = try await openStore(fx2)
        for i in 0..<6 { store2.canvasChanged(pageKey: "p\(i + 1)", drawing: Handschrift.page(50 + i, strokes: 300)) }
        _ = await store2.pageStructureDocument()
        await store2.flush()
        let shown2 = show(store2)
        defer { hide(shown2) }
        _ = try await waitForCanvas(shown2.editor, page: 0, strokes: 300, timeout: 30)
        try await settle(1.5)
        func both(_ percent: Int) async throws {
            peak.reset()
            for s in [shown, shown2] {
                let f = s.editor === editor ? fit : s.editor.pdfView.scaleFactorForSizeToFit
                s.editor.pdfView.scaleFactor = f * CGFloat(percent) / 100
            }
            try await settle(1.0)
            for s in [shown, shown2] {
                let o = try await waitForOverlay(s.editor, page: 0, timeout: 20)
                try center(s, on: o, at: CGPoint(x: 297, y: 842 + 4))
            }
            try await settle(3.0)
            let all = installedOverlays(editor) + installedOverlays(shown2.editor)
            report(m, "zwei Dokumente \(percent) % Seitengrenze", stand(all, screen: screen, peak: peak, windows: [shown.window, shown2.window]), base: before)
        }
        try await both(100)
        try await both(285)
        try await both(600)
        _ = peak.stop()
        hide(shown2)
        await store2.close()
        await store.close()
        m.finish()
    }

    // MARK: (g) Bilder in den Notizen

    /// Foto wie aus der Kamera (4032 x 3024), ungleichmaessiger Inhalt (JPEG wird nicht winzig)
    static func foto(_ n: Int, size: CGSize = CGSize(width: 4032, height: 3024)) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            var rng = SplitMix64(seed: 0xF070 &+ UInt64(n))
            UIColor(hue: CGFloat(n % 10) / 10, saturation: 0.3, brightness: 0.9, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            for _ in 0..<400 {
                UIColor(hue: CGFloat(rng.next() % 100) / 100, saturation: 0.7, brightness: 0.7, alpha: 1).setFill()
                ctx.fill(CGRect(x: CGFloat(rng.next() % UInt64(size.width)), y: CGFloat(rng.next() % UInt64(size.height)),
                                width: CGFloat(20 + rng.next() % 300), height: CGFloat(20 + rng.next() % 300)))
            }
        }
    }

    /// Wie `makeFixture`, aber mit Ablage fuer Dateien (Bilder der Notizen), wie in der App
    func makeFixtureMitAblage(pages: Int) async throws -> Fixture {
        let root = try tempDir()
        let clock: UniFlowClock = .fixed(berlin: "2026-11-21T10:00:00")!
        let layout = DataContainerLayout(base: root.appendingPathComponent("c", isDirectory: true),
                                         key: DataContainerKey(userID: "001234.erfunden.speicher", university: .luh))
        try layout.prepare(clock: clock)
        let host = LocalBackendHost(directory: layout.databaseDirectory, clock: clock, files: .container(layout), university: .luh)
        let backend = try await host.backend()
        let fileID = "speicher-" + UUID().uuidString.prefix(8).lowercased()
        try await backend.context.database.transaction { c in
            try c.execute("INSERT OR IGNORE INTO courses(id, title, semester, subject, kind, created_at) VALUES (?,?,?,?,?,?)",
                          [.text("k-mess"), .text("Messkurs"), .text("WiSe 2026/27"), .text("Messkurs"), .text("vorlesung"),
                           .text("2026-10-01T08:00:00")])
            try c.execute("INSERT INTO files(id, course_id, name, chdate, status, kind, downloaded_at) VALUES (?,?,?,?, 'neu', 'pdf', ?)",
                          [.text(fileID), .text("k-mess"), .text("Messskript.pdf"), .integer(1_792_000_000), .text("2026-11-21T09:00:00")])
        }
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
        let pdfURL = AppPaths.pdf(fileID, namespace: api.namespace, root: root)
        try FileManager.default.createDirectory(at: pdfURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Skript.pdf(pages: pages, .schlicht).write(to: pdfURL)
        let meta = try await api.value("/api/files/\(fileID)")
        try DocumentStore.stamp(meta).write(to: pdfURL.appendingPathExtension("stand"), atomically: true, encoding: .utf8)
        let file = LibFile(id: fileID, name: "Messskript.pdf", title: "Messskript", kind: "pdf", module_id: nil, subject: "Messkurs",
                           doc_type: nil, ai_title: nil, sub_label: nil, downloaded_at: "2026-11-21T09:00:00", has_notes: nil,
                           page_count: pages, studip_folder: nil)
        return Fixture(root: root, host: host, api: api, file: file)
    }

    /// 30 Seiten, auf jeder ein Foto aus der Kamera (eingefuegt wie in der App, `ObjectClipboard.insertImage`). Gemessen:
    /// Speicher je eingefuegtem Foto in derselben Sitzung, nach dem erneuten Oeffnen beim Blaettern (Bilder laden bei
    /// Bedarf) und was danach liegen bleibt (`DocumentStore.images`).
    func testSpeicherBilderDerNotizenOnRequest() async throws {
        try nurSpeicherMessung()
        let m = Messwerte("Speicher Bilder der Notizen")
        let pages = 30
        let fx = try await makeFixtureMitAblage(pages: pages)
        var store = try await openStore(fx)
        var shown = show(store)
        _ = try await waitForOverlay(shown.editor, page: 0, timeout: 30)
        try await settle(1.0)
        let base = Double(Speicher.footprintBytes()) / 1_048_576
        m.add("Bezug (Editor offen, keine Bilder): phys_footprint", base, "MB")
        let peak = Spitze()
        peak.start()
        for i in 0..<pages {
            let ok = await shown.editor.objects.insertImage(Self.foto(i), on: "p\(i + 1)", at: CGPoint(x: 40, y: 80))
            XCTAssertTrue(ok, "Bild \(i + 1) eingefuegt")
            if [0, 4, 9, 19, 29].contains(i) {
                try await settle(0.5)
                m.add("eingefuegt \(i + 1) Fotos: phys_footprint", Double(Speicher.footprintBytes()) / 1_048_576, "MB")
                m.add("eingefuegt \(i + 1) Fotos: Bilder im Speicher des Dokuments", Double(store.images.count), "")
            }
        }
        m.add("Einfuegen: Spitze phys_footprint", Double(peak.current().footprint) / 1_048_576, "MB")
        let held = store.images.values.reduce(0.0) { $0 + Double(($1.cgImage?.bytesPerRow ?? 0) * ($1.cgImage?.height ?? 0)) }
        m.add("Bilder im Speicher des Dokuments: Bildpunkte x Byte", held / 1_048_576, "MB")
        if let any = store.images.values.first { m.text("Groesse eines Bildes", "\(Int(any.size.width * any.scale)) x \(Int(any.size.height * any.scale))") }
        await store.flush()
        hide(shown)
        await store.close()
        try await settle(1.5)
        m.add("nach dem Schliessen: phys_footprint", Double(Speicher.footprintBytes()) / 1_048_576, "MB")

        // erneut oeffnen und durchblaettern: Bilder laden bei Bedarf
        store = try await openStore(fx)
        shown = show(store)
        defer { hide(shown) }
        _ = try await waitForOverlay(shown.editor, page: 0, timeout: 30)
        try await settle(1.5)
        let reopened = Double(Speicher.footprintBytes()) / 1_048_576
        m.add("erneut geoeffnet: phys_footprint", reopened, "MB")
        peak.reset()
        // langsam genug, dass jede Seite ihr Bild laedt und zeigt
        let r = try await scrollThrough(shown, timeLimit: 120, stepFraction: 0.04, drain: 10)
        try await settle(2.0)
        m.add("Blaettern: Seiten gesehen", Double(r.seen.count), "von \(pages)")
        m.add("Blaettern: Spitze phys_footprint", Double(peak.current().footprint) / 1_048_576, "MB")
        m.add("nach dem Blaettern: phys_footprint", Double(Speicher.footprintBytes()) / 1_048_576, "MB")
        m.add("nach dem Blaettern: Zuwachs", Double(Speicher.footprintBytes()) / 1_048_576 - reopened, "MB")
        m.add("nach dem Blaettern: Bilder im Speicher des Dokuments", Double(store.images.count), "")
        // Speicherwarnung
        let before = Double(Speicher.footprintBytes()) / 1_048_576
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: UIApplication.shared)
        shown.editor.didReceiveMemoryWarning()
        try await settle(2.0)
        m.add("Speicherwarnung: freigegeben", before - Double(Speicher.footprintBytes()) / 1_048_576, "MB")
        m.add("Speicherwarnung: Bilder im Speicher des Dokuments danach", Double(store.images.count), "")
        _ = peak.stop()
        await store.close()
        m.finish()
    }
}

// MARK: - Mensa-Fotos

/// Mensa-Fotos (`MensaMealPhoto`): Die App fragt jedes Foto 480 Pixel breit an (`Mensa.imageWidth`) und zeigt es in einer
/// Liste, die nur baut, was im Bild ist. Gemessen wird, was 40 gleichzeitig gezeigte Fotos dieser Groesse kosten (dekodiert
/// und angezeigt), zum Vergleich mit unverkleinerten Fotos. `AsyncImage` selbst laesst sich im Test nicht mit erfundenen
/// Antworten versorgen (kein Netz); darum hier derselbe Weg von Hand: JPEG-Daten -> `UIImage` -> Anzeige in 76 x 76 Punkten.
/// Nur auf Anforderung (`UNIFLOW_EDITOR_MESSUNG=speicher`).
///
/// Die Reiter der offenen Dokumente misst `UniFlowUITests/SpeicherReiterUITests` in der echten App: In einem im Test
/// gehosteten Fenster haelt SwiftUI abgebaute Ansichten in seinem Zeichen-Zwischenspeicher fest (dort blieben alle 20
/// Editoren nach 20 Wechseln am Leben), in der App nicht (gezaehlt mit `heap`: immer genau ein Editor).
@MainActor
final class SpeicherAnsichtenMessungTests: XCTestCase {

    private func mb() -> Double { Double(Speicher.footprintBytes()) / 1_048_576 }

    func testSpeicherMensaFotosOnRequest() throws {
        try XCTSkipUnless(EditorScaleTests.speicherMessung, "nur auf Anforderung (UNIFLOW_EDITOR_MESSUNG=speicher)")
        let m = Messwerte("Speicher Mensa-Fotos")
        m.add("angefragte Breite (Mensa.imageWidth)", Double(Mensa.imageWidth), "px")
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        for (name, size) in [("480 x 360 (wie angefragt)", CGSize(width: 480, height: 360)), ("2000 x 1500 (unverkleinert)", CGSize(width: 2000, height: 1500))] {
            let files = try (0..<40).map { try XCTUnwrap(EditorScaleTests.foto($0, size: size).jpegData(compressionQuality: 0.7)) }
            let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
            window.frame = CGRect(x: 0, y: 0, width: 900, height: 420)
            let root = UIViewController()
            root.view.backgroundColor = .white
            window.rootViewController = root
            window.makeKeyAndVisible()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            let before = mb()
            let peak = Spitze()
            peak.start()
            for (i, data) in files.enumerated() {
                let view = UIImageView(frame: CGRect(x: 10 + (i % 10) * 86, y: 10 + (i / 10) * 86, width: 76, height: 76))
                view.contentMode = .scaleAspectFill
                view.clipsToBounds = true
                view.image = UIImage(data: data)
                root.view.addSubview(view)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(2.5))
            m.add("\(name): Datei", Double(files[0].count) / 1024, "KB")
            m.add("\(name): Zuwachs mit 40 Fotos im Bild", mb() - before, "MB")
            m.add("\(name): Spitze Zuwachs", Double(peak.stop().footprint) / 1_048_576 - before, "MB")
            m.add("\(name): gerechnet 40 x Breite x Hoehe x 4 Byte", Double(40 * size.width * size.height * 4) / 1_048_576, "MB")
            m.add("\(name): IOSurface im Fenster", EditorScaleTests.surfaceMB([window]), "MB")
            window.isHidden = true
            window.rootViewController = nil
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))
            m.add("\(name): nach dem Schliessen gegenueber vorher", mb() - before, "MB")
        }
        m.finish()
    }
}
