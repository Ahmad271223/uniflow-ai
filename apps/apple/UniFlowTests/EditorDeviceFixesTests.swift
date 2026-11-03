import PDFKit
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
        XCTAssertEqual(PDFEditorController.renderScale(screen: 2, zoom: 8), 8, "Speicher begrenzt")
        XCTAssertEqual(PDFEditorController.renderScale(screen: 2, zoom: .nan), 2)
        XCTAssertEqual(PDFEditorController.renderScale(screen: 2, zoom: 2.1), PDFEditorController.renderScale(screen: 2, zoom: 2.9), "kleiner Pinch: kein Neuzeichnen")
    }

    func testSetRenderScaleZoomsTheCanvasItself() {
        let v = PageInkView(pageIndex: 0, geometry: PageGeometry(pageSize: CGSize(width: 600, height: 800)))
        v.canvas.addSubview(UIView())
        v.objectsView.show(template: nil, placeholder: nil, objects: [["id": "t", "type": "text", "text": "Hallo", "x": 1, "y": 2]], images: [:])
        v.setRenderScale(10, screen: 2)
        XCTAssertEqual(v.canvas.zoomScale, 5, "PencilKit rendert fertige Striche nur nach seinem eigenen Zoom")
        XCTAssertEqual(v.canvas.bounds.size, CGSize(width: 3000, height: 4000))
        XCTAssertEqual(v.canvas.frame, CGRect(x: 0, y: 0, width: 600, height: 800), "Die Canvas bleibt so gross wie die Seite")
        XCTAssertEqual(v.canvas.contentOffset, .zero)
        XCTAssertEqual(v.objectsView.subviews.first?.contentScaleFactor, 10)
        v.isDrawing = true
        v.setRenderScale(4, screen: 2)
        XCTAssertEqual(v.canvas.zoomScale, 5, "ein laufender Strich bleibt unberuehrt")
        v.isDrawing = false
        v.setRenderScale(8, screen: 2)
        XCTAssertEqual(v.canvas.zoomScale, 5, "leicht herausgezoomt bleiben die feineren Kacheln")
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
