import PencilKit
import UIKit

// Glaettung einstellbar (Wunsch des Inhabers 13.11.2026: "so wie jetzt oder noch weniger, nahe 0 %").
//
// Was heute glaettet: nur PencilKit selbst. Die App hat keine eigene Glaettung und keine eigene Vorhersage. PencilKit
// filtert die Stiftpunkte beim Zeichnen und legt den Strich als gleichmaessige kubische B-Spline ueber seine
// Kontrollpunkte (`PKStrokePath`); der Strich laeuft dabei nicht genau durch die gemessenen Punkte. Das laesst sich
// in PencilKit weder fuer den laufenden Strich noch ueber eine Werkzeug- oder Tinteneinstellung abschalten.
//
// Darum misst der Editor die Rohpunkte des Stifts mit (`RawPencilRecorder`, alle Zwischenpunkte des Pencil, 240 je
// Sekunde) und baut den Strich beim Absetzen daraus neu (`RawStroke.rebuild`):
// - Normal (Standard, wie bisher): der Strich von PencilKit bleibt.
// - Leicht: die Rohpunkte sind die Kontrollpunkte der Kurve; sie glaettet nur ueber je zwei Nachbarpunkte (bei 240
//   Punkten je Sekunde Bruchteile eines Millimeters).
// - Aus: die Kontrollpunkte werden so berechnet, dass die Kurve genau durch jeden gemessenen Punkt laeuft.
// Breite, Deckkraft und Druck je Punkt uebernimmt der neue Strich von PencilKit (zeitlich naechster Punkt), Tinte und
// Farbe bleiben. Ehrlich: Waehrend der Stift noch schreibt, zeigt PencilKit immer seinen eigenen, geglaetteten Strich;
// erst beim Absetzen steht der Strich aus den Rohpunkten da. Mit Lineal und bei erkannten Formen bleibt der Strich.

enum PencilSmoothing: String, CaseIterable {
    case off, light, normal

    static let key = "uniflow.pencilSmoothing"
    static let standard = PencilSmoothing.normal

    static var current: PencilSmoothing {
        UserDefaults.standard.string(forKey: key).flatMap(PencilSmoothing.init(rawValue:)) ?? standard
    }

    static let title = "Glättung"
    static let options: [(value: String, label: String)] = [("off", "Aus"), ("light", "Leicht"), ("normal", "Normal")]
    static let note = "Normal: wie bisher. Leicht und Aus zeichnen den Strich beim Absetzen aus den echten Messpunkten des Stifts, "
        + "„Aus“ genau durch jeden Punkt. Während du schreibst, glättet das iPad immer etwas."
}

/// Ein Messpunkt des Stifts in Zeichnungskoordinaten (Seitenpunkte)
struct RawPencilSample: Equatable {
    var location: CGPoint
    /// Sekunden (Zeitstempel des Systems)
    var time: TimeInterval
}

/// Sammelt die Rohpunkte des Pencil auf einer Zeichenflaeche, ohne die Eingabe zu beruehren: erkennt nie etwas,
/// haelt keine Beruehrung zurueck und laesst sich von PencilKit nicht verdraengen. Nur aktiv, wenn die Glaettung nicht
/// "Normal" ist.
final class RawPencilRecorder: UIGestureRecognizer {
    private(set) var samples: [RawPencilSample] = []
    private var tracked: UITouch?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
    }

    convenience init() { self.init(target: nil, action: nil) }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    /// Nur Tests: Messpunkte wie vom Stift (im Simulator gibt es keinen Pencil)
    func setSamplesForTesting(_ s: [RawPencilSample]) { samples = s }

    /// Messpunkte des letzten Strichs abholen (danach leer)
    func take() -> [RawPencilSample] {
        defer { samples = [] }
        return samples
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard PencilSmoothing.current != .normal, tracked == nil, let t = touches.first else { return }
        tracked = t
        samples = []
        record(t, event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = tracked, touches.contains(t) else { return }
        record(t, event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = tracked, touches.contains(t) else { return }
        record(t, event)
        tracked = nil
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        tracked = nil
        samples = []
        state = .failed
    }

    override func reset() {
        super.reset()
        tracked = nil
    }

    private func record(_ touch: UITouch, _ event: UIEvent) {
        guard let canvas = view as? PKCanvasView else { return }
        let zoom = max(canvas.zoomScale, 0.0001)
        for c in event.coalescedTouches(for: touch) ?? [touch] {
            let p = c.preciseLocation(in: canvas)
            samples.append(RawPencilSample(location: CGPoint(x: p.x / zoom, y: p.y / zoom), time: c.timestamp))
        }
    }
}

/// Strich aus Rohpunkten (reine Funktionen, `PencilSmoothingTests`)
enum RawStroke {
    /// Rohpunkte, die naeher als dieser Abstand (Seitenpunkte) am vorigen liegen, fallen weg (Stillstand)
    static let minimumStep: CGFloat = 0.05

    /// Neuer Strich aus den Rohpunkten fuer `smoothing` (nil bei "Normal" oder zu wenigen Punkten). Lage und Zeit aus
    /// den Messpunkten, Breite, Deckkraft, Druck und Neigung vom PencilKit-Strich (zeitlich naechster Punkt).
    static func rebuild(_ original: PKStroke, samples raw: [RawPencilSample], smoothing: PencilSmoothing) -> PKStroke? {
        guard smoothing != .normal, original.path.count > 0 else { return nil }
        let samples = thinned(raw)
        guard samples.count >= 2 else { return nil }
        let inverse = original.transform.inverted()
        let locations = samples.map { $0.location.applying(inverse) }
        let control = smoothing == .off ? interpolatingControlPoints(locations) : locations
        let t0 = samples[0].time
        let path = original.path
        var j = 0
        var points: [PKStrokePoint] = []
        points.reserveCapacity(control.count)
        for (i, p) in control.enumerated() {
            let offset = samples[i].time - t0
            // zeitlich naechster Punkt von PencilKit (beide Folgen sind nach der Zeit geordnet)
            while j + 1 < path.count, abs(path[j + 1].timeOffset - offset) <= abs(path[j].timeOffset - offset) { j += 1 }
            let ref = path[j]
            points.append(PKStrokePoint(location: p, timeOffset: offset, size: ref.size, opacity: ref.opacity, force: ref.force,
                                        azimuth: ref.azimuth, altitude: ref.altitude))
        }
        var stroke = PKStroke(ink: original.ink, path: PKStrokePath(controlPoints: points, creationDate: path.creationDate),
                              transform: original.transform, mask: original.mask)
        stroke.randomSeed = original.randomSeed
        return stroke
    }

    /// Doppelte Punkte (Stift steht) weglassen; der letzte Punkt bleibt
    static func thinned(_ samples: [RawPencilSample]) -> [RawPencilSample] {
        var out: [RawPencilSample] = []
        for s in samples {
            if let last = out.last, hypot(s.location.x - last.location.x, s.location.y - last.location.y) < minimumStep { continue }
            out.append(s)
        }
        if let last = samples.last, out.last != last, out.count >= 1 {
            out[out.count - 1] = last
        }
        return out
    }

    /// Kontrollpunkte, mit denen die Kurve von PencilKit genau durch `q` laeuft. PencilKit wertet die Kontrollpunkte
    /// als gleichmaessige kubische B-Spline aus: an Stelle i liegt die Kurve bei (P[i-1] + 4 P[i] + P[i+1]) / 6, Anfang
    /// und Ende liegen genau auf P[0] bzw. P[n-1] (gemessen am iOS-27-SDK, `PencilSmoothingTests`). Also: P[0] = q[0],
    /// P[n-1] = q[n-1] und dazwischen ein tridiagonales Gleichungssystem (Thomas-Verfahren, stabil: 4 > 1 + 1).
    static func interpolatingControlPoints(_ q: [CGPoint]) -> [CGPoint] {
        let n = q.count
        guard n > 2 else { return q }
        var p = q
        let m = n - 2                                                        // Unbekannte P[1] ... P[n-2]
        var c = [CGFloat](repeating: 0, count: m)                           // obere Nebendiagonale nach Elimination
        var dx = [CGFloat](repeating: 0, count: m), dy = [CGFloat](repeating: 0, count: m)
        for k in 0..<m {
            var rx = 6 * q[k + 1].x, ry = 6 * q[k + 1].y
            if k == 0 { rx -= q[0].x; ry -= q[0].y }
            if k == m - 1 { rx -= q[n - 1].x; ry -= q[n - 1].y }
            let denom = 4 - (k > 0 ? c[k - 1] : 0)
            c[k] = 1 / denom
            dx[k] = (rx - (k > 0 ? dx[k - 1] : 0)) / denom
            dy[k] = (ry - (k > 0 ? dy[k - 1] : 0)) / denom
        }
        var nx = dx[m - 1], ny = dy[m - 1]
        p[m] = CGPoint(x: nx, y: ny)
        if m >= 2 {
            for k in stride(from: m - 2, through: 0, by: -1) {
                nx = dx[k] - c[k] * nx
                ny = dy[k] - c[k] * ny
                p[k + 1] = CGPoint(x: nx, y: ny)
            }
        }
        return p
    }
}
