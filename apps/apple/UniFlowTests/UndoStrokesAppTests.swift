import PDFKit
import PencilKit
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Rueckgaengig im Editor (Fehlerbericht des Inhabers 13.11.2026, Build 37/38: "Rueckgaengig holt frueher geloeschte
/// Striche zurueck"). Echte Striche ueber die Wege von PencilKit (Werkzeug an, Zeichnung geaendert, Werkzeug aus) im
/// echten Editor mit lokalem Speicher; ein Modell fuehrt mit, was nach jedem Schritt auf der Seite stehen muss.
/// Rueckgaengig nimmt genau den letzten Schritt zurueck, Wiederholen stellt genau ihn wieder her, geloeschte Striche
/// kommen nie von selbst zurueck - auch nicht nach Sichern, Abgleich, Seitenwechsel, mit Glaettung und Formerkennung.
@MainActor
final class UndoStrokesAppTests: XCTestCase {

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: PencilSmoothing.key)
        UserDefaults.standard.removeObject(forKey: ShapeSnapSetting.key)
    }

    // MARK: Modell

    /// Striche einer Seite als Kennungen (Erstellzeit, wie StrokeConverter)
    private func ids(_ d: PKDrawing) -> [Double] { d.strokes.map { $0.path.creationDate.timeIntervalSince1970.rounded(toPlaces: 3) } }

    private struct Model {
        var now: [Double] = []
        var undo: [[Double]] = []
        var redo: [[Double]] = []
        mutating func change(_ next: [Double]) { undo.append(now); now = next; redo = [] }
        mutating func doUndo() { guard let p = undo.popLast() else { return }; redo.append(now); now = p }
        mutating func doRedo() { guard let n = redo.popLast() else { return }; undo.append(now); now = n }
    }

    private var created = 1_900_000_000.0

    private func newStroke(_ n: Int, hold: Bool = false) -> PKStroke {
        created += 1
        let y = 120 + CGFloat(n % 14) * 45
        let x = 60 + CGFloat((n / 14) % 3) * 160
        var pts = (0..<30).map { i -> PKStrokePoint in
            let t = CGFloat(i) / 29
            return PKStrokePoint(location: CGPoint(x: x + t * 120, y: y + sin(t * 9) * 8), timeOffset: Double(i) * 0.01,
                                 size: CGSize(width: 2.4, height: 2.4), opacity: 1, force: 0.8, azimuth: 0.6, altitude: 1.1)
        }
        if hold, let last = pts.last {
            for k in 1...20 { pts.append(PKStrokePoint(location: last.location, timeOffset: last.timeOffset + Double(k) * 0.04, size: last.size,
                                                        opacity: 1, force: 0.8, azimuth: 0.6, altitude: 1.1)) }
        }
        return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: pts, creationDate: Date(timeIntervalSince1970: created)))
    }

    private func setCanvas(_ d: PKDrawing, _ o: PageInkView) {
        o.isApplyingDrawing = true
        o.canvas.drawing = d
        o.isApplyingDrawing = false
    }

    /// Stiftstrich wie PencilKit: Werkzeug an, Strich da, Meldung, Werkzeug aus (oder Meldung nach "aus")
    /// Hauptschleife einmal laufen lassen: wie zwischen zwei Beruehrungen am iPad (UndoManager fasst alles, was in
    /// einem Durchlauf registriert wird, zu einem Schritt zusammen)
    private func tick() async { try? await Task.sleep(nanoseconds: 30_000_000) }

    private func undo(_ e: PDFEditorController) async { await tick(); e.undo(); await tick() }
    private func redo(_ e: PDFEditorController) async { await tick(); e.redo(); await tick() }

    private func pen(_ e: PDFEditorController, _ o: PageInkView, _ s: PKStroke, changeAfterEnd: Bool = false, raw: Bool = false) async {
        await tick()
        o.canvas.tool = PKInkingTool(.pen, color: .black, width: 3)
        e.canvasViewDidBeginUsingTool(o.canvas)
        var d = o.canvas.drawing
        d.strokes.append(s)
        setCanvas(d, o)
        if raw {
            let t0 = 2000.0
            o.rawRecorder.setSamplesForTesting((0..<60).map { i in
                let p = s.path.interpolatedLocation(at: CGFloat(i) / 59 * CGFloat(max(0, s.path.count - 1)))
                return RawPencilSample(location: CGPoint(x: p.x + (i % 2 == 0 ? 0.2 : -0.2), y: p.y), time: t0 + Double(i) / 240)
            })
        }
        if changeAfterEnd {
            e.canvasViewDidEndUsingTool(o.canvas)
            e.canvasViewDrawingDidChange(o.canvas)
        } else {
            e.canvasViewDrawingDidChange(o.canvas)
            e.canvasViewDidEndUsingTool(o.canvas)
        }
        await tick()
    }

    /// Radierer ueber Striche (je geloeschtem Strich eine Meldung, waehrend der Stift aufliegt)
    private func erase(_ e: PDFEditorController, _ o: PageInkView, indices: [Int]) async {
        await tick()
        o.canvas.tool = PKEraserTool(.vector)
        e.canvasViewDidBeginUsingTool(o.canvas)
        for idx in indices.sorted(by: >) {
            var d = o.canvas.drawing
            guard idx < d.strokes.count else { continue }
            d.strokes.remove(at: idx)
            setCanvas(d, o)
            e.canvasViewDrawingDidChange(o.canvas)
            await tick()
        }
        e.canvasViewDidEndUsingTool(o.canvas)
        await tick()
    }

    private func check(_ o: PageInkView, _ m: Model, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(ids(o.canvas.drawing), m.now, "\(what): Canvas", file: file, line: line)
    }

    private func checkStore(_ store: DocumentStore, _ key: String, _ m: Model, _ what: String, file: StaticString = #filePath, line: UInt = #line) async {
        let d = await store.drawing(forPageKey: key)
        XCTAssertEqual(ids(d).sorted(), m.now.sorted(), "\(what): gespeichert", file: file, line: line)
    }

    // MARK: Ablaeufe

    /// Schreiben, Radieren, Rueckgaengig, Wiederholen in allen Reihenfolgen der PencilKit-Meldungen, mit Pausen
    /// (Sichern laeuft dazwischen) und je Glaettungsstufe, Formerkennung an
    func testUndoRedoAlwaysTakesExactlyTheLastStep() async throws {
        for smoothing in [PencilSmoothing.normal, .light, .off] {
            UserDefaults.standard.set(smoothing.rawValue, forKey: PencilSmoothing.key)
            let fx = try await makeFixture(pages: 3)
            let store = try await openStore(fx)
            let shown = show(store)
            defer { hide(shown) }
            let e = shown.editor
            let o = try await waitForOverlay(e, page: 0)
            var m = Model()
            let tag = "Glaettung \(smoothing.rawValue)"
            var n = 0
            func write(_ count: Int, changeAfterEnd: Bool = false) async {
                for _ in 0..<count {
                    n += 1
                    let s = newStroke(n)
                    await pen(e, o, s, changeAfterEnd: changeAfterEnd, raw: smoothing != .normal)
                    m.change(m.now + [ids(PKDrawing(strokes: [s]))[0]])
                    check(o, m, "\(tag): Strich \(n)")
                }
            }
            await write(5)
            await erase(e, o, indices: [1, 3])
            m.change(m.now.enumerated().filter { ![1, 3].contains($0.offset) }.map(\.element))
            check(o, m, "\(tag): radiert")
            try await Task.sleep(nanoseconds: 400_000_000)                    // Sichern nach der Pause
            await write(2, changeAfterEnd: true)
            await undo(e); m.doUndo(); check(o, m, "\(tag): Rueckgaengig 1")
            await undo(e); m.doUndo(); check(o, m, "\(tag): Rueckgaengig 2")
            try await Task.sleep(nanoseconds: 400_000_000)
            await undo(e); m.doUndo(); check(o, m, "\(tag): Rueckgaengig 3 (Radieren zurueck)")
            await redo(e); m.doRedo(); check(o, m, "\(tag): Wiederholen (wieder radiert)")
            await write(1)                                                          // neuer Schritt: Wiederholen-Liste leer
            await redo(e); m.doRedo(); check(o, m, "\(tag): Wiederholen ohne Liste")
            for k in 1...4 { await undo(e); m.doUndo(); check(o, m, "\(tag): Rueckgaengig Serie \(k)") }
            try await Task.sleep(nanoseconds: 400_000_000)
            await write(1)
            await store.flush()
            await checkStore(store, o.pageKey, m, tag)
            await undo(e); m.doUndo(); check(o, m, "\(tag): nach Sichern Rueckgaengig")
            await store.flush()
            await checkStore(store, o.pageKey, m, "\(tag) nach Rueckgaengig")
            await store.close()
        }
    }

    /// Fall des Inhabers: Strich A, Rueckgaengig, an derselben Stelle Strich B - danach steht nur B da, auch nach dem
    /// Sichern, Neuladen und Abgleich. Je Glaettungsstufe, Formerkennung an und aus; dazwischen Zeit zum Umrechnen,
    /// ein Abgleich und eine Vorschau der Seite (liest den Speicher wie Seitenleiste und Suche).
    func testUndoThenDrawAtTheSamePlaceNeverBringsTheOldStrokeBack() async throws {
        var report: [String] = []
        for shapes in [true, false] {
            for smoothing in [PencilSmoothing.normal, .light, .off] {
                UserDefaults.standard.set(smoothing.rawValue, forKey: PencilSmoothing.key)
                UserDefaults.standard.set(shapes, forKey: ShapeSnapSetting.key)
                let tag = "Glaettung \(smoothing.rawValue), Formen \(shapes ? "an" : "aus")"
                let fx = try await makeFixture(pages: 2)
                let store = try await openStore(fx)
                let shown = show(store)
                defer { hide(shown) }
                let e = shown.editor
                var o = try await waitForOverlay(e, page: 0)
                let raw = smoothing != .normal
                for variant in 0..<4 {
                    let a = newStroke(1)                                    // gleiche Stelle wie b
                    let b = newStroke(1)
                    let before = ids(o.canvas.drawing)
                    await pen(e, o, a, raw: raw)
                    if variant >= 1 { try await Task.sleep(nanoseconds: 450_000_000) }        // A gesichert
                    if variant == 2 { _ = await store.drawing(forPageKey: o.pageKey) }        // Vorschau liest
                    await undo(e)
                    XCTAssertEqual(ids(o.canvas.drawing), before, "\(tag) v\(variant): A weg")
                    if variant >= 1 { try await Task.sleep(nanoseconds: 450_000_000) }        // Rueckgaengig gesichert
                    if variant == 3 {
                        NotificationCenter.default.post(name: .uniflowAccountSynced, object: nil)
                        try await Task.sleep(nanoseconds: 300_000_000)
                    }
                    if variant == 2 { _ = await store.drawing(forPageKey: o.pageKey) }
                    await pen(e, o, b, raw: raw)
                    let bID = ids(PKDrawing(strokes: [b]))[0], aID = ids(PKDrawing(strokes: [a]))[0]
                    XCTAssertEqual(ids(o.canvas.drawing), before + [bID], "\(tag) v\(variant): nur B")
                    try await Task.sleep(nanoseconds: 600_000_000)                            // B gesichert, ggf. neu geladen
                    XCTAssertFalse(ids(o.canvas.drawing).contains(aID), "\(tag) v\(variant): A kommt nach dem Sichern zurueck")
                    XCTAssertEqual(o.canvas.drawing.strokes.count, before.count + 1, "\(tag) v\(variant): Anzahl nach dem Sichern")
                    await store.flush()
                    let stored = await store.drawing(forPageKey: o.pageKey)
                    XCTAssertEqual(stored.strokes.count, before.count + 1, "\(tag) v\(variant): gespeichert")
                    if o.canvas.drawing.strokes.count != before.count + 1 { report.append("\(tag) v\(variant): A zurueck") }
                }
                // weg und zurueck: Seite aus dem Speicher neu
                e.goToPage(1)
                try await Task.sleep(nanoseconds: 500_000_000)
                e.goToPage(0)
                o = try await waitForOverlay(e, page: 0)
                XCTAssertEqual(o.canvas.drawing.strokes.count, 4, "\(tag): nach Seitenwechsel vier B-Striche")
                await store.close()
            }
        }
        print("[Undo] gleiche Stelle: " + (report.isEmpty ? "nie zurueck" : report.joined(separator: "; ")))
    }

    /// Ist das iPad kurz beschaeftigt (volle Seite sichern, Abgleich), stauen sich die Beruehrungen und iOS arbeitet
    /// sie in EINEM Durchlauf der Hauptschleife ab. Der UndoManager fasste dann alles zu einem Schritt zusammen:
    /// Radieren und der naechste Strich wurden ein Schritt, Rueckgaengig nahm den Strich weg UND holte die radierten
    /// Striche zurueck (Fehlerbericht Build 37/38). Hier ohne Pause zwischen den Schritten.
    func testStepsInOneBusyMomentStaySeparate() async throws {
        let fx = try await makeFixture(pages: 2)
        let store = try await openStore(fx)
        let shown = show(store)
        defer { hide(shown) }
        let e = shown.editor
        let o = try await waitForOverlay(e, page: 0)
        var m = Model()
        // drei Striche, dann radieren und sofort weiterschreiben - alles in einem Durchlauf
        for k in 1...3 {
            let s = newStroke(k)
            penNow(e, o, s)
            m.change(m.now + [ids(PKDrawing(strokes: [s]))[0]])
        }
        eraseNow(e, o, indices: [1])
        m.change(m.now.enumerated().filter { $0.offset != 1 }.map(\.element))
        let y = newStroke(4)
        penNow(e, o, y)
        m.change(m.now + [ids(PKDrawing(strokes: [y]))[0]])
        check(o, m, "nach dem Schreiben")
        e.undo(); m.doUndo()
        check(o, m, "Rueckgaengig nimmt nur den letzten Strich (der radierte bleibt weg)")
        e.undo(); m.doUndo()
        check(o, m, "Rueckgaengig holt jetzt den radierten Strich zurueck")
        e.redo(); m.doRedo()
        check(o, m, "Wiederholen radiert wieder")
        await tick()
        e.undo(); m.doUndo()
        check(o, m, "Rueckgaengig nach einer Pause")
        await store.flush()
        await checkStore(store, o.pageKey, m, "gespeichert")
        await store.close()
    }

    /// Wie `pen`/`erase`, aber ohne Pause (alles im selben Durchlauf der Hauptschleife)
    private func penNow(_ e: PDFEditorController, _ o: PageInkView, _ s: PKStroke) {
        o.canvas.tool = PKInkingTool(.pen, color: .black, width: 3)
        e.canvasViewDidBeginUsingTool(o.canvas)
        var d = o.canvas.drawing
        d.strokes.append(s)
        setCanvas(d, o)
        e.canvasViewDrawingDidChange(o.canvas)
        e.canvasViewDidEndUsingTool(o.canvas)
    }

    private func eraseNow(_ e: PDFEditorController, _ o: PageInkView, indices: [Int]) {
        o.canvas.tool = PKEraserTool(.vector)
        e.canvasViewDidBeginUsingTool(o.canvas)
        for idx in indices.sorted(by: >) {
            var d = o.canvas.drawing
            d.strokes.remove(at: idx)
            setCanvas(d, o)
            e.canvasViewDrawingDidChange(o.canvas)
        }
        e.canvasViewDidEndUsingTool(o.canvas)
    }

    /// Abgleich (Geraete-Abgleich meldet `.uniflowAccountSynced`, der Speicher laedt neu) und Seitenwechsel zwischen
    /// den Schritten: geloeschte Striche kommen nicht zurueck, Rueckgaengig bleibt richtig
    func testSyncAndPageSwitchNeverBringBackDeletedStrokes() async throws {
        let fx = try await makeFixture(pages: 12)
        let store = try await openStore(fx)
        let shown = show(store)
        defer { hide(shown) }
        let e = shown.editor
        var o = try await waitForOverlay(e, page: 0)
        var m = Model()
        var n = 0
        func write(_ count: Int) async {
            for _ in 0..<count {
                n += 1
                let s = newStroke(n)
                await pen(e, o, s)
                m.change(m.now + [ids(PKDrawing(strokes: [s]))[0]])
            }
        }
        await write(4)
        await erase(e, o, indices: [0])
        m.change(Array(m.now.dropFirst()))
        // Abgleich direkt nach dem Radieren (vor der Schreibpause) und danach
        NotificationCenter.default.post(name: .uniflowAccountSynced, object: nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        check(o, m, "Abgleich direkt nach dem Radieren")
        try await Task.sleep(nanoseconds: 600_000_000)
        NotificationCenter.default.post(name: .uniflowAccountSynced, object: nil)
        try await Task.sleep(nanoseconds: 600_000_000)
        check(o, m, "Abgleich nach der Pause")
        await checkStore(store, o.pageKey, m, "Abgleich")
        await undo(e); m.doUndo(); check(o, m, "Rueckgaengig nach Abgleich (Radieren zurueck)")
        await undo(e); m.doUndo(); check(o, m, "Rueckgaengig nach Abgleich 2")
        await redo(e); m.doRedo(); check(o, m, "Wiederholen nach Abgleich")

        // weg und zurueck (Seite wird geparkt bzw. neu angelegt)
        e.goToPage(8)
        try await Task.sleep(nanoseconds: 800_000_000)
        e.goToPage(0)
        o = try await waitForOverlay(e, page: 0)
        try await Task.sleep(nanoseconds: 300_000_000)
        check(o, m, "nach Seitenwechsel")
        await undo(e); m.doUndo(); check(o, m, "Rueckgaengig nach Seitenwechsel")
        await write(1)
        await undo(e); m.doUndo(); check(o, m, "Rueckgaengig neuer Strich nach Seitenwechsel")
        await undo(e); m.doUndo(); check(o, m, "Rueckgaengig weiter")
        await store.flush()
        await checkStore(store, o.pageKey, m, "Ende")
        await store.close()
    }

    /// Formerkennung (Strich mit Halten am Ende) und Lineal: Rueckgaengig nimmt Strich samt Form zurueck
    func testShapeSnapIsOneUndoStep() async throws {
        UserDefaults.standard.set(true, forKey: ShapeSnapSetting.key)
        let fx = try await makeFixture(pages: 2)
        let store = try await openStore(fx)
        let shown = show(store)
        defer { hide(shown) }
        let e = shown.editor
        let o = try await waitForOverlay(e, page: 0)
        await pen(e, o, newStroke(1))
        let one = o.canvas.drawing.strokes.count
        let line = Handschrift.line(from: CGPoint(x: 60, y: 500), to: CGPoint(x: 400, y: 503), created: Date(timeIntervalSince1970: 1_950_000_000))
        var pts = (0..<line.path.count).map { line.path[$0] }
        let last = pts[pts.count - 1]
        for k in 1...20 { pts.append(PKStrokePoint(location: last.location, timeOffset: last.timeOffset + Double(k) * 0.04, size: last.size,
                                                    opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)) }
        let held = PKStroke(ink: line.ink, path: PKStrokePath(controlPoints: pts, creationDate: line.path.creationDate))
        await pen(e, o, held)
        XCTAssertEqual(o.canvas.drawing.strokes.count, one + 1)
        await undo(e)
        XCTAssertEqual(o.canvas.drawing.strokes.count, one, "Strich samt Form in einem Schritt zurueck")
        await undo(e)
        XCTAssertEqual(o.canvas.drawing.strokes.count, 0)
        await redo(e); await redo(e)
        XCTAssertEqual(o.canvas.drawing.strokes.count, one + 1)
        await store.close()
    }

    // MARK: Formerkennung am Geraet

    /// Am iPad kann iOS "Werkzeug aus" VOR "Zeichnung geaendert" melden. Vorher lief die Formerkennung nur in der
    /// anderen Reihenfolge (Befund Inhaber Build 39: "Formen erkennen klappt ueberhaupt nicht"). Die Haltezeit kommt aus
    /// den Zeitstempeln des Stifts; PencilKit legt beim stillen Stift oft keine Punkte mehr an. In beiden Reihenfolgen:
    /// Kreis und Linie werden ersetzt, ein Rueckgaengig-Schritt; ohne Halten bleibt der Strich.
    func testShapeSnapWorksInBothEventOrdersWithPencilTimestamps() async throws {
        UserDefaults.standard.set(true, forKey: ShapeSnapSetting.key)
        let fx = try await makeFixture(pages: 2)
        let store = try await openStore(fx)
        let shown = show(store)
        defer { hide(shown) }
        let e = shown.editor
        let o = try await waitForOverlay(e, page: 0)
        /// Kreis wie vom Stift: PencilKit-Punkte OHNE Haltepunkte am Ende, Rohpunkte mit Zeitstempeln (240/s) und
        /// am Ende `hold` Sekunden still
        func circle(_ n: Int, hold: Double) -> (PKStroke, [RawPencilSample]) {
            created += 1
            let c = CGPoint(x: 250, y: 200 + CGFloat(n) * 130)
            let pts = (0...80).map { i -> PKStrokePoint in
                let t = CGFloat(i) / 80 * 2 * .pi
                return PKStrokePoint(location: CGPoint(x: c.x + 50 * cos(t), y: c.y + 48 * sin(t)), timeOffset: Double(i) * 0.008,
                                     size: CGSize(width: 2.5, height: 2.5), opacity: 1, force: 0.8, azimuth: 0.5, altitude: 1.2)
            }
            let stroke = PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: pts, creationDate: Date(timeIntervalSince1970: created)))
            var raw = pts.enumerated().map { RawPencilSample(location: $1.location, time: 100 + Double($0) / 240) }
            let last = raw[raw.count - 1]
            var t = last.time
            while t < last.time + hold { t += 1.0 / 240; raw.append(RawPencilSample(location: CGPoint(x: last.location.x + 0.4, y: last.location.y), time: t)) }
            return (stroke, raw)
        }
        for changeAfterEnd in [false, true] {
            let tag = changeAfterEnd ? "erst Werkzeug aus" : "erst Zeichnung"
            let count0 = o.canvas.drawing.strokes.count
            let (held, rawHeld) = circle(changeAfterEnd ? 1 : 0, hold: 0.6)
            await tick()
            o.canvas.tool = PKInkingTool(.pen, color: .black, width: 3)
            e.canvasViewDidBeginUsingTool(o.canvas)
            var d = o.canvas.drawing
            d.strokes.append(held)
            setCanvas(d, o)
            o.rawRecorder.setSamplesForTesting(rawHeld)
            if changeAfterEnd { e.canvasViewDidEndUsingTool(o.canvas); e.canvasViewDrawingDidChange(o.canvas) }
            else { e.canvasViewDrawingDidChange(o.canvas); e.canvasViewDidEndUsingTool(o.canvas) }
            await tick()
            let snapped = try XCTUnwrap(o.canvas.drawing.strokes.last)
            XCTAssertEqual(o.canvas.drawing.strokes.count, count0 + 1, tag)
            XCTAssertNotEqual(snapped.path.count, held.path.count, "\(tag): Kreis ersetzt")
            XCTAssertEqual(ShapeRecognizer.recognize(snapped.path.interpolatedPoints(by: .distance(2)).map(\.location))?.name, "circle", tag)
            XCTAssertEqual(snapped.ink.inkType, .pen, "\(tag): gleiches Werkzeug")
            await undo(e)
            XCTAssertEqual(o.canvas.drawing.strokes.count, count0, "\(tag): ein Schritt zurueck")
            // ohne Halten: Strich bleibt Handschrift
            let (free, rawFree) = circle(changeAfterEnd ? 3 : 2, hold: 0)
            await tick()
            e.canvasViewDidBeginUsingTool(o.canvas)
            var f = o.canvas.drawing
            f.strokes.append(free)
            setCanvas(f, o)
            o.rawRecorder.setSamplesForTesting(rawFree)
            if changeAfterEnd { e.canvasViewDidEndUsingTool(o.canvas); e.canvasViewDrawingDidChange(o.canvas) }
            else { e.canvasViewDrawingDidChange(o.canvas); e.canvasViewDidEndUsingTool(o.canvas) }
            await tick()
            XCTAssertEqual(o.canvas.drawing.strokes.last?.path.count, free.path.count, "\(tag): ohne Halten unveraendert")
        }
        // Formerkennung aus: auch mit Halten unveraendert
        UserDefaults.standard.set(false, forKey: ShapeSnapSetting.key)
        let (held, rawHeld) = circle(4, hold: 0.8)
        await tick()
        e.canvasViewDidBeginUsingTool(o.canvas)
        var d = o.canvas.drawing
        d.strokes.append(held)
        setCanvas(d, o)
        o.rawRecorder.setSamplesForTesting(rawHeld)
        e.canvasViewDidEndUsingTool(o.canvas); e.canvasViewDrawingDidChange(o.canvas)
        XCTAssertEqual(o.canvas.drawing.strokes.last?.path.count, held.path.count, "Formen aus")
        await store.close()
    }

    // MARK: Reine Rechnung

    func testInkUndoStepOnlyTouchesItsOwnStrokes() {
        let a = newStroke(1), b = newStroke(2), c = newStroke(3), x = newStroke(4)
        // Schritt: c hinzugefuegt, b entfernt
        let step = InkUndoStep.between(PKDrawing(strokes: [a, b]), PKDrawing(strokes: [a, c]))
        XCTAssertEqual(step.added.count, 1); XCTAssertEqual(step.removed.count, 1)
        // inzwischen wurde a anderswo geloescht und x dazugeschrieben: Rueckgaengig holt b zurueck und nimmt c weg,
        // a bleibt weg (vorher: ganze Seite auf "vorher" -> a kam zurueck, x verschwand)
        let now = PKDrawing(strokes: [c, x])
        XCTAssertEqual(Set(ids(step.reverted(on: now))), Set(ids(PKDrawing(strokes: [b, x]))))
        XCTAssertEqual(Set(ids(step.reapplied(on: step.reverted(on: now)))), Set(ids(PKDrawing(strokes: [c, x]))))
        // verschobener Strich (Lasso): alte Lage zurueck
        var moved = a
        moved.transform = CGAffineTransform(translationX: 40, y: 0)
        let move = InkUndoStep.between(PKDrawing(strokes: [a]), PKDrawing(strokes: [moved]))
        XCTAssertEqual(move.reverted(on: PKDrawing(strokes: [moved])).strokes.first?.transform, .identity)
        // nichts geaendert: kein Schritt
        XCTAssertTrue(InkUndoStep.between(PKDrawing(strokes: [a, b]), PKDrawing(strokes: [a, b])).isEmpty)
        // Platz bleibt: Rueckgaengig von "b radiert" setzt b zwischen a und c
        let erase = InkUndoStep.between(PKDrawing(strokes: [a, b, c]), PKDrawing(strokes: [a, c]))
        XCTAssertEqual(ids(erase.reverted(on: PKDrawing(strokes: [a, c]))), ids(PKDrawing(strokes: [a, b, c])))
    }

    func testHeldDurationFromPencilTimestamps() {
        let moving = (0..<50).map { RawPencilSample(location: CGPoint(x: CGFloat($0) * 2, y: 0), time: Double($0) / 240) }
        XCTAssertLessThan(RawStroke.heldDuration(moving, radius: 6) ?? 1, 0.03)
        let still = moving + (1...144).map { RawPencilSample(location: CGPoint(x: 98.5, y: 0.5), time: 49.0 / 240 + Double($0) / 240) }
        XCTAssertEqual(RawStroke.heldDuration(still, radius: 6) ?? 0, 0.6 + 2.0 / 240, accuracy: 0.02, "0,6 s gehalten")
        // nur das Absetzen kommt spaeter (keine Punkte beim stillen Stift)
        let lift = moving + [RawPencilSample(location: moving.last!.location, time: moving.last!.time + 0.7)]
        XCTAssertEqual(RawStroke.heldDuration(lift, radius: 6) ?? 0, 0.7 + 2.0 / 240, accuracy: 0.02)
        XCTAssertNil(RawStroke.heldDuration([], radius: 6))
    }

    // MARK: Aufbau

    private struct Fixture {
        let root: URL
        let api: APIClient
        let file: LibFile
    }

    private struct Shown {
        let editor: PDFEditorController
        let window: UIWindow
    }

    private func makeFixture(pages: Int) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-undo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let host = LocalBackendHost(directory: root.appendingPathComponent("db", isDirectory: true), clock: .fixed(berlin: "2026-11-13T18:00:00")!)
        let backend = try await host.backend()
        let fileID = "undo-" + UUID().uuidString.prefix(8).lowercased()
        try await backend.context.database.transaction { c in
            try c.execute("INSERT INTO courses(id, title, semester, subject, kind, created_at) VALUES (?,?,?,?,?,?)",
                          [.text("k-undo"), .text("Undokurs"), .text("WiSe 2026/27"), .text("Undokurs"), .text("vorlesung"), .text("2026-10-01T08:00:00")])
            try c.execute("INSERT INTO files(id, course_id, name, chdate, status, kind, downloaded_at) VALUES (?,?,?,?, 'neu', 'pdf', ?)",
                          [.text(fileID), .text("k-undo"), .text("Undo.pdf"), .integer(1_792_000_000), .text("2026-11-13T09:00:00")])
        }
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
        let pdfURL = AppPaths.pdf(fileID, namespace: api.namespace, root: root)
        try FileManager.default.createDirectory(at: pdfURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Skript.pdf(pages: pages, .schlicht).write(to: pdfURL)
        let meta = try await api.value("/api/files/\(fileID)")
        try DocumentStore.stamp(meta).write(to: pdfURL.appendingPathExtension("stand"), atomically: true, encoding: .utf8)
        let file = LibFile(id: fileID, name: "Undo.pdf", title: "Undo", kind: "pdf", module_id: nil, subject: "Undokurs",
                           doc_type: nil, ai_title: nil, sub_label: nil, downloaded_at: "2026-11-13T09:00:00", has_notes: nil,
                           page_count: pages, studip_folder: nil)
        return Fixture(root: root, api: api, file: file)
    }

    private func openStore(_ fx: Fixture) async throws -> DocumentStore {
        let store = DocumentStore(file: fx.file, api: fx.api, root: fx.root)
        await store.load()
        XCTAssertNil(store.errorMessage, store.errorMessage ?? "")
        return store
    }

    private func show(_ store: DocumentStore) -> Shown {
        let editor = PDFEditorController(store: store)
        editor.pencilOnly = true
        editor.ownNotesVisible = true
        editor.canEdit = true
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let frame = scene?.screen.bounds ?? CGRect(x: 0, y: 0, width: 834, height: 1210)
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        window.rootViewController = editor
        window.makeKeyAndVisible()
        return Shown(editor: editor, window: window)
    }

    private func hide(_ shown: Shown) {
        guard shown.window.rootViewController != nil else { return }
        shown.editor.showToolPicker(false)
        shown.window.isHidden = true
        shown.window.rootViewController = nil
    }

    private func waitForOverlay(_ editor: PDFEditorController, page: Int, timeout: Double = 20) async throws -> PageInkView {
        let end = Uhr.now() + timeout
        while Uhr.now() < end {
            if let o = editor.allOverlays.first(where: { $0.pageIndex == page && $0.window != nil && $0.generation == editor.shownLayoutVersion }),
               o.loaded, o.bounds.width > 0 { return o }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw MessFehler("kein geladenes Overlay fuer Seite \(page + 1)")
    }
}

private extension Double {
    func rounded(toPlaces p: Int) -> Double {
        let f = pow(10, Double(p))
        return (self * f).rounded() / f
    }
}
