import PencilKit
import UIKit
import XCTest
@testable import UniFlow

/// Ein Strich der Messreihe: die Handzeichnung (`Handzeichnung`) und die Kontrollpunkte, die PencilKit aus der echten
/// Beruehrung gemacht hat (Seitenpunkte). Eine Zeile Text je Strich (`FormenKorpusDaten`).
struct KorpusStrich {
    var name: String
    var art: Handzeichnung.Art
    var erlaubt: [String]
    var merkmale: [String: String]
    /// Soll-Werte in Seitenpunkten (siehe `Handzeichnung.soll`)
    var soll: [CGFloat]
    /// Mittlere Punktgroesse und Dauer des Strichs von PencilKit
    var breite: CGFloat
    var dauer: Double
    /// Kontrollpunkte von PencilKit
    var punkte: [CGPoint]

    var zeile: String {
        func n(_ v: CGFloat) -> String { String(Int((v * 10).rounded())) }
        return [name, art.rawValue, erlaubt.joined(separator: "/"),
                merkmale.keys.sorted().map { "\($0)=\(merkmale[$0] ?? "")" }.joined(separator: ";"),
                soll.map(n).joined(separator: ","), String(Int((breite * 100).rounded())), String(Int((dauer * 1000).rounded())),
                punkte.map { n($0.x) + "," + n($0.y) }.joined(separator: ";")].joined(separator: "\t")
    }

    init?(zeile: String) {
        let f = zeile.components(separatedBy: "\t")
        guard f.count == 8, let art = Handzeichnung.Art(rawValue: f[1]) else { return nil }
        name = f[0]
        self.art = art
        erlaubt = f[2].components(separatedBy: "/")
        merkmale = [:]
        for pair in f[3].components(separatedBy: ";") {
            let kv = pair.components(separatedBy: "=")
            if kv.count == 2 { merkmale[kv[0]] = kv[1] }
        }
        soll = f[4].isEmpty ? [] : f[4].components(separatedBy: ",").map { CGFloat(Double($0) ?? 0) / 10 }
        breite = CGFloat(Double(f[5]) ?? 300) / 100
        dauer = (Double(f[6]) ?? 1000) / 1000
        punkte = f[7].components(separatedBy: ";").compactMap { s in
            let xy = s.components(separatedBy: ",")
            guard xy.count == 2, let x = Double(xy[0]), let y = Double(xy[1]) else { return nil }
            return CGPoint(x: x / 10, y: y / 10)
        }
    }

    init(_ fall: Handzeichnung, soll: [CGFloat], stroke: PKStroke) {
        name = fall.name
        art = fall.art
        erlaubt = fall.erlaubt
        merkmale = fall.merkmale
        self.soll = soll
        let path = stroke.path
        let widths = (0..<path.count).map { path[$0].size.width }.sorted()
        breite = widths.isEmpty ? 3 : widths[widths.count / 2]
        dauer = path.count > 0 ? path[path.count - 1].timeOffset : 0
        punkte = (0..<path.count).map { path[$0].location.applying(stroke.transform) }
    }

    /// Der Strich, wie PencilKit ihn geliefert hat (gleiche Kontrollpunkte, gleichmaessige Breite)
    func stroke(_ ink: PKInk = PKInk(.pen, color: .black), breite width: CGFloat? = nil) -> PKStroke {
        let w = width ?? breite
        let n = punkte.count
        let pts = punkte.enumerated().map { i, p in
            PKStrokePoint(location: p, timeOffset: dauer * Double(i) / Double(max(1, n - 1)), size: CGSize(width: w, height: w), opacity: 1,
                          force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: pts, creationDate: Date(timeIntervalSinceReferenceDate: 800_000_000)))
    }

    /// Punkte so, wie die Erkennung sie bekommt (`PDFEditorController.snapShape`)
    var erkennungspunkte: [CGPoint] { stroke().path.interpolatedPoints(by: .distance(2)).map(\.location) }

    static let alle: [KorpusStrich] = FormenKorpusDaten.text.components(separatedBy: "\n").compactMap(KorpusStrich.init(zeile:))
}

/// Formerkennung mit Strichen aus echter Beruehrung (PencilKit hat sie selbst geglaettet): Vierecke, Dreiecke und
/// Linien von Hand - mit Luecke oder doppelt gezogenem Schluss, Start mitten auf der Seite, runden Ecken, schief,
/// klein und gross, mit Halte-Knaeuel am Ende. Dazu Buchstaben und Zeichen, die keine Form werden duerfen.
/// Zeilen "[Formen]" im Testprotokoll sind die Messwerte.
@MainActor
final class FormenHandzeichnungTests: XCTestCase {

    struct Zaehlung {
        var gesamt = 0
        var richtig = 0
        var ergebnisse: [String: Int] = [:]
        var fehler: [String] = []
    }

    static func name(_ shape: ShapeRecognizer.Shape?) -> String { shape?.name ?? "-" }

    static func zaehle(_ striche: [KorpusStrich]) -> [Handzeichnung.Art: Zaehlung] {
        var out: [Handzeichnung.Art: Zaehlung] = [:]
        for s in striche {
            let got = name(ShapeRecognizer.recognize(s.erkennungspunkte))
            var z = out[s.art] ?? Zaehlung()
            z.gesamt += 1
            z.ergebnisse[got, default: 0] += 1
            if s.erlaubt.contains(got) { z.richtig += 1 } else { z.fehler.append("\(s.name) -> \(got)") }
            out[s.art] = z
        }
        return out
    }

    /// Aufschluesselung der Treffer nach einem Merkmal ("Schluss": Luecke 20/24, genau 24/24, doppelt 3/24)
    static func nachMerkmal(_ striche: [KorpusStrich], _ key: String) -> String {
        var hit: [String: Int] = [:], all: [String: Int] = [:]
        for s in striche {
            guard let v = s.merkmale[key] else { continue }
            all[v, default: 0] += 1
            if s.erlaubt.contains(name(ShapeRecognizer.recognize(s.erkennungspunkte))) { hit[v, default: 0] += 1 }
        }
        return key + ": " + all.keys.sorted().map { "\($0) \(hit[$0] ?? 0)/\(all[$0] ?? 0)" }.joined(separator: ", ")
    }

    func testKorpusIstVollstaendig() {
        let all = KorpusStrich.alle
        func count(_ a: Handzeichnung.Art) -> Int { all.filter { $0.art == a }.count }
        XCTAssertEqual(count(.viereck), 72)
        XCTAssertEqual(count(.dreieck), 48)
        XCTAssertEqual(count(.linie), 40)
        XCTAssertEqual(count(.rund), 24)
        XCTAssertEqual(count(.pfeil), 12)
        XCTAssertEqual(count(.zeichen), 84)
        XCTAssertTrue(all.allSatisfy { $0.punkte.count >= 4 })
    }

    /// Die Zaehlung: Wie viele Vierecke, Dreiecke, Linien (und Kreise, Pfeile) werden erkannt, wie viele Buchstaben
    /// faelschlich zu einer Form
    func testHandgezeichneteFormenWerdenErkanntUndSchriftBleibt() {
        let all = KorpusStrich.alle
        let z = Self.zaehle(all)
        var report: [String] = []
        for art in Handzeichnung.Art.allCases {
            guard let c = z[art] else { continue }
            let results = c.ergebnisse.keys.sorted().map { "\($0)×\(c.ergebnisse[$0] ?? 0)" }.joined(separator: " ")
            if art == .zeichen {
                report.append("\(art.rawValue): \(c.gesamt - c.richtig) von \(c.gesamt) faelschlich zur Form (\(results))")
            } else {
                report.append("\(art.rawValue): \(c.richtig) von \(c.gesamt) erkannt (\(results))")
            }
            if art == .viereck || art == .dreieck {
                let own = all.filter { $0.art == art }
                for key in ["Größe", "Start", "Schluss"] + (art == .dreieck ? ["Sorte"] : ["Schräglage"]) { report.append("   " + Self.nachMerkmal(own, key)) }
            }
            for f in c.fehler.prefix(40) { report.append("   nicht wie erwartet: " + f) }
        }
        print("[Formen] Striche aus echter Beruehrung (PencilKit im Simulator), am Ende gehalten:\n  " + report.joined(separator: "\n  "))
        // Was fehlen darf, sind nur die kleinsten Formen (25 pt, etwa 9 mm): Dort ist die Rundung der Ecken so gross wie
        // die Seite selbst, und unter 18 pt (`ShapeRecognizer.minimumSize`) wird mit Absicht nichts zur Form.
        for (art, least) in Self.mindestens {
            let c = z[art] ?? Zaehlung()
            XCTAssertGreaterThanOrEqual(c.richtig, least, "\(art.rawValue): \(c.richtig) von \(c.gesamt) erkannt, nicht wie erwartet: \(c.fehler)")
        }
        for f in (z[.viereck]?.fehler ?? []) + (z[.dreieck]?.fehler ?? []) + (z[.rund]?.fehler ?? []) {
            XCTAssertTrue(f.contains(" 25 pt"), "nur bei 25 pt darf eine Form unerkannt bleiben: \(f)")
        }
        XCTAssertEqual(z[.zeichen]?.richtig, z[.zeichen]?.gesamt, "Buchstaben und Zeichen bleiben Handschrift: \(z[.zeichen]?.fehler ?? [])")
    }

    /// So viele muessen mindestens erkannt werden (Stand der Aufnahme in `FormenKorpusDaten`)
    static let mindestens: [(Handzeichnung.Art, Int)] = [(.viereck, 70), (.dreieck, 46), (.linie, 40), (.rund, 22), (.pfeil, 12)]

    // MARK: Staerkere Glaettung, wie vom iPad berichtet

    /// Am iPad mit Apple Pencil kommen die Ecken staerker gerundet an als im Simulator (ueber 10 bis 20 pt verteilt,
    /// `ShapeSnapDeviceTests`). Das laesst sich hier nicht aufnehmen, aber nachstellen: Von jeder Handzeichnung wird nur
    /// jeder k-te Beruehrungspunkt Kontrollpunkt der Kurve (Abstand `abstand` pt) - je groesser der Abstand, desto
    /// runder die Ecken.
    static func geglaettet(_ h: Handzeichnung, abstand: CGFloat) -> [CGPoint] {
        let moving = h.bahn.count - h.knaeuel
        let spacing = max(0.5, ShapeRecognizer.pathLength(Array(h.bahn[..<moving])) / CGFloat(max(1, moving - 1)))
        let k = max(1, Int((abstand / spacing).rounded()))
        var control: [CGPoint] = []
        var i = 0
        while i < moving { control.append(h.bahn[i]); i += k }
        if control.last != h.bahn[moving - 1] { control.append(h.bahn[moving - 1]) }
        i = moving
        while i < h.bahn.count { control.append(h.bahn[i]); i += 3 }
        let n = control.count
        let points = control.enumerated().map { j, p in
            PKStrokePoint(location: p, timeOffset: Double(j) / Double(max(1, n - 1)), size: CGSize(width: 3, height: 3), opacity: 1, force: 1,
                          azimuth: 0, altitude: .pi / 2)
        }
        return PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSinceReferenceDate: 800_000_000))
            .interpolatedPoints(by: .distance(2)).map(\.location)
    }

    /// Mit Glaettung ueber 6, 9 und 12 pt: Vierecke und Dreiecke ab 150 pt werden alle erkannt, bei 60 pt fast alle.
    /// Bei 25 pt bleibt von den Ecken nichts uebrig (eine Seite hat dann zwei, drei Kontrollpunkte): Das kann keine
    /// Erkennung retten, die Zahlen stehen im Protokoll. Die Zeichen aus der Liste des Inhabers bleiben Handschrift.
    func testFormenMitStaerkererGlaettungWieAmGeraet() {
        let faelle = Handzeichnung.alle(maxBreite: 547, maxHoehe: 381)
        var report: [String] = []
        for abstand in [6, 9, 12] as [CGFloat] {
            var hit: [String: Int] = [:], total: [String: Int] = [:]
            var wrongSigns: [String] = []
            for h in faelle {
                let got = Self.name(ShapeRecognizer.recognize(Self.geglaettet(h, abstand: abstand)))
                let size = h.merkmale["Größe"] ?? ""
                let key = h.art == .viereck || h.art == .dreieck ? "\(h.art.rawValue) \(size)" : h.art.rawValue
                total[key, default: 0] += 1
                let ok = h.erlaubt.contains(got)
                if ok { hit[key, default: 0] += 1 }
                if h.art == .zeichen, !ok { wrongSigns.append("\(h.name) -> \(got)") }
                if (h.art == .viereck || h.art == .dreieck), size == "150 pt" || size == "400 pt" {
                    XCTAssertTrue(ok, "Glaettung \(abstand) pt: \(h.name) wurde \(got)")
                }
                if h.art == .linie { XCTAssertTrue(ok, "Glaettung \(abstand) pt: \(h.name) wurde \(got)") }
                // Zeichen aus der Liste des Inhabers in Schreibgroesse 40 und 70 pt (bei 12 pt Glaettung ist die Wellenlinie
                // selbst fast gerade: dort nur Protokoll)
                if h.art == .zeichen, abstand <= 9, size != "24 pt", h.merkmale["Zeichen"] != "Fünfeck" {
                    XCTAssertTrue(ok, "Glaettung \(abstand) pt: \(h.name) wurde \(got)")
                }
            }
            // 60 pt: von 18 Vierecken mindestens 16 (bei 12 pt Glaettung 12), von 12 Dreiecken mindestens 10 (8).
            // Vorher (Stand bis 17.11.2026, gleiche Striche): Vierecke 12 / 8 / 2, Dreiecke 9 / 7 / 5 - und auch bei
            // 150 und 400 pt nur 12 bis 13 von 18 Vierecken und 8 bis 9 von 12 Dreiecken.
            XCTAssertGreaterThanOrEqual(hit["Viereck 60 pt", default: 0], abstand <= 9 ? 16 : 12, "Glaettung \(abstand) pt: Vierecke 60 pt")
            XCTAssertGreaterThanOrEqual(hit["Dreieck 60 pt", default: 0], abstand <= 9 ? 10 : 8, "Glaettung \(abstand) pt: Dreiecke 60 pt")
            let keys = total.keys.sorted()
            report.append("Glaettung \(Int(abstand)) pt: " + keys.map { "\($0) \(hit[$0] ?? 0)/\(total[$0] ?? 0)" }.joined(separator: ", "))
            if !wrongSigns.isEmpty { report.append("   Zeichen faelschlich zur Form: " + wrongSigns.joined(separator: "; ")) }
        }
        print("[Formen] Dieselben Handzeichnungen mit staerkerer Glaettung (wie am iPad berichtet):\n  " + report.joined(separator: "\n  "))
    }

    // MARK: Guete der Form

    /// Abstand zwischen zwei Winkeln eines Rechtecks in Grad (alle 90 Grad gleich)
    static func winkelAbstand(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        var d = (a - b).truncatingRemainder(dividingBy: 90)
        if d > 45 { d -= 90 }
        if d < -45 { d += 90 }
        return abs(d)
    }

    /// Das Rechteck sitzt, wo gezeichnet wurde: Mitte, Seitenlaengen, Lage. Achsparallel, wenn nahezu waagerecht
    /// gezeichnet; Quadrat nur bei nahezu gleichen Seiten.
    func testRechteckSitztWoGezeichnetWurde() {
        var report: [String] = []
        var worstCenter: CGFloat = 0, worstSide: CGFloat = 0, worstAngle: CGFloat = 0
        var squares = 0, squaresMeant = 0, axis = 0, axisMeant = 0, found = 0
        for s in KorpusStrich.alle where s.art == .viereck {
            guard case .rectangle(let c, let size, let angle)? = ShapeRecognizer.recognize(s.erkennungspunkte) else { continue }
            found += 1
            let w = s.soll[2], h = s.soll[3], tilt = s.soll[4]
            let centerError = hypot(c.x - s.soll[0], c.y - s.soll[1])
            // Seiten: die laengere mit der laengeren vergleichen (das Rechteck darf um 90 Grad anders benannt sein)
            let sideError = max(abs(max(size.width, size.height) - max(w, h)), abs(min(size.width, size.height) - min(w, h)))
            let tolerance = max(4, 0.08 * max(w, h))
            XCTAssertLessThanOrEqual(centerError, tolerance, "\(s.name): Mitte \(centerError) pt daneben")
            XCTAssertLessThanOrEqual(sideError, 1.5 * tolerance, "\(s.name): Seite \(sideError) pt daneben (\(size) statt \(w) x \(h))")
            worstCenter = max(worstCenter, centerError / max(w, h))
            worstSide = max(worstSide, sideError / max(w, h))
            let angleDeg = angle * 180 / .pi
            // `tilt` ist die Lage, wie die Hand sie wirklich gezogen hat (mit verwackelten Ecken). Zwischen 5 und 11 Grad
            // darf beides herauskommen: Eingerastet wird bis 8 Grad gemessener Schraeglage.
            if abs(tilt) <= 5 {
                axisMeant += 1
                if angle == 0 { axis += 1 }
                XCTAssertEqual(angle, 0, "\(s.name): nahezu waagerecht gezeichnet (\(tilt)°) wird achsparallel, war \(angleDeg)°")
            } else if abs(tilt) >= 11, max(w, h) >= 100 {
                // (bei kleinen Formen verdreht schon das Zittern der Hand eine Seite um mehrere Grad: nur Protokoll)
                let d = Self.winkelAbstand(angleDeg, tilt)
                worstAngle = max(worstAngle, d)
                XCTAssertLessThanOrEqual(d, 5, "\(s.name): gedreht gezeichnet (\(tilt)°) bleibt gedreht, war \(angleDeg)°")
            }
            // Quadrat nur bei nahezu gleichen Seiten: gezeichnet bis 5 % Unterschied muss, ab 18 % darf nicht
            let isSquare = abs(size.width - size.height) <= 0.001
            let ratio = max(w, h) / min(w, h)
            if ratio <= 1.05 {
                squaresMeant += 1
                XCTAssertTrue(isSquare, "\(s.name): \(w) x \(h) gezeichnet ist ein Quadrat, wurde \(size)")
            }
            if isSquare { squares += 1 }
            if ratio >= 1.18 { XCTAssertFalse(isSquare, "\(s.name): \(w) x \(h) ist kein Quadrat") }
        }
        report.append("Rechtecke: \(found); Mitte hoechstens \(Self.prozent(worstCenter)) der Groesse daneben, Seiten hoechstens \(Self.prozent(worstSide))")
        report.append("nahezu waagerecht gezeichnet (bis 5°): \(axis) von \(axisMeant) achsparallel; gedreht gezeichnet (ab 11°): Lage hoechstens \(String(format: "%.1f", worstAngle))° daneben")
        report.append("fast gleiche Seiten gezeichnet (bis 5 % Unterschied): \(squaresMeant); zum Quadrat geworden insgesamt: \(squares)")
        print("[Formen] Guete Rechteck:\n  " + report.joined(separator: "\n  "))
    }

    static func prozent(_ v: CGFloat) -> String { String(format: "%.1f %%", v * 100) }

    /// Die Ecken des Dreiecks liegen dort, wo die gezeichneten Seiten sich treffen (nicht innen auf der Rundung)
    func testDreieckEckenSitzenWoGezeichnetWurde() {
        var worst: CGFloat = 0, sum: CGFloat = 0, n = 0
        for s in KorpusStrich.alle where s.art == .dreieck {
            guard case .triangle(let a, let b, let c)? = ShapeRecognizer.recognize(s.erkennungspunkte) else { continue }
            let want = [CGPoint(x: s.soll[0], y: s.soll[1]), CGPoint(x: s.soll[2], y: s.soll[3]), CGPoint(x: s.soll[4], y: s.soll[5])]
            let size = max(ShapeRecognizer.bounds(want).width, ShapeRecognizer.bounds(want).height)
            for w in want {
                let d = [a, b, c].map { hypot($0.x - w.x, $0.y - w.y) }.min() ?? 0
                worst = max(worst, d / size)
                sum += d / size
                n += 1
                XCTAssertLessThanOrEqual(d, max(6, 0.15 * size), "\(s.name): Ecke \(d) pt daneben")
            }
        }
        print("[Formen] Guete Dreieck: \(n / 3) Dreiecke, Ecken im Mittel \(Self.prozent(n > 0 ? sum / CGFloat(n) : 0)) der Groesse daneben, hoechstens \(Self.prozent(worst))")
    }

    // MARK: Laenge der Linie

    struct Laengen {
        var gezeichnet: CGFloat = 0
        var ideal: CGFloat = 0
        /// Abstand der idealen Enden vom gezeichneten Anfang bzw. aeussersten Punkt
        var anfang: CGFloat = 0
        var ende: CGFloat = 0
    }

    /// Gezeichnete Linie gegen die ideale Linie. "Gezeichnet" ist der Strich, wie PencilKit ihn auf dem Bildschirm hatte:
    /// von seinem ersten Punkt bis zum aeussersten Punkt in Strichrichtung (das Halte-Knaeuel am Ende eingeschlossen).
    static func laengen(_ s: KorpusStrich) -> Laengen? {
        let pts = s.erkennungspunkte
        guard case .line(let a, let b)? = ShapeRecognizer.recognize(pts), let first = pts.first else { return nil }
        guard let far = pts.max(by: { hypot($0.x - first.x, $0.y - first.y) < hypot($1.x - first.x, $1.y - first.y) }) else { return nil }
        let reach = hypot(far.x - first.x, far.y - first.y)
        guard reach > 0 else { return nil }
        let ux = (far.x - first.x) / reach, uy = (far.y - first.y) / reach
        let along = pts.map { ($0.x - first.x) * ux + ($0.y - first.y) * uy }
        let drawn = (along.max() ?? 0) - (along.min() ?? 0)
        return Laengen(gezeichnet: drawn, ideal: hypot(b.x - a.x, b.y - a.y), anfang: hypot(a.x - first.x, a.y - first.y),
                       ende: hypot(b.x - far.x, b.y - far.y))
    }

    /// "Gerader Strich wird kuerzer": Die ideale Linie reicht vom Anfang bis zum Ende des gezeichneten Strichs
    func testLinieIstSoLangWieGezeichnet() {
        var report: [String] = []
        for g in Handzeichnung.linienLaengen {
            let own = KorpusStrich.alle.filter { $0.art == .linie && $0.merkmale["Größe"] == String(format: "%.0f pt", g) }
            let l = own.compactMap(Self.laengen)
            guard !l.isEmpty else { report.append(String(format: "%.0f pt: keine Linie erkannt", g)); continue }
            let ratio = l.map { $0.ideal / $0.gezeichnet }.reduce(0, +) / CGFloat(l.count)
            let short = l.map { $0.gezeichnet - $0.ideal }
            report.append(String(format: "%.0f pt (%d von %d Linien erkannt): Laenge ideal/gezeichnet im Mittel %.3f; kuerzer um %.1f pt im Mittel, hoechstens %.1f pt",
                                 g, l.count, own.count, ratio, short.reduce(0, +) / CGFloat(l.count), short.max() ?? 0))
            XCTAssertEqual(l.count, own.count, "\(g) pt: jede Linie erkannt")
            for (s, x) in zip(own, l) {
                XCTAssertEqual(x.ideal, x.gezeichnet, accuracy: 1, "\(s.name): \(x.ideal) statt \(x.gezeichnet) pt lang")
                // waagerecht/senkrecht eingerastet dreht die Linie (bis 5 Grad): dann wandern die Enden quer
                XCTAssertLessThanOrEqual(x.anfang, max(1.5, 0.05 * x.gezeichnet), "\(s.name): Anfang \(x.anfang) pt daneben")
            }
        }
        print("[Formen] Laenge der Linie (gezeichneter Strich von PencilKit gegen die ideale Linie):\n  " + report.joined(separator: "\n  "))
    }

    /// Sichtbare Laenge und Dicke an den Enden, in jeder Tinte: die ideale Linie als Bild von PencilKit, gemessen wird
    /// die Tinte selbst. Erwartet: Die Tinte reicht an beiden Enden bis zum Endpunkt (plus halbe Strichbreite fuer die
    /// runde Kappe), und kurz vor dem Ende ist der Strich so dick wie in der Mitte.
    func testIdealeLinieIstInJederTinteBisZumEndeGleichDick() throws {
        let line = try XCTUnwrap(KorpusStrich.alle.first { $0.art == .linie && $0.name.hasPrefix("Linie 150 pt, 0°") })
        var report: [String] = []
        let inks: [(String, PKInkingTool.InkType, CGFloat)] = [("Stift", .pen, 2), ("Stift breit", .pen, 6), ("Fineliner", .monoline, 2),
                                                                ("Fineliner breit", .monoline, 5), ("Füller", .fountainPen, 4), ("Bleistift", .pencil, 3),
                                                                ("Textmarker", .marker, 12)]
        for (name, type, width) in inks {
            let original = line.stroke(PKInk(type, color: .black), breite: width)
            guard case .line(let a, let b)? = ShapeRecognizer.recognize(line.erkennungspunkte) else { return XCTFail("Linie") }
            let ideal = ShapeRecognizer.idealStroke(.line(from: a, to: b), like: original)
            let m = Self.tinte(ideal, from: a, to: b)
            report.append(String(format: "%@ %.0f pt: Linie %.1f pt lang, Tinte sichtbar %.1f pt (links %+.1f, rechts %+.1f ueber den Endpunkt); Dicke Mitte %.2f, 3 pt vor dem Anfang %.2f, 3 pt vor dem Ende %.2f",
                                 name, width, hypot(b.x - a.x, b.y - a.y), m.sichtbar, m.links, m.rechts, m.mitte, m.anfang, m.ende))
            // die Tinte reicht bis zum Endpunkt (hoechstens 1 pt davor)
            XCTAssertGreaterThanOrEqual(m.links, -1, "\(name): Tinte beginnt \(-m.links) pt nach dem Anfangspunkt")
            XCTAssertGreaterThanOrEqual(m.rechts, -1, "\(name): Tinte endet \(-m.rechts) pt vor dem Endpunkt")
            if type != .pencil {                                            // Bleistift ist koernig: Dicke nicht vergleichbar
                XCTAssertGreaterThanOrEqual(m.anfang, 0.8 * m.mitte, "\(name): am Anfang duenner")
                XCTAssertGreaterThanOrEqual(m.ende, 0.8 * m.mitte, "\(name): am Ende duenner")
            }
        }
        print("[Formen] Ideale Linie als Tinte:\n  " + report.joined(separator: "\n  "))
    }

    // MARK: Einzelne Regeln (gerechnete Punkte)

    /// Punkte entlang eines Linienzugs (alle 3 pt)
    static func along(_ v: [CGPoint]) -> [CGPoint] {
        var out: [CGPoint] = []
        for i in 0..<(v.count - 1) {
            let a = v[i], b = v[i + 1]
            let n = max(1, Int(hypot(b.x - a.x, b.y - a.y) / 3))
            for k in 0..<n { out.append(CGPoint(x: a.x + (b.x - a.x) * CGFloat(k) / CGFloat(n), y: a.y + (b.y - a.y) * CGFloat(k) / CGFloat(n))) }
        }
        out.append(v[v.count - 1])
        return out
    }

    static func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    static func kreis(_ c: CGPoint, _ r: CGFloat, von: CGFloat) -> [CGPoint] {
        (0...120).map { i in
            let t = von + CGFloat(i) / 120 * 2 * .pi
            return CGPoint(x: c.x + r * cos(t), y: c.y + r * sin(t))
        }
    }

    /// Schluss der Form: ein doppelt gezogenes Stueck, eine Luecke und ein ueberstehendes Ende gehoeren zum Zeichnen von
    /// Hand; der Stiel einer 9 oder 6 macht aus dem Kreis keine Form
    func testSchlussDoppeltGezogenLueckeUeberstandUndStiel() {
        let p = Self.p
        // Rechteck 200 x 100 ab der Mitte der oberen Kante, die letzten 40 pt doppelt gezogen (2 pt versetzt)
        let doppelt = Self.along([p(200, 100), p(300, 100), p(300, 200), p(100, 200), p(100, 100), p(200, 102), p(240, 102)])
        guard case .rectangle(let c, let size, let angle)? = ShapeRecognizer.recognize(doppelt) else { return XCTFail("doppelt gezogen: Rechteck (vorher: nichts)") }
        XCTAssertEqual(c.x, 200, accuracy: 3); XCTAssertEqual(c.y, 150, accuracy: 3)
        XCTAssertEqual(size.width, 200, accuracy: 5); XCTAssertEqual(size.height, 100, accuracy: 5)
        XCTAssertEqual(angle, 0)
        XCTAssertEqual(ShapeRecognizer.recognize(Self.along([p(100, 100), p(300, 100), p(300, 200), p(100, 200), p(100, 125)]))?.name, "rectangle", "Luecke 25 pt")
        XCTAssertEqual(ShapeRecognizer.recognize(Self.along([p(100, 100), p(300, 100), p(300, 200), p(100, 200), p(100, 92)]))?.name, "rectangle", "Ende steht 8 pt ueber")
        // Luecke an der spitzen Ecke eines Dreiecks: das Ende ist der ersten Seite naeher als dem Anfang
        XCTAssertEqual(ShapeRecognizer.recognize(Self.along([p(100, 300), p(400, 300), p(380, 220), p(150, 290)]))?.name, "triangle")
        // 9: Kreis, dann der Stiel; 6: Stiel, dann der Kreis
        XCTAssertNil(ShapeRecognizer.recognize(Self.kreis(p(200, 200), 30, von: 0) + Self.along([p(230, 200), p(230, 290)])), "9 bleibt Schrift")
        XCTAssertNil(ShapeRecognizer.recognize(Self.along([p(240, 100), p(200, 170)]) + Self.kreis(p(200, 200), 30, von: -.pi / 2)), "6 bleibt Schrift")
    }

    /// Ein Rechteck darf von Hand schief sein (Winkel bis 20 Grad daneben); Parallelogramm, Trapez und Raute mit
    /// deutlich schiefen Winkeln bleiben, wie gezeichnet (vorher wurden Parallelogramm und Trapez zur Ellipse)
    func testSchiefesRechteckJaParallelogrammTrapezRauteNein() {
        let p = Self.p
        guard case .rectangle(_, let size, let angle)? = ShapeRecognizer.recognize(Self.along([p(100, 100), p(300, 108), p(296, 205), p(104, 198), p(100, 100)])) else {
            return XCTFail("leicht schiefes Rechteck")
        }
        XCTAssertEqual(angle, 0, "nahezu waagerecht: achsparallel")
        XCTAssertEqual(size.width, 194, accuracy: 6); XCTAssertEqual(size.height, 97, accuracy: 6)
        XCTAssertNil(ShapeRecognizer.recognize(Self.along([p(150, 100), p(350, 100), p(300, 187), p(100, 187), p(150, 100)])), "Parallelogramm (60 Grad)")
        XCTAssertNil(ShapeRecognizer.recognize(Self.along([p(150, 100), p(250, 100), p(300, 200), p(100, 200), p(150, 100)])), "Trapez")
        XCTAssertNil(ShapeRecognizer.recognize(Self.along([p(200, 100), p(258, 200), p(200, 300), p(142, 200), p(200, 100)])), "Raute (60 Grad)")
    }

    /// Die Linie reicht bis zum aeussersten Punkt, auch wenn am Ende gehalten wurde; eingerastet behaelt sie ihre Laenge
    func testLinieReichtBisZumEndeUndBehaeltIhreLaenge() {
        var pts = (0...50).map { CGPoint(x: 100 + CGFloat($0) * 2, y: 300) }                 // 100 pt lang
        for k in 0..<30 { pts.append(CGPoint(x: 200 + 1.5 * cos(CGFloat(k)), y: 300 + 1.5 * sin(CGFloat(k) * 1.7))) }   // Halte-Knaeuel
        guard case .line(let a, let b)? = ShapeRecognizer.recognize(pts) else { return XCTFail("Linie") }
        XCTAssertEqual(a.x, 100, accuracy: 0.5)
        XCTAssertEqual(b.x, 201.5, accuracy: 0.6, "bis zum aeussersten Punkt des Knaeuels (vorher endete sie bei 193)")
        // 4 Grad daneben: waagerecht eingerastet, gleich lang (vorher um den Kosinus gestaucht)
        let flat = ShapeRecognizer.snapAxis(from: .zero, to: CGPoint(x: 400 * cos(4 * CGFloat.pi / 180), y: 400 * sin(4 * CGFloat.pi / 180)))
        XCTAssertEqual(flat.x, 400, accuracy: 0.001); XCTAssertEqual(flat.y, 0)
        let down = ShapeRecognizer.snapAxis(from: .zero, to: CGPoint(x: 300 * sin(3 * CGFloat.pi / 180), y: -300 * cos(3 * CGFloat.pi / 180)))
        XCTAssertEqual(down.y, -300, accuracy: 0.001); XCTAssertEqual(down.x, 0)
        let slanted = ShapeRecognizer.snapAxis(from: .zero, to: CGPoint(x: 100, y: 20))
        XCTAssertEqual(slanted, CGPoint(x: 100, y: 20), "11 Grad: bleibt schraeg")
    }

    /// Flache Welle und Strich hin und zurueck sind keine Linie (vorher wurde die Welle gerade gezogen)
    func testWelleUndStrichHinUndZurueckSindKeineLinie() {
        let p = Self.p
        XCTAssertNil(ShapeRecognizer.recognize((0...100).map { i in p(100 + CGFloat(i) * 3, 300 + 12 * sin(CGFloat(i) / 8)) }), "Welle")
        XCTAssertNil(ShapeRecognizer.recognize(Self.along([p(100, 300), p(300, 302), p(120, 310)])), "hin und zurueck")
        // ein leichter Bauch bleibt eine Linie
        let bow = (0...100).map { i in p(100 + CGFloat(i) * 3, 300 + 5 * sin(CGFloat(i) / 100 * .pi)) }
        XCTAssertEqual(ShapeRecognizer.recognize(bow)?.name, "line")
    }

    struct TinteMass {
        var sichtbar: CGFloat = 0
        /// so weit reicht die Tinte ueber den Anfangs- bzw. Endpunkt hinaus (negativ: sie hoert davor auf)
        var links: CGFloat = 0
        var rechts: CGFloat = 0
        var mitte: CGFloat = 0
        var anfang: CGFloat = 0
        var ende: CGFloat = 0
    }

    /// Tinte einer (nahezu) waagerechten Linie messen: Bild von PencilKit in 8-facher Aufloesung, je Spalte die Deckung
    static func tinte(_ stroke: PKStroke, from a: CGPoint, to b: CGPoint) -> TinteMass {
        let rect = stroke.renderBounds.insetBy(dx: -8, dy: -8).integral
        let scale: CGFloat = 8
        var image = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = PKDrawing(strokes: [stroke]).image(from: rect, scale: scale)
        }
        guard let cg = image.cgImage else { return TinteMass() }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return TinteMass() }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Deckung je Spalte (Summe der Alpha-Werte, in Seitenpunkten Dicke)
        var column = [CGFloat](repeating: 0, count: w)
        var peak: CGFloat = 0
        for x in 0..<w {
            var sum = 0.0
            for y in 0..<h { sum += Double(px[(y * w + x) * 4 + 3]) / 255 }
            column[x] = CGFloat(sum) / scale
            peak = max(peak, column[x])
        }
        func at(_ pageX: CGFloat) -> CGFloat {
            let x = Int(((pageX - rect.minX) * scale).rounded())
            guard x >= 2, x < w - 2 else { return 0 }
            return (column[x - 2] + column[x - 1] + column[x] + column[x + 1] + column[x + 2]) / 5
        }
        // sichtbar: Spalten mit mindestens einem Viertel der groessten Deckung
        let visible = column.indices.filter { column[$0] >= 0.25 * peak }
        guard let first = visible.first, let last = visible.last else { return TinteMass() }
        let left = rect.minX + CGFloat(first) / scale, right = rect.minX + CGFloat(last + 1) / scale
        let x0 = min(a.x, b.x), x1 = max(a.x, b.x)
        return TinteMass(sichtbar: right - left, links: x0 - left, rechts: right - x1, mitte: at((x0 + x1) / 2), anfang: at(x0 + 3), ende: at(x1 - 3))
    }
}
