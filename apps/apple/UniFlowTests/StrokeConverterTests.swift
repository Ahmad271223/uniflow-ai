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

    // MARK: Unbekannte Felder (Schema: muessen erhalten bleiben)

    private func ids(_ page: JSONValue) -> [String] { page["objects"]?.array?.compactMap { $0["id"]?.string } ?? [] }

    func testLassoMoveKeepsUnknownFields() {
        let page: JSONValue = ["objects": [webStroke("a")]]
        var (drawing, state) = StrokeConverter.drawing(fromPage: page)
        drawing.strokes[0].transform = CGAffineTransform(translationX: 30, y: 0)
        let (out, _) = StrokeConverter.page(from: drawing, previous: page, state: state)
        let o = out["objects"]?.array?.first
        XCTAssertEqual(o?["id"], "a")
        XCTAssertEqual(o?["fremdesFeld"], "bleibt")
        XCTAssertEqual(o?["tool"], "pen")
        XCTAssertEqual(o?["color"], "#e5322d")
        XCTAssertEqual(o?["pkInk"]?.string, PKInk.InkType.pen.rawValue)
    }

    func testColorChangeKeepsUnknownFields() {
        let page: JSONValue = ["objects": [webStroke("a")]]
        var (drawing, state) = StrokeConverter.drawing(fromPage: page)
        drawing.strokes[0].ink = PKInk(.pen, color: UIColor(red: 0, green: 0, blue: 1, alpha: 1))
        let (out, _) = StrokeConverter.page(from: drawing, previous: page, state: state)
        let o = out["objects"]?.array?.first
        XCTAssertEqual(o?["id"], "a")
        XCTAssertEqual(o?["color"], "#0000ff")
        XCTAssertEqual(o?["fremdesFeld"], "bleibt")
    }

    func testPixelEraserOnWebStrokeKeepsUnknownFieldsInEveryPiece() {
        let page: JSONValue = ["objects": [webStroke("a", x: 10, points: 30)]]
        var (drawing, state) = StrokeConverter.drawing(fromPage: page)
        let mask = UIBezierPath(rect: CGRect(x: 0, y: 0, width: 50, height: 300))
        mask.append(UIBezierPath(rect: CGRect(x: 70, y: 0, width: 300, height: 300)))
        drawing.strokes[0].mask = mask
        let (out, _) = StrokeConverter.page(from: drawing, previous: page, state: state)
        let objs = out["objects"]?.array ?? []
        XCTAssertGreaterThanOrEqual(objs.count, 2)
        XCTAssertEqual(objs.first?["id"], "a", "erstes Stueck behaelt die ID")
        for o in objs { XCTAssertEqual(o["fremdesFeld"], "bleibt") }
        XCTAssertEqual(Set(objs.compactMap { $0["id"]?.string }).count, objs.count)
    }

    // MARK: Werkzeuge

    func testFountainMapsBothWays() {
        let page: JSONValue = ["objects": [webStroke("f", tool: "fountain")]]
        let (drawing, state) = StrokeConverter.drawing(fromPage: page)
        XCTAssertEqual(drawing.strokes.first?.ink.inkType, .fountainPen)
        var d = drawing
        d.strokes.append(nativeStroke(at: 200))
        d.strokes[1].ink = PKInk(.fountainPen, color: .black)
        let (out, _) = StrokeConverter.page(from: d, previous: page, state: state)
        let objs = out["objects"]?.array ?? []
        XCTAssertEqual(objs.first?["tool"], "fountain", "Web-Strich unveraendert")
        XCTAssertEqual(objs.last?["tool"], "fountain")
        XCTAssertEqual(objs.last?["pkInk"]?.string, PKInk.InkType.fountainPen.rawValue)
    }

    func testNativeInkIsRestoredUnlessToolChangedInBrowser() {
        var mono = webStroke("m")
        mono["pkInk"] = .string(PKInk.InkType.monoline.rawValue)
        XCTAssertEqual(StrokeConverter.drawing(fromPage: ["objects": [mono]]).0.strokes.first?.ink.inkType, .monoline)
        mono["tool"] = "pencil"                                     // im Browser auf Bleistift umgestellt
        XCTAssertEqual(StrokeConverter.drawing(fromPage: ["objects": [mono]]).0.strokes.first?.ink.inkType, .pencil)
        mono["tool"] = "pen"
        mono["pkInk"] = "com.example.unbekannt"
        XCTAssertEqual(StrokeConverter.drawing(fromPage: ["objects": [mono]]).0.strokes.first?.ink.inkType, .pen)
        XCTAssertEqual(StrokeConverter.webTool(for: .crayon), "pencil")
        XCTAssertEqual(StrokeConverter.webTool(for: .watercolor), "marker")
        XCTAssertEqual(StrokeConverter.webTool(for: .monoline), "pen")
    }

    func testMarkerOpacityFromJSONIsRespected() {
        var light = webStroke("m", tool: "marker")
        light["opacity"] = 0.175
        let s = StrokeConverter.drawing(fromPage: ["objects": [light]]).0.strokes.first
        XCTAssertEqual(s?.ink.inkType, .marker)
        XCTAssertEqual(s?.ink.color.uniflowRGBA.alpha ?? 0, 0.5, accuracy: 0.01, "0,175 = halbe Markerfarbe")
        // geaenderter Marker mit kraeftigerer Deckkraft als PencilKit darstellt: Wert bleibt
        var strong = webStroke("s", tool: "marker")
        strong["opacity"] = 0.6
        let page: JSONValue = ["objects": [strong]]
        var (drawing, state) = StrokeConverter.drawing(fromPage: page)
        drawing.strokes[0].transform = CGAffineTransform(translationX: 5, y: 5)
        let (out, _) = StrokeConverter.page(from: drawing, previous: page, state: state)
        XCTAssertEqual(out["objects"]?.array?.first?["opacity"], 0.6)
        // neuer Marker vom iPad: Standard-Deckkraft des Web-Editors
        var d = PKDrawing()
        d.strokes.append(nativeStroke(at: 300))
        d.strokes[0].ink = PKInk(.marker, color: .yellow)
        let (fresh, _) = StrokeConverter.page(from: d, previous: ["objects": []], state: InkPageState())
        XCTAssertEqual(fresh["objects"]?.array?.first?["opacity"]?.double ?? 0, 0.35, accuracy: 0.001)
        XCTAssertEqual(fresh["objects"]?.array?.first?["tool"], "marker")
    }

    // MARK: pkdrawing-v2

    func testBrowserEditKeepsUnchangedNativeStrokes() throws {
        let created = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let text: JSONValue = ["id": "t1", "type": "text", "text": "Notiz", "x": 5, "y": 5]
        let page: JSONValue = ["objects": [text]]
        var (d, state) = StrokeConverter.drawing(fromPage: page)
        d.strokes.append(nativeStroke(at: 100, created: created))
        d.strokes.append(nativeStroke(at: 140, created: created.addingTimeInterval(1)))
        d.strokes.append(nativeStroke(at: 180, created: created.addingTimeInterval(2)))
        let (saved, _) = StrokeConverter.page(from: d, previous: page, state: state)
        XCTAssertEqual(saved["pkdrawing"]?["format"], "pkdrawing-v2")
        XCTAssertEqual(saved["pkdrawing"]?["strokeSigs"]?.array?.count, 3)
        // im Browser: Text verschoben, ein Strich umgefaerbt
        var objs = try XCTUnwrap(saved["objects"]?.array)
        objs[0]["x"] = 300
        objs[2]["color"] = "#00ff00"
        var edited = saved
        edited["objects"] = .array(objs)
        let (reloaded, _) = StrokeConverter.drawing(fromPage: edited)
        XCTAssertEqual(reloaded.strokes.count, 3)
        let dates = reloaded.strokes.map { $0.path.creationDate.timeIntervalSinceReferenceDate }
        XCTAssertEqual(dates[0], created.timeIntervalSinceReferenceDate, accuracy: 0.01, "nativ geblieben")
        XCTAssertLessThan(dates[1], 10_000, "umgefaerbter Strich aus JSON neu aufgebaut")
        XCTAssertEqual(dates[2], created.timeIntervalSinceReferenceDate + 2, accuracy: 0.01, "nativ geblieben")
        XCTAssertEqual(reloaded.strokes[1].ink.color.uniflowRGBA.hex, "#00ff00")
    }

    func testV1DrawingIsStillRead() {
        let created = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var d = PKDrawing()
        d.strokes.append(nativeStroke(at: 100, created: created))
        let (saved, _) = StrokeConverter.page(from: d, previous: ["objects": []], state: InkPageState())
        let objects = saved["objects"]?.array ?? []
        // wie eine aeltere App-Version: nur v1-Felder
        let v1 = StoredDrawing(data: StoredDrawing(page: saved)!.data, signature: StrokeConverter.signature(objects),
                               strokeIDs: [objects.compactMap { $0["id"]?.string }])
        let page: JSONValue = ["objects": .array(objects), "pkdrawing": v1.json]
        XCTAssertEqual(page["pkdrawing"]?["format"], "pkdrawing-v1")
        let (native, state) = StrokeConverter.drawing(fromPage: page)
        XCTAssertEqual(native.strokes.first?.path.creationDate.timeIntervalSinceReferenceDate ?? 0, created.timeIntervalSinceReferenceDate, accuracy: 0.01)
        XCTAssertEqual(state.represented, Set(objects.compactMap { $0["id"]?.string }))
        // v1 mit veralteter Signatur: Neuaufbau aus JSON
        var stale = page
        stale["pkdrawing"] = StoredDrawing(data: v1.data, signature: "alt", strokeIDs: v1.strokeIDs).json
        XCTAssertLessThan(StrokeConverter.drawing(fromPage: stale).0.strokes.first?.path.creationDate.timeIntervalSinceReferenceDate ?? 0, 10_000)
    }

    func testMergedPageWithServerDeletionShowsRemainingStrokesNatively() {
        let created = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var d = PKDrawing()
        d.strokes.append(nativeStroke(at: 100, created: created))
        d.strokes.append(nativeStroke(at: 140, created: created.addingTimeInterval(1)))
        let (local, _) = StrokeConverter.page(from: d, previous: ["objects": []], state: InkPageState())
        let objs = local["objects"]?.array ?? []
        let base: JSONValue = ["objects": []]
        let server: JSONValue = ["objects": [webStroke("web")]]
        let merged = AnnotationMerge.mergePage(base: base, local: local, server: server).page
        XCTAssertNotNil(merged?["pkdrawing"], "v2 bleibt trotz abweichender Objekte")
        // Browser loescht danach den ersten iPad-Strich
        var afterDelete = merged!
        afterDelete["objects"] = .array((merged?["objects"]?.array ?? []).filter { $0["id"] != objs[0]["id"] })
        let (drawing, _) = StrokeConverter.drawing(fromPage: afterDelete)
        let dates = drawing.strokes.map { $0.path.creationDate.timeIntervalSinceReferenceDate }
        XCTAssertEqual(drawing.strokes.count, 2, "Web-Strich + verbliebener iPad-Strich")
        XCTAssertTrue(dates.contains { abs($0 - (created.timeIntervalSinceReferenceDate + 1)) < 0.01 }, "verbliebener iPad-Strich nativ")
        XCTAssertFalse(dates.contains { abs($0 - created.timeIntervalSinceReferenceDate) < 0.01 }, "geloeschter Strich kommt nicht zurueck")
    }

    // MARK: Drei-Wege beim Speichern

    func testStrokeDeletedInBrowserDoesNotReturnWhileWritingOnIPad() {
        let page: JSONValue = ["objects": [webStroke("a"), webStroke("b", x: 100)]]
        var (drawing, state) = StrokeConverter.drawing(fromPage: page)
        let browser: JSONValue = ["objects": [webStroke("b", x: 100)]]          // im Browser a geloescht
        drawing.strokes.append(nativeStroke(at: 300))                          // gleichzeitig auf dem iPad geschrieben
        let first = StrokeConverter.update(from: drawing, previous: browser, state: state)
        XCTAssertEqual(ids(first.page).first, "b")
        XCTAssertEqual(ids(first.page).count, 2)
        XCTAssertFalse(ids(first.page).contains("a"), "Loeschung gewinnt gegen unveraendert")
        XCTAssertTrue(first.canvasOutdated, "Canvas zeigt a noch: neu laden")
        // naechster Strich, bevor die Canvas neu geladen ist: a bleibt weg und bekommt keine neue ID
        drawing.strokes.append(nativeStroke(at: 340))
        let second = StrokeConverter.update(from: drawing, previous: first.page, state: first.state)
        XCTAssertEqual(ids(second.page).count, 3)
        XCTAssertEqual(Array(ids(second.page).prefix(2)), ids(first.page))
        XCTAssertEqual(StoredDrawing(page: second.page)?.strokeIDs.count, 3, "Geisterstrich nicht in pkdrawing")
    }

    func testBrowserChangeOfUnchangedStrokeWins() {
        let page: JSONValue = ["objects": [webStroke("a"), webStroke("b", x: 100)]]
        var (drawing, state) = StrokeConverter.drawing(fromPage: page)
        var recolored = webStroke("a")
        recolored["color"] = "#00ff00"
        let browser: JSONValue = ["objects": [recolored, webStroke("b", x: 100)]]
        drawing.strokes.append(nativeStroke(at: 300))
        let u = StrokeConverter.update(from: drawing, previous: browser, state: state)
        XCTAssertEqual(u.page["objects"]?.array?.first?["color"], "#00ff00", "Browser-Aenderung nicht zurueckgesetzt")
        XCTAssertTrue(u.canvasOutdated)
        let stored = StoredDrawing(page: u.page)
        XCTAssertFalse(stored?.strokeIDs.contains(["a"]) ?? true, "nativer Strich passt nicht mehr zum JSON")
        XCTAssertEqual(stored?.signature, "teilweise", "aeltere Versionen bauen aus JSON auf")
    }

    func testErasedHereButChangedInBrowserIsKept() {
        let page: JSONValue = ["objects": [webStroke("a"), webStroke("b", x: 100)]]
        var (drawing, state) = StrokeConverter.drawing(fromPage: page)
        drawing.strokes.remove(at: 0)                                          // hier radiert
        var moved = webStroke("a")
        moved["x"] = 50                                                        // dort verschoben
        let u = StrokeConverter.update(from: drawing, previous: ["objects": [moved, webStroke("b", x: 100)]], state: state)
        XCTAssertEqual(ids(u.page), ["a", "b"])
        XCTAssertEqual(u.page["objects"]?.array?.first?["x"], 50)
        XCTAssertTrue(u.canvasOutdated)
    }

    func testUnchangedPageIsNotOutdated() {
        let page: JSONValue = ["objects": [webStroke("a")]]
        let (drawing, state) = StrokeConverter.drawing(fromPage: page)
        XCTAssertFalse(StrokeConverter.update(from: drawing, previous: page, state: state).canvasOutdated)
    }

    func testColorRoundTrip() {
        XCTAssertEqual(UIColor(hex: "#e5322d")?.uniflowRGBA.hex, "#e5322d")
        XCTAssertEqual(UIColor.black.uniflowRGBA.hex, "#000000")
        XCTAssertEqual(UIColor.white.withAlphaComponent(0.5).uniflowRGBA.alpha, 0.5, accuracy: 0.01)
    }
}
