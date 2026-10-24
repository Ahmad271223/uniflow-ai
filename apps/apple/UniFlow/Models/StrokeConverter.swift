import CryptoKit
import PencilKit
import UIKit
import UniFlowCore

/// Umrechnung zwischen PencilKit und dem gemeinsamen UniFlow-Strichformat mit stabilen Objekt-IDs.
///
/// Plattformuebergreifend bearbeitbar: Punkte, Farbe, Breite je Punkt, Deckkraft, Werkzeugart. Nur auf dem iPad
/// sichtbar (gehen bei Bearbeitung im Browser verloren): PencilKit-eigene Pinselstruktur und Neigung. Deshalb wird
/// die native Zeichnung zusaetzlich als `pkdrawing` gespeichert, zusammen mit den Objekt-IDs je Strich.
///
/// Identitaet eines PencilKit-Strichs: Erstellzeit des Pfads + Punktzahl + Tintenart. Verschieben (Lasso) aendert nur
/// `transform`, Radieren mit dem Pixel-Radierer nur `mask` -> die ID bleibt, das Objekt wird aktualisiert.
/// Unveraenderte Striche werden nie neu umgerechnet; ihr JSON bleibt Byte fuer Byte erhalten.
struct InkPageState: Sendable {
    struct StrokeKey: Hashable, Sendable {
        let created: Double
        let count: Int
        let ink: String
    }

    struct Entry: Sendable {
        var ids: [String]
        var content: Int
        var objects: [JSONValue]
    }

    var entries: [StrokeKey: [Entry]] = [:]
    /// IDs, die in der Zeichnung dargestellt sind. Andere Strich-Objekte der Seite (z. B. nicht darstellbar)
    /// werden beim Speichern unveraendert uebernommen.
    var represented: Set<String> = []
}

/// PencilKit-Zeichnung, die zwischen Threads weitergereicht wird (PKDrawing ist ein Werttyp).
struct DrawingBox: @unchecked Sendable {
    let drawing: PKDrawing
}

enum StrokeConverter {

    // MARK: Seite -> PencilKit

    /// Zeichnung einer Seite: bevorzugt die gespeicherte native Zeichnung, wenn sie noch zu den Objekten passt
    /// (sonst wurde die Seite im Browser bearbeitet und die Zeichnung wird aus den Objekten aufgebaut).
    static func drawing(fromPage page: JSONValue?) -> (PKDrawing, InkPageState) {
        let objects = page?["objects"]?.array ?? []
        if let stored = StoredDrawing(page: page), stored.signature == signature(objects),
           let data = Data(base64Encoded: stored.data), let native = try? PKDrawing(data: data),
           native.strokes.count == stored.strokeIDs.count {
            var byID: [String: JSONValue] = [:]
            for o in objects { if let id = o["id"]?.string { byID[id] = o } }
            var state = InkPageState()
            var complete = true
            for (i, s) in native.strokes.enumerated() {
                let ids = stored.strokeIDs[i]
                let objs = ids.compactMap { byID[$0] }
                if objs.count != ids.count { complete = false; break }
                state.entries[key(s), default: []].append(.init(ids: ids, content: contentHash(s), objects: objs))
                state.represented.formUnion(ids)
            }
            if complete { return (native, state) }
        }
        return rebuild(objects: objects)
    }

    /// Zeichnung aus den Objekten aufbauen. Jeder Strich bekommt eine eindeutige kuenstliche Erstellzeit, damit
    /// er spaeter eindeutig wiedererkannt wird.
    static func rebuild(objects: [JSONValue]) -> (PKDrawing, InkPageState) {
        var strokes: [PKStroke] = []
        var state = InkPageState()
        for o in objects {
            guard let id = o["id"]?.string else { continue }
            let created = Date(timeIntervalSinceReferenceDate: 1_000 + Double(strokes.count) * 0.001)
            guard let s = stroke(from: o, created: created) else { continue }
            strokes.append(s)
            state.entries[key(s), default: []].append(.init(ids: [id], content: contentHash(s), objects: [o]))
            state.represented.insert(id)
        }
        return (PKDrawing(strokes: strokes), state)
    }

    static func stroke(from o: JSONValue, created: Date) -> PKStroke? {
        guard o["type"]?.string == "stroke", let raw = o["points"]?.array else { return nil }
        let pts = raw.compactMap { $0.double }
        guard pts.count >= 4, pts.count % 2 == 0 else { return nil }
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
        let scale = max(abs(sx), abs(sy))
        var points: [PKStrokePoint] = []
        points.reserveCapacity(n)
        for i in 0..<n {
            let p = CGPoint(x: pts[2 * i], y: pts[2 * i + 1]).applying(t)
            let w = CGFloat(((widths?.count == n) ? widths![i] : width) * scale)
            points.append(PKStrokePoint(location: p, timeOffset: TimeInterval(i) * 0.008, size: CGSize(width: w, height: w),
                                        opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2))
        }
        let base = UIColor(hex: o["color"]?.string) ?? .black
        let ink: PKInk
        switch tool {
        case "marker": ink = PKInk(.marker, color: base)
        case "pencil": ink = PKInk(.pencil, color: base.withAlphaComponent(CGFloat(opacity)))
        default: ink = PKInk(.pen, color: base.withAlphaComponent(CGFloat(opacity)))
        }
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: created))
    }

    // MARK: PencilKit -> Seite

    /// Neuer Seitenstand aus der Zeichnung. Text, Formen, Bilder und nicht dargestellte Striche bleiben an ihrer
    /// Stelle; unveraenderte Striche behalten ihr JSON; neue Striche bekommen neue IDs.
    static func page(from drawing: PKDrawing, previous: JSONValue?, state: InkPageState) -> (JSONValue, InkPageState) {
        var pool = state.entries
        var next = InkPageState()
        var strokeIDs: [[String]] = []
        var current: [JSONValue] = []
        for s in drawing.strokes {
            let k = key(s)
            let content = contentHash(s)
            var entry: InkPageState.Entry
            if var list = pool[k], !list.isEmpty {
                let old = list.removeFirst()
                pool[k] = list
                if old.content == content {
                    entry = old
                } else {
                    let objs = objects(for: s, ids: old.ids)
                    entry = .init(ids: objs.compactMap { $0["id"]?.string }, content: content, objects: objs)
                }
            } else {
                let objs = objects(for: s, ids: [])
                entry = .init(ids: objs.compactMap { $0["id"]?.string }, content: content, objects: objs)
            }
            next.entries[k, default: []].append(entry)
            next.represented.formUnion(entry.ids)
            strokeIDs.append(entry.ids)
            current.append(contentsOf: entry.objects)
        }
        var byID: [String: JSONValue] = [:]
        for o in current { if let id = o["id"]?.string { byID[id] = o } }

        var result: [JSONValue] = []
        var placed = Set<String>()
        for o in previous?["objects"]?.array ?? [] {
            let id = o["id"]?.string ?? ""
            if o["type"]?.string == "stroke", !id.isEmpty, state.represented.contains(id) {
                if let updated = byID[id] { result.append(updated); placed.insert(id) }   // sonst: radiert
            } else {
                result.append(o)                                                       // Text, Formen, Bilder ...
            }
        }
        for o in current {
            if let id = o["id"]?.string, placed.insert(id).inserted { result.append(o) }
        }

        var p = previous?.object ?? [:]
        p["objects"] = .array(result)
        p["pkdrawing"] = StoredDrawing(data: drawing.dataRepresentation().base64EncodedString(),
                                       signature: signature(result), strokeIDs: strokeIDs).json
        return (.object(p), next)
    }

    /// Ein PencilKit-Strich als UniFlow-Objekt(e). Mit Pixel-Radierer geteilte Striche ergeben je sichtbarem Stueck
    /// ein Objekt, damit im Browser keine radierten Teile wieder auftauchen.
    static func objects(for s: PKStroke, ids: [String]) -> [JSONValue] {
        let ranges: [ClosedRange<CGFloat>]
        if s.mask != nil {
            ranges = s.maskedPathRanges
        } else {
            ranges = [0...CGFloat(max(s.path.count - 1, 0))]
        }
        let tool: String
        switch s.ink.inkType {
        case .marker: tool = "marker"
        case .pencil: tool = "pencil"
        default: tool = "pen"
        }
        let t = s.transform
        let scale = sqrt(abs(t.a * t.d - t.b * t.c))
        let (hex, alpha) = s.ink.color.uniflowRGBA
        var out: [JSONValue] = []
        for (i, range) in ranges.enumerated() {
            var pts: [JSONValue] = []
            var widths: [Double] = []
            for p in s.path.interpolatedPoints(in: range, by: .distance(1.5)) {
                let loc = p.location.applying(t)
                pts.append(.number(round2(Double(loc.x))))
                pts.append(.number(round2(Double(loc.y))))
                widths.append(round2(Double(p.size.width * scale)))
            }
            guard pts.count >= 4 else { continue }
            let id = i < ids.count ? ids[i] : newID()
            let avg = widths.reduce(0, +) / Double(max(1, widths.count))
            var o: [String: JSONValue] = [
                "id": .string(id), "type": "stroke", "tool": .string(tool), "color": .string(hex),
                "width": .number(round2(avg)), "opacity": .number(tool == "marker" ? 0.35 : round2(alpha)),
                "points": .array(pts), "x": 0, "y": 0, "rotation": 0, "scaleX": 1, "scaleY": 1,
                "source": "pencilkit",
            ]
            if tool != "marker", (widths.max() ?? 0) - (widths.min() ?? 0) > 0.05 {
                o["widths"] = .array(widths.map { .number($0) })
            }
            out.append(.object(o))
        }
        return out
    }

    // MARK: Hilfen

    static func key(_ s: PKStroke) -> InkPageState.StrokeKey {
        .init(created: s.path.creationDate.timeIntervalSinceReferenceDate, count: s.path.count, ink: s.ink.inkType.rawValue)
    }

    /// Inhalt, der sich durch Lasso, Pixel-Radierer oder Farbaenderung aendert.
    static func contentHash(_ s: PKStroke) -> Int {
        var h = Hasher()
        let t = s.transform
        for v in [t.a, t.b, t.c, t.d, t.tx, t.ty] { h.combine(Double(v)) }
        if let m = s.mask {
            let b = m.bounds
            for v in [b.minX, b.minY, b.width, b.height] { h.combine(Double(v)) }
            h.combine(s.maskedPathRanges.count)
            for r in s.maskedPathRanges { h.combine(Double(r.lowerBound)); h.combine(Double(r.upperBound)) }
        }
        h.combine(s.ink.color.uniflowRGBA.hex)
        return h.finalize()
    }

    /// Stabile Signatur der Objekte einer Seite (Schluessel sortiert), um Browser-Aenderungen zu erkennen.
    static func signature(_ objects: [JSONValue]) -> String {
        let data = JSONValue.array(objects).serialized(sortedKeys: true)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func newID() -> String {
        "pk" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
    }

    static func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
}

extension UIColor {
    convenience init?(hex: String?) {
        guard var s = hex?.trimmingCharacters(in: .whitespaces), s.hasPrefix("#") else { return nil }
        s.removeFirst()
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    /// Farbe im hellen Erscheinungsbild (so speichert PencilKit Tinten) als `#rrggbb` plus Deckkraft.
    var uniflowRGBA: (hex: String, alpha: Double) {
        let c = resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        if !c.getRed(&r, green: &g, blue: &b, alpha: &a) {
            var white: CGFloat = 0
            if c.getWhite(&white, alpha: &a) { r = white; g = white; b = white }
        }
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return (String(format: "#%02x%02x%02x", byte(r), byte(g), byte(b)), Double(a))
    }
}
