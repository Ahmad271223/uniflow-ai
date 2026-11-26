import XCTest
@testable import UniFlowCore

/// Befunde der Durchsicht vom 26.11.2026 ("teste das komplett einmal durch ... ist etwas schlecht geloest vllt"):
/// je Befund ein Test, der vor der Korrektur falsch lag.
final class SheetReviewTests: XCTestCase {

    private func sheet(_ cells: [String: String], rows: Int = 8, cols: Int = 5) -> Sheet {
        var s = Sheet(rows: rows, cols: cols)
        for (k, v) in cells { s.set(v, at: SheetRef(k)!) }
        return s
    }

    private func value(_ formula: String, _ cells: [String: String] = [:]) -> SheetValue {
        var c = cells
        c["E8"] = formula
        return sheet(c).calc().value(SheetRef("E8")!)
    }

    private func shown(_ s: Sheet, _ name: String) -> String { s.display(SheetRef(name)!, s.calc()) }

    /// Auf einem Faden mit kleinem Stapel rechnen (so gross wie die Hintergrundfaeden am iPad)
    private func onSmallStack(_ work: @escaping () -> Void) {
        let done = expectation(description: "fertig")
        let t = Thread { work(); done.fulfill() }
        t.stackSize = 512 * 1024
        t.start()
        wait(for: [done], timeout: 60)
    }

    // MARK: Abstuerze

    func testRiesigeZahlenAlsStelleStuerzenNichtAb() {
        let cells = ["A1": "3", "A2": "1", "A3": "2", "B1": "x", "B2": "y"]
        XCTAssertEqual(value("=KGRÖSSTE(A1:A3;1E20)", cells), .error(.num))
        XCTAssertEqual(value("=KKLEINSTE(A1:A3;-1E20)", cells), .error(.num))
        XCTAssertEqual(value("=SVERWEIS(1;A1:B2;1E20)", cells), .error(.ref))
        XCTAssertEqual(value("=KGRÖSSTE(A1:A3;C1)", cells.merging(["C1": "99999999999999999999"]) { $1 }), .error(.num))
        XCTAssertEqual(value("=INDEX(A1:B2;1E20;1)", cells), .error(.ref))
        // unendlich ist keine Zahl
        XCTAssertEqual(value("=VARIANZ(1E200;-1E200)"), .error(.num))
        XCTAssertEqual(value("=ISTFEHLER(VARIANZ(1E200;-1E200))"), .bool(true))
    }

    func testLangeKettenUndTiefeFormelnBrauchenKeinenGrossenStapel() {
        onSmallStack {
            // laufende Summe ueber alle 500 Zeilen, die unterste Zelle zuerst gefragt
            var s = Sheet(rows: 500, cols: 3)
            s.set("1", at: SheetRef("A1")!)
            for r in 2...500 { s.set("=WENN(A\(r - 1)>0;SUMME(A\(r - 1))+1;0)", at: SheetRef("A\(r)")!) }
            XCTAssertEqual(s.calc().value(SheetRef("A500")!), .number(500))

            // zwei Spruenge je Zeile: frueher ab 300 Zeilen faelschlich #ZIRKEL!
            var t = Sheet(rows: 500, cols: 4)
            for r in 1...500 {
                t.set("1", at: SheetRef("A\(r)")!)
                t.set(r == 1 ? "=A1" : "=D\(r - 1)+A\(r)", at: SheetRef("C\(r)")!)
                t.set("=C\(r)", at: SheetRef("D\(r)")!)
            }
            XCTAssertEqual(t.calc().value(SheetRef("D500")!), .number(500))

            // 1000 Summanden, 30 Klammern, 30 Funktionen ineinander
            XCTAssertEqual(self.value("=" + Array(repeating: "1", count: 900).joined(separator: "+")), .number(900))
            XCTAssertEqual(self.value("=" + String(repeating: "(", count: 30) + "7" + String(repeating: ")", count: 30)), .number(7))
            XCTAssertEqual(self.value("=" + String(repeating: "ABS(", count: 30) + "-7" + String(repeating: ")", count: 30)), .number(7))
            XCTAssertEqual(self.value("=" + String(repeating: "-", count: 1001) + "4"), .number(-4))
            // zu tief: ein Fehler, kein Absturz
            XCTAssertEqual(self.value("=" + String(repeating: "(", count: 900) + "7" + String(repeating: ")", count: 900)), .error(.syntax))
            XCTAssertEqual(self.value("=" + String(repeating: "ABS(", count: 390) + "7" + String(repeating: ")", count: 390)), .error(.syntax))
        }
    }

    func testKreiseBleibenKreise() {
        XCTAssertEqual(sheet(["A1": "=WENNFEHLER(A1;0)"]).calc().value(SheetRef("A1")!), .error(.cycle))
        let s = sheet(["A1": "=B1+1", "B1": "=C1+1", "C1": "=A1+1", "D1": "=A1", "A2": "5", "B2": "=A2*2"])
        let c = s.calc()
        for n in ["A1", "B1", "C1", "D1"] { XCTAssertEqual(c.value(SheetRef(n)!), .error(.cycle), n) }
        XCTAssertEqual(c.value(SheetRef("B2")!), .number(10))
        // die Reihenfolge der Fragen aendert nichts
        let d = s.calc()
        for n in ["D1", "C1", "B1", "A1"] { XCTAssertEqual(d.value(SheetRef(n)!), .error(.cycle), n) }
    }

    // MARK: Zahlen

    func testTausenderpunktUndWieGetippt() {
        XCTAssertEqual(SheetText.parseNumber("1.500")?.value, 1500)
        XCTAssertEqual(SheetText.parseNumber("1.000.000")?.value, 1_000_000)
        XCTAssertEqual(SheetText.parseNumber("-12.345")?.value, -12345)
        XCTAssertEqual(SheetText.parseNumber("10.000 €")?.value, 10000)
        XCTAssertEqual(SheetText.parseNumber("0.500")?.value, 0.5)
        XCTAssertEqual(SheetText.parseNumber("1.5")?.value, 1.5)
        XCTAssertEqual(SheetText.parseNumber("3.14159")?.value, 3.14159)
        XCTAssertNil(SheetText.parseNumber("1.2."))
        XCTAssertNil(SheetText.parseNumber("12.11.2026"))
        // was die Tabelle selbst schreibt, liest sie auch wieder
        XCTAssertEqual(SheetText.parseNumber(SheetText.fixed(1500, decimals: 0))?.value, 1500)
        XCTAssertEqual(SheetText.parseNumber(SheetText.fixed(1234567.5, decimals: 2))?.value, 1234567.5)

        // mit Punkt oder Exponent getippt: bleibt stehen, rechnet aber
        let s = sheet(["A1": "14.30", "A2": "10.00", "A3": "1E3", "A4": "1,50", "A5": "1.500", "B1": "=A1*2", "B3": "=A3+1"])
        XCTAssertEqual(shown(s, "A1"), "14.30")
        XCTAssertEqual(shown(s, "A2"), "10.00")
        XCTAssertEqual(shown(s, "A3"), "1E3")
        XCTAssertEqual(shown(s, "A4"), "1,5")
        XCTAssertEqual(shown(s, "A5"), "1500")
        XCTAssertEqual(shown(s, "B1"), "28,6")
        XCTAssertEqual(shown(s, "B3"), "1001")
    }

    func testProzentUndEuroKlebenNicht() {
        var s = sheet(["A1": "50 %"])
        s.set("7", at: SheetRef("A1")!)
        XCTAssertEqual(shown(s, "A1"), "7 %")
        XCTAssertEqual(s.calc().value(SheetRef("A1")!), .number(0.07))
        s.set("0,25", at: SheetRef("A1")!)
        XCTAssertEqual(shown(s, "A1"), "25 %")
        s.set("3,20 €", at: SheetRef("A1")!)
        XCTAssertEqual(shown(s, "A1"), "3,20 €")
        s.set("12,5 %", at: SheetRef("A1")!)
        XCTAssertEqual(shown(s, "A1"), "12,5 %")
        // eine Formel in der Prozent-Zelle bleibt, wie sie ist
        s.set("=1/4", at: SheetRef("A1")!)
        XCTAssertEqual(shown(s, "A1"), "25,0 %")
    }

    func testRundenUndVergleichenOhneBinaerRauschen() {
        XCTAssertEqual(value("=AUFRUNDEN(0,1+0,2;1)"), .number(0.3))
        XCTAssertEqual(value("=ABRUNDEN(0,7+0,1;1)"), .number(0.8))
        XCTAssertEqual(value("=GANZZAHL((0,1+0,7)*10)"), .number(8))
        XCTAssertEqual(value("=AUFRUNDEN(1,21;1)"), .number(1.3))
        XCTAssertEqual(value("=ABRUNDEN(1,29;1)"), .number(1.2))
        XCTAssertEqual(value("=GANZZAHL(-1,5)"), .number(-2))
        XCTAssertEqual(value("=3*0,1=0,3"), .bool(true))
        XCTAssertEqual(value("=0,1+0,2<=0,3"), .bool(true))
        XCTAssertEqual(value("=0,3000001=0,3"), .bool(false))
        let cells = ["A1": "=0,1+0,2", "B1": "ja", "A2": "0,5", "B2": "nein"]
        XCTAssertEqual(value("=SVERWEIS(0,3;A1:B2;2;FALSCH)", cells), .text("ja"))
        XCTAssertEqual(value("=ZÄHLENWENN(A1:A2;0,3)", cells), .number(1))
        XCTAssertEqual(value("=RANG(0,3;A1:A2)", cells), .number(2))
    }

    // MARK: Formeln

    func testEnglischeSchreibweiseMitKomma() {
        XCTAssertEqual(value("=IF(A1>50,1,0)", ["A1": "60"]), .number(1))
        XCTAssertEqual(value("=IF(A1>50,1,0)", ["A1": "40"]), .number(0))
        XCTAssertEqual(value("=SUM(10,20,30)"), .number(60))
        XCTAssertEqual(value("=WENN(A1>50,1,0)", ["A1": "60"]), .number(1))
        XCTAssertEqual(value("=SUMME(A1,B1)", ["A1": "2", "B1": "3"]), .number(5))
        XCTAssertEqual(value("=ROUND(A1,1)", ["A1": "2,26"]), .number(2.3))
        XCTAssertEqual(value("=IF(A1>5,\"a, b\",\"c\")", ["A1": "6"]), .text("a, b"))
        // deutsch bleibt deutsch
        XCTAssertEqual(value("=MAX(1,2)"), .number(1.2))
        XCTAssertEqual(value("=SUMME(1,5;2,5)"), .number(4))
        XCTAssertEqual(value("=RUNDEN(2,55;1)"), .number(2.6))
        XCTAssertEqual(value("=A1*1,19", ["A1": "100"]), .number(119))
        XCTAssertEqual(value("=SUM(A1:A2)*1,5", ["A1": "2", "A2": "2"]), .number(6))
        XCTAssertEqual(value("=VERKETTEN(\"a, b\";\"c\")"), .text("a, bc"))
    }

    func testAnfuehrungszeichenDerTastaturUndZeichen() {
        XCTAssertEqual(value("=WENN(A1>=50;„bestanden“;„nicht bestanden“)", ["A1": "60"]), .text("bestanden"))
        XCTAssertEqual(value("=WENN(A1≥50;“ja”;“nein”)", ["A1": "50"]), .text("ja"))
        XCTAssertEqual(value("=A1≠2", ["A1": "3"]), .bool(true))
        XCTAssertEqual(value("=A1≤2", ["A1": "3"]), .bool(false))
        XCTAssertEqual(value("=ZÄHLENWENN(A1:A3;„ja“)", ["A1": "ja", "A2": "nein", "A3": "ja"]), .number(2))
    }

    func testNeueFunktionen() {
        let cells = ["A1": "Mathe", "B1": "5", "C1": "1,7", "A2": "Physik", "B2": "10", "C2": "2,3", "A3": "Mathe", "B3": "10", "C3": "3,0"]
        XCTAssertEqual(value("=ZÄHLENWENNS(A1:A3;\"Mathe\";B1:B3;\">5\")", cells), .number(1))
        XCTAssertEqual(value("=SUMMEWENNS(C1:C3;A1:A3;\"Mathe\")", cells), .number(4.7))
        XCTAssertEqual(value("=MITTELWERTWENNS(C1:C3;B1:B3;10)", cells), .number(2.65))
        XCTAssertEqual(value("=WENNS(B1>=10;\"viel\";B1>=5;\"mittel\";WAHR;\"wenig\")", cells), .text("mittel"))
        XCTAssertEqual(value("=WENNS(B1>100;1)", cells), .error(.na))
        XCTAssertEqual(value("=INDEX(A1:C3;2;3)", cells), .number(2.3))
        XCTAssertEqual(value("=INDEX(A1:C1;2)", cells), .number(5))
        XCTAssertEqual(value("=INDEX(A1:C3;4;1)", cells), .error(.ref))
        XCTAssertEqual(value("=VERGLEICH(\"Physik\";A1:A3;0)", cells), .number(2))
        XCTAssertEqual(value("=VERGLEICH(\"Chemie\";A1:A3;0)", cells), .error(.na))
        XCTAssertEqual(value("=INDEX(C1:C3;VERGLEICH(\"Physik\";A1:A3;0))", cells), .number(2.3))
        XCTAssertEqual(value("=ISTNV(VERGLEICH(\"Chemie\";A1:A3;0))", cells), .bool(true))
        XCTAssertEqual(value("=WENNNV(SVERWEIS(\"Chemie\";A1:C3;3;FALSCH);\"fehlt\")", cells), .text("fehlt"))
        for name in ["ZÄHLENWENNS", "SUMMEWENNS", "INDEX", "VERGLEICH", "WENNS"] {
            XCTAssertTrue(SheetFormula.catalog.contains { $0.name == name }, name)
        }
        // jedes Muster der Auswahl rechnet (kein #NAME?, kein #FEHLER!)
        for f in SheetFormula.catalog {
            let e = value("=" + f.pattern).error
            XCTAssertFalse(e == .name || e == .syntax, f.name)
        }
    }

    func testFehlerWerdenWeitergegebenUndKriterien() {
        XCTAssertEqual(value("=LINKS(A1;2)", ["A1": "=1/0"]), .error(.div0))
        XCTAssertEqual(value("=TEIL(A1;\"x\";2)", ["A1": "abc"]), .error(.value))
        XCTAssertEqual(value("=RANG(\"x\";A1:A3)", ["A1": "1"]), .error(.value))
        let cells = ["A1": "12", "A2": "1a", "A3": "'5", "A4": "5"]
        XCTAssertEqual(value("=ZÄHLENWENN(A1:A4;\"1*\")", cells), .number(1))
        XCTAssertEqual(value("=ZÄHLENWENN(A1:A4;5)", cells), .number(2))
    }

    func testBezuegeUeberDenRandBleibenBeimKopieren() {
        XCTAssertEqual(SheetFormula.shifted("=SUMME(A1:A1000)", dCol: 1, dRow: 0), "=SUMME(B1:B1000)")
        XCTAssertEqual(SheetFormula.shifted("=SUMME(A$1:A$900)", dCol: 0, dRow: 3), "=SUMME(A$1:A$900)")
        XCTAssertEqual(SheetFormula.adjusted("=SUMME(A1:A9999)", rows: true, at: 0, count: 1), "=SUMME(A2:A9999)")
        XCTAssertEqual(SheetFormula.shifted("=A1", dCol: -1, dRow: 0), "=#BEZUG!")
    }

    // MARK: Tabelle

    func testSortierenLaesstSummenzeilenUnten() {
        var s = sheet(["A1": "Fach", "B1": "Note", "A2": "Physik", "B2": "3", "A3": "Mathe", "B3": "1", "A4": "Chemie", "B4": "2",
                       "A6": "Schnitt", "B6": "=MITTELWERT(B2:B4)", "A7": "Beste", "B7": "=MIN(B2:B4)"])
        s.sort(byCol: 1, ascending: true)
        XCTAssertEqual((2...4).map { s.raw(SheetRef("A\($0)")!) }, ["Mathe", "Chemie", "Physik"])
        XCTAssertEqual(s.raw(SheetRef("A6")!), "Schnitt")
        XCTAssertEqual(s.raw(SheetRef("B6")!), "=MITTELWERT(B2:B4)")
        XCTAssertEqual(s.calc().value(SheetRef("B6")!), .number(2))
        XCTAssertEqual(s.calc().value(SheetRef("B7")!), .number(1))
        // laufende Summe in jeder Zeile: das sind Daten, sie gehen mit
        var t = sheet(["A1": "x", "A2": "3", "A3": "1", "A4": "2", "A5": "5", "A6": "4",
                       "B2": "=SUMME(A$2:A2)", "B3": "=SUMME(A$2:A3)", "B4": "=SUMME(A$2:A4)", "B5": "=SUMME(A$2:A5)", "B6": "=SUMME(A$2:A6)"])
        t.sort(byCol: 0, ascending: true)
        XCTAssertEqual((2...6).map { t.raw(SheetRef("A\($0)")!) }, ["1", "2", "3", "4", "5"])
    }

    func testAusschneidenLaesstBezuegeStehenUndEinfuegenWaechst() {
        var s = sheet(["A1": "2", "B1": "=A1*2"], rows: 3, cols: 2)
        let b = s.block(SheetRange("B1")!)
        s.paste(b, at: SheetRef(col: 1, row: 4), shiftingReferences: false)
        XCTAssertEqual(s.rows, 5)
        XCTAssertEqual(s.raw(SheetRef("B5")!), "=A1*2")
        s.paste(b, at: SheetRef(col: 2, row: 1))
        XCTAssertEqual(s.cols, 3)
        XCTAssertEqual(s.raw(SheetRef("C2")!), "=B2*2")
        // daneben loeschen trifft nichts
        s.clear(SheetRange("Z99")!)
        XCTAssertEqual(s.cells.count, 4)
    }

    func testDiagrammNimmtZaehlungAlsBeschriftung() {
        let s = sheet(["A1": "Semester", "B1": "Schnitt", "A2": "1", "B2": "2,3", "A3": "2", "B3": "2,0", "A4": "3", "B4": "1,7"])
        let c = SheetChart(id: "c", range: SheetRange("A1:B4")!).content(s, s.calc())
        XCTAssertEqual(c.categories, ["1", "2", "3"])
        XCTAssertEqual(c.series.map(\.name), ["Schnitt"])
        XCTAssertEqual(c.series[0].values, [2.3, 2.0, 1.7])
        // zwei gewoehnliche Zahlenreihen bleiben zwei Reihen
        let t = sheet(["A1": "4", "B1": "2", "A2": "1", "B2": "5", "A3": "9", "B3": "3"])
        XCTAssertEqual(SheetChart(id: "c", range: SheetRange("A1:B3")!).content(t, t.calc()).series.count, 2)
    }

    // MARK: KI

    func testKILeertNichtOhneNeuenInhaltUndMeldetEhrlich() throws {
        var s = sheet(["A1": "Fach", "B1": "Note", "A2": "Mathe", "B2": "1,7"])
        let before = s
        let onlyChart = try XCTUnwrap(SheetAI.parse(#"{"neu":true,"diagramme":[{"art":"balken","bereich":"A1:B2"}]}"#))
        XCTAssertFalse(onlyChart.replace)
        let out = SheetAI.apply(onlyChart, to: &s, at: SheetRef(col: 0, row: 0))
        XCTAssertEqual(s.cells, before.cells)
        XCTAssertEqual(out.charts, 1)
        XCTAssertEqual(out.cleared, 0)

        let fresh = try XCTUnwrap(SheetAI.parse(#"{"neu":true,"zellen":{"A1":"Tag","A2":""}}"#))
        let out2 = SheetAI.apply(fresh, to: &s, at: SheetRef(col: 0, row: 0))
        XCTAssertEqual(out2.cleared, 4)
        XCTAssertEqual(out2.cells, 1)
        XCTAssertTrue(out2.summary.contains("ersetzt"), out2.summary)
    }

    func testKIFormelnMitFehlerWerdenGezaehltUndGrenzenGelten() throws {
        var s = Sheet()
        let plan = try XCTUnwrap(SheetAI.parse(##"{"zellen":{"A1":"1","A2":"2","A3":"=SUMME(A1:A3)","B1":"=GIBTSNICHT(1)","B2":"=A1+A2","AZ500":"zu weit","C1":"#NV"},"diagramme":[{"art":"kreis","bereich":"K1:L5"}]}"##))
        XCTAssertNil(plan.cells[SheetRef("AZ500")!])
        let out = SheetAI.apply(plan, to: &s, at: SheetRef(col: 0, row: 0))
        XCTAssertEqual(out.broken, 2)                       // Kreis und unbekannte Funktion; "#NV" als Text zaehlt nicht
        XCTAssertEqual(out.charts, 0)                       // Bereich neben der Tabelle
        XCTAssertLessThanOrEqual(s.rows, 6)
        XCTAssertLessThanOrEqual(s.cols, 4)
    }

    func testKIAntwortMitKleinemFehlerWirdGerettet() throws {
        // Zahl mit Komma ohne Anfuehrungszeichen: kein gueltiges JSON
        let a = try XCTUnwrap(SheetAI.parse(#"{"neu":false,"zellen":{"A1":"Fach","B1":"Note","A2":"Mathe","B2":1,7,"A3":"Physik","B3":2,"B4":"=MITTELWERT(B2:B3)"}}"#))
        XCTAssertEqual(a.cells[SheetRef("B2")!], "1,7")
        XCTAssertEqual(a.cells[SheetRef("B3")!], "2")
        XCTAssertEqual(a.cells[SheetRef("B4")!], "=MITTELWERT(B2:B3)")
        XCTAssertEqual(a.cells.count, 7)
        // mitten im Wert abgeschnitten
        let b = try XCTUnwrap(SheetAI.parse(#"{"neu":true,"zellen":{"A1":"Tag","B1":"Thema","A2":"Mo","B2":"Analysis \"Folgen\"","A3":"Di","B3":"Line"#))
        XCTAssertTrue(b.replace)
        XCTAssertEqual(b.cells[SheetRef("B2")!], "Analysis \"Folgen\"")
        XCTAssertEqual(b.cells.count, 5)
        // zu viele Zellen: die ersten Zeilen, nicht irgendwelche
        let many = "{\"zellen\":{" + (1...190).flatMap { r in (0..<20).map { c in "\"\(SheetRef.colName(c))\(r)\":\"x\"" } }.joined(separator: ",") + "}}"
        let c = try XCTUnwrap(SheetAI.parse(many))
        XCTAssertEqual(c.cells.count, SheetAI.maxCells)
        XCTAssertEqual(c.cells.keys.map(\.row).max(), 149)
    }
}
