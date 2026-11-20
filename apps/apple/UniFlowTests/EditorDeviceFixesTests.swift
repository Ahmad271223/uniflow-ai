import PDFKit
import PencilKit
import XCTest
import UniFlowCore
@testable import UniFlow

/// Fehler aus dem ersten Test auf dem iPad (1.11.2026): unscharfe Tinte, verzerrtes Verschieben
@MainActor
final class EditorDeviceFixesTests: XCTestCase {
    func testRenderScaleFollowsZoomWithinTheLimit() {
        XCTAssertEqual(PDFEditorController.renderScale(screen: 2, zoom: 1), 2)
        XCTAssertEqual(PDFEditorController.renderScale(screen: 2, zoom: 1.4), 3)
        XCTAssertEqual(PDFEditorController.renderScale(screen: 2, zoom: 0.5), 2, "nie unter dem Bildschirm")
        XCTAssertEqual(PDFEditorController.renderScale(screen: 2, zoom: 8), 16, "600 %: so fein wie die Anzeige (bis 1.0.7 hoechstens 8)")
        XCTAssertEqual(PDFEditorController.renderScale(screen: 2, zoom: 8.16), 20, "iPad hoch bei 600 %: naechste Stufe, nie groeber als die Anzeige")
        XCTAssertEqual(PDFEditorController.renderScale(screen: 2, zoom: 12), 20, "hoechstens der 10-fache Zoom von PencilKit")
        XCTAssertEqual(PDFEditorController.renderScale(screen: 2, zoom: .nan), 2)
        XCTAssertEqual(PDFEditorController.renderScale(screen: 2, zoom: 2.1), PDFEditorController.renderScale(screen: 2, zoom: 2.9), "kleiner Pinch: kein Neuzeichnen")
    }

    func testSetRenderScaleZoomsTheCanvasItself() {
        let v = PageInkView(pageIndex: 0, geometry: PageGeometry(pageSize: CGSize(width: 600, height: 800)))
        v.canvas.addSubview(UIView())
        v.objectsView.show(template: nil, placeholder: nil, objects: [["id": "t", "type": "text", "text": "Hallo", "x": 1, "y": 2]], images: [:])
        v.setRenderScale(8, screen: 2)
        XCTAssertEqual(v.canvas.zoomScale, 4, "PencilKit rendert fertige Striche nur nach seinem eigenen Zoom")
        XCTAssertEqual(v.canvas.bounds.size, CGSize(width: 2400, height: 3200))
        XCTAssertEqual(v.canvas.frame, CGRect(x: 0, y: 0, width: 600, height: 800), "bis zum 4-fachen bleibt die Canvas so gross wie die Seite")
        XCTAssertEqual(v.canvas.contentOffset, .zero)
        XCTAssertEqual(v.objectsView.subviews.first?.contentScaleFactor, 8)
        v.isDrawing = true
        v.setRenderScale(2, screen: 2)
        XCTAssertEqual(v.canvas.zoomScale, 4, "ein laufender Strich bleibt unberuehrt")
        v.isDrawing = false
        v.setRenderScale(6, screen: 2)
        XCTAssertEqual(v.canvas.zoomScale, 4, "leicht herausgezoomt bleiben die feineren Kacheln")
        v.setRenderScale(10, screen: 2)
        XCTAssertEqual(v.canvas.zoomScale, 4, "ganze Seite 5-fach waere zu gross, ohne Fenster ist der sichtbare Teil unbekannt: Zoom bleibt")
        XCTAssertEqual(v.canvas.frame, CGRect(x: 0, y: 0, width: 600, height: 800))
        XCTAssertEqual(v.objectsView.subviews.first?.contentScaleFactor, 8, "Text hoechstens so fein wie bis 1.0.7 (Speicher)")
        v.setRenderScale(2)
        XCTAssertEqual(v.canvas.zoomScale, 1)
        XCTAssertGreaterThanOrEqual(v.objectsView.subviews.first?.contentScaleFactor ?? 0, UIScreen.main.scale * 2, "Text nie groeber als vorher")
    }

    func testCanvasPointsStayPagePointsWhenZoomed() {
        let v = PageInkView(pageIndex: 0, geometry: PageGeometry(pageSize: CGSize(width: 600, height: 800)))
        v.setRenderScale(8, screen: 2)
        // Inhaltspunkt der Canvas (Seitenpunkte) -> Ansicht der Canvas -> Seite
        let onCanvas = CGPoint(x: 150 * v.canvas.zoomScale, y: 200 * v.canvas.zoomScale)
        let onPage = v.canvas.convert(onCanvas, to: v.content)
        XCTAssertEqual(onPage.x, 150, accuracy: 0.01)
        XCTAssertEqual(onPage.y, 200, accuracy: 0.01)
    }

    /// Objekte stehen in Seitenpunkten: Bei skalierter Seite ergibt derselbe Finger-Weg den halben Weg auf der Seite
    func testGestureCoordinatesAreInPagePointsOnAScaledPage() {
        let v = PageInkView(pageIndex: 0, geometry: PageGeometry(pageSize: CGSize(width: 600, height: 800)))
        v.frame = CGRect(x: 0, y: 0, width: 1200, height: 1600)
        v.layoutIfNeeded()
        let p = v.convert(CGPoint(x: 400, y: 200), to: v.content)
        XCTAssertEqual(p.x, 200, accuracy: 0.001)
        XCTAssertEqual(p.y, 100, accuracy: 0.001)
    }

    /// Importierte Loesungen: ihre Canvas zoomt wie die eigene, sonst wirkt die fremde Tinte beim Hineinzoomen grob
    func testForeignLayerZoomsLikeTheOwnCanvas() throws {
        let page = SolutionPage(key: "p1", kind: .pdf, pdfIndex: 1, width: 600, height: 800, rotation: 0, extraRotation: 0,
                                objects: [["type": "stroke", "points": [10, 10, 50, 50, 90, 20], "color": "#000000", "width": 2]])
        let layer = ForeignLayerView(solutionID: "s", page: page, images: [:], targetRotation: 0, label: "Test")
        let layer2 = ForeignLayerView(solutionID: "t", page: page, images: [:], targetRotation: 0, label: "Test 2")
        let v = PageInkView(pageIndex: 0, geometry: PageGeometry(pageSize: CGSize(width: 600, height: 800)))
        v.setRenderScale(6, screen: 2)
        v.setForeign([layer, layer2])
        let f = try XCTUnwrap(v.foreignInk, "eine gemeinsame Canvas fuer alle Ebenen der Seite")
        XCTAssertNil(layer.ink.superview, "keine eigene Canvas je Ebene (Speicher)")
        XCTAssertEqual(f.drawing.strokes.count, 2, "Striche beider Ebenen")
        XCTAssertEqual(f.zoomScale, 3, "uebernimmt den aktuellen Zoom")
        XCTAssertEqual(f.frame.size.width, 600, accuracy: 0.01, "bleibt so gross wie die Seite")
        v.setRenderScale(2, screen: 2)
        XCTAssertEqual(f.zoomScale, 1)
        v.setForeign([])
        XCTAssertNil(v.foreignInk)
    }

    /// Ganze Seite bis zur bisherigen Grenze, darueber nur der sichtbare Teil mit Rand (Meldung des Inhabers 20.11.2026:
    /// Handschrift bei 600 % verpixelt, weil die Canvas hoechstens 4-fach zoomte)
    func testInkLayoutWholePageUpToTheOldLimitThenOnlyTheVisiblePart() throws {
        let a4 = CGSize(width: 595, height: 842), page = CGRect(origin: .zero, size: a4)
        XCTAssertEqual(PageInkView.inkLayout(pageSize: a4, viewport: nil, zoom: 4, screen: 2), InkLayout(zoom: 4, window: page),
                       "bis zum 4-fachen die ganze Seite wie bisher")
        XCTAssertNil(PageInkView.inkLayout(pageSize: a4, viewport: nil, zoom: 12, screen: 2), "ohne sichtbaren Teil kein Ausschnitt")
        let a0 = CGSize(width: 3370, height: 2384)
        XCTAssertEqual(PageInkView.inkLayout(pageSize: a0, viewport: CGRect(x: 0, y: 0, width: 500, height: 700), zoom: 1.5, screen: 2),
                       InkLayout(zoom: 1.5, window: CGRect(origin: .zero, size: a0)), "A0 bis zum 4-fachen: ganze Seite wie bis 1.0.7")
        let viewport = CGRect(x: 150, y: 600, width: 100, height: 145)          // iPad hoch bei 600 %
        let l = try XCTUnwrap(PageInkView.inkLayout(pageSize: a4, viewport: viewport, zoom: 10, screen: 2))
        XCTAssertEqual(l.zoom, 10, "so fein wie die Anzeige")
        XCTAssertEqual(PageInkView.inkLayout(pageSize: a4, viewport: viewport, zoom: 12, screen: 2)?.zoom, 10, "hoechstens 10-fach (PencilKit)")
        XCTAssertTrue(l.window.contains(viewport.insetBy(dx: -20, dy: -30)), "sichtbarer Teil mit Rand: \(l.window)")
        XCTAssertLessThanOrEqual(l.window.width * l.window.height * 100 * 4, PageInkView.inkPixelBudget)
        // Herauszoomen mit der feinen Stufe: zu grosser Ausschnitt -> eine Stufe tiefer, bis er passt
        let wide = CGRect(x: 0, y: 0, width: 400, height: 600)
        let w = try XCTUnwrap(PageInkView.inkLayout(pageSize: a4, viewport: wide, zoom: 10, screen: 2))
        XCTAssertLessThan(w.zoom, 10)
        XCTAssertLessThanOrEqual(w.window.width * w.window.height * w.zoom * w.zoom * 4, PageInkView.inkPixelBudget)
        XCTAssertNil(PageInkView.inkLayout(pageSize: a4, viewport: CGRect(x: 2000, y: 2000, width: 100, height: 100), zoom: 12, screen: 2),
                     "Seite weit weg: kein Ausschnitt")
    }

    /// Bei starkem Zoom zeigt die Canvas nur den sichtbaren Teil; beim Scrollen wandert der Ausschnitt mit (ohne alle
    /// Striche neu zu zeichnen), die Striche bleiben in Seitenpunkten und der sichtbare Teil liegt immer auf der Canvas
    func testWindowedCanvasFollowsScrollingAndKeepsPagePoints() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 600)
        window.isHidden = false
        defer { window.isHidden = true }
        let scroll = UIScrollView(frame: window.bounds)
        window.addSubview(scroll)
        let v = PageInkView(pageIndex: 0, geometry: PageGeometry(pageSize: CGSize(width: 600, height: 800)))
        v.frame = CGRect(x: 0, y: 0, width: 600 * 8, height: 800 * 8)       // Seite 8-fach wie in der PDFView
        scroll.addSubview(v)
        scroll.contentSize = v.frame.size
        v.layoutIfNeeded()
        var d = PKDrawing()
        d.strokes.append(PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: [
            PKStrokePoint(location: CGPoint(x: 20, y: 30), timeOffset: 0, size: CGSize(width: 2, height: 2), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2),
            PKStrokePoint(location: CGPoint(x: 400, y: 600), timeOffset: 0.1, size: CGSize(width: 2, height: 2), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2),
        ], creationDate: Date())))
        v.canvas.drawing = d
        v.setRenderScale(16, screen: 2)
        XCTAssertEqual(v.canvas.zoomScale, 8, "so fein wie die Anzeige (bis 1.0.7: 4)")
        func check(_ label: String) {
            let visible = try! XCTUnwrap(v.viewportInPage()).intersection(CGRect(x: 0, y: 0, width: 600, height: 800))
            XCTAssertTrue(v.inkWindow.insetBy(dx: -0.5, dy: -0.5).contains(visible), "\(label): sichtbarer Teil \(visible) auf der Canvas \(v.inkWindow)")
            let pixels = v.canvas.bounds.width * v.canvas.bounds.height * 4
            XCTAssertLessThanOrEqual(pixels, PageInkView.inkPixelBudget, "\(label): Flaeche der Canvas begrenzt")
            XCTAssertLessThan(v.inkWindow.width, 600, "\(label): nur ein Ausschnitt")
            // Inhaltspunkt der Canvas (Seitenpunkte x Zoom) -> Seite
            let onPage = v.canvas.convert(CGPoint(x: 300 * v.canvas.zoomScale, y: 400 * v.canvas.zoomScale), to: v.content)
            XCTAssertEqual(onPage.x, 300, accuracy: 0.01, label)
            XCTAssertEqual(onPage.y, 400, accuracy: 0.01, label)
            // der sichtbare Teil der Seite auf dem Bildschirm liegt ganz auf der Canvas (Stift schreibt ueberall)
            let canvasOnScreen = v.canvas.convert(v.canvas.bounds, to: window).insetBy(dx: -1, dy: -1)
            let pageOnScreen = v.content.convert(CGRect(x: 0, y: 0, width: 600, height: 800), to: window).intersection(window.bounds)
            XCTAssertTrue(canvasOnScreen.contains(pageOnScreen), "\(label): \(pageOnScreen) in \(canvasOnScreen)")
        }
        check("oben links")
        let rescales = PageInkView.rescalesMade, moves = PageInkView.windowMoves
        scroll.contentOffset = CGPoint(x: 1600, y: 2400)
        check("nach dem Scrollen")
        XCTAssertGreaterThan(PageInkView.windowMoves, moves, "Ausschnitt wandert mit")
        XCTAssertEqual(PageInkView.rescalesMade, rescales, "dabei kein Neuzeichnen aller Striche")
        scroll.contentOffset = CGPoint(x: 1610, y: 2405)
        XCTAssertEqual(PageInkView.windowMoves, moves + 1, "kleine Bewegung im Rand: nichts zu tun")
        XCTAssertEqual(v.canvas.drawing.strokes.count, 1, "Zeichnung unveraendert")
        // Grenze von PencilKit: 10-fach wird angenommen, mehr nicht (darum `maxCanvasZoom`)
        let probe = PKCanvasView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        probe.maximumZoomScale = 12
        probe.zoomScale = 12
        print("[Tinte] PKCanvasView: zoomScale 12 gesetzt, gelesen \(probe.zoomScale)")
        PageInkView.place(probe, pageSize: CGSize(width: 100, height: 100), layout: InkLayout(zoom: 12, window: CGRect(x: 0, y: 0, width: 100, height: 100)))
        XCTAssertEqual(probe.zoomScale, PageInkView.maxCanvasZoom, accuracy: 0.001)
        XCTAssertEqual(probe.bounds.width, 100 * probe.zoomScale, accuracy: 0.01, "Rahmen passt zum tatsaechlichen Zoom")
        // zurueck auf Bildschirmaufloesung: wieder die ganze Seite wie bisher
        v.setRenderScale(2, screen: 2)
        XCTAssertEqual(v.canvas.zoomScale, 1)
        XCTAssertEqual(v.canvas.frame.size.width, 600, accuracy: 0.01)
        XCTAssertEqual(v.canvas.contentOffset, .zero)
    }

    /// "Daneben ansehen": die Seite der Loesung mit der eigenen PDF darunter (nicht weiss), in der Breite der Spalte
    func testSolutionSideImageDrawsThePDFBehindTheNotes() throws {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { ctx in
            ctx.beginPage()
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 50, y: 50, width: 495, height: 200))
        }
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        let p0 = try XCTUnwrap(pdf.page(at: 0))
        let b = p0.bounds(for: .cropBox).size
        let page = SolutionPage(key: "p1", kind: .pdf, pdfIndex: 1, width: Double(b.width), height: Double(b.height), rotation: p0.rotation,
                                extraRotation: 0, objects: [])
        let plain = SolutionPreview.image(page, images: [:], width: 400, scale: 1)
        let withPDF = SolutionPreview.image(page, images: [:], width: 400, scale: 1, pdfPage: p0)
        XCTAssertEqual(withPDF.size.width, 400)
        XCTAssertNotEqual(plain.pngData(), withPDF.pngData(), "die PDF erscheint unter den Notizen")
    }

    func testPreviewMoveFollowsTheFingerAndGoesBack() {
        let view = PageObjectsView(frame: CGRect(x: 0, y: 0, width: 600, height: 800))
        view.show(template: nil, placeholder: nil, objects: [["id": "t", "type": "text", "text": "Hallo", "x": 10, "y": 20]], images: [:])
        let box = view.subviews[0]
        let base = box.transform
        view.previewMove(ids: ["t"], by: CGPoint(x: 5, y: 7))
        XCTAssertEqual(box.transform.tx, base.tx + 5)
        XCTAssertEqual(box.transform.ty, base.ty + 7)
        view.previewMove(ids: ["t"], by: .zero)
        XCTAssertEqual(box.transform, base)
    }
}
