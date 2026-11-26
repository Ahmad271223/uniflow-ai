import XCTest
@testable import UniFlowCore

/// Textbloecke "wie Word" (25.11.2026): Format im gemeinsamen Notizmodell, gemischte Formatierung, Einrasten auf den
/// Linien, Listen. Dazu: aeltere Apps und die Community duerfen an den neuen Feldern nicht scheitern.
final class TextBlockTests: XCTestCase {

    private func style(_ change: (inout TextBlock.Style) -> Void) -> TextBlock.Style {
        var s = TextBlock.Style(fontSize: 14)
        change(&s)
        return s
    }

    // MARK: Anlegen

    func testNeuerBlockAufBlankoBleibtEinTextobjektDesGemeinsamenFormats() {
        let o = TextBlock.block(id: "b1", x: 100, y: 200, template: "blank", pageWidth: 595)
        XCTAssertEqual(o["type"], "text", "kein neuer Objekttyp: aeltere Apps und die Community kennen nur text")
        XCTAssertEqual(o["block"], 1)
        XCTAssertNil(o["snap"], "blanko: frei gesetzt")
        XCTAssertEqual(o["x"]?.double, 100)
        XCTAssertEqual(o["y"]?.double, 200)
        XCTAssertEqual(o["fontSize"]?.double, 14)
        XCTAssertEqual(o["width"]?.double, 595 - 100 - 36, "bis zum rechten Rand")
        XCTAssertTrue(TextBlock.isBlock(o))
        XCTAssertFalse(TextBlock.isBlock(PageObjectEdit.text(id: "t", x: 0, y: 0)), "Textfeld aus dem Web bleibt, wie es ist")
        XCTAssertFalse(TextBlock.isBlock(PageObjectEdit.sticky(id: "s", x: 0, y: 0)))
        // PDF-Seite (keine Vorlage) wie blanko
        XCTAssertNil(TextBlock.block(id: "b2", x: 10, y: 10, template: nil)["snap"])
        // am rechten Rand angetippt: nie schmaler als 140
        XCTAssertEqual(TextBlock.block(id: "b3", x: 560, y: 10, template: "blank", pageWidth: 595)["width"]?.double, 140)
    }

    func testNeuerBlockAufLiniertSitztAufDerLinieUnterDemTippunkt() {
        // Linien bei 60, 84, 108 ... (TemplateGeometry). Tippen bei y = 100 (zwischen 84 und 108): Zeile auf 108.
        let o = TextBlock.block(id: "b1", x: 80, y: 100, template: "lined", pageWidth: 595)
        XCTAssertEqual(o["snap"], "lines")
        XCTAssertEqual(o["fontSize"]?.double, 16)
        let baseline = (o["y"]?.double ?? 0) + TextBlock.padding + TextBlock.lineStep - TextBlock.baselineDrop
        XCTAssertEqual(baseline, 108, accuracy: 0.011)
        // genau auf einer Linie angetippt: diese Linie
        let on = TextBlock.block(id: "b2", x: 80, y: 84, template: "lined")
        XCTAssertEqual((on["y"]?.double ?? 0) + TextBlock.padding + TextBlock.lineStep - TextBlock.baselineDrop, 84, accuracy: 0.011)
        // ueber der ersten Linie angetippt: erste Linie
        let top = TextBlock.block(id: "b3", x: 80, y: 5, template: "cornell")
        XCTAssertEqual(top["y"]?.double, TextBlock.y(forLine: 0))
        XCTAssertEqual((top["y"]?.double ?? 0) + TextBlock.padding + TextBlock.lineStep - TextBlock.baselineDrop, 60, accuracy: 0.011)
        // Zeilenabstand fuer aeltere Apps und das Web: 24 pt bei Schrift 16
        XCTAssertEqual((o["lineHeight"]?.double ?? 0) * 16, 24, accuracy: 0.01)
        XCTAssertTrue(TextBlock.hasLines("lined"))
        XCTAssertTrue(TextBlock.hasLines("cornell"))
        XCTAssertFalse(TextBlock.hasLines("grid"))
        XCTAssertFalse(TextBlock.hasLines(nil))
    }

    func testLinienrasterPasstZurVorlage() {
        let g = TemplateGeometry.make("lined", width: 595, height: 842)
        XCTAssertEqual(g.horizontal.first, TextBlock.firstLine)
        XCTAssertEqual(g.horizontal[1] - g.horizontal[0], TextBlock.lineStep)
    }

    // MARK: Einrasten

    func testEinrastenNachVerschiebenUndGroesse() {
        let o = TextBlock.block(id: "b1", x: 80, y: 100, template: "lined")
        let y0 = o["y"]?.double ?? 0
        // 30 pt nach unten geschoben: rastet auf die naechste Linie (24 pt)
        let moved = PageObjectEdit.move([o], ids: ["b1"], dx: 7, dy: 30)
        let snapped = TextBlock.resnapped(moved)
        XCTAssertEqual(snapped[0]["y"]?.double ?? 0, y0 + 24, accuracy: 0.011)
        XCTAssertEqual(snapped[0]["x"]?.double, 80 - TextBlock.padding + 7, "waagerecht frei")
        XCTAssertEqual(TextBlock.resnapped(snapped), snapped, "sitzt schon: keine Aenderung")
        // ueber die erste Linie hinaus nach oben: bleibt auf der ersten
        let up = TextBlock.resnapped(PageObjectEdit.move([o], ids: ["b1"], dx: 0, dy: -500))
        XCTAssertEqual(up[0]["y"]?.double, TextBlock.y(forLine: 0))
        XCTAssertEqual(TextBlock.snappedDelta(30), 24)
        XCTAssertEqual(TextBlock.snappedDelta(-11), 0)
        XCTAssertEqual(TextBlock.snappedDelta(-13), -24)
        // nur die genannten Bloecke
        let two = [o, PageObjectEdit.move([TextBlock.block(id: "b2", x: 80, y: 300, template: "lined")], ids: ["b2"], dx: 0, dy: 5)[0]]
        XCTAssertEqual(TextBlock.resnapped(two, ids: ["b1"])[1], two[1])
        XCTAssertNotEqual(TextBlock.resnapped(two)[1], two[1])
    }

    func testBlankoUndGedrehteBloeckeRastenNicht() {
        let free = PageObjectEdit.move([TextBlock.block(id: "f", x: 80, y: 100, template: "blank")], ids: ["f"], dx: 0, dy: 7.3)
        XCTAssertEqual(TextBlock.resnapped(free), free)
        var turned = TextBlock.block(id: "t", x: 80, y: 100, template: "lined")
        turned["rotation"] = 90
        turned["y"] = 123.4
        XCTAssertFalse(TextBlock.isSnapped(turned))
        XCTAssertEqual(TextBlock.resnapped([turned]), [turned])
        XCTAssertEqual(TextBlock.snappedY(.nan), TextBlock.y(forLine: 0))
        XCTAssertTrue(TextBlock.snappedY(1e300).isFinite)
    }

    // MARK: Abschnitte

    func testAbschnitteSchreibenUndLesen() {
        let o = TextBlock.block(id: "b1", x: 10, y: 10, template: "blank")
        let base = TextBlock.baseStyle(o)
        let runs = [
            TextBlock.Run(text: "Satz des ", style: base),
            TextBlock.Run(text: "Pythagoras", style: style { $0.bold = true; $0.mark = "#f5d90a" }),
            TextBlock.Run(text: "", style: base),
            TextBlock.Run(text: ": ", style: base),
            TextBlock.Run(text: "a² + b² = c²", style: style { $0.italic = true; $0.fontFamily = "Georgia"; $0.fontSize = 18; $0.fill = "#e5322d" }),
        ]
        let saved = TextBlock.setting(runs, in: o)
        XCTAssertEqual(saved["text"], "Satz des Pythagoras: a² + b² = c²", "text bleibt der ganze Text (Suche, KI, aeltere Apps)")
        let raw = saved["runs"]?.array ?? []
        XCTAssertEqual(raw.count, 4, "leerer Abschnitt entfaellt")
        XCTAssertEqual(raw[0], ["text": "Satz des "], "nur Abweichungen von der Grundformatierung")
        XCTAssertEqual(raw[1], ["text": "Pythagoras", "bold": true, "mark": "#f5d90a"])
        XCTAssertEqual(raw[3], ["text": "a² + b² = c²", "italic": true, "fontFamily": "Georgia", "fontSize": 18, "fill": "#e5322d"])
        XCTAssertEqual(TextBlock.runs(saved), TextBlock.merged(runs))
        // alles in Grundformatierung: kein runs-Feld
        let plain = TextBlock.setting([TextBlock.Run(text: "nur ", style: base), TextBlock.Run(text: "Text", style: base)], in: saved)
        XCTAssertNil(plain["runs"])
        XCTAssertEqual(plain["text"], "nur Text")
        XCTAssertEqual(TextBlock.runs(plain), [TextBlock.Run(text: "nur Text", style: base)])
        XCTAssertEqual(TextBlock.runs(TextBlock.setting([], in: saved)), [], "leerer Text: keine Abschnitte")
    }

    func testAeltereAppAendertDenTextDannGiltDieGrundformatierung() {
        let o = TextBlock.block(id: "b1", x: 10, y: 10, template: "blank")
        let saved = TextBlock.setting([TextBlock.Run(text: "fett", style: style { $0.bold = true }),
                                       TextBlock.Run(text: " normal", style: TextBlock.baseStyle(o))], in: o)
        // 1.0.7 und das Web setzen nur `text`
        let edited = PageObjectEdit.set([saved], ids: ["b1"], "text", "ganz anderer Text")[0]
        XCTAssertEqual(TextBlock.runs(edited), [TextBlock.Run(text: "ganz anderer Text", style: TextBlock.baseStyle(o))])
        // beschaedigte Abschnitte (kein Text, falscher Typ): Grundformatierung, kein Absturz
        var broken = saved
        broken["runs"] = [["bold": true], 7, "x"]
        XCTAssertEqual(TextBlock.runs(broken).count, 1)
        broken["runs"] = .array(Array(repeating: ["text": ""], count: TextBlock.maxRuns + 1))
        XCTAssertEqual(TextBlock.runs(broken).count, 1)
        // Schriftgroesse ausserhalb der Grenzen
        broken["runs"] = [["text": "fett", "fontSize": 1e9], ["text": " normal", "fontSize": -3]]
        XCTAssertEqual(TextBlock.runs(broken).map(\.style.fontSize), [200, 6])
    }

    func testGanzenBlockFormatieren() {
        let o = TextBlock.block(id: "b1", x: 10, y: 10, template: "lined")
        let base = TextBlock.baseStyle(o)
        let saved = TextBlock.setting([TextBlock.Run(text: "fett", style: style { $0.bold = true; $0.fontSize = 16 }),
                                       TextBlock.Run(text: " normal", style: base)], in: o)
        // kursiv fuer den ganzen Block: beide Abschnitte, fett bleibt
        let it = TextBlock.applying(.italic(true), to: [saved], ids: ["b1"])[0]
        XCTAssertEqual(it["italic"], true, "Grundformatierung fuer aeltere Apps")
        XCTAssertEqual(TextBlock.runs(it).map(\.style.italic), [true, true])
        XCTAssertEqual(TextBlock.runs(it).map(\.style.bold), [true, false])
        // Schrift groesser: alle Abschnitte, Zeilenhoehe fuers Web folgt (Zeilenabstand bleibt 24)
        let big = TextBlock.applying(.sizeDelta(2), to: it)
        XCTAssertEqual(big["fontSize"], 18)
        XCTAssertEqual(TextBlock.runs(big).map(\.style.fontSize), [18, 18])
        XCTAssertEqual((big["lineHeight"]?.double ?? 0) * 18, 24, accuracy: 0.02)
        // Schriftart und Markieren
        let font = TextBlock.applying(.fontFamily("Georgia"), to: TextBlock.applying(.mark("#7ee081"), to: big))
        XCTAssertEqual(font["fontFamily"], "Georgia")
        XCTAssertEqual(font["mark"], "#7ee081")
        XCTAssertNil(font["runs"]?.array?.first?["mark"], "steht in der Grundformatierung")
        XCTAssertEqual(TextBlock.runs(font).map(\.style.mark), ["#7ee081", "#7ee081"])
        // andere Objekte und andere IDs bleiben
        let rect = PageObjectEdit.shape(id: "r", kind: "rect", from: (0, 0), to: (10, 10), color: "#000000", width: 1)!
        XCTAssertEqual(TextBlock.applying(.bold(true), to: [rect, saved], ids: ["r"]), [rect, saved])
        // gemeinsame Formatierung fuer die Leiste
        let common = TextBlock.commonStyle(TextBlock.runs(it), fallback: base)
        XCTAssertTrue(common.italic)
        XCTAssertFalse(common.bold, "gemischt: Schalter aus")
        XCTAssertEqual(TextBlock.commonStyle([], fallback: base), base)
        // Ausrichtung
        XCTAssertEqual(TextBlock.aligning("center", [saved], ids: ["b1"])[0]["align"], "center")
        XCTAssertEqual(TextBlock.aligning("quer", [saved], ids: ["b1"])[0], saved)
    }

    func testBefundeDerDurchsicht() {
        // Zeilenabstand fuer aeltere Apps: grosse Schrift nimmt ganze Linien, nie weniger als die Schrift hoch ist
        XCTAssertEqual(TextBlock.webLineHeight(fontSize: 16) * 16, 24, accuracy: 0.02)
        XCTAssertEqual(TextBlock.webLineHeight(fontSize: 36) * 36, 48, accuracy: 0.05)
        XCTAssertEqual(TextBlock.webLineHeight(fontSize: 60) * 60, 72, accuracy: 0.05)
        for size in stride(from: 8.0, through: 96, by: 4) { XCTAssertGreaterThanOrEqual(TextBlock.webLineHeight(fontSize: size), 0.99, "\(size)") }
        XCTAssertGreaterThanOrEqual(TextBlock.webLineHeight(fontSize: 40, step: StickyNote.lineStep), 1)

        // Listen: "12. November" ist keine Liste, "1. " und die Fortsetzung schon
        XCTAssertTrue(TextBlock.continuesList("• Milch", previous: nil))
        XCTAssertTrue(TextBlock.continuesList("1. Analysis", previous: "Plan"))
        XCTAssertTrue(TextBlock.continuesList("2. Lineare Algebra", previous: "1. Analysis"))
        XCTAssertFalse(TextBlock.continuesList("12. November 2026", previous: nil))
        XCTAssertFalse(TextBlock.continuesList("12. November 2026", previous: "Klausur am"))
        XCTAssertFalse(TextBlock.continuesList("3. Versuch", previous: "1. Versuch"))
        XCTAssertFalse(TextBlock.continuesList("ohne Zeichen", previous: "1. davor"))
    }

    func testSpeichernNimmtDieHaeufigsteFormatierungAlsGrundformatierung() {
        let o = TextBlock.block(id: "b1", x: 10, y: 10, template: "lined")
        let big = style { $0.fontSize = 24; $0.fontFamily = "Georgia" }
        // alles in einer Formatierung getippt: sie wird die Grundformatierung, keine Abschnitte
        let one = TextBlock.saving([TextBlock.Run(text: "Überschrift", style: big)], in: o)
        XCTAssertEqual(one["fontSize"], 24)
        XCTAssertEqual(one["fontFamily"], "Georgia")
        XCTAssertNil(one["runs"])
        XCTAssertEqual(one["text"], "Überschrift")
        // 24 pt passt mit Oberlaenge und Abstand zur Linie nicht in eine 24-pt-Zeile: Die App setzt sie auf zwei Linien,
        // aeltere Apps und das Web bekommen denselben Abstand (Durchsicht 26.11.2026; vorher 24 = Zeilen ineinander)
        XCTAssertEqual((one["lineHeight"]?.double ?? 0) * 24, 48, accuracy: 0.02)
        XCTAssertEqual(one["snap"], "lines")
        // gemischt: die laengere Formatierung ist die Grundformatierung, die kuerzere ein Abschnitt
        let normal = TextBlock.baseStyle(o)
        let mixed = TextBlock.saving([TextBlock.Run(text: "kurz", style: big), TextBlock.Run(text: " und ein langer Rest", style: normal)], in: one)
        XCTAssertEqual(mixed["fontSize"], 16)
        XCTAssertEqual(mixed["fontFamily"], "Arial")
        XCTAssertEqual(TextBlock.runs(mixed), [TextBlock.Run(text: "kurz", style: big), TextBlock.Run(text: " und ein langer Rest", style: normal)])
        XCTAssertEqual(mixed["runs"]?.array?.count, 2)
        // leer gespeichert: kein Text, keine Abschnitte
        let empty = TextBlock.saving([], in: mixed)
        XCTAssertEqual(empty["text"], "")
        XCTAssertNil(empty["runs"])
        XCTAssertNil(TextBlock.dominantStyle([]))
    }

    func testAltesTextfeldWirdBeimFormatierenZumBlock() {
        let old = PageObjectEdit.text(id: "t1", x: 10, y: 10, text: "Hallo")
        let bold = TextBlock.applying(.bold(true), to: old)
        XCTAssertEqual(bold["bold"], true)
        XCTAssertEqual(bold["block"], 1)
        XCTAssertEqual(bold["text"], "Hallo")
        XCTAssertNil(bold["runs"])
        XCTAssertNil(bold["snap"])
    }

    // MARK: Aeltere Apps, Community

    func testCommunityNimmtTextbloeckeAn() throws {
        let o = TextBlock.block(id: "b1", x: 80, y: 100, template: "lined")
        let saved = TextBlock.setting([TextBlock.Run(text: "%PDF- ist nur Text", style: style { $0.bold = true }),
                                       TextBlock.Run(text: " normal", style: TextBlock.baseStyle(o))], in: o)
        XCTAssertNoThrow(try SolutionValidator.validateObject(saved), "Felder der Textbloecke gehen mit geteilten Loesungen mit")
        XCTAssertTrue(SolutionValidator.allowedObjectTypes.contains(saved["type"]?.string ?? ""))
    }

    func testAeltereAppKannBlockVerschiebenSkalierenUndTreffen() {
        // 1.0.7 kennt nur PageObjectEdit: die Felder des Blocks bleiben dabei erhalten
        let o = TextBlock.setting([TextBlock.Run(text: "fett", style: style { $0.bold = true })],
                                  in: TextBlock.block(id: "b1", x: 80, y: 100, template: "lined"))
        let moved = PageObjectEdit.scale(PageObjectEdit.move([o], ids: ["b1"], dx: 5, dy: 5), ids: ["b1"], factorX: 0.5, factorY: 0.5)[0]
        XCTAssertEqual(moved["runs"], o["runs"])
        XCTAssertEqual(moved["snap"], "lines")
        XCTAssertEqual(moved["block"], 1)
        XCTAssertNotNil(PageObjectEdit.hit([moved], x: (moved["x"]?.double ?? 0) + 5, y: (moved["y"]?.double ?? 0) + 5, textHeight: { _ in 32 }))
        // zurueck in der neuen App: rastet wieder ein
        let back = TextBlock.resnapped([moved])[0]
        XCTAssertEqual(back["y"]?.double, TextBlock.snappedY(moved["y"]?.double ?? 0))
    }

    // MARK: Listen

    func testListenFortsetzenUndBeenden() {
        XCTAssertNil(TextBlock.listContinuation(after: "kein Punkt"))
        XCTAssertEqual(TextBlock.listContinuation(after: "• Mitose")?.insert, "\n• ")
        XCTAssertEqual(TextBlock.listContinuation(after: "3. Schritt")?.insert, "\n4. ")
        let empty = TextBlock.listContinuation(after: "• ")
        XCTAssertNil(empty?.insert, "leerer Punkt: Liste endet")
        XCTAssertEqual(empty?.endLength, 2)
        XCTAssertEqual(TextBlock.listContinuation(after: "12. ")?.endLength, 4)
        XCTAssertNil(TextBlock.listContinuation(after: "2026. Jahr im Kalender aber 12345. nicht".replacingOccurrences(of: "2026", with: "12345")))
        XCTAssertNil(TextBlock.listPrefix(of: "1.5 Liter"))
    }

    func testListeAnUndAus() {
        XCTAssertEqual(TextBlock.togglingList(.bullet, lines: ["eins", "zwei"]), ["• eins", "• zwei"])
        XCTAssertEqual(TextBlock.togglingList(.bullet, lines: ["• eins", "• zwei"]), ["eins", "zwei"], "alle schon Punkte: wieder aus")
        XCTAssertEqual(TextBlock.togglingList(.number, lines: ["• eins", "zwei", "7. drei"]), ["1. eins", "2. zwei", "3. drei"])
        XCTAssertEqual(TextBlock.togglingList(.number, lines: ["1. eins", "2. zwei"]), ["eins", "zwei"])
        XCTAssertEqual(TextBlock.togglingList(.bullet, lines: []), [])
    }
}
