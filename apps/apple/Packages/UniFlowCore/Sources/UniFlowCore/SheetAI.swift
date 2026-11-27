import Foundation

/// KI-Hilfe fuer Tabellen (Auftrag des Inhabers 26.11.2026: "Diagramme durch KI und Tabellen mit Hilfe KI machen
/// koennen ... fuer Pro AI Nutzer"). Die App schickt den Wunsch und die Tabelle als gewoehnliche Frage an die KI-Hilfe
/// (`POST /api/ai/tutor`, Modus "ask" - kein neuer Weg im Dienst, kein Server-Update) und liest aus der Antwort einen
/// Bauplan: Zellen (Text, Zahlen, Formeln) und Diagramme. Gelesen wird grosszuegig (JSON, auch in Markdown-Zaeunen
/// oder mit Text drumherum; ersatzweise eine Markdown-Tabelle), eingesetzt streng: nur Zellen innerhalb der Grenzen,
/// Formeln rechnet das eigene Rechenwerk. Alles zusammen ist ein Rueckgaengig-Schritt.
public enum SheetAI {
    /// Die KI-Hilfe kuerzt die Frage auf 1000 Zeichen (`AIPrompts.tutor`): Der Auftrag muss mit Wunsch darunter bleiben
    public static let questionLimit = 1_000
    public static let wishLimit = 240
    /// Tabelle als Text im Feld `page_text` (dort gehen bis zu 9000 Zeichen mit)
    public static let contextLimit = 7_000
    /// So viel uebernimmt die App hoechstens aus einer Antwort
    public static let maxCells = 3_000
    /// So weit liest die App eine Antwort (so gross wie jede Tabelle)
    public static let maxRows = Sheet.maxRows
    public static let maxCols = Sheet.maxCols
    /// So weit darf die KI eine Tabelle wachsen lassen: Eine vorhandene Tabelle darf sie ganz fuellen, neu anlegen bis
    /// 200 Zeilen und 26 Spalten - eine verirrte Zelle "AZ500" blaeht eine kleine Tabelle nicht auf (die Meldung nennt sie)
    public static let growRows = 200
    public static let growCols = 26

    public static let examples = ["Notenübersicht mit Schnitt und Leistungspunkten", "Lernplan für die nächsten 4 Wochen",
                                  "Haushaltsbuch für einen Monat mit Summe", "Mach aus dieser Tabelle ein passendes Diagramm"]

    // MARK: Anfrage

    /// Tabelle fuer die KI: je Zeile Zellname, Tabulator, was getippt wurde (Formeln als Formeln)
    public static func context(_ s: Sheet, selection: SheetRange) -> String {
        var lines = ["TABELLE: \(s.rows) Zeilen, \(s.cols) Spalten. Ausgewählt: \(selection.name). Zellen (Name, Tabulator, Inhalt):"]
        if s.cells.isEmpty { lines.append("(noch leer)") }
        var used = lines.joined(separator: "\n").count
        for r in s.cells.keys.sorted() where s.contains(r) {
            let raw = (s.cells[r] ?? "").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
            let line = r.name + "\t" + String(raw.prefix(120))
            guard used + line.count + 1 <= contextLimit else { lines.append("(weitere Zellen ausgelassen)"); break }
            used += line.count + 1
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// Auftrag an die KI (als "Frage"). Der Wunsch wird gekuerzt, damit die Regeln immer vollstaendig mitgehen.
    public static func question(wish: String) -> String {
        let w = wish.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "»", with: "").replacingOccurrences(of: "«", with: "")
            .trimmingCharacters(in: .whitespaces)
        let rules = #"Antworte NUR mit einem JSON-Objekt, ohne Erklärung, ohne Markdown, ohne LaTeX: {"neu":false,"zellen":{"A1":"Fach","B2":"1,7","B7":"=SUMME(B2:B6)"},"diagramme":[{"art":"balken","bereich":"A1:B6","titel":"Noten"}],"hinweis":"ein kurzer Satz"}. "neu":true leert die Tabelle vorher. In "zellen" nur, was sich ändert; erste Zeile = Überschriften. Formeln deutsch wie in Excel mit = und ; (SUMME, MITTELWERT, WENN, RUNDEN, ZÄHLENWENN, SUMMENPRODUKT, MIN, MAX), jeder Wert in Anführungszeichen. "art": balken, linien oder kreis; "diagramme" nur auf Wunsch oder wenn es passt. Höchstens 40 Zeilen, 8 Spalten."#
        let head = "Keine Frage zum Stoff: Ich baue eine Tabelle wie in Excel; sie steht unter SEITENINHALT. Mein Wunsch: »"
        let room = max(20, min(wishLimit, questionLimit - head.count - rules.count - 3))
        return head + String(w.prefix(room)) + "«. " + rules
    }

    /// Rumpf fuer `POST /api/ai/tutor`
    public static func requestBody(wish: String, sheet: Sheet, selection: SheetRange) -> JSONValue {
        ["mode": "ask", "page": 1, "file_id": .null, "question": .string(question(wish: wish)),
         "page_text": .string(context(sheet, selection: selection)), "history": .array([])]
    }

    // MARK: Antwort lesen

    public struct Chart: Equatable, Sendable {
        public var kind: String
        public var range: SheetRange
        public var title: String
    }

    public struct Plan: Equatable, Sendable {
        /// Tabelle vorher leeren
        public var replace = false
        /// Die Zellen stehen ab A1 und sollen an der gewaehlten Stelle eingesetzt werden (Antwort ohne Zellnamen)
        public var relative = false
        public var cells: [SheetRef: String] = [:]
        public var charts: [Chart] = []
        public var note = ""
        /// Zellen der Antwort, die nicht in die Tabelle passten
        public var dropped = 0
        public init() {}
        public var isEmpty: Bool { cells.isEmpty && charts.isEmpty }
    }

    static func cellText(_ v: JSONValue) -> String? {
        switch v {
        case .string(let s): return s
        case .number(let d): return d.isFinite ? SheetText.general(d) : nil
        case .bool(let b): return b ? "WAHR" : "FALSCH"
        default: return nil
        }
    }

    static func chartKind(_ s: String) -> String? {
        let t = s.lowercased()
        if t.contains("kreis") || t.contains("pie") || t.contains("torte") { return "pie" }
        if t.contains("lini") || t.contains("line") || t.contains("verlauf") { return "line" }
        if t.contains("balken") || t.contains("bar") || t.contains("säule") || t.contains("saeule") || t.contains("column") { return "bar" }
        return nil
    }

    /// JSON-Objekt in einem Text finden (auch zwischen Markdown-Zaeunen oder mit Saetzen davor und danach)
    static func jsonObject(in text: String) -> JSONValue? {
        var searchFrom = text.startIndex
        var tries = 0
        while let open = text[searchFrom...].firstIndex(of: "{") {
            var end = text.endIndex
            while tries < 24, let close = text[open..<end].lastIndex(of: "}") {
                tries += 1
                if let v = try? JSONValue.parse(String(text[open...close])), v.object != nil { return v }
                end = close
            }
            searchFrom = text.index(after: open)
            // nur wenige Anlaeufe: ein langer Text ohne JSON soll nicht quadratisch teuer werden
            if text.distance(from: text.startIndex, to: searchFrom) > 400 { break }
        }
        return nil
    }

    /// Rettung fuer eine Antwort, die kein sauberes JSON ist (abgeschnitten, Zahl mit Komma ohne Anfuehrungszeichen):
    /// alle Paare `"B2": "…"` einzeln herauslesen. Diagramme gehen dabei verloren.
    static func looseCells(in text: String) -> Plan? {
        let pattern = #""\$?([A-Za-z]{1,2})\$?([0-9]{1,3})"\s*:\s*(?:"((?:[^"\\]|\\.)*)"|(-?[0-9]+(?:[.,][0-9]+)?)(?=\s*(?:,\s*"|\}|\]|$))|(true|false))"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        var plan = Plan()
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let r = SheetRef(ns.substring(with: m.range(at: 1)) + ns.substring(with: m.range(at: 2))) else { continue }
            var value: String?
            if m.range(at: 3).location != NSNotFound {
                value = (try? JSONValue.parse("\"" + ns.substring(with: m.range(at: 3)) + "\""))?.string
            } else if m.range(at: 4).location != NSNotFound {
                value = ns.substring(with: m.range(at: 4)).replacingOccurrences(of: ".", with: ",")
            } else if m.range(at: 5).location != NSNotFound {
                value = ns.substring(with: m.range(at: 5)) == "true" ? "WAHR" : "FALSCH"
            }
            if let value { plan.cells[r] = value }
        }
        guard plan.cells.count >= 2 else { return nil }
        plan.replace = text.range(of: #""(neu|new|replace|leeren)"\s*:\s*true"#, options: .regularExpression) != nil
        return limited(plan)
    }

    /// Nur was in die Grenzen passt; bei zu vielen Zellen die ersten Zeilen (nicht irgendwelche). Was wegfaellt, zaehlt
    /// `dropped` (die Meldung nennt es).
    static func limited(_ plan: Plan) -> Plan {
        var out = plan
        out.cells = [:]
        for r in plan.cells.keys.sorted() {
            guard r.row < maxRows, r.col < maxCols, out.cells.count < maxCells else { out.dropped += 1; continue }
            out.cells[r] = String((plan.cells[r] ?? "").prefix(Sheet.maxCellLength))
        }
        return out
    }

    private static func first(_ o: JSONValue, _ keys: [String]) -> JSONValue? {
        for k in keys { if let v = o[k], !v.isNull { return v } }
        return nil
    }

    /// Bauplan aus der Antwort der KI; nil, wenn nichts Brauchbares darin steht
    public static func parse(_ answer: String) -> Plan? {
        if let o = jsonObject(in: answer) {
            var plan = Plan()
            plan.replace = first(o, ["neu", "new", "replace", "leeren"])?.bool == true
            if let cells = first(o, ["zellen", "cells"])?.object {
                for (k, v) in cells {
                    guard let r = SheetRef(k), let text = cellText(v) else { continue }
                    plan.cells[r] = text
                }
            }
            // manche Antworten liefern Zeilen statt Zellnamen: [["Fach","Note"],["Mathe",1.7]]
            if plan.cells.isEmpty, let rows = first(o, ["zeilen", "rows", "tabelle", "table"])?.array {
                plan.relative = true
                for (r, row) in rows.prefix(maxRows).enumerated() {
                    for (c, v) in (row.array ?? []).prefix(maxCols).enumerated() {
                        guard let text = cellText(v), !text.isEmpty else { continue }
                        plan.cells[SheetRef(col: c, row: r)] = text
                    }
                }
            }
            for c in (first(o, ["diagramme", "charts", "diagramm", "chart"])?.array ?? []).prefix(SheetChart.maxPerSheet) {
                guard let range = first(c, ["bereich", "range"])?.string.flatMap({ SheetRange($0.replacingOccurrences(of: "$", with: "")) }) else { continue }
                let kind = first(c, ["art", "kind", "typ", "type"])?.string.flatMap(chartKind) ?? "bar"
                plan.charts.append(Chart(kind: kind, range: range, title: String((first(c, ["titel", "title"])?.string ?? "").prefix(80))))
            }
            plan.note = String((first(o, ["hinweis", "note", "erklaerung", "erklärung"])?.string ?? "").prefix(300))
            plan = limited(plan)
            // leeren ohne neuen Inhalt waere nur Verlust
            if plan.cells.isEmpty { plan.replace = false }
            if !plan.isEmpty { return plan }
        }
        return looseCells(in: answer) ?? markdownTable(in: answer)
    }

    /// Ersatz: eine Markdown-Tabelle (`| Fach | Note |`) in der Antwort
    static func markdownTable(in answer: String) -> Plan? {
        var plan = Plan()
        plan.relative = true
        var row = 0
        for line in answer.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("|"), t.count > 2 else {
                if row > 0 { break }                              // nur die erste Tabelle
                continue
            }
            var parts = t.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.first == "" { parts.removeFirst() }
            if parts.last == "" { parts.removeLast() }
            // Trennzeile |---|:---:|
            if !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0 == "-" || $0 == ":" } }) { continue }
            guard row < maxRows else { break }
            for (c, v) in parts.prefix(maxCols).enumerated() where !v.isEmpty && plan.cells.count < maxCells {
                // **fett** der KI stoert in der Zelle
                plan.cells[SheetRef(col: c, row: row)] = String(v.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "").prefix(Sheet.maxCellLength))
            }
            row += 1
        }
        return row >= 2 && !plan.cells.isEmpty ? plan : nil
    }

    // MARK: Einsetzen

    public struct Outcome: Equatable, Sendable {
        public var cells = 0
        public var charts = 0
        /// Formeln der KI, die einen Fehler zeigen (unbekannte Funktion, rechnet mit sich selbst, zeigt ins Leere)
        public var broken = 0
        /// Die Tabelle wurde vorher geleert: so viele Zellen standen darin
        public var cleared = 0
        /// Zellen der Antwort, die nicht hineinpassten
        public var dropped = 0
        /// Bereich, den die neuen Zellen fuellen
        public var filled: SheetRange?
        public init() {}

        /// Ein Satz fuer den Nutzer
        public var summary: String {
            var parts: [String] = []
            if cells > 0 { parts.append(cells == 1 ? "1 Zelle gefüllt" : "\(cells) Zellen gefüllt") }
            if charts > 0 { parts.append(charts == 1 ? "1 Diagramm angelegt" : "\(charts) Diagramme angelegt") }
            var s = parts.isEmpty ? "Die KI hat nichts geändert." : "Die KI hat " + parts.joined(separator: " und ") + "."
            if cleared > 0 { s += " Der alte Inhalt wurde dafür ersetzt." }
            if dropped > 0 { s += dropped == 1 ? " Eine Zelle passte nicht mehr in die Tabelle." : " \(dropped) Zellen passten nicht mehr in die Tabelle." }
            if broken > 0 { s += broken == 1 ? " Eine Formel muss noch geprüft werden." : " \(broken) Formeln müssen noch geprüft werden." }
            return s
        }
    }

    /// Bauplan einsetzen. `origin`: Stelle fuer Antworten ohne Zellnamen (`relative`), wenn die Tabelle schon gefuellt ist.
    @discardableResult
    public static func apply(_ plan: Plan, to s: inout Sheet, at origin: SheetRef) -> Outcome {
        var out = Outcome()
        out.dropped = plan.dropped
        let wasEmpty = s.cells.isEmpty
        if plan.replace, !plan.cells.isEmpty {
            out.cleared = s.cells.count
            s.cells = [:]
            s.styles = [:]
            s.filters = [:]
            s.charts = []
        }
        let shift = plan.relative && out.cleared == 0 && !wasEmpty ? origin : SheetRef(col: 0, row: 0)
        var lo: SheetRef?, hi: SheetRef?
        var placed: [SheetRef] = []
        for (r, text) in plan.cells {
            let to = SheetRef(col: r.col + shift.col, row: r.row + shift.row)
            guard to.col >= 0, to.row >= 0, to.col < max(growCols, s.cols), to.row < max(growRows, s.rows),
                  to.col < Sheet.maxCols, to.row < Sheet.maxRows else { out.dropped += 1; continue }
            // "" raeumt eine Zelle leer und zaehlt nicht als gefuellt
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { if s.contains(to) { s.cells[to] = nil }; continue }
            s.rows = max(s.rows, to.row + 1)
            s.cols = max(s.cols, to.col + 1)
            // eine Formel aus einer Antwort ohne Zellnamen wandert mit an die Stelle
            s.set(shift == SheetRef(col: 0, row: 0) ? text : SheetFormula.shifted(text, dCol: shift.col, dRow: shift.row), at: to)
            placed.append(to)
            lo = SheetRef(col: min(lo?.col ?? to.col, to.col), row: min(lo?.row ?? to.row, to.row))
            hi = SheetRef(col: max(hi?.col ?? to.col, to.col), row: max(hi?.row ?? to.row, to.row))
        }
        out.cells = placed.count
        if let lo, let hi { out.filled = SheetRange(lo, hi) }
        for c in plan.charts where s.charts.count < SheetChart.maxPerSheet {
            // ein Bereich neben der Tabelle ergaebe ein Diagramm ueber fremde Zellen: weglassen
            guard let range = s.intersection(SheetRange(SheetRef(col: c.range.from.col + shift.col, row: c.range.from.row + shift.row),
                                                        SheetRef(col: c.range.to.col + shift.col, row: c.range.to.row + shift.row))) else { continue }
            let id = "ki" + String(UInt64.random(in: 0...UInt64.max), radix: 36)
            s.charts.append(SheetChart(id: id, kind: c.kind, range: range, title: c.title))
            out.charts += 1
        }
        if out.charts > 0, s.show == "table" { s.show = "both" }
        let calc = s.calc()
        let own: Set<SheetError> = [.name, .syntax, .cycle, .ref]
        out.broken = placed.filter { SheetFormula.isFormula(s.raw($0)) && calc.value($0).error.map(own.contains) == true }.count
        return out
    }
}
