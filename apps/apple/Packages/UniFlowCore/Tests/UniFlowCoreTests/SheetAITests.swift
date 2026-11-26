import XCTest
@testable import UniFlowCore

/// KI-Hilfe fuer Tabellen (26.11.2026): Auftrag passt in die Grenzen der KI-Hilfe, Antworten werden grosszuegig gelesen
/// (JSON, Markdown-Zaun, Text drumherum, Zeilenlisten, Markdown-Tabelle) und streng eingesetzt.
final class SheetAITests: XCTestCase {

    private func sheet(_ cells: [String: String], rows: Int = 6, cols: Int = 4) -> Sheet {
        var s = Sheet(rows: rows, cols: cols)
        for (k, v) in cells { s.set(v, at: SheetRef(k)!) }
        return s
    }

    func testAuftragPasstInDieFrageDerKIHilfe() throws {
        let long = String(repeating: "Bitte eine sehr ausführliche Notenübersicht. ", count: 40)
        let q = SheetAI.question(wish: long)
        XCTAssertLessThanOrEqual(q.count, SheetAI.questionLimit, "die KI-Hilfe kuerzt Fragen auf 1000 Zeichen")
        XCTAssertTrue(q.contains("JSON"))
        XCTAssertTrue(q.hasSuffix("12 Spalten."), "die Regeln gehen vollstaendig mit")
        XCTAssertTrue(SheetAI.question(wish: "Lernplan\nmit »Wochen«").contains("»Lernplan mit Wochen«"), "eine Zeile, eigene Anfuehrungszeichen raus")

        let s = sheet(["A1": "Fach", "B1": "Note", "B2": "=SUMME(B3:B4)", "A2": "Zeile\nzwei"])
        let ctx = SheetAI.context(s, selection: SheetRange("A1:B2")!)
        XCTAssertEqual(ctx, "TABELLE: 6 Zeilen, 4 Spalten. Ausgewählt: A1:B2. Zellen (Name, Tabulator, Inhalt):\nA1\tFach\nB1\tNote\nA2\tZeile zwei\nB2\t=SUMME(B3:B4)")
        XCTAssertTrue(SheetAI.context(Sheet(), selection: SheetRange("A1")!).hasSuffix("(noch leer)"))
        var big = Sheet(rows: 500, cols: 52)
        for r in 0..<500 { for c in 0..<10 { big.set("Wert \(r) \(c)", at: SheetRef(col: c, row: r)) } }
        let capped = SheetAI.context(big, selection: SheetRange("A1")!)
        XCTAssertLessThanOrEqual(capped.count, SheetAI.contextLimit + 40)
        XCTAssertTrue(capped.hasSuffix("(weitere Zellen ausgelassen)"))

        let body = SheetAI.requestBody(wish: "Summe", sheet: s, selection: SheetRange("A1")!)
        XCTAssertEqual(body["mode"], "ask")
        XCTAssertEqual(body["file_id"], .null)
        XCTAssertEqual(body["question"]?.string, SheetAI.question(wish: "Summe"))
        XCTAssertEqual(body["page_text"]?.string, SheetAI.context(s, selection: SheetRange("A1")!))
        // der Auftrag passt unveraendert in den Prompt der KI-Hilfe
        let prompt = AIPrompts.tutor(mode: "ask", pageText: body["page_text"]?.string ?? "", question: body["question"]?.string ?? "")
        XCTAssertTrue(prompt.contains(SheetAI.question(wish: "Summe")))
        XCTAssertTrue(prompt.contains("B2\t=SUMME(B3:B4)"))
    }

    func testAntwortenLesen() throws {
        let json = #"{"neu":true,"zellen":{"A1":"Fach","B1":"Note","A2":"Mathe","B2":1.7,"B3":"=MITTELWERT(B2:B2)","C1":true,"ZZ99999":"x","D1":null},"diagramme":[{"art":"Balken","bereich":"$A$1:$B$2","titel":"Noten"},{"art":"Kreisdiagramm","bereich":"A1:B2"},{"art":"x"}],"hinweis":"Fertig."}"#
        let p = try XCTUnwrap(SheetAI.parse(json))
        XCTAssertTrue(p.replace)
        XCTAssertFalse(p.relative)
        XCTAssertEqual(p.cells, [SheetRef("A1")!: "Fach", SheetRef("B1")!: "Note", SheetRef("A2")!: "Mathe", SheetRef("B2")!: "1,7",
                                 SheetRef("B3")!: "=MITTELWERT(B2:B2)", SheetRef("C1")!: "WAHR"], "Zahlen deutsch, Unsinn faellt weg")
        XCTAssertEqual(p.charts, [SheetAI.Chart(kind: "bar", range: SheetRange("A1:B2")!, title: "Noten"),
                                  SheetAI.Chart(kind: "pie", range: SheetRange("A1:B2")!, title: "")], "ohne Bereich kein Diagramm")
        XCTAssertEqual(p.note, "Fertig.")

        // im Markdown-Zaun, mit Saetzen davor und danach, englische Schluessel
        let fenced = "Gern! Hier ist dein Plan:\n```json\n{\"cells\": {\"a1\": \"Woche\", \"b1\": \"Thema {wichtig}\"}, \"charts\": []}\n```\nViel Erfolg – {noch} Fragen?"
        XCTAssertEqual(SheetAI.parse(fenced)?.cells, [SheetRef("A1")!: "Woche", SheetRef("B1")!: "Thema {wichtig}"])
        XCTAssertEqual(SheetAI.parse(fenced)?.replace, false)

        // Zeilen statt Zellnamen
        let rows = try XCTUnwrap(SheetAI.parse(#"{"zeilen":[["Fach","LP"],["Mathe",10],["",5]]}"#))
        XCTAssertTrue(rows.relative)
        XCTAssertEqual(rows.cells, [SheetRef("A1")!: "Fach", SheetRef("B1")!: "LP", SheetRef("A2")!: "Mathe", SheetRef("B2")!: "10", SheetRef("B3")!: "5"])

        // nur ein Diagramm
        let chart = try XCTUnwrap(SheetAI.parse(#"{"diagramme":[{"art":"linien","bereich":"A1:C5","titel":"Verlauf"}]}"#))
        XCTAssertTrue(chart.cells.isEmpty)
        XCTAssertEqual(chart.charts.first?.kind, "line")

        // die KI antwortet doch mit einer Markdown-Tabelle
        let md = "## 1. Übersicht\n\n| Fach | **Note** |\n|:---|---:|\n| Mathe | 1,7 |\n| Physik | `2,3` |\n\nNoch Fragen?\n| x | y |"
        let table = try XCTUnwrap(SheetAI.parse(md))
        XCTAssertTrue(table.relative)
        XCTAssertEqual(table.cells, [SheetRef("A1")!: "Fach", SheetRef("B1")!: "Note", SheetRef("A2")!: "Mathe", SheetRef("B2")!: "1,7",
                                     SheetRef("A3")!: "Physik", SheetRef("B3")!: "2,3"], "nur die erste Tabelle, ohne Auszeichnung")

        XCTAssertNil(SheetAI.parse("Das kann ich leider nicht."))
        XCTAssertNil(SheetAI.parse(#"{"zellen":{},"hinweis":"nichts"}"#))
        XCTAssertNil(SheetAI.parse("{ kaputt"))
        XCTAssertNil(SheetAI.parse(""))
    }

    func testEinsetzen() throws {
        // in eine vorhandene Tabelle: nur die genannten Zellen, die Tabelle waechst
        var s = sheet(["A1": "Fach", "B1": "Note", "A2": "Mathe", "B2": "1,7"], rows: 2, cols: 2)
        s.restyle(SheetRange("A1")!) { $0.bold = true }
        var plan = SheetAI.Plan()
        plan.cells = [SheetRef("A3")!: "Physik", SheetRef("B3")!: "2,3", SheetRef("A4")!: "Schnitt", SheetRef("B4")!: "=MITTELWERT(B2:B3)",
                      SheetRef("C1")!: "50 %", SheetRef("C2")!: "=QUATSCH(B2)"]
        plan.charts = [SheetAI.Chart(kind: "bar", range: SheetRange("A1:Z99")!, title: "Noten")]
        var out = SheetAI.apply(plan, to: &s, at: SheetRef("A1")!)
        XCTAssertEqual(s.rows, 4)
        XCTAssertEqual(s.cols, 3)
        XCTAssertEqual(s.raw(SheetRef("A2")!), "Mathe", "das Vorhandene bleibt")
        XCTAssertTrue(s.style(SheetRef("A1")!).bold)
        XCTAssertEqual(s.calc().value(SheetRef("B4")!), .number(2))
        XCTAssertEqual(s.display(SheetRef("C1")!, s.calc()), "50 %")
        XCTAssertEqual(out.cells, 6)
        XCTAssertEqual(out.charts, 1)
        XCTAssertEqual(out.broken, 1, "unbekannte Funktion wird gemeldet")
        XCTAssertEqual(out.filled?.name, "A1:C4", "C1 und C2 gehoeren dazu")
        XCTAssertEqual(s.charts.first?.range.name, "A1:C4", "der Bereich bleibt in der Tabelle")
        XCTAssertEqual(out.summary, "Die KI hat 6 Zellen gefüllt und 1 Diagramm angelegt. Eine Formel muss noch geprüft werden.")

        // "neu": vorher leeren
        plan = SheetAI.Plan()
        plan.replace = true
        plan.cells = [SheetRef("A1")!: "Woche", SheetRef("B1")!: "Thema"]
        out = SheetAI.apply(plan, to: &s, at: SheetRef("B2")!)
        XCTAssertEqual(s.cells.count, 2)
        XCTAssertTrue(s.styles.isEmpty)
        XCTAssertTrue(s.charts.isEmpty)
        XCTAssertEqual(out.summary, "Die KI hat 2 Zellen gefüllt.")

        // Antwort ohne Zellnamen: in einer gefuellten Tabelle an der gewaehlten Stelle, Formeln wandern mit
        plan = SheetAI.Plan()
        plan.relative = true
        plan.cells = [SheetRef("A1")!: "3", SheetRef("A2")!: "4", SheetRef("A3")!: "=SUMME(A1:A2)"]
        plan.charts = [SheetAI.Chart(kind: "pie", range: SheetRange("A1:A2")!, title: "")]
        out = SheetAI.apply(plan, to: &s, at: SheetRef("D5")!)
        XCTAssertEqual(s.raw(SheetRef("D7")!), "=SUMME(D5:D6)")
        XCTAssertEqual(s.calc().value(SheetRef("D7")!), .number(7))
        XCTAssertEqual(s.charts.last?.range.name, "D5:D6")
        XCTAssertEqual(out.filled?.name, "D5:D7")
        // in einer leeren Tabelle: ab A1
        var empty = Sheet()
        SheetAI.apply(plan, to: &empty, at: SheetRef("C3")!)
        XCTAssertEqual(empty.raw(SheetRef("A3")!), "=SUMME(A1:A2)")

        // ausgeblendete Diagramme werden wieder gezeigt; nie mehr als erlaubt
        var many = sheet(["A1": "1"])
        many.show = "table"
        plan = SheetAI.Plan()
        plan.charts = Array(repeating: SheetAI.Chart(kind: "bar", range: SheetRange("A1")!, title: ""), count: 9)
        out = SheetAI.apply(plan, to: &many, at: SheetRef("A1")!)
        XCTAssertEqual(many.charts.count, SheetChart.maxPerSheet)
        XCTAssertEqual(Set(many.charts.map(\.id)).count, SheetChart.maxPerSheet, "jedes Diagramm mit eigener Kennung")
        XCTAssertEqual(many.show, "both")
        XCTAssertEqual(SheetAI.apply(SheetAI.Plan(), to: &many, at: SheetRef("A1")!).summary, "Die KI hat nichts geändert.")
        // was eingesetzt wird, bleibt ein Textobjekt des gemeinsamen Formats
        XCTAssertNoThrow(try SolutionValidator.validateObject(SheetObject.object(id: "t", x: 0, y: 0, sheet: s)))
    }
}
