import CryptoKit
import PencilKit
import UIKit

/// Umrechnung zwischen PencilKit und dem gemeinsamen UniFlow-Strichformat.
///
/// Plattformuebergreifend editierbar: Punkte, Farbe, Breite je Punkt, Deckkraft, Werkzeugart.
/// Nur visuell erhalten (gehen bei Bearbeitung im Browser verloren): PencilKit-eigene Pinselstruktur, Neigung,
/// Druckverlauf zwischen den Stuetzpunkten. Deshalb wird die native Zeichnung zusaetzlich als `pkdrawing` gespeichert.
enum StrokeConverter {

    // MARK: UniFlow-Objekte -> PencilKit

    static func drawing(from objects: [JSONValue]) -> PKDrawing {
        var strokes: [PKStroke] = []
        for o in objects {
            guard o["type"]?.string == "stroke", let raw = o["points"]?.array else { continue }
            let pts = raw.compactMap { $0.double }
            guard pts.count >= 4 else { continue }
            let tool = o["tool"]?.string ?? "pen"
            let width = o["width"]?.double ?? 2.2
            let widths = o["widths"]?.array?.compactMap { $0.double }
            let opacity = o["opacity"]?.double ?? 1
            let x = o["x"]?.double ?? 0, y = o["y"]?.double ?? 0
            let rot = (o["rotation"]?.double ?? 0) * .pi / 180
            let sx = o["scaleX"]?.double ?? 1, sy = o["scaleY"]?.double ?? 1
            // Konva-Reihenfolge: skalieren, drehen, verschieben
            let t = CGAffineTransform(translationX: x, y: y).rotated(by: rot).scaledBy(x: sx, y: sy)
            let n = pts.count / 2
            var points: [PKStrokePoint] = []
            points.reserveCapacity(n)
            for i in 0..<n {
                let p = CGPoint(x: pts[2 * i], y: pts[2 * i + 1]).applying(t)
                let w = CGFloat((widths?.count == n ? widths![i] : width) * max(abs(sx), abs(sy)))
                points.append(PKStrokePoint(location: p, timeOffset: TimeInterval(i) * 0.008, size: CGSize(width: w, height: w),
                                            opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2))
            }
            let ink: PKInk
            switch tool {
            case "marker": ink = PKInk(.marker, color: UIColor(hex: o["color"]?.string) ?? .systemYellow)
            case "pencil": ink = PKInk(.pencil, color: (UIColor(hex: o["color"]?.string) ?? .label).withAlphaComponent(CGFloat(opacity)))
            case "fountain": ink = PKInk(.fountainPen, color: (UIColor(hex: o["color"]?.string) ?? .label).withAlphaComponent(CGFloat(opacity)))
            default: ink = PKInk(.pen, color: (UIColor(hex: o["color"]?.string) ?? .label).withAlphaComponent(CGFloat(opacity)))
            }
            strokes.append(PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: Date())))
        }
        return PKDrawing(strokes: strokes)
    }

    // MARK: PencilKit -> UniFlow-Objekte

    static func objects(from drawing: PKDrawing) -> [JSONValue] {
        drawing.strokes.compactMap { stroke -> JSONValue? in
            var pts: [JSONValue] = []
            var widths: [Double] = []
            for p in stroke.path.interpolatedPoints(by: .distance(1.5)) {
                let loc = p.location.applying(stroke.transform)
                pts.append(.number(round2(loc.x)))
                pts.append(.number(round2(loc.y)))
                widths.append(round2(p.size.width))
            }
            guard pts.count >= 4 else { return nil }
            let tool: String
            switch stroke.ink.inkType {
            case .marker: tool = "marker"
            case .pencil: tool = "pencil"
            case .fountainPen: tool = "fountain"
            default: tool = "pen"
            }
            var a: CGFloat = 1
            stroke.ink.color.getRed(nil, green: nil, blue: nil, alpha: &a)
            let avg = widths.reduce(0, +) / Double(max(1, widths.count))
            var o: [String: JSONValue] = [
                "id": .string("pk" + String(UUID().uuidString.prefix(12)).lowercased()),
                "type": .string("stroke"), "tool": .string(tool),
                "color": .string(stroke.ink.color.hexString),
                "width": .number(round2(avg)),
                "opacity": .number(tool == "marker" ? 0.35 : round2(Double(a))),
                "points": .array(pts),
                "x": .number(0), "y": .number(0), "rotation": .number(0), "scaleX": .number(1), "scaleY": .number(1),
                "source": .string("pencilkit"),
            ]
            if tool != "marker" { o["widths"] = .array(widths.map { .number($0) }) }
            return .object(o)
        }
    }

    /// Stabile Signatur der Objekte einer Seite (Schluessel sortiert), um Browser-Aenderungen zu erkennen.
    static func signature(_ objects: [JSONValue]) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = (try? enc.encode(JSONValue.array(objects))) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func round2(_ v: CGFloat) -> Double { (Double(v) * 100).rounded() / 100 }
    private static func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
}

extension UIColor {
    convenience init?(hex: String?) {
        guard var s = hex?.trimmingCharacters(in: .whitespaces), s.hasPrefix("#") else { return nil }
        s.removeFirst()
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02x%02x%02x", Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255)))
    }
}
