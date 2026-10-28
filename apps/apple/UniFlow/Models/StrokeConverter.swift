import CryptoKit
import PencilKit
import UIKit
import UniFlowCore

/// Umrechnung zwischen PencilKit und dem gemeinsamen UniFlow-Strichformat mit stabilen Objekt-IDs.
///
/// Plattformuebergreifend bearbeitbar: Punkte, Farbe, Breite je Punkt, Deckkraft, Werkzeugart. Nur auf dem iPad
/// sichtbar (gehen bei Bearbeitung im Browser verloren): PencilKit-eigene Pinselstruktur und Neigung. Deshalb wird
/// die native Zeichnung zusaetzlich als `pkdrawing` gespeichert, zusammen mit den Objekt-IDs und (ab v2) einer
/// Signatur je Strich: aendert der Browser einen Strich, wird nur dieser aus dem JSON neu aufgebaut.
///
/// Identitaet eines PencilKit-Strichs: Erstellzeit des Pfads + Punktzahl + Tintenart. Verschieben (Lasso) aendert nur
/// `transform`, Radieren mit dem Pixel-Radierer nur `mask` -> die ID bleibt, das Objekt wird aktualisiert und behaelt
/// alle Felder, die die App nicht kennt. Unveraenderte Striche werden nie neu umgerechnet; ihr JSON bleibt Byte fuer
/// Byte erhalten.
///
/// Drei-Wege beim Speichern (Basis = Stand beim letzten Laden/Speichern, hier = Zeichnung, dort = aktuelle Seite):
/// anderswo geloescht und hier unveraendert -> geloescht; anderswo geaendert und hier unveraendert -> dortiger Stand;
/// hier geaendert -> Stand dieses Geraets; hier radiert, dort geaendert -> bleibt.
///
/// Neuladen der Canvas ist asynchron: bis die neue Zeichnung wirklich auf der Canvas liegt, koennen noch Zeichnungen
/// der alten Canvas kommen. Der Zustand nach dem Neuladen (`carryingOver`) kennt deshalb beide Canvas-Staende und
/// erkennt beim Speichern an den Strichen, welcher vorliegt. Fehlt ein Strich, der nur zum anderen Stand gehoert,
/// gilt er nicht als radiert.
struct InkPageState: Sendable {
    struct StrokeKey: Hashable, Sendable {
        let created: Double
        let count: Int
        let ink: String
    }

    /// Zu welchem Canvas-Stand ein Eintrag gehoert (nur zwischen Neuladen und naechster Umrechnung nicht `.both`).
    enum Canvas: Sendable {
        case both
        /// nur auf der Canvas vor dem Neuladen
        case older
        /// nur auf der neu geladenen Canvas
        case newer
    }

    struct Entry: Sendable {
        var ids: [String]
        var content: Int
        var objects: [JSONValue]
        /// Die native Darstellung entspricht `objects` (darf so in `pkdrawing` gespeichert werden).
        var nativeMatches = true
        /// Anderswo geloescht, hier unveraendert: wird nicht gespeichert, bis die Canvas neu geladen ist.
        var deletedElsewhere = false
        /// Signatur von `objects` fuer `pkdrawing-v2` (einmal berechnet, solange der Strich unveraendert bleibt).
        var signature: String?
        var canvas: Canvas = .both
    }

    var entries: [StrokeKey: [Entry]] = [:]
    /// IDs, die in der Zeichnung dargestellt sind. Andere Strich-Objekte der Seite (z. B. nicht darstellbar)
    /// werden beim Speichern unveraendert uebernommen.
    var represented: Set<String> = []
    /// Nach dem Neuladen, solange noch keine Zeichnung umgerechnet wurde: dargestellte IDs der alten Canvas.
    var olderRepresented: Set<String>?
    /// Strich-Objekte der Seite, die sich nicht darstellen lassen (ohne ID, zu wenige oder unbrauchbare Punkte,
    /// Koordinaten oder Massstaebe ausserhalb jedes Seitenmasses). Sie bleiben beim Speichern unveraendert; der Editor
    /// sagt, dass es sie gibt (`DocumentStore.inkNotice`).
    var unrenderable = 0

    /// Erstellzeiten (als Platz in `CreationSlots`), die Striche dieses Zustands tragen.
    var creationSlots: Set<Int> {
        Set(entries.keys.map { CreationSlots.slot(Date(timeIntervalSinceReferenceDate: $0.created)) })
    }

    /// Zustand nach dem Neuladen (`self` = frisch aus der Seite), der auch Zeichnungen der alten Canvas (`older`)
    /// richtig zuordnet. Aus JSON aufgebaute Striche muessen dafuer andere Erstellzeiten tragen als die der alten
    /// Canvas (`StrokeConverter.drawing(fromPage:avoiding:)`). Wird mit der naechsten Umrechnung wieder einfach.
    func carryingOver(_ older: InkPageState) -> InkPageState {
        var s = self
        for (k, list) in entries where older.entries[k] == nil {
            s.entries[k] = list.map { var e = $0; e.canvas = .newer; return e }
        }
        for (k, list) in older.entries where entries[k] == nil {
            s.entries[k] = list.map { var e = $0; e.canvas = .older; return e }
        }
        // war schon die alte Canvas nicht eindeutig: nur IDs, die beide Staende darstellen (nichts zu viel loeschen)
        s.olderRepresented = older.olderRepresented.map { older.represented.intersection($0) } ?? older.represented
        return s
    }
}

/// Ergebnis einer Umrechnung PencilKit -> Seite.
struct InkPageUpdate: Sendable {
    var page: JSONValue
    var state: InkPageState
    /// Die Canvas zeigt etwas anderes als der gespeicherte Stand (anderswo geloeschte oder geaenderte Striche):
    /// Anzeige aus dem Seitenstand neu laden.
    var canvasOutdated: Bool
}

/// PencilKit-Zeichnung, die zwischen Threads weitergereicht wird (PKDrawing ist ein Werttyp).
struct DrawingBox: @unchecked Sendable {
    let drawing: PKDrawing
    /// Strich-Objekte der Seite, die nicht dargestellt werden konnten (`InkPageState.unrenderable`)
    var unrenderable = 0
}

enum StrokeConverter {

    /// Deckkraft des Textmarkers im Web-Editor, die dem PencilKit-Marker mit voller Farbe entspricht.
    static let markerOpacity = 0.35

    /// Tintenarten, die ab iOS 17 sicher wiederhergestellt werden koennen (`pkInk`).
    static let restorableInks: Set<PKInk.InkType> = [.pen, .pencil, .marker, .monoline, .fountainPen, .watercolor, .crayon]

    /// Groesster Betrag einer Koordinate (Seitenpunkte), der noch gezeichnet wird; Seiten messen hoechstens einige
    /// Tausend Punkte. Groesseres (beschaedigte oder fremde Daten) bliebe unsichtbar, koennte PencilKit aber beim
    /// Zeichnen und Umrechnen lange aufhalten.
    static let maxCoordinate = 100_000.0
    /// Groesster Massstab bzw. groesste Breite eines Strich-Objekts, die noch gezeichnet werden
    static let maxScale = 1_000.0
    /// Hoechstzahl Punkte eines Strichs aus dem JSON (ein langer Strich aus dem Browser hat einige Tausend)
    static let maxPoints = 200_000

    // MARK: Seite -> PencilKit

    /// Zeichnung einer Seite: bevorzugt die gespeicherte native Zeichnung. v2: je Strich, solange dessen Objekte
    /// unveraendert sind; v1: nur als Ganzes, wenn sie noch zu allen Objekten passt. Alles andere wird aus den
    /// Objekten aufgebaut. `avoiding`: Erstellzeiten, die aufgebaute Striche nicht tragen duerfen (Striche der
    /// Canvas vor dem Neuladen, siehe `InkPageState.carryingOver`).
    static func drawing(fromPage page: JSONValue?, avoiding: Set<Int> = []) -> (PKDrawing, InkPageState) {
        let objects = page?["objects"]?.array ?? []
        guard let stored = StoredDrawing(page: page), let data = Data(base64Encoded: stored.data),
              let native = try? PKDrawing(data: data), native.strokes.count == stored.strokeIDs.count else {
            return rebuild(objects: objects, avoiding: avoiding)
        }
        if let sigs = stored.strokeSignatures, sigs.count == stored.strokeIDs.count {
            return combine(native: native, strokeIDs: stored.strokeIDs, signatures: sigs, objects: objects, avoiding: avoiding)
        }
        if stored.signature == signature(objects) {
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
        return rebuild(objects: objects, avoiding: avoiding)
    }

    /// v2: native Striche, deren Objekte unveraendert sind (Signatur je Strich), behalten ihr Aussehen; alle anderen
    /// Strich-Objekte werden aus dem JSON aufgebaut. Reihenfolge (Ueberdeckung) wie in `objects`.
    static func combine(native: PKDrawing, strokeIDs: [[String]], signatures: [String], objects: [JSONValue],
                        avoiding: Set<Int> = []) -> (PKDrawing, InkPageState) {
        var byID: [String: JSONValue] = [:]
        for o in objects { if let id = o["id"]?.string { byID[id] = o } }
        var valid: [Int: [JSONValue]] = [:]
        var nativeIndex: [String: Int] = [:]
        var objectless: [Int] = []                                   // Striche ohne Objekt (aeltere Staende)
        var anyInvalid = false
        for (i, ids) in strokeIDs.enumerated() {
            if ids.isEmpty { objectless.append(i); continue }
            let objs = ids.compactMap { byID[$0] }
            guard objs.count == ids.count, strokeSignature(objs) == signatures[i] else { anyInvalid = true; continue }   // geaendert/geloescht
            valid[i] = objs
            for id in ids { nativeIndex[id] = i }
        }
        // Striche ohne Objekt sieht der Browser nicht und kann sie nicht loeschen: nur behalten, solange dort kein
        // Strich der Seite geloescht oder geaendert wurde (sonst blieben z. B. i-Punkte eines geloeschten Worts stehen)
        if anyInvalid { objectless = [] }
        var slots = CreationSlots(reserved: valid.keys.map { native.strokes[$0] } + objectless.map { native.strokes[$0] },
                                  avoiding: avoiding)
        var strokes: [PKStroke] = []
        var state = InkPageState()
        var emitted = Set<Int>()
        func addNative(_ i: Int, objects objs: [JSONValue]) {
            let s = native.strokes[i]
            strokes.append(s)
            state.entries[key(s), default: []].append(.init(ids: strokeIDs[i], content: contentHash(s), objects: objs,
                                                            signature: signatures[i]))
            state.represented.formUnion(strokeIDs[i])
        }
        for o in objects {
            guard let id = o["id"]?.string else {
                if o["type"]?.string == "stroke" { state.unrenderable += 1 }
                continue
            }
            if let i = nativeIndex[id], let objs = valid[i] {
                if emitted.insert(i).inserted { addNative(i, objects: objs) }
            } else if let s = stroke(from: o, created: slots.next()) {
                strokes.append(s)
                state.entries[key(s), default: []].append(.init(ids: [id], content: contentHash(s), objects: [o]))
                state.represented.insert(id)
            } else if o["type"]?.string == "stroke" {
                state.unrenderable += 1
            }
        }
        for i in objectless { addNative(i, objects: []) }
        return (PKDrawing(strokes: strokes), state)
    }

    /// Zeichnung aus den Objekten aufbauen. Jeder Strich bekommt eine eindeutige kuenstliche Erstellzeit, damit
    /// er spaeter eindeutig wiedererkannt wird.
    static func rebuild(objects: [JSONValue], avoiding: Set<Int> = []) -> (PKDrawing, InkPageState) {
        var strokes: [PKStroke] = []
        var state = InkPageState()
        var slots = CreationSlots(reserved: [], avoiding: avoiding)
        for o in objects {
            let isStroke = o["type"]?.string == "stroke"
            guard let id = o["id"]?.string, let s = stroke(from: o, created: slots.next()) else {
                if isStroke { state.unrenderable += 1 }
                continue
            }
            strokes.append(s)
            state.entries[key(s), default: []].append(.init(ids: [id], content: contentHash(s), objects: [o]))
            state.represented.insert(id)
        }
        return (PKDrawing(strokes: strokes), state)
    }

    /// PencilKit-Strich zu einem Strich-Objekt; nil, wenn es sich nicht darstellen laesst (Objekt bleibt dann
    /// unveraendert, `InkPageState.unrenderable`)
    static func stroke(from o: JSONValue, created: Date) -> PKStroke? {
        guard o["type"]?.string == "stroke", let raw = o["points"]?.array else { return nil }
        let pts = raw.compactMap { $0.double }
        guard pts.count >= 4, pts.count % 2 == 0, pts.count / 2 <= maxPoints,
              pts.allSatisfy({ $0.isFinite && abs($0) <= maxCoordinate }) else { return nil }
        let tool = o["tool"]?.string ?? "pen"
        let width = o["width"]?.double ?? 2.2
        let widths = o["widths"]?.array?.compactMap { $0.double }
        let opacity = o["opacity"]?.double ?? 1
        let x = o["x"]?.double ?? 0, y = o["y"]?.double ?? 0
        let rot = (o["rotation"]?.double ?? 0) * .pi / 180
        let sx = o["scaleX"]?.double ?? 1, sy = o["scaleY"]?.double ?? 1
        guard [x, y].allSatisfy({ $0.isFinite && abs($0) <= maxCoordinate }), rot.isFinite,
              [sx, sy, width].allSatisfy({ $0.isFinite && abs($0) <= maxScale }),
              (widths ?? []).allSatisfy({ $0.isFinite && abs($0) <= maxScale }) else { return nil }
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
        let type = inkType(forWebTool: tool, pkInk: o["pkInk"]?.string)
        let ink = PKInk(type, color: base.withAlphaComponent(CGFloat(inkAlpha(opacity: opacity, tool: tool))))
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: created))
    }

    // MARK: Werkzeuge

    /// Werkzeug im Web-Editor (pen, fountain, pencil, marker) zu einer PencilKit-Tintenart.
    static func webTool(for ink: PKInk.InkType) -> String {
        switch ink {
        case .marker, .watercolor: return "marker"
        case .pencil, .crayon: return "pencil"
        case .fountainPen: return "fountain"
        default: return "pen"
        }
    }

    /// Tintenart zu einem Web-Werkzeug. Die gespeicherte native Tintenart (`pkInk`) gilt, solange das Werkzeug im
    /// Browser nicht geaendert wurde (sonst bestimmt das Web-Werkzeug).
    static func inkType(forWebTool tool: String, pkInk: String?) -> PKInk.InkType {
        if let raw = pkInk, let t = PKInk.InkType(rawValue: raw), restorableInks.contains(t), webTool(for: t) == tool { return t }
        switch tool {
        case "marker": return .marker
        case "pencil": return .pencil
        case "fountain": return .fountainPen
        default: return .pen
        }
    }

    /// Deckkraft im JSON -> Alpha der PencilKit-Farbe. Der Marker ist in PencilKit schon durchscheinend:
    /// Web-Deckkraft 0,35 entspricht voller Farbe.
    static func inkAlpha(opacity: Double, tool: String) -> Double {
        let o = min(max(opacity, 0), 1)
        return tool == "marker" ? min(1, o / markerOpacity) : o
    }

    /// Alpha der PencilKit-Farbe -> Deckkraft im JSON (Umkehrung von `inkAlpha`).
    static func opacity(inkAlpha alpha: Double, tool: String) -> Double {
        let a = min(max(alpha, 0), 1)
        return tool == "marker" ? a * markerOpacity : a
    }

    // MARK: PencilKit -> Seite

    /// Neuer Seitenstand aus der Zeichnung (Kurzform von `update`).
    static func page(from drawing: PKDrawing, previous: JSONValue?, state: InkPageState) -> (JSONValue, InkPageState) {
        let u = update(from: drawing, previous: previous, state: state)
        return (u.page, u.state)
    }

    /// Neuer Seitenstand aus der Zeichnung. Text, Formen, Bilder und nicht dargestellte Striche bleiben an ihrer
    /// Stelle; unveraenderte Striche behalten ihr JSON; neue Striche bekommen neue IDs. `previous` ist der aktuelle
    /// Seitenstand (kann inzwischen Aenderungen aus dem Browser enthalten), `state` der Stand beim letzten Laden.
    static func update(from drawing: PKDrawing, previous: JSONValue?, state: InkPageState) -> InkPageUpdate {
        let previousObjects = previous?["objects"]?.array ?? []
        var previousByID: [String: JSONValue] = [:]
        for o in previousObjects { if let id = o["id"]?.string { previousByID[id] = o } }

        var pool = state.entries
        var next = InkPageState()
        var nativeStrokes: [PKStroke] = []
        var strokeIDs: [[String]] = []
        var strokeSigs: [String] = []
        var current: [JSONValue] = []
        var outdated = false
        var sawOlder = false, sawNewer = false
        for s in drawing.strokes {
            let k = key(s)
            let content = contentHash(s)
            var entry: InkPageState.Entry
            if var list = pool[k], !list.isEmpty {
                let old = list.removeFirst()
                pool[k] = list
                if old.canvas == .older { sawOlder = true }
                if old.canvas == .newer { sawNewer = true }
                if old.content == content && !old.ids.isEmpty {
                    // hier unveraendert: fuer diese IDs gilt der aktuelle Seitenstand
                    let present = old.ids.filter { previousByID[$0] != nil }
                    if present.isEmpty {
                        // anderswo geloescht, hier unveraendert -> Loeschung gewinnt
                        var ghost = old
                        ghost.deletedElsewhere = true
                        ghost.canvas = .both
                        next.entries[k, default: []].append(ghost)
                        outdated = true
                        continue
                    }
                    let objs = present.compactMap { previousByID[$0] }
                    if present.count == old.ids.count && objs == old.objects {
                        entry = old
                        entry.deletedElsewhere = false
                        entry.canvas = .both
                    } else {
                        // anderswo geaendert oder teilweise geloescht: dortiger Stand, native Darstellung passt nicht mehr
                        entry = .init(ids: present, content: content, objects: objs, nativeMatches: false)
                        outdated = true
                    }
                } else {
                    // hier geaendert (Lasso, Radierer, Farbe) oder bisher ohne Objekt: neu umrechnen, bisherige
                    // Zusatzfelder behalten
                    var oldByID: [String: JSONValue] = [:]
                    for o in old.objects { if let id = o["id"]?.string { oldByID[id] = o } }
                    let templates = old.ids.map { previousByID[$0] ?? oldByID[$0] }
                    let objs = objects(for: s, ids: old.ids, templates: templates)
                    entry = .init(ids: objs.compactMap { $0["id"]?.string }, content: content, objects: objs)
                }
            } else {
                let objs = objects(for: s, ids: [])
                entry = .init(ids: objs.compactMap { $0["id"]?.string }, content: content, objects: objs)
            }
            if entry.nativeMatches {
                let sig = entry.signature ?? strokeSignature(entry.objects)
                entry.signature = sig
                nativeStrokes.append(s)
                strokeIDs.append(entry.ids)
                strokeSigs.append(sig)
            }
            next.entries[k, default: []].append(entry)
            next.represented.formUnion(entry.ids)
            current.append(contentsOf: entry.objects)
        }

        // Nach einem Neuladen: welcher Canvas-Stand liegt vor? Nicht eindeutig -> nur loeschen, was beide darstellen.
        var represented = state.represented
        var otherCanvas: InkPageState.Canvas?
        if let olderRepresented = state.olderRepresented {
            if sawOlder && !sawNewer {
                represented = olderRepresented
                otherCanvas = .newer
            } else if sawNewer && !sawOlder {
                otherCanvas = .older
            } else {
                represented = state.represented.intersection(olderRepresented)
            }
        }
        // nur ein Canvas-Stand zeigt sie, ob hier radiert wurde ist offen: bleiben stehen
        let uncertain = state.olderRepresented.map { state.represented.union($0).subtracting(represented) } ?? []

        // hier radiert: nur, wenn anderswo unveraendert (sonst bleibt der dortige Stand). Striche, die nur der
        // andere Canvas-Stand zeigt, fehlen hier nicht wegen Radierens.
        var keptDespiteErase = Set<String>()
        for list in pool.values {
            for old in list where !old.deletedElsewhere && (otherCanvas == nil || old.canvas != otherCanvas) {
                for o in old.objects {
                    guard let id = o["id"]?.string, let theirs = previousByID[id], theirs != o else { continue }
                    keptDespiteErase.insert(id)
                    outdated = true
                }
            }
        }

        var byID: [String: JSONValue] = [:]
        for o in current { if let id = o["id"]?.string { byID[id] = o } }
        var result: [JSONValue] = []
        var placed = Set<String>()
        for o in previousObjects {
            let id = o["id"]?.string ?? ""
            if o["type"]?.string == "stroke", !id.isEmpty, represented.contains(id) || byID[id] != nil {
                if let updated = byID[id] {
                    if placed.insert(id).inserted { result.append(updated) }
                } else if keptDespiteErase.contains(id), placed.insert(id).inserted {
                    result.append(o)
                }                                                                   // sonst: hier radiert
            } else {
                result.append(o)                                                    // Text, Formen, Bilder ...
                if !id.isEmpty { placed.insert(id) }
                if uncertain.contains(id) { outdated = true }                       // bleibt, Canvas soll ihn zeigen
            }
        }
        for o in current {
            if let id = o["id"]?.string, placed.insert(id).inserted { result.append(o) }
        }

        var p = previous?.object ?? [:]
        p["objects"] = .array(result)
        let native = nativeStrokes.count == drawing.strokes.count ? drawing : PKDrawing(strokes: nativeStrokes)
        // Aeltere App-Versionen (nur v1) nutzen die Zeichnung als Ganzes, wenn `objectsSig` passt. Das darf nur
        // sein, wenn sie jedes Strich-Objekt der Seite enthaelt; sonst wuerden die fehlenden dort unsichtbar.
        let nativeIDs = Set(strokeIDs.joined())
        let complete = result.allSatisfy { o in
            o["type"]?.string != "stroke" || (o["id"]?.string).map { nativeIDs.contains($0) } == true
        }
        p["pkdrawing"] = StoredDrawing(data: native.dataRepresentation().base64EncodedString(),
                                       signature: complete ? signature(result) : "teilweise",
                                       strokeIDs: strokeIDs, strokeSignatures: strokeSigs).json
        return InkPageUpdate(page: .object(p), state: next, canvasOutdated: outdated)
    }

    /// Ein PencilKit-Strich als UniFlow-Objekt(e). Mit Pixel-Radierer geteilte Striche ergeben je sichtbarem Stueck
    /// ein Objekt, damit im Browser keine radierten Teile wieder auftauchen. `templates[i]` ist der bisherige Stand
    /// des Objekts mit `ids[i]`: seine Felder bleiben erhalten (auch unbekannte), nur Geometrie, Farbe, Deckkraft und
    /// Werkzeug werden neu gesetzt. Zusaetzliche Stuecke uebernehmen die Felder des ersten bisherigen Objekts.
    ///
    /// Punkte: Vom Stift geschriebene Striche werden entlang der gezeichneten Kurve abgetastet. Aus dem JSON aufgebaute
    /// Striche (kuenstliche Erstellzeit, `CreationSlots`) behalten ihre Punkte, nur mit der Aenderung (Verschieben)
    /// umgerechnet: PencilKit legt durch die Punkte einen glaettenden B-Spline, der nicht durch sie hindurchgeht. Vorher
    /// wurde auch hier abgetastet, und jede Aenderung auf dem iPad schliff die Form ab (gemessen: ein Zickzack aus dem
    /// Browser mit 40 pt Ausschlag verlor beim ersten Verschieben 13 pt an jeder Ecke, Runde fuer Runde mehr).
    static func objects(for s: PKStroke, ids: [String], templates: [JSONValue?] = []) -> [JSONValue] {
        let ranges: [ClosedRange<CGFloat>]
        if s.mask != nil {
            ranges = s.maskedPathRanges
        } else {
            ranges = [0...CGFloat(max(s.path.count - 1, 0))]
        }
        let type = s.ink.inkType
        let tool = webTool(for: type)
        let t = s.transform
        let scale = sqrt(abs(t.a * t.d - t.b * t.c))
        let (hex, alpha) = s.ink.color.uniflowRGBA
        let firstTemplate = templates.lazy.compactMap { $0 }.first
        let fromJSON = CreationSlots.isSynthetic(s.path.creationDate)
        var out: [JSONValue] = []
        for (i, range) in ranges.enumerated() {
            var pts: [JSONValue] = []
            var widths: [Double] = []
            let samples: [(CGPoint, CGFloat)] = fromJSON
                ? controlPoints(of: s.path, in: range)
                : s.path.interpolatedPoints(in: range, by: .distance(1.5)).map { ($0.location, $0.size.width) }
            for (location, size) in samples {
                let loc = location.applying(t)
                pts.append(.number(round2(Double(loc.x))))
                pts.append(.number(round2(Double(loc.y))))
                widths.append(round2(Double(size * scale)))
            }
            if pts.count < 4, !s.path.isEmpty {
                // einzelner Punkt (z. B. i-Punkt): wie im Web-Editor als Mini-Strich, damit der Browser ihn sieht
                // und loeschen kann
                let p = s.path.interpolatedPoint(at: range.lowerBound)
                let loc = p.location.applying(t)
                let x = round2(Double(loc.x)), y = round2(Double(loc.y)), w = round2(Double(p.size.width * scale))
                pts = [.number(x), .number(y), .number(round2(x + 0.05)), .number(round2(y + 0.05))]
                widths = [w, w]
            }
            guard pts.count >= 4 else { continue }
            let id = i < ids.count ? ids[i] : newID()
            let template = (i < templates.count ? templates[i] : nil) ?? firstTemplate
            var o = template?.object ?? [:]
            // Farbe und Deckkraft: bisherige Angabe behalten, wenn sie dieselbe Darstellung ergibt. Deckkraft auf drei
            // Stellen (zwei machten aus Marker-Alpha 0,5 = 0,175 eine 0,18, zurueck ein Alpha von 0,514)
            let oldColor = o["color"]?.string
            let color = oldColor?.lowercased() == hex ? oldColor! : hex
            var opacity = round3(opacity(inkAlpha: alpha, tool: tool))
            if let old = o["opacity"]?.double, o["tool"]?.string == tool, abs(inkAlpha(opacity: old, tool: tool) - alpha) < 0.01 {
                opacity = old
            }
            let avg = widths.reduce(0, +) / Double(max(1, widths.count))
            o["id"] = .string(id)
            o["type"] = "stroke"
            o["tool"] = .string(tool)
            o["pkInk"] = .string(type.rawValue)
            o["color"] = .string(color)
            o["width"] = .number(round2(avg))
            o["opacity"] = .number(opacity)
            o["points"] = .array(pts)
            o["x"] = 0
            o["y"] = 0
            o["rotation"] = 0
            o["scaleX"] = 1
            o["scaleY"] = 1
            if o["source"] == nil { o["source"] = "pencilkit" }
            if tool != "marker", (widths.max() ?? 0) - (widths.min() ?? 0) > 0.05 {
                o["widths"] = .array(widths.map { .number($0) })
            } else {
                o.removeValue(forKey: "widths")
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
        let rgba = s.ink.color.uniflowRGBA
        h.combine(rgba.hex)
        h.combine(round2(rgba.alpha))
        return h.finalize()
    }

    /// Stabile Signatur der Objekte einer Seite (Schluessel sortiert), um Browser-Aenderungen zu erkennen.
    static func signature(_ objects: [JSONValue]) -> String {
        let data = JSONValue.array(objects).serialized(sortedKeys: true)
        return SolutionSHA256.hexString(Array(SHA256.hash(data: data)))
    }

    /// Signatur der Objekte eines einzelnen Strichs (`pkdrawing-v2`, gekuerzt auf 96 Bit).
    static func strokeSignature(_ objects: [JSONValue]) -> String {
        String(signature(objects).prefix(24))
    }

    static func newID() -> String {
        "pk" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
    }

    static func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }

    static func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }

    /// Stuetzpunkte eines Pfads im Parameterbereich `range` (Parameter i = i-ter Punkt), an gebrochenen Enden linear
    /// zwischen den Nachbarn: die Punkte, aus denen der Strich aufgebaut wurde, unveraendert (fuer Striche aus dem JSON)
    static func controlPoints(of path: PKStrokePath, in range: ClosedRange<CGFloat>) -> [(CGPoint, CGFloat)] {
        let n = path.count
        guard n > 0 else { return [] }
        func at(_ t: CGFloat) -> (CGPoint, CGFloat) {
            let c = min(max(t, 0), CGFloat(n - 1))
            let i = Int(c.rounded(.down)), j = min(i + 1, n - 1), f = c - CGFloat(i)
            let a = path[i], b = path[j]
            return (CGPoint(x: a.location.x + (b.location.x - a.location.x) * f, y: a.location.y + (b.location.y - a.location.y) * f),
                    a.size.width + (b.size.width - a.size.width) * f)
        }
        let lo = max(range.lowerBound, 0), hi = min(range.upperBound, CGFloat(n - 1))
        guard lo <= hi else { return [] }
        var out: [(CGPoint, CGFloat)] = []
        if lo != lo.rounded(.down) { out.append(at(lo)) }
        var i = Int(lo.rounded(.up))
        while i < n, CGFloat(i) <= hi {
            out.append((path[i].location, path[i].size.width))
            i += 1
        }
        if hi != hi.rounded(.down) { out.append(at(hi)) }
        return out
    }
}

/// Kuenstliche Erstellzeiten fuer aus JSON aufgebaute Striche (1000 s + n ms nach dem Referenzdatum). Zeiten, die
/// gespeicherte native Striche schon tragen, werden uebersprungen, damit jeder Strich eindeutig wiedererkannt wird.
struct CreationSlots {
    private var taken: Set<Int>
    private var n = 0

    init(reserved: [PKStroke], avoiding: Set<Int> = []) {
        taken = Set(reserved.map { CreationSlots.slot($0.path.creationDate) }).union(avoiding)
    }

    /// Kuenstliche Erstellzeit (aus dem JSON aufgebauter Strich)? Echte Striche tragen das Datum ihres Entstehens.
    static func isSynthetic(_ date: Date) -> Bool {
        let t = date.timeIntervalSinceReferenceDate
        return t >= 1_000 && t < 2_000_000
    }

    static func slot(_ date: Date) -> Int {
        let v = (date.timeIntervalSinceReferenceDate - 1_000) * 1_000
        return v.isFinite && abs(v) < 1e15 ? Int(v.rounded()) : Int.min
    }

    mutating func next() -> Date {
        while taken.contains(n) { n += 1 }
        defer { n += 1 }
        return Date(timeIntervalSinceReferenceDate: 1_000 + Double(n) * 0.001)
    }
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
