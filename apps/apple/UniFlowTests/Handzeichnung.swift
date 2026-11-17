import CoreGraphics
import Foundation

/// Handzeichnungen fuer die Formerkennung (Meldung des Inhabers 17.11.2026: "Viereck geht immer noch nicht ..., Dreieck
/// auch nicht immer, und gerader Strich wird kuerzer immer").
///
/// Die bisherigen Teststriche waren zu brav: Anfang und Ende trafen sich genau, jede Form begann an einer Ecke. Von
/// Hand ist es anders. Darum baut `Handzeichnung` Bahnen, wie eine Hand sie zieht:
/// - Zittern (1 bis 3 pt, langsam schwingend plus etwas Rauschen), die Hand driftet (das Ende trifft den Anfang nicht),
/// - runde Ecken (Radius 3 bis 14 pt), ungleiche, schiefe und leicht bauchige Seiten, Schraeglage 0 bis 20 Grad,
/// - am Schluss eine Luecke oder ein Stueck doppelt gezogen (bis 15 % der Seite), Start an einer Ecke oder mitten auf
///   einer Seite, im Uhrzeigersinn und dagegen, Groessen 25 / 60 / 150 / 400 pt,
/// - am Ende das "Halte-Knaeuel": 20 bis 40 Punkte im Umkreis von 2 pt, waehrend der Stift fuer die Form still steht
///   (bei jedem zweiten Strich wandert die Hand dabei noch 3 bis 5 pt weiter).
/// Dazu Buchstaben und Zeichen, die KEINE Form werden duerfen, auch wenn man am Ende haelt.
///
/// Die Bahnen laufen als echte Beruehrung durch PencilKit (`EditorStrichBleibtTests.testFormenKorpusAufnehmen`); was
/// PencilKit daraus macht, steht in `FormenKorpusDaten` und wird in `FormenHandzeichnungTests` ausgewertet.
struct Handzeichnung {
    enum Art: String, CaseIterable {
        case viereck = "Viereck", dreieck = "Dreieck", linie = "Linie", rund = "Kreis/Ellipse", pfeil = "Pfeil", zeichen = "Zeichen"
    }

    var name: String
    var art: Art
    /// Namen der Formen, die herauskommen duerfen (`ShapeRecognizer.Shape.name`); "-" = bleibt Handschrift
    var erlaubt: [String]
    /// Merkmale fuer die Aufschluesselung (Groesse, Start, Schluss)
    var merkmale: [String: String] = [:]
    /// Was gemeint war, um den Mittelpunkt (0, 0): Viereck = Mitte x, y, Breite, Hoehe, Schraeglage in Grad;
    /// Dreieck = drei Ecken; Linie und Pfeil = Anfang und Ende; Kreis/Ellipse = Mitte x, y, Radien
    var soll: [CGFloat] = []
    /// Bahn der Beruehrung um den Mittelpunkt (0, 0), in Seitenpunkten
    var bahn: [CGPoint] = []
    /// Punkte des Halte-Knaeuels am Ende (schon in `bahn` enthalten)
    var knaeuel = 0

    // MARK: Zufall (fest je Fall, damit jeder Lauf dieselben Bahnen zieht)

    struct Zufall {
        private var state: UInt64
        init(_ seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 0x1234_5678_9ABC_DEF1 }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        /// 0 ..< 1
        mutating func unit() -> CGFloat { CGFloat(next() % 1_000_000) / 1_000_000 }
        /// -a ... a
        mutating func pm(_ a: CGFloat) -> CGFloat { (unit() * 2 - 1) * a }
        mutating func between(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * unit() }
        mutating func pick<T>(_ xs: [T]) -> T { xs[Int(next() % UInt64(xs.count))] }
    }

    // MARK: Bausteine

    static func rotate(_ p: CGPoint, _ degrees: CGFloat) -> CGPoint {
        let a = degrees * .pi / 180
        return CGPoint(x: p.x * cos(a) - p.y * sin(a), y: p.x * sin(a) + p.y * cos(a))
    }

    static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }
    static func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(b.x - a.x, b.y - a.y) }

    /// Bogen einer Ellipse (Winkel in Grad, y nach unten: wachsender Winkel laeuft im Uhrzeigersinn), dicht
    static func bogen(_ c: CGPoint, _ rx: CGFloat, _ ry: CGFloat, von: CGFloat, bis: CGFloat) -> [CGPoint] {
        let n = max(8, Int(abs(bis - von) / 4))
        return (0...n).map { i in
            let t = (von + (bis - von) * CGFloat(i) / CGFloat(n)) * .pi / 180
            return CGPoint(x: c.x + rx * cos(t), y: c.y + ry * sin(t))
        }
    }

    /// Linienzug mit gerundeten Ecken: an jeder inneren Ecke ein Bogen, der `radius` vor der Ecke beginnt (hoechstens
    /// 40 % der kuerzeren Nachbarseite). Dicht abgetastet (0,5 pt).
    static func rund(_ v: [CGPoint], radius: CGFloat) -> [CGPoint] {
        guard v.count >= 2 else { return v }
        var out: [CGPoint] = [v[0]]
        func line(to b: CGPoint) {
            guard let a = out.last else { return }
            let n = max(1, Int(dist(a, b) / 0.5))
            for k in 1...n { out.append(lerp(a, b, CGFloat(k) / CGFloat(n))) }
        }
        for i in 1..<(v.count - 1) {
            let p = v[i - 1], c = v[i], q = v[i + 1]
            let lin = dist(p, c), lout = dist(c, q)
            let t = min(radius, 0.4 * min(lin, lout))
            guard t > 0.3, lin > 0, lout > 0 else { line(to: c); continue }
            let a = lerp(c, p, t / lin), b = lerp(c, q, t / lout)
            line(to: a)
            let n = max(4, Int(t * 2))
            for k in 1...n {
                let u = CGFloat(k) / CGFloat(n)
                let x = (1 - u) * (1 - u) * a.x + 2 * u * (1 - u) * c.x + u * u * b.x
                let y = (1 - u) * (1 - u) * a.y + 2 * u * (1 - u) * c.y + u * u * b.y
                out.append(CGPoint(x: x, y: y))
            }
        }
        line(to: v[v.count - 1])
        return out
    }

    /// Geschlossene Form von Hand: Start bei `start` (Anteil der ersten Seite, 0 = an der Ecke), am Schluss `schluss`
    /// (Anteil der ersten bzw. letzten Seite: negativ = Luecke, positiv = doppelt gezogen)
    static func umlauf(_ v: [CGPoint], start: CGFloat, schluss: CGFloat, radius: CGFloat) -> [CGPoint] {
        let n = v.count
        var list: [CGPoint] = []
        if start <= 0 {
            list = Array(v)
            if schluss > 0 {
                list.append(v[0])
                list.append(lerp(v[0], v[1], schluss))
            } else {
                list.append(lerp(v[n - 1], v[0], 1 + schluss))
            }
        } else {
            list = [lerp(v[0], v[1], start)] + Array(v[1...]) + [v[0], lerp(v[0], v[1], max(0.02, start + schluss))]
        }
        return rund(list, radius: radius)
    }

    /// Jede Seite bekommt einen Bauch (von Hand ist keine Seite gerade): Punkte der dichten Bahn werden quer zu ihrer
    /// Seite verschoben, in der Seitenmitte um `bauch[i]`, an den Ecken gar nicht.
    static func gebogen(_ dense: [CGPoint], ecken v: [CGPoint], bauch: [CGFloat]) -> [CGPoint] {
        dense.map { p in
            var best = 0, bestD = CGFloat.greatestFiniteMagnitude, bestU: CGFloat = 0
            for i in 0..<v.count {
                let a = v[i], b = v[(i + 1) % v.count]
                let len2 = (b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)
                guard len2 > 0 else { continue }
                let u = max(0, min(1, ((p.x - a.x) * (b.x - a.x) + (p.y - a.y) * (b.y - a.y)) / len2))
                let d = hypot(p.x - (a.x + (b.x - a.x) * u), p.y - (a.y + (b.y - a.y) * u))
                if d < bestD { bestD = d; best = i; bestU = u }
            }
            let a = v[best], b = v[(best + 1) % v.count]
            let len = dist(a, b)
            let s = sin(bestU * .pi) * bauch[best]
            return CGPoint(x: p.x - (b.y - a.y) / len * s, y: p.y + (b.x - a.x) / len * s)
        }
    }

    /// Dichte Bahn mit der Hand abfahren: Abstand `abstand` (schwankt), Zittern mit Ausschlag `zittern`, die Hand
    /// driftet bis zum Ende um `drift`; dann das Halte-Knaeuel.
    static func hand(_ dense: [CGPoint], abstand: CGFloat, zittern: CGFloat, drift: CGPoint, knaeuel: Int, _ z: inout Zufall) -> [CGPoint] {
        guard dense.count > 1 else { return dense }
        var cum: [CGFloat] = [0]
        for i in 1..<dense.count { cum.append(cum[i - 1] + dist(dense[i - 1], dense[i])) }
        let total = cum[cum.count - 1]
        let l1 = z.between(9, 14), l2 = z.between(5, 7)
        let p1 = z.between(0, 6.28), p2 = z.between(0, 6.28), p3 = z.between(0, 6.28), p4 = z.between(0, 6.28)
        var out: [CGPoint] = []
        var s: CGFloat = 0
        var i = 0
        var k = 0
        while s <= total {
            while i + 1 < dense.count, cum[i + 1] < s { i += 1 }
            let seg = cum[min(i + 1, cum.count - 1)] - cum[i]
            let p = seg > 0 ? lerp(dense[i], dense[min(i + 1, dense.count - 1)], (s - cum[i]) / seg) : dense[i]
            let u = total > 0 ? s / total : 0
            let jx = zittern * (0.6 * sin(s / l1 + p1) + 0.4 * sin(s / l2 + p2)) + z.pm(0.3)
            let jy = zittern * (0.6 * sin(s / l1 + p3) + 0.4 * sin(s / l2 + p4)) + z.pm(0.3)
            out.append(CGPoint(x: p.x + jx + drift.x * u, y: p.y + jy + drift.y * u))
            s += abstand * (1 + 0.3 * sin(CGFloat(k) / 7 + p1))
            k += 1
        }
        // Knaeuel: der Stift steht, zittert im Umkreis von 2 pt - und bei jedem zweiten Strich wandert die Hand dabei
        // noch 3 bis 5 pt weiter
        if knaeuel > 0, let last = out.last {
            var q = CGPoint.zero
            let weit = z.pick([0, 0, 3, 5] as [CGFloat]), wohin = z.between(0, 6.28)
            for i in 0..<knaeuel {
                q = CGPoint(x: q.x + z.pm(0.9), y: q.y + z.pm(0.9))
                let r = hypot(q.x, q.y)
                if r > 2 { q = CGPoint(x: q.x * 2 / r, y: q.y * 2 / r) }
                let u = CGFloat(i + 1) / CGFloat(knaeuel)
                out.append(CGPoint(x: last.x + q.x + weit * u * cos(wohin), y: last.y + q.y + weit * u * sin(wohin)))
            }
        }
        return out
    }

    static func abstand(fuer groesse: CGFloat) -> CGFloat { groesse <= 30 ? 1.5 : groesse <= 70 ? 2.5 : groesse <= 160 ? 4 : 6 }

    static func bounds(_ pts: [CGPoint]) -> CGRect {
        var r = CGRect.null
        for p in pts { r = r.union(CGRect(origin: p, size: .zero)) }
        return r
    }

    // MARK: Faelle

    static let groessen: [CGFloat] = [25, 60, 150, 400]
    static let schluesse: [(name: String, von: CGFloat, bis: CGFloat)] = [("Lücke", -0.15, -0.04), ("genau", -0.02, 0.02), ("doppelt", 0.04, 0.15)]

    /// Alle Faelle. Was nicht in `maxBreite` x `maxHoehe` passt (sichtbarer Teil der Seite), wird gleichmaessig verkleinert.
    static func alle(maxBreite: CGFloat, maxHoehe: CGFloat) -> [Handzeichnung] {
        var out = vierecke() + dreiecke() + linien() + runde() + pfeile() + zeichen()
        for i in out.indices {
            let b = bounds(out[i].bahn)
            let f = min(1, maxBreite / max(1, b.width), maxHoehe / max(1, b.height))
            let c = CGPoint(x: b.midX, y: b.midY)
            // mittig, und wenn noetig verkleinert (Soll-Werte: Laengen und Punkte mit, Winkel nicht)
            out[i].bahn = out[i].bahn.map { CGPoint(x: ($0.x - c.x) * f, y: ($0.y - c.y) * f) }
            switch out[i].art {
            case .viereck:
                out[i].soll = [(out[i].soll[0] - c.x) * f, (out[i].soll[1] - c.y) * f, out[i].soll[2] * f, out[i].soll[3] * f, out[i].soll[4]]
            case .rund:
                out[i].soll = [(out[i].soll[0] - c.x) * f, (out[i].soll[1] - c.y) * f, out[i].soll[2] * f, out[i].soll[3] * f]
            default:
                out[i].soll = out[i].soll.enumerated().map { ($0.element - ($0.offset % 2 == 0 ? c.x : c.y)) * f }
            }
        }
        return out
    }

    /// Mitte, mittlere Laenge gegenueberliegender Seiten und Lage (Grad, -45 ... 45) eines Vierecks mit vier Ecken
    static func lage(_ v: [CGPoint]) -> [CGFloat] {
        let cx = v.reduce(0) { $0 + $1.x } / 4, cy = v.reduce(0) { $0 + $1.y } / 4
        var c4: CGFloat = 0, s4: CGFloat = 0
        for i in 0..<4 {
            let a = v[i], b = v[(i + 1) % 4]
            let t = atan2(b.y - a.y, b.x - a.x)
            c4 += dist(a, b) * cos(4 * t)
            s4 += dist(a, b) * sin(4 * t)
        }
        return [cx, cy, (dist(v[0], v[1]) + dist(v[2], v[3])) / 2, (dist(v[1], v[2]) + dist(v[3], v[0])) / 2, atan2(s4, c4) / 4 * 180 / .pi]
    }

    /// 72 Vierecke: 4 Groessen x 3 Schluesse x Start an der Ecke / mitten auf der Seite x 3 Fassungen
    static func vierecke() -> [Handzeichnung] {
        var out: [Handzeichnung] = []
        var n: UInt64 = 0
        for g in groessen {
            for s in schluesse {
                for mitte in [false, true] {
                    for fassung in 0..<3 {
                        n += 1
                        var z = Zufall(1000 + n)
                        let seiten = z.pick([1.0, 1.25, 1.6, 2.2] as [CGFloat])
                        let w = g, h = g / seiten
                        let schraeg = z.pick([0, 0, 3, -4, 8, 15, 20, -15] as [CGFloat])
                        let schief = z.pick([0.02, 0.04, 0.07] as [CGFloat]) * (w * h).squareRoot()
                        let radius = min(z.pick([3, 6, 10, 14] as [CGFloat]), h / 4)
                        let uhr = z.unit() < 0.5
                        var v = [CGPoint(x: -w / 2, y: -h / 2), CGPoint(x: w / 2, y: -h / 2), CGPoint(x: w / 2, y: h / 2), CGPoint(x: -w / 2, y: h / 2)]
                        v = v.map { CGPoint(x: $0.x + z.pm(schief), y: $0.y + z.pm(schief)) }.map { rotate($0, schraeg) }
                        // was die Hand damit wirklich meint (die Ecken sind verwackelt): Mitte, Seiten, Lage
                        let ist = lage(v)
                        if !uhr { v.reverse() }
                        let first = Int(z.next() % 4)
                        v = Array(v[first...] + v[..<first])
                        let start: CGFloat = mitte ? z.between(0.3, 0.7) : 0
                        let schluss = z.between(s.von, s.bis)
                        let bauch = (0..<4).map { z.pm(0.03 * dist(v[$0], v[($0 + 1) % 4])) }
                        let dense = gebogen(umlauf(v, start: start, schluss: schluss, radius: radius), ecken: v, bauch: bauch)
                        let zittern = min(z.pick([1, 2, 3] as [CGFloat]), g / 25)
                        let drift = CGPoint(x: z.pm(max(1.5, 0.03 * h)), y: z.pm(max(1.5, 0.03 * h)))
                        let k = 20 + Int(z.next() % 21)
                        var c = Handzeichnung(name: String(format: "Viereck %.0f pt (%.0f x %.0f), Start %@, Schluss %@ %+.0f %%, %.0f°, Radius %.0f, %@, Zittern %.0f, Fassung %d",
                                                           g, w, h, mitte ? "Seitenmitte" : "Ecke", s.name, schluss * 100, schraeg, radius,
                                                           uhr ? "im Uhrzeigersinn" : "gegen den Uhrzeigersinn", zittern, fassung + 1),
                                              art: .viereck, erlaubt: ["rectangle", "square"])
                        c.merkmale = ["Größe": String(format: "%.0f pt", g), "Start": mitte ? "Seitenmitte" : "Ecke", "Schluss": s.name,
                                      "Schräglage": abs(schraeg) <= 4 ? "bis 4°" : abs(schraeg) < 15 ? "8°" : "ab 15°"]
                        c.soll = ist
                        c.bahn = hand(dense, abstand: abstand(fuer: g), zittern: zittern, drift: drift, knaeuel: k, &z)
                        c.knaeuel = k
                        out.append(c)
                    }
                }
            }
        }
        return out
    }

    /// 48 Dreiecke: 4 Groessen x 3 Schluesse x Start Ecke / Seitenmitte x 2 Fassungen; gleichseitig, rechtwinklig,
    /// spitz (Spitze um 28 Grad) und stumpf (Spitze um 115 Grad)
    static func dreiecke() -> [Handzeichnung] {
        var out: [Handzeichnung] = []
        var n: UInt64 = 0
        for g in groessen {
            for s in schluesse {
                for mitte in [false, true] {
                    for fassung in 0..<2 {
                        n += 1
                        var z = Zufall(2000 + n)
                        let sorte = Int(n % 4)
                        var v: [CGPoint]
                        let sorteName: String
                        switch sorte {
                        case 0: v = [CGPoint(x: -g / 2, y: 0.43 * g), CGPoint(x: 0, y: -0.43 * g), CGPoint(x: g / 2, y: 0.43 * g)]; sorteName = "gleichseitig"
                        case 1: v = [CGPoint(x: -g / 2, y: 0.35 * g), CGPoint(x: -g / 2, y: -0.35 * g), CGPoint(x: g / 2, y: 0.35 * g)]; sorteName = "rechtwinklig"
                        case 2: v = [CGPoint(x: -g / 4, y: g / 2), CGPoint(x: 0, y: -g / 2), CGPoint(x: g / 4, y: g / 2)]; sorteName = "spitz"
                        default: v = [CGPoint(x: -g / 2, y: 0.16 * g), CGPoint(x: 0, y: -0.16 * g), CGPoint(x: g / 2, y: 0.16 * g)]; sorteName = "stumpf"
                        }
                        let dreh = z.pick([0, 0, 5, -8, 15, 180, 90, 200] as [CGFloat])
                        let schief = z.pick([0.02, 0.04] as [CGFloat]) * g
                        v = v.map { CGPoint(x: $0.x + z.pm(schief), y: $0.y + z.pm(schief)) }.map { rotate($0, dreh) }
                        let uhr = z.unit() < 0.5
                        if !uhr { v.reverse() }
                        let first = Int(z.next() % 3)
                        v = Array(v[first...] + v[..<first])
                        let kurz = (0..<3).map { dist(v[$0], v[($0 + 1) % 3]) }.min() ?? g
                        let radius = min(z.pick([3, 6, 10, 14] as [CGFloat]), kurz / 5)
                        let start: CGFloat = mitte ? z.between(0.3, 0.7) : 0
                        let schluss = z.between(s.von, s.bis)
                        let bauch = (0..<3).map { z.pm(0.03 * dist(v[$0], v[($0 + 1) % 3])) }
                        let dense = gebogen(umlauf(v, start: start, schluss: schluss, radius: radius), ecken: v, bauch: bauch)
                        let zittern = min(z.pick([1, 2, 3] as [CGFloat]), g / 25)
                        let drift = CGPoint(x: z.pm(max(1.5, 0.02 * g)), y: z.pm(max(1.5, 0.02 * g)))
                        let k = 20 + Int(z.next() % 21)
                        var c = Handzeichnung(name: String(format: "Dreieck %.0f pt, %@, Start %@, Schluss %@ %+.0f %%, gedreht %.0f°, Radius %.0f, %@, Zittern %.0f",
                                                           g, sorteName, mitte ? "Seitenmitte" : "Ecke", s.name, schluss * 100, dreh, radius,
                                                           uhr ? "im Uhrzeigersinn" : "gegen den Uhrzeigersinn", zittern),
                                              art: .dreieck, erlaubt: ["triangle"])
                        c.merkmale = ["Größe": String(format: "%.0f pt", g), "Start": mitte ? "Seitenmitte" : "Ecke", "Schluss": s.name, "Sorte": sorteName]
                        c.soll = v.flatMap { [$0.x, $0.y] }
                        c.bahn = hand(dense, abstand: abstand(fuer: g), zittern: zittern, drift: drift, knaeuel: k, &z)
                        c.knaeuel = k
                        out.append(c)
                    }
                }
            }
        }
        return out
    }

    /// Laengen der Linien: die kuerzeste 35 pt statt 25 pt - unter 30 pt (`ShapeRecognizer.minimumLength`) wird ein
    /// Strich mit Absicht nie zur Linie (Gedankenstrich, "l", "1" beim Schreiben)
    static let linienLaengen: [CGFloat] = [35, 60, 150, 400]

    /// 40 Linien: 4 Laengen x 10 Richtungen (waagerecht, fast waagerecht, schraeg, senkrecht, rueckwaerts)
    static func linien() -> [Handzeichnung] {
        var out: [Handzeichnung] = []
        var n: UInt64 = 0
        let winkel: [CGFloat] = [0, 3, -4, 12, 30, 45, 70, 88, 90, 183]
        for g in linienLaengen {
            for w in winkel {
                n += 1
                var z = Zufall(3000 + n)
                let a = rotate(CGPoint(x: -g / 2, y: 0), w), b = rotate(CGPoint(x: g / 2, y: 0), w)
                // leichter Bauch (bis 1,5 % der Laenge)
                let bauch = z.pm(0.015 * g)
                let nx = -(b.y - a.y) / g, ny = (b.x - a.x) / g
                let steps = max(2, Int(g / 0.5))
                let dense = (0...steps).map { i -> CGPoint in
                    let u = CGFloat(i) / CGFloat(steps)
                    let p = lerp(a, b, u)
                    return CGPoint(x: p.x + nx * sin(u * .pi) * bauch, y: p.y + ny * sin(u * .pi) * bauch)
                }
                let zittern = min(z.pick([0.5, 1, 2] as [CGFloat]), g / 30)
                let k = 20 + Int(z.next() % 21)
                var c = Handzeichnung(name: String(format: "Linie %.0f pt, %.0f°, Zittern %.1f", g, w, zittern), art: .linie, erlaubt: ["line"])
                c.merkmale = ["Größe": String(format: "%.0f pt", g)]
                c.bahn = hand(dense, abstand: abstand(fuer: g), zittern: zittern, drift: .zero, knaeuel: k, &z)
                c.knaeuel = k
                // gemeint ist die Linie von der ersten Beruehrung bis zum Absetzen (Mitte des Knaeuels)
                let first = c.bahn[0], last = c.bahn[c.bahn.count - 1 - k]
                c.soll = [first.x, first.y, last.x, last.y]
                out.append(c)
            }
        }
        return out
    }

    /// 24 Kreise und Ellipsen: 4 Groessen x 3 Schluesse x 2 Fassungen
    static func runde() -> [Handzeichnung] {
        var out: [Handzeichnung] = []
        var n: UInt64 = 0
        for g in groessen {
            for s in schluesse {
                for fassung in 0..<2 {
                    n += 1
                    var z = Zufall(4000 + n)
                    let seiten: CGFloat = fassung == 0 ? z.pick([1.0, 1.05]) : z.pick([1.5, 2.2])
                    let rx = g / 2, ry = g / 2 / seiten
                    let von = z.between(0, 360)
                    let richtung: CGFloat = z.unit() < 0.5 ? 1 : -1
                    let schluss = z.between(s.von, s.bis) * 0.5                     // Anteil des Umfangs: bis 7,5 %
                    let dense = bogen(.zero, rx, ry, von: von, bis: von + richtung * 360 * (1 + schluss))
                    let fein = ShapeFein.dicht(dense)
                    let zittern = min(z.pick([1, 2] as [CGFloat]), g / 25)
                    let drift = CGPoint(x: z.pm(max(1.5, 0.03 * ry)), y: z.pm(max(1.5, 0.03 * ry)))
                    let k = 20 + Int(z.next() % 21)
                    var c = Handzeichnung(name: String(format: "%@ %.0f pt (%.0f x %.0f), Schluss %@ %+.0f %%", seiten <= 1.05 ? "Kreis" : "Ellipse", g, 2 * rx, 2 * ry,
                                                       s.name, schluss * 100),
                                          art: .rund, erlaubt: seiten <= 1.05 ? ["circle", "ellipse"] : ["ellipse"])
                    c.merkmale = ["Größe": String(format: "%.0f pt", g), "Schluss": s.name]
                    c.soll = [0, 0, rx, ry]
                    c.bahn = hand(fein, abstand: abstand(fuer: g), zittern: zittern, drift: drift, knaeuel: k, &z)
                    c.knaeuel = k
                    out.append(c)
                }
            }
        }
        return out
    }

    /// 12 Pfeile: 3 Laengen x 2 Richtungen x Spitze als "V" / als Haken
    static func pfeile() -> [Handzeichnung] {
        var out: [Handzeichnung] = []
        var n: UInt64 = 0
        for g in [60, 150, 400] as [CGFloat] {
            for w in [0, -60] as [CGFloat] {
                for haken in [false, true] {
                    n += 1
                    var z = Zufall(5000 + n)
                    let a = CGPoint(x: -g / 2, y: 0), tip = CGPoint(x: g / 2, y: 0)
                    let kopf = min(30, max(12, 0.18 * g))
                    let l = CGPoint(x: tip.x - kopf * cos(.pi / 5), y: tip.y - kopf * sin(.pi / 5))
                    let r = CGPoint(x: tip.x - kopf * cos(.pi / 5), y: tip.y + kopf * sin(.pi / 5))
                    let v = (haken ? [a, tip, l] : [a, tip, l, tip, r]).map { rotate($0, w) }
                    let dense = rund(v, radius: 1.5)
                    let zittern = min(1, g / 60)
                    let k = 20 + Int(z.next() % 21)
                    var c = Handzeichnung(name: String(format: "Pfeil %.0f pt, %.0f°, Spitze %@", g, w, haken ? "als Haken" : "als V"), art: .pfeil, erlaubt: ["arrow"])
                    c.merkmale = ["Größe": String(format: "%.0f pt", g)]
                    c.bahn = hand(dense, abstand: abstand(fuer: g), zittern: zittern, drift: .zero, knaeuel: k, &z)
                    c.knaeuel = k
                    let first = c.bahn[0], t = rotate(tip, w)
                    c.soll = [first.x, first.y, t.x, t.y]
                    out.append(c)
                }
            }
        }
        return out
    }

    /// Buchstaben und Zeichen in einem Zug (Einheitskasten: Hoehe 1, y nach unten), je in drei Schriftgroessen und am
    /// Ende gehalten. Erlaubt ist nur beim "O" und bei der "0" ein Kreis bzw. eine Ellipse: Ein gehaltenes O IST ein Kreis.
    static func zeichen() -> [Handzeichnung] {
        typealias P = CGPoint
        func p(_ x: CGFloat, _ y: CGFloat) -> P { P(x: x, y: y) }
        /// (Name, Bahn dicht oder Ecken, Ecken runden?, erlaubt)
        var glyphen: [(String, [P], Bool, [String])] = []
        glyphen.append(("O", bogen(p(0.36, 0.5), 0.36, 0.5, von: -90, bis: -90 - 385), false, ["circle", "ellipse", "-"]))
        glyphen.append(("0", bogen(p(0.26, 0.5), 0.26, 0.5, von: -80, bis: -80 - 380), false, ["circle", "ellipse", "-"]))
        glyphen.append(("D", [p(0, 0), p(0, 1)] + bogen(p(0, 0.5), 0.55, 0.5, von: 90, bis: -90), false, ["-"]))
        glyphen.append(("U", [p(0, 0), p(0, 0.6)] + bogen(p(0.3, 0.6), 0.3, 0.4, von: 180, bis: 0) + [p(0.6, 0)], false, ["-"]))
        glyphen.append(("V", [p(0, 0), p(0.3, 1), p(0.6, 0)], true, ["-"]))
        glyphen.append(("L", [p(0, 0), p(0, 1), p(0.55, 1)], true, ["-"]))
        glyphen.append(("Z", [p(0, 0), p(0.6, 0), p(0, 1), p(0.6, 1)], true, ["-"]))
        glyphen.append(("N", [p(0, 1), p(0, 0), p(0.6, 1), p(0.6, 0)], true, ["-"]))
        glyphen.append(("M", [p(0, 1), p(0, 0), p(0.35, 0.6), p(0.7, 0), p(0.7, 1)], true, ["-"]))
        glyphen.append(("7", [p(0, 0), p(0.55, 0), p(0.2, 1)], true, ["-"]))
        glyphen.append(("1", [p(0, 0.35), p(0.3, 0), p(0.3, 1)], true, ["-"]))
        glyphen.append(("Häkchen", [p(0, 0.55), p(0.3, 1), p(1.0, 0)], true, ["-"]))
        glyphen.append(("Unterstreichung hin und zurück", [p(0, 0), p(3.2, 0.04), p(0.4, 0.3)], true, ["-"]))
        glyphen.append(("Unterstreichung mit Schlaufe", [p(0, 0), p(3.0, 0)] + bogen(p(3.0, -0.22), 0.3, 0.22, von: 90, bis: -200), false, ["-"]))
        glyphen.append(("Wellenlinie", (0...120).map { i in p(CGFloat(i) / 30, 0.25 * sin(CGFloat(i) / 30 * 2 * .pi / 1.3)) }, false, ["-"]))
        glyphen.append(("Pfeilspitze", [p(0, 0), p(0.6, 0.5), p(0, 1)], true, ["-"]))
        glyphen.append(("S", bogen(p(0.3, 0.25), 0.3, 0.25, von: -30, bis: -270) + bogen(p(0.3, 0.75), 0.3, 0.25, von: -90, bis: 150), false, ["-"]))
        glyphen.append(("C", bogen(p(0.35, 0.5), 0.35, 0.5, von: -45, bis: -315), false, ["-"]))
        glyphen.append(("2", bogen(p(0.3, 0.25), 0.3, 0.25, von: 180, bis: 390) + [p(0, 1), p(0.65, 1)], false, ["-"]))
        glyphen.append(("3", bogen(p(0.25, 0.25), 0.3, 0.25, von: -150, bis: 90) + bogen(p(0.25, 0.75), 0.3, 0.25, von: -90, bis: 150), false, ["-"]))
        glyphen.append(("6", bogen(p(0.5, 0.55), 0.45, 0.55, von: -70, bis: -270) + bogen(p(0.5, 0.8), 0.3, 0.3, von: 90, bis: -180), false, ["-"]))
        glyphen.append(("8", (0...90).map { i in
            let u = CGFloat(i) / 90 * 2 * .pi
            return p(0.3 + 0.28 * sin(2 * u), 0.5 - 0.5 * cos(u))
        }, false, ["-"]))
        glyphen.append(("e", [p(0, 0.6), p(0.55, 0.42)] + bogen(p(0.3, 0.5), 0.28, 0.45, von: -15, bis: -300), false, ["-"]))
        glyphen.append(("W", [p(0, 0), p(0.25, 1), p(0.5, 0.3), p(0.75, 1), p(1, 0)], true, ["-"]))
        glyphen.append(("P", [p(0, 1), p(0, 0)] + bogen(p(0, 0.25), 0.5, 0.25, von: -90, bis: 90), false, ["-"]))
        glyphen.append(("eckige Klammer", [p(0.4, 0), p(0, 0), p(0, 1), p(0.4, 1)], true, ["-"]))
        glyphen.append(("Fünfeck", (0...5).map { i in
            let t = CGFloat(i) / 5 * 2 * .pi - .pi / 2
            return p(0.5 + 0.55 * cos(t), 0.5 + 0.55 * sin(t))
        }, true, ["-"]))
        glyphen.append(("Bogen", bogen(p(0.6, 0.6), 0.6, 0.6, von: 180, bis: 360), false, ["-"]))

        var out: [Handzeichnung] = []
        var n: UInt64 = 0
        for g in glyphen {
            for h in [24, 40, 70] as [CGFloat] {
                n += 1
                var z = Zufall(6000 + n)
                let neigung = z.between(0, 0.2)
                let pts = g.1.map { CGPoint(x: ($0.x - neigung * $0.y) * h, y: $0.y * h) }
                let dense = g.2 ? rund(pts, radius: z.between(0.03, 0.08) * h) : ShapeFein.dicht(pts)
                let k = 20 + Int(z.next() % 21)
                var c = Handzeichnung(name: String(format: "%@, %.0f pt hoch", g.0, h), art: .zeichen, erlaubt: g.3)
                c.merkmale = ["Größe": String(format: "%.0f pt", h), "Zeichen": g.0]
                c.bahn = hand(dense, abstand: h <= 30 ? 1.2 : h <= 45 ? 1.8 : 2.5, zittern: min(1, h / 40), drift: .zero, knaeuel: k, &z)
                c.knaeuel = k
                out.append(c)
            }
        }
        return out
    }
}

/// Linienzug dicht abtasten (0,5 pt), damit `Handzeichnung.hand` gleichmaessig darueberfahren kann
enum ShapeFein {
    static func dicht(_ v: [CGPoint]) -> [CGPoint] {
        guard var last = v.first else { return v }
        var out = [last]
        for b in v.dropFirst() {
            let d = Handzeichnung.dist(last, b)
            let n = max(1, Int(d / 0.5))
            for k in 1...n { out.append(Handzeichnung.lerp(last, b, CGFloat(k) / CGFloat(n))) }
            last = b
        }
        return out
    }
}
