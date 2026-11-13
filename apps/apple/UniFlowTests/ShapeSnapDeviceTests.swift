import PencilKit
import UniFlowCore
import UIKit
import XCTest
@testable import UniFlow

/// Formerkennung mit Strichdaten, wie sie vom iPad kommen (Fehler des Inhabers 13.11.2026: "Formen erkennen tut am
/// iPad gar nichts", im Simulator ging es). Die bisherigen Tests rechneten die Punkte genau aus; am Gerät kommt
/// etwas anderes an:
///
/// - die Hand zittert und wandert, die Kanten bekommen einen Bauch, die Geschwindigkeit wechselt,
/// - der Stift misst 240-mal je Sekunde, am Ende steht er still (zittert aber weiter und wandert ein paar Punkte),
/// - PencilKit legt über diese Punkte eine B-Spline mit deutlich weniger Kontrollpunkten: **die Ecken kommen
///   abgerundet an**, über 10 bis 20 pt verteilt.
///
/// Genau daran scheiterte die alte Erkennung: Sie maß die Drehung über einen festen Hebel von 6 pt und fand in der
/// Rundung keine Ecke mehr - ein Rechteck wurde zum Dreieck oder zu nichts. `DeviceStroke` baut solche Striche
/// nach, damit das nicht wieder unbemerkt bleibt.
@MainActor
final class ShapeSnapDeviceTests: XCTestCase {

    // MARK: Formen, die erkannt werden müssen

    func testEveryShapeIsRecognizedFromDeviceLikeStrokes() throws {
        var report: [String] = []
        for c in DeviceStroke.cases where c.want != nil {
            var hits: [String: Int] = [:]
            for seed in UInt64(1)...12 {
                let stroke = DeviceStroke.stroke(c.vertices, closed: c.closed, seed: seed)
                let shape = ShapeRecognizer.recognize(DeviceStroke.points(of: stroke))
                hits[shape?.name ?? "—", default: 0] += 1
                if shape != nil { XCTAssertNotNil(ShapeRecognizer.replacement(for: stroke), "\(c.name): Strich zur Form") }
            }
            report.append("\(c.name): " + hits.map { "\($0.key)×\($0.value)" }.sorted().joined(separator: " "))
            XCTAssertEqual(hits[c.want ?? "", default: 0], 12, "\(c.name) muss \(c.want ?? "") werden, war: \(hits)")
        }
        print("[Formen] vom Gerät, je 12 Striche:\n  " + report.joined(separator: "\n  "))
    }

    /// Alles andere bleibt Handschrift: Bogen, Welle, Zickzack, Fünfeck, ein Wort, ein Haken
    func testHandwritingAndOtherStrokesStayAsTheyAre() {
        for c in DeviceStroke.cases where c.want == nil {
            for seed in UInt64(1)...12 {
                let stroke = DeviceStroke.stroke(c.vertices, closed: c.closed, seed: seed)
                XCTAssertNil(ShapeRecognizer.recognize(DeviceStroke.points(of: stroke)),
                             "\(c.name) (Zufall \(seed)) darf keine Form werden")
            }
        }
    }

    /// Die Ecken eines von Hand gezeichneten Rechtecks werden gefunden, obwohl PencilKit sie rundet; ein Kreis und
    /// die engen Enden einer flachen Ellipse haben weiter keine Ecken (sonst wäre jeder Bogen ein Vieleck).
    func testCornersSurvivePencilKitRoundingAndArcsHaveNone() {
        for seed in UInt64(1)...6 {
            let rect = DeviceStroke.points(of: DeviceStroke.stroke(DeviceStroke.rectangle(100, 100, 200, 120), closed: true, seed: seed))
            let pts = ShapeRecognizer.resample(ShapeRecognizer.trimHold(rect), step: 3)
            XCTAssertEqual(ShapeRecognizer.cornerIndices(pts, closed: true).count, 4, "vier Ecken (Zufall \(seed))")
            let circle = DeviceStroke.points(of: DeviceStroke.stroke(DeviceStroke.ellipse(200, 300, 70, 70), closed: true, seed: seed))
            let round = ShapeRecognizer.resample(ShapeRecognizer.trimHold(circle), step: 3)
            XCTAssertEqual(ShapeRecognizer.cornerIndices(round, closed: true).count, 0, "Kreis ohne Ecke (Zufall \(seed))")
        }
    }

    // MARK: Stillhalten am Ende

    /// Das Stillhalten wird während des Zeichnens aus den Zeitstempeln des Stifts gemessen
    /// (`RawStroke.heldDuration`), nicht erst aus dem fertigen Strich: Am Gerät fasst PencilKit die Ruhepunkte
    /// zusammen, und auf welche Uhr sich `creationDate` und `timeOffset` beziehen, sagt Apple nicht zu.
    func testHoldIsMeasuredWhileDrawingEvenWhenTheHandDrifts() throws {
        let corners = DeviceStroke.rectangle(100, 100, 200, 120)
        // gezeichnet, dann 0,6 s gehalten (die Hand wandert dabei gut 4 pt und zittert)
        let held = try XCTUnwrap(RawStroke.heldDuration(DeviceStroke.samples(corners, closed: true, seed: 3, hold: 0.6),
                                                        radius: ShapeRecognizer.holdRadius))
        XCTAssertGreaterThanOrEqual(held, 0.55, "0,6 s Stillstand gemessen")
        XCTAssertGreaterThanOrEqual(held, ShapeRecognizer.holdDuration)

        // ohne Halten: abgesetzt, sobald die Form fertig war
        let quick = try XCTUnwrap(RawStroke.heldDuration(DeviceStroke.samples(corners, closed: true, seed: 3, hold: 0),
                                                         radius: ShapeRecognizer.holdRadius))
        XCTAssertLessThan(quick, ShapeRecognizer.holdDuration, "ohne Halten keine Form")
        // kurz gezögert, aber nicht lange genug
        let short = try XCTUnwrap(RawStroke.heldDuration(DeviceStroke.samples(corners, closed: true, seed: 3, hold: 0.25),
                                                         radius: ShapeRecognizer.holdRadius))
        XCTAssertLessThan(short, ShapeRecognizer.holdDuration, "0,25 s ist zu kurz")
        // gar nichts gemessen (kein Stift, Mac): kein Wert, dann zählt der fertige Strich
        XCTAssertNil(RawStroke.heldDuration([], radius: ShapeRecognizer.holdRadius))
    }

    /// Der Halteradius muss das Wandern der Hand aushalten: mit den alten 6 pt wurde dieselbe Ruhephase zu kurz
    /// gemessen, sobald die Hand wanderte.
    func testHoldRadiusCopesWithADriftingHand() throws {
        var drifting = DeviceStroke.samples(DeviceStroke.rectangle(100, 100, 200, 120), closed: true, seed: 2, hold: 0.6)
        // die Hand wandert in der Ruhephase 8 pt (statt gut 4)
        let moving = drifting.count - Int(0.6 * 240)
        for k in moving..<drifting.count {
            let u = CGFloat(k - moving) / CGFloat(drifting.count - moving)
            drifting[k].location.x += 4 * u
        }
        let held = try XCTUnwrap(RawStroke.heldDuration(drifting, radius: ShapeRecognizer.holdRadius))
        XCTAssertGreaterThanOrEqual(held, ShapeRecognizer.holdDuration, "wandernde Hand gilt weiter als still")
    }

    // MARK: Werkzeuge

    /// Formen erkennt nur der Stift (auch Fineliner, Bleistift, Füller), nicht der Textmarker und nicht der Radierer
    func testOnlyPenToolsSnapShapes() {
        for type in [PKInkingTool.InkType.pen, .pencil, .monoline, .fountainPen] {
            XCTAssertTrue(ShapeRecognizer.snaps(PKInkingTool(type, color: .black, width: 3)), "\(type.rawValue) ist ein Stift")
        }
        XCTAssertFalse(ShapeRecognizer.snaps(PKInkingTool(.marker, color: .yellow, width: 20)), "Textmarker nicht")
        XCTAssertFalse(ShapeRecognizer.snaps(PKEraserTool(.bitmap)), "Radierer nicht")
        XCTAssertFalse(ShapeRecognizer.snaps(PKLassoTool()), "Lasso nicht")
    }
}

/// Strichdaten, wie sie vom iPad kommen: Zittern der Hand, Bauch in den Kanten, wechselnde Geschwindigkeit,
/// 240 Messpunkte je Sekunde, Ruhephase am Ende - und darüber die Glättung von PencilKit (weniger Kontrollpunkte,
/// gerundete Ecken).
enum DeviceStroke {

    struct Case {
        var name: String
        var vertices: [CGPoint]
        var closed: Bool
        /// Name der erwarteten Form, nil = muss Handschrift bleiben
        var want: String?
    }

    static func rectangle(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> [CGPoint] {
        [CGPoint(x: x, y: y), CGPoint(x: x + w, y: y), CGPoint(x: x + w, y: y + h), CGPoint(x: x, y: y + h)]
    }

    static func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ a: CGFloat, _ b: CGFloat) -> [CGPoint] {
        (0..<72).map { i in
            let t = CGFloat(i) / 72 * 2 * .pi
            return CGPoint(x: cx + a * cos(t), y: cy + b * sin(t))
        }
    }

    static let cases: [Case] = [
        Case(name: "Linie waagerecht", vertices: [CGPoint(x: 100, y: 300), CGPoint(x: 380, y: 303)], closed: false, want: "line"),
        Case(name: "Linie schräg", vertices: [CGPoint(x: 100, y: 500), CGPoint(x: 340, y: 380)], closed: false, want: "line"),
        Case(name: "Linie kurz", vertices: [CGPoint(x: 100, y: 100), CGPoint(x: 190, y: 104)], closed: false, want: "line"),
        Case(name: "Rechteck", vertices: rectangle(100, 100, 200, 120), closed: true, want: "rectangle"),
        Case(name: "Rechteck klein", vertices: rectangle(100, 100, 90, 55), closed: true, want: "rectangle"),
        Case(name: "Rechteck groß", vertices: rectangle(60, 80, 420, 260), closed: true, want: "rectangle"),
        Case(name: "Quadrat", vertices: rectangle(100, 100, 150, 146), closed: true, want: "square"),
        Case(name: "Dreieck", vertices: [CGPoint(x: 100, y: 300), CGPoint(x: 200, y: 120), CGPoint(x: 310, y: 300)], closed: true, want: "triangle"),
        Case(name: "Dreieck schief", vertices: [CGPoint(x: 90, y: 400), CGPoint(x: 300, y: 330), CGPoint(x: 180, y: 180)], closed: true, want: "triangle"),
        Case(name: "Kreis", vertices: ellipse(200, 300, 70, 70), closed: true, want: "circle"),
        Case(name: "Kreis klein", vertices: ellipse(200, 300, 28, 27), closed: true, want: "circle"),
        Case(name: "Ellipse", vertices: ellipse(200, 300, 100, 45), closed: true, want: "ellipse"),
        Case(name: "Ellipse flach", vertices: ellipse(200, 300, 140, 38), closed: true, want: "ellipse"),
        Case(name: "Pfeil", vertices: [CGPoint(x: 100, y: 300), CGPoint(x: 300, y: 300), CGPoint(x: 272, y: 284),
                                       CGPoint(x: 300, y: 300), CGPoint(x: 272, y: 316)], closed: false, want: "arrow"),
        Case(name: "Pfeil mit Haken", vertices: [CGPoint(x: 100, y: 400), CGPoint(x: 100, y: 200), CGPoint(x: 122, y: 226)],
             closed: false, want: "arrow"),
        Case(name: "Bogen", vertices: (0...40).map { i in
            let t = CGFloat(i) / 40 * .pi
            return CGPoint(x: 200 + 100 * cos(t), y: 300 - 100 * sin(t))
        }, closed: false, want: nil),
        Case(name: "Welle", vertices: (0...60).map { i in CGPoint(x: 100 + CGFloat(i) * 4, y: 300 + sin(CGFloat(i) / 6) * 30) },
             closed: false, want: nil),
        Case(name: "Zickzack", vertices: [CGPoint(x: 100, y: 100), CGPoint(x: 140, y: 160), CGPoint(x: 180, y: 100),
                                          CGPoint(x: 220, y: 160), CGPoint(x: 260, y: 100), CGPoint(x: 300, y: 160)],
             closed: false, want: nil),
        Case(name: "Fünfeck", vertices: (0..<5).map { i in
            let t = CGFloat(i) / 5 * 2 * .pi
            return CGPoint(x: 200 + 80 * cos(t), y: 300 + 80 * sin(t))
        }, closed: true, want: nil),
        Case(name: "Haken", vertices: [CGPoint(x: 100, y: 300), CGPoint(x: 130, y: 340), CGPoint(x: 200, y: 240)], closed: false, want: nil),
        Case(name: "Handschrift", vertices: (0..<4).flatMap { k -> [CGPoint] in
            let x = 100 + CGFloat(k) * 26
            return [CGPoint(x: x, y: 300), CGPoint(x: x + 4, y: 264), CGPoint(x: x + 12, y: 300),
                    CGPoint(x: x + 20, y: 280), CGPoint(x: x + 26, y: 300)]
        }, closed: false, want: nil),
    ]

    /// Messpunkte einer Berührung: entlang `vertices`, mit Zittern und Ruhephase; der letzte Punkt liegt bei
    /// `endingAt` auf der Uhr von `UITouch.timestamp`.
    static func samples(_ vertices: [CGPoint], closed: Bool, seed: UInt64, hold: TimeInterval = 0.6,
                        endingAt end: TimeInterval = 1000) -> [RawPencilSample] {
        var rng = SplitMix64(seed: seed &* 7919 &+ 13)
        func noise(_ amount: CGFloat) -> CGFloat { CGFloat(Int(rng.next() % 2001) - 1000) / 1000 * amount }
        var vs = vertices
        if closed, let first = vertices.first { vs.append(first) }
        // ideale Bahn in 1-pt-Schritten, jede Kante mit etwas Bauch (von Hand gezeichnet ist nichts gerade)
        var path: [CGPoint] = []
        for i in 0..<(vs.count - 1) {
            let a = vs[i], b = vs[i + 1]
            let len = hypot(b.x - a.x, b.y - a.y)
            if len < 0.001 { continue }
            let nx = -(b.y - a.y) / len, ny = (b.x - a.x) / len
            let sag = 0.012 * len * noise(1)
            let n = max(2, Int(len))
            for k in 0..<n {
                let u = CGFloat(k) / CGFloat(n)
                let s = sin(u * .pi) * sag
                path.append(CGPoint(x: a.x + (b.x - a.x) * u + nx * s, y: a.y + (b.y - a.y) * u + ny * s))
            }
        }
        path.append(vs[vs.count - 1])
        // mit wechselnder Geschwindigkeit abfahren, 240 Messpunkte je Sekunde, dabei zittern
        var out: [RawPencilSample] = []
        var distance = 0.0
        var i = 0
        let phase = Double(rng.next() % 600) / 100, phase2 = Double(rng.next() % 600) / 100
        while i < path.count {
            let tremorX = 1.1 * sin(Double(out.count) / 9 + phase) + Double(noise(0.35))
            let tremorY = 0.9 * cos(Double(out.count) / 13 + phase2) + Double(noise(0.35))
            out.append(RawPencilSample(location: CGPoint(x: path[i].x + CGFloat(tremorX), y: path[i].y + CGFloat(tremorY)), time: 0))
            distance += 420 * (1 + 0.45 * sin(Double(out.count) / 37 + phase)) / 240
            i = Int(distance)
        }
        // Ruhephase: der Stift steht, die Hand wandert dabei ein paar Punkte weit
        if hold > 0, let last = out.last {
            for k in 0..<Int(hold * 240) {
                let u = CGFloat(k) / CGFloat(max(1, Int(hold * 240)))
                out.append(RawPencilSample(location: CGPoint(x: last.location.x + 4 * u + noise(0.4),
                                                             y: last.location.y + 1.6 * u + noise(0.4)), time: 0))
            }
        }
        // Zeitstempel: 240 je Sekunde, der letzte liegt bei `end`
        let start = end - Double(out.count - 1) / 240
        for k in out.indices { out[k].time = start + Double(k) / 240 }
        return out
    }

    /// Daraus der Strich, den PencilKit abliefert: deutlich weniger Kontrollpunkte (jeder sechste Messpunkt), die
    /// Kurve läuft als B-Spline darüber - die Ecken kommen gerundet an.
    static func stroke(_ vertices: [CGPoint], closed: Bool, seed: UInt64, hold: TimeInterval = 0.6,
                       ink: PKInk = PKInk(.pen, color: .black),
                       created: Date = Date(timeIntervalSinceReferenceDate: 800_000_000)) -> PKStroke {
        let raw = samples(vertices, closed: closed, seed: seed, hold: hold)
        let t0 = raw[0].time
        var control: [PKStrokePoint] = []
        var i = 0
        while i < raw.count {
            let s = raw[i]
            let force = 0.35 + CGFloat(i % 7) * 0.08
            control.append(PKStrokePoint(location: s.location, timeOffset: s.time - t0,
                                         size: CGSize(width: 2 + force, height: 2 + force), opacity: 1, force: force,
                                         azimuth: 0.6, altitude: 1.1))
            i += 6
        }
        if let last = raw.last, control.last?.location != last.location {
            control.append(PKStrokePoint(location: last.location, timeOffset: last.time - t0, size: CGSize(width: 2.5, height: 2.5),
                                         opacity: 1, force: 0.4, azimuth: 0.6, altitude: 1.1))
        }
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: control, creationDate: created))
    }

    /// Punkte des Strichs so, wie die Erkennung sie sieht
    static func points(of stroke: PKStroke) -> [CGPoint] {
        stroke.path.interpolatedPoints(by: .distance(2)).map { $0.location.applying(stroke.transform) }
    }
}
