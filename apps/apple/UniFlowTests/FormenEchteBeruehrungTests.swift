import PencilKit
import UIKit
import UniFlowCore
import XCTest
@testable import UniFlow

/// Formerkennung mit echter Beruehrung (Meldung des Inhabers 17.11.2026). Zwei Dinge:
/// - `testFormenKorpusAufnehmen` zieht jede Handzeichnung (`Handzeichnung.alle`) als Beruehrung ueber die Seite; PencilKit
///   zeichnet und glaettet selbst. Was PencilKit liefert, wird als Text abgelegt (`FormenKorpusDaten`). Laeuft nur auf
///   Auftrag (Datei `korpus-aufnehmen.txt` im Ordner der Bilder), weil es mehrere Minuten dauert.
/// - `testFormenEchtGezeichnetUndGehalten` zeichnet ein Viereck, ein Dreieck und eine Linie, haelt am Ende und prueft
///   den ganzen Weg im Editor: Form ersetzt den Strich, ein Strich bleibt ein Strich, ein Mal Rueckgaengig nimmt beides.
extension EditorStrichBleibtTests {

    /// Ordner fuer Bilder und Auftraege auf dem Mac (der Simulator darf dorthin schreiben); nil ausserhalb des Simulators
    static var formenOrdner: URL? {
        guard let home = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] else { return nil }
        return URL(fileURLWithPath: home).appendingPathComponent("Studora-Builds/aufraeumen-17-11/formen", isDirectory: true)
    }

    /// Inhalt einer Auftragsdatei im Ordner (ohne Leerraum), nil wenn sie fehlt
    static func formenAuftrag(_ name: String) -> String? {
        guard let dir = formenOrdner, let text = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Teil der Seite (Seitenpunkte), der im Fenster liegt und auf dem eine Beruehrung die Zeichenflaeche trifft
    static func freieFlaeche(_ overlay: PageInkView, in window: UIWindow) -> CGRect {
        let page = CGRect(origin: .zero, size: overlay.geometry.pageSize)
        var sicht = overlay.content.convert(window.bounds, from: nil).intersection(page).insetBy(dx: 12, dy: 12)
        func frei(_ p: CGPoint) -> Bool {
            guard let v = window.hitTest(overlay.content.convert(p, to: nil), with: nil) else { return false }
            return v.isDescendant(of: overlay)
        }
        while sicht.width > 60, !frei(CGPoint(x: sicht.minX + 2, y: sicht.midY)) { sicht.origin.x += 6; sicht.size.width -= 6 }
        while sicht.width > 60, !frei(CGPoint(x: sicht.maxX - 2, y: sicht.midY)) { sicht.size.width -= 6 }
        func zeileFrei(_ y: CGFloat) -> Bool {
            stride(from: sicht.minX + 4, through: sicht.maxX - 4, by: 12).allSatisfy { frei(CGPoint(x: $0, y: y)) }
        }
        while sicht.height > 60, !zeileFrei(sicht.minY + 2) { sicht.origin.y += 6; sicht.size.height -= 6 }
        while sicht.height > 60, !zeileFrei(sicht.maxY - 2) { sicht.size.height -= 6 }
        return sicht
    }

    /// Bahn als Beruehrung ziehen (Punkte des Fensters). Die letzten `knaeuel` Punkte sind das Halten: sie verteilen sich
    /// auf `halten` Sekunden. `vorDemAbsetzen` laeuft, waehrend der Finger noch liegt (Bild der Zeichnung von Hand).
    static func zeichne(_ pts: [CGPoint], knaeuel: Int, halten: Double, in window: UIWindow, step: Double = 0.004,
                        vorDemAbsetzen: (() -> Void)? = nil) async throws {
        guard let first = pts.first else { return }
        let finger = TestFinger(at: first, in: window)
        let moving = pts.count - knaeuel
        for (i, p) in pts.enumerated().dropFirst() {
            let pause = i < moving ? step : halten / Double(max(1, knaeuel))
            try await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000))
            finger.move(to: p)
        }
        vorDemAbsetzen?()
        try await Task.sleep(nanoseconds: 8_000_000)
        finger.lift()
    }

    /// Soll-Werte eines Falls an die Stelle `mitte` auf der Seite schieben
    static func verschoben(_ fall: Handzeichnung, um mitte: CGPoint) -> [CGFloat] {
        switch fall.art {
        case .viereck, .rund:
            var s = fall.soll
            s[0] += mitte.x
            s[1] += mitte.y
            return s
        default:
            return fall.soll.enumerated().map { $0.element + ($0.offset % 2 == 0 ? mitte.x : mitte.y) }
        }
    }

    func testFormenKorpusAufnehmen() async throws {
        try XCTSkipUnless(TestFinger.verfuegbar, "Beruehrung laesst sich in dieser iOS-Version nicht nachstellen")
        guard let ziel = Self.formenAuftrag("korpus-aufnehmen.txt"), !ziel.isEmpty else {
            throw XCTSkip("nur auf Auftrag: korpus-aufnehmen.txt mit dem Zielpfad im Ordner der Bilder")
        }
        // der Strich soll bleiben, wie PencilKit ihn liefert
        UserDefaults.standard.set(false, forKey: ShapeSnapSetting.key)
        let fx = try await makeFixture(pages: 2)
        let store = try await openStore(fx)
        let shown = show(store, pencilOnly: false)
        defer { hide(shown) }
        let overlay = try await waitForOverlay(shown.editor, page: 0)
        shown.editor.tools.select(.pen)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let canvas = overlay.canvas
        let frei = Self.freieFlaeche(overlay, in: shown.window)
        print("[Formen] Aufnahme: freie Flaeche der Seite \(frei), Zoom \(canvas.zoomScale)")
        XCTAssertGreaterThan(frei.width, 300)
        XCTAssertGreaterThan(frei.height, 200)
        let faelle = Handzeichnung.alle(maxBreite: frei.width - 24, maxHoehe: frei.height - 24)
        let mitte = CGPoint(x: frei.midX, y: frei.midY)
        var zeilen: [String] = []
        var fehlend: [String] = []
        var abweichung: CGFloat = 0
        for (i, fall) in faelle.enumerated() {
            // alle 40 Striche die Seite leeren (in einer Schreibpause), damit sie nicht voll laeuft
            if i % 40 == 0, i > 0 {
                try await Task.sleep(nanoseconds: 400_000_000)
                ZeichnungSpion.own = true
                canvas.drawing = PKDrawing()
                ZeichnungSpion.own = false
                try await Task.sleep(nanoseconds: 600_000_000)
            }
            let n0 = canvas.drawing.strokes.count
            let pts = fall.bahn.map { overlay.content.convert(CGPoint(x: $0.x + mitte.x, y: $0.y + mitte.y), to: nil) }
            try await Self.zeichne(pts, knaeuel: fall.knaeuel, halten: 0.55, in: shown.window)
            let until = Uhr.now() + 4
            while Uhr.now() < until, canvas.drawing.strokes.count <= n0 { try await Task.sleep(nanoseconds: 15_000_000) }
            guard canvas.drawing.strokes.count == n0 + 1, let stroke = canvas.drawing.strokes.last else {
                fehlend.append(fall.name)
                continue
            }
            let k = KorpusStrich(fall, soll: Self.verschoben(fall, um: mitte), stroke: stroke)
            // Gegenprobe: aus dem Text gelesen ergibt derselbe Strich dieselben Punkte fuer die Erkennung
            if let back = KorpusStrich(zeile: k.zeile) {
                let a = stroke.path.interpolatedPoints(by: .distance(2)).map { $0.location.applying(stroke.transform) }
                let b = back.erkennungspunkte
                if abs(a.count - b.count) <= 2 {
                    for j in 0..<min(a.count, b.count) { abweichung = max(abweichung, hypot(a[j].x - b[j].x, a[j].y - b[j].y)) }
                } else {
                    abweichung = max(abweichung, 99)
                }
            }
            zeilen.append(k.zeile)
            try await Task.sleep(nanoseconds: 120_000_000)
        }
        print("[Formen] Aufnahme: \(zeilen.count) von \(faelle.count) Strichen; aus dem Text gelesen weichen die Punkte hoechstens \(abweichung) pt ab; ohne Strich: \(fehlend)")
        XCTAssertTrue(fehlend.isEmpty, "PencilKit hat nicht jeden Strich angenommen: \(fehlend)")
        XCTAssertLessThan(abweichung, 1.5, "Text und Strich stimmen ueberein")
        let swift = "// Aufgenommen mit EditorStrichBleibtTests.testFormenKorpusAufnehmen (echte Beruehrung im Simulator, PencilKit zeichnet\n"
            + "// und glaettet selbst). Nicht von Hand aendern: neu aufnehmen. Je Zeile ein Strich, Felder mit Tabulator getrennt\n"
            + "// (Name, Art, erlaubte Formen, Merkmale, Soll in 1/10 pt, Breite in 1/100 pt, Dauer in ms, Kontrollpunkte in 1/10 pt).\n"
            + "// freie Flaeche der Seite bei der Aufnahme: \(Int(frei.width)) x \(Int(frei.height)) pt, Zoom \(String(format: "%.2f", canvas.zoomScale))\n"
            + "enum FormenKorpusDaten {\n    static let text = \"\"\"\n" + zeilen.joined(separator: "\n") + "\n\"\"\"\n}\n"
        try swift.write(to: URL(fileURLWithPath: ziel), atomically: true, encoding: .utf8)
        await store.close()
    }

    /// Bild eines Teils der Seite, wie er im Fenster steht (Seitenpunkte), als PNG in den Ordner der Bilder
    static func bild(_ window: UIWindow, _ overlay: PageInkView, _ pageRect: CGRect, name: String) {
        guard let dir = formenOrdner, formenAuftrag("stand.txt") != nil else { return }
        let r = overlay.content.convert(pageRect, to: nil).intersection(window.bounds).integral
        guard !r.isNull, r.width > 4, r.height > 4 else { return }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: r, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try? image.pngData()?.write(to: dir.appendingPathComponent(name + ".png"))
    }

    /// Der ganze Weg im Editor mit echter Beruehrung: zeichnen, am Ende halten, absetzen. Viereck (Schluss doppelt
    /// gezogen, Start mitten auf der Seite), Dreieck (Luecke am Schluss) und Linie werden zur Form; es bleibt EIN Strich,
    /// ein Mal Rueckgaengig nimmt Form und Strich. Ohne Halten bleibt die Zeichnung von Hand.
    func testFormenEchtGezeichnetUndGehalten() async throws {
        try XCTSkipUnless(TestFinger.verfuegbar, "Beruehrung laesst sich in dieser iOS-Version nicht nachstellen")
        let stand = Self.formenAuftrag("stand.txt")                         // "vorher" / "nachher": Bilder ablegen
        let fx = try await makeFixture(pages: 2)
        let store = try await openStore(fx)
        let shown = show(store, pencilOnly: false)
        defer { hide(shown) }
        let editor = shown.editor
        let overlay = try await waitForOverlay(editor, page: 0)
        editor.tools.select(.pen)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let canvas = overlay.canvas
        let frei = Self.freieFlaeche(overlay, in: shown.window)
        let alle = Handzeichnung.alle(maxBreite: frei.width - 24, maxHoehe: frei.height - 24)
        func fall(_ prefix: String, _ needle: String) throws -> Handzeichnung {
            try XCTUnwrap(alle.first { $0.name.hasPrefix(prefix) && $0.name.contains(needle) }, "\(prefix) … \(needle)")
        }
        let faelle: [(String, Handzeichnung, [String])] = [
            ("viereck", try fall("Viereck 150 pt (150 x 120), Start Seitenmitte", "Schluss doppelt"), ["rectangle", "square"]),
            ("dreieck", try fall("Dreieck 150 pt, stumpf, Start Seitenmitte", "Schluss doppelt"), ["triangle"]),
            ("linie", try fall("Linie 150 pt, 12°", "Zittern"), ["line"]),
        ]
        var report: [String] = []
        let mitte = CGPoint(x: frei.midX, y: frei.midY)
        for (kurz, f, erlaubt) in faelle {
            let n0 = canvas.drawing.strokes.count
            let box = Handzeichnung.bounds(f.bahn).offsetBy(dx: mitte.x, dy: mitte.y).insetBy(dx: -30, dy: -30)
            let pts = f.bahn.map { overlay.content.convert(CGPoint(x: $0.x + mitte.x, y: $0.y + mitte.y), to: nil) }
            let window = shown.window
            try await Self.zeichne(pts, knaeuel: f.knaeuel, halten: 0.8, in: window) {
                Self.bild(window, overlay, box, name: "\(kurz)-gezeichnet")
            }
            let until = Uhr.now() + 4
            while Uhr.now() < until, canvas.drawing.strokes.count <= n0 { try await Task.sleep(nanoseconds: 15_000_000) }
            try await Task.sleep(nanoseconds: 1_800_000_000)                // Deckbild ist weg, PencilKit hat gezeichnet
            XCTAssertEqual(canvas.drawing.strokes.count, n0 + 1, "\(kurz): ein Strich bleibt ein Strich")
            guard let stroke = canvas.drawing.strokes.last else { continue }
            if let stand { Self.bild(window, overlay, box, name: "\(kurz)-\(stand)") }
            // die ideale Form besteht aus geraden Stuecken: sie wird wieder als dieselbe Form erkannt und liegt genau darauf
            let points = stroke.path.interpolatedPoints(by: .distance(2)).map { $0.location.applying(stroke.transform) }
            let shape = ShapeRecognizer.recognize(points)
            let exact = shape.map { ShapeRecognizer.maxDistance(points, toPolygon: Self.ecken($0)) } ?? 99
            report.append("\(f.name): wurde \(shape?.name ?? "keine Form")" + (exact < 99 ? String(format: ", Strich weicht von der idealen Form %.2f pt ab", exact) : ""))
            XCTAssertTrue(erlaubt.contains(shape?.name ?? "-"), "\(f.name): wurde \(shape?.name ?? "keine Form")")
            XCTAssertLessThanOrEqual(exact, 0.6, "\(f.name): der Strich ist nach dem Halten die ideale Form (gerade Seiten)")
            // gespeichert: ein Strich
            await store.flush()
            let saved = await store.objects(forPageKey: "p1").filter { $0["type"]?.string == "stroke" }.count
            XCTAssertEqual(saved, n0 + 1, "\(kurz): gespeichert als ein Strich")
            // ein Mal Rueckgaengig: Form UND Strich weg
            editor.undo()
            try await Task.sleep(nanoseconds: 400_000_000)
            XCTAssertEqual(canvas.drawing.strokes.count, n0, "\(kurz): ein Mal Rueckgaengig nimmt Form und Strich")
            editor.redo()
            try await Task.sleep(nanoseconds: 400_000_000)
            XCTAssertEqual(canvas.drawing.strokes.count, n0 + 1, "\(kurz): Wiederholen bringt die Form zurueck")
            // Platz fuer die naechste Form (in einer Schreibpause)
            editor.undo()
            try await Task.sleep(nanoseconds: 900_000_000)
        }
        // ohne Halten: nichts wird ersetzt
        let f = faelle[0].1
        let n0 = canvas.drawing.strokes.count
        let pts = f.bahn.dropLast(f.knaeuel).map { overlay.content.convert(CGPoint(x: $0.x + mitte.x, y: $0.y + mitte.y), to: nil) }
        let log0 = ZeichnungSpion.log.count
        try await Self.zeichne(Array(pts), knaeuel: 0, halten: 0, in: shown.window)
        let until = Uhr.now() + 4
        while Uhr.now() < until, canvas.drawing.strokes.count <= n0 { try await Task.sleep(nanoseconds: 15_000_000) }
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let id = ObjectIdentifier(canvas)
        let replaced = ZeichnungSpion.log[log0...].filter { $0.canvas == id && !$0.own }.count
        XCTAssertEqual(replaced, 0, "ohne Halten wird die Zeichnung nie neu gesetzt")
        XCTAssertEqual(canvas.drawing.strokes.count, n0 + 1)
        report.append("ohne Halten: Zeichnung \(replaced) Mal neu gesetzt")
        print("[Formen] echte Beruehrung, ganzer Weg im Editor:\n  " + report.joined(separator: "\n  "))
        await store.close()
    }

    /// "Gerader Strich wird kuerzer" - liegt es (auch) an der Tinte? Je Tinte eine waagerechte Linie mit echter
    /// Beruehrung (ohne Halten), daraus die ideale Linie (`ShapeRecognizer.replacement`); beide als Bild von PencilKit
    /// gemessen: sichtbare Laenge der Tinte, Dicke in der Mitte und 3 pt vor den Enden. Die ideale Linie darf sichtbar
    /// nicht kuerzer sein als die gezeichnete und an den Enden nicht duenner als in der Mitte.
    func testFormenMessungTinteGezeichnetGegenIdeal() async throws {
        try XCTSkipUnless(TestFinger.verfuegbar, "Beruehrung laesst sich in dieser iOS-Version nicht nachstellen")
        UserDefaults.standard.set(false, forKey: ShapeSnapSetting.key)      // hier wird nichts ersetzt, nur gemessen
        let fx = try await makeFixture(pages: 2)
        let store = try await openStore(fx)
        let shown = show(store, pencilOnly: false)
        defer { hide(shown) }
        let overlay = try await waitForOverlay(shown.editor, page: 0)
        shown.editor.tools.select(.pen)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let canvas = overlay.canvas
        let frei = Self.freieFlaeche(overlay, in: shown.window)
        let tinten: [(String, PKInkingTool)] = [
            ("Stift 1 pt", PKInkingTool(.pen, color: .black, width: 1)), ("Stift 3 pt", PKInkingTool(.pen, color: .black, width: 3)),
            ("Stift 8 pt", PKInkingTool(.pen, color: .black, width: 8)), ("Fineliner 2 pt", PKInkingTool(.monoline, color: .black, width: 2)),
            ("Füller 4 pt", PKInkingTool(.fountainPen, color: .black, width: 4)), ("Bleistift 3 pt", PKInkingTool(.pencil, color: .black, width: 3)),
            ("Textmarker 12 pt", PKInkingTool(.marker, color: .black, width: 12)),
        ]
        var report: [String] = []
        for (i, tinte) in tinten.enumerated() {
            canvas.tool = tinte.1
            try await Task.sleep(nanoseconds: 200_000_000)
            let y = frei.minY + 50 + CGFloat(i) * 45
            var pts: [CGPoint] = []
            for k in 0...50 { pts.append(overlay.content.convert(CGPoint(x: frei.midX - 75 + CGFloat(k) * 3, y: y), to: nil)) }
            let n0 = canvas.drawing.strokes.count
            try await TestFinger.strich(pts, in: shown.window, step: 0.006)
            let until = Uhr.now() + 4
            while Uhr.now() < until, canvas.drawing.strokes.count <= n0 { try await Task.sleep(nanoseconds: 15_000_000) }
            guard canvas.drawing.strokes.count == n0 + 1, let stroke = canvas.drawing.strokes.last else {
                XCTFail("\(tinte.0): kein Strich")
                continue
            }
            let path = stroke.path
            let first = path[0].location.applying(stroke.transform), last = path[path.count - 1].location.applying(stroke.transform)
            let sizes = (0..<path.count).map { path[$0].size.width }
            guard let ideal = ShapeRecognizer.replacement(for: stroke) else {
                XCTFail("\(tinte.0): Linie nicht erkannt")
                continue
            }
            let a = ideal.path[0].location, b = ideal.path[ideal.path.count - 1].location
            let drawn = FormenHandzeichnungTests.tinte(stroke, from: first, to: last)
            let snapped = FormenHandzeichnungTests.tinte(ideal, from: a, to: b)
            report.append(String(format: "%@: Punktgroessen %.2f bis %.2f (Anfang %.2f, Ende %.2f), ideal %.2f", tinte.0, sizes.min() ?? 0, sizes.max() ?? 0,
                                 sizes.first ?? 0, sizes.last ?? 0, ideal.path[0].size.width))
            report.append(String(format: "   gezeichnet: Strich %.1f pt lang, Tinte sichtbar %.1f pt; Dicke Mitte %.2f, 3 pt nach dem Anfang %.2f, 3 pt vor dem Ende %.2f",
                                 hypot(last.x - first.x, last.y - first.y), drawn.sichtbar, drawn.mitte, drawn.anfang, drawn.ende))
            report.append(String(format: "   ideal:      Linie %.1f pt lang, Tinte sichtbar %.1f pt; Dicke Mitte %.2f, 3 pt nach dem Anfang %.2f, 3 pt vor dem Ende %.2f",
                                 hypot(b.x - a.x, b.y - a.y), snapped.sichtbar, snapped.mitte, snapped.anfang, snapped.ende))
            XCTAssertGreaterThanOrEqual(snapped.sichtbar, drawn.sichtbar - 1, "\(tinte.0): die ideale Linie ist sichtbar kuerzer als die gezeichnete")
            XCTAssertEqual(hypot(b.x - a.x, b.y - a.y), hypot(last.x - first.x, last.y - first.y), accuracy: 1, "\(tinte.0): Laenge")
            if tinte.1.inkType != .pencil {                                  // Bleistift ist koernig
                XCTAssertGreaterThanOrEqual(snapped.anfang, 0.8 * snapped.mitte, "\(tinte.0): ideale Linie am Anfang duenner")
                XCTAssertGreaterThanOrEqual(snapped.ende, 0.8 * snapped.mitte, "\(tinte.0): ideale Linie am Ende duenner")
            }
        }
        print("[Formen] Tinte: gezeichnete Linie (echte Beruehrung, 150 pt) gegen die ideale Linie:\n  " + report.joined(separator: "\n  "))
        await store.close()
    }

    /// Eckpunkte der Form als Linienzug (Linie: Anfang und Ende)
    static func ecken(_ shape: ShapeRecognizer.Shape) -> [CGPoint] {
        switch shape {
        case .line(let a, let b): return [a, b]
        case .rectangle: return ShapeRecognizer.rectangleCorners(of: shape)
        case .triangle(let a, let b, let c): return [a, b, c]
        case .arrow(let a, let b): return [a, b]
        case .ellipse: return []
        }
    }
}
