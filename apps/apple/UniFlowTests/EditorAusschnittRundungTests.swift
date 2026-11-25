import PDFKit
import PencilKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Meldung des Inhabers 25.11.2026: "Schreiben zittert etwas" (iPad A16, Schreiben bei starkem Zoom). Zaehler von
/// seinem Geraet: 47-mal "Ausschnitt nach Strich" bei 44 Strichen - die Zeichenflaeche wurde nach JEDEM Strich unter
/// einem Deckbild neu eingehaengt, obwohl die Seite still stand. Ursache: UIScrollView legt `contentOffset` auf halbe
/// Punkte; bei einem Zoom, der kein rundes Vielfaches ist (mit zwei Fingern gewaehlt, z. B. 5,37), liest sich der
/// Ausschnitt der Zeichenflaeche um bis zu 0,25 / Zoom Seitenpunkte versetzt zurueck - mehr als die 0,01, die als
/// "gleich" galten. Die vorhandenen Tests zoomten nur 8-fach (rund), dort fiel es nicht auf.
@MainActor
final class EditorAusschnittRundungTests: XCTestCase {

    private func makeView(zoom: CGFloat, in window: UIWindow) -> (PageInkView, UIScrollView) {
        let scroll = UIScrollView(frame: window.bounds)
        window.addSubview(scroll)
        let v = PageInkView(pageIndex: 0, geometry: PageGeometry(pageSize: CGSize(width: 600, height: 800)))
        v.frame = CGRect(x: 0, y: 0, width: 600 * zoom, height: 800 * zoom)   // Seite gezoomt wie in der PDFView
        scroll.addSubview(v)
        scroll.contentSize = v.frame.size
        v.layoutIfNeeded()
        var d = PKDrawing()
        d.strokes.append(PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: [
            PKStrokePoint(location: CGPoint(x: 20, y: 30), timeOffset: 0, size: CGSize(width: 2, height: 2), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2),
            PKStrokePoint(location: CGPoint(x: 400, y: 600), timeOffset: 0.1, size: CGSize(width: 2, height: 2), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2),
        ], creationDate: Date())))
        v.canvas.drawing = d
        v.setRenderScale(2, screen: 2)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))            // einmal auf dem Bildschirm
        return (v, scroll)
    }

    func testStrichendeHaengtDieZeichenflaecheBeiKrummemZoomNichtUm() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        PencilTuning.coverWindowMoves = true
        for zoom: CGFloat in [5.37, 6.213, 7.3, 9.81, 8] {
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 400, height: 600)
            window.isHidden = false
            defer { window.isHidden = true }
            let (v, scroll) = makeView(zoom: zoom, in: window)
            v.setRenderScale(2 * zoom, screen: 2)
            XCTAssertEqual(v.canvas.zoomScale, zoom, accuracy: 0.001)
            scroll.contentOffset = CGPoint(x: 173 * zoom, y: 291 * zoom)      // irgendwo mitten auf der Seite
            RunLoop.current.run(until: Date().addingTimeInterval(PageInkView.zoomSwitchReveal + 0.3))
            XCTAssertLessThan(v.inkWindow.width, 600, "Zoom \(zoom): nur ein Ausschnitt")
            XCTAssertGreaterThan(v.inkWindow.minX, 1, "Zoom \(zoom): Ausschnitt liegt nicht am Seitenrand")
            XCTAssertFalse(v.isSwitchingZoom, "Zoom \(zoom): Ruhe vor der Messung")

            // 20 Striche hintereinander, die Seite steht still: jedes Strichende setzt die Aufloesung neu
            // (`canvasViewDidEndUsingTool`). Die Zeichenflaeche bleibt, wo sie ist - kein Deckbild, kein Umhaengen.
            let moves = PageInkView.windowMoves, covers = PageInkView.coversMade, rescales = PageInkView.rescalesMade
            let before = v.inkWindow, offset = v.canvas.contentOffset
            for _ in 0..<20 {
                v.setRenderScale(2 * zoom, screen: 2)
                XCTAssertFalse(v.isSwitchingZoom, "Zoom \(zoom): kein Deckbild nach dem Strich")
                XCTAssertNil(v.canvas.layer.mask, "Zoom \(zoom): Zeichenflaeche bleibt sichtbar")
            }
            XCTAssertEqual(PageInkView.windowMoves - moves, 0, "Zoom \(zoom): Ausschnitt nach dem Strich nicht neu gesetzt")
            XCTAssertEqual(PageInkView.coversMade - covers, 0, "Zoom \(zoom): kein Deckbild")
            XCTAssertEqual(PageInkView.rescalesMade - rescales, 0, "Zoom \(zoom): kein Neuzeichnen")
            XCTAssertEqual(v.inkWindow, before, "Zoom \(zoom): Ausschnitt unveraendert")
            XCTAssertEqual(v.canvas.contentOffset, offset, "Zoom \(zoom): Zeichenflaeche nicht angefasst")

            // ein echter Wechsel (Seite waehrend eines Strichs weit verschoben) wird weiter erkannt
            v.isDrawing = true
            scroll.contentOffset = CGPoint(x: 320 * zoom, y: 540 * zoom)
            v.isDrawing = false
            v.setRenderScale(2 * zoom, screen: 2)
            XCTAssertEqual(PageInkView.windowMoves - moves, 1, "Zoom \(zoom): reicht der Ausschnitt nicht, wandert er einmal")
            let visible = try XCTUnwrap(v.viewportInPage()).intersection(CGRect(x: 0, y: 0, width: 600, height: 800))
            XCTAssertTrue(v.inkWindow.insetBy(dx: -0.5, dy: -0.5).contains(visible), "Zoom \(zoom): sichtbarer Teil liegt auf der Zeichenflaeche")
            RunLoop.current.run(until: Date().addingTimeInterval(PageInkView.windowMoveReveal + 0.15))
            v.setRenderScale(2 * zoom, screen: 2)
            XCTAssertEqual(PageInkView.windowMoves - moves, 1, "Zoom \(zoom): danach wieder Ruhe")
        }
    }
}
