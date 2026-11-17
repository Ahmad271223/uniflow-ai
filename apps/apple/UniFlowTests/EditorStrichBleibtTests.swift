import PDFKit
import PencilKit
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Meldung des Inhabers vom echten iPad, 16.11.2026: "wenn man was schreibt geht es kurz weg dann - das darf nicht
/// passieren". Die bisherigen Tests zaehlten nur, ob die Tinte am Ende da ist. Hier wird nach jedem abgesetzten
/// Strich einige Sekunden lang in kurzen Abstaenden geprueft, dass
/// 1. die Zeichnung der Zeichenflaeche nie kleiner wird und vom Programm nie neu gesetzt wird (jedes Neu-Setzen baut
///    bei PencilKit alle Striche der Seite neu auf: sie verschwinden kurz),
/// 2. nichts ueber oder unter die Zeichenflaeche gelegt wird (Deckbild, Bild der Handschrift), sie sichtbar bleibt
///    und ihre Zoomstufe behaelt,
/// 3. Seite und Editor dieselben bleiben (kein Neuaufbau),
/// 4. der Strich im Bild des Fensters zu sehen bleibt (echte Beruehrung, `TestFinger`).
/// Zeilen "[Strich]" im Testprotokoll sind die Messwerte.
@MainActor
final class EditorStrichBleibtTests: XCTestCase {

    override func setUp() async throws {
        ZeichnungSpion.install()
        UserDefaults.standard.removeObject(forKey: PencilSmoothing.key)
        UserDefaults.standard.removeObject(forKey: ShapeSnapSetting.key)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: PencilSmoothing.key)
        UserDefaults.standard.removeObject(forKey: ShapeSnapSetting.key)
        // Gegenproben stellen diese Schalter um: immer zurueck auf den Stand der App
        PencilTuning.rebuildFromRawPointsAfterLift = false
        PencilTuning.liftBelongsToItsStroke = true
        PencilTuning.coverWhenStrokeIsReplaced = true
    }

    // MARK: Strich wie von PencilKit gemeldet (Zeichnung gesetzt, Meldungen von Hand)

    func testEinStrichBleibtStehen() async throws {
        for order in [Reihenfolge.meldungZuerst, .absetzenZuerst] {
            let r = try await lauf("ein Strich, \(order)", strokes: 1, vorhanden: 0, order: order, warten: 6)
            pruefe(r, erlaubtNeu: 0)
        }
    }

    func testSchnellMehrereStricheBleibenStehen() async throws {
        let r = try await lauf("acht Striche schnell hintereinander", strokes: 8, abstand: 0.12, vorhanden: 0, order: .absetzenZuerst, warten: 6)
        pruefe(r, erlaubtNeu: 0)
    }

    /// Volle Seite: Die Schreibpause bis zum Sichern der Seite ist dort laenger (Speicherweg Stufe A3), die Runden
    /// laufen waehrend der Beobachtung
    func testStrichAufVollerSeiteBleibtStehen() async throws {
        let r = try await lauf("drei Striche auf einer Seite mit 450 Strichen", strokes: 3, abstand: 0.4, vorhanden: 450, order: .absetzenZuerst, warten: 14)
        pruefe(r, erlaubtNeu: 0)
    }

    func testStrichDannLangeWarten() async throws {
        let r = try await lauf("ein Strich auf 120 Strichen, dann 10 s warten", strokes: 1, vorhanden: 120, order: .absetzenZuerst, warten: 10)
        pruefe(r, erlaubtNeu: 0)
    }

    func testTextmarkerBleibtStehen() async throws {
        let r = try await lauf("Textmarker, drei Striche", strokes: 3, abstand: 0.3, vorhanden: 60, order: .absetzenZuerst, warten: 6, tool: .marker)
        pruefe(r, erlaubtNeu: 0)
    }

    /// Glaettung "Aus"/"Leicht" setzt seit 17.11.2026 nichts mehr neu (abgeschaltet, `PencilTuning`): wie "Normal".
    func testGlaettungAusUndLeichtSetzenNichtsMehrNeu() async throws {
        for smoothing in [PencilSmoothing.off, .light] {
            UserDefaults.standard.set(smoothing.rawValue, forKey: PencilSmoothing.key)
            let r = try await lauf("Glaettung \(smoothing.rawValue), abgeschaltet, zwei Striche", strokes: 2, abstand: 0.4, vorhanden: 60,
                                   order: .absetzenZuerst, warten: 4, rohpunkte: true)
            pruefe(r, erlaubtNeu: 0)
        }
    }

    /// Gegenprobe mit dem Schalter (so war es bis 17.11.2026): Der Strich wird beim Absetzen einmal durch den aus den
    /// Messpunkten ersetzt - genau einmal je Strich, nie kleiner.
    func testGlaettungAusUndLeichtSetzenJeStrichEinmal() async throws {
        PencilTuning.rebuildFromRawPointsAfterLift = true
        for smoothing in [PencilSmoothing.off, .light] {
            UserDefaults.standard.set(smoothing.rawValue, forKey: PencilSmoothing.key)
            let r = try await lauf("Glaettung \(smoothing.rawValue), zwei Striche", strokes: 2, abstand: 0.4, vorhanden: 60, order: .absetzenZuerst,
                                   warten: 6, rohpunkte: true, deckbild: true)
            pruefe(r, erlaubtNeu: 2)
        }
    }

    /// Formerkennung aus: nichts wird ersetzt. An (Standard) und am Ende gehalten: einmal ersetzt.
    func testFormerkennung() async throws {
        UserDefaults.standard.set(false, forKey: ShapeSnapSetting.key)
        var r = try await lauf("Formerkennung aus, Linie gehalten", strokes: 1, vorhanden: 60, order: .absetzenZuerst, warten: 5, gehalten: true)
        pruefe(r, erlaubtNeu: 0)
        UserDefaults.standard.removeObject(forKey: ShapeSnapSetting.key)
        r = try await lauf("Formerkennung an, Linie gehalten", strokes: 1, vorhanden: 60, order: .absetzenZuerst, warten: 5, gehalten: true, deckbild: true)
        pruefe(r, erlaubtNeu: 1)
    }

    // MARK: Echte Beruehrung: PencilKit zeichnet und meldet selbst

    func testEchterStrichMitDemFingerBleibtSichtbar() async throws {
        try XCTSkipUnless(TestFinger.verfuegbar, "Beruehrung laesst sich in dieser iOS-Version nicht nachstellen")
        let r = try await lauf("echte Beruehrung, ein Strich", strokes: 1, vorhanden: 0, order: .echt, warten: 6)
        pruefe(r, erlaubtNeu: 0)
        XCTAssertTrue(r.sichtbarGemessen, "Messaufbau: der Strich ist im Bild des Fensters zu sehen")
    }

    func testEchteStricheSchnellHintereinander() async throws {
        try XCTSkipUnless(TestFinger.verfuegbar, "Beruehrung laesst sich in dieser iOS-Version nicht nachstellen")
        let r = try await lauf("echte Beruehrung, sechs Striche schnell", strokes: 6, abstand: 0.15, vorhanden: 0, order: .echt, warten: 6)
        pruefe(r, erlaubtNeu: 0)
    }

    func testEchterStrichAufVollerSeite() async throws {
        try XCTSkipUnless(TestFinger.verfuegbar, "Beruehrung laesst sich in dieser iOS-Version nicht nachstellen")
        let r = try await lauf("echte Beruehrung, drei Striche auf 450 Strichen", strokes: 3, abstand: 0.5, vorhanden: 450, order: .echt, warten: 14)
        pruefe(r, erlaubtNeu: 0)
    }

    func testEchterStrichMitTextmarker() async throws {
        try XCTSkipUnless(TestFinger.verfuegbar, "Beruehrung laesst sich in dieser iOS-Version nicht nachstellen")
        let r = try await lauf("echte Beruehrung, Textmarker", strokes: 2, abstand: 0.4, vorhanden: 60, order: .echt, warten: 6, tool: .marker)
        pruefe(r, erlaubtNeu: 0)
    }

    // MARK: Auftrag 17.11.2026: Stift absetzen (Flackern, Verlust), auf dem alten Editor

    /// Schnelles Schreiben: Der zweite Strich setzt auf, bevor PencilKit den ersten gemeldet hat (die Meldung kommt
    /// dann waehrend des zweiten Strichs). Beim Absetzen des zweiten darf der ERSTE nicht mit den Daten des zweiten
    /// behandelt werden: nicht aus dessen Messpunkten neu gebaut (er laege dann auf dem zweiten, der erste waere weg)
    /// und nicht als "am Ende gehalten" zur Form gemacht.
    func testZweiterStrichSetztAufBevorDerErsteGemeldetIst() async throws {
        PencilTuning.rebuildFromRawPointsAfterLift = true                   // mit Neubau aus den Messpunkten (Gegenprobe-Schalter)
        let faelle: [(String, PencilSmoothing, Bool)] = [("Glaettung Aus", .off, false), ("Glaettung Leicht", .light, false),
                                                          ("Standard, erster Strich eine Linie", .normal, true)]
        for (name, smoothing, linie) in faelle {
            UserDefaults.standard.set(smoothing.rawValue, forKey: PencilSmoothing.key)
            let fx = try await makeFixture(pages: 2)
            let store = try await openStore(fx)
            let shown = show(store, pencilOnly: true)
            let editor = shown.editor
            let overlay = try await waitForOverlay(editor, page: 0)
            let canvas = overlay.canvas
            let s1 = linie ? Self.gerade(from: CGPoint(x: 120, y: 250), to: CGPoint(x: 240, y: 252), vor: 1.0)
                           : Self.strich(at: CGPoint(x: 120, y: 250), n: 0, marker: false, gehalten: false)
            let s2 = Self.strich(at: CGPoint(x: 330, y: 330), n: 1, marker: false, gehalten: false)
            let m1 = Self.mitte(s1), m2 = Self.mitte(s2)
            let log0 = ZeichnungSpion.log.count
            func setze(_ stroke: PKStroke) {
                var d = canvas.drawing
                d.strokes.append(stroke)
                ZeichnungSpion.own = true
                overlay.isApplyingDrawing = true
                canvas.drawing = d
                overlay.isApplyingDrawing = false
                ZeichnungSpion.own = false
            }
            // Strich 1: aufsetzen, absetzen - noch nicht gemeldet
            editor.canvasViewDidBeginUsingTool(canvas)
            overlay.rawRecorder.setSamplesForTesting(Self.rohpunkte(s1))
            editor.canvasViewDidEndUsingTool(canvas)
            // Strich 2 setzt auf; jetzt erst meldet PencilKit Strich 1
            editor.canvasViewDidBeginUsingTool(canvas)
            setze(s1)
            editor.canvasViewDrawingDidChange(canvas)
            try await Task.sleep(nanoseconds: 650_000_000)                  // der zweite Strich dauert
            overlay.rawRecorder.setSamplesForTesting(Self.rohpunkte(s2))
            editor.canvasViewDidEndUsingTool(canvas)
            let nachAbsetzen = canvas.drawing
            XCTAssertEqual(nachAbsetzen.strokes.count, 1, "\(name): Strich 2 ist noch nicht gemeldet")
            let ort1 = nachAbsetzen.strokes.first.map { Self.mitte($0) } ?? .zero
            XCTAssertLessThan(hypot(ort1.x - m1.x, ort1.y - m1.y), 6, "\(name): der erste Strich liegt noch an seiner Stelle (\(ort1) statt \(m1))")
            if linie {
                XCTAssertEqual(nachAbsetzen.strokes.first?.path.count, s1.path.count, "\(name): der erste Strich ist nicht zur Form geworden")
            }
            setze(s2)
            editor.canvasViewDrawingDidChange(canvas)
            try await Task.sleep(nanoseconds: 400_000_000)
            let d = canvas.drawing
            XCTAssertEqual(d.strokes.count, 2, "\(name): beide Striche da")
            let orte = d.strokes.map { Self.mitte($0) }
            if orte.count == 2 {
                XCTAssertLessThan(hypot(orte[0].x - m1.x, orte[0].y - m1.y), 6, "\(name): Strich 1 an seiner Stelle")
                XCTAssertLessThan(hypot(orte[1].x - m2.x, orte[1].y - m2.y), 6, "\(name): Strich 2 an seiner Stelle")
            }
            let sets = ZeichnungSpion.log[log0...].filter { $0.canvas == ObjectIdentifier(canvas) && !$0.own }
            let wo = orte.map { "\(Int($0.x)),\(Int($0.y))" }.joined(separator: " und ")
            print("[Strich] verschraenkt, \(name): gezeichnet bei \(Int(m1.x)),\(Int(m1.y)) und \(Int(m2.x)),\(Int(m2.y)); danach liegen die Striche bei \(wo); vom Programm neu gesetzt \(sets.count) Mal")
            if smoothing == .normal { XCTAssertEqual(sets.count, 0, "\(name): nichts wird ersetzt") }
            await store.flush()
            let saved = await store.objects(forPageKey: "p1").filter { $0["type"]?.string == "stroke" }.count
            XCTAssertEqual(saved, 2, "\(name): gespeichert")
            await store.close()
            hide(shown)
        }
    }

    /// Viele kurze Striche schnell hintereinander mit echter Beruehrung (Punkte, i-Punkte, Kommas): Keiner geht
    /// verloren, jeder bleibt an seiner Stelle - mit Glaettung Standard, Leicht und Aus.
    func testVieleKurzeStricheSchnellHintereinanderGehenNichtVerloren() async throws {
        try XCTSkipUnless(TestFinger.verfuegbar, "Beruehrung laesst sich in dieser iOS-Version nicht nachstellen")
        for smoothing in [PencilSmoothing.normal, .light, .off] {
            UserDefaults.standard.set(smoothing.rawValue, forKey: PencilSmoothing.key)
            let fx = try await makeFixture(pages: 2)
            let store = try await openStore(fx)
            let shown = show(store, pencilOnly: false)
            let editor = shown.editor
            let overlay = try await waitForOverlay(editor, page: 0)
            // im Simulator gibt es keinen Pencil: die Messpunkte kommen hier vom Finger
            overlay.rawRecorder.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.pencil.rawValue)]
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let canvas = overlay.canvas
            let log0 = ZeichnungSpion.log.count
            let rebuilds0 = editor.rawRebuilds
            let count = 36
            var wanted: [CGPoint] = []
            for i in 0..<count {
                let page = CGPoint(x: 90 + CGFloat(i % 12) * 34, y: 200 + CGFloat(i / 12) * 34)
                let a = overlay.content.convert(page, to: nil)
                var pts: [CGPoint] = []
                switch i % 3 {
                case 0:                                                      // Punkt
                    pts = [a, CGPoint(x: a.x + 0.5, y: a.y + 0.5)]
                case 1:                                                      // Komma
                    for k in 0...4 { pts.append(CGPoint(x: a.x - CGFloat(k) * 1.2, y: a.y + CGFloat(k) * 2.5)) }
                default:                                                     // kurzer Bogen
                    for k in 0...8 { pts.append(CGPoint(x: a.x + CGFloat(k) * 2.5, y: a.y + sin(CGFloat(k)) * 3)) }
                }
                let mid = CGPoint(x: (pts[0].x + pts[pts.count - 1].x) / 2, y: (pts[0].y + pts[pts.count - 1].y) / 2)
                wanted.append(overlay.content.convert(mid, from: nil))
                try await TestFinger.strich(pts, in: shown.window, step: 0.006)
                try await Task.sleep(nanoseconds: 45_000_000)                // sofort der naechste
            }
            let until = Uhr.now() + 4
            while Uhr.now() < until, canvas.drawing.strokes.count < count { try await Task.sleep(nanoseconds: 20_000_000) }
            try await Task.sleep(nanoseconds: 1_200_000_000)
            let strokes = canvas.drawing.strokes
            let mitten = strokes.map { Self.mitte($0) }
            // jede gewollte Stelle hat einen Strich in der Naehe
            var missing = 0
            for w in wanted where !mitten.contains(where: { hypot($0.x - w.x, $0.y - w.y) < 9 }) { missing += 1 }
            let sets = ZeichnungSpion.log[log0...].filter { $0.canvas == ObjectIdentifier(canvas) && !$0.own }
            let shrunk = sets.filter { $0.after < $0.before }.count
            print("[Strich] \(count) kurze Striche schnell, Glaettung \(smoothing.rawValue): \(strokes.count) Striche in der Zeichnung, \(missing) Stellen ohne Strich; vom Programm neu gesetzt \(sets.count) Mal, davon mit weniger Strichen \(shrunk); aus Messpunkten neu gebaut \(editor.rawRebuilds - rebuilds0)")
            XCTAssertEqual(strokes.count, count, "Glaettung \(smoothing.rawValue): kein Strich verloren")
            XCTAssertEqual(missing, 0, "Glaettung \(smoothing.rawValue): jeder Strich an seiner Stelle")
            XCTAssertEqual(shrunk, 0, "Glaettung \(smoothing.rawValue): die Zeichnung wurde nie kleiner gesetzt")
            XCTAssertEqual(sets.count, 0, "Glaettung \(smoothing.rawValue): nach einem normalen Strich wird nichts neu gesetzt")
            await store.flush()
            let saved = await store.objects(forPageKey: "p1").filter { $0["type"]?.string == "stroke" }.count
            XCTAssertEqual(saved, count, "Glaettung \(smoothing.rawValue): gespeichert")
            await store.close()
            hide(shown)
        }
    }

    /// Bild fuer Bild: Nach dem Absetzen eines echten Strichs wird gut 1 s lang in jedem Durchlauf der Hauptschleife
    /// das Bild des Fensters geprueft - die Tinte des neuen Strichs fehlt in keinem. Mit Glaettung Standard (nichts
    /// wird ersetzt) und Aus bzw. Leicht (der Strich wird beim Absetzen einmal durch den aus den Messpunkten ersetzt).
    func testNeuerStrichFehltInKeinemBildNachDemAbsetzen() async throws {
        try XCTSkipUnless(TestFinger.verfuegbar, "Beruehrung laesst sich in dieser iOS-Version nicht nachstellen")
        // mit Neubau aus den Messpunkten (Gegenprobe-Schalter): das Ersetzen selbst darf nicht blitzen; so bleibt auch
        // die erkannte Form ohne Luecke (dasselbe Ersetzen)
        PencilTuning.rebuildFromRawPointsAfterLift = true
        // letzter Fall: Gegenprobe ohne Deckbild (so war es bis 17.11.2026) - dort fehlt die Tinte in einzelnen Bildern
        let faelle: [(PencilSmoothing, Int, Bool)] = [(.normal, 0, true), (.off, 0, true), (.light, 300, true), (.off, 900, true), (.off, 300, false)]
        addTeardownBlock { @MainActor in PencilTuning.coverWhenStrokeIsReplaced = true }
        for (smoothing, vorhanden, deckbild) in faelle {
            PencilTuning.coverWhenStrokeIsReplaced = deckbild
            UserDefaults.standard.set(smoothing.rawValue, forKey: PencilSmoothing.key)
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
            let overlay = try await waitForOverlay(editor, page: 0)
            overlay.rawRecorder.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.pencil.rawValue)]
            editor.tools.setWidth(6, for: .pen)                             // kraeftig, damit die Pixel sicher zaehlen
            editor.tools.select(.pen)
            try await Task.sleep(nanoseconds: 1_500_000_000)
            let canvas = overlay.canvas
            var worst = 1.0, frames = 0, gaps = 0, sets = 0
            let rebuilds0 = editor.rawRebuilds
            // die uebrige Schrift der Seite (oben): fehlt sie beim Ersetzen auch?
            let rest = overlay.content.convert(CGRect(x: 30, y: 36, width: 320, height: 70), to: nil)
            let restFull = vorhanden > 0 ? Self.dunkel(shown.window, rest) : 0
            var restLeast = restFull
            for i in 0..<4 {
                // freie Stelle unter der vorhandenen Schrift (die fuellt die oberen zehn Zeilen)
                let a = overlay.content.convert(CGPoint(x: 110 + CGFloat(i) * 110, y: 330), to: nil)
                var pts: [CGPoint] = []
                for k in 0...22 { pts.append(CGPoint(x: a.x + CGFloat(k) * 4, y: a.y + sin(CGFloat(k) / 3) * 14)) }
                let region = CGRect(x: a.x - 8, y: a.y - 26, width: 104, height: 52)
                let before = Self.dunkel(shown.window, region)
                let log0 = ZeichnungSpion.log.count
                let n0 = canvas.drawing.strokes.count
                let finger = TestFinger(at: pts[0], in: shown.window)
                for p in pts.dropFirst() {
                    try await Task.sleep(nanoseconds: 8_000_000)
                    finger.move(to: p)
                }
                try await Task.sleep(nanoseconds: 30_000_000)
                let drawn = Self.dunkel(shown.window, region) - before          // Tinte des laufenden Strichs, Finger liegt noch auf
                finger.lift()
                var least = Int.max
                var series: [Int] = []
                let end = Uhr.now() + 1.2
                while Uhr.now() < end {
                    let now = Self.dunkel(shown.window, region) - before
                    least = min(least, now)
                    series.append(now)
                    frames += 1
                    if vorhanden > 0, frames % 2 == 0 { restLeast = min(restLeast, Self.dunkel(shown.window, rest)) }
                    await Task.yield()
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
                let final = series.last ?? 0
                XCTAssertGreaterThan(final, 150, "Messaufbau: der Strich ist im Bild zu sehen (\(final) dunkle Pixel)")
                XCTAssertEqual(canvas.drawing.strokes.count, n0 + 1, "Strich angenommen")
                let ratio = final > 0 ? Double(least) / Double(final) : 0
                worst = min(worst, ratio)
                if ratio < 0.6 { gaps += 1 }
                sets += ZeichnungSpion.log[log0...].filter { $0.canvas == ObjectIdentifier(canvas) && !$0.own }.count
                if i == 0 {
                    let verlauf = series.prefix(40).map(String.init).joined(separator: " ")
                    print("[Strich]   Verlauf dunkle Pixel (Strich 1, Glaettung \(smoothing.rawValue), \(vorhanden) vorhanden): beim Schreiben \(drawn), danach \(verlauf)")
                }
            }
            let restText = vorhanden > 0 ? "; uebrige Schrift der Seite mindestens \(restFull > 0 ? restLeast * 100 / restFull : 100) % zu sehen" : ""
            print("[Strich] Bild fuer Bild, Glaettung \(smoothing.rawValue), \(vorhanden) Striche vorhanden, \(deckbild ? "mit Deckbild" : "OHNE Deckbild (Gegenprobe, wie vorher)"): 4 Striche, \(frames) Bilder; wenigste Tinte \(Int(worst * 100)) % des Endstands; Striche mit Luecke \(gaps); vom Programm neu gesetzt \(sets) Mal; aus Messpunkten neu gebaut \(editor.rawRebuilds - rebuilds0)\(restText)")
            if deckbild {
                XCTAssertEqual(gaps, 0, "Glaettung \(smoothing.rawValue): die Tinte des neuen Strichs fehlt in keinem Bild")
                if vorhanden > 0 { XCTAssertGreaterThan(restLeast * 100, restFull * 90, "die uebrige Schrift der Seite bleibt zu sehen") }
            }
            if smoothing != .normal { XCTAssertEqual(editor.rawRebuilds - rebuilds0, 4, "Messaufbau: jeder Strich wurde aus den Messpunkten neu gebaut") }
            await store.close()
            hide(shown)
        }
    }

    /// Zaehlung je abgesetztem Strich in jeder Kombination der Einstellungen: wie oft setzt das Programm die Zeichnung
    /// neu, wechselt die Zoomstufe der Zeichenflaeche, legt ein Deckbild.
    func testZaehlungJeStrichInAllenEinstellungen() async throws {
        let fx = try await makeFixture(pages: 2)
        let store = try await openStore(fx)
        let shown = show(store, pencilOnly: true)
        defer { hide(shown) }
        let editor = shown.editor
        let overlay = try await waitForOverlay(editor, page: 0)
        let canvas = overlay.canvas
        try await Task.sleep(nanoseconds: 800_000_000)
        var lines: [String: [String]] = [:]
        var order: [String] = []
        var n = 0, unexpected = 0
        let tools: [EditorToolState.Tool] = [.pen, .fineliner, .marker]
        for smoothing in [PencilSmoothing.normal, .light, .off] {
            UserDefaults.standard.set(smoothing.rawValue, forKey: PencilSmoothing.key)
            for shapes in [true, false] {
                UserDefaults.standard.set(shapes, forKey: ShapeSnapSetting.key)
                for ruler in [false, true] {
                    for tool in tools {
                        for width in tool.widths {
                            for held in [false, true] {
                                editor.tools.setWidth(width, for: tool)
                                editor.tools.select(tool)
                                canvas.isRulerActive = ruler
                                let log0 = ZeichnungSpion.log.count, z0 = PageInkView.rescalesMade, c0 = PageInkView.coversMade
                                let before = canvas.drawing.strokes.count
                                let p = CGPoint(x: 40 + CGFloat(n % 3) * 170, y: 40 + CGFloat((n / 3) % 18) * 40)
                                let stroke = Self.strich(at: p, n: n, marker: tool == .marker, gehalten: held)
                                Self.meldeStrich(stroke, on: overlay, editor: editor, order: .absetzenZuerst, rohpunkte: true)
                                n += 1
                                let sets = ZeichnungSpion.log[log0...].filter { $0.canvas == ObjectIdentifier(canvas) && !$0.own }
                                let zooms = PageInkView.rescalesMade - z0, covers = PageInkView.coversMade - c0
                                XCTAssertEqual(canvas.drawing.strokes.count, before + 1)
                                XCTAssertTrue(sets.allSatisfy { $0.after == $0.before }, "nie kleiner gesetzt")
                                XCTAssertEqual(zooms, 0, "kein Zoomwechsel der Zeichenflaeche beim Absetzen")
                                // ersetzt wird nur noch eine erkannte Form (am Ende gehalten, nicht Textmarker); die
                                // Glaettung setzt nichts mehr neu (abgeschaltet, `PencilTuning`)
                                let mayReplace = shapes && held && tool != .marker
                                if !mayReplace, !sets.isEmpty { unexpected += 1 }
                                XCTAssertLessThanOrEqual(sets.count, 1, "hoechstens einmal je Strich")
                                let key = "Glaettung \(smoothing.rawValue), Formen \(shapes ? "an" : "aus"), Lineal \(ruler ? "an" : "aus"), \(tool.rawValue), \(held ? "am Ende gehalten" : "normal")"
                                if lines[key] == nil { order.append(key) }
                                lines[key, default: []].append("\(sets.count)/\(zooms)/\(covers)")
                            }
                        }
                    }
                }
            }
        }
        canvas.isRulerActive = false
        var report: [String] = []
        for key in order {
            let values = lines[key] ?? []
            let same = Set(values).count == 1
            report.append("\(key): " + (same ? "\(values[0]) bei allen \(values.count) Staerken" : values.joined(separator: " ")))
        }
        print("[Strich] Zaehlung je Strich (neu gesetzt/Zoomwechsel/Deckbild), \(n) Striche:\n  " + report.joined(separator: "\n  "))
        XCTAssertEqual(unexpected, 0, "ohne erkannte Form wird in keiner Einstellung neu gesetzt")
        await store.close()
    }

    /// Grenzen von PencilKit fuer die Strichstaerke je Tinte (so duenn und so dick geht es), dazu die Stufen der Leiste
    func testGrenzenDerStrichstaerkeVonPencilKit() throws {
        var out: [String] = []
        let types: [(String, PKInkingTool.InkType)] = [("Stift (pen)", .pen), ("Fineliner (monoline)", .monoline), ("Textmarker (marker)", .marker),
                                                        ("Bleistift (pencil)", .pencil), ("Fueller (fountainPen)", .fountainPen),
                                                        ("Wasserfarbe (watercolor)", .watercolor), ("Kreide (crayon)", .crayon)]
        for (name, type) in types {
            let r = type.validWidthRange
            out.append(String(format: "%@: %.4f bis %.2f pt, Vorgabe %.2f", name, r.lowerBound, r.upperBound, type.defaultWidth))
        }
        let tools: [EditorToolState.Tool] = [.pen, .fineliner, .marker]
        for t in tools {
            out.append("Stufen \(t.rawValue): " + t.widths.map { String(format: "%.2f", $0) }.joined(separator: " / "))
        }
        print("[Strich] Strichstaerken von PencilKit (Seitenpunkte; 1 pt = 0,353 mm auf dem Papier):\n  " + out.joined(separator: "\n  "))
        XCTAssertEqual(PKInkingTool.InkType.monoline.validWidthRange.lowerBound, 0.5, accuracy: 0.01)
        XCTAssertLessThan(PKInkingTool.InkType.pen.validWidthRange.lowerBound, 0.9)
    }

    // MARK: Stiftgefuehl: was PencilKit hergibt (Messung)

    /// Messung fuer "Striche noch duenner" und "gleichmaessiger": echte Striche (Finger) mit dem Stift auf der duennsten
    /// Stufe, dem Fineliner, mit Breiten UNTER der Grenze von PencilKit, und derselbe Strich mit halbierten
    /// Punktgroessen. Ausgegeben: Breite, die das Werkzeug wirklich annimmt, Punktgroessen des Strichs und die
    /// gezeichnete Dicke (aus dem Bild gemessen).
    func testMessungWieDuennPencilKitSchreibt() async throws {
        try XCTSkipUnless(TestFinger.verfuegbar, "Beruehrung laesst sich in dieser iOS-Version nicht nachstellen")
        let fx = try await makeFixture(pages: 2)
        let store = try await openStore(fx)
        let shown = show(store, pencilOnly: false)
        defer { hide(shown) }
        let editor = shown.editor
        let overlay = try await waitForOverlay(editor, page: 0)
        let canvas = overlay.canvas
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let faelle: [(String, PKInkingTool)] = [
            ("Stift, duennste Stufe 0,88", PKInkingTool(.pen, color: .black, width: 0.88)),
            ("Stift, verlangt 0,40 (unter der Grenze)", PKInkingTool(.pen, color: .black, width: 0.4)),
            ("Fineliner, duennste Stufe 0,50", PKInkingTool(.monoline, color: .black, width: 0.5)),
            ("Fineliner, verlangt 0,35 (unter der Grenze)", PKInkingTool(.monoline, color: .black, width: 0.35)),
            ("Fineliner, verlangt 0,25 (unter der Grenze)", PKInkingTool(.monoline, color: .black, width: 0.25)),
            ("Fineliner, verlangt 0,10 (unter der Grenze)", PKInkingTool(.monoline, color: .black, width: 0.1)),
            ("Fueller, duennste 1,50", PKInkingTool(.fountainPen, color: .black, width: 1.5)),
            ("Bleistift, duennste 2,40", PKInkingTool(.pencil, color: .black, width: 2.4)),
        ]
        var out: [String] = []
        for (i, fall) in faelle.enumerated() {
            canvas.tool = fall.1
            let taken = (canvas.tool as? PKInkingTool)?.width ?? -1
            let a = overlay.content.convert(CGPoint(x: 100, y: 100 + CGFloat(i) * 36), to: nil)
            var pts: [CGPoint] = []
            for k in 0...40 { pts.append(CGPoint(x: a.x + CGFloat(k) * 5, y: a.y)) }
            let n0 = canvas.drawing.strokes.count
            try await TestFinger.strich(pts, in: shown.window, step: 0.008)
            let until = Uhr.now() + 3
            while Uhr.now() < until, canvas.drawing.strokes.count == n0 { try await Task.sleep(nanoseconds: 20_000_000) }
            guard let stroke = canvas.drawing.strokes.last, canvas.drawing.strokes.count == n0 + 1 else {
                out.append("\(fall.0): kein Strich")
                continue
            }
            let sizes = (0..<stroke.path.count).map { stroke.path[$0].size.width }
            let drawn = Self.dicke(stroke)
            out.append(String(format: "%@: Werkzeug nimmt %.2f an; Punktgroessen %.2f bis %.2f; gezeichnet %.2f pt dick (%.2f mm auf dem Papier)",
                              fall.0, taken, sizes.min() ?? 0, sizes.max() ?? 0, drawn, drawn * 0.3528))
            // derselbe Strich mit halben Punktgroessen (so koennte ein Strich NACH dem Absetzen duenner werden)
            if i == 0 || i == 2 {
                let half = (0..<stroke.path.count).map { k -> PKStrokePoint in
                    let p = stroke.path[k]
                    return PKStrokePoint(location: p.location, timeOffset: p.timeOffset, size: CGSize(width: p.size.width / 2, height: p.size.height / 2),
                                         opacity: p.opacity, force: p.force, azimuth: p.azimuth, altitude: p.altitude)
                }
                let thinner = PKStroke(ink: stroke.ink, path: PKStrokePath(controlPoints: half, creationDate: stroke.path.creationDate), transform: stroke.transform)
                out.append(String(format: "   derselbe Strich mit halben Punktgroessen: gezeichnet %.2f pt dick", Self.dicke(thinner)))
            }
        }
        print("[Strich] Was PencilKit beim Schreiben hergibt (Finger, gleichmaessiger Druck):\n  " + out.joined(separator: "\n  "))
        await store.close()
    }

    /// Gezeichnete Dicke eines waagerechten Strichs in Seitenpunkten: Bild von PencilKit in 16-facher Aufloesung, in
    /// fuenf Spalten die Deckung aufsummiert (Median)
    static func dicke(_ stroke: PKStroke) -> CGFloat {
        let rect = stroke.renderBounds.insetBy(dx: -3, dy: -3)
        let scale: CGFloat = 16
        var image = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = PKDrawing(strokes: [stroke]).image(from: rect, scale: scale)
        }
        guard let cg = image.cgImage else { return 0 }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var runs: [CGFloat] = []
        for k in 1...5 {
            let x = w * k / 6
            var sum = 0.0
            for y in 0..<h { sum += Double(px[(y * w + x) * 4 + 3]) / 255 }      // Deckung aufsummiert (auch halbe Pixel)
            runs.append(CGFloat(sum) / scale)
        }
        return runs.sorted()[2]
    }

    // MARK: Ablauf

    enum Reihenfolge: CustomStringConvertible {
        /// Zeichnung gemeldet, dann "Werkzeug aus" (Radierer, Lasso; so riefen die bisherigen Tests)
        case meldungZuerst
        /// "Werkzeug aus", dann die Zeichnung (so meldet PencilKit einen Stiftstrich)
        case absetzenZuerst
        /// echte Beruehrung, PencilKit meldet selbst
        case echt

        var description: String {
            switch self {
            case .meldungZuerst: return "Meldung vor dem Absetzen"
            case .absetzenZuerst: return "Absetzen vor der Meldung"
            case .echt: return "echte Beruehrung"
            }
        }
    }

    struct Ergebnis {
        var name = ""
        var proben = 0
        /// Wie oft das Programm die Zeichnung der Seite neu gesetzt hat ("vorher -> nachher" Striche)
        var neuGesetzt: [String] = []
        var verstoesse: [String] = []
        var strokesAmEnde = 0
        var strokesErwartet = 0
        /// Konnte die Sichtbarkeit im Bild des Fensters gemessen werden (dunkle Pixel kamen mit dem Strich dazu)?
        var sichtbarGemessen = false
        var bilder = 0
    }

    private func pruefe(_ r: Ergebnis, erlaubtNeu: Int, file: StaticString = #filePath, line: UInt = #line) {
        var text = "[Strich] \(r.name): \(r.proben) Proben, \(r.bilder) Bilder des Fensters"
        text += "; vom Programm neu gesetzt \(r.neuGesetzt.count) Mal"
        if !r.neuGesetzt.isEmpty { text += " (" + r.neuGesetzt.joined(separator: ", ") + ")" }
        text += "; Striche am Ende \(r.strokesAmEnde) (erwartet \(r.strokesErwartet))"
        text += "; im Bild gemessen: \(r.sichtbarGemessen ? "ja" : "nein")"
        text += "; Auffaelliges: " + (r.verstoesse.isEmpty ? "nichts" : r.verstoesse.prefix(12).joined(separator: " | "))
        print(text)
        XCTAssertLessThanOrEqual(r.neuGesetzt.count, erlaubtNeu, "\(r.name): Zeichnung vom Programm neu gesetzt: \(r.neuGesetzt)", file: file, line: line)
        XCTAssertTrue(r.verstoesse.isEmpty, "\(r.name): \(r.verstoesse.joined(separator: " | "))", file: file, line: line)
        XCTAssertEqual(r.strokesAmEnde, r.strokesErwartet, "\(r.name): alle Striche da", file: file, line: line)
    }

    /// Dokument mit eigener Datenbank oeffnen (wie in der App: Journal, Speicher-Runden mit den Standardzeiten), auf
    /// Seite 1 `vorhanden` Striche, dann `strokes` Striche schreiben und `warten` Sekunden beobachten
    private func lauf(_ name: String, strokes: Int, abstand: Double = 0.3, vorhanden: Int, order: Reihenfolge, warten: Double,
                      tool: EditorToolState.Tool = .pen, rohpunkte: Bool = false, gehalten: Bool = false, deckbild: Bool = false) async throws -> Ergebnis {
        let fx = try await makeFixture(pages: 3)
        var store = try await openStore(fx)
        if vorhanden > 0 {
            store.canvasChanged(pageKey: "p1", drawing: Self.volleSeite(strokes: vorhanden))
            await store.flush()
            await store.close()
            store = try await openStore(fx)
        }
        let shown = show(store, pencilOnly: order != .echt)
        defer { hide(shown) }
        let overlay = try await waitForOverlay(shown.editor, page: 0)
        XCTAssertEqual(overlay.canvas.drawing.strokes.count, vorhanden, "Messaufbau: Seite geladen")
        // erst schreiben, wenn nach dem Oeffnen alles steht (Laden, erste Runden)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let r = try await beobachte(name, editor: shown.editor, overlay: overlay, window: shown.window, strokes: strokes, abstand: abstand,
                                    order: order, warten: warten, tool: tool, rohpunkte: rohpunkte, gehalten: gehalten, deckbild: deckbild)
        // nichts verloren: nach dem Sichern stehen alle Striche im gespeicherten Stand
        await store.flush()
        let saved = await store.objects(forPageKey: "p1").filter { $0["type"]?.string == "stroke" }.count
        XCTAssertEqual(saved, r.strokesErwartet, "\(name): gespeichert")
        await store.close()
        return r
    }

    private func beobachte(_ name: String, editor: PDFEditorController, overlay: PageInkView, window: UIWindow, strokes: Int, abstand: Double,
                           order: Reihenfolge, warten: Double, tool: EditorToolState.Tool, rohpunkte: Bool, gehalten: Bool,
                           deckbild: Bool = false) async throws -> Ergebnis {
        editor.tools.select(tool)
        try await Task.sleep(nanoseconds: 300_000_000)
        var r = Ergebnis()
        r.name = name
        let canvas = overlay.canvas
        let start = canvas.drawing.strokes.count
        r.strokesErwartet = start + strokes
        let editorID = ObjectIdentifier(editor), pageIndex = overlay.pageIndex
        let layers0 = Self.layers(overlay), zoom0 = canvas.zoomScale
        let log0 = ZeichnungSpion.log.count
        var most = start
        // Stelle der neuen Striche (Seitenpunkte) und dieselbe im Fenster
        func place(_ i: Int) -> CGPoint { CGPoint(x: 120 + CGFloat(i % 4) * 90, y: 250 + CGFloat(i / 4) * 40) }
        let region = overlay.content.convert(CGRect(x: 100, y: 228, width: 400, height: 100), to: nil)
        XCTAssertTrue(window.bounds.contains(region), "Messaufbau: die Stelle der neuen Striche ist im Bild (\(region))")
        let dark0 = Self.dunkel(window, region)
        var darkSeen = dark0

        func probe(_ t: String) {
            r.proben += 1
            let n = canvas.drawing.strokes.count
            if n < most { r.verstoesse.append("\(t): Zeichnung kleiner (\(most) -> \(n) Striche)") }
            most = max(most, n)
            if canvas.alpha != 1 || canvas.isHidden { r.verstoesse.append("\(t): Zeichenflaeche nicht sichtbar (alpha \(canvas.alpha), versteckt \(canvas.isHidden))") }
            if abs(canvas.zoomScale - zoom0) > 0.001 { r.verstoesse.append("\(t): Zoomstufe der Zeichenflaeche \(zoom0) -> \(canvas.zoomScale)") }
            // wird der Strich gewollt ersetzt (Form, Glaettung), liegt solange ein Deckbild darueber: kein Verstoss
            let l = Self.layers(overlay)
            if l != layers0, !deckbild { r.verstoesse.append("\(t): Ebenen der Seite geaendert: \(layers0) -> \(l)") }
            if ObjectIdentifier(editor) != editorID || editor.view.window == nil { r.verstoesse.append("\(t): Editor neu aufgebaut") }
            let live = editor.allOverlays.first { $0.pageIndex == pageIndex && $0.window != nil && $0.generation == editor.shownLayoutVersion }
            if live !== overlay { r.verstoesse.append("\(t): Seite neu aufgebaut") }
            if canvas.superview !== overlay.content { r.verstoesse.append("\(t): Zeichenflaeche umgehaengt") }
        }
        /// Tinte im Bild des Fensters: einmal gesehen, darf sie nicht wieder weniger werden
        func bild(_ t: String) {
            r.bilder += 1
            let d = Self.dunkel(window, region)
            if d < darkSeen - max(40, (darkSeen - dark0) / 5) {
                r.verstoesse.append("\(t): Tinte im Bild weniger (\(darkSeen - dark0) -> \(d - dark0) dunkle Pixel)")
            }
            darkSeen = max(darkSeen, d)
        }

        let t0 = Uhr.now()
        func stamp() -> String { String(format: "%.2f s", Uhr.since(t0)) }
        for i in 0..<strokes {
            let p = place(i)
            if order == .echt {
                let a = overlay.content.convert(p, to: nil)
                var pts: [CGPoint] = []
                for k in 0...24 { pts.append(CGPoint(x: a.x + CGFloat(k) * 2.5, y: a.y + sin(CGFloat(k) / 3) * 9)) }
                try await TestFinger.strich(pts, in: window, step: 0.008)
            } else {
                Self.meldeStrich(Self.strich(at: p, n: i, marker: tool == .marker, gehalten: gehalten), on: overlay, editor: editor, order: order,
                                 rohpunkte: rohpunkte)
            }
            let until = Uhr.now() + abstand
            while Uhr.now() < until {
                probe(stamp())
                try await Task.sleep(nanoseconds: 8_000_000)
            }
        }
        if order == .echt {
            // PencilKit uebernimmt den letzten Strich kurz nach dem Absetzen in die Zeichnung
            let until = Uhr.now() + 3
            while Uhr.now() < until, canvas.drawing.strokes.count < start + strokes {
                probe(stamp())
                try await Task.sleep(nanoseconds: 8_000_000)
            }
            XCTAssertEqual(canvas.drawing.strokes.count, start + strokes, "\(name): PencilKit hat die Striche angenommen")
        }
        let end = Uhr.now() + warten
        var k = 0
        while Uhr.now() < end {
            probe(stamp())
            if k % 6 == 0 { bild(stamp()) }
            k += 1
            try await Task.sleep(nanoseconds: 8_000_000)
        }
        r.sichtbarGemessen = darkSeen > dark0 + 40
        r.strokesAmEnde = canvas.drawing.strokes.count
        let id = ObjectIdentifier(canvas)
        r.neuGesetzt = ZeichnungSpion.log[log0...].filter { $0.canvas == id && !$0.own }.map { "\($0.before) -> \($0.after)" }
        return r
    }

    /// Geschwister der Zeichenflaeche auf der Seite: Art, sichtbar, mit Bild? (ein Deckbild oder ein Bild der
    /// Handschrift aendert diese Liste)
    private static func layers(_ overlay: PageInkView) -> String {
        overlay.content.subviews.map { v in
            let image = (v as? UIImageView)?.image != nil
            return "\(type(of: v))\(v.isHidden ? " versteckt" : "")\(v.alpha != 1 ? " alpha \(v.alpha)" : "")\(image ? " mit Bild" : "")"
        }.joined(separator: ", ") + " / \(overlay.subviews.count)"
    }

    /// Dunkle Pixel im Bild des Fensters in `rect` (Punkte des Fensters), wie es auf dem Bildschirm steht
    static func dunkel(_ window: UIWindow, _ rect: CGRect) -> Int {
        let r = rect.intersection(window.bounds).integral
        guard !r.isNull, r.width > 2, r.height > 2 else { return 0 }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(bounds: r, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        guard let cg = image.cgImage else { return 0 }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var dark = 0
        for i in stride(from: 0, to: px.count, by: 4) {
            // dunkel oder kraeftig gefaerbt (Textmarker): deutlich weg vom weissen Papier
            let lo = min(px[i], px[i + 1], px[i + 2])
            if lo < 170 { dark += 1 }
        }
        return dark
    }

    /// Strich wie von PencilKit gemeldet: Zeichnung der Zeichenflaeche um einen Strich ergaenzt, dann die Meldungen
    private static func meldeStrich(_ stroke: PKStroke, on overlay: PageInkView, editor: PDFEditorController, order: Reihenfolge, rohpunkte: Bool) {
        let canvas = overlay.canvas
        editor.canvasViewDidBeginUsingTool(canvas)
        var d = canvas.drawing
        d.strokes.append(stroke)
        ZeichnungSpion.own = true
        overlay.isApplyingDrawing = true                    // die Meldung kommt unten von Hand, in der gewuenschten Reihenfolge
        canvas.drawing = d
        overlay.isApplyingDrawing = false
        ZeichnungSpion.own = false
        if rohpunkte {
            let n = stroke.path.count
            let samples = (0..<(n * 4)).map { i -> RawPencilSample in
                let p = stroke.path.interpolatedLocation(at: CGFloat(i) / 4)
                return RawPencilSample(location: CGPoint(x: p.x, y: p.y + (i % 2 == 0 ? 0.2 : -0.2)), time: 500 + Double(i) / 240)
            }
            overlay.rawRecorder.setSamplesForTesting(samples)
        }
        if order == .meldungZuerst {
            editor.canvasViewDrawingDidChange(canvas)
            editor.canvasViewDidEndUsingTool(canvas)
        } else {
            editor.canvasViewDidEndUsingTool(canvas)
            editor.canvasViewDrawingDidChange(canvas)
        }
    }

    /// Ein Buchstabe bzw. (gehalten) eine gerade Linie, deren Ende 0,8 s still steht
    private static func strich(at p: CGPoint, n: Int, marker: Bool, gehalten: Bool) -> PKStroke {
        var pts: [PKStrokePoint] = []
        let width: CGFloat = marker ? 14 : 2.4
        if gehalten {
            for i in 0..<30 {
                pts.append(PKStrokePoint(location: CGPoint(x: p.x + CGFloat(i) * 5, y: p.y + CGFloat(i % 2) * 0.6), timeOffset: Double(i) * 0.01,
                                         size: CGSize(width: width, height: width), opacity: 1, force: 0.9, azimuth: 0.8, altitude: 1.1))
            }
            for i in 0..<20 {
                pts.append(PKStrokePoint(location: CGPoint(x: p.x + 145, y: p.y), timeOffset: 0.3 + Double(i) * 0.04,
                                         size: CGSize(width: width, height: width), opacity: 1, force: 0.9, azimuth: 0.8, altitude: 1.1))
            }
        } else {
            for i in 0..<36 {
                let t = CGFloat(i) / 35
                pts.append(PKStrokePoint(location: CGPoint(x: p.x + t * 60, y: p.y + sin(t * .pi * 4 + CGFloat(n)) * 9), timeOffset: Double(i) * 0.008,
                                         size: CGSize(width: width, height: width), opacity: 1, force: 0.9, azimuth: 0.8, altitude: 1.1))
            }
        }
        let ink = marker ? PKInk(.marker, color: .systemYellow) : PKInk(.pen, color: .black)
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: pts, creationDate: Date().addingTimeInterval(-2)))
    }

    /// Gerade Linie, vor `vor` Sekunden begonnen (0,3 s lang gezogen, nicht gehalten)
    private static func gerade(from a: CGPoint, to b: CGPoint, vor: TimeInterval) -> PKStroke {
        let pts = (0..<30).map { i -> PKStrokePoint in
            let t = CGFloat(i) / 29
            return PKStrokePoint(location: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), timeOffset: Double(i) * 0.01,
                                 size: CGSize(width: 2.4, height: 2.4), opacity: 1, force: 0.9, azimuth: 0.8, altitude: 1.1)
        }
        return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: pts, creationDate: Date().addingTimeInterval(-vor)))
    }

    /// Messpunkte wie vom Stift entlang eines Strichs (240 je Sekunde)
    private static func rohpunkte(_ stroke: PKStroke) -> [RawPencilSample] {
        let n = stroke.path.count
        return (0..<((n - 1) * 4 + 1)).map { i in
            let p = stroke.path.interpolatedLocation(at: CGFloat(i) / 4)
            return RawPencilSample(location: p.applying(stroke.transform), time: 500 + Double(i) / 240)
        }
    }

    /// Mitte eines Strichs (Seitenpunkte)
    private static func mitte(_ s: PKStroke) -> CGPoint {
        let b = s.renderBounds
        return CGPoint(x: b.midX, y: b.midY)
    }

    /// Dicht beschriebene Seite wie echte Handschrift (je Strich 30 bis 50 Punkte), obere zwei Drittel der Seite
    static func volleSeite(strokes count: Int, zeilen: Int = 22) -> PKDrawing {
        var seed: UInt64 = 0x5712_1C40
        func next() -> UInt64 {
            seed &+= 0x9E37_79B9_7F4A_7C15
            var z = seed
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        var strokes: [PKStroke] = []
        for s in 0..<count {
            let line = (s / 40) % zeilen, col = s % 40
            let x0 = 30 + CGFloat(col) * 13.5 + CGFloat(next() % 4)
            let y0 = 40 + CGFloat(line) * 21 + CGFloat(next() % 5)
            let n = 30 + Int(next() % 21)
            let phase = CGFloat(next() % 628) / 100
            let pts = (0..<n).map { i -> PKStrokePoint in
                let t = CGFloat(i) / CGFloat(n - 1)
                return PKStrokePoint(location: CGPoint(x: x0 + t * 10 + cos(t * .pi * 4 + phase) * 3, y: y0 + sin(t * .pi * 4 + phase) * 7),
                                     timeOffset: Double(i) * 0.008, size: CGSize(width: 1.8, height: 1.8), opacity: 1, force: 0.8, azimuth: 0.8, altitude: 1.1)
            }
            let created = Date(timeIntervalSinceReferenceDate: 791_500_000 + Double(s) * 0.05)
            strokes.append(PKStroke(ink: PKInk(.pen, color: s % 5 == 4 ? .systemBlue : .black), path: PKStrokePath(controlPoints: pts, creationDate: created)))
        }
        return PKDrawing(strokes: strokes)
    }

    // MARK: Aufbau

    struct Fixture {
        let root: URL
        let api: APIClient
        let file: LibFile
    }

    struct Shown {
        let editor: PDFEditorController
        let window: UIWindow
    }

    /// Eigene Datenbank und PDF in einem Temp-Ordner
    func makeFixture(pages: Int) async throws -> Fixture {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("uniflow-strich-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temp) }
        let root = temp
        let host = LocalBackendHost(directory: temp.appendingPathComponent("db", isDirectory: true),
                                    clock: .fixed(berlin: "2026-11-16T20:00:00")!)
        let backend = try await host.backend()
        let fileID = "strich-" + UUID().uuidString.prefix(8).lowercased()
        try await backend.context.database.transaction { c in
            try c.execute("INSERT INTO courses(id, title, semester, subject, kind, created_at) VALUES (?,?,?,?,?,?)",
                          [.text("k-strich"), .text("Kurs"), .text("WiSe 2026/27"), .text("Kurs"), .text("vorlesung"),
                           .text("2026-10-01T08:00:00")])
            try c.execute("INSERT INTO files(id, course_id, name, chdate, status, kind, downloaded_at) VALUES (?,?,?,?, 'neu', 'pdf', ?)",
                          [.text(fileID), .text("k-strich"), .text("Skript.pdf"), .integer(1_792_000_000), .text("2026-11-16T09:00:00")])
        }
        let api = APIClient(base: APIClient.localBase, transport: LocalTransport(host: host))
        let pdfURL = AppPaths.pdf(fileID, namespace: api.namespace, root: root)
        try FileManager.default.createDirectory(at: pdfURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Skript.pdf(pages: pages, .schlicht).write(to: pdfURL)
        let meta = try await api.value("/api/files/\(fileID)")
        try DocumentStore.stamp(meta).write(to: pdfURL.appendingPathExtension("stand"), atomically: true, encoding: .utf8)
        let file = LibFile(id: fileID, name: "Skript.pdf", title: "Skript", kind: "pdf", module_id: nil, subject: "Kurs",
                           doc_type: nil, ai_title: nil, sub_label: nil, downloaded_at: "2026-11-16T09:00:00", has_notes: nil,
                           page_count: pages, studip_folder: nil)
        return Fixture(root: root, api: api, file: file)
    }

    func openStore(_ fx: Fixture) async throws -> DocumentStore {
        let store = DocumentStore(file: fx.file, api: fx.api, root: fx.root)
        await store.load()
        XCTAssertNil(store.errorMessage, store.errorMessage ?? "")
        return store
    }

    /// Fenster wie ein iPad quer (1080 x 810 pt)
    func show(_ store: DocumentStore, pencilOnly: Bool) -> Shown {
        let suite = "uniflow.tests.strich-werkzeuge.\(UUID().uuidString)"
        let toolDefaults = UserDefaults(suiteName: suite) ?? .standard
        addTeardownBlock { toolDefaults.removePersistentDomain(forName: suite) }
        let editor = PDFEditorController(store: store, tools: EditorToolState(defaults: toolDefaults))
        editor.pencilOnly = pencilOnly
        editor.ownNotesVisible = true
        editor.canEdit = true
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let frame = CGRect(x: 0, y: 0, width: 1080, height: 810)
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        window.rootViewController = editor
        window.makeKeyAndVisible()
        return Shown(editor: editor, window: window)
    }

    func hide(_ shown: Shown) {
        guard shown.window.rootViewController != nil else { return }
        shown.editor.showToolPicker(false)
        shown.window.isHidden = true
        shown.window.rootViewController = nil
    }

    func waitForOverlay(_ editor: PDFEditorController, page: Int, timeout: Double = 20) async throws -> PageInkView {
        let end = Uhr.now() + timeout
        while Uhr.now() < end {
            if let o = editor.allOverlays.first(where: { $0.pageIndex == page && $0.window != nil && $0.generation == editor.shownLayoutVersion }),
               o.loaded, o.bounds.width > 0 { return o }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw MessFehler("kein geladenes Overlay fuer Seite \(page + 1) nach \(Int(timeout)) s")
    }
}

/// Zaehlt jedes Setzen der Zeichnung einer Zeichenflaeche von PencilKit (`PKCanvasView.drawing = ...`): Der Aufruf wird
/// fuer die Dauer der Tests durch einen ersetzt, der mitschreibt und dann das Original ruft. `own`: der Test setzt
/// gerade selbst (stellt einen Strich nach) - zaehlt nicht als "vom Programm neu gesetzt".
@MainActor
enum ZeichnungSpion {
    struct Eintrag {
        let canvas: ObjectIdentifier
        let before: Int
        let after: Int
        let own: Bool
        var at = Uhr.now()
    }

    static var log: [Eintrag] = []
    static var own = false
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        guard let a = class_getInstanceMethod(PKCanvasView.self, NSSelectorFromString("setDrawing:")),
              let b = class_getInstanceMethod(PKCanvasView.self, #selector(PKCanvasView.uf_spion_setDrawing(_:))) else {
            XCTFail("Zeichnung der Zeichenflaeche laesst sich nicht beobachten")
            return
        }
        method_exchangeImplementations(a, b)
    }
}

extension PKCanvasView {
    @objc dynamic func uf_spion_setDrawing(_ d: AnyObject) {
        let before = drawing.strokes.count
        uf_spion_setDrawing(d)                              // nach dem Tausch: das Original
        ZeichnungSpion.log.append(.init(canvas: ObjectIdentifier(self), before: before, after: drawing.strokes.count, own: ZeichnungSpion.own))
    }
}
