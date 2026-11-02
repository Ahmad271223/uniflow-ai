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
