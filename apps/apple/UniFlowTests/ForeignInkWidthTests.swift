import PencilKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Fremde Loesungs-Ebene: ein Strich erscheint beim Empfaenger B so breit wie auf der Canvas des Absenders A.
/// Vorher zeichnete B die Striche als CAShapeLayer mit der gespeicherten Punktgroesse; PencilKit zeichnet sie bei A
/// aber anders (gemessen im Simulator: Stift 3 pt -> 2 pt, Stift 8 pt -> 12 pt, Bleistift 4 pt -> 6,8 pt).
@MainActor
final class ForeignInkWidthTests: XCTestCase {
    private static let page = CGSize(width: 400, height: 300)
    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        windows.forEach { $0.isHidden = true }
        windows = []
    }

    /// Strich wie vom Apple Pencil auf der Canvas von A: waagerecht bei y, Punkte alle 1,5 pt
    private func native(_ ink: PKInk.InkType, size: CGFloat, y: CGFloat) -> PKStroke {
        let pts = stride(from: 40.0, through: 360.0, by: 1.5).enumerated().map { i, x in
            PKStrokePoint(location: CGPoint(x: x, y: y), timeOffset: TimeInterval(i) * 0.01, size: CGSize(width: size, height: size),
                          opacity: 1, force: 0.7, azimuth: 0, altitude: .pi / 3)
        }
        return PKStroke(ink: PKInk(ink, color: .black), path: PKStrokePath(controlPoints: pts, creationDate: Date()))
    }

    private func window(_ content: UIView) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let w = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(origin: .zero, size: Self.page))
        w.frame = CGRect(origin: .zero, size: Self.page)
        let root = UIViewController()
        root.view.backgroundColor = .white
        root.view.overrideUserInterfaceStyle = .light
        content.frame = CGRect(origin: .zero, size: Self.page)
        root.view.addSubview(content)
        w.rootViewController = root
        w.makeKeyAndVisible()
        windows.append(w)
        return w
    }

    private func snapshot(_ window: UIWindow) async throws -> UIImage {
        try await Task.sleep(nanoseconds: 800_000_000)                 // PencilKit zeichnet seine Kacheln nach
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    /// Mittlere Dicke (Punkte) der dunklen Linie im Band y-20 ... y+20, gemessen in Spalten zwischen x = 100 und 300
    private func thickness(_ image: UIImage, y: CGFloat) -> CGFloat {
        guard let cg = image.cgImage else { return -1 }
        let w = cg.width, h = cg.height, s = image.scale
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let columns = stride(from: Int(100 * s), to: Int(300 * s), by: 5).map { $0 }
        let rows = max(0, Int((y - 20) * s))..<min(h, Int((y + 20) * s))
        var sum: CGFloat = 0
        for x in columns {
            for row in rows {
                let i = (row * w + x) * 4
                sum += 1 - CGFloat(Int(data[i]) + Int(data[i + 1]) + Int(data[i + 2])) / (3 * 255)    // Deckung schwarz
            }
        }
        return sum / CGFloat(columns.count) / s
    }

    func testForeignStrokeIsAsWideAsOnTheAuthorsCanvas() async throws {
        let cases: [(PKInk.InkType, CGFloat)] = [(.pen, 3), (.pen, 8), (.pencil, 4), (.fountainPen, 6), (.monoline, 5)]
        let rows = cases.indices.map { CGFloat(30 + 60 * $0) }
        let strokes = zip(cases, rows).map { c, y in native(c.0, size: c.1, y: y) }

        // A: eigene Canvas eines Seiten-Overlays mit den Strichen
        let geometry = PageGeometry(pageSize: Self.page)
        let a = PageInkView(pageIndex: 0, pageKey: "p1", geometry: geometry)
        a.canvas.drawing = PKDrawing(strokes: strokes)
        let shotA = try await snapshot(window(a))

        // B: dieselben Striche als Objekte (wie gespeichert und geteilt) in der fremden Schicht
        let objects = strokes.enumerated().flatMap { i, s in StrokeConverter.objects(for: s, ids: ["s\(i)"]) }
        XCTAssertEqual(objects.count, strokes.count)
        let page = SolutionPage(key: "p1", kind: .pdf, pdfIndex: 1, width: Double(Self.page.width), height: Double(Self.page.height),
                                rotation: 0, objects: objects)
        let foreign = ForeignLayerView(solutionID: "l1", page: page, images: [:], targetRotation: 0, label: "Lösung")
        XCTAssertEqual(foreign.strokeCount, strokes.count)
        let b = PageInkView(pageIndex: 0, pageKey: "p1", geometry: geometry)
        b.setForeign([foreign])
        let shotB = try await snapshot(window(b))

        for ((ink, size), y) in zip(cases, rows) {
            let wa = thickness(shotA, y: y), wb = thickness(shotB, y: y)
            XCTAssertGreaterThan(wa, 0.5, "\(ink.rawValue) \(size) pt bei A sichtbar")
            XCTAssertEqual(wb, wa, accuracy: max(0.25, wa * 0.08), "\(ink.rawValue) \(size) pt: B \(wb) pt, A \(wa) pt")
        }
    }

    /// Nur Anzeige; im Dunkelmodus bleibt schwarze Tinte schwarz (wie auf der eigenen Canvas)
    func testForeignInkIsReadOnlyAndLight() {
        let o: JSONValue = .object(["type": "stroke", "tool": "pen", "color": "#000000", "width": 3, "opacity": 1,
                                    "points": .array([10, 10, 50, 10].map { .number($0) })])
        let page = SolutionPage(key: "p1", kind: .pdf, pdfIndex: 1, width: 100, height: 100, rotation: 0, objects: [o])
        let view = ForeignLayerView(solutionID: "l1", page: page, images: [:], targetRotation: 0, label: "")
        XCTAssertEqual(view.ink.traitCollection.userInterfaceStyle, .light)
        XCTAssertFalse(view.ink.isUserInteractionEnabled)
        XCTAssertFalse(view.ink.drawingGestureRecognizer.isEnabled)
        XCTAssertEqual(view.strokeCount, 1)
    }
}
