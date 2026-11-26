import PDFKit
import PencilKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// "Lösung daneben ansehen" (Meldung des Inhabers 20.11.2026: "nicht 1 zu 1 wie das Original-Dokument, wie man es
/// beschriftet; man kann nicht reinzoomen, wenn man Lösung daneben importiert").
/// - Die Spalte zeigt Striche, Textmarker und Formen an denselben Stellen und in derselben Breite wie die Canvas des
///   Absenders (gemessen in Pixeln, umgerechnet in Seitenpunkte); ebenso die Einblendung auf der eigenen PDF.
/// - Die alte Spalte (feste Bilder aus `SolutionPreview`) zeichnete einen 8-pt-Strich sichtbar anders.
/// - Die Spalte laesst sich zoomen (Grenzen, Pinch der PDFView, Doppeltippen, Tinte in der Aufloesung des Zooms).
/// - Seiten stehen in der Drehung des Absenders; leere Blaetter auf ihrem Papier.
@MainActor
final class SolutionSideViewerAppTests: XCTestCase {
    private static let pageSize = CGSize(width: 595, height: 842)
    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        windows.forEach { $0.isHidden = true }
        windows = []
    }

    // MARK: Testdaten

    /// Eine weisse Seite (A4 hoch), optional ganz blau gefuellt
    private func pdfURL(pages: Int = 1, fill: UIColor? = nil, rotate: Int = 0) throws -> URL {
        let raw = NSMutableData()
        let rect = CGRect(origin: .zero, size: Self.pageSize)
        UIGraphicsBeginPDFContextToData(raw, rect, nil)
        for _ in 0..<pages {
            UIGraphicsBeginPDFPageWithInfo(rect, nil)
            if let fill { fill.setFill(); UIRectFill(rect) }
        }
        UIGraphicsEndPDFContext()
        let doc = try XCTUnwrap(PDFDocument(data: raw as Data))
        for i in 0..<doc.pageCount { doc.page(at: i)?.rotation = rotate }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("loesung-daneben-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("blatt.pdf")
        try XCTUnwrap(doc.dataRepresentation()).write(to: url)
        return url
    }

    /// Strich wie vom Apple Pencil auf der Canvas des Absenders: waagerecht bei y von x 80 bis 500
    private func native(_ ink: PKInk.InkType, size: CGFloat, y: CGFloat, color: UIColor = .black, azimuth: CGFloat = 0) -> PKStroke {
        let pts = stride(from: 80.0, through: 500.0, by: 1.5).enumerated().map { i, x in
            PKStrokePoint(location: CGPoint(x: x, y: y), timeOffset: TimeInterval(i) * 0.01, size: CGSize(width: size, height: size),
                          opacity: 1, force: 0.7, azimuth: azimuth, altitude: .pi / 3)
        }
        return PKStroke(ink: PKInk(ink, color: color), path: PKStrokePath(controlPoints: pts, creationDate: Date()))
    }

    /// Baender (Mitte y, Seitenpunkte), in denen je ein Objekt liegt
    private static let bands: [CGFloat] = [150, 270, 390, 510, 640]

    private struct Sample {
        let strokes: [PKStroke]
        let shape: JSONValue
        let objects: [JSONValue]
    }

    /// Stift 3 pt, Stift 8 pt, Fueller 6 pt, Textmarker 15 pt (gelb), rotes Rechteck (Form) – wie geteilt: als Objekte.
    /// Der Textmarker ist in PencilKit eine schraege Keilspitze, seine Dicke haengt an der Neigungsrichtung des Stifts
    /// (Azimut). Die steht nicht im gemeinsamen Strichformat (und damit nicht im Loesungspaket); beim Empfaenger gilt
    /// `StrokeConverter.markerAzimuth` (pi/4). Mit einem anderen Azimut beim Absender ist die Markierung beim Empfaenger
    /// in Spalte UND Einblendung gleich, aber anders dick als beim Absender (`markerAzimuth`).
    private func sample(markerAzimuth: CGFloat = StrokeConverter.markerAzimuth) throws -> Sample {
        let strokes = [native(.pen, size: 3, y: Self.bands[0]), native(.pen, size: 8, y: Self.bands[1]),
                       native(.fountainPen, size: 6, y: Self.bands[2]),
                       native(.marker, size: 15, y: Self.bands[3], color: UIColor(red: 1, green: 0.83, blue: 0, alpha: 1),
                              azimuth: markerAzimuth)]
        let shape = try JSONValue.parse(##"{"id":"r1","type":"shape","shape":"rect","x":120,"y":610,"width":300,"height":60,"stroke":"#e5322d","strokeWidth":4}"##)
        let objects = strokes.enumerated().flatMap { i, s in StrokeConverter.objects(for: s, ids: ["s\(i)"]) } + [shape]
        return Sample(strokes: strokes, shape: shape, objects: objects)
    }

    private func layer(_ pages: [SolutionPage]) -> ForeignSolutionLayer {
        ForeignSolutionLayer(id: "l1", displayName: "", createdAt: "2026-11-20T10:00:00Z", visible: true, pages: pages,
                             images: [:], missingImages: 0)
    }

    // MARK: Fenster und Messung

    private func window(size: CGSize, root: UIViewController) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let w = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(origin: .zero, size: size))
        w.frame = CGRect(origin: .zero, size: size)
        w.overrideUserInterfaceStyle = .light
        w.rootViewController = root
        w.makeKeyAndVisible()
        windows.append(w)
        return w
    }

    private func window(page view: UIView) -> UIWindow {
        let root = UIViewController()
        root.view.backgroundColor = .white
        view.frame = CGRect(origin: .zero, size: Self.pageSize)
        root.view.addSubview(view)
        return window(size: Self.pageSize, root: root)
    }

    private func snapshot(_ window: UIWindow) async throws -> UIImage {
        try await Task.sleep(nanoseconds: 900_000_000)                 // PencilKit zeichnet seine Kacheln nach
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    private struct Pixels {
        let data: [UInt8]
        let width: Int
        let height: Int
        let scale: CGFloat

        init(_ image: UIImage) {
            let cg = image.cgImage!
            width = cg.width
            height = cg.height
            scale = image.scale
            var d = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            let ctx = CGContext(data: &d, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            data = d
        }

        func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * width + x) * 4
            return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
        }

        /// Tinte: deutlich nicht weiss (schwarz, rot oder gelb)
        func isInk(_ x: Int, _ y: Int) -> Bool {
            let (r, g, b) = rgb(x, y)
            return min(r, g, b) < 170
        }

        /// Umriss der Tinte in einem Bereich (Punkte des Bildes), nil wenn keine
        func inkBox(in rect: CGRect) -> CGRect? {
            let x0 = max(0, Int(rect.minX * scale)), x1 = min(width, Int(rect.maxX * scale))
            let y0 = max(0, Int(rect.minY * scale)), y1 = min(height, Int(rect.maxY * scale))
            var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
            for y in y0..<y1 {
                for x in x0..<x1 where isInk(x, y) {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            guard maxX >= 0 else { return nil }
            return CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                          width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
        }
    }

    /// Umrisse je Band in Seitenpunkten; `pageRect` = Lage der Seite im Bild, `s` = Bildpunkte je Seitenpunkt
    private func boxes(_ image: UIImage, pageRect: CGRect) -> [CGRect?] {
        let px = Pixels(image)
        let s = pageRect.width / Self.pageSize.width
        return Self.bands.map { y in
            let band = CGRect(x: pageRect.minX + 2 * s, y: pageRect.minY + (y - 45) * s,
                              width: pageRect.width - 4 * s, height: 90 * s)
            return px.inkBox(in: band).map {
                CGRect(x: ($0.minX - pageRect.minX) / s, y: ($0.minY - pageRect.minY) / s, width: $0.width / s, height: $0.height / s)
            }
        }
    }

    private func assertSame(_ got: [CGRect?], _ want: [CGRect?], tolerance: CGFloat, _ what: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        let names = ["Stift 3 pt", "Stift 8 pt", "Füller 6 pt", "Textmarker 15 pt", "Rechteck"]
        for (i, (g, w)) in zip(got, want).enumerated() {
            guard let g, let w else {
                XCTFail("\(what) \(names[i]): sichtbar? \(String(describing: g)) / Original \(String(describing: w))", file: file, line: line)
                continue
            }
            for (a, b, edge) in [(g.minX, w.minX, "links"), (g.maxX, w.maxX, "rechts"), (g.minY, w.minY, "oben"), (g.maxY, w.maxY, "unten")] {
                XCTAssertEqual(a, b, accuracy: tolerance, "\(what) \(names[i]) \(edge): \(a) statt \(b)", file: file, line: line)
            }
        }
    }

    /// Seite des Absenders, wie er sie sah: eigene Canvas mit den nativen Strichen, Form im Objekt-Overlay
    private func authorBoxes(_ sample: Sample) async throws -> [CGRect?] {
        let a = PageInkView(pageIndex: 0, pageKey: "p1", geometry: PageGeometry(pageSize: Self.pageSize))
        a.canvas.drawing = PKDrawing(strokes: sample.strokes)
        a.objectsView.show(template: nil, placeholder: nil, objects: [sample.shape], images: [:])
        let shot = try await snapshot(window(page: a))
        return boxes(shot, pageRect: CGRect(origin: .zero, size: Self.pageSize))
    }

    private func sideController(_ layer: ForeignSolutionLayer, url: URL?, size: CGSize = CGSize(width: 420, height: 720))
        async throws -> (SolutionSideController, UIWindow) {
        let c = SolutionSideController(layer: layer, pdfURL: url)
        let w = window(size: size, root: c)
        for _ in 0..<40 where c.overlays[0] == nil || c.fitScale == 0 { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertNotNil(c.overlays[0], "Overlay der ersten Seite")
        return (c, w)
    }

    /// Bild zum Ansehen (Simulator: tmp-Ordner der App)
    private static func keep(_ image: UIImage, _ name: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("loesung-daneben-\(name).png")
        try? image.pngData()?.write(to: url)
        print("Bild: \(url.path)")
    }

    // MARK: 1:1

    func testSidePaneMatchesTheAuthorsCanvas() async throws {
        let sample = try sample()
        let want = try await authorBoxes(sample)
        XCTAssertTrue(want.allSatisfy { $0 != nil }, "Original zeigt alle Objekte")

        let page = SolutionPage(key: "p1", kind: .pdf, pdfIndex: 1, width: 595, height: 842, rotation: 0, objects: sample.objects)
        let (c, w) = try await sideController(layer([page]), url: try pdfURL())
        let overlay = try XCTUnwrap(c.overlays[0])
        XCTAssertFalse(overlay.isUserInteractionEnabled, "nur ansehen")
        XCTAssertNil(overlay.canvas.superview, "keine eigene Zeichenflaeche")
        XCTAssertEqual(overlay.foreignLayerViews.count, 1)
        XCTAssertEqual(overlay.foreignInk?.drawing.strokes.count, sample.strokes.count, "Striche in PencilKit wie im Editor")
        let shot = try await snapshot(w)
        let pageRect = overlay.content.convert(overlay.content.bounds, to: w)
        XCTAssertLessThan(pageRect.width, Self.pageSize.width, "Seite in die schmale Spalte eingepasst")
        let got = boxes(shot, pageRect: pageRect)
        Self.keep(shot, "spalte-neu")
        // Massstab ~0,65: ein Bildpixel sind ~0,8 Seitenpunkte
        assertSame(got, want, tolerance: 2.0, "Spalte daneben")

        // Einblendung auf der eigenen PDF (dieselbe Ebene, Overlay des Editors in Seitengroesse)
        let projected = PageInkView(pageIndex: 0, pageKey: "p1", geometry: PageGeometry(pageSize: Self.pageSize))
        projected.setForeign([ForeignLayerView(solutionID: "l1", page: page, images: [:], targetRotation: 0, label: "Lösung")])
        let projShot = try await snapshot(window(page: projected))
        let proj = boxes(projShot, pageRect: CGRect(origin: .zero, size: Self.pageSize))
        assertSame(proj, want, tolerance: 1.0, "Einblendung")
        assertSame(got, proj, tolerance: 2.0, "Spalte gegen Einblendung")
    }

    /// Textmarker mit anderer Neigung beim Absender (Azimut 0): Spalte und Einblendung zeigen ihn gleich (dieselbe
    /// Ebene); die Dicke beim Absender kann davon abweichen, weil die Neigung nicht mitgeteilt wird
    func testMarkerTiltIsNotSharedButSideEqualsProjection() async throws {
        let sample = try sample(markerAzimuth: 0)
        let want = try await authorBoxes(sample)
        let page = SolutionPage(key: "p1", kind: .pdf, pdfIndex: 1, width: 595, height: 842, rotation: 0, objects: sample.objects)
        let (c, w) = try await sideController(layer([page]), url: try pdfURL())
        let overlay = try XCTUnwrap(c.overlays[0])
        let shot = try await snapshot(w)
        let got = boxes(shot, pageRect: overlay.content.convert(overlay.content.bounds, to: w))
        let projected = PageInkView(pageIndex: 0, pageKey: "p1", geometry: PageGeometry(pageSize: Self.pageSize))
        projected.setForeign([ForeignLayerView(solutionID: "l1", page: page, images: [:], targetRotation: 0, label: "Lösung")])
        let proj = boxes(try await snapshot(window(page: projected)), pageRect: CGRect(origin: .zero, size: Self.pageSize))
        assertSame(got, proj, tolerance: 2.0, "Spalte gegen Einblendung")
        // alles ausser dem Textmarker wie beim Absender
        assertSame(Array(got.prefix(3)) + [got[4]], Array(want.prefix(3)) + [want[4]], tolerance: 2.0, "Spalte ohne Textmarker")
        let markerSide = try XCTUnwrap(got[3]).height, markerAuthor = try XCTUnwrap(want[3]).height
        print("Textmarker 15 pt, Azimut 0: Absender \(markerAuthor) pt, Empfaenger \(markerSide) pt")
    }

    /// Vorschau-Bild (`SolutionPreview`: Leser und Kommentare der Community, Kacheln): bis 22.11.2026 zeichnete die
    /// Vektor-Routine des PDF-Exports die Handschrift in der gespeicherten Breite, der 3-pt-Stift war darum fetter als
    /// bei PencilKit (Meldung des Inhabers: "Schrift sieht fett aus, in echt ist die nicht so"). Jetzt zeichnet
    /// PencilKit sie wie auf der Canvas des Absenders.
    func testPreviewImageDrawsInkLikeTheAuthorsCanvas() async throws {
        let sample = try sample()
        let want = try await authorBoxes(sample)
        let page = SolutionPage(key: "p1", kind: .pdf, pdfIndex: 1, width: 595, height: 842, rotation: 0, objects: sample.objects)
        let image = SolutionPreview.image(page, images: [:], width: 595, scale: 2)
        let got = boxes(image, pageRect: CGRect(origin: .zero, size: Self.pageSize))
        Self.keep(image, "vorschau-neu")
        for (i, name) in ["Stift 3 pt", "Stift 8 pt", "Füller 6 pt"].enumerated() {
            let w = try XCTUnwrap(want[i]).height, g = try XCTUnwrap(got[i]).height
            print("\(name): Absender \(w) pt, Vorschau \(g) pt")
        }
        assertSame(got, want, tolerance: 1.5, "Vorschau")
        // dieselbe Seite im Dunkelmodus: Tinte bleibt wie sie ist (nicht umgekehrt), Bild gleich
        var dark: UIImage?
        UITraitCollection(userInterfaceStyle: .dark).performAsCurrent { dark = SolutionPreview.image(page, images: [:], width: 595, scale: 2) }
        assertSame(boxes(try XCTUnwrap(dark), pageRect: CGRect(origin: .zero, size: Self.pageSize)), got, tolerance: 0.5, "Vorschau dunkel")
    }

    // MARK: Nur noch daneben (22.11.2026)

    /// Inhaber 22.11.2026: "nur noch daneben anzeigen ... ohne Ebene mehr erstmal jetzt", der Satz "Lösung neben deinem
    /// Dokument öffnen" soll zu lesen sein, und schon vor dem Laden steht da, was passiert
    func testSolutionsOpenOnlyBesideTheDocument() throws {
        XCTAssertFalse(SolutionOverlay.enabled, "keine Einblendung ueber der eigenen Seite")
        XCTAssertEqual(SolutionOverlay.openBeside, "Lösung neben deinem Dokument öffnen")
        let text = CommunitySolutionsSheet.explain(overlay: false, beside: true)
        XCTAssertTrue(text.contains("neben deinem Dokument"), text)
        XCTAssertTrue(text.contains("nur ansehen"), text)
        XCTAssertTrue(text.contains("in deinem eigenen Dokument"), text)
        XCTAssertFalse(text.contains("Ebene"), text)
        XCTAssertEqual(DocumentView.besideChip(1), "Lösung neben deinem Dokument öffnen")
        XCTAssertEqual(DocumentView.besideChip(3), "3 Lösungen · neben deinem Dokument öffnen")

        // Haken im Menue "Ebenen": die Loesung, die gerade daneben offen ist
        let one = layer([SolutionPage(key: "p1", kind: .pdf, pdfIndex: 1, width: 595, height: 842, rotation: 0, objects: [])])
        XCTAssertEqual(DocumentView.layerSymbol(one, beside: one.id), "checkmark.circle.fill")
        XCTAssertEqual(DocumentView.layerSymbol(one, beside: nil), "circle")

        // Inhaber 23.11.2026: "nie einfach nur Striche, immer ganze Lösung mit Dokument" - eine PDF-Seite ohne eigene
        // PDF erscheint nicht (Platzhalter), eigene Blaetter stehen auf ihrem Papier
        let onPDF = SolutionPage(key: "p1", kind: .pdf, pdfIndex: 1, width: 595, height: 842, rotation: 0, objects: [])
        let blank = SolutionPage(key: "b1", kind: .blank, pdfIndex: nil, width: 595, height: 842, rotation: 0, objects: [])
        XCTAssertTrue(CommunityReaderPage.needsPDF(onPDF, source: nil))
        XCTAssertFalse(CommunityReaderPage.needsPDF(onPDF, source: OffscreenPDF(url: try pdfURL())))
        XCTAssertFalse(CommunityReaderPage.needsPDF(blank, source: nil))
        XCTAssertFalse(CommunityTexts.noPDFNotice.contains("weißen Seiten"), CommunityTexts.noPDFNotice)

        // Bitte aus dem Leser der Community: wartet je Datei, wird genau einmal abgeholt
        let launch = SolutionBesideLaunch.shared
        launch.request(solutionID: "abc", fileID: "datei-1")
        XCTAssertEqual(launch.pending["datei-1"], "abc")
        XCTAssertNil(launch.take(fileID: "andere"))
        XCTAssertEqual(launch.take(fileID: "datei-1"), "abc")
        XCTAssertNil(launch.take(fileID: "datei-1"))
    }

    // MARK: Zoom

    func testSidePaneZooms() async throws {
        let sample = try sample()
        let page = SolutionPage(key: "p1", kind: .pdf, pdfIndex: 1, width: 595, height: 842, rotation: 0, objects: sample.objects)
        let (c, _) = try await sideController(layer([page]), url: try pdfURL())
        let pdf = c.pdfView
        let fit = c.fitScale
        XCTAssertGreaterThan(fit, 0)
        XCTAssertFalse(pdf.autoScales)
        XCTAssertEqual(pdf.scaleFactor, fit, accuracy: 0.001, "startet in der Breite der Spalte")
        XCTAssertEqual(pdf.minScaleFactor, fit, accuracy: 0.001)
        XCTAssertEqual(pdf.maxScaleFactor, fit * ZoomPolicy.maxFactor, accuracy: 0.001, "bis 6-fach wie im Editor")
        let scroll = try XCTUnwrap(SolutionSideController.firstScrollView(in: pdf))
        XCTAssertTrue(scroll.pinchGestureRecognizer?.isEnabled == true, "zwei Finger zoomen")
        XCTAssertTrue(scroll.isScrollEnabled)
        XCTAssertTrue(c.doubleTap.isEnabled && c.doubleTap.numberOfTapsRequired == 2, "Doppeltippen")

        // Doppeltippen auf den 8-pt-Strich: 2,5-fach, die Stelle bleibt unter dem Finger
        let overlay = try XCTUnwrap(c.overlays[0])
        let spot = overlay.content.convert(CGPoint(x: 300, y: Self.bands[1]), to: pdf)
        let before = try XCTUnwrap(pdf.page(for: spot, nearest: true))
        let pagePoint = pdf.convert(spot, to: before)
        let target = SolutionSideController.doubleTapTarget(current: pdf.scaleFactor, fit: fit, max: pdf.maxScaleFactor)
        XCTAssertEqual(target, fit * 2.5, accuracy: 0.001)
        c.zoom(to: target, keeping: spot)
        XCTAssertEqual(pdf.scaleFactor, fit * 2.5, accuracy: 0.001)
        let after = pdf.convert(pagePoint, from: before)
        XCTAssertEqual(after.x, spot.x, accuracy: 2, "Stelle bleibt (x)")
        XCTAssertEqual(after.y, spot.y, accuracy: 2, "Stelle bleibt (y)")
        XCTAssertTrue(c.userZoomed)

        // nach dem Zoomen zeichnet PencilKit die Tinte in der Aufloesung des Zooms (wie im Editor, sonst grob)
        try await Task.sleep(nanoseconds: 500_000_000)
        let ink = try XCTUnwrap(c.overlays.values.first?.foreignInk)
        XCTAssertGreaterThan(ink.zoomScale, 1.4, "Tinte fein gezeichnet: Zoom der Zeichenflaeche \(ink.zoomScale)")

        // zweites Doppeltippen: zurueck auf die Breite
        XCTAssertEqual(SolutionSideController.doubleTapTarget(current: pdf.scaleFactor, fit: fit, max: pdf.maxScaleFactor), fit, accuracy: 0.001)
        c.zoom(to: fit, keeping: spot)
        XCTAssertEqual(pdf.scaleFactor, fit, accuracy: 0.001)

        // Pinch (wie PDFKit ihn meldet): Grenzen halten
        pdf.scaleFactor = fit * 20
        XCTAssertLessThanOrEqual(pdf.scaleFactor, fit * ZoomPolicy.maxFactor + 0.001)
    }

    // MARK: Drehung und Papier

    func testSidePaneUsesTheSendersRotationAndPaper() async throws {
        // Absender hat die Seite selbst um 90 Grad gedreht (`extraRotation`), die PDF hat kein /Rotate
        let stroke: JSONValue = .object(["id": "s1", "type": "stroke", "tool": "pen", "color": "#000000", "width": 3, "opacity": 1,
                                         "points": .array([100, 100, 700, 100].map { .number($0) })])
        let rotated = SolutionPage(key: "p1", kind: .pdf, pdfIndex: 1, width: 595, height: 842, rotation: 90, extraRotation: 90,
                                   objects: [stroke])
        let lined = SolutionPage(key: "n1", kind: .blank, pdfIndex: nil, width: 595, height: 842, rotation: 0, template: "lined",
                                 objects: [stroke])
        let url = try pdfURL(fill: .blue)
        let l = layer([rotated, lined])
        let doc = SolutionSideController.document(for: l, pdf: PDFDocument(url: url))
        XCTAssertEqual(doc.pageCount, 2)
        let p0 = try XCTUnwrap(doc.page(at: 0)), p1 = try XCTUnwrap(doc.page(at: 1))
        XCTAssertEqual(p0.rotation, 90, "Drehung des Absenders")
        let o0 = SolutionSideController.overlay(for: rotated, page: p0, index: 0, layer: l)
        XCTAssertEqual(o0.geometry.pageSize, CGSize(width: 842, height: 595), "quer wie beim Absender")
        XCTAssertTrue(try XCTUnwrap(o0.foreignLayerViews.first).mapping.isIdentity, "Objekte ohne Umrechnung")
        XCTAssertTrue(o0.objectsView.isHidden)
        let o1 = SolutionSideController.overlay(for: lined, page: p1, index: 1, layer: l)
        XCTAssertFalse(o1.objectsView.isHidden, "Papier des Blatts")
        XCTAssertTrue(o1.content.subviews.first === o1.objectsView, "Papier unter der Lösung")
        XCTAssertGreaterThan(o1.objectsView.layer.sublayers?.count ?? 0, 0, "Linien gezeichnet")

        // Vorschau-Bild (Community) aus der eigenen PDF: die blaue Seite fuellt das quere Bild ganz (vorher lag die
        // ungedrehte Seite hochkant in der Mitte, links und rechts weiss)
        let preview = await OffscreenPDF(url: url).solutionPreview(rotated, images: [:], width: 400, scale: 1)
        let image = try XCTUnwrap(preview, "PDF-Seite vorhanden (seit 26.11.2026 nil, wenn sie sich nicht oeffnen laesst)")
        XCTAssertGreaterThan(image.size.width, image.size.height)
        let px = Pixels(image)
        for (x, y) in [(5, px.height / 2), (px.width - 6, px.height / 2)] {
            let (r, g, b) = px.rgb(x, y)
            XCTAssertTrue(b > 150 && r < 100 && g < 100, "Rand blau (\(r), \(g), \(b)) bei \(x)")
        }
    }
}
