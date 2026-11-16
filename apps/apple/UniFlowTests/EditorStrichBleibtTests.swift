import PDFKit
import PencilKit
import SwiftUI
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

    /// Glaettung "Aus"/"Leicht": Der Strich wird beim Absetzen einmal durch den aus den Messpunkten ersetzt (gewollt,
    /// so auch in Build 43) - genau einmal je Strich, nie kleiner.
    func testGlaettungAusUndLeichtSetzenJeStrichEinmal() async throws {
        for smoothing in [PencilSmoothing.off, .light] {
            UserDefaults.standard.set(smoothing.rawValue, forKey: PencilSmoothing.key)
            let r = try await lauf("Glaettung \(smoothing.rawValue), zwei Striche", strokes: 2, abstand: 0.4, vorhanden: 60, order: .absetzenZuerst,
                                   warten: 6, rohpunkte: true)
            pruefe(r, erlaubtNeu: 2)
        }
    }

    /// Formerkennung aus: nichts wird ersetzt. An (Standard) und am Ende gehalten: einmal ersetzt.
    func testFormerkennung() async throws {
        UserDefaults.standard.set(false, forKey: ShapeSnapSetting.key)
        var r = try await lauf("Formerkennung aus, Linie gehalten", strokes: 1, vorhanden: 60, order: .absetzenZuerst, warten: 5, gehalten: true)
        pruefe(r, erlaubtNeu: 0)
        UserDefaults.standard.removeObject(forKey: ShapeSnapSetting.key)
        r = try await lauf("Formerkennung an, Linie gehalten", strokes: 1, vorhanden: 60, order: .absetzenZuerst, warten: 5, gehalten: true)
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

    /// Ganze Dokumentansicht wie in der App (Kopfzeile, Leiste, Sicherungsanzeige): echter Strich, danach laufen die
    /// Speicher-Runden und die Anzeigen wechseln
    func testEchterStrichInDerGanzenDokumentansicht() async throws {
        try XCTSkipUnless(TestFinger.verfuegbar, "Beruehrung laesst sich in dieser iOS-Version nicht nachstellen")
        XCTAssertTrue(HostedEnvironment.accessibilityAutomation(true))
        addTeardownBlock { @MainActor in HostedEnvironment.accessibilityAutomation(false) }
        Entitlements.shared.setPlanForTesting(.plus)
        addTeardownBlock { @MainActor in Entitlements.shared.setPlanForTesting(.free) }
        let t = AIViewsAppTests.Transport()
        let id = "f-strich-\(UUID().uuidString.prefix(8))"
        t.answer("/api/files/\(id)/content", data: Skript.pdf(pages: 3, .schlicht), type: "application/pdf")
        t.answer("/api/files/\(id)/annotations", ["data": AnnotationDocument.emptyRoot, "version": 0, "updated_at": .null])
        t.answer("/api/related", ["results": []])
        let meta: JSONValue = ["id": .string(id), "name": "Skript.pdf", "title": "Skript", "kind": "pdf", "module_id": 1,
                               "downloaded_at": "2026-11-11T09:00:00", "page_count": 3, "doc_type": "skript"]
        let file = try JSONDecoder().decode(LibFile.self, from: meta.serialized())
        let api = APIClient(base: URL(string: "http://erfunden.test/")!, transport: t)
        let env = try hostWithEnvironment(NavigationStack { DocumentView(file: file, api: api) }, api: api,
                                          size: CGSize(width: 1080, height: 810))
        // warten ohne die Hauptschleife zu blockieren (das Laden laeuft in Aufgaben auf dem Hauptthread)
        let until = Uhr.now() + 20
        while Uhr.now() < until, EditorToolbarTests.pdfViews(in: env.view).first?.document == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNotNil(EditorToolbarTests.pdfViews(in: env.view).first?.document, "PDF fehlt:\n" + env.labels().joined(separator: "\n"))
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let editor = try XCTUnwrap(EditorToolbarTests.pdfViews(in: env.view).first.flatMap(EditorToolbarTests.editor(of:)))
        editor.pencilOnly = false
        let overlay = try await waitForOverlay(editor, page: 0)
        let r = try await beobachte("ganze Dokumentansicht, echte Beruehrung, vier Striche", editor: editor, overlay: overlay, window: env.window,
                                    strokes: 4, abstand: 0.4, order: .echt, warten: 10, tool: .pen, rohpunkte: false, gehalten: false)
        pruefe(r, erlaubtNeu: 0)
        await editor.store.close()
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
                      tool: EditorToolState.Tool = .pen, rohpunkte: Bool = false, gehalten: Bool = false) async throws -> Ergebnis {
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
                                    order: order, warten: warten, tool: tool, rohpunkte: rohpunkte, gehalten: gehalten)
        // nichts verloren: nach dem Sichern stehen alle Striche im gespeicherten Stand
        await store.flush()
        let saved = await store.objects(forPageKey: "p1").filter { $0["type"]?.string == "stroke" }.count
        XCTAssertEqual(saved, r.strokesErwartet, "\(name): gespeichert")
        await store.close()
        return r
    }

    private func beobachte(_ name: String, editor: PDFEditorController, overlay: PageInkView, window: UIWindow, strokes: Int, abstand: Double,
                           order: Reihenfolge, warten: Double, tool: EditorToolState.Tool, rohpunkte: Bool, gehalten: Bool) async throws -> Ergebnis {
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
            let l = Self.layers(overlay)
            if l != layers0 { r.verstoesse.append("\(t): Ebenen der Seite geaendert: \(layers0) -> \(l)") }
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
    private static func dunkel(_ window: UIWindow, _ rect: CGRect) -> Int {
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

    /// Dicht beschriebene Seite wie echte Handschrift (je Strich 30 bis 50 Punkte), obere zwei Drittel der Seite
    static func volleSeite(strokes count: Int) -> PKDrawing {
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
            let line = (s / 40) % 22, col = s % 40
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

    private struct Fixture {
        let root: URL
        let api: APIClient
        let file: LibFile
    }

    private struct Shown {
        let editor: PDFEditorController
        let window: UIWindow
    }

    /// Eigene Datenbank und PDF in einem Temp-Ordner
    private func makeFixture(pages: Int) async throws -> Fixture {
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

    private func openStore(_ fx: Fixture) async throws -> DocumentStore {
        let store = DocumentStore(file: fx.file, api: fx.api, root: fx.root)
        await store.load()
        XCTAssertNil(store.errorMessage, store.errorMessage ?? "")
        return store
    }

    /// Fenster wie ein iPad quer (1080 x 810 pt)
    private func show(_ store: DocumentStore, pencilOnly: Bool) -> Shown {
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
