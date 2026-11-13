import PencilKit
import SwiftUI
import XCTest
@testable import UniFlow

/// Glaettung einstellbar und Formen erkennen (Wunsch des Inhabers 13.11.2026): reine Rechnung (`RawStroke`,
/// `ShapeRecognizer`) und die Einstellungen. Der Weg im Editor steht in `PencilFeelTests`.
/// Bild der Einstellungen mit `TEST_RUNNER_UF_STARTSEITE_DIR=<Ordner>`.
@MainActor
final class PencilSmoothingTests: XCTestCase {

    /// Zitternde Handschrift wie Rohpunkte des Pencil: 240 Punkte je Sekunde, kleine Unruhe
    private func wobbly(_ n: Int = 120) -> [RawPencilSample] {
        var rng = SplitMix64(seed: 42)
        return (0..<n).map { i in
            let t = CGFloat(i)
            let jitter = CGFloat(Int(rng.next() % 100) - 50) / 100 * 0.6           // ±0,3 pt
            return RawPencilSample(location: CGPoint(x: 100 + t * 1.5, y: 200 + sin(t / 9) * 20 + jitter), time: 1000 + Double(i) / 240)
        }
    }

    /// Strich wie von PencilKit: weniger Kontrollpunkte, glatter, mit Breite je Druck
    private func pencilKitStroke(for samples: [RawPencilSample]) -> PKStroke {
        let t0 = samples[0].time
        let pts = stride(from: 0, to: samples.count, by: 4).map { i -> PKStrokePoint in
            let s = samples[i]
            return PKStrokePoint(location: s.location, timeOffset: s.time - t0, size: CGSize(width: 2 + CGFloat(i) / 60, height: 2 + CGFloat(i) / 60),
                                 opacity: 0.9, force: 0.5 + CGFloat(i) / 240, azimuth: 0.7, altitude: 1.1)
        }
        return PKStroke(ink: PKInk(.pen, color: .systemBlue), path: PKStrokePath(controlPoints: pts, creationDate: Date(timeIntervalSince1970: 1_800_000_000)))
    }

    /// PencilKit wertet Kontrollpunkte als kubische B-Spline aus: an Stelle i (P[i-1] + 4 P[i] + P[i+1]) / 6, Enden
    /// genau auf dem ersten und letzten Punkt. Darauf baut "Aus" auf; aendert Apple das, schlaegt dieser Test an.
    func testPencilKitEvaluatesControlPointsAsUniformCubicBSpline() {
        let ctrl = [CGPoint(x: 0, y: 0), CGPoint(x: 60, y: 0), CGPoint(x: 120, y: 0), CGPoint(x: 180, y: 60), CGPoint(x: 240, y: 0), CGPoint(x: 300, y: 0)]
        let path = PKStrokePath(controlPoints: ctrl.enumerated().map {
            PKStrokePoint(location: $1, timeOffset: Double($0) * 0.01, size: CGSize(width: 2, height: 2), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }, creationDate: Date())
        XCTAssertEqual(path.interpolatedLocation(at: 0).x, 0, accuracy: 0.001)
        XCTAssertEqual(path.interpolatedLocation(at: 3).y, 40, accuracy: 0.001, "(0 + 4·60 + 0) / 6")
        XCTAssertEqual(path.interpolatedLocation(at: 2).y, 10, accuracy: 0.001, "(0 + 0 + 60) / 6")
        XCTAssertEqual(path.interpolatedLocation(at: 5).x, 300, accuracy: 0.001)
    }

    /// "Aus": die Kurve laeuft genau durch jeden gemessenen Punkt; "Leicht": nah daran; "Normal": unveraendert
    func testOffDrawsThroughEveryRawPointLightStaysCloseNormalKeepsPencilKit() throws {
        let samples = wobbly()
        let original = pencilKitStroke(for: samples)
        XCTAssertNil(RawStroke.rebuild(original, samples: samples, smoothing: .normal), "Normal: Strich von PencilKit bleibt")

        var report: [String] = []
        for level in [PencilSmoothing.light, .off] {
            let s = try XCTUnwrap(RawStroke.rebuild(original, samples: samples, smoothing: level))
            XCTAssertEqual(s.path.count, samples.count)
            let deviations = samples.indices.map { i -> CGFloat in
                let p = s.path.interpolatedLocation(at: CGFloat(i)).applying(s.transform)
                return hypot(p.x - samples[i].location.x, p.y - samples[i].location.y)
            }
            let maxDev = deviations.max() ?? 0
            let mean = deviations.reduce(0, +) / CGFloat(deviations.count)
            report.append(String(format: "%@: Abstand der Kurve zu den Messpunkten im Mittel %.3f pt, hoechstens %.3f pt",
                                 level == .off ? "Aus" : "Leicht", mean, maxDev))
            if level == .off {
                XCTAssertLessThan(maxDev, 0.01, "Aus: genau durch jeden Messpunkt")
            } else {
                XCTAssertLessThan(maxDev, 0.5, "Leicht: hoechstens ein halber Punkt daneben")
                XCTAssertGreaterThan(mean, 0.001, "Leicht glaettet etwas")
            }
            // Tinte, Farbe und Breite/Druck von PencilKit bleiben (zeitlich naechster Punkt)
            XCTAssertEqual(s.ink.inkType, .pen)
            XCTAssertEqual(s.ink.color, original.ink.color)
            XCTAssertEqual(s.path.creationDate, original.path.creationDate)
            XCTAssertEqual(s.path[0].size.width, original.path[0].size.width, accuracy: 0.001)
            XCTAssertEqual(s.path[s.path.count - 1].force, original.path[original.path.count - 1].force, accuracy: 0.02)
            XCTAssertEqual(s.path[10].azimuth, 0.7, accuracy: 0.001)
        }
        // zum Vergleich: der PencilKit-Strich (jeder 4. Punkt, B-Spline) neben denselben Messpunkten
        let pk = original.path
        let pkDev = samples.indices.map { i -> CGFloat in
            let p = pk.interpolatedLocation(at: CGFloat(i) / 4)
            return hypot(p.x - samples[i].location.x, p.y - samples[i].location.y)
        }
        report.append(String(format: "Vergleich, nachgebauter PencilKit-Strich: im Mittel %.3f pt, hoechstens %.3f pt",
                             pkDev.reduce(0, +) / CGFloat(pkDev.count), pkDev.max() ?? 0))
        print("[Stift] Glaettung, 120 Messpunkte mit ±0,3 pt Unruhe:\n  " + report.joined(separator: "\n  "))
    }

    func testRebuildHandlesStillPenTransformAndTooFewPoints() throws {
        let original = pencilKitStroke(for: wobbly(20))
        XCTAssertNil(RawStroke.rebuild(original, samples: [], smoothing: .off))
        let still = [RawPencilSample(location: CGPoint(x: 5, y: 5), time: 1), RawPencilSample(location: CGPoint(x: 5.01, y: 5), time: 2)]
        XCTAssertNil(RawStroke.rebuild(original, samples: still, smoothing: .off), "Stift stand nur: kein Strich daraus")
        // Stillstand mitten im Strich faellt weg, der Strich bleibt
        var samples = wobbly(40)
        samples.insert(contentsOf: Array(repeating: samples[20], count: 10), at: 20)
        XCTAssertEqual(RawStroke.thinned(samples).count, 40)
        // verschobener Strich (Transform): Rohpunkte in Zeichnungskoordinaten, gespeichert in Strichkoordinaten
        var moved = original
        moved.transform = CGAffineTransform(translationX: 30, y: -10)
        let raw = wobbly(20)
        let s = try XCTUnwrap(RawStroke.rebuild(moved, samples: raw, smoothing: .off))
        let p = s.path.interpolatedLocation(at: 5).applying(s.transform)
        XCTAssertEqual(p.x, raw[5].location.x, accuracy: 0.01)
        XCTAssertEqual(p.y, raw[5].location.y, accuracy: 0.01)
    }

    // MARK: Formen

    func testNearSquareBecomesSquareRectangleStaysRectangle() {
        func along(_ v: [CGPoint]) -> [CGPoint] {
            var out: [CGPoint] = []
            let closed = v + [v[0]]
            for i in 0..<(closed.count - 1) {
                let a = closed[i], b = closed[i + 1]
                let n = Int(hypot(b.x - a.x, b.y - a.y) / 2)
                for k in 0..<max(1, n) { out.append(CGPoint(x: a.x + (b.x - a.x) * CGFloat(k) / CGFloat(n), y: a.y + (b.y - a.y) * CGFloat(k) / CGFloat(n))) }
            }
            return out
        }
        let square = along([CGPoint(x: 100, y: 100), CGPoint(x: 196, y: 100), CGPoint(x: 196, y: 192), CGPoint(x: 100, y: 192)])
        guard case .rectangle(_, let s, _)? = ShapeRecognizer.recognize(square) else { return XCTFail("Quadrat") }
        XCTAssertEqual(s.width, s.height, "96 x 92: Quadrat")
        XCTAssertEqual(ShapeRecognizer.recognize(square)?.name, "square")
        let rect = along([CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100), CGPoint(x: 300, y: 180), CGPoint(x: 100, y: 180)])
        XCTAssertEqual(ShapeRecognizer.recognize(rect)?.name, "rectangle", "200 x 80 bleibt Rechteck")
        // Kreis, Ellipse, Dreieck, Linie weiter wie bisher
        let circle = (0..<120).map { i -> CGPoint in let t = CGFloat(i) / 120 * 2 * .pi; return CGPoint(x: 200 + 50 * cos(t), y: 200 + 51 * sin(t)) }
        XCTAssertEqual(ShapeRecognizer.recognize(circle)?.name, "circle")
        let tri = along([CGPoint(x: 100, y: 300), CGPoint(x: 200, y: 120), CGPoint(x: 300, y: 300)])
        XCTAssertEqual(ShapeRecognizer.recognize(tri)?.name, "triangle")
    }

    func testShapeSwitchDefaultsOnAndTurnsOff() {
        UserDefaults.standard.removeObject(forKey: ShapeSnapSetting.key)
        defer { UserDefaults.standard.removeObject(forKey: ShapeSnapSetting.key) }
        XCTAssertTrue(ShapeSnapSetting.enabled, "Standard: an")
        UserDefaults.standard.set(false, forKey: ShapeSnapSetting.key)
        XCTAssertFalse(ShapeSnapSetting.enabled)
        UserDefaults.standard.removeObject(forKey: PencilSmoothing.key)
        XCTAssertEqual(PencilSmoothing.current, .normal, "Standard: wie bisher")
        UserDefaults.standard.set("off", forKey: PencilSmoothing.key)
        XCTAssertEqual(PencilSmoothing.current, .off)
        UserDefaults.standard.removeObject(forKey: PencilSmoothing.key)
    }

    // MARK: Einstellungen

    /// Die zwei Zeilen in den Stift-Einstellungen: bedienbar, schreiben die Einstellung; Bild hell und dunkel
    func testSettingsRowsSwitchSmoothingAndShapes() throws {
        UserDefaults.standard.removeObject(forKey: PencilSmoothing.key)
        UserDefaults.standard.removeObject(forKey: ShapeSnapSetting.key)
        defer {
            UserDefaults.standard.removeObject(forKey: PencilSmoothing.key)
            UserDefaults.standard.removeObject(forKey: ShapeSnapSetting.key)
        }
        XCTAssertTrue(HostedEnvironment.accessibilityAutomation(true))
        defer { HostedEnvironment.accessibilityAutomation(false) }
        let view = UFContent { UFCard { PencilFeelSettingsRows() }.frame(maxWidth: 520) }
        let env = try hostWithEnvironment(view, size: CGSize(width: 600, height: 420))
        env.pump(0.8)
        let labels = env.labels()
        XCTAssertTrue(labels.contains { $0.contains(PencilSmoothing.title) }, labels.joined(separator: "\n"))
        XCTAssertTrue(labels.contains { $0.contains(ShapeSnapSetting.title) })
        for style in [UIUserInterfaceStyle.light, .dark] {
            env.window.overrideUserInterfaceStyle = style
            env.pump(0.5)
            shoot(env, "stift-einstellungen-\(style == .dark ? "dunkel" : "hell")")
        }
        let aus = try XCTUnwrap(LayoutWidthAuditTests.elements(in: env.window).first { $0.accessibilityLabel == "Aus" && $0.accessibilityTraits.contains(.button) },
                                "Knopf Aus:\n" + labels.joined(separator: "\n"))
        XCTAssertTrue(aus.accessibilityActivate())
        env.pump(0.3)
        XCTAssertEqual(PencilSmoothing.current, .off)
        let toggle = try XCTUnwrap(LockVisibilityAppTests.element("settings.shapeSnap", in: env.view))
        XCTAssertTrue(toggle.accessibilityActivate())
        env.pump(0.3)
        XCTAssertFalse(ShapeSnapSetting.enabled)
        env.window.isHidden = true
    }

    private func shoot(_ env: HostedEnvironment, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["UF_STARTSEITE_DIR"], !dir.isEmpty else { return }
        let window = env.window
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let data = UIGraphicsImageRenderer(bounds: window.bounds, format: format).pngData { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
    }
}
