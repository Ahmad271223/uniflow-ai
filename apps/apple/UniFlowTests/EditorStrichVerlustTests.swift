import PencilKit
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Meldung des Inhabers 17.11.2026: "ab und zu geht [der Strich] weg" - ein frisch geschriebener Strich bleibt ganz weg.
/// Waechter: sehr viele sehr kurze Striche in schneller Folge mit echter Beruehrung (Punkte, Kommas, kurze Boegen,
/// dazwischen laengere), Abstand 20 bis 150 ms, auf leerer und voller Seite, mit jeder Glaettung und Formerkennung an
/// und aus, waehrend laufend "Seite neu laden" eintrifft und fremde Aenderungen dazukommen. Danach muss JEDER Strich in
/// der Zeichenflaeche UND im gespeicherten Stand sein. Zeilen "[Verlust]" im Testprotokoll sind die Messwerte.
extension EditorStrichBleibtTests {

    struct VerlustErgebnis {
        var name = ""
        var geschrieben = 0
        var inDerFlaeche = 0
        var fehlenInDerFlaeche = 0
        var gespeichert = 0
        var fehlenGespeichert = 0
        var neuGesetzt = 0
        var verschoben = 0
        var zaehlerFehlt = 0
        /// zu jedem fehlenden Strich: was um sein Absetzen herum geschah
        var hergang: [String] = []
        var text: String {
            (hergang.isEmpty ? "" : hergang.map { "   >> " + $0 }.joined(separator: "\n") + "\n  ") + "\(name): geschrieben \(geschrieben); in der Zeichenflaeche \(inDerFlaeche), es fehlen \(fehlenInDerFlaeche); gespeichert \(gespeichert), es fehlen \(fehlenGespeichert); vom Programm neu gesetzt \(neuGesetzt) Mal; Laden auf einen Strich gewartet \(verschoben) Mal; Zaehler \"fehltNachAbsetzen\" +\(zaehlerFehlt)"
        }
    }

    func testWaechterKeinStrichGehtVerloren() async throws {
        try XCTSkipUnless(TestFinger.verfuegbar, "Beruehrung laesst sich in dieser iOS-Version nicht nachstellen")
        addTeardownBlock { @MainActor in PencilTuning.liftBelongsToItsStroke = true }
        var report: [String] = []
        for vorhanden in [0, 400] {
            for smoothing in [PencilSmoothing.normal, .light, .off] {
                for shapes in [true, false] {
                    let r = try await verlustLauf(smoothing: smoothing, shapes: shapes, vorhanden: vorhanden, sofort: false)
                    report.append(r.text)
                    pruefeVerlust(r)
                }
            }
        }
        // sofort nach dem Oeffnen losschreiben: die volle Seite laedt noch
        for smoothing in [PencilSmoothing.normal, .off] {
            let r = try await verlustLauf(smoothing: smoothing, shapes: true, vorhanden: 900, sofort: true)
            report.append(r.text)
            pruefeVerlust(r)
        }
        // Gegenprobe "wie bis 17.11.2026": Glaettung baut jeden Strich neu, ein gemerktes Absetzen, Laden sofort (nur
        // Messwerte, ohne Pruefung), je zweimal
        PencilTuning.rebuildFromRawPointsAfterLift = true
        PencilTuning.liftBelongsToItsStroke = false
        var before: [String] = []
        for (smoothing, vorhanden) in [(PencilSmoothing.off, 400), (.light, 400), (.off, 400), (.light, 400)] {
            let r = try await verlustLauf(smoothing: smoothing, shapes: true, vorhanden: vorhanden, sofort: false)
            before.append(r.text)
        }
        // Neubau an, aber mit den Sicherungen vom 17.11. (Absetzen gehoert zu seinem Strich, nicht wenn der Stift aufliegt)
        PencilTuning.liftBelongsToItsStroke = true
        var guarded: [String] = []
        for (smoothing, vorhanden) in [(PencilSmoothing.off, 400), (.light, 400), (.off, 400), (.light, 400)] {
            let r = try await verlustLauf(smoothing: smoothing, shapes: true, vorhanden: vorhanden, sofort: false)
            guarded.append(r.text)
        }
        PencilTuning.rebuildFromRawPointsAfterLift = false
        print("[Verlust] Waechter, je Lauf 40 Striche mit echter Beruehrung:\n  " + report.joined(separator: "\n  ")
              + "\n[Verlust] Gegenprobe, wie bis 17.11.2026 (Glaettung baut jeden Strich neu):\n  " + before.joined(separator: "\n  ")
              + "\n[Verlust] Gegenprobe, Neubau an mit den Sicherungen vom 17.11.:\n  " + guarded.joined(separator: "\n  "))
    }

    private func pruefeVerlust(_ r: VerlustErgebnis, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(r.fehlenInDerFlaeche, 0, "\(r.name): Striche fehlen in der Zeichenflaeche", file: file, line: line)
        XCTAssertEqual(r.inDerFlaeche, r.geschrieben, "\(r.name): Zahl der Striche in der Zeichenflaeche", file: file, line: line)
        XCTAssertEqual(r.fehlenGespeichert, 0, "\(r.name): Striche fehlen im gespeicherten Stand", file: file, line: line)
        XCTAssertEqual(r.gespeichert, r.geschrieben, "\(r.name): Zahl der gespeicherten Striche", file: file, line: line)
        XCTAssertEqual(r.zaehlerFehlt, 0, "\(r.name): der Zaehler auf dem Geraet haette einen Verlust gemeldet", file: file, line: line)
    }

    /// Ein Lauf: 40 Striche in den freien Bereich der Seite (Seitenpunkte y 280 bis 420)
    private func verlustLauf(smoothing: PencilSmoothing, shapes: Bool, vorhanden: Int, sofort: Bool) async throws -> VerlustErgebnis {
        UserDefaults.standard.set(smoothing.rawValue, forKey: PencilSmoothing.key)
        UserDefaults.standard.set(shapes, forKey: ShapeSnapSetting.key)
        var r = VerlustErgebnis()
        r.name = "Glaettung \(smoothing.rawValue), Formen \(shapes ? "an" : "aus"), \(vorhanden) Striche vorhanden\(sofort ? ", sofort nach dem Oeffnen" : "")"
        let fx = try await makeFixture(pages: 2)
        var store = try await openStore(fx)
        if vorhanden > 0 {
            store.canvasChanged(pageKey: "p1", drawing: Self.volleSeite(strokes: vorhanden, zeilen: 10))
            await store.flush()
            await store.close()
            store = try await openStore(fx)
        }
        let shown = show(store, pencilOnly: false)
        let editor = shown.editor
        var found: PageInkView?
        if sofort {
            // nicht auf das Laden warten: sobald die Seite im Bild ist, wird geschrieben
            let until = Uhr.now() + 20
            while Uhr.now() < until, found == nil {
                found = editor.allOverlays.first { $0.pageIndex == 0 && $0.window != nil && $0.bounds.width > 0 }
                if found == nil { try await Task.sleep(nanoseconds: 5_000_000) }
            }
        } else {
            found = try await waitForOverlay(editor, page: 0)
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        let overlay = try XCTUnwrap(found, "Seite 1 im Bild")
        let canvas = overlay.canvas
        overlay.rawRecorder.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        let log0 = ZeichnungSpion.log.count
        let deferred0 = editor.reloadsDeferredForLift
        let lost0 = StiftZaehler.value(.fehltNachAbsetzen)

        // Im Hintergrund: laufend "Seite neu laden", dazu ab und zu eine fremde Aenderung (ein Strich mehr im Speicher,
        // wie nach einer Zusammenfuehrung mit einem anderen Geraet)
        let running = Schalter()
        let traffic = Task { @MainActor in
            var n = 0
            // nicht beim ersten Laden (`sofort`): dort ist das Laden selbst das Ereignis, das mit dem Schreiben zusammenfaellt
            while running.an, !sofort {
                try? await Task.sleep(nanoseconds: 90_000_000)
                guard running.an else { break }
                n += 1
                if n % 6 == 0, overlay.loaded, !overlay.isDrawing {
                    var d = canvas.drawing
                    d.strokes.append(Handschrift.line(from: CGPoint(x: 40 + CGFloat(n), y: 470), to: CGPoint(x: 60 + CGFloat(n), y: 474)))
                    store.canvasChanged(pageKey: "p1", drawing: d)
                }
                store.onPagesChanged?(["p1"])
            }
        }

        var seed: UInt64 = 0x1234_5678 &+ UInt64(vorhanden) &+ UInt64(smoothing.rawValue.count)
        func random(_ range: ClosedRange<Int>) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return range.lowerBound + Int((seed >> 33) % UInt64(range.count))
        }
        let count = 40
        var wanted: [CGPoint] = []
        var lifted: [Double] = []
        var hits: [String] = []
        var liftsSeen: [Int] = []
        var reportsSeen: [Int] = []
        for i in 0..<count {
            let page = CGPoint(x: 50 + CGFloat(i % 10) * 52, y: 292 + CGFloat(i / 10) * 36)
            let a = overlay.content.convert(page, to: nil)
            var pts: [CGPoint] = []
            switch i % 5 {
            case 0:                                                          // Punkt
                pts = [a, CGPoint(x: a.x + 0.5, y: a.y + 0.5)]
            case 1:                                                          // Komma
                for k in 0...4 { pts.append(CGPoint(x: a.x - CGFloat(k) * 1.2, y: a.y + CGFloat(k) * 2.5)) }
            case 2:                                                          // kurzer Bogen
                for k in 0...8 { pts.append(CGPoint(x: a.x + CGFloat(k) * 2.5, y: a.y + sin(CGFloat(k)) * 3)) }
            case 3:                                                          // laengere gerade Linie
                for k in 0...16 { pts.append(CGPoint(x: a.x + CGFloat(k) * 4, y: a.y + CGFloat(k) * 0.2)) }
            default:                                                         // Buchstabe
                for k in 0...14 { pts.append(CGPoint(x: a.x + CGFloat(k) * 3, y: a.y + sin(CGFloat(k) / 2) * 9)) }
            }
            var lo = pts[0], hi = pts[0]
            for p in pts { lo = CGPoint(x: min(lo.x, p.x), y: min(lo.y, p.y)); hi = CGPoint(x: max(hi.x, p.x), y: max(hi.y, p.y)) }
            wanted.append(overlay.content.convert(CGPoint(x: (lo.x + hi.x) / 2, y: (lo.y + hi.y) / 2), from: nil))
            let l0 = StiftZaehler.value(.abgesetzt)
            hits.append(try await TestFinger.strich(pts, in: shown.window, step: 0.005))
            lifted.append(Uhr.now())
            liftsSeen.append(StiftZaehler.value(.abgesetzt) - l0)
            reportsSeen.append(StiftZaehler.value(.gemeldet))
            try await Task.sleep(nanoseconds: UInt64(random(20...150)) * 1_000_000)
        }
        r.geschrieben = count
        running.an = false
        _ = await traffic.value

        // warten, bis PencilKit alles gemeldet hat und die Pruefung des Zaehlers (2 s nach dem Absetzen) gelaufen ist
        try await Task.sleep(nanoseconds: 2_600_000_000)
        // die Seite ist geladen (frueh geschriebene Striche sind erst dann im Speicher)
        let loadedBy = Uhr.now() + 30
        while Uhr.now() < loadedBy, !overlay.loaded { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(overlay.loaded, "\(r.name): Seite geladen")
        if vorhanden > 0 { XCTAssertGreaterThanOrEqual(canvas.drawing.strokes.count, vorhanden + count, "\(r.name): vorhandene und neue Striche zusammen") }
        func eigene(_ d: PKDrawing) -> [CGPoint] {
            d.strokes.map { s -> CGPoint in
                let b = s.renderBounds
                return CGPoint(x: b.midX, y: b.midY)
            }.filter { $0.y > 275 && $0.y < 440 }
        }
        func fehlen(_ centers: [CGPoint]) -> Int {
            wanted.filter { w in !centers.contains { hypot($0.x - w.x, $0.y - w.y) < 10 } }.count
        }
        let onCanvas = eigene(canvas.drawing)
        r.inDerFlaeche = onCanvas.count
        r.fehlenInDerFlaeche = fehlen(onCanvas)
        r.neuGesetzt = ZeichnungSpion.log[log0...].filter { $0.canvas == ObjectIdentifier(canvas) && !$0.own }.count
        for (i, w) in wanted.enumerated() where !onCanvas.contains(where: { hypot($0.x - w.x, $0.y - w.y) < 10 }) {
            let t = lifted[i]
            let near = ZeichnungSpion.log[log0...].filter { $0.canvas == ObjectIdentifier(canvas) && abs($0.at - t) < 0.4 }
                .map { String(format: "%+.0f ms: %d -> %d%@", ($0.at - t) * 1000, $0.before, $0.after, $0.own ? " (Test)" : "") }
            let next = i + 1 < lifted.count ? String(format: "%.0f ms", (lifted[i + 1] - t) * 1000) : "-"
            let reports = (i + 1 < reportsSeen.count ? reportsSeen[i + 1] : StiftZaehler.value(.gemeldet)) - reportsSeen[i]
            r.hergang.append("Strich \(i + 1) (Art \(i % 5)) fehlt; getroffen: \(hits[i]); PencilKit meldete Absetzen \(liftsSeen[i]) Mal, bis zum naechsten Strich Zeichnung geaendert \(reports) Mal; naechster Strich abgesetzt nach \(next); Zeichnung neu gesetzt um sein Absetzen: \(near.isEmpty ? "nie" : near.joined(separator: ", "))")
        }
        r.verschoben = editor.reloadsDeferredForLift - deferred0
        r.zaehlerFehlt = StiftZaehler.value(.fehltNachAbsetzen) - lost0
        await store.flush()
        await store.close()
        hide(shown)
        // gespeicherter Stand: neu oeffnen und zaehlen
        let again = try await openStore(fx)
        let saved = eigene(await again.drawing(forPageKey: "p1"))
        r.gespeichert = saved.count
        r.fehlenGespeichert = fehlen(saved)
        await again.close()
        return r
    }

    /// Was macht PencilKit, wenn die Zeichnung neu gesetzt wird, waehrend ein Strich abgesetzt, aber noch nicht gemeldet
    /// ist? (Das passierte bis 17.11.2026, wenn in diesem Moment eine Seite geladen oder neu geladen wurde.) Messung:
    /// zwoelf Striche, nach jedem Absetzen sofort neu gesetzt - wie viele bleiben?
    func testMessungNeuSetzenZwischenAbsetzenUndMeldung() async throws {
        try XCTSkipUnless(TestFinger.verfuegbar, "Beruehrung laesst sich in dieser iOS-Version nicht nachstellen")
        var out: [String] = []
        for delay in [0, 1, 8, 30] {
            let fx = try await makeFixture(pages: 2)
            let store = try await openStore(fx)
            let shown = show(store, pencilOnly: false)
            let overlay = try await waitForOverlay(shown.editor, page: 0)
            let canvas = overlay.canvas
            try await Task.sleep(nanoseconds: 800_000_000)
            var reportedBeforeSet = 0
            for i in 0..<12 {
                let a = overlay.content.convert(CGPoint(x: 60 + CGFloat(i % 6) * 80, y: 200 + CGFloat(i / 6) * 60), to: nil)
                var pts: [CGPoint] = []
                for k in 0...10 { pts.append(CGPoint(x: a.x + CGFloat(k) * 3, y: a.y + sin(CGFloat(k) / 2) * 8)) }
                let n0 = canvas.drawing.strokes.count
                let finger = TestFinger(at: pts[0], in: shown.window)
                for p in pts.dropFirst() {
                    try await Task.sleep(nanoseconds: 6_000_000)
                    finger.move(to: p)
                }
                finger.lift()
                if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000) }
                if canvas.drawing.strokes.count > n0 { reportedBeforeSet += 1 }
                // wie `apply`: der Stand ohne den Strich, der noch unterwegs ist
                let d = canvas.drawing
                ZeichnungSpion.own = true
                overlay.isApplyingDrawing = true
                canvas.drawing = d
                overlay.isApplyingDrawing = false
                ZeichnungSpion.own = false
                try await Task.sleep(nanoseconds: 350_000_000)
            }
            try await Task.sleep(nanoseconds: 1_500_000_000)
            out.append("neu gesetzt \(delay) ms nach dem Absetzen: von 12 Strichen bleiben \(canvas.drawing.strokes.count) (davon waren \(reportedBeforeSet) beim Neu-Setzen schon gemeldet)")
            await store.close()
            hide(shown)
        }
        print("[Verlust] PencilKit, Zeichnung neu gesetzt zwischen Absetzen und Meldung:\n  " + out.joined(separator: "\n  "))
    }
    /// Wie lange nach einem Neu-Setzen der Zeichnung verliert PencilKit einen Strich, der dann beginnt? Messung: nach
    /// dem Neu-Setzen `d` ms warten, dann ein Punkt bzw. ein kurzer Strich; je Abstand zehn Mal.
    func testMessungStrichKurzNachDemNeuSetzen() async throws {
        try XCTSkipUnless(TestFinger.verfuegbar, "Beruehrung laesst sich in dieser iOS-Version nicht nachstellen")
        var out: [String] = []
        for vorhanden in [0, 400] {
            let fx = try await makeFixture(pages: 2)
            var store = try await openStore(fx)
            if vorhanden > 0 {
                store.canvasChanged(pageKey: "p1", drawing: Self.volleSeite(strokes: vorhanden, zeilen: 10))
                await store.flush()
                await store.close()
                store = try await openStore(fx)
            }
            let shown = show(store, pencilOnly: false)
            let overlay = try await waitForOverlay(shown.editor, page: 0)
            let canvas = overlay.canvas
            try await Task.sleep(nanoseconds: 1_000_000_000)
            var n = 0
            for kind in ["Punkt", "kurzer Strich"] {
                var line: [String] = []
                for delay in [0, 4, 8, 16, 30, 50, 80, 120, 200] {
                    var kept = 0
                    for _ in 0..<10 {
                        let a = overlay.content.convert(CGPoint(x: 40 + CGFloat(n % 24) * 22, y: 290 + CGFloat((n / 24) % 7) * 20), to: nil)
                        n += 1
                        let d = canvas.drawing
                        ZeichnungSpion.own = true
                        overlay.isApplyingDrawing = true
                        canvas.drawing = d
                        overlay.isApplyingDrawing = false
                        ZeichnungSpion.own = false
                        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000) }
                        let n0 = canvas.drawing.strokes.count
                        var pts = [a, CGPoint(x: a.x + 0.5, y: a.y + 0.5)]
                        if kind != "Punkt" { pts = (0...8).map { CGPoint(x: a.x + CGFloat($0) * 1.5, y: a.y + sin(CGFloat($0)) * 3) } }
                        try await TestFinger.strich(pts, in: shown.window, step: 0.005)
                        let until = Uhr.now() + 0.7
                        while Uhr.now() < until, canvas.drawing.strokes.count == n0 { try await Task.sleep(nanoseconds: 10_000_000) }
                        if canvas.drawing.strokes.count > n0 { kept += 1 }
                        try await Task.sleep(nanoseconds: 120_000_000)
                    }
                    line.append("\(delay) ms: \(kept)/10")
                }
                out.append("\(vorhanden) Striche vorhanden, \(kind) nach dem Neu-Setzen - angekommen: " + line.joined(separator: ", "))
            }
            await store.close()
            hide(shown)
        }
        print("[Verlust] PencilKit, Strich beginnt kurz NACH einem Neu-Setzen der Zeichnung:\n  " + out.joined(separator: "\n  "))
    }
    /// Eingrenzung des Verlusts: Strich A, dann nach `d` ms Strich B (ein Komma). Kommt B an? Vier Faelle: (0) nichts
    /// wird neu gesetzt, (1) der Editor ersetzt A beim Melden (Glaettung "Leicht") mit Deckbild, (2) dasselbe ohne
    /// Deckbild, (3) Glaettung "Normal", aber die Zeichnung wird gleich nach der Meldung von A unveraendert neu gesetzt.
    func testMessungZweiterStrichNachErsetzenDesErsten() async throws {
        try XCTSkipUnless(TestFinger.verfuegbar, "Beruehrung laesst sich in dieser iOS-Version nicht nachstellen")
        PencilTuning.rebuildFromRawPointsAfterLift = true                   // Gegenprobe-Schalter: der Editor ersetzt A
        var out: [String] = []
        let faelle: [(String, PencilSmoothing, Bool, Bool)] = [
            ("nichts neu gesetzt", .normal, true, false),
            ("Editor ersetzt A, mit Deckbild", .light, true, false),
            ("Editor ersetzt A, ohne Deckbild", .light, false, false),
            ("unveraendert neu gesetzt nach der Meldung von A", .normal, true, true),
        ]
        for (name, smoothing, cover, plainSet) in faelle {
            UserDefaults.standard.set(smoothing.rawValue, forKey: PencilSmoothing.key)
            PencilTuning.coverWhenStrokeIsReplaced = cover
            let fx = try await makeFixture(pages: 2)
            let store = try await openStore(fx)
            let shown = show(store, pencilOnly: false)
            let overlay = try await waitForOverlay(shown.editor, page: 0)
            let canvas = overlay.canvas
            overlay.rawRecorder.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.pencil.rawValue)]
            try await Task.sleep(nanoseconds: 1_000_000_000)
            var n = 0
            var line: [String] = []
            var t0 = Uhr.now()
            var trace: [String] = []
            var shownTraces = 0
            shown.editor.inkTrace = { trace.append(String(format: "%+.0f ms %@", (Uhr.now() - t0) * 1000, $0)) }
            for gap in [0, 8, 16, 25, 35, 50, 70, 100, 160] {
                var kept = 0, replaced = 0
                for _ in 0..<10 {
                    trace = []
                    let a = overlay.content.convert(CGPoint(x: 40 + CGFloat(n % 10) * 52, y: 120 + CGFloat((n / 10) % 9) * 34), to: nil)
                    n += 1
                    let n0 = canvas.drawing.strokes.count
                    let log0 = ZeichnungSpion.log.count
                    var ptsA: [CGPoint] = []
                    for k in 0...8 { ptsA.append(CGPoint(x: a.x + CGFloat(k) * 2.5, y: a.y + sin(CGFloat(k)) * 3)) }
                    try await TestFinger.strich(ptsA, in: shown.window, step: 0.005)
                    t0 = Uhr.now()
                    trace.append("0 ms A abgesetzt")
                    // Fall 3: sobald A gemeldet ist, die Zeichnung unveraendert neu setzen (neben dem Schreiben her)
                    let setter = Task { @MainActor in
                        guard plainSet else { return }
                        let until = Uhr.now() + 0.5
                        while Uhr.now() < until, canvas.drawing.strokes.count == n0 { try? await Task.sleep(nanoseconds: 1_000_000) }
                        let d = canvas.drawing
                        overlay.isApplyingDrawing = true
                        canvas.drawing = d
                        overlay.isApplyingDrawing = false
                    }
                    if gap > 0 { try await Task.sleep(nanoseconds: UInt64(gap) * 1_000_000) }
                    var ptsB: [CGPoint] = []
                    for k in 0...4 { ptsB.append(CGPoint(x: a.x + 30 - CGFloat(k) * 1.2, y: a.y + CGFloat(k) * 2.5)) }
                    trace.append(String(format: "%+.0f ms B setzt auf", (Uhr.now() - t0) * 1000))
                    try await TestFinger.strich(ptsB, in: shown.window, step: 0.005)
                    trace.append(String(format: "%+.0f ms B abgesetzt", (Uhr.now() - t0) * 1000))
                    _ = await setter.value
                    let until = Uhr.now() + 0.8
                    while Uhr.now() < until, canvas.drawing.strokes.count < n0 + 2 { try await Task.sleep(nanoseconds: 10_000_000) }
                    if canvas.drawing.strokes.count >= n0 + 2 { kept += 1 } else if shownTraces < 3 {
                        shownTraces += 1
                        out.append("   >> \(name), Abstand \(gap) ms, B fehlt: " + trace.joined(separator: "; "))
                    }
                    if ZeichnungSpion.log[log0...].contains(where: { $0.canvas == ObjectIdentifier(canvas) && !$0.own }) { replaced += 1 }
                    try await Task.sleep(nanoseconds: 150_000_000)
                }
                line.append("\(gap) ms: \(kept)/10" + (replaced > 0 ? " (neu gesetzt in \(replaced))" : ""))
            }
            out.append("\(name) - B angekommen bei Abstand: " + line.joined(separator: ", "))
            await store.close()
            hide(shown)
        }
        print("[Verlust] Strich B kurz nach Strich A:\n  " + out.joined(separator: "\n  "))
    }
}

/// Schalter fuer eine Aufgabe im Hintergrund eines Tests
@MainActor
final class Schalter {
    var an = true
}
