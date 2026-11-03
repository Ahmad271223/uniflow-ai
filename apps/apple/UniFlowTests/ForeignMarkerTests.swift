import PencilKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Textmarker einer importierten Loesung: iPad-Strich -> JSON -> Paket v2 (`SolutionWire`) -> fremde Ebene
/// (`ForeignLayerView.drawing`) sieht aus wie beim Absender. Vorher bekam der Marker aus dem JSON Azimut 0: PencilKit
/// legte die Keilspitze laengs zum Strich, gemessen (Breite 15, Massstab 3) 7,8 statt 14,5 pt dick, Flaeche 55 %,
/// runde weiche Enden statt der schraegen Kante.
@MainActor
final class ForeignMarkerTests: XCTestCase {
    struct Profile {
        /// mittlere Dicke (pt, Alpha ueber der Haelfte des Kerns) und deckende Flaeche (Pixel)
        var thick: Double, pixels: Int
    }

    /// Alpha-Profil quer zu einem waagerechten Strich bei y = 60, Spalten x = 80 ... 320
    static func profile(_ d: PKDrawing, scale: CGFloat = 3) -> Profile {
        var img = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            img = d.image(from: CGRect(x: 0, y: 0, width: 400, height: 120), scale: scale)
        }
        guard let cg = img.cgImage else { return Profile(thick: 0, pixels: 0) }
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        func a(_ x: Int, _ y: Int) -> Double { Double(data[(y * w + x) * 4 + 3]) / 255 }
        var pixels = 0
        for y in 0..<h { for x in 0..<w where a(x, y) > 0.02 { pixels += 1 } }
        var thicks: [Double] = []
        for x in stride(from: Int(80 * scale), to: Int(320 * scale), by: 3) {
            let col = (0..<h).map { a(x, $0) }.filter { $0 > 0.02 }.sorted()
            guard !col.isEmpty else { continue }
            let core = col[col.count * 3 / 4]
            thicks.append(Double(col.filter { $0 > core * 0.5 }.count) / Double(scale))
        }
        return Profile(thick: thicks.reduce(0, +) / Double(max(1, thicks.count)), pixels: pixels)
    }

    /// Marker wie vom Apple Pencil: leicht wellig, Abstand und Druck wechseln, Stift schraeg gehalten
    static func pencilMarker() -> PKStroke {
        var pts: [PKStrokePoint] = []
        var x: CGFloat = 30, t: TimeInterval = 0, i = 0
        while x <= 370 {
            pts.append(PKStrokePoint(location: CGPoint(x: x, y: 60 + 6 * sin(x / 40)), timeOffset: t, size: CGSize(width: 15, height: 15),
                                     opacity: 1, force: 0.6 + 0.3 * sin(Double(i) / 7),
                                     azimuth: 0.7 + 0.1 * sin(Double(i) / 11), altitude: 0.9))
            x += 2 + 1.5 * CGFloat(abs(sin(Double(i) / 5)))
            t += 1.0 / 120
            i += 1
        }
        return PKStroke(ink: PKInk(.marker, color: .systemYellow), path: PKStrokePath(controlPoints: pts, creationDate: Date()))
    }

    func testImportedMarkerLooksLikeTheAuthorsMarker() throws {
        let native = Self.pencilMarker()
        let (page, _) = StrokeConverter.page(from: PKDrawing(strokes: [native]), previous: ["objects": []], state: InkPageState())
        let o = try XCTUnwrap(page["objects"]?.array?.first)
        let wire = try JSONValue.parse(try SolutionWire.encodeObject(o).serialized(sortedKeys: true))
        let foreign = try XCTUnwrap(ForeignLayerView.drawing([try SolutionWire.decodeObject(wire)]).strokes.first)
        XCTAssertEqual(foreign.ink.inkType, .marker)
        XCTAssertEqual(foreign.ink.color.uniflowRGBA.alpha, 1, accuracy: 0.01, "Deckkraft 0,35 = volle Markerfarbe")

        let a = Self.profile(PKDrawing(strokes: [native])), b = Self.profile(PKDrawing(strokes: [foreign]))
        XCTAssertEqual(b.thick, a.thick, accuracy: a.thick * 0.1, "Dicke: Absender \(a.thick) pt, Ebene \(b.thick) pt")
        XCTAssertEqual(Double(b.pixels), Double(a.pixels), accuracy: Double(a.pixels) * 0.1, "Flaeche \(a.pixels) / \(b.pixels)")
    }

    /// Marker aus dem JSON: waagerecht und senkrecht so dick wie gespeichert (wie im Browser und im PDF-Export)
    func testMarkerFromJSONIsAsThickAsItsWidthInBothDirections() {
        for vertical in [false, true] {
            let pts: [Double] = vertical ? [60, 30, 60, 370] : [30, 60, 370, 60]
            let o: JSONValue = .object(["type": "stroke", "id": "m", "tool": "marker", "color": "#ffd60a", "width": 15,
                                        "opacity": 0.35, "points": .array(pts.map { .number($0) })])
            var d = ForeignLayerView.drawing([o])
            // senkrecht: an der Diagonale spiegeln, damit das Profil quer misst
            if vertical { d = d.transformed(using: CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)) }
            let p = Self.profile(d)
            XCTAssertEqual(p.thick, 15, accuracy: 1.5, vertical ? "senkrecht" : "waagerecht")
        }
    }
}
