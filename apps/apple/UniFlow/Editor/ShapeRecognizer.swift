import PencilKit
import UIKit

/// Formerkennung "zeichnen und halten" (Plan EDITOR-GOODNOTES-PLAN, Schritt H).
///
/// PencilKit kann das nicht selbst: In den oeffentlichen Headern (iOS 27.2 SDK: PKCanvasView.h, PKToolPicker.h,
/// PKStroke.h, PKStrokePath.h) gibt es weder eine Einstellung noch eine Rueckmeldung zum Einrasten von Formen; die
/// Notizen-App nutzt dafuer private Teile. Darum erkennt der Editor die Form selbst, nachdem der Strich fertig ist:
/// Blieb der Stift am Ende mindestens `holdDuration` still (`heldStill`), wird der Strich durch eine ideale Form
/// ersetzt (Linie, Rechteck bzw. Quadrat, Ellipse bzw. Kreis, Dreieck, Pfeil). Die Form ist wieder ein gewoehnlicher `PKStroke`
/// mit derselben Tinte, Farbe und Breite: Speicherformat, Web-Editor und `StrokeConverter` bleiben unveraendert. Der
/// Tausch ist ein Rueckgaengig-Schritt (`PDFEditorController.canvasViewDidEndUsingTool`).
enum ShapeRecognizer {
    /// So lange muss der Stift am Ende still stehen (Sekunden), wie bei GoodNotes
    static let holdDuration: TimeInterval = 0.5
    /// Bis zu diesem Abstand (Seitenpunkte) gilt der Stift als still. Eine ruhig gehaltene Hand wandert in einer
    /// halben Sekunde ein paar Punkte weit; 6 pt war am Geraet zu streng.
    static let holdRadius: CGFloat = 9
    /// So nah am Endpunkt gilt ein Punkt als beim Halten entstanden und zaehlt nicht mehr zur Form
    static let trimRadius: CGFloat = 6
    /// Kuerzere Striche sind kein Kandidat (Punkte, Haekchen)
    static let minimumLength: CGFloat = 30
    /// Rechteck mit Seiten, die hoechstens so viel (Anteil der laengeren) auseinanderliegen, wird ein Quadrat
    static let squareTolerance: CGFloat = 0.1

    enum Shape: Equatable {
        case line(from: CGPoint, to: CGPoint)
        /// Rechteck, `angle` in Bogenmass (0 = achsparallel)
        case rectangle(center: CGPoint, size: CGSize, angle: CGFloat)
        /// Ellipse in der umschliessenden Box; Kreis bei gleichen Achsen
        case ellipse(center: CGPoint, radii: CGSize)
        case triangle(CGPoint, CGPoint, CGPoint)
        /// Pfeil vom Schaftanfang zur Spitze
        case arrow(from: CGPoint, to: CGPoint)

        var name: String {
            switch self {
            case .line: return "line"
            case .rectangle(_, let size, _): return abs(size.width - size.height) <= 0.001 ? "square" : "rectangle"
            case .ellipse(_, let r): return abs(r.width - r.height) <= 0.001 ? "circle" : "ellipse"
            case .triangle: return "triangle"
            case .arrow: return "arrow"
            }
        }
    }

    // MARK: Halten am Ende

    /// Formen erkennt nur ein Stift-Werkzeug (Stift, Fineliner, Bleistift, Fueller) - nicht der Textmarker und
    /// nicht der Radierer, das Lasso oder das Lineal.
    static func snaps(_ tool: PKTool) -> Bool {
        guard let ink = tool as? PKInkingTool else { return false }
        switch ink.inkType {
        case .marker, .watercolor: return false
        default: return true
        }
    }

    /// Stand der Stift am Ende still? Zwei Wege, weil PencilKit beim stillen Stift nicht unbedingt weitere Punkte
    /// anlegt: die Dauer der Punkte im Umkreis `holdRadius` um den letzten Punkt, und die Zeit zwischen der letzten
    /// Bewegung (`creationDate` + letzter `timeOffset`) und dem Absetzen (`endedAt`).
    static func heldStill(_ path: PKStrokePath, endedAt: Date? = nil, minimum: TimeInterval = holdDuration) -> Bool {
        guard path.count > 0 else { return false }
        let last = path[path.count - 1]
        var firstStill = path.count - 1
        while firstStill > 0, hypot(path[firstStill - 1].location.x - last.location.x, path[firstStill - 1].location.y - last.location.y) <= holdRadius {
            firstStill -= 1
        }
        let tail = last.timeOffset - path[firstStill].timeOffset
        if tail >= minimum { return true }
        guard let endedAt else { return false }
        let lastMove = path.creationDate.addingTimeInterval(path[firstStill].timeOffset)
        return endedAt.timeIntervalSince(lastMove) >= minimum
    }

    // MARK: Erkennen

    /// Form zu einer Punktfolge (Seitenpunkte, in Zeichenreihenfolge); nil, wenn es keine der fuenf Formen ist
    static func recognize(_ raw: [CGPoint]) -> Shape? {
        let pts = resample(trimHold(raw), step: 3)
        guard pts.count >= 8 else { return nil }
        let length = pathLength(pts)
        let box = bounds(pts)
        guard length >= minimumLength, max(box.width, box.height) >= 12 else { return nil }
        let closed = hypot(pts[0].x - pts[pts.count - 1].x, pts[0].y - pts[pts.count - 1].y) <= max(12, 0.15 * length)
        let corners = cornerIndices(pts, closed: closed)
        if closed {
            // Die engen Enden einer flachen Ellipse sehen aus wie Ecken: passt das Vieleck nicht, bleibt die Ellipse
            if corners.count == 3, let t = triangle(pts, corners: corners) { return t }
            if corners.count == 4, let r = rectangle(pts, corners: corners) { return r }
            guard corners.count <= 4 else { return nil }
            return ellipse(pts)
        }
        if corners.isEmpty { return line(pts) }
        // kein Pfeil: eine Ecke kann auch ein Haken an einer sonst geraden Linie sein
        return arrow(pts, corners: corners, length: length) ?? line(pts)
    }

    /// Strich eines Werkzeugs pruefen und, wenn er eine Form ist, die ideale Form als Strich mit derselben Tinte
    static func replacement(for stroke: PKStroke) -> PKStroke? {
        guard stroke.mask == nil else { return nil }
        let points = stroke.path.interpolatedPoints(by: .distance(2)).map { $0.location.applying(stroke.transform) }
        guard let shape = recognize(points) else { return nil }
        return idealStroke(shape, like: stroke)
    }

    // MARK: Einzelne Formen

    private static func line(_ pts: [CGPoint]) -> Shape? {
        let a = pts[0], b = pts[pts.count - 1]
        let chord = hypot(b.x - a.x, b.y - a.y)
        guard chord >= minimumLength * 0.8 else { return nil }
        // alle Punkte nahe der Sehne (sonst ein Bogen oder Haken)
        let deviation = pts.map { distance($0, toLine: a, b) }.max() ?? 0
        guard deviation <= max(4, 0.08 * chord) else { return nil }
        return .line(from: a, to: snapAxis(from: a, to: b))
    }

    /// Waagerecht oder senkrecht einrasten (bis 5 Grad daneben)
    static func snapAxis(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let angle = abs(atan2(dy, dx)) * 180 / .pi
        if angle <= 5 || angle >= 175 { return CGPoint(x: b.x, y: a.y) }
        if abs(angle - 90) <= 5 { return CGPoint(x: a.x, y: b.y) }
        return b
    }

    /// Wie weit darf der Strich von der idealen Form abweichen (Zittern der Hand, Bauch der Kanten)
    static func fitTolerance(_ pts: [CGPoint]) -> CGFloat {
        let box = bounds(pts)
        return max(8, 0.07 * max(box.width, box.height))
    }

    private static func triangle(_ pts: [CGPoint], corners: [Int]) -> Shape? {
        let v = [pts[corners[0]], pts[corners[1]], pts[corners[2]]]
        // drei Ecken, die wirklich auseinanderliegen, und der Strich laeuft nahe an den drei Kanten
        for i in 0..<3 where hypot(v[(i + 1) % 3].x - v[i].x, v[(i + 1) % 3].y - v[i].y) < 12 { return nil }
        guard maxDistance(pts, toPolygon: v) <= fitTolerance(pts) else { return nil }
        return .triangle(v[0], v[1], v[2])
    }

    private static func rectangle(_ pts: [CGPoint], corners: [Int]) -> Shape? {
        let v = corners.map { pts[$0] }
        // vier Ecken mit annaehernd rechten Winkeln
        for i in 0..<4 {
            let p = v[(i + 3) % 4], c = v[i], n = v[(i + 1) % 4]
            let a = angleBetween(CGPoint(x: p.x - c.x, y: p.y - c.y), CGPoint(x: n.x - c.x, y: n.y - c.y))
            guard a >= 60, a <= 120 else { return nil }
        }
        // Ausrichtung der laengsten Seite; nahe an den Achsen achsparallel
        var best = 0, bestLen: CGFloat = -1
        for i in 0..<4 {
            let l = hypot(v[(i + 1) % 4].x - v[i].x, v[(i + 1) % 4].y - v[i].y)
            if l > bestLen { bestLen = l; best = i }
        }
        var angle = atan2(v[(best + 1) % 4].y - v[best].y, v[(best + 1) % 4].x - v[best].x)
        angle = normalized(angle)
        if abs(angle) * 180 / .pi <= 8 { angle = 0 }
        // Box im gedrehten Rahmen ueber alle Punkte des Strichs (nicht nur die Ecken)
        let cosA = cos(-angle), sinA = sin(-angle)
        let rotated = pts.map { CGPoint(x: $0.x * cosA - $0.y * sinA, y: $0.x * sinA + $0.y * cosA) }
        let b = bounds(rotated)
        let centerR = CGPoint(x: b.midX, y: b.midY)
        let center = CGPoint(x: centerR.x * cos(angle) - centerR.y * sin(angle), y: centerR.x * sin(angle) + centerR.y * cos(angle))
        // Quadrat bei fast gleichen Seiten (wie der Kreis bei fast gleichen Achsen)
        var size = CGSize(width: b.width, height: b.height)
        if abs(size.width - size.height) <= squareTolerance * max(size.width, size.height) {
            let side = (size.width + size.height) / 2
            size = CGSize(width: side, height: side)
        }
        let shape = Shape.rectangle(center: center, size: size, angle: angle)
        // der Strich muss nahe an den vier Kanten liegen (sonst war eine Ecke nur Zufall)
        guard maxDistance(pts, toPolygon: rectangleCorners(of: shape)) <= fitTolerance(pts) else { return nil }
        return shape
    }

    /// Die vier Eckpunkte eines Rechtecks
    static func rectangleCorners(of shape: Shape) -> [CGPoint] {
        guard case .rectangle(let c, let s, let angle) = shape else { return [] }
        let hw = s.width / 2, hh = s.height / 2
        return [CGPoint(x: -hw, y: -hh), CGPoint(x: hw, y: -hh), CGPoint(x: hw, y: hh), CGPoint(x: -hw, y: hh)].map { p in
            CGPoint(x: c.x + p.x * cos(angle) - p.y * sin(angle), y: c.y + p.x * sin(angle) + p.y * cos(angle))
        }
    }

    /// Winkel auf -45 ... 45 Grad (ein Rechteck sieht alle 90 Grad gleich aus)
    private static func normalized(_ angle: CGFloat) -> CGFloat {
        var a = angle
        while a > .pi / 4 { a -= .pi / 2 }
        while a < -.pi / 4 { a += .pi / 2 }
        return a
    }

    private static func ellipse(_ pts: [CGPoint]) -> Shape? {
        let b = bounds(pts)
        let cx = b.midX, cy = b.midY
        var rx = b.width / 2, ry = b.height / 2
        guard rx >= 6, ry >= 6 else { return nil }
        // mittlere Abweichung von der Ellipse in der Box
        let err = pts.reduce(0.0) { sum, p in
            sum + abs(pow((p.x - cx) / rx, 2) + pow((p.y - cy) / ry, 2) - 1)
        } / CGFloat(pts.count)
        guard err <= 0.3 else { return nil }
        // Kreis bei fast gleichen Achsen
        if abs(rx - ry) <= 0.12 * max(rx, ry) {
            let r = (rx + ry) / 2
            rx = r; ry = r
        }
        return .ellipse(center: CGPoint(x: cx, y: cy), radii: CGSize(width: rx, height: ry))
    }

    /// Pfeil: ein gerader Schaft, danach die Spitze als Haken oder "V" in der Naehe des Schaftendes (die Spitze
    /// darf in einem Zug zurueck und wieder vor gezeichnet sein)
    private static func arrow(_ pts: [CGPoint], corners: [Int], length: CGFloat) -> Shape? {
        guard corners.count <= 5 else { return nil }
        // Die Spitze ist die erste Ecke, an der der Strich kehrtmacht; eine Unruhe weiter vorn im Schaft soll den
        // Pfeil nicht verhindern, darum werden die Ecken der Reihe nach probiert. Zuletzt der am weitesten vom
        // Anfang entfernte Punkt: Rundet PencilKit die Spitze und den Haken zu einer Ecke zusammen, ist nur er die
        // Spitze.
        var candidates = corners
        if let far = pts.indices.max(by: { hypot(pts[$0].x - pts[0].x, pts[$0].y - pts[0].y) < hypot(pts[$1].x - pts[0].x, pts[$1].y - pts[0].y) }) {
            candidates.append(far)
        }
        for tipIndex in candidates where tipIndex >= 4 && tipIndex <= pts.count - 4 {
            if let arrow = arrow(pts, tipIndex: tipIndex, length: length) { return arrow }
        }
        return nil
    }

    private static func arrow(_ pts: [CGPoint], tipIndex: Int, length: CGFloat) -> Shape? {
        let start = pts[0], tip = pts[tipIndex]
        let shaft = hypot(tip.x - start.x, tip.y - start.y)
        guard shaft >= minimumLength * 0.8, shaft >= 0.5 * length else { return nil }
        // Schaft gerade
        let deviation = pts[0...tipIndex].map { distance($0, toLine: start, tip) }.max() ?? 0
        guard deviation <= max(4, 0.08 * shaft) else { return nil }
        // Rest bleibt nahe der Spitze und zeigt schraeg zum Schaft zurueck
        let head = Array(pts[tipIndex...])
        let reach = head.map { hypot($0.x - tip.x, $0.y - tip.y) }.max() ?? 0
        guard reach >= 6, reach <= 0.5 * shaft else { return nil }
        let back = CGPoint(x: start.x - tip.x, y: start.y - tip.y)
        let slanted = head.contains { p in
            let d = CGPoint(x: p.x - tip.x, y: p.y - tip.y)
            guard hypot(d.x, d.y) >= 0.5 * reach else { return false }
            let a = angleBetween(back, d)
            return a >= 15 && a <= 80
        }
        guard slanted else { return nil }
        return .arrow(from: start, to: tip)
    }

    // MARK: Ideale Form als Strich

    /// Die Form als Strich mit Tinte, Breite, Deckkraft und Druckwerten des Originals (gleichmaessige Breite); Ecken
    /// sind dreifache Kontrollpunkte, damit die B-Spline dort scharf bleibt
    static func idealStroke(_ shape: Shape, like original: PKStroke) -> PKStroke {
        let path = original.path
        let sample = path.count > 0 ? path[min(path.count / 2, path.count - 1)] : nil
        let widths = (0..<path.count).map { path[$0].size.width }.sorted()
        let width = widths.isEmpty ? 3 : widths[widths.count / 2]
        let size = CGSize(width: width, height: width)
        let opacity = sample?.opacity ?? 1
        let force = sample?.force ?? 1
        let azimuth = sample?.azimuth ?? 0
        let altitude = sample?.altitude ?? .pi / 2
        let locations = outline(shape)
        var points: [PKStrokePoint] = []
        points.reserveCapacity(locations.count)
        for (i, p) in locations.enumerated() {
            points.append(PKStrokePoint(location: p, timeOffset: Double(i) * 0.004, size: size, opacity: opacity, force: force,
                                        azimuth: azimuth, altitude: altitude))
        }
        return PKStroke(ink: original.ink, path: PKStrokePath(controlPoints: points, creationDate: path.creationDate))
    }

    /// Kontrollpunkte der Form (alle 3 pt, Ecken dreifach)
    static func outline(_ shape: Shape) -> [CGPoint] {
        switch shape {
        case .line(let a, let b):
            return polyline([a, b], closed: false)
        case .rectangle(let c, let s, let angle):
            let hw = s.width / 2, hh = s.height / 2
            let local = [CGPoint(x: -hw, y: -hh), CGPoint(x: hw, y: -hh), CGPoint(x: hw, y: hh), CGPoint(x: -hw, y: hh)]
            let corners = local.map { p in
                CGPoint(x: c.x + p.x * cos(angle) - p.y * sin(angle), y: c.y + p.x * sin(angle) + p.y * cos(angle))
            }
            return polyline(corners, closed: true)
        case .ellipse(let c, let r):
            let n = max(48, Int((2 * .pi * max(r.width, r.height)) / 3))
            return (0...n).map { i in
                let t = CGFloat(i) / CGFloat(n) * 2 * .pi
                return CGPoint(x: c.x + r.width * cos(t), y: c.y + r.height * sin(t))
            }
        case .triangle(let a, let b, let c):
            return polyline([a, b, c], closed: true)
        case .arrow(let a, let tip):
            let dx = tip.x - a.x, dy = tip.y - a.y
            let len = hypot(dx, dy)
            let head = min(0.25 * len, max(12, 0.12 * len))
            let angle = atan2(dy, dx)
            let left = CGPoint(x: tip.x - head * cos(angle - .pi / 6), y: tip.y - head * sin(angle - .pi / 6))
            let right = CGPoint(x: tip.x - head * cos(angle + .pi / 6), y: tip.y - head * sin(angle + .pi / 6))
            return polyline([a, tip, left, tip, right], closed: false)
        }
    }

    private static func polyline(_ vertices: [CGPoint], closed: Bool, step: CGFloat = 3) -> [CGPoint] {
        var out: [CGPoint] = []
        let v = closed ? vertices + [vertices[0]] : vertices
        for i in 0..<(v.count - 1) {
            let a = v[i], b = v[i + 1]
            let len = hypot(b.x - a.x, b.y - a.y)
            let n = max(1, Int(len / step))
            out.append(contentsOf: [a, a, a])                               // Ecke scharf
            for k in 1..<n {
                let t = CGFloat(k) / CGFloat(n)
                out.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        if let last = v.last { out.append(contentsOf: [last, last, last]) }
        return out
    }

    // MARK: Geometrie

    /// Punkte, die beim Halten am Ende entstanden sind, weglassen
    static func trimHold(_ pts: [CGPoint]) -> [CGPoint] {
        guard let last = pts.last else { return pts }
        var end = pts.count - 1
        while end > 0, hypot(pts[end - 1].x - last.x, pts[end - 1].y - last.y) <= trimRadius { end -= 1 }
        return Array(pts[0...end])
    }

    /// Gleichmaessig in Abstand `step` abtasten (Dichte der Eingabe spielt danach keine Rolle)
    static func resample(_ pts: [CGPoint], step: CGFloat) -> [CGPoint] {
        guard pts.count > 1 else { return pts }
        var out = [pts[0]]
        for i in 1..<pts.count {
            var a = out.last!
            let b = pts[i]
            var d = hypot(b.x - a.x, b.y - a.y)
            while d >= step {
                let t = step / d
                a = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                out.append(a)
                d = hypot(b.x - a.x, b.y - a.y)
            }
        }
        if let l = pts.last, let o = out.last, hypot(l.x - o.x, l.y - o.y) > step / 2 { out.append(l) }
        return out
    }

    static func pathLength(_ pts: [CGPoint]) -> CGFloat {
        guard pts.count > 1 else { return 0 }
        return (1..<pts.count).reduce(0) { $0 + hypot(pts[$1].x - pts[$1 - 1].x, pts[$1].y - pts[$1 - 1].y) }
    }

    static func bounds(_ pts: [CGPoint]) -> CGRect {
        let xs = pts.map(\.x), ys = pts.map(\.y)
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return .zero }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    static func distance(_ p: CGPoint, toLine a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        guard len > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        return abs(dy * p.x - dx * p.y + b.x * a.y - b.y * a.x) / len
    }

    /// Winkel zwischen zwei Richtungen in Grad (0 ... 180)
    static func angleBetween(_ u: CGPoint, _ v: CGPoint) -> CGFloat {
        let lu = hypot(u.x, u.y), lv = hypot(v.x, v.y)
        guard lu > 0, lv > 0 else { return 0 }
        let c = max(-1, min(1, (u.x * v.x + u.y * v.y) / (lu * lv)))
        return acos(c) * 180 / .pi
    }

    /// Ecken einer Punktfolge. PencilKit legt den Strich als B-Spline ueber seine Kontrollpunkte: eine von Hand
    /// gezeichnete Ecke kommt darum nicht spitz an, sondern ueber 10 bis 20 pt abgerundet (am Geraet gemessen; im
    /// Simulator mit gerechneten Punkten faellt das nicht auf). Ein fester Hebel von 6 pt misst in dieser Rundung
    /// darum zu wenig Drehung und findet die Ecken eines Rechtecks nicht.
    ///
    /// Darum: Der Hebel waechst mit der Form (5 % der Stricklaenge, 9 bis 24 pt), sodass die Rundung ganz darin
    /// liegt. Damit Boegen (Kreis, die engen Enden einer Ellipse) nicht als Ecke gelten, wird jede Stelle zweimal
    /// gemessen, mit Hebel und mit doppeltem Hebel: Bei einem Bogen dreht der doppelte Hebel etwa doppelt so viel,
    /// an einer Ecke bleibt es bei dem einen Knick. Ecke ist also: Drehung ueber 45 Grad und doppelter Hebel unter
    /// `arcRatio` mal der Drehung. Zusammenhaengende Kandidaten bilden eine Ecke (groesste Drehung, bei Gleichstand
    /// die Mitte). Bei geschlossenen Formen laeuft der Hebel ueber den Anfang hinweg.
    static func cornerIndices(_ pts: [CGPoint], closed: Bool) -> [Int] {
        let n = pts.count
        guard n >= 8 else { return [] }
        let spacing = max(0.5, pathLength(pts) / CGFloat(n - 1))
        let lever = max(9, min(0.05 * pathLength(pts), 24))
        let w = max(2, min(n / 6, Int((lever / spacing).rounded())))
        func at(_ i: Int) -> CGPoint? {
            if closed { return pts[((i % n) + n) % n] }
            return (0..<n).contains(i) ? pts[i] : nil
        }
        func turn(_ i: Int, _ lever: Int) -> CGFloat? {
            guard let p = at(i - lever), let c = at(i), let q = at(i + lever) else { return nil }
            return angleBetween(CGPoint(x: c.x - p.x, y: c.y - p.y), CGPoint(x: q.x - c.x, y: q.y - c.y))
        }
        var sharp = [CGFloat](repeating: 0, count: n)
        let near = max(2, w / 2)
        for i in 0..<n {
            guard let t = turn(i, w), t >= cornerAngle else { continue }
            // Scharfe Kehre (Spitze eines Pfeils) schon auf kurzem Hebel: immer eine Ecke
            if let close = turn(i, near), close >= sharpAngle { sharp[i] = t; continue }
            // Sonst: Bogen oder Ecke? Der doppelte Hebel dreht beim Bogen mit, an der Ecke kaum
            guard let wide = turn(i, 2 * w), wide <= arcRatio * t else { continue }
            sharp[i] = t
        }
        // Die staerkste Stelle je Ecke: ein Kandidat zaehlt, wenn im Umkreis des Hebels nichts staerker dreht
        // (sonst wuerden die Spitze eines Pfeils und das Ende seines Hakens, oft nur 25 pt auseinander, zu einer Ecke
        // verschmelzen). Gleich starke Nachbarn (flache Kuppe) kommen danach zusammen; davon bleibt die Mitte.
        func value(_ i: Int) -> CGFloat {
            if closed { return sharp[((i % n) + n) % n] }
            return (0..<n).contains(i) ? sharp[i] : 0
        }
        var peaks: [Int] = []
        for i in 0..<n where sharp[i] > 0 {
            var isPeak = true
            for d in 1...w where value(i - d) > sharp[i] || value(i + d) > sharp[i] { isPeak = false; break }
            if isPeak { peaks.append(i) }
        }
        var groups: [[Int]] = []
        for i in peaks {
            if let last = groups.last?.last, i - last <= w { groups[groups.count - 1].append(i) } else { groups.append([i]) }
        }
        // geschlossen: eine Kuppe ueber den Anfang hinweg ist eine Gruppe (Indizes der ersten Gruppe um n versetzt)
        if closed, groups.count > 1, let first = groups.first, let last = groups.last, first[0] + n - last[last.count - 1] <= w {
            groups[groups.count - 1] = last + first.map { $0 + n }
            groups.removeFirst()
        }
        var out: [Int] = []
        for g in groups { out.append(g[g.count / 2] % n) }
        return out.sorted()
    }

    /// Ab dieser Drehung (Grad) ueber den Hebel ist eine Stelle ein Ecken-Kandidat
    static let cornerAngle: CGFloat = 45
    /// Dreht der doppelte Hebel mehr als so viel mal die Drehung des einfachen, ist es ein Bogen und keine Ecke
    static let arcRatio: CGFloat = 1.6
    /// So viel Drehung schon auf dem halben Hebel ist eine Kehre (Pfeilspitze), nie ein Bogen
    static let sharpAngle: CGFloat = 75

    /// Groesster Abstand der Punkte von einem (geschlossenen) Linienzug
    static func maxDistance(_ pts: [CGPoint], toPolygon v: [CGPoint]) -> CGFloat {
        guard v.count >= 2 else { return .greatestFiniteMagnitude }
        var worst: CGFloat = 0
        for p in pts {
            var best = CGFloat.greatestFiniteMagnitude
            for i in 0..<v.count {
                best = min(best, distance(p, toSegment: v[i], v[(i + 1) % v.count]))
            }
            worst = max(worst, best)
        }
        return worst
    }

    /// Abstand zu einer Strecke (nicht zur unendlichen Geraden)
    static func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2
        t = max(0, min(1, t))
        return hypot(p.x - (a.x + dx * t), p.y - (a.y + dy * t))
    }
}

/// Schalter "Formen erkennen" in den Einstellungen (Wunsch des Inhabers 13.11.2026); Standard an, je Geraet
enum ShapeSnapSetting {
    static let key = "uniflow.shapeSnap"
    static var enabled: Bool { UserDefaults.standard.object(forKey: key) == nil || UserDefaults.standard.bool(forKey: key) }
    static let title = "Formen erkennen"
    static let note = "Linie, Rechteck, Quadrat, Dreieck, Kreis, Ellipse oder Pfeil zeichnen und am Ende kurz stehen bleiben "
        + "(½ Sekunde): StudiNow macht die Form gerade bzw. rund. Normales Schreiben bleibt, wie es ist. Ein Mal Rückgängig nimmt die Form wieder weg."
}
