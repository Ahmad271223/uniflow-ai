import PencilKit
import UIKit

/// Ein Schritt im Rueckgaengig-Verlauf der Handschrift (Fehlerbericht des Inhabers 13.11.2026: "Rueckgaengig holt
/// frueher geloeschte Striche zurueck", auch an derselben Stelle neu gezeichnet).
///
/// Vorher merkte sich jeder Schritt zwei ganze Zeichnungen (vorher/nachher) und Rueckgaengig setzte die Seite auf
/// "vorher". War dieses "vorher" veraltet (zwei Schritte in einem Durchlauf zusammengefasst, Seite zwischendurch neu
/// geladen oder abgeglichen), kamen damit Striche zurueck, die laengst geloescht waren. Jetzt merkt sich ein Schritt
/// nur, welche Striche er entfernt und welche er hinzugefuegt hat (mit ihrem Platz), und Rueckgaengig wendet genau das
/// umgekehrt auf die Seite an, wie sie JETZT ist: ein Strich, den der Schritt nicht entfernt hat, kommt nie zurueck.
struct InkUndoStep {
    /// Strich mit seinem Platz in der Zeichnung (Reihenfolge = Ueberdeckung, z. B. Textmarker unter Stift)
    struct Placed {
        let index: Int
        let stroke: PKStroke
    }

    let removed: [Placed]
    let added: [Placed]

    var isEmpty: Bool { removed.isEmpty && added.isEmpty }

    /// Kennung eines Strichs: Erstellzeit, Punktzahl, Tinte, Farbe, Lage (Transform) und Maske. Verschieben,
    /// Umfaerben, Radieren mit dem Pixel-Radierer und der Ersatz durch eine Form oder die Rohpunkte aendern sie, also
    /// gilt der Strich dann als entfernt und neu hinzugefuegt. Billig auch auf vollen Seiten (keine Punkte lesen).
    struct Identity: Hashable {
        let created: Double
        let count: Int
        let ink: String
        let color: Int
        let transform: [Double]
        let masked: Bool
        let width: Double

        init(_ s: PKStroke) {
            created = s.path.creationDate.timeIntervalSinceReferenceDate
            count = s.path.count
            ink = s.ink.inkType.rawValue
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            s.ink.color.getRed(&r, green: &g, blue: &b, alpha: &a)
            color = Int(r * 255) << 24 | Int(g * 255) << 16 | Int(b * 255) << 8 | Int(a * 255)
            let t = s.transform
            transform = [t.a, t.b, t.c, t.d, t.tx, t.ty].map { Double($0) }
            masked = s.mask != nil
            width = s.path.count > 0 ? Double(s.path[0].size.width) : 0
        }
    }

    /// Unterschied zweier Staende derselben Seite
    static func between(_ before: PKDrawing, _ after: PKDrawing) -> InkUndoStep {
        var pool: [Identity: [Int]] = [:]
        for (i, s) in before.strokes.enumerated() { pool[Identity(s), default: []].append(i) }
        var kept = Set<Int>()
        var added: [Placed] = []
        for (i, s) in after.strokes.enumerated() {
            let id = Identity(s)
            if var list = pool[id], !list.isEmpty {
                kept.insert(list.removeFirst())
                pool[id] = list
            } else {
                added.append(Placed(index: i, stroke: s))
            }
        }
        let removed = before.strokes.enumerated().filter { !kept.contains($0.offset) }.map { Placed(index: $0.offset, stroke: $0.element) }
        return InkUndoStep(removed: removed, added: added)
    }

    /// Rueckgaengig auf dem jetzigen Stand: Hinzugefuegtes heraus, Entferntes an seinen Platz zurueck
    func reverted(on current: PKDrawing) -> PKDrawing {
        Self.swap(current, take: added, put: removed)
    }

    /// Wiederholen auf dem jetzigen Stand: Entferntes wieder heraus, Hinzugefuegtes wieder hinein
    func reapplied(on current: PKDrawing) -> PKDrawing {
        Self.swap(current, take: removed, put: added)
    }

    /// `take` aus der Zeichnung nehmen (nur, was noch da ist), dann `put` an den gemerkten Plaetzen einsetzen (nur,
    /// was nicht schon da ist; Plaetze nach hinten begrenzt)
    private static func swap(_ current: PKDrawing, take: [Placed], put: [Placed]) -> PKDrawing {
        var strokes = current.strokes
        var wanted: [Identity: Int] = [:]
        for p in take { wanted[Identity(p.stroke), default: 0] += 1 }
        if !wanted.isEmpty {
            // von hinten: der zuletzt hinzugefuegte von mehreren gleichen faellt zuerst
            for i in strokes.indices.reversed() {
                let id = Identity(strokes[i])
                if let n = wanted[id], n > 0 {
                    strokes.remove(at: i)
                    wanted[id] = n - 1
                }
            }
        }
        var present: [Identity: Int] = [:]
        for s in strokes { present[Identity(s), default: 0] += 1 }
        for p in put.sorted(by: { $0.index < $1.index }) {
            let id = Identity(p.stroke)
            if let n = present[id], n > 0 { present[id] = n - 1; continue }   // ist schon da: nicht doppeln
            strokes.insert(p.stroke, at: min(max(0, p.index), strokes.count))
        }
        var d = current
        d.strokes = strokes
        return d
    }
}
