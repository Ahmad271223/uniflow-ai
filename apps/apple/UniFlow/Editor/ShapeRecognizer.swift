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
///
/// Stand 17.11.2026 (Meldung des Inhabers: "Viereck geht immer noch nicht ..., Dreieck auch nicht immer, und gerader
/// Strich wird kuerzer immer"), gemessen mit 280 Strichen aus echter Beruehrung (`FormenHandzeichnungTests`):
/// - Schluss: Von Hand trifft das Ende den Anfang nicht. Ein doppelt gezogenes Stueck oder ein ueberstehendes Ende
///   wird abgeschnitten (`closedLoop`), statt als Ecke zu zaehlen.
/// - Ecken: Der Hebel der Eckensuche passt sich auch kleinen Formen an, und passt das Vieleck mit den deutlichen
///   Ecken nicht, werden schwache und stark gerundete Ecken dazugenommen (`polygon`). Die Ecken der idealen Form sind
///   die Schnittpunkte der gezeichneten Seiten (`vertices`), nicht mehr die Punkte innen auf der Rundung.
/// - Rechteck: liegt auf den gezeichneten Seiten (Mittel je Seite) statt auf den aeussersten Punkten; schiefe Seiten
///   bis 20 Grad sind erlaubt (`rightAngleTolerance`), vorher scheiterte ein Rechteck schon an 4 Grad.
/// - Linie: reicht bis zum aeussersten Punkt der Zeichnung (`line`); vorher fehlten am Ende rund 6 pt.
/// - Schrift bleibt Schrift: Welle, Strich hin und zurueck, Schlaufe, "D", "P" werden keine Form mehr.
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
    /// Kleinere Formen sind kein Kandidat (Seitenpunkte): ein kleines "o" beim Nachdenken soll kein Kreis werden
    static let minimumSize: CGFloat = 18
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

    /// Formen erkennt ein Stift-Werkzeug (Stift, Fineliner, Bleistift, Fueller) - und der Textmarker, aber der nur die
    /// gerade Linie (`lineOnly`). Nicht: Wasserfarbe, Radierer, Lasso, Lineal.
    static func snaps(_ tool: PKTool) -> Bool {
        guard let ink = tool as? PKInkingTool else { return false }
        return ink.inkType != .watercolor
    }

    /// Textmarker (Wunsch 17.11.2026): zeichnen und am Ende halten macht den Strich gerade - zum Markieren einer
    /// Textzeile. Nur die Linie: Ein Rahmen um einen Absatz oder ein Kringel um ein Wort bleibt, wie gezogen. Nahezu
    /// waagerecht rastet die Linie genau waagerecht ein, sonst bleibt die gezeichnete Richtung (auch fast senkrecht).
    static func lineOnly(_ ink: PKInk) -> Bool { ink.inkType == .marker }

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
    /// - Parameter lineOnly: nur die gerade Linie (Textmarker, `lineOnly`), waagerecht eingerastet, nie senkrecht
    static func recognize(_ raw: [CGPoint], lineOnly: Bool = false) -> Shape? {
        let drawn = drawnPath(raw)
        // Gleichmaessig abtasten: alle 3 pt, bei kleinen Formen feiner (rund 100 Punkte), damit auch ein Viereck von
        // 25 pt noch Seiten und Ecken hat
        let pts = resample(drawn, step: min(3, max(1, pathLength(drawn) / 100)))
        guard pts.count >= 8 else { return nil }
        let length = pathLength(pts)
        let box = bounds(pts)
        // das Stueck, das mit dem Halte-Knaeuel abgeschnitten wurde (`trimRadius`), gehoert zur gezeichneten Laenge
        guard length + trimRadius >= minimumLength, max(box.width, box.height) >= minimumSize else { return nil }
        if lineOnly { return line(pts, all: raw, vertical: false) }
        if let loop = closedLoop(pts, length: length) {
            if let shape = polygon(loop) { return shape }
            // Kreis oder Ellipse: Die engen Enden einer flachen Ellipse sehen aus wie Ecken, und wo Anfang und Ende
            // sich treffen, bleibt oft ein Knick. Bis zu einer solchen Stelle gilt die grosszuegige Pruefung wie
            // bisher, bei zwei oder drei die strenge (ein "D" hat zwei Ecken und ist keine Ellipse), ab vier ist es
            // ein Vieleck, das nicht passt, und keine der Formen.
            let corners = cornerIndices(loop, closed: true).count
            guard corners <= 3 else { return nil }
            return ellipse(loop, strict: corners >= 2)
        }
        let corners = cornerIndices(pts, closed: false)
        // gerundeter Haken ohne erkennbare Ecke: erst als Pfeil pruefen (Spitze mindestens 8 pt), sonst Linie
        if corners.isEmpty {
            if let hooked = arrow(pts, corners: [], length: length, minimumHead: 8) { return hooked }
            if let straight = line(pts, all: raw) { return straight }
        }
        // kein Pfeil: eine Ecke kann auch ein kleiner Haken an einer sonst geraden Linie sein
        return arrow(pts, corners: corners, length: length) ?? line(pts, all: raw)
    }

    /// Dreieck oder Rechteck zu einem Umlauf. Zuerst mit den deutlichen Ecken. Passt das nicht, kommen schwache Ecken
    /// dazu (die stumpfe Ecke eines flachen Dreiecks, eine sehr rund gezogene Ecke), und jede Auswahl von drei bzw.
    /// vier Ecken wird geprueft: Eine Stelle, an der die Hand nur gezuckt hat oder an der Anfang und Ende versetzt
    /// aufeinandertreffen, faellt so wieder heraus. Ob es ein Vieleck IST, entscheidet nie die Zahl der Ecken allein,
    /// sondern ob der Strich auf den Seiten liegt (`triangle`, `rectangle`).
    private static func polygon(_ loop: [CGPoint]) -> Shape? {
        let strong = cornerIndices(loop, closed: true)
        if strong.count == 3, let t = triangle(loop, corners: strong) { return t.shape }
        if strong.count == 4, let r = rectangle(loop, corners: strong) { return r.shape }
        let all = cornerCandidates(loop)
        guard all.count >= 2, all.count <= 7 else { return nil }
        for size in [3, 4] where all.count >= size {
            var best: (shape: Shape, error: CGFloat)?
            for subset in subsets(all, size) {
                guard let fit = size == 3 ? triangle(loop, corners: subset) : rectangle(loop, corners: subset) else { continue }
                if fit.error < (best?.error ?? .greatestFiniteMagnitude) { best = fit }
            }
            if let best { return best.shape }
        }
        // Eine Ecke fehlt ganz (so rund gezogen, dass sie auf keinem Hebel eine Ecke ist): Sie liegt dort, wo der
        // Strich am weitesten vom Dreieck durch die drei gefundenen Ecken entfernt ist. Ob damit wirklich ein
        // Rechteck entsteht, pruefen wieder die Seiten und die Winkel. (Nur beim Rechteck: Mit zwei Ecken und einer
        // dazugedachten dritten waere der Bauch eines "D" ein Dreieck.)
        guard all.count == 3 else { return nil }
        let found = all.map { loop[$0] }
        var extra = 0, reach: CGFloat = -1
        for (i, p) in loop.enumerated() {
            var d = CGFloat.greatestFiniteMagnitude
            for k in 0..<found.count { d = min(d, distance(p, toSegment: found[k], found[(k + 1) % found.count])) }
            if d > reach { reach = d; extra = i }
        }
        guard !all.contains(extra) else { return nil }
        let withExtra = (all + [extra]).sorted()
        return rectangle(loop, corners: withExtra)?.shape
    }

    /// Kandidaten fuer die Ecken eines Vielecks: deutliche und schwache Ecken, dazu die mit doppeltem Hebel
    /// gemessenen - eine Ecke, die ueber 15 bis 20 pt gerundet ankommt (PencilKit am Geraet, schnelle Hand), sieht auf
    /// dem einfachen Hebel aus wie ein Bogen und fehlte bisher.
    static func cornerCandidates(_ loop: [CGPoint]) -> [Int] {
        var all = cornerIndices(loop, closed: true, angle: weakCornerAngle)
        let merge = max(3, loop.count / 12)
        for c in cornerIndices(loop, closed: true, leverScale: 2) + cornerIndices(loop, closed: true, angle: weakCornerAngle, leverScale: 2) {
            let near = all.contains { abs($0 - c) <= merge || loop.count - abs($0 - c) <= merge }
            if !near { all.append(c) }
        }
        return all.sorted()
    }

    /// Alle Auswahlen von `size` Elementen, Reihenfolge bleibt
    static func subsets(_ items: [Int], _ size: Int) -> [[Int]] {
        guard size > 0 else { return [[]] }
        guard items.count >= size else { return [] }
        var out: [[Int]] = []
        for i in 0...(items.count - size) {
            for rest in subsets(Array(items[(i + 1)...]), size - 1) { out.append([items[i]] + rest) }
        }
        return out
    }

    // MARK: Schluss einer geschlossenen Form

    /// Bis zu diesem Abstand (Seitenpunkte bzw. Anteil der Stricklaenge) gelten Anfang und Ende als zusammengefuehrt
    static let closeMinimum: CGFloat = 12
    static let closeFraction: CGFloat = 0.1

    /// Von Hand trifft das Ende den Anfang nie genau: Es bleibt eine Luecke, oder das letzte Stueck wird doppelt
    /// gezogen, oder ein Ende steht ein paar Punkte ueber. Gesucht wird darum die Stelle, an der sich das erste und
    /// das letzte Fuenftel des Strichs am naechsten kommen; dazwischen liegt der Umlauf. Was davor und danach liegt,
    /// muss kurz sein oder auf dem Umlauf liegen (doppelt gezogen) - steht es ab wie der Stiel einer 6 oder 9, ist
    /// der Strich keine geschlossene Form.
    ///
    /// Vorher zaehlte nur der Abstand vom ersten zum letzten Punkt, und der ganze Strich galt als Umlauf: Wurde das
    /// letzte Stueck doppelt gezogen, lief der Strich am Schluss "rueckwaerts" zum Anfang, die Eckensuche fand dort
    /// eine oder zwei Ecken zu viel, und aus dem Viereck wurde nichts.
    /// - Returns: die Punkte des Umlaufs (Anfang und Ende nah beieinander), nil = offen
    static func closedLoop(_ pts: [CGPoint], length: CGFloat) -> [CGPoint]? {
        let n = pts.count
        guard n >= 8 else { return nil }
        let tolerance = max(closeMinimum, closeFraction * length)
        let ends = hypot(pts[0].x - pts[n - 1].x, pts[0].y - pts[n - 1].y)
        let span = max(1, n / 5)
        var bi = 0, bj = n - 1
        var bd = ends
        for i in 0..<span {
            for j in (n - span)..<n {
                let d = hypot(pts[i].x - pts[j].x, pts[i].y - pts[j].y)
                if d < bd - 0.01 { bd = d; bi = i; bj = j }
            }
        }
        guard bd <= tolerance else { return nil }
        let loop = Array(pts[bi...bj])
        let box = bounds(loop)
        let spare = max(6, 0.04 * length)
        let near = max(7, 0.06 * max(box.width, box.height))
        func retraces(_ part: ArraySlice<CGPoint>) -> Bool {
            if part.isEmpty || pathLength(Array(part)) <= spare { return true }
            return part.allSatisfy { p in
                (1..<loop.count).contains { distance(p, toSegment: loop[$0 - 1], loop[$0]) <= near }
            }
        }
        if loop.count >= 8, retraces(pts[...bi]), retraces(pts[bj...]) { return loop }
        // Luecke an einer spitzen Ecke: Das Ende laeuft schraeg auf die erste Seite zu und ist ihr naeher als dem
        // Anfang, ohne dass etwas doppelt gezogen waere. Dann ist der ganze Strich der Umlauf.
        return ends <= tolerance ? pts : nil
    }

    /// Strich eines Werkzeugs pruefen und, wenn er eine Form ist, die ideale Form als Strich mit derselben Tinte
    static func replacement(for stroke: PKStroke) -> PKStroke? {
        guard stroke.mask == nil else { return nil }
        let points = stroke.path.interpolatedPoints(by: .distance(2)).map { $0.location.applying(stroke.transform) }
        guard let shape = recognize(points, lineOnly: lineOnly(stroke.ink)) else { return nil }
        return idealStroke(shape, like: stroke)
    }

    // MARK: Einzelne Formen

    /// Linie: Ausgleichsgerade durch den Strich. Sie reicht vom ersten bis zum aeussersten Punkt der Zeichnung - auch
    /// die Punkte, die beim Halten am Ende entstanden sind, zaehlen dafuer mit (`all`). Vorher endete die Linie am
    /// ersten Punkt des Halte-Knaeuels: bis zu 6 pt (`trimRadius`) und einen Abtastschritt zu frueh, bei jeder Linie.
    private static func line(_ pts: [CGPoint], all: [CGPoint], vertical: Bool = true) -> Shape? {
        guard let fit = fitLine(pts[...]) else { return nil }
        var u = fit.direction
        let a = pts[0], b = pts[pts.count - 1]
        if (b.x - a.x) * u.x + (b.y - a.y) * u.y < 0 { u = CGPoint(x: -u.x, y: -u.y) }
        var low = CGFloat.greatestFiniteMagnitude, high = -CGFloat.greatestFiniteMagnitude
        for p in all {
            let t = (p.x - fit.point.x) * u.x + (p.y - fit.point.y) * u.y
            low = min(low, t)
            high = max(high, t)
        }
        let chord = high - low
        guard chord >= minimumLength * 0.8 else { return nil }
        // alle Punkte nahe der Geraden (sonst ein Bogen oder Haken)
        let deviation = pts.map { abs(($0.x - fit.point.x) * u.y - ($0.y - fit.point.y) * u.x) }.max() ?? 0
        guard deviation <= max(4, 0.08 * chord) else { return nil }
        // und der Strich laeuft einmal von Anfang bis Ende: keine Welle, kein Strich hin und zurueck, keine Schlaufe
        guard pathLength(pts) <= 1.12 * chord + 6 else { return nil }
        // flache Wellenlinie: der Strich wechselt mehr als einmal deutlich die Seite der Geraden (ein leichter
        // Bauch oder ein S-Schwung von Hand wechselt hoechstens einmal)
        let swing = max(3, 0.02 * chord)
        var side = 0, changes = 0
        for p in pts {
            let d = (p.x - fit.point.x) * u.y - (p.y - fit.point.y) * u.x
            if d > swing, side != 1 {
                if side == -1 { changes += 1 }
                side = 1
            } else if d < -swing, side != -1 {
                if side == 1 { changes += 1 }
                side = -1
            }
        }
        guard changes < 2 else { return nil }
        let from = CGPoint(x: fit.point.x + u.x * low, y: fit.point.y + u.y * low)
        let to = CGPoint(x: fit.point.x + u.x * high, y: fit.point.y + u.y * high)
        return .line(from: from, to: snapAxis(from: from, to: to, vertical: vertical))
    }

    /// Ausgleichsgerade (Hauptachse) durch Punkte: Schwerpunkt und Richtung
    static func fitLine(_ pts: ArraySlice<CGPoint>) -> (point: CGPoint, direction: CGPoint)? {
        guard pts.count >= 2 else { return nil }
        let n = CGFloat(pts.count)
        let mx = pts.reduce(0) { $0 + $1.x } / n, my = pts.reduce(0) { $0 + $1.y } / n
        var sxx: CGFloat = 0, sxy: CGFloat = 0, syy: CGFloat = 0
        for p in pts {
            sxx += (p.x - mx) * (p.x - mx)
            sxy += (p.x - mx) * (p.y - my)
            syy += (p.y - my) * (p.y - my)
        }
        guard sxx + syy > 0 else { return nil }
        let angle = 0.5 * atan2(2 * sxy, sxx - syy)
        return (CGPoint(x: mx, y: my), CGPoint(x: cos(angle), y: sin(angle)))
    }

    /// Waagerecht oder senkrecht einrasten (bis 5 Grad daneben)
    static func snapAxis(from a: CGPoint, to b: CGPoint, vertical: Bool = true) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let angle = abs(atan2(dy, dx)) * 180 / .pi
        // gleich lang wie gezeichnet (gedreht, nicht gestaucht)
        let length = hypot(dx, dy)
        if angle <= 5 || angle >= 175 { return CGPoint(x: a.x + (dx >= 0 ? length : -length), y: a.y) }
        if vertical, abs(angle - 90) <= 5 { return CGPoint(x: a.x, y: a.y + (dy >= 0 ? length : -length)) }
        return b
    }

    /// Wie weit darf der Strich vom Vieleck abweichen (Zittern der Hand, Bauch der Kanten, Rundung der Ecken):
    /// 7 % der Groesse, mindestens 8 pt - bei kleinen Formen aber hoechstens 12 % der Groesse (mit 8 pt waere bei
    /// 25 pt Groesse fast jeder Kringel ein Dreieck).
    static func fitTolerance(_ pts: [CGPoint]) -> CGFloat {
        let box = bounds(pts)
        let size = max(box.width, box.height)
        return min(max(8, 0.07 * size), max(3, 0.12 * size))
    }

    /// Seiten eines Vielecks als Ausgleichsgeraden. PencilKit rundet jede Ecke, und die Hand tut es auch: Der Punkt mit
    /// der staerksten Drehung liegt darum innen auf der Rundung, nicht auf der gemeinten Ecke. Die Seiten selbst sind
    /// aber gerade. Also: je Seite eine Gerade durch ihre Punkte (ohne das Fuenftel an jedem Ende, dort liegt die
    /// Rundung); die Ecken des Vielecks sind die Schnittpunkte benachbarter Geraden.
    /// - Returns: je Seite Schwerpunkt, Richtung (von Ecke zu Ecke) und Laenge der Sehne; nil bei entarteten Seiten
    static func sides(_ loop: [CGPoint], corners: [Int]) -> [(point: CGPoint, direction: CGPoint, length: CGFloat)]? {
        let n = loop.count, k = corners.count
        guard k >= 3 else { return nil }
        var out: [(point: CGPoint, direction: CGPoint, length: CGFloat)] = []
        for s in 0..<k {
            let a = corners[s], b = corners[(s + 1) % k]
            let count = (b - a + n) % n
            guard count >= 2 else { return nil }
            let pa = loop[a], pb = loop[b]
            let chord = hypot(pb.x - pa.x, pb.y - pa.y)
            guard chord > 0 else { return nil }
            var point = CGPoint(x: (pa.x + pb.x) / 2, y: (pa.y + pb.y) / 2)
            var direction = CGPoint(x: (pb.x - pa.x) / chord, y: (pb.y - pa.y) / chord)
            let margin = max(1, count / 5)
            var part: [CGPoint] = []
            if count - 2 * margin >= 3 {
                for t in margin...(count - margin) { part.append(loop[(a + t) % n]) }
            }
            // kurze Seite (wenige Punkte): die Sehne zwischen den Ecken ist verlaesslicher als eine Gerade durch drei Punkte
            if part.count >= 4, let fit = fitLine(part[...]) {
                point = fit.point
                let along = fit.direction.x * direction.x + fit.direction.y * direction.y
                direction = along >= 0 ? fit.direction : CGPoint(x: -fit.direction.x, y: -fit.direction.y)
            }
            out.append((point, direction, chord))
        }
        return out
    }

    /// Schnittpunkt zweier Geraden (Punkt und Richtung); nil, wenn sie fast parallel laufen
    static func intersection(_ p: CGPoint, _ u: CGPoint, _ q: CGPoint, _ v: CGPoint) -> CGPoint? {
        let cross = u.x * v.y - u.y * v.x
        guard abs(cross) > 0.15 else { return nil }
        let t = ((q.x - p.x) * v.y - (q.y - p.y) * v.x) / cross
        return CGPoint(x: p.x + u.x * t, y: p.y + u.y * t)
    }

    /// Ecken eines Vielecks: Schnittpunkte benachbarter Seiten. Liegt ein Schnittpunkt weit von der gefundenen Ecke
    /// (fast parallele oder sehr kurze Seiten) oder weiter innen als der Strich selbst (eine Rundung schneidet die
    /// Ecke nur ab, nie hinaus - dann hat der Bauch einer Seite die Gerade verzogen), bleibt es beim Punkt auf dem Strich.
    static func vertices(_ loop: [CGPoint], corners: [Int]) -> [CGPoint]? {
        guard let sides = sides(loop, corners: corners) else { return nil }
        let k = corners.count
        let n = CGFloat(loop.count)
        let middle = CGPoint(x: loop.reduce(0) { $0 + $1.x } / n, y: loop.reduce(0) { $0 + $1.y } / n)
        var out: [CGPoint] = []
        for i in 0..<k {
            let before = sides[(i + k - 1) % k], after = sides[i]
            let drawn = loop[corners[i]]
            let limit = max(8, 0.3 * min(before.length, after.length))
            if let x = intersection(before.point, before.direction, after.point, after.direction),
               hypot(x.x - drawn.x, x.y - drawn.y) <= limit,
               hypot(x.x - middle.x, x.y - middle.y) >= hypot(drawn.x - middle.x, drawn.y - middle.y) {
                out.append(x)
            } else {
                out.append(drawn)
            }
        }
        return out
    }

    /// Jede Seite des Vielecks ist auch gezeichnet: Entlang der Seite gibt es keine Luecke ueber 35 % ihrer Laenge (8 pt).
    /// Sonst waere ein offener Winkel, dessen Enden zufaellig nah beieinander liegen, ein Dreieck.
    static func covered(_ pts: [CGPoint], polygon v: [CGPoint], tolerance: CGFloat) -> Bool {
        for i in 0..<v.count {
            let a = v[i], b = v[(i + 1) % v.count]
            let len = hypot(b.x - a.x, b.y - a.y)
            guard len > 0 else { return false }
            let ux = (b.x - a.x) / len, uy = (b.y - a.y) / len
            var ts: [CGFloat] = [0, len]
            for p in pts where distance(p, toSegment: a, b) <= tolerance {
                ts.append(max(0, min(len, (p.x - a.x) * ux + (p.y - a.y) * uy)))
            }
            ts.sort()
            var gap: CGFloat = 0
            for j in 1..<ts.count { gap = max(gap, ts[j] - ts[j - 1]) }
            if gap > max(8, 0.35 * len) { return false }
        }
        return true
    }

    private static func triangle(_ pts: [CGPoint], corners: [Int]) -> (shape: Shape, error: CGFloat)? {
        guard let v = vertices(pts, corners: corners) else { return nil }
        // drei Ecken, die wirklich auseinanderliegen ...
        var longest: CGFloat = 0
        for i in 0..<3 {
            let side = hypot(v[(i + 1) % 3].x - v[i].x, v[(i + 1) % 3].y - v[i].y)
            guard side >= 8 else { return nil }
            longest = max(longest, side)
        }
        // ... und kein Splitter (ein Strich hin und zurueck): Hoehe ueber der laengsten Seite
        let area = abs((v[1].x - v[0].x) * (v[2].y - v[0].y) - (v[1].y - v[0].y) * (v[2].x - v[0].x)) / 2
        guard 2 * area / longest >= max(4, 0.12 * longest) else { return nil }
        // der Strich laeuft nahe an den drei Kanten, und jede Kante ist auch gezeichnet
        let tolerance = fitTolerance(pts)
        let error = maxDistance(pts, toPolygon: v)
        guard error <= tolerance, covered(pts, polygon: v, tolerance: tolerance) else { return nil }
        return (.triangle(v[0], v[1], v[2]), error)
    }

    /// So weit duerfen die Winkel eines von Hand gezeichneten Rechtecks vom rechten Winkel abweichen (Grad). Ein
    /// Parallelogramm, ein Trapez oder eine Raute mit deutlich schiefen Winkeln bleibt, wie gezeichnet.
    static let rightAngleTolerance: CGFloat = 20

    private static func rectangle(_ pts: [CGPoint], corners: [Int]) -> (shape: Shape, error: CGFloat)? {
        guard let sides = sides(pts, corners: corners), sides.count == 4, let quad = vertices(pts, corners: corners) else { return nil }
        // vier gerade Seiten: der Strich liegt auf dem Viereck durch die vier Ecken, und jede Seite ist gezeichnet
        let tolerance = fitTolerance(pts)
        let error = maxDistance(pts, toPolygon: quad)
        guard error <= tolerance, covered(pts, polygon: quad, tolerance: tolerance) else { return nil }
        // annaehernd rechte Winkel (zwischen den Ausgleichsgeraden der Seiten)
        for i in 0..<4 {
            let a = angleBetween(sides[i].direction, sides[(i + 1) % 4].direction)
            guard abs(a - 90) <= rightAngleTolerance else { return nil }
        }
        // Lage: Mittel der vier Seitenrichtungen, nach Laenge gewichtet (ein Rechteck sieht alle 90 Grad gleich aus,
        // darum mit dem vierfachen Winkel gemittelt); nahe an den Achsen achsparallel
        var c4: CGFloat = 0, s4: CGFloat = 0
        for s in sides {
            let t = atan2(s.direction.y, s.direction.x)
            c4 += s.length * cos(4 * t)
            s4 += s.length * sin(4 * t)
        }
        var angle = atan2(s4, c4) / 4
        if abs(angle) * 180 / .pi <= axisSnapAngle { angle = 0 }
        // Im gedrehten Rahmen liegt jede Seite waagerecht oder senkrecht; ihre Lage ist der Schwerpunkt ihrer Punkte.
        // Das Rechteck liegt damit mitten auf den gezeichneten Seiten - nicht auf den aeussersten Punkten: ein
        // ueberstehendes Ende oder eine schiefe Seite blaeht es nicht auf.
        let cosA = cos(-angle), sinA = sin(-angle)
        var xs: [CGFloat] = [], ys: [CGFloat] = []
        for s in sides {
            let p = CGPoint(x: s.point.x * cosA - s.point.y * sinA, y: s.point.x * sinA + s.point.y * cosA)
            let d = CGPoint(x: s.direction.x * cosA - s.direction.y * sinA, y: s.direction.x * sinA + s.direction.y * cosA)
            if abs(d.x) >= abs(d.y) { ys.append(p.y) } else { xs.append(p.x) }
        }
        guard xs.count == 2, ys.count == 2 else { return nil }
        let centerR = CGPoint(x: (xs[0] + xs[1]) / 2, y: (ys[0] + ys[1]) / 2)
        let center = CGPoint(x: centerR.x * cos(angle) - centerR.y * sin(angle), y: centerR.x * sin(angle) + centerR.y * cos(angle))
        // Quadrat bei fast gleichen Seiten (wie der Kreis bei fast gleichen Achsen)
        var size = CGSize(width: abs(xs[1] - xs[0]), height: abs(ys[1] - ys[0]))
        guard min(size.width, size.height) >= 6 else { return nil }
        if abs(size.width - size.height) <= squareTolerance * max(size.width, size.height) {
            let side = (size.width + size.height) / 2
            size = CGSize(width: side, height: side)
        }
        return (.rectangle(center: center, size: size, angle: angle), error)
    }

    /// Bis zu dieser Schraeglage (Grad) wird ein Rechteck achsparallel
    static let axisSnapAngle: CGFloat = 8

    /// Die vier Eckpunkte eines Rechtecks
    static func rectangleCorners(of shape: Shape) -> [CGPoint] {
        guard case .rectangle(let c, let s, let angle) = shape else { return [] }
        let hw = s.width / 2, hh = s.height / 2
        return [CGPoint(x: -hw, y: -hh), CGPoint(x: hw, y: -hh), CGPoint(x: hw, y: hh), CGPoint(x: -hw, y: hh)].map { p in
            CGPoint(x: c.x + p.x * cos(angle) - p.y * sin(angle), y: c.y + p.x * sin(angle) + p.y * cos(angle))
        }
    }

    private static func ellipse(_ pts: [CGPoint], strict: Bool) -> Shape? {
        let b = bounds(pts)
        let cx = b.midX, cy = b.midY
        var rx = b.width / 2, ry = b.height / 2
        guard rx >= 6, ry >= 6 else { return nil }
        // mittlere Abweichung von der Ellipse in der Box, und der Anteil der Punkte, die weit daneben liegen
        var sum: CGFloat = 0
        var far = 0
        for p in pts {
            let r2 = pow((p.x - cx) / rx, 2) + pow((p.y - cy) / ry, 2)
            sum += abs(r2 - 1)
            if abs(r2.squareRoot() - 1) > 0.2 { far += 1 }
        }
        let err = sum / CGFloat(pts.count)
        guard err <= (strict ? 0.2 : 0.3) else { return nil }
        if strict, CGFloat(far) > 0.12 * CGFloat(pts.count) { return nil }
        // Kreis bei fast gleichen Achsen
        if abs(rx - ry) <= 0.12 * max(rx, ry) {
            let r = (rx + ry) / 2
            rx = r; ry = r
        }
        return .ellipse(center: CGPoint(x: cx, y: cy), radii: CGSize(width: rx, height: ry))
    }

    /// Pfeil: ein gerader Schaft, danach die Spitze als Haken oder "V" in der Naehe des Schaftendes (die Spitze
    /// darf in einem Zug zurueck und wieder vor gezeichnet sein)
    private static func arrow(_ pts: [CGPoint], corners: [Int], length: CGFloat, minimumHead: CGFloat = 6) -> Shape? {
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
            if let arrow = arrow(pts, tipIndex: tipIndex, length: length, minimumHead: minimumHead) { return arrow }
        }
        return nil
    }

    private static func arrow(_ pts: [CGPoint], tipIndex: Int, length: CGFloat, minimumHead: CGFloat) -> Shape? {
        let start = pts[0], tip = pts[tipIndex]
        let shaft = hypot(tip.x - start.x, tip.y - start.y)
        guard shaft >= minimumLength * 0.8, shaft >= 0.5 * length else { return nil }
        // Schaft gerade
        let deviation = pts[0...tipIndex].map { distance($0, toLine: start, tip) }.max() ?? 0
        guard deviation <= max(4, 0.08 * shaft) else { return nil }
        // Rest bleibt nahe der Spitze und zeigt schraeg zum Schaft zurueck
        let head = Array(pts[tipIndex...])
        let reach = head.map { hypot($0.x - tip.x, $0.y - tip.y) }.max() ?? 0
        guard reach >= minimumHead, reach <= 0.5 * shaft else { return nil }
        let back = CGPoint(x: start.x - tip.x, y: start.y - tip.y)
        let slanted = head.contains { p in
            let d = CGPoint(x: p.x - tip.x, y: p.y - tip.y)
            guard hypot(d.x, d.y) >= 0.5 * reach else { return false }
            let a = angleBetween(back, d)
            return a >= 15 && a <= 80
        }
        guard slanted else { return nil }
        // Die Spitze besteht aus geraden Strichen von der Spitze weg (ein Haken oder ein "V"): jeder Punkt liegt nahe
        // an einem der beiden. Eine Schlaufe am Ende einer Unterstreichung oder der Bauch eines "P" ist keine Spitze.
        guard let barb = head.max(by: { hypot($0.x - tip.x, $0.y - tip.y) < hypot($1.x - tip.x, $1.y - tip.y) }) else { return nil }
        let other = head.max(by: { distance($0, toSegment: tip, barb) < distance($1, toSegment: tip, barb) }) ?? barb
        let slack = max(2, 0.2 * reach)
        guard head.allSatisfy({ min(distance($0, toSegment: tip, barb), distance($0, toSegment: tip, other)) <= slack }) else { return nil }
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

    /// Bahn der Zeichnung ohne das Halte-Knaeuel - aber bis zu ihrem Ende. `trimHold` schneidet alles im Umkreis
    /// `trimRadius` um den letzten Punkt ab, also auch die letzten Punkte der Zeichnung selbst: Bei einer
    /// geschlossenen Form klaffte dadurch am Schluss eine Luecke von gut 6 pt mehr als gezeichnet, und der Haken
    /// eines kleinen Pfeils ging verloren. Hier kommt das Ende wieder dazu: Der Strich laeuft weiter, solange er sich
    /// vom Eintritt in diesen Umkreis entfernt und seine Richtung haelt (hoechstens 60 Grad je Schritt); die erste
    /// Umkehr ist das Zittern beim Halten, ein Knick das Wandern der Hand.
    static func drawnPath(_ raw: [CGPoint]) -> [CGPoint] {
        var pts = trimHold(raw)
        guard pts.count >= 2, pts.count < raw.count, let entry = pts.last else { return pts }
        var far: CGFloat = 0
        var last = entry
        var heading = CGPoint(x: entry.x - pts[pts.count - 2].x, y: entry.y - pts[pts.count - 2].y)
        for p in raw[pts.count...] {
            let step = CGPoint(x: p.x - last.x, y: p.y - last.y)
            let d = hypot(p.x - entry.x, p.y - entry.y)
            let along = step.x * heading.x + step.y * heading.y
            guard d > far, along > 0.5 * hypot(step.x, step.y) * hypot(heading.x, heading.y) else { break }
            far = d
            pts.append(p)
            heading = step
            last = p
        }
        return pts
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
    static func cornerIndices(_ pts: [CGPoint], closed: Bool, angle: CGFloat = cornerAngle, leverScale: CGFloat = 1) -> [Int] {
        let n = pts.count
        guard n >= 8 else { return [] }
        let spacing = max(0.5, pathLength(pts) / CGFloat(n - 1))
        let lever = max(4, min(0.05 * pathLength(pts), 24)) * leverScale
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
            guard let t = turn(i, w), t >= angle else { continue }
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
    /// Schwache Ecke (stumpfer Winkel, stark gerundet): zaehlt nur, wenn das Vieleck damit auf dem Strich liegt (`polygon`)
    static let weakCornerAngle: CGFloat = 28
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
        + "(½ Sekunde): StudiNow macht die Form gerade bzw. rund. Mit dem Textmarker wird so nur die gerade Linie daraus. "
        + "Normales Schreiben bleibt, wie es ist. Ein Mal Rückgängig nimmt die Form wieder weg."
}
