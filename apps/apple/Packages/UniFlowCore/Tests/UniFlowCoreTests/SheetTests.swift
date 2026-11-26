import XCTest
@testable import UniFlowCore

/// Tabelle ("Excel", 26.11.2026): Formeln, Zellbezuege, Sortieren/Filtern, Zeilen und Spalten, Diagramme, Speichern -
/// und dass die Tabelle im gemeinsamen Format ein gewoehnliches Textobjekt bleibt.
final class SheetTests: XCTestCase {

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

    private func num(_ formula: String, _ cells: [String: String] = [:], file: StaticString = #filePath, line: UInt = #line) -> Double {
        guard case .number(let d) = value(formula, cells) else {
            XCTFail("\(formula) ergibt \(value(formula, cells))", file: file, line: line)
            return .nan
        }
        return d
    }

    // MARK: Bezuege

    func testZellnamen() {
        XCTAssertEqual(SheetRef.colName(0), "A")
        XCTAssertEqual(SheetRef.colName(25), "Z")
        XCTAssertEqual(SheetRef.colName(26), "AA")
        XCTAssertEqual(SheetRef.colName(51), "AZ")
        XCTAssertEqual(SheetRef.colIndex("az"), 51)
        XCTAssertEqual(SheetRef("B12"), SheetRef(col: 1, row: 11))
        XCTAssertEqual(SheetRef("$c$3"), SheetRef(col: 2, row: 2))
        XCTAssertNil(SheetRef("B0"))
        XCTAssertNil(SheetRef("12"))
        XCTAssertNil(SheetRef("ABC1"))
        XCTAssertEqual(SheetRef(col: 27, row: 98).name, "AB99")
        let r = SheetRange("C3:A1")!
        XCTAssertEqual(r.name, "A1:C3", "immer von links oben nach rechts unten")
        XCTAssertEqual(r.count, 9)
        XCTAssertEqual(r.refs.first, SheetRef("A1"))
        XCTAssertEqual(r.refs.last, SheetRef("C3"))
        XCTAssertEqual(SheetRange("B2")?.name, "B2")
    }

    // MARK: Zahlen lesen und zeigen

    func testZahlenDeutschUndEnglisch() {
        XCTAssertEqual(SheetText.parseNumber("12,5")?.value, 12.5)
        XCTAssertEqual(SheetText.parseNumber("12.5")?.value, 12.5)
        XCTAssertEqual(SheetText.parseNumber("1.234,56")?.value, 1234.56)
        XCTAssertEqual(SheetText.parseNumber("1,234.56")?.value, 1234.56)
        XCTAssertEqual(SheetText.parseNumber("-3")?.value, -3)
        XCTAssertEqual(SheetText.parseNumber("50 %")?.value, 0.5)
        XCTAssertEqual(SheetText.parseNumber("50 %")?.hint, "p")
        XCTAssertEqual(SheetText.parseNumber("3,20 €")?.value, 3.2)
        XCTAssertEqual(SheetText.parseNumber("3,20 €")?.hint, "e")
        XCTAssertNil(SheetText.parseNumber("Mathe 1"))
        XCTAssertNil(SheetText.parseNumber("1,2,3"))
        XCTAssertNil(SheetText.parseNumber("inf"))
        XCTAssertNil(SheetText.parseNumber("0x10"))
        XCTAssertNil(SheetText.parseNumber("12a"))
        XCTAssertEqual(SheetText.general(3), "3")
        XCTAssertEqual(SheetText.general(2.5), "2,5")
        XCTAssertEqual(SheetText.general(0.1 + 0.2), "0,3", "keine 0,30000000000000004")
        XCTAssertEqual(SheetText.general(-0.0), "0")
        XCTAssertEqual(SheetText.fixed(1234567.891, decimals: 2), "1.234.567,89")
        XCTAssertEqual(SheetText.fixed(-0.004, decimals: 2), "0,00", "kein -0,00")
        XCTAssertEqual(SheetText.fixed(-12.5, decimals: 0), "-13")
        XCTAssertEqual(SheetCalc.literal("'007"), .text("007"))
        XCTAssertEqual(SheetCalc.literal("wahr"), .bool(true))
        XCTAssertEqual(SheetCalc.literal(" 7 "), .number(7))
        XCTAssertEqual(SheetCalc.literal("Hallo"), .text("Hallo"))
    }

    // MARK: Formeln

    func testGrundrechnenUndRangfolge() {
        XCTAssertEqual(num("=1+2*3"), 7)
        XCTAssertEqual(num("=(1+2)*3"), 9)
        XCTAssertEqual(num("=2^3^2"), 64, "wie Excel: von links")
        XCTAssertEqual(num("=-2^2"), 4, "wie Excel: Minus zuerst")
        XCTAssertEqual(num("=10/4"), 2.5)
        XCTAssertEqual(num("=1,5+1.5"), 3, "Komma und Punkt")
        XCTAssertEqual(num("=50%*200"), 100)
        XCTAssertEqual(num("= 3 × 4 ÷ 2"), 6)
        XCTAssertEqual(value("=1/0"), .error(.div0))
        XCTAssertEqual(value("=\"a\"&\"b\"&1"), .text("ab1"))
        XCTAssertEqual(value("=2>1"), .bool(true))
        XCTAssertEqual(value("=\"Apfel\"=\"apfel\""), .bool(true))
        XCTAssertEqual(value("=1<>1"), .bool(false))
        XCTAssertEqual(value("=1+"), .error(.syntax))
        XCTAssertEqual(value("=(1+2"), .error(.syntax))
        XCTAssertEqual(value("=QUATSCH(1)"), .error(.name))
        XCTAssertEqual(value("=\"x\"+1"), .error(.value))
        XCTAssertEqual(value("=\"3\"+1"), .number(4), "Text, der eine Zahl ist, rechnet mit")
    }

    func testBezuegeUndBereiche() {
        let c = ["A1": "10", "A2": "20", "A3": "30", "B1": "2", "B2": "Text", "B3": ""]
        XCTAssertEqual(num("=A1+A2", c), 30)
        XCTAssertEqual(num("=a1*$B$1", c), 20)
        XCTAssertEqual(num("=SUMME(A1:A3)", c), 60)
        XCTAssertEqual(num("=sum(A1:B3)", c), 62, "Text und leere Zellen zaehlen nicht")
        XCTAssertEqual(num("=SUMME(A1;A3;5)", c), 45)
        XCTAssertEqual(num("=SUM(A1, A3)", c), 40, "Komma mit Leerzeichen trennt")
        XCTAssertEqual(num("=SUMME(A1,A3)", c), 40, "Komma nach einem Bezug trennt")
        XCTAssertEqual(num("=RUNDEN(3,14159;2)"), 3.14)
        XCTAssertEqual(num("=MITTELWERT(A1:A3)", c), 20)
        XCTAssertEqual(num("=MIN(A1:A3)", c), 10)
        XCTAssertEqual(num("=MAX(A1:A3;99)", c), 99)
        XCTAssertEqual(num("=ANZAHL(A1:B3)", c), 4)
        XCTAssertEqual(num("=ANZAHL2(A1:B3)", c), 5)
        XCTAssertEqual(num("=D1+1", c), 1, "leere Zelle zaehlt als 0")
        XCTAssertEqual(value("=B2*2", c), .error(.value))
        XCTAssertEqual(value("=A1:A3", c), .error(.value), "ein Bereich allein ist kein Wert")
        XCTAssertEqual(value("=MITTELWERT(D1:D3)", c), .error(.div0))
    }

    func testFunktionen() {
        let c = ["A1": "4", "A2": "9", "A3": "1", "A4": "6", "B1": "ja", "B2": "nein", "B3": "ja", "B4": "ja",
                 "C1": "1,0", "C2": "2,3", "C3": "3,7", "C4": "1,3", "D1": "5", "D2": "10", "D3": "5", "D4": "10"]
        XCTAssertEqual(value("=WENN(A1>3;\"gross\";\"klein\")", c), .text("gross"))
        XCTAssertEqual(value("=IF(A3>3;\"gross\")", c), .bool(false))
        XCTAssertEqual(num("=WENN(A1>3;1;1/0)", c), 1, "der andere Zweig wird nicht gerechnet")
        XCTAssertEqual(num("=WENNFEHLER(1/0;7)"), 7)
        XCTAssertEqual(value("=UND(A1>3;A2>3)", c), .bool(true))
        XCTAssertEqual(value("=ODER(A3>3;FALSCH)", c), .bool(false))
        XCTAssertEqual(value("=NICHT(WAHR)"), .bool(false))
        XCTAssertEqual(num("=RUNDEN(2,675;2)"), 2.68)
        XCTAssertEqual(num("=RUNDEN(-2,5)"), -3)
        XCTAssertEqual(num("=RUNDEN(1234;-2)"), 1200)
        XCTAssertEqual(num("=ABRUNDEN(2,99;1)"), 2.9)
        XCTAssertEqual(num("=AUFRUNDEN(2,01;1)"), 2.1)
        XCTAssertEqual(num("=GANZZAHL(-2,5)"), -3)
        XCTAssertEqual(num("=ABS(-3)"), 3)
        XCTAssertEqual(num("=WURZEL(A2)", c), 3)
        XCTAssertEqual(value("=WURZEL(-1)"), .error(.num))
        XCTAssertEqual(num("=POTENZ(2;10)"), 1024)
        XCTAssertEqual(num("=REST(-7;3)"), 2)
        XCTAssertEqual(value("=REST(1;0)"), .error(.div0))
        XCTAssertEqual(num("=MEDIAN(A1:A4)", c), 5)
        XCTAssertEqual(num("=PRODUKT(A1:A3)", c), 36)
        XCTAssertEqual(num("=STABW(A1:A4)", c), 3.366501646, accuracy: 1e-6)
        XCTAssertEqual(num("=STABWN(A1:A4)", c), 2.915475947, accuracy: 1e-6)
        XCTAssertEqual(num("=VARIANZ(A1:A4)", c), 11.33333333, accuracy: 1e-6)
        XCTAssertEqual(num("=SUMMEWENN(B1:B4;\"ja\";A1:A4)", c), 11)
        XCTAssertEqual(num("=SUMMEWENN(A1:A4;\">4\")", c), 15)
        XCTAssertEqual(num("=ZÄHLENWENN(B1:B4;\"j*\")", c), 3)
        XCTAssertEqual(num("=ZÄHLENWENN(A1:A4;\"<>4\")", c), 3)
        XCTAssertEqual(num("=COUNTIF(A1:A4;6)", c), 1)
        XCTAssertEqual(num("=MITTELWERTWENN(A1:A4;\">=6\")", c), 7.5)
        // Notenschnitt: Note mal Leistungspunkte durch Leistungspunkte
        XCTAssertEqual(num("=SUMMENPRODUKT(C1:C4;D1:D4)/SUMME(D1:D4)", c), 59.5 / 30, accuracy: 1e-9)
        XCTAssertEqual(value("=SUMMENPRODUKT(C1:C4;D1:D3)", c), .error(.value))
        XCTAssertEqual(num("=KGRÖSSTE(A1:A4;2)", c), 6)
        XCTAssertEqual(num("=KKLEINSTE(A1:A4;1)", c), 1)
        XCTAssertEqual(num("=RANG(A4;A1:A4)", c), 2)
        XCTAssertEqual(num("=PI()"), Double.pi)
        XCTAssertEqual(num("=LOG10(1000)"), 3, accuracy: 1e-12)
        XCTAssertEqual(num("=LOG(8;2)"), 3, accuracy: 1e-12)
        XCTAssertEqual(value("=LN(0)"), .error(.num))
        XCTAssertEqual(value("=VERKETTEN(B1;\"-\";A1)", c), .text("ja-4"))
        XCTAssertEqual(num("=LÄNGE(\"Hallo\")"), 5)
        XCTAssertEqual(value("=LINKS(\"Hallo\";2)"), .text("Ha"))
        XCTAssertEqual(value("=RECHTS(\"Hallo\";3)"), .text("llo"))
        XCTAssertEqual(value("=TEIL(\"Hallo\";2;3)"), .text("all"))
        XCTAssertEqual(value("=GROSS(\"ab\")&KLEIN(\"CD\")"), .text("ABcd"))
        XCTAssertEqual(value("=GLÄTTEN(\"  a   b \")"), .text("a b"))
        XCTAssertEqual(num("=WERT(\"1,5\")"), 1.5)
        XCTAssertEqual(value("=ISTLEER(E1)", c), .bool(true))
        XCTAssertEqual(value("=ISTZAHL(A1)", c), .bool(true))
        XCTAssertEqual(value("=ISTTEXT(B1)", c), .bool(true))
        XCTAssertEqual(value("=ISTFEHLER(1/0)"), .bool(true))
    }

    func testSverweis() {
        let c = ["A1": "Mathe", "B1": "1,7", "A2": "Physik", "B2": "2,3", "A3": "Chemie", "B3": "3,0",
                 "D1": "10", "E1": "x", "D2": "20", "E2": "y", "D3": "30", "E3": "z"]
        XCTAssertEqual(num("=SVERWEIS(\"physik\";A1:B3;2;FALSCH)", c), 2.3)
        XCTAssertEqual(value("=SVERWEIS(\"Bio\";A1:B3;2;FALSCH)", c), .error(.na))
        XCTAssertEqual(value("=SVERWEIS(25;D1:E3;2)", c), .text("y"), "ohne 4. Angabe: der naechstkleinere Wert")
        XCTAssertEqual(value("=SVERWEIS(5;D1:E3;2)", c), .error(.na))
        XCTAssertEqual(value("=SVERWEIS(10;D1:E3;3;FALSCH)", c), .error(.ref))
    }

    func testFormelnBauenAufeinanderAufUndKreiseWerdenErkannt() {
        var s = Sheet(rows: 300, cols: 3)
        s.set("1", at: SheetRef("A1")!)
        for r in 1..<300 { s.set("=A\(r)+1", at: SheetRef(col: 0, row: r)) }
        XCTAssertEqual(s.calc().value(SheetRef("A300")!), .number(300))
        s.set("=B2", at: SheetRef("B1")!)
        s.set("=B1+1", at: SheetRef("B2")!)
        s.set("=C1", at: SheetRef("C1")!)
        let c = s.calc()
        XCTAssertEqual(c.value(SheetRef("B1")!), .error(.cycle))
        XCTAssertEqual(c.value(SheetRef("B2")!), .error(.cycle))
        XCTAssertEqual(c.value(SheetRef("C1")!), .error(.cycle))
        XCTAssertEqual(c.value(SheetRef("A300")!), .number(300), "der Rest rechnet weiter")
    }

    func testFehlerErklaerenSich() {
        for e in SheetError.allCases { XCTAssertFalse(e.hint.isEmpty) }
        XCTAssertEqual(value("=#BEZUG!+1"), .error(.ref))
        for f in SheetFormula.catalog {
            XCTAssertNotEqual(value("=" + f.pattern).error, .name, "\(f.name) aus der Auswahl ist bekannt")
            XCTAssertNotEqual(value("=" + f.pattern).error, .syntax, "\(f.pattern) laesst sich lesen")
        }
    }

    // MARK: Formeln umschreiben

    func testKopierenVerschiebtBezuege() {
        XCTAssertEqual(SheetFormula.shifted("=A1*$B$1+$C2+D$3", dCol: 1, dRow: 2), "=B3*$B$1+$C4+E$3")
        XCTAssertEqual(SheetFormula.shifted("=SUMME(A1:A3) & \"A1\"", dCol: 0, dRow: 1), "=SUMME(A2:A4) & \"A1\"", "Text bleibt Text")
        XCTAssertEqual(SheetFormula.shifted("=A1", dCol: -1, dRow: 0), "=#BEZUG!")
        XCTAssertEqual(SheetFormula.shifted("12", dCol: 1, dRow: 1), "12")
        XCTAssertEqual(SheetFormula.references("=SUMME(A1:B2)+C3").map(\.name), ["A1:B2", "C3"])
    }

    func testZeilenUndSpaltenEinfuegenUndLoeschen() {
        var s = sheet(["A1": "1", "A2": "2", "A3": "3", "A4": "=SUMME(A1:A3)", "B1": "=A2*10", "C1": "=A1+A3"])
        s.styles[SheetRef("A3")!] = { var st = SheetStyle(); st.bold = true; return st }()
        s.insertRows(at: 1)
        XCTAssertEqual(s.rows, 9)
        XCTAssertEqual(s.raw(SheetRef("A5")!), "=SUMME(A1:A4)", "der Bereich waechst mit")
        XCTAssertEqual(s.raw(SheetRef("B1")!), "=A3*10")
        XCTAssertEqual(s.raw(SheetRef("A2")!), "")
        XCTAssertTrue(s.style(SheetRef("A4")!).bold, "das Aussehen wandert mit")
        XCTAssertEqual(s.calc().value(SheetRef("A5")!), .number(6))
        s.deleteRows(at: 2)                       // die Zeile mit der 2
        XCTAssertEqual(s.raw(SheetRef("A4")!), "=SUMME(A1:A3)")
        XCTAssertEqual(s.raw(SheetRef("B1")!), "=#BEZUG!*10", "die Zelle gibt es nicht mehr")
        XCTAssertEqual(s.calc().value(SheetRef("B1")!), .error(.ref))
        XCTAssertEqual(s.calc().value(SheetRef("A4")!), .number(4))
        s.insertCols(at: 0)
        XCTAssertEqual(s.raw(SheetRef("D1")!), "=B1+B3")
        s.deleteCols(at: 0)
        XCTAssertEqual(s.raw(SheetRef("C1")!), "=A1+A3")
        XCTAssertEqual(s.cols, 5)
        // die letzte Zeile und die letzte Spalte bleiben
        var one = Sheet(rows: 1, cols: 1)
        one.deleteRows(at: 0)
        one.deleteCols(at: 0)
        XCTAssertEqual(one.rows, 1)
        XCTAssertEqual(one.cols, 1)
        // Obergrenzen
        var big = Sheet(rows: Sheet.maxRows, cols: Sheet.maxCols)
        big.insertRows(at: 0, count: 5)
        big.insertCols(at: 0, count: 5)
        XCTAssertEqual(big.rows, Sheet.maxRows)
        XCTAssertEqual(big.cols, Sheet.maxCols)
    }

    func testBereichSchrumpftBeimLoeschen() {
        XCTAssertEqual(SheetFormula.adjusted("=SUMME(A2:A5)", rows: true, at: 3, count: -1), "=SUMME(A2:A4)")
        XCTAssertEqual(SheetFormula.adjusted("=SUMME(A2:A5)", rows: true, at: 1, count: -2), "=SUMME(A2:A3)")
        XCTAssertEqual(SheetFormula.adjusted("=SUMME(A2:A5)", rows: true, at: 1, count: -4), "=SUMME(#BEZUG!)")
        XCTAssertEqual(SheetFormula.adjusted("=SUMME(A2:A5)", rows: true, at: 4, count: -3), "=SUMME(A2:A4)")
        XCTAssertEqual(SheetFormula.adjusted("=B1+C1", rows: false, at: 1, count: 2), "=D1+E1")
        XCTAssertEqual(SheetFormula.adjusted("=A1", rows: true, at: 5, count: 3), "=A1")
    }

    func testKopierenEinfuegenUndAusfuellen() {
        var s = sheet(["A1": "5", "B1": "=A1*2", "A2": "7"])
        s.restyle(SheetRange("B1")!) { $0.fill = "#fff7a8" }
        let b = s.block(SheetRange("B1")!)
        XCTAssertEqual(s.paste(b, at: SheetRef("B2")!).name, "B2")
        XCTAssertEqual(s.raw(SheetRef("B2")!), "=A2*2")
        XCTAssertEqual(s.style(SheetRef("B2")!).fill, "#fff7a8")
        XCTAssertEqual(s.calc().value(SheetRef("B2")!), .number(14))
        s.set("9", at: SheetRef("A3")!)
        s.fillDown(SheetRange("B1:B3")!)
        XCTAssertEqual(s.raw(SheetRef("B3")!), "=A3*2")
        XCTAssertEqual(b.plainText { s.display($0, s.calc()) }, "10")
        // aus einer anderen App: Tabulator und Zeilen; die Tabelle waechst
        var t = Sheet(rows: 2, cols: 2)
        XCTAssertEqual(t.pasteText("Fach\tNote\tLP\r\nMathe\t1,7\t10\nPhysik\t2,3\t5\n", at: SheetRef("A1")!).name, "A1:C3")
        XCTAssertEqual(t.rows, 3)
        XCTAssertEqual(t.cols, 3)
        XCTAssertEqual(t.calc().value(SheetRef("B2")!), .number(1.7))
        t.clear(SheetRange("A1:C1")!)
        XCTAssertEqual(t.raw(SheetRef("A1")!), "")
    }

    // MARK: Anzeige

    func testAnzeigeUndFormate() {
        var s = sheet(["A1": "0,256", "A2": "1234,5", "A3": "50 %", "A4": "3,20 €", "A5": "Text", "A6": "=1/0", "A7": "12,5 %"])
        var c = s.calc()
        XCTAssertEqual(s.display(SheetRef("A1")!, c), "0,256")
        XCTAssertEqual(s.display(SheetRef("A3")!, c), "50 %", "das getippte Prozent bleibt")
        XCTAssertEqual(s.display(SheetRef("A7")!, c), "12,5 %")
        XCTAssertEqual(s.display(SheetRef("A4")!, c), "3,20 €")
        XCTAssertEqual(s.display(SheetRef("A6")!, c), "#DIV/0!")
        XCTAssertEqual(s.alignment(SheetRef("A1")!, c), "r", "Zahlen rechts")
        XCTAssertEqual(s.alignment(SheetRef("A5")!, c), "l")
        XCTAssertEqual(s.alignment(SheetRef("A6")!, c), "c")
        s.restyle(SheetRange("A1:A2")!) { $0.format = "n"; $0.decimals = 1; $0.align = "c" }
        c = s.calc()
        XCTAssertEqual(s.display(SheetRef("A1")!, c), "0,3")
        XCTAssertEqual(s.display(SheetRef("A2")!, c), "1.234,5")
        XCTAssertEqual(s.alignment(SheetRef("A1")!, c), "c")
        s.restyle(SheetRange("A1")!) { $0.format = "p"; $0.decimals = 0 }
        XCTAssertEqual(s.display(SheetRef("A1")!, s.calc()), "26 %")
        s.restyle(SheetRange("A2")!) { $0.format = "t" }
        XCTAssertEqual(s.calc().value(SheetRef("A2")!), .text("1234,5"), "als Text: wird nicht gerechnet")
    }

    func testRahmen() {
        var s = Sheet(rows: 3, cols: 3)
        s.setBorder(SheetRange("A1:B2")!, "outer")
        XCTAssertEqual(s.style(SheetRef("A1")!).border, 1 | 8)
        XCTAssertEqual(s.style(SheetRef("B1")!).border, 1 | 2)
        XCTAssertEqual(s.style(SheetRef("B2")!).border, 2 | 4)
        s.setBorder(SheetRange("A1:B2")!, "all")
        XCTAssertEqual(s.style(SheetRef("A1")!).border, 15)
        s.setBorder(SheetRange("A1:B2")!, "none")
        XCTAssertTrue(s.styles.isEmpty, "Standard wird nicht gespeichert")
        s.setBorder(SheetRange("A1:C1")!, "bottom")
        XCTAssertEqual(s.style(SheetRef("C1")!).border, 4)
    }

    // MARK: Sortieren und Filtern

    func testSortieren() {
        var s = sheet(["A1": "Fach", "B1": "Note", "C1": "Doppelt",
                       "A2": "Physik", "B2": "2,3", "C2": "=B2*2",
                       "A3": "Mathe", "B3": "1,7", "C3": "=B3*2",
                       "A4": "Chemie", "B4": "", "C4": "=B4*2",
                       "A5": "Bio", "B5": "1,7", "C5": "=B5*2 + $B$2"])
        s.restyle(SheetRange("A3")!) { $0.bold = true }
        s.sort(byCol: 1, ascending: true)
        XCTAssertEqual((1...5).map { s.raw(SheetRef(col: 0, row: $0 - 1)) }, ["Fach", "Mathe", "Bio", "Physik", "Chemie"],
                       "Kopfzeile bleibt, gleiche Werte behalten ihre Reihenfolge, Leeres steht unten")
        XCTAssertEqual(s.raw(SheetRef("C2")!), "=B2*2", "die Formel rechnet weiter mit ihrer Zeile")
        XCTAssertEqual(s.raw(SheetRef("C3")!), "=B3*2 + $B$2", "feste Bezuege bleiben")
        XCTAssertTrue(s.style(SheetRef("A2")!).bold)
        XCTAssertEqual(s.calc().value(SheetRef("C4")!), .number(4.6))
        s.sort(byCol: 1, ascending: false)
        XCTAssertEqual((1...5).map { s.raw(SheetRef(col: 0, row: $0 - 1)) }, ["Fach", "Physik", "Mathe", "Bio", "Chemie"])
        s.sort(byCol: 0, ascending: true)
        XCTAssertEqual((2...5).map { s.raw(SheetRef(col: 0, row: $0 - 1)) }, ["Bio", "Chemie", "Mathe", "Physik"])
        // ohne Kopfzeile sortiert die erste Zeile mit
        s.header = false
        s.sort(byCol: 0, ascending: false)
        XCTAssertEqual(s.raw(SheetRef("A1")!), "Physik")
    }

    func testFiltern() {
        var s = sheet(["A1": "Fach", "B1": "Bestanden", "C1": "LP",
                       "A2": "Mathe", "B2": "ja", "C2": "10",
                       "A3": "Physik", "B3": "nein", "C3": "5",
                       "A4": "Chemie", "B4": "ja", "C4": "5"], rows: 5, cols: 3)
        let c = s.calc()
        XCTAssertEqual(s.filterValues(col: 1, c), ["ja", "nein"])
        XCTAssertEqual(s.filterValues(col: 2, c), ["5", "10"], "Zahlen nach Groesse")
        XCTAssertTrue(s.hiddenRows(c).isEmpty)
        s.filters[1] = ["nein"]
        XCTAssertEqual(s.hiddenRows(c), [2])
        s.filters[2] = ["10"]
        XCTAssertEqual(s.hiddenRows(c), [1, 2], "mehrere Filter zusammen; die Kopfzeile bleibt immer")
        XCTAssertEqual(s.fallbackText(c), "Fach\tBestanden\tLP\nChemie\tja\t5")
        XCTAssertEqual(s.tableHeight(hidden: s.hiddenRows(c)), 3 * Sheet.defaultRowHeight)
        // Spalte davor geloescht: der Filter wandert mit
        s.deleteCols(at: 0)
        XCTAssertEqual(s.filters[0], ["nein"])
        XCTAssertEqual(s.filters[1], ["10"])
    }

    // MARK: Diagramme

    func testDiagrammLiestBeschriftungUndReihen() {
        var s = sheet(["A1": "Fach", "B1": "Note", "C1": "LP",
                       "A2": "Mathe", "B2": "1,7", "C2": "10",
                       "A3": "Physik", "B3": "2,3", "C3": "5",
                       "A4": "Chemie", "B4": "x", "C4": "=C2+C3"], rows: 5, cols: 3)
        let chart = SheetChart(id: "d1", kind: "line", range: SheetRange("A1:C4")!, title: "Noten")
        var content = chart.content(s, s.calc())
        XCTAssertEqual(content.categories, ["Mathe", "Physik", "Chemie"])
        XCTAssertEqual(content.series.map(\.name), ["Note", "LP"])
        XCTAssertEqual(content.series[0].values, [1.7, 2.3, nil], "Text ist eine Luecke")
        XCTAssertEqual(content.series[1].values, [10, 5, 15])
        XCTAssertEqual(content.bounds.max, 15)
        XCTAssertEqual(content.bounds.min, 0)
        // nur Zahlen: Zeilennummern als Beschriftung
        content = SheetChart(id: "d2", range: SheetRange("C2:C4")!).content(s, s.calc())
        XCTAssertEqual(content.categories, ["2", "3", "4"])
        XCTAssertEqual(content.series.map(\.name), ["Spalte C"])
        // gefilterte Zeilen fehlen
        s.filters[0] = ["Physik"]
        XCTAssertEqual(chart.content(s, s.calc()).categories, ["Mathe", "Chemie"])
        XCTAssertTrue(SheetChart(id: "leer", range: SheetRange("A1:A1")!).content(Sheet(), Sheet().calc()).isEmpty)
        XCTAssertEqual(SheetChart(id: "x", kind: "unbekannt", range: SheetRange("A1")!).kind, "bar")
        let a = SheetChart.axis(min: 0, max: 15)
        XCTAssertEqual(a.low, 0)
        XCTAssertEqual(a.high, 15)
        XCTAssertEqual(a.step, 5)
        XCTAssertEqual(SheetChart.axis(min: 0, max: 16).high, 20)
        XCTAssertEqual(SheetChart.axis(min: -3, max: 7).low, -5)
        XCTAssertEqual(SheetChart.axis(min: 0, max: 0).high, 1, "nie eine leere Achse")
    }

    func testDiagrammFolgtBeimEinfuegenUndVerschwindetMitSeinemBereich() {
        var s = sheet(["A1": "1", "A2": "2", "A3": "3"])
        s.charts = [SheetChart(id: "d", range: SheetRange("A1:A3")!)]
        s.insertRows(at: 0)
        XCTAssertEqual(s.charts[0].range.name, "A2:A4")
        s.deleteRows(at: 1, count: 3)
        XCTAssertTrue(s.charts.isEmpty)
    }

    // MARK: Speichern

    func testSpeichernUndLesen() throws {
        var s = sheet(["A1": "Fach", "B1": "=SUMME(B2:B3)", "B2": "1,5", "B3": "50 %"], rows: 4, cols: 3)
        s.restyle(SheetRange("A1")!) { $0.bold = true; $0.italic = true; $0.color = "#D7263D"; $0.fill = "#fff7a8"; $0.align = "c"; $0.border = 15 }
        s.restyle(SheetRange("B2")!) { $0.format = "n"; $0.decimals = 3 }
        s.setWidth(120, col: 0)
        s.setHeight(40, row: 1)
        s.filters[0] = ["x"]
        s.charts = [SheetChart(id: "d1", kind: "pie", range: SheetRange("A1:B3")!, title: "Titel")]
        s.show = "chart"
        s.isDocument = true
        s.header = false
        let text = s.json.jsonString(sortedKeys: true)
        let back = try XCTUnwrap(Sheet(json: try JSONValue.parse(text)))
        XCTAssertEqual(back.cells, s.cells)
        XCTAssertEqual(back.style(SheetRef("A1")!).color, "#d7263d")
        var expected = s
        expected.styles[SheetRef("A1")!]?.color = "#d7263d"
        XCTAssertEqual(back, expected)
        // Unsinn von aussen: begrenzt statt abgestuerzt
        let odd = try JSONValue.parse(#"{"rows": 99999, "cols": 0.5, "cells": {"ZZ9999": "x", "A1": 5}}"#)
        XCTAssertNil(Sheet(json: odd), "ohne Spalten keine Tabelle")
        let huge = try XCTUnwrap(Sheet(json: try JSONValue.parse(#"{"rows": 99999, "cols": 3, "cells": {"ZZ9999": "x", "A1": 5, "B2": "ok"}, "cw": {"0": 1e9, "7": 50}, "fmt": {"A1": {"c": "rot", "dp": 99, "bd": 77}}}"#)))
        XCTAssertEqual(huge.rows, Sheet.maxRows)
        XCTAssertEqual(huge.cells, [SheetRef("B2")!: "ok"])
        XCTAssertEqual(huge.width(0), Sheet.colWidthRange.upperBound)
        XCTAssertTrue(huge.styles.isEmpty)
        XCTAssertNil(Sheet(json: "kein Objekt"))
    }

    func testTabelleIstEinTextobjektDesGemeinsamenFormats() throws {
        var s = sheet(["A1": "Fach", "B1": "LP", "A2": "Mathe", "B2": "10", "A3": "Summe", "B3": "=SUMME(B2:B2)"], rows: 3, cols: 2)
        let o = SheetObject.object(id: "t", x: 500, y: 800, sheet: s, page: (595, 842))
        XCTAssertEqual(o["type"], "text", "kein neuer Objekttyp")
        XCTAssertEqual(o["text"], "Fach\tLP\nMathe\t10\nSumme\t10", "aeltere Apps zeigen die Werte als Text")
        XCTAssertTrue(SheetObject.isSheet(o))
        XCTAssertFalse(SheetObject.isSheet(PageObjectEdit.text(id: "x", x: 0, y: 0)))
        XCTAssertFalse(TextBlock.isBlock(o))
        XCTAssertFalse(StickyNote.isNote(o))
        XCTAssertNoThrow(try SolutionValidator.validateObject(o), "geht mit geteilten Loesungen mit")
        XCTAssertEqual(o["width"]?.double, 2 * Sheet.defaultColWidth)
        XCTAssertEqual(o["x"]?.double, 595 - 168, "ganz auf der Seite")
        XCTAssertEqual(o["y"]?.double, 842 - 72)
        let size = try XCTUnwrap(SheetObject.size(o))
        XCTAssertEqual(size.width, 168)
        XCTAssertEqual(size.height, 72)
        XCTAssertEqual(SheetObject.table(o), s)
        // groesser gezogen (wie jeder Text: nur die Breite) → Massstab 2, die Hoehe folgt
        let wide = PageObjectEdit.scale([o], ids: ["t"], factorX: 2, factorY: 2)[0]
        XCTAssertEqual(SheetObject.size(wide)?.height, 144)
        // Spalte dazu: der Massstab bleibt, die Breite waechst
        s.insertCols(at: 2)
        let saved = SheetObject.saving(s, in: wide)
        XCTAssertEqual(saved["width"]?.double, 3 * Sheet.defaultColWidth * 2)
        XCTAssertEqual(SheetObject.table(saved)?.cols, 3)
        // Diagramm darunter
        s.charts = [SheetChart(id: "d", range: SheetRange("A1:B2")!)]
        let l = SheetObject.layout(s, s.calc())
        XCTAssertEqual(l.height, 72 + Sheet.gap + SheetChart.height)
        XCTAssertEqual(l.width, SheetChart.minWidth)
        s.show = "chart"
        XCTAssertEqual(SheetObject.layout(s, s.calc()).height, SheetChart.height)
        XCTAssertFalse(SheetObject.layout(s, s.calc()).showsTable)
        s.charts = []
        XCTAssertTrue(SheetObject.layout(s, s.calc()).showsTable, "ohne Diagramm bleibt die Tabelle sichtbar")
        // verschieben wie jeder Text
        let moved = PageObjectEdit.move([o], ids: ["t"], dx: -10, dy: -5)[0]
        XCTAssertEqual(moved["sheet"], o["sheet"])
    }
}
