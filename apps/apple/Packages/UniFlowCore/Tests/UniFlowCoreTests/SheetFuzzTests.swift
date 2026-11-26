import XCTest
@testable import UniFlowCore

/// Zufalls- und Lasttests fuer die Tabelle (Auftrag des Inhabers 26.11.2026: "teste bis zum geht nicht mehr").
/// Feste Startwerte: Ein Fund laesst sich mit demselben Wert wiederholen.
final class SheetFuzzTests: XCTestCase {

    /// Kleiner, wiederholbarer Zufall
    struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ n: Int) -> Int { Int(next() % UInt64(max(1, n))) }
        mutating func chance(_ p: Double) -> Bool { Double(next() % 10_000) / 10_000 < p }
        mutating func pick<T>(_ a: [T]) -> T { a[int(a.count)] }
    }

    static let functions = SheetFormula.catalog.map(\.name) + ["IF", "SUM", "AVERAGE", "ROUND", "COUNTIF", "VLOOKUP", "INDEX", "MATCH",
                                                               "WENNS", "SUMMEWENNS", "ZÄHLENWENNS", "ISTNV", "WENNNV", "GIBTSNICHT"]
    static let literals = ["0", "1", "-3", "2,5", "1.5", "1E3", "1e-300", "1E308", "99999999999999999999", "\"\"", "\"ja\"", "\"a, b\"",
                           "WAHR", "FALSCH", "#DIV/0!", "#NV", "„x“", "50%", "0,1", "-0"]
    static let ops = ["+", "-", "*", "/", "^", "&", "=", "<>", "<", ">", "<=", ">=", "≤", "≠", "×", "−", ";", ",", ":", "%", "$", "(", ")"]

    /// Zufaellige Formel (oft gueltig, manchmal kaputt)
    static func formula(_ r: inout Rng, cols: Int, rows: Int, depth: Int = 0) -> String {
        func ref() -> String {
            let c = r.chance(0.08) ? 60 : r.int(cols + 1), row = r.chance(0.05) ? 9_000 : r.int(rows + 2) + 1
            return (r.chance(0.2) ? "$" : "") + SheetRef.colName(c) + (r.chance(0.2) ? "$" : "") + "\(row)"
        }
        func term() -> String {
            switch r.int(depth > 3 ? 3 : 6) {
            case 0: return r.pick(literals)
            case 1: return ref()
            case 2: return ref() + ":" + ref()
            case 3: return "(" + formula(&r, cols: cols, rows: rows, depth: depth + 1) + ")"
            case 4:
                let n = r.int(4)
                let args = (0..<n).map { _ in r.chance(0.1) ? "" : formula(&r, cols: cols, rows: rows, depth: depth + 1) }
                return r.pick(functions) + "(" + args.joined(separator: r.chance(0.8) ? ";" : ",") + ")"
            default: return r.pick(["-", "+", "--"]) + term()
            }
        }
        var s = term()
        for _ in 0..<r.int(3) { s += (r.chance(0.03) ? r.pick(ops) : r.pick(["+", "-", "*", "/", "&", "<", "=", "^"])) + term() }
        if r.chance(0.03) { s += r.pick(ops) }
        return s
    }

    static func randomSheet(_ r: inout Rng, rows: Int, cols: Int, fill: Double = 0.6) -> Sheet {
        var s = Sheet(rows: rows, cols: cols)
        for row in 0..<rows {
            for col in 0..<cols where r.chance(fill) {
                let v: String
                switch r.int(5) {
                case 0, 1: v = "=" + formula(&r, cols: cols, rows: rows)
                case 2: v = r.pick(["Mathe", "Physik", "ja", "nein", "1.500", "14.30", "50 %", "3,20 €", "'12", "", " ", "1,7", "x"])
                default: v = r.pick(["0", "1", "2", "-4,5", "1E3", "100", "0,1", "7"])
                }
                s.set(v, at: SheetRef(col: col, row: row))
            }
        }
        return s
    }

    // MARK: Kein Absturz, kein Haengen

    func testZufaelligeFormelnStuerzenNichtAbUndEndenImmer() {
        var r = Rng(state: 26_11_2026)
        let started = Date()
        for round in 0..<400 {
            let s = Self.randomSheet(&r, rows: 6 + r.int(10), cols: 3 + r.int(5))
            let c = s.calc()
            for ref in s.bounds.refs {
                let v = c.value(ref)
                if case .number(let d) = v { XCTAssertTrue(d.isFinite, "Runde \(round) \(ref.name): \(s.raw(ref)) → \(d)") }
                _ = s.display(ref, c)
                _ = s.alignment(ref, c)
            }
            _ = s.fallbackText(c)
            for ch in s.charts { _ = ch.content(s, c) }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 60, "400 Tabellen in hoechstens einer Minute")
    }

    /// Reine Zeichen-Suppe: weder Lesen noch Rechnen noch Umschreiben darf abstuerzen
    func testZeichenSuppe() {
        var r = Rng(state: 4711)
        let alphabet = Array("=+-*/^&%$:;,.()\"„“#!?<>≤≥≠×÷−–AZaz019 EeWAHRSUMMEWENN") + ["\u{301}", "😀", "\n", "\t"]
        var s = Sheet(rows: 4, cols: 4)
        for i in 0..<5_000 {
            let text = "=" + String((0..<r.int(40)).map { _ in r.pick(alphabet) })
            s.set(text, at: SheetRef(col: i % 4, row: (i / 4) % 4))
            _ = s.calc().value(SheetRef(col: i % 4, row: (i / 4) % 4))
            _ = SheetFormula.shifted(text, dCol: r.int(5) - 2, dRow: r.int(5) - 2)
            _ = SheetFormula.adjusted(text, rows: r.chance(0.5), at: r.int(5), count: r.int(5) - 2)
            _ = SheetFormula.movedRow(text, from: r.int(4), to: r.int(4))
            _ = SheetFormula.references(text)
        }
    }

    // MARK: Gleiche Ergebnisse, egal in welcher Reihenfolge gefragt

    func testReihenfolgeDerFragenAendertKeinErgebnis() {
        var r = Rng(state: 99)
        for round in 0..<200 {
            let s = Self.randomSheet(&r, rows: 8, cols: 5, fill: 0.8)
            let refs = s.bounds.refs
            let forward = s.calc(), backward = s.calc(), shuffled = s.calc()
            let a = refs.map { forward.value($0) }
            let b = refs.reversed().map { backward.value($0) }.reversed()
            var order = refs
            for i in stride(from: order.count - 1, to: 0, by: -1) { order.swapAt(i, r.int(i + 1)) }
            var c: [SheetRef: SheetValue] = [:]
            for ref in order { c[ref] = shuffled.value(ref) }
            for (i, ref) in refs.enumerated() {
                XCTAssertEqual(a[i], Array(b)[i], "Runde \(round) \(ref.name) \(s.raw(ref)): vorwaerts vs. rueckwaerts")
                XCTAssertEqual(a[i], c[ref], "Runde \(round) \(ref.name) \(s.raw(ref)): vorwaerts vs. gemischt")
            }
        }
    }

    // MARK: Speichern, Einfuegen/Loeschen, Kopieren

    func testSpeichernUndLesenGibtDieselbeTabelle() {
        var r = Rng(state: 7)
        for _ in 0..<300 {
            var s = Self.randomSheet(&r, rows: 1 + r.int(20), cols: 1 + r.int(8))
            if r.chance(0.5) { s.restyle(SheetRange(SheetRef(col: 0, row: 0), SheetRef(col: s.cols - 1, row: 0))) { $0.bold = true; $0.fill = "#d6f5c8" } }
            if r.chance(0.3) { s.setBorder(s.bounds, r.pick(["outer", "all", "bottom"])) }
            if r.chance(0.3) { s.setWidth(Double(30 + r.int(300)), col: r.int(s.cols)) }
            if r.chance(0.3) { s.charts = [SheetChart(id: "c", kind: r.pick(["bar", "line", "pie"]), range: s.bounds, title: "T")] }
            if r.chance(0.3) { s.filters[0] = ["x"] }
            s.header = r.chance(0.7)
            s.isDocument = r.chance(0.2)
            XCTAssertEqual(Sheet(json: s.json), s)
            // ueber Text (wie auf der Platte) und zurueck
            let text = s.json.jsonString(sortedKeys: true)
            XCTAssertEqual(Sheet(json: try? JSONValue.parse(text)), s)
        }
    }

    func testZeilenEinfuegenUndWiederLoeschenStelltAllesWiederHer() {
        var r = Rng(state: 12)
        for round in 0..<300 {
            let s = Self.randomSheet(&r, rows: 10, cols: 5)
            let at = r.int(s.rows + 1), n = 1 + r.int(4)
            var t = s
            if r.chance(0.5) {
                t.insertRows(at: at, count: n)
                t.deleteRows(at: at, count: n)
            } else {
                t.insertCols(at: min(at, s.cols), count: n)
                t.deleteCols(at: min(at, s.cols), count: n)
            }
            XCTAssertEqual(t.cells, s.cells, "Runde \(round)")
            XCTAssertEqual(t.rows, s.rows)
            XCTAssertEqual(t.cols, s.cols)
        }
    }

    func testKopierenHinUndZurueck() {
        var r = Rng(state: 13)
        for _ in 0..<2_000 {
            let f = "=" + Self.formula(&r, cols: 6, rows: 30)
            let dc = r.int(5) - 2, dr = r.int(9) - 4
            let there = SheetFormula.shifted(f, dCol: dc, dRow: dr)
            guard !there.contains("#BEZUG!") || f.contains("#BEZUG!") else { continue }
            XCTAssertEqual(SheetFormula.shifted(there, dCol: -dc, dRow: -dr), f, "\(f) → \(there)")
        }
    }

    func testSortierenBehaeltAlleZeilen() {
        var r = Rng(state: 14)
        for round in 0..<200 {
            var s = Sheet(rows: 12, cols: 3)
            s.set("Kopf", at: SheetRef("A1")!)
            for row in 1..<12 where r.chance(0.85) {
                s.set(r.pick(["Mathe", "physik", "Ärger", "Zoo", "1", "10", "2", "-1", "WAHR", "1,5", ""]), at: SheetRef(col: 0, row: row))
                s.set("\(row)", at: SheetRef(col: 1, row: row))
            }
            let before = s.cells.values.sorted()
            s.sort(byCol: 0, ascending: r.chance(0.5))
            XCTAssertEqual(s.cells.values.sorted(), before, "Runde \(round): nichts geht verloren, nichts kommt dazu")
            XCTAssertEqual(s.raw(SheetRef("A1")!), "Kopf")
            // sortiert ist sortiert: noch einmal aendert nichts
            let once = s.cells
            s.sort(byCol: 0, ascending: true)
            var again = s
            again.sort(byCol: 0, ascending: true)
            XCTAssertEqual(again.cells, s.cells)
            _ = once
        }
    }

    // MARK: Zahlen

    func testZahlenHinUndZurueck() {
        var r = Rng(state: 15)
        for _ in 0..<20_000 {
            let magnitude = pow(10, Double(r.int(16)) - 6)
            let d = (Double(r.int(2_000_001)) - 1_000_000) / 1_000_000 * magnitude
            if let back = SheetText.parseNumber(SheetText.general(d))?.value {
                XCTAssertEqual(back, d, accuracy: max(abs(d) * 1e-9, 1e-12), SheetText.general(d))
            } else {
                XCTFail("nicht lesbar: \(SheetText.general(d)) aus \(d)")
            }
            let n = r.int(4)
            let shown = SheetText.fixed(d, decimals: n)
            let read = SheetText.parseNumber(shown)?.value
            XCTAssertNotNil(read, shown)
            // kaufmaennisch gerundet (4,0825 → 4,083): hoechstens eine halbe Stelle daneben
            XCTAssertEqual(read ?? .nan, d, accuracy: pow(10, -Double(n)) * 0.5 * (1 + 1e-9) + abs(d) * 1e-12, "\(d) → \(shown)")
        }
    }

    // MARK: KI-Antworten

    func testKaputteKIAntwortenStuerzenNichtAbUndBleibenInDenGrenzen() {
        var r = Rng(state: 16)
        let pieces = ["{", "}", "[", "]", "\"zellen\"", "\"neu\"", "true", ":", ",", "\"A1\"", "\"AZ500\"", "\"ZZ9999\"", "\"=SUMME(A1:A3)\"",
                      "1,7", "-0", "\"diagramme\"", "\"bereich\"", "\"A1:B9\"", "\"art\"", "\"kreis\"", "```json", "```", "| a | b |", "|---|---|",
                      "\n", "Gern!", "\\\"", "null", "1e999", "\"zeilen\"", "[[\"x\",1]]"]
        for _ in 0..<3_000 {
            let text = (0..<r.int(30)).map { _ in r.pick(pieces) }.joined(separator: r.chance(0.5) ? "" : " ")
            guard let plan = SheetAI.parse(text) else { continue }
            XCTAssertLessThanOrEqual(plan.cells.count, SheetAI.maxCells)
            XCTAssertTrue(plan.cells.keys.allSatisfy { $0.row < SheetAI.maxRows && $0.col < SheetAI.maxCols })
            var s = Self.randomSheet(&r, rows: 5, cols: 4)
            let out = SheetAI.apply(plan, to: &s, at: SheetRef(col: r.int(4), row: r.int(5)))
            XCTAssertLessThanOrEqual(s.rows, Sheet.maxRows)
            XCTAssertLessThanOrEqual(s.cols, Sheet.maxCols)
            XCTAssertLessThanOrEqual(s.charts.count, SheetChart.maxPerSheet)
            XCTAssertTrue(s.charts.allSatisfy { s.bounds.contains($0.range.from) && s.bounds.contains($0.range.to) })
            _ = out.summary
        }
    }

    // MARK: Last: volle Tabelle 500 x 52

    func testVolleTabelleRechnetSpeichertSortiertInVertretbarerZeit() {
        var s = Sheet(rows: Sheet.maxRows, cols: Sheet.maxCols)
        for row in 0..<Sheet.maxRows {
            for col in 0..<Sheet.maxCols {
                let ref = SheetRef(col: col, row: row)
                switch col % 4 {
                case 0: s.set("\(row * 7 % 113)", at: ref)
                case 1: s.set(row == 0 ? "=A1*2" : "=\(SheetRef.colName(col))\(row)+\(SheetRef.colName(col - 1))\(row + 1)", at: ref)   // Kette nach unten
                case 2: s.set("=SUMME(\(SheetRef.colName(col - 2))1:\(SheetRef.colName(col - 2))\(row + 1))", at: ref)                   // laufende Summe
                default: s.set("=WENN(\(SheetRef.colName(col - 1))\(row + 1)>100;\"viel\";\"wenig\")", at: ref)
                }
            }
        }
        XCTAssertEqual(s.cells.count, 26_000)
        func time(_ what: String, limit: Double, _ f: () -> Void) {
            let t = Date()
            f()
            let d = Date().timeIntervalSince(t)
            print("[Last] \(what): \(Int(d * 1000)) ms")
            XCTAssertLessThan(d, limit, what)
        }
        var c = s.calc()
        time("alle 26 000 Zellen rechnen, unterste zuerst", limit: 20) {
            for row in stride(from: Sheet.maxRows - 1, through: 0, by: -1) { for col in 0..<Sheet.maxCols { _ = c.value(SheetRef(col: col, row: row)) } }
        }
        XCTAssertEqual(c.value(SheetRef(col: 2, row: 499)), .number(Double((0..<500).reduce(0) { $0 + $1 * 7 % 113 })))
        c = s.calc()
        time("sichtbaren Ausschnitt (20 x 10) einer frischen Rechnung, unten", limit: 10) {
            for row in 480..<500 { for col in 0..<10 { _ = c.value(SheetRef(col: col, row: row)) } }
        }
        time("Ersatztext", limit: 20) { _ = s.fallbackText(s.calc()) }
        var json: JSONValue = .null
        time("speichern (JSON)", limit: 5) { json = s.json }
        time("lesen (JSON)", limit: 5) { XCTAssertEqual(Sheet(json: json), s) }
        time("Objekt fuer die Seite schreiben", limit: 30) { _ = SheetObject.saving(s, in: SheetObject.object(id: "x", x: 0, y: 0, sheet: s)) }
        var t = s
        time("sortieren", limit: 30) { t.sort(byCol: 0, ascending: true) }
        time("Zeile oben einfuegen", limit: 10) { t.insertRows(at: 1) }
        let o = SheetObject.saving(s, in: SheetObject.object(id: "x", x: 0, y: 0, sheet: Sheet()))
        time("1000 Mal die Groesse auf der Seite (bei jedem Antippen)", limit: 0.2) {
            for _ in 0..<1_000 { _ = SheetObject.size(o) }
        }
    }
}
