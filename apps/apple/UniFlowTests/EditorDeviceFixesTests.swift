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
        XCTAssertEqual(PDFEditorController.renderScale(screen: 2, zoom: 8), 5, "Speicher begrenzt")
        XCTAssertEqual(PDFEditorController.renderScale(screen: 2, zoom: .nan), 2)
    }

    func testSetRenderScaleReachesCanvasObjectsAndSubviews() {
        let v = PageInkView(pageIndex: 0, geometry: PageGeometry(pageSize: CGSize(width: 600, height: 800)))
        v.canvas.addSubview(UIView())
        v.objectsView.show(template: nil, placeholder: nil, objects: [["id": "t", "type": "text", "text": "Hallo", "x": 1, "y": 2]], images: [:])
        v.setRenderScale(4)
        XCTAssertEqual(v.canvas.contentScaleFactor, 4)
        XCTAssertEqual(v.canvas.subviews.first?.contentScaleFactor, 4)
        XCTAssertEqual(v.objectsView.subviews.first?.contentScaleFactor, 4)
        v.setRenderScale(2)
        XCTAssertGreaterThanOrEqual(v.objectsView.subviews.first?.contentScaleFactor ?? 0, UIScreen.main.scale * 2, "Text nie groeber als vorher")
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
