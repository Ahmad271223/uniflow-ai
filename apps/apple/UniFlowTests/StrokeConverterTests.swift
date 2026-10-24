import PencilKit
import UniFlowCore
import XCTest
@testable import UniFlow

final class StrokeConverterTests: XCTestCase {

    private func webStroke(_ id: String, x: Double = 10, points: Int = 8, tool: String = "pen") -> JSONValue {
        var pts: [JSONValue] = []
        for i in 0..<points { pts.append(.number(x + Double(i) * 4)); pts.append(.number(40 + Double(i % 3))) }
        return .object(["id": .string(id), "type": "stroke", "tool": .string(tool), "color": "#e5322d", "width": 2.5,
                        "opacity": 1, "points": .array(pts), "x": 0, "y": 0, "rotation": 0, "scaleX": 1, "scaleY": 1,
                        "fremdesFeld": "bleibt"])
    }

    private func nativeStroke(at y: CGFloat, created: Date = Date()) -> PKStroke {
        let pts = (0..<20).map { i in
            PKStrokePoint(location: CGPoint(x: 50 + CGFloat(i) * 3, y: y), timeOffset: Double(i) * 0.01,
                          size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: pts, creationDate: created))
    }

    func testWebStrokesSurviveUnchanged() {
        let text: JSONValue = ["id": "t1", "type": "text", "text": "Notiz", "x": 5, "y": 5]
        let page: JSONValue = ["objects": [webStroke("a"), text, webStroke("b", x: 100)], "template": "lined"]
        let (drawing, state) = StrokeConverter.drawing(fromPage: page)
        XCTAssertEqual(drawing.strokes.count, 2)
        let (out, _) = StrokeConverter.page(from: drawing, previous: page, state: state)
        XCTAssertEqual(out["objects"], page["objects"], "unveraenderte Objekte bleiben Byte fuer Byte gleich")
        XCTAssertEqual(out["template"], "lined")
        XCTAssertNotNil(StoredDrawing(page: out))
    }

    func testNewStrokeGetsNewIDOldKeepTheirs() {
        let page: JSONValue = ["objects": [webStroke("a")]]
        var (drawing, state) = StrokeConverter.drawing(fromPage: page)
        drawing.strokes.append(nativeStroke(at: 200))
        let (out, next) = StrokeConverter.page(from: drawing, previous: page, state: state)
        let ids = out["objects"]?.array?.compactMap { $0["id"]?.string } ?? []
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(ids.first, "a")
        XCTAssertTrue(ids[1].hasPrefix("pk"))
        // zweite Runde ohne Aenderung: gleiche IDs, kein neues Objekt
        let (again, _) = StrokeConverter.page(from: drawing, previous: out, state: next)
        XCTAssertEqual(again["objects"], out["objects"])
    }

    func testReopenFromStoredDrawingKeepsIDs() {
        let page: JSONValue = ["objects": []]
        let (empty, state) = StrokeConverter.drawing(fromPage: page)
        var d = empty
        d.strokes.append(nativeStroke(at: 100))
        d.strokes.append(nativeStroke(at: 140))
        let (saved, _) = StrokeConverter.page(from: d, previous: page, state: state)
        // "App neu gestartet": Zeichnung aus pkdrawing, IDs aus strokeIds
        let (reloaded, reloadedState) = StrokeConverter.drawing(fromPage: saved)
        XCTAssertEqual(reloaded.strokes.count, 2)
        var more = reloaded
        more.strokes.append(nativeStroke(at: 180))
        let (out, _) = StrokeConverter.page(from: more, previous: saved, state: reloadedState)
        let before = saved["objects"]?.array?.compactMap { $0["id"]?.string } ?? []
        let after = out["objects"]?.array?.compactMap { $0["id"]?.string } ?? []
        XCTAssertEqual(Array(after.prefix(2)), before)
        XCTAssertEqual(after.count, 3)
    }

    func testEraseRemovesOnlyThatStroke() {
        let page: JSONValue = ["objects": [webStroke("a"), webStroke("b", x: 100), webStroke("c", x: 200)]]
        var (drawing, state) = StrokeConverter.drawing(fromPage: page)
        drawing.strokes.remove(at: 1)
        let (out, _) = StrokeConverter.page(from: drawing, previous: page, state: state)
        XCTAssertEqual(out["objects"]?.array?.compactMap { $0["id"]?.string }, ["a", "c"])
    }

    func testLassoMoveKeepsIDAndMovesPoints() {
        let page: JSONValue = ["objects": [webStroke("a")]]
        var (drawing, state) = StrokeConverter.drawing(fromPage: page)
        drawing.strokes[0].transform = CGAffineTransform(translationX: 30, y: 0)
        let (out, _) = StrokeConverter.page(from: drawing, previous: page, state: state)
        let o = out["objects"]?.array?.first
        XCTAssertEqual(o?["id"], "a")
        let x0 = o?["points"]?.array?.first?.double ?? 0
        XCTAssertEqual(x0, 40, accuracy: 0.6, "um 30 Punkte verschoben")
    }

    func testPixelEraserSplitsIntoVisibleParts() {
        let page: JSONValue = ["objects": []]
        let (empty, state) = StrokeConverter.drawing(fromPage: page)
        var s = nativeStroke(at: 100)
        // Maske: links und rechts sichtbar, Mitte radiert
        let mask = UIBezierPath(rect: CGRect(x: 0, y: 0, width: 70, height: 300))
        mask.append(UIBezierPath(rect: CGRect(x: 90, y: 0, width: 300, height: 300)))
        s.mask = mask
        var d = empty
        d.strokes.append(s)
        let (out, _) = StrokeConverter.page(from: d, previous: page, state: state)
        let objs = out["objects"]?.array ?? []
        XCTAssertEqual(objs.count, s.maskedPathRanges.count)
        XCTAssertGreaterThanOrEqual(objs.count, 2, "radierte Mitte erscheint im Browser nicht")
        XCTAssertEqual(Set(objs.compactMap { $0["id"]?.string }).count, objs.count)
    }

    func testThousandStrokesProcessQuickly() {
        let objects = (0..<1000).map { webStroke("s\($0)", x: Double($0 % 50) * 10) }
        let page: JSONValue = ["objects": .array(objects)]
        let start = Date()
        var (drawing, state) = StrokeConverter.drawing(fromPage: page)
        let build = Date().timeIntervalSince(start)
        drawing.strokes.append(nativeStroke(at: 500))
        let t1 = Date()
        let (out, _) = StrokeConverter.page(from: drawing, previous: page, state: state)
        let update = Date().timeIntervalSince(t1)
        XCTAssertEqual(out["objects"]?.array?.count, 1001)
        print("1000 Striche: Aufbau \(String(format: "%.3f", build)) s, Aenderung \(String(format: "%.3f", update)) s")
        XCTAssertLessThan(update, 10)
    }

    func testColorRoundTrip() {
        XCTAssertEqual(UIColor(hex: "#e5322d")?.uniflowRGBA.hex, "#e5322d")
        XCTAssertEqual(UIColor.black.uniflowRGBA.hex, "#000000")
        XCTAssertEqual(UIColor.white.withAlphaComponent(0.5).uniflowRGBA.alpha, 0.5, accuracy: 0.01)
    }
}
