import PencilKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Externe Pruefpunkte 331-340 (docs/audit/RUNDE-11-331-380.md): Umrechnung PencilKit <-> Seiten-JSON. Was nur der
/// echte Stift zeigt (Druck, Neigung, Zeitverhalten der Canvas), steht dort als Pruefanleitung fuer das Geraet.
final class AuditRunde11PencilTests: XCTestCase {

    private func ids(_ page: JSONValue) -> [String] { page["objects"]?.array?.compactMap { $0["id"]?.string } ?? [] }

    private func webStroke(_ id: String, points: [Double], tool: String = "pen", opacity: Double = 1, widths: [Double]? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "type": "stroke", "tool": .string(tool), "color": "#1d4ed8", "width": 3,
                                      "opacity": .number(opacity), "points": .array(points.map { .number($0) }),
                                      "x": 0, "y": 0, "rotation": 0, "scaleX": 1, "scaleY": 1]
        if let widths { o["widths"] = .array(widths.map { .number($0) }) }
        return .object(o)
    }

    /// Strich wie vom Stift: Erstellzeit heute, wechselnder Druck, Neigung und Breite je Punkt
    private func pencilStroke(y: CGFloat, count: Int = 40, created: Date = Date(timeIntervalSinceReferenceDate: 800_000_000),
                              ink: PKInk = PKInk(.pen, color: .black)) -> PKStroke {
        let pts = (0..<count).map { i in
            PKStrokePoint(location: CGPoint(x: 40 + CGFloat(i) * 2.5, y: y + CGFloat(i % 7)), timeOffset: Double(i) * 0.0042,
                          size: CGSize(width: 1.5 + CGFloat(i % 5) * 0.8, height: 1.5 + CGFloat(i % 5) * 0.8),
                          opacity: 1, force: 0.2 + CGFloat(i % 9) * 0.1, azimuth: CGFloat(i % 4) * 0.3, altitude: 0.6 + CGFloat(i % 3) * 0.2)
        }
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: pts, creationDate: created))
    }

    // MARK: 331 nicht lesbare native Zeichnung

    func testUndecodableNativeDrawingKeepsEveryStrokeFromTheObjects() throws {
        var d = PKDrawing()
        for i in 0..<5 { d.strokes.append(pencilStroke(y: 60 + CGFloat(i) * 30, created: Date(timeIntervalSinceReferenceDate: 800_000_000 + Double(i)))) }
        let saved = StrokeConverter.update(from: d, previous: ["objects": [webStroke("web", points: [5, 5, 50, 50])]], state: InkPageState()).page
        let objects = try XCTUnwrap(saved["objects"]?.array)
        XCTAssertEqual(objects.count, 6)
        for broken in ["!!kein-base64!!", Data("PencilKit? nein".utf8).base64EncodedString(), ""] {
            var page = saved
            page["pkdrawing"]?["data"] = .string(broken)
            let (drawing, state) = StrokeConverter.drawing(fromPage: page)
            XCTAssertEqual(drawing.strokes.count, 6, "jeder Strich aus den Objekten aufgebaut (\(broken.prefix(8)))")
            XCTAssertEqual(state.represented, Set(ids(saved)))
            // unveraendert gespeichert: Objekte Byte fuer Byte gleich, die native Zeichnung neu und lesbar
            let again = StrokeConverter.update(from: drawing, previous: page, state: state)
            XCTAssertEqual(again.page["objects"], saved["objects"])
            XCTAssertFalse(again.canvasOutdated)
            let stored = try XCTUnwrap(StoredDrawing(page: again.page))
            XCTAssertEqual(try PKDrawing(data: try XCTUnwrap(Data(base64Encoded: stored.data))).strokes.count, 6)
        }
    }

    // MARK: 332 Zahl der Strich-IDs

    func testStoredStrokeIDsAlwaysMatchTheNativeStrokes() throws {
        func check(_ page: JSONValue, _ what: String) throws {
            let stored = try XCTUnwrap(StoredDrawing(page: page), what)
            let native = try PKDrawing(data: try XCTUnwrap(Data(base64Encoded: stored.data)))
            XCTAssertEqual(stored.strokeIDs.count, native.strokes.count, what)
            XCTAssertEqual(stored.strokeSignatures?.count, native.strokes.count, what)
            let all = stored.strokeIDs.flatMap { $0 }
            XCTAssertEqual(all.count, Set(all).count, "\(what): keine ID doppelt")
            XCTAssertTrue(Set(all).isSubset(of: Set(ids(page))), "\(what): nur IDs, die es auf der Seite gibt")
        }
        var d = PKDrawing()
        for i in 0..<4 { d.strokes.append(pencilStroke(y: 50 + CGFloat(i) * 40, created: Date(timeIntervalSinceReferenceDate: 800_000_000 + Double(i)))) }
        let first = StrokeConverter.update(from: d, previous: ["objects": [webStroke("web", points: [5, 5, 60, 60])]], state: InkPageState())
        try check(first.page, "neu")
        // Radierer teilt einen Strich in zwei Stuecke (ein nativer Strich, zwei IDs)
        var (erased, erasedState) = StrokeConverter.drawing(fromPage: first.page)
        let mask = UIBezierPath(rect: CGRect(x: 0, y: 0, width: 70, height: 400))
        mask.append(UIBezierPath(rect: CGRect(x: 100, y: 0, width: 400, height: 400)))
        erased.strokes[1].mask = mask
        let split = StrokeConverter.update(from: erased, previous: first.page, state: erasedState)
        try check(split.page, "geteilt")
        // im Browser: ein Strich geloescht, einer umgefaerbt -> Geisterstrich und geaenderter Strich nicht in pkdrawing
        var objs = try XCTUnwrap(split.page["objects"]?.array)
        objs.remove(at: 2)
        objs[3]["color"] = "#00aa00"
        var browser = split.page
        browser["objects"] = .array(objs)
        let (stale, staleState) = StrokeConverter.drawing(fromPage: split.page)
        let ghost = StrokeConverter.update(from: stale, previous: browser, state: staleState)
        try check(ghost.page, "Geist")
        // manipulierte Zahl der IDs: nicht nativ verwendet, alles aus den Objekten
        var tampered = ghost.page
        tampered["pkdrawing"]?["strokeIds"] = .array([["x"]])
        let (rebuilt, _) = StrokeConverter.drawing(fromPage: tampered)
        XCTAssertEqual(rebuilt.strokes.count, ids(tampered).count)
        XCTAssertTrue(rebuilt.strokes.allSatisfy { $0.path.creationDate.timeIntervalSinceReferenceDate < 10_000 })
    }

    // MARK: 333 nicht darstellbare Striche

    func testUnrenderableStrokesAreKeptCountedAndNotDrawn() {
        let broken: [JSONValue] = [
            ["id": "eins", "type": "stroke", "points": [10, 10]],                          // ein Punkt ohne Partner
            ["id": "ungerade", "type": "stroke", "points": [10, 10, 20]],
            ["id": "leer", "type": "stroke", "points": []],
            ["type": "stroke", "points": [1, 1, 30, 30]],                                  // ohne ID
            webStroke("riesig", points: [0, 0, 5e9, 5e9]),
            webStroke("ok", points: [10, 10, 80, 80]),
        ]
        let page: JSONValue = ["objects": .array(broken + [["id": "t", "type": "text", "text": "Notiz"]])]
        let (drawing, state) = StrokeConverter.drawing(fromPage: page)
        XCTAssertEqual(drawing.strokes.count, 1, "nur der darstellbare Strich")
        XCTAssertEqual(state.unrenderable, 5)
        var d = drawing
        d.strokes.append(pencilStroke(y: 200))
        let out = StrokeConverter.update(from: d, previous: page, state: state).page
        let kept = out["objects"]?.array ?? []
        for o in broken + [["id": "t", "type": "text", "text": "Notiz"]] { XCTAssertTrue(kept.contains(o), "unveraendert behalten: \(o)") }
        XCTAssertEqual(kept.count, broken.count + 2)
    }

    // MARK: 334 Neuladen waehrend des Schreibens

    /// Viele Runden "Neuladen, waehrenddessen auf der alten Canvas weiterschreiben, umrechnen": keine ID doppelt,
    /// kein Strich doppelt, keiner verloren
    func testInterleavedReloadsAndWritingNeverDuplicateStrokes() async throws {
        let ink = InkProcessor()
        var page: JSONValue = ["objects": [webStroke("web1", points: [5, 5, 40, 40]), webStroke("web2", points: [50, 5, 90, 40])]]
        var canvas = await ink.drawing(key: "p", page: page).drawing
        var written = 0
        for round in 0..<12 {
            canvas.strokes.append(pencilStroke(y: 100 + CGFloat(round) * 15, created: Date(timeIntervalSinceReferenceDate: 800_000_000 + Double(round))))
            written += 1
            let u = await ink.page(key: "p", drawing: DrawingBox(drawing: canvas), previous: page)
            page = u.page
            if round % 3 == 0 { _ = await ink.drawing(key: "p", page: page) }      // Neuladen, Canvas noch alt
            if round % 3 == 2 { canvas = await ink.drawing(key: "p", page: page).drawing }   // neue Canvas angekommen
            let all = ids(page)
            XCTAssertEqual(all.count, Set(all).count, "Runde \(round): doppelte ID")
            XCTAssertEqual(all.count, 2 + written, "Runde \(round): \(all)")
            XCTAssertEqual(canvas.strokes.count, 2 + written, "Runde \(round): Canvas")
        }
    }

    // MARK: 336 Breite und Druck

    func testWidthsPressureAndTiltSurviveSavingAndReopening() throws {
        var d = PKDrawing()
        d.strokes.append(pencilStroke(y: 80))
        let original = d.strokes[0]
        let saved = StrokeConverter.update(from: d, previous: ["objects": []], state: InkPageState()).page
        let widths = try XCTUnwrap(saved["objects"]?.array?.first?["widths"]?.array?.compactMap { $0.double })
        XCTAssertGreaterThan((widths.max() ?? 0) - (widths.min() ?? 0), 1, "Breite je Punkt im JSON")
        let (reopened, state) = StrokeConverter.drawing(fromPage: saved)
        let s = try XCTUnwrap(reopened.strokes.first)
        XCTAssertEqual(s.path.count, original.path.count)
        for (a, b) in zip(original.path, s.path) {
            XCTAssertEqual(a.size.width, b.size.width, accuracy: 0.001)
            XCTAssertEqual(a.force, b.force, accuracy: 0.001, "Druck bleibt (native Zeichnung)")
            XCTAssertEqual(a.altitude, b.altitude, accuracy: 0.001, "Neigung bleibt")
            XCTAssertEqual(a.azimuth, b.azimuth, accuracy: 0.001)
        }
        // nach dem erneuten Speichern ohne Aenderung: Objekt Byte fuer Byte gleich
        XCTAssertEqual(StrokeConverter.update(from: reopened, previous: saved, state: state).page["objects"], saved["objects"])
        // aus dem Browser (nur Breiten, kein Druck): die Breiten je Punkt bleiben
        let web = webStroke("w", points: [10, 10, 20, 12, 30, 15, 40, 20], widths: [1, 2.5, 4, 2])
        let (fromWeb, webState) = StrokeConverter.drawing(fromPage: ["objects": [web]])
        XCTAssertEqual(fromWeb.strokes.first?.path.map { Double($0.size.width) }, [1, 2.5, 4, 2])
        var moved = fromWeb
        moved.strokes[0].transform = CGAffineTransform(translationX: 3, y: 0)
        let out = StrokeConverter.update(from: moved, previous: ["objects": [web]], state: webState).page
        XCTAssertEqual(out["objects"]?.array?.first?["widths"], web["widths"], "Breiten nach dem Verschieben")
    }

    // MARK: 337 Textmarker

    func testMarkerTransparencyIsStableOverManyRoundTrips() throws {
        for opacity in [0.35, 0.2, 0.6] {
            var page: JSONValue = ["objects": [webStroke("m", points: [10, 50, 60, 52, 120, 55], tool: "marker", opacity: opacity)]]
            for cycle in 0..<6 {
                let (d, state) = StrokeConverter.drawing(fromPage: page)
                XCTAssertEqual(d.strokes.first?.ink.inkType, .marker)
                var moved = d
                moved.strokes[0].transform = CGAffineTransform(translationX: 2, y: 1)
                page = StrokeConverter.update(from: moved, previous: page, state: state).page
                XCTAssertEqual(page["objects"]?.array?.first?["opacity"]?.double ?? -1, opacity, accuracy: 0.001, "Runde \(cycle)")
                XCTAssertEqual(page["objects"]?.array?.first?["tool"], "marker")
                page["pkdrawing"] = nil                                       // wie nach einer Aenderung im Browser
            }
        }
        // Marker vom Stift: Deckkraft bleibt ueber Speichern und Oeffnen
        var d = PKDrawing()
        d.strokes.append(pencilStroke(y: 90, ink: PKInk(.marker, color: UIColor.yellow.withAlphaComponent(0.5))))
        let saved = StrokeConverter.update(from: d, previous: ["objects": []], state: InkPageState()).page
        let (re, _) = StrokeConverter.drawing(fromPage: saved)
        XCTAssertEqual(re.strokes.first?.ink.color.uniflowRGBA.alpha ?? 0, 0.5, accuracy: 0.01)
        var noNative = saved
        noNative["pkdrawing"] = nil
        XCTAssertEqual(StrokeConverter.drawing(fromPage: noNative).0.strokes.first?.ink.color.uniflowRGBA.alpha ?? 0, 0.5, accuracy: 0.01)
    }

    // MARK: 338 kurze Striche und Punkte

    func testVeryShortStrokesAndDotsNeverDisappear() throws {
        let created = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func tiny(_ dx: CGFloat, count: Int, at date: Date) -> PKStroke {
            let pts = (0..<count).map { i in
                PKStrokePoint(location: CGPoint(x: 100 + CGFloat(i) * dx, y: 100), timeOffset: Double(i) * 0.004,
                              size: CGSize(width: 2, height: 2), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: pts, creationDate: date))
        }
        var d = PKDrawing()
        d.strokes.append(tiny(0, count: 1, at: created))                      // Punkt
        d.strokes.append(tiny(0.05, count: 2, at: created.addingTimeInterval(1)))   // 0,05 pt
        d.strokes.append(tiny(0.4, count: 3, at: created.addingTimeInterval(2)))
        let saved = StrokeConverter.update(from: d, previous: ["objects": []], state: InkPageState()).page
        XCTAssertEqual(ids(saved).count, 3, "jeder Strich ein Objekt")
        for o in saved["objects"]?.array ?? [] { XCTAssertGreaterThanOrEqual(o["points"]?.array?.count ?? 0, 4) }
        // aus den Objekten (Browser) wieder aufgebaut: alle drei da
        var web = saved
        web["pkdrawing"] = nil
        XCTAssertEqual(StrokeConverter.drawing(fromPage: web).0.strokes.count, 3)
        // Punkt aus dem Web-Editor (Punkt + Punkt um 0,05 versetzt): dargestellt, unveraendert gespeichert
        let dot = webStroke("punkt", points: [50, 50, 50.05, 50.05])
        let (fromWeb, st) = StrokeConverter.drawing(fromPage: ["objects": [dot]])
        XCTAssertEqual(fromWeb.strokes.count, 1)
        XCTAssertEqual(StrokeConverter.update(from: fromWeb, previous: ["objects": [dot]], state: st).page["objects"], ["objects": [dot]]["objects"])
        // vom Radierer bis auf ein kurzes Stueck abgeschnitten: das Stueck bleibt
        var cut = d
        cut.strokes[2].mask = UIBezierPath(rect: CGRect(x: 99, y: 90, width: 1.5, height: 20))
        let cutPage = StrokeConverter.update(from: cut, previous: saved, state: StrokeConverter.drawing(fromPage: saved).1).page
        XCTAssertGreaterThanOrEqual(ids(cutPage).count, 3)
    }

    // MARK: 339 wiederholte Umrechnung

    /// Groesster Abstand (pt) eines erwarteten Eckpunkts zur gespeicherten Linie (Polygonzug der Punkte)
    private func cornerDistance(_ pts: [Double], corners: [Double]) -> Double {
        var worst = 0.0
        for c in stride(from: 0, to: corners.count - 1, by: 2) {
            let px = corners[c], py = corners[c + 1]
            var best = Double.infinity
            for i in stride(from: 0, to: max(0, pts.count - 3), by: 2) {
                let ax = pts[i], ay = pts[i + 1], bx = pts[i + 2], by = pts[i + 3]
                let dx = bx - ax, dy = by - ay
                let len2 = dx * dx + dy * dy
                let t = len2 == 0 ? 0 : max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / len2))
                let qx = ax + t * dx - px, qy = ay + t * dy - py
                best = min(best, (qx * qx + qy * qy).squareRoot())
            }
            worst = max(worst, best)
        }
        return worst
    }

    /// Ein Strich aus dem Browser (Ecken, wenige Punkte) wird auf dem iPad mehrmals verschoben, dazwischen jeweils im
    /// Browser geaendert: seine Punkte bleiben genau erhalten (nur verschoben), keine Glaettung von Runde zu Runde.
    func testRepeatedConversionKeepsTheShapeOfABrowserStroke() throws {
        let zigzag: [Double] = [10, 10, 30, 50, 50, 10, 70, 50, 90, 10]
        var page: JSONValue = ["objects": [webStroke("z", points: zigzag)]]
        var expected = zigzag
        for cycle in 0..<6 {
            let (d, state) = StrokeConverter.drawing(fromPage: page)
            var moved = d
            moved.strokes[0].transform = CGAffineTransform(translationX: 5, y: 2)
            page = StrokeConverter.update(from: moved, previous: page, state: state).page
            expected = expected.enumerated().map { $0.offset % 2 == 0 ? $0.element + 5 : $0.element + 2 }
            let got = page["objects"]?.array?.first?["points"]?.array?.compactMap { $0.double } ?? []
            let corner = cornerDistance(got, corners: expected)
            print("Runde \(cycle): \(got.count / 2) Punkte, Ecken bis \(String(format: "%.2f", corner)) pt von der Linie")
            XCTAssertLessThan(corner, 0.05, "Runde \(cycle): Ecken abgerundet um \(corner) pt")
            XCTAssertEqual(got.count, expected.count, "Runde \(cycle): \(got.count) Punkte statt \(expected.count)")
            var deviation = got.isEmpty ? Double.infinity : 0
            for (a, b) in zip(got, expected) { deviation = max(deviation, abs(a - b)) }
            XCTAssertLessThan(deviation, 0.02, "Runde \(cycle): Abweichung \(deviation) pt")
            page["pkdrawing"] = nil                                           // Browser hat die Seite geaendert
        }
    }

    /// Vom Stift geschriebene Striche: mehrfach verschieben (mit und ohne native Zeichnung) veraendert die Form nicht
    func testRepeatedMovesOfAPencilStrokeKeepItsShape() throws {
        var d = PKDrawing()
        d.strokes.append(pencilStroke(y: 120))
        var page = StrokeConverter.update(from: d, previous: ["objects": []], state: InkPageState()).page
        let first = page["objects"]?.array?.first?["points"]?.array?.compactMap { $0.double } ?? []
        var offset = 0.0
        for cycle in 0..<5 {
            let (re, state) = StrokeConverter.drawing(fromPage: page)
            var moved = re
            moved.strokes[0].transform = moved.strokes[0].transform.translatedBy(x: 4, y: 0)
            page = StrokeConverter.update(from: moved, previous: page, state: state).page
            offset += 4
            let got = page["objects"]?.array?.first?["points"]?.array?.compactMap { $0.double } ?? []
            XCTAssertEqual(got.count, first.count, "Runde \(cycle)")
            var deviation = 0.0
            for (i, pair) in zip(got, first).enumerated() {
                let shift: Double = i % 2 == 0 ? offset : 0
                deviation = max(deviation, abs(pair.0 - (pair.1 + shift)))
            }
            XCTAssertLessThan(deviation, 0.02, "Runde \(cycle): Abweichung \(deviation)")
            if cycle % 2 == 1 { page["pkdrawing"] = nil }
        }
    }

    // MARK: 340 Belastung

    func testStrokesWithManyPointsOrUnusualCoordinatesStayFastAndSafe() throws {
        // 20 000 Punkte aus dem Browser: aufbauen, verschieben, speichern
        var long: [Double] = []
        for i in 0..<20_000 { long.append(10 + Double(i % 500)); long.append(10 + Double(i / 500) * 3) }
        let page: JSONValue = ["objects": [webStroke("lang", points: long)]]
        let t0 = Date()
        let (d, state) = StrokeConverter.drawing(fromPage: page)
        var moved = d
        moved.strokes[0].transform = CGAffineTransform(translationX: 1, y: 1)
        let out = StrokeConverter.update(from: moved, previous: page, state: state).page
        let seconds = Date().timeIntervalSince(t0)
        print("20 000 Punkte: aufbauen und umrechnen \(String(format: "%.2f", seconds)) s")
        XCTAssertLessThan(seconds, 10)
        XCTAssertEqual(out["objects"]?.array?.first?["points"]?.array?.count, 40_000)
        // ungewoehnliche, aber darstellbare Koordinaten: negativ, weit ausserhalb der Seite, Nachkommastellen
        let odd = webStroke("odd", points: [-500, -20.125, 3000.5, 9000, -0.0, 0.001])
        let (oddDrawing, oddState) = StrokeConverter.drawing(fromPage: ["objects": [odd]])
        XCTAssertEqual(oddDrawing.strokes.count, 1)
        XCTAssertEqual(StrokeConverter.update(from: oddDrawing, previous: ["objects": [odd]], state: oddState).page["objects"], ["objects": [odd]]["objects"])
        // riesige Werte und Massstaebe: nicht gezeichnet (kein Haengen), unveraendert behalten
        var huge = webStroke("skala", points: [1, 1, 2, 2])
        huge["scaleX"] = 1e12
        let monster: [JSONValue] = [webStroke("weit", points: [1e300, 0, 0, 1e300]), huge]
        let (none, noneState) = StrokeConverter.drawing(fromPage: ["objects": .array(monster)])
        XCTAssertEqual(none.strokes.count, 0)
        XCTAssertEqual(noneState.unrenderable, 2)
        XCTAssertEqual(StrokeConverter.update(from: none, previous: ["objects": .array(monster)], state: noneState).page["objects"]?.array,
                       monster)
    }
}
