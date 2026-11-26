import Foundation

/// Tabelle ("sehr gutes Excel", Auftrag des Inhabers 25.11.2026; Antworten 26.11.2026: als Kasten auf der Seite UND als
/// eigene Datei, mit Formeln, Sortieren/Filtern, Diagrammen, Farben und Rahmen; keine .xlsx-Dateien).
///
/// Speicherformat: Eine Tabelle ist ein Objekt `type: "text"` des gemeinsamen Notizformats mit dem Zusatzfeld `sheet`
/// (kein neuer Objekttyp: die Community lehnt unbekannte Typen ab, `SolutionValidator`). `text` traegt die Werte als
/// Ersatztext (Zeilen, Spalten mit Tabulator) - aeltere Apps, Web und Windows zeigen die Zahlen als Text. `width` ist
/// die Breite auf der Seite; der Massstab ist `width` / natuerliche Breite der Tabelle.
///
/// `sheet`: `{v, rows, cols, cells: {"A1": "roh"}, fmt: {"A1": {...}}, cw: {"0": 120}, rh: {...}, head, flt, charts,
/// show, doc}`. In `cells` steht, was getippt wurde (`=SUMME(A1:A3)`, `12,5`); gerechnet wird beim Anzeigen.
public struct Sheet: Equatable, Sendable {
    public static let maxRows = 500
    public static let maxCols = 52
    public static let defaultColWidth = 84.0
    public static let defaultRowHeight = 24.0
    public static let colWidthRange = 28.0...400.0
    public static let rowHeightRange = 18.0...200.0
    /// Schrift in Tabellen-Punkten (bei Massstab 1 = Punkte der Seite)
    public static let fontSize = 12.0
    public static let cellPadding = 5.0
    /// Abstand zwischen Tabelle und Diagramm im Kasten
    public static let gap = 10.0
    /// Hoechstlaenge einer Zelle (Zeichen)
    public static let maxCellLength = 2_000

    public var rows: Int
    public var cols: Int
    /// Was getippt wurde, je Zelle (leere Zellen fehlen)
    public var cells: [SheetRef: String] = [:]
    public var styles: [SheetRef: SheetStyle] = [:]
    public var colWidths: [Int: Double] = [:]
    public var rowHeights: [Int: Double] = [:]
    /// Die erste Zeile ist die Kopfzeile: bleibt beim Sortieren oben, wird nie weggefiltert
    public var header = true
    /// Filter: Spalte → Werte (wie angezeigt), deren Zeilen versteckt sind
    public var filters: [Int: Set<String>] = [:]
    public var charts: [SheetChart] = []
    /// Was der Kasten auf der Seite zeigt: "both", "table", "chart"
    public var show = "both"
    /// Tabelle als eigene Datei: oeffnet sich beim Oeffnen des Dokuments gleich gross
    public var isDocument = false

    public init(rows: Int = 6, cols: Int = 4) {
        self.rows = min(Sheet.maxRows, max(1, rows))
        self.cols = min(Sheet.maxCols, max(1, cols))
    }

    // MARK: Zellen

    public func contains(_ r: SheetRef) -> Bool { r.row >= 0 && r.col >= 0 && r.row < rows && r.col < cols }
    public var bounds: SheetRange { SheetRange(SheetRef(col: 0, row: 0), SheetRef(col: cols - 1, row: rows - 1)) }

    public func clamped(_ r: SheetRange) -> SheetRange {
        SheetRange(SheetRef(col: min(cols - 1, max(0, r.from.col)), row: min(rows - 1, max(0, r.from.row))),
                   SheetRef(col: min(cols - 1, max(0, r.to.col)), row: min(rows - 1, max(0, r.to.row))))
    }

    /// Der Teil des Bereichs, der in der Tabelle liegt (nil: liegt ganz daneben)
    public func intersection(_ r: SheetRange) -> SheetRange? {
        guard r.from.col < cols, r.from.row < rows, r.to.col >= 0, r.to.row >= 0 else { return nil }
        return clamped(r)
    }

    public func raw(_ r: SheetRef) -> String { cells[r] ?? "" }
    public func style(_ r: SheetRef) -> SheetStyle { styles[r] ?? SheetStyle() }

    /// Zelle setzen, wie getippt. "50 %" und "3,20 €" merken sich das Format, wenn die Zelle noch keins hat.
    public mutating func set(_ input: String, at r: SheetRef) {
        guard contains(r) else { return }
        let text = String(input.prefix(Sheet.maxCellLength))
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { cells[r] = nil; return }
        cells[r] = text
        guard !SheetFormula.isFormula(text), let n = SheetText.parseNumber(text) else { return }
        var s = style(r)
        if let hint = n.hint {
            // "50 %" oder "3,20 €" getippt: Das Format folgt - auch wenn die Zelle vorher das andere hatte
            guard s.format == nil || (s.format != hint && (s.format == "p" || s.format == "e")) else { return }
            let switched = s.format != nil
            s.format = hint
            if hint == "p", s.decimals == nil || switched { s.decimals = Sheet.percentDecimals(text) }
            if hint == "e", switched { s.decimals = nil }
            styles[r] = s
        } else if s.format == "p", abs(n.value) >= 1, !text.hasPrefix("'") {
            // in eine Prozent-Zelle "7" getippt meint 7 % (wie in Excel), nicht 700 %
            cells[r] = text.trimmingCharacters(in: .whitespaces) + " %"
        }
    }

    /// "12,5 %" → 1 Nachkommastelle
    static func percentDecimals(_ text: String) -> Int {
        let t = text.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
        guard let i = t.lastIndex(where: { $0 == "," || $0 == "." }) else { return 0 }
        return min(6, t.distance(from: i, to: t.endIndex) - 1)
    }

    public mutating func setStyle(_ s: SheetStyle, at r: SheetRef) {
        guard contains(r) else { return }
        styles[r] = s.isDefault ? nil : s
    }

    public mutating func restyle(_ range: SheetRange, _ change: (inout SheetStyle) -> Void) {
        guard let g = intersection(range) else { return }
        for r in g.refs {
            var s = style(r)
            change(&s)
            setStyle(s, at: r)
        }
    }

    /// Rahmen: "outer" um den Bereich, "all" jede Zelle, "bottom" Linie darunter, "none" weg
    public mutating func setBorder(_ range: SheetRange, _ mode: String) {
        guard let g = intersection(range) else { return }
        for r in g.refs {
            var s = style(r)
            switch mode {
            case "all": s.border = 15
            case "none": s.border = 0
            case "bottom": if r.row == g.to.row { s.border |= 4 }
            default:
                if r.row == g.from.row { s.border |= 1 }
                if r.col == g.to.col { s.border |= 2 }
                if r.row == g.to.row { s.border |= 4 }
                if r.col == g.from.col { s.border |= 8 }
            }
            setStyle(s, at: r)
        }
    }

    public mutating func clear(_ range: SheetRange, styles alsoStyles: Bool = false) {
        guard let g = intersection(range) else { return }
        for r in g.refs {
            cells[r] = nil
            if alsoStyles { styles[r] = nil }
        }
    }

    /// Kleinster Bereich, der alle gefuellten Zellen fasst (nil: leer)
    public var usedRange: SheetRange? {
        guard let first = cells.keys.first else { return nil }
        var lo = first, hi = first
        for r in cells.keys {
            lo = SheetRef(col: min(lo.col, r.col), row: min(lo.row, r.row))
            hi = SheetRef(col: max(hi.col, r.col), row: max(hi.row, r.row))
        }
        return SheetRange(lo, hi)
    }

    // MARK: Groessen

    public func width(_ col: Int) -> Double { colWidths[col] ?? Sheet.defaultColWidth }
    public func height(_ row: Int) -> Double { rowHeights[row] ?? Sheet.defaultRowHeight }

    public mutating func setWidth(_ w: Double, col: Int) {
        guard col >= 0, col < cols, w.isFinite else { return }
        let v = min(Sheet.colWidthRange.upperBound, max(Sheet.colWidthRange.lowerBound, w.rounded()))
        colWidths[col] = v == Sheet.defaultColWidth ? nil : v
    }

    public mutating func setHeight(_ h: Double, row: Int) {
        guard row >= 0, row < rows, h.isFinite else { return }
        let v = min(Sheet.rowHeightRange.upperBound, max(Sheet.rowHeightRange.lowerBound, h.rounded()))
        rowHeights[row] = v == Sheet.defaultRowHeight ? nil : v
    }

    public var tableWidth: Double { (0..<cols).reduce(0) { $0 + width($1) } }

    public func tableHeight(hidden: Set<Int> = []) -> Double {
        (0..<rows).reduce(0) { $0 + (hidden.contains($1) ? 0 : height($1)) }
    }

    // MARK: Zeilen und Spalten

    private mutating func remap(rows byRows: Bool, at index: Int, count: Int) {
        func moved(_ r: SheetRef) -> SheetRef? {
            let v = byRows ? r.row : r.col
            var n = v
            if count > 0 { if v >= index { n = v + count } }
            else {
                if v >= index, v < index - count { return nil }
                if v >= index - count { n = v + count }
            }
            return byRows ? SheetRef(col: r.col, row: n) : SheetRef(col: n, row: r.row)
        }
        func movedIndex(_ v: Int) -> Int? {
            if count > 0 { return v >= index ? v + count : v }
            if v >= index, v < index - count { return nil }
            return v >= index - count ? v + count : v
        }
        var newCells: [SheetRef: String] = [:]
        for (r, raw) in cells {
            guard let n = moved(r) else { continue }
            newCells[n] = SheetFormula.adjusted(raw, rows: byRows, at: index, count: count)
        }
        cells = newCells
        var newStyles: [SheetRef: SheetStyle] = [:]
        for (r, s) in styles { if let n = moved(r) { newStyles[n] = s } }
        styles = newStyles
        if byRows {
            rowHeights = Dictionary(uniqueKeysWithValues: rowHeights.compactMap { k, v in movedIndex(k).map { ($0, v) } })
        } else {
            colWidths = Dictionary(uniqueKeysWithValues: colWidths.compactMap { k, v in movedIndex(k).map { ($0, v) } })
            filters = Dictionary(uniqueKeysWithValues: filters.compactMap { k, v in movedIndex(k).map { ($0, v) } })
        }
        charts = charts.compactMap { ch in
            guard let r = SheetRange(SheetFormula.adjusted("=" + ch.range.name, rows: byRows, at: index, count: count).dropFirst().description) else { return nil }
            var c = ch
            c.range = r
            return c
        }
    }

    /// Leere Zeilen einfuegen (vor `index`); Formeln zeigen danach auf dieselben Zellen wie vorher
    public mutating func insertRows(at index: Int, count: Int = 1) {
        let n = min(count, Sheet.maxRows - rows)
        guard n > 0, index >= 0, index <= rows else { return }
        remap(rows: true, at: index, count: n)
        rows += n
    }

    public mutating func deleteRows(at index: Int, count: Int = 1) {
        let n = min(count, rows - index, rows - 1)
        guard n > 0, index >= 0, index < rows else { return }
        remap(rows: true, at: index, count: -n)
        rows -= n
    }

    public mutating func insertCols(at index: Int, count: Int = 1) {
        let n = min(count, Sheet.maxCols - cols)
        guard n > 0, index >= 0, index <= cols else { return }
        remap(rows: false, at: index, count: n)
        cols += n
    }

    public mutating func deleteCols(at index: Int, count: Int = 1) {
        let n = min(count, cols - index, cols - 1)
        guard n > 0, index >= 0, index < cols else { return }
        remap(rows: false, at: index, count: -n)
        cols -= n
    }

    // MARK: Kopieren

    /// Ausschnitt zum Einfuegen an anderer Stelle
    public struct Block: Equatable, Sendable {
        public var origin: SheetRef
        public var rows: Int
        public var cols: Int
        public var cells: [SheetRef: String]      // Lage im Ausschnitt (ab 0/0)
        public var styles: [SheetRef: SheetStyle]

        public init(origin: SheetRef, rows: Int, cols: Int, cells: [SheetRef: String] = [:], styles: [SheetRef: SheetStyle] = [:]) {
            self.origin = origin
            self.rows = rows
            self.cols = cols
            self.cells = cells
            self.styles = styles
        }

        /// Werte mit Tabulator und Zeilenumbruch (Zwischenablage fuer andere Apps)
        public func plainText(_ value: (SheetRef) -> String) -> String {
            (0..<rows).map { r in (0..<cols).map { c in value(SheetRef(col: origin.col + c, row: origin.row + r)) }.joined(separator: "\t") }
                .joined(separator: "\n")
        }
    }

    public func block(_ range: SheetRange) -> Block {
        let g = clamped(range)
        var b = Block(origin: g.from, rows: g.rows.count, cols: g.cols.count, cells: [:], styles: [:])
        for r in g.refs {
            let k = SheetRef(col: r.col - g.from.col, row: r.row - g.from.row)
            if let raw = cells[r] { b.cells[k] = raw }
            if let s = styles[r] { b.styles[k] = s }
        }
        return b
    }

    /// Ausschnitt einsetzen; Formeln wandern mit (`=A1*2` zwei Zeilen tiefer wird `=A3*2`) - ausser nach dem
    /// Ausschneiden (`shiftingReferences: false`): Dann zeigt die Formel weiter auf dieselben Zellen. Die Tabelle
    /// waechst, wenn der Ausschnitt ueber den Rand reicht. Liefert den gefuellten Bereich.
    @discardableResult
    public mutating func paste(_ b: Block, at target: SheetRef, shiftingReferences: Bool = true) -> SheetRange {
        guard target.col >= 0, target.row >= 0, target.col < Sheet.maxCols, target.row < Sheet.maxRows else { return SheetRange(target) }
        rows = max(rows, min(Sheet.maxRows, target.row + b.rows))
        cols = max(cols, min(Sheet.maxCols, target.col + b.cols))
        let dCol = shiftingReferences ? target.col - b.origin.col : 0, dRow = shiftingReferences ? target.row - b.origin.row : 0
        for r in 0..<b.rows {
            for c in 0..<b.cols {
                let k = SheetRef(col: c, row: r), to = SheetRef(col: target.col + c, row: target.row + r)
                guard contains(to) else { continue }
                cells[to] = b.cells[k].map { SheetFormula.shifted($0, dCol: dCol, dRow: dRow) }
                styles[to] = b.styles[k]
            }
        }
        return clamped(SheetRange(target, SheetRef(col: target.col + b.cols - 1, row: target.row + b.rows - 1)))
    }

    /// Text aus einer anderen App (Tabulator / Zeilenumbruch) ab `target` einsetzen; die Tabelle waechst bei Bedarf
    @discardableResult
    public mutating func pasteText(_ text: String, at target: SheetRef) -> SheetRange {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        var trimmed = lines
        while let l = trimmed.last, l.allSatisfy({ $0.isEmpty }) { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return SheetRange(target) }
        let h = min(trimmed.count, Sheet.maxRows - target.row), w = min(trimmed.map(\.count).max() ?? 1, Sheet.maxCols - target.col)
        guard h > 0, w > 0 else { return SheetRange(target) }
        rows = max(rows, target.row + h)
        cols = max(cols, target.col + w)
        for (r, line) in trimmed.prefix(h).enumerated() {
            for (c, v) in line.prefix(w).enumerated() { set(v, at: SheetRef(col: target.col + c, row: target.row + r)) }
        }
        return SheetRange(target, SheetRef(col: target.col + w - 1, row: target.row + h - 1))
    }

    /// Erste Zeile des Bereichs nach unten ausfuellen
    public mutating func fillDown(_ range: SheetRange) {
        let g = clamped(range)
        guard g.rows.count > 1 else { return }
        let top = block(SheetRange(g.from, SheetRef(col: g.to.col, row: g.from.row)))
        for r in (g.from.row + 1)...g.to.row { paste(top, at: SheetRef(col: g.from.col, row: r)) }
    }

    // MARK: Rechnen und Anzeigen

    public func calc() -> SheetCalc { SheetCalc(self) }

    /// Wie die Zelle aussieht: Text und ob er rechts steht (Zahlen)
    public func display(_ r: SheetRef, _ calc: SheetCalc) -> String {
        let v = calc.value(r), s = style(r)
        guard case .number(let d) = v else { return SheetText.text(v) }
        switch s.format {
        case "p": return SheetText.fixed(d * 100, decimals: s.decimals ?? 0) + " %"
        case "e": return SheetText.fixed(d, decimals: s.decimals ?? 2) + " €"
        case "n": return SheetText.fixed(d, decimals: s.decimals ?? 2)
        default:
            if let n = s.decimals { return SheetText.fixed(d, decimals: n) }
            // "14.30" oder "1E3" getippt: so stehen lassen (gerechnet wird mit der Zahl)
            if let raw = cells[r], !SheetFormula.isFormula(raw), SheetText.keepsTyped(raw) { return raw.trimmingCharacters(in: .whitespaces) }
            return SheetText.general(d)
        }
    }

    /// "l", "c" oder "r": gesetzt oder nach Inhalt (Zahlen rechts, Wahrheitswerte und Fehler mittig)
    public func alignment(_ r: SheetRef, _ calc: SheetCalc) -> String {
        if let a = style(r).align { return a }
        switch calc.value(r) {
        case .number: return "r"
        case .bool, .error: return "c"
        default: return "l"
        }
    }

    // MARK: Sortieren und Filtern

    /// Erste Zeile mit Daten (nach der Kopfzeile)
    public var firstDataRow: Int { header && rows > 1 ? 1 : 0 }

    /// Zeilen nach einer Spalte ordnen. Die Kopfzeile bleibt; leere Zellen stehen immer unten; gleiche Werte behalten
    /// ihre Reihenfolge. Formeln, die auf die eigene Zeile zeigen, gehen mit.
    public mutating func sort(byCol col: Int, ascending: Bool) {
        guard col >= 0, col < cols, let used = usedRange, used.to.row >= firstDataRow else { return }
        let c = calc()
        // Zeilen am Ende, die ueber die Zeilen darueber rechnen ("Summe", "Schnitt"), bleiben unten stehen
        // (hoechstens drei; rechnet jede Zeile so, sind es Daten)
        var last = used.to.row, kept = 0
        while last > firstDataRow, let kind = summaryRow(last, over: firstDataRow..<last) {
            if kind == .formula { kept += 1 }
            last -= 1
        }
        if kept > 3 { last = used.to.row }
        let range = firstDataRow...last
        let keyed = range.map { (row: $0, value: c.value(SheetRef(col: col, row: $0))) }
        let order = keyed.enumerated().sorted { a, b in
            let x = a.element.value, y = b.element.value
            if x.isEmpty != y.isEmpty { return y.isEmpty }
            let cmp = SheetFormula.Evaluator.compare(x, y)
            if cmp != 0 { return ascending ? cmp < 0 : cmp > 0 }
            return a.offset < b.offset
        }.map(\.element.row)
        guard order != Array(range) else { return }
        var newCells = cells.filter { !range.contains($0.key.row) }
        var newStyles = styles.filter { !range.contains($0.key.row) }
        var newHeights = rowHeights.filter { !range.contains($0.key) }
        for (i, from) in order.enumerated() {
            let to = range.lowerBound + i
            for col in 0..<cols {
                let src = SheetRef(col: col, row: from), dst = SheetRef(col: col, row: to)
                if let raw = cells[src] { newCells[dst] = SheetFormula.movedRow(raw, from: from, to: to) }
                if let s = styles[src] { newStyles[dst] = s }
            }
            if let h = rowHeights[from] { newHeights[to] = h }
        }
        cells = newCells
        styles = newStyles
        rowHeights = newHeights
    }

    enum SummaryKind { case blank, formula }

    /// Leere Zeile oder eine, in der eine Formel einen Bereich ueber mehrere der Zeilen `data` zusammenfasst
    func summaryRow(_ row: Int, over data: Range<Int>) -> SummaryKind? {
        var empty = true, summary = false
        for col in 0..<cols {
            guard let raw = cells[SheetRef(col: col, row: row)] else { continue }
            empty = false
            if SheetFormula.isFormula(raw), SheetFormula.references(raw).contains(where: {
                $0.rows.count > 1 && $0.rows.lowerBound < data.upperBound && $0.rows.upperBound >= data.lowerBound && !$0.rows.contains(row)
            }) { summary = true }
        }
        return empty ? .blank : (summary ? .formula : nil)
    }

    /// Verschiedene Werte einer Spalte (wie angezeigt, ohne Kopfzeile), fuer die Auswahl im Filter; "" = leer
    public func filterValues(col: Int, _ calc: SheetCalc) -> [String] {
        guard let used = usedRange, used.to.row >= firstDataRow else { return [] }
        var seen = Set<String>(), out: [(String, SheetValue)] = []
        for row in firstDataRow...used.to.row {
            let r = SheetRef(col: col, row: row)
            let s = display(r, calc)
            if seen.insert(s).inserted { out.append((s, calc.value(r))) }
        }
        return out.sorted { a, b in
            if a.1.isEmpty != b.1.isEmpty { return b.1.isEmpty }
            return SheetFormula.Evaluator.compare(a.1, b.1) < 0
        }.map(\.0)
    }

    /// Zeilen, die ein Filter gerade versteckt
    public func hiddenRows(_ calc: SheetCalc) -> Set<Int> {
        let active = filters.filter { !$0.value.isEmpty && $0.key < cols }
        guard !active.isEmpty, rows > firstDataRow else { return [] }
        var out = Set<Int>()
        for row in firstDataRow..<rows {
            for (col, hide) in active where hide.contains(display(SheetRef(col: col, row: row), calc)) { out.insert(row); break }
        }
        return out
    }

    // MARK: Ersatztext

    /// Werte als Text fuer aeltere Apps, Web und Windows: Zeilen untereinander, Spalten mit Tabulator
    public func fallbackText(_ calc: SheetCalc) -> String {
        guard let used = usedRange else { return "" }
        let hidden = hiddenRows(calc)
        return (0...used.to.row).filter { !hidden.contains($0) }.map { row in
            var line = (0...used.to.col).map { display(SheetRef(col: $0, row: row), calc).replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
            while let l = line.last, l.isEmpty, line.count > 1 { line.removeLast() }
            return line.joined(separator: "\t")
        }.joined(separator: "\n")
    }
}

// MARK: - Aussehen einer Zelle

public struct SheetStyle: Equatable, Sendable {
    public var bold = false
    public var italic = false
    /// Textfarbe (`#rrggbb`), nil: schwarz
    public var color: String?
    /// Zellfarbe, nil: keine
    public var fill: String?
    /// "l", "c", "r"; nil: nach Inhalt
    public var align: String?
    /// "n" Zahl, "p" Prozent, "e" Euro, "t" Text; nil: automatisch
    public var format: String?
    public var decimals: Int?
    /// Rahmen als Bits: 1 oben, 2 rechts, 4 unten, 8 links
    public var border = 0

    public init() {}

    public var isDefault: Bool { self == SheetStyle() }

    public static let textColors = ["#1a1a1a", "#d7263d", "#2f7fd1", "#2e9e5b", "#e08a00", "#7c3aed", "#7a8199"]
    public static let fillColors = ["#fff7a8", "#ffd3e0", "#d6f5c8", "#cfe8ff", "#ffe2b8", "#e7dbff", "#eceef2"]

    static func hex(_ v: JSONValue?) -> String? {
        guard let s = v?.string, s.count == 7, s.hasPrefix("#"), s.dropFirst().allSatisfy({ $0.isHexDigit }) else { return nil }
        return s.lowercased()
    }

    public init(json o: JSONValue) {
        bold = o["b"]?.double == 1
        italic = o["i"]?.double == 1
        color = SheetStyle.hex(o["c"])
        fill = SheetStyle.hex(o["bg"])
        if let a = o["al"]?.string, ["l", "c", "r"].contains(a) { align = a }
        if let f = o["nf"]?.string, ["n", "p", "e", "t"].contains(f) { format = f }
        if let d = o["dp"]?.int, (0...6).contains(d) { decimals = d }
        if let b = o["bd"]?.int, (0...15).contains(b) { border = b }
    }

    public var json: JSONValue {
        var o: [String: JSONValue] = [:]
        if bold { o["b"] = 1 }
        if italic { o["i"] = 1 }
        if let color { o["c"] = .string(color) }
        if let fill { o["bg"] = .string(fill) }
        if let align { o["al"] = .string(align) }
        if let format { o["nf"] = .string(format) }
        if let decimals { o["dp"] = .number(Double(decimals)) }
        if border != 0 { o["bd"] = .number(Double(border)) }
        return .object(o)
    }
}

// MARK: - Rechnen

/// Rechnet eine Tabelle einmal durch und merkt sich die Ergebnisse (eine Instanz je Stand der Tabelle).
///
/// Formeln, die aufeinander aufbauen (laufende Summe ueber 500 Zeilen), werden der Reihe nach gerechnet - nicht eine in
/// der anderen: Bevor eine Formel dran ist, sind alle Zellen fertig, die sie liest (`settle`, eigener Stapel statt
/// Aufrufe ineinander; der Stapel des Programms ist am iPad klein). Rechnet eine Formel mit sich selbst, auch ueber
/// Umwege, zeigt sie `#ZIRKEL!`.
public final class SheetCalc {
    private let sheet: Sheet
    private var memo: [SheetRef: SheetValue] = [:]
    private var visiting = Set<SheetRef>()
    /// Wie oft eine Formel beim Rechnen auf eine Zelle traf, die selbst noch in Arbeit ist
    private var cycleHits = 0
    private lazy var formulas: Set<SheetRef> = Set(sheet.cells.lazy.filter { SheetFormula.isFormula($0.value) }.map(\.key))

    public init(_ sheet: Sheet) { self.sheet = sheet }

    /// Getippter Wert ohne Formel: Zahl, Wahrheitswert oder Text (`'12` bleibt Text)
    public static func literal(_ raw: String, asText: Bool = false) -> SheetValue {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return .empty }
        if t.hasPrefix("'") { return .text(String(t.dropFirst())) }
        if asText { return .text(raw) }
        if let n = SheetText.parseNumber(t) { return .number(n.value) }
        switch t.uppercased() {
        case "WAHR", "TRUE": return .bool(true)
        case "FALSCH", "FALSE": return .bool(false)
        default: return .text(raw)
        }
    }

    public func value(_ r: SheetRef) -> SheetValue {
        if let v = memo[r] { return v }
        guard sheet.contains(r), let raw = sheet.cells[r] else { return .empty }
        guard SheetFormula.isFormula(raw) else {
            let v = SheetCalc.literal(raw, asText: sheet.styles[r]?.format == "t")
            memo[r] = v
            return v
        }
        if visiting.contains(r) { cycleHits += 1; return .error(.cycle) }
        return settle(r)
    }

    private struct Job {
        let ref: SheetRef
        let node: SheetFormula.Node?
        let error: SheetError?
        /// Formel-Zellen, die diese Formel liest
        let needs: [SheetRef]
        var next = 0
    }

    private func job(_ r: SheetRef) -> Job {
        switch SheetFormula.parse(sheet.cells[r] ?? "") {
        case .failure(let f): return Job(ref: r, node: nil, error: f.error, needs: [])
        case .success(let node):
            var needs: [SheetRef] = []
            SheetFormula.ranges(in: node) { range in
                guard let g = sheet.intersection(range) else { return }
                if g.count <= formulas.count { for x in g.refs where formulas.contains(x) { needs.append(x) } }
                else { for x in formulas where g.contains(x) { needs.append(x) } }
            }
            return Job(ref: r, node: node, error: nil, needs: needs)
        }
    }

    /// Eine Formel-Zelle fertig rechnen: erst alles, was sie liest (und was das liest ...), dann sie selbst
    private func settle(_ start: SheetRef) -> SheetValue {
        var stack = [job(start)]
        visiting.insert(start)
        while var top = stack.last {
            var waits = false
            while top.next < top.needs.count {
                let d = top.needs[top.next]
                top.next += 1
                // schon fertig; oder selbst gerade in Arbeit: ein Kreis, die Formel bekommt beim Lesen #ZIRKEL!
                guard memo[d] == nil, !visiting.contains(d) else { continue }
                stack[stack.count - 1] = top
                stack.append(job(d))
                visiting.insert(d)
                waits = true
                break
            }
            if waits { continue }
            var v: SheetValue
            if let node = top.node {
                let before = cycleHits
                let result = SheetFormula.Evaluator(cell: { [unowned self] in self.value($0) }).value(node)
                // eine Formel, die auf eine leere Zelle zeigt, ergibt 0 (wie in Excel)
                v = result.isEmpty ? .number(0) : result
                // auch wenn WENNFEHLER den Kreis abfaengt: Die Formel rechnet mit sich selbst
                if cycleHits != before { v = .error(.cycle) }
            } else {
                v = .error(top.error ?? .syntax)
            }
            visiting.remove(top.ref)
            memo[top.ref] = v
            stack.removeLast()
        }
        return memo[start] ?? .error(.cycle)
    }
}

// MARK: - Speichern

extension Sheet {
    public init?(json o: JSONValue?) {
        guard let o, o.object != nil, let rows = o["rows"]?.int, let cols = o["cols"]?.int, rows >= 1, cols >= 1 else { return nil }
        self.init(rows: rows, cols: cols)
        for (k, v) in o["cells"]?.object ?? [:] {
            guard let r = SheetRef(k), contains(r), let s = v.string, !s.isEmpty else { continue }
            cells[r] = String(s.prefix(Sheet.maxCellLength))
        }
        for (k, v) in o["fmt"]?.object ?? [:] {
            guard let r = SheetRef(k), contains(r) else { continue }
            let s = SheetStyle(json: v)
            if !s.isDefault { styles[r] = s }
        }
        for (k, v) in o["cw"]?.object ?? [:] { if let i = Int(k), let w = v.double { setWidth(w, col: i) } }
        for (k, v) in o["rh"]?.object ?? [:] { if let i = Int(k), let h = v.double { setHeight(h, row: i) } }
        header = o["head"]?.double != 0
        for (k, v) in o["flt"]?.object ?? [:] {
            guard let i = Int(k), i >= 0, i < self.cols, let a = v.array else { continue }
            let set = Set(a.compactMap(\.string))
            if !set.isEmpty { filters[i] = set }
        }
        charts = (o["charts"]?.array ?? []).prefix(SheetChart.maxPerSheet).compactMap(SheetChart.init(json:))
        if let s = o["show"]?.string, ["both", "table", "chart"].contains(s) { show = s }
        isDocument = o["doc"]?.double == 1
    }

    public var json: JSONValue {
        var o: [String: JSONValue] = ["v": 1, "rows": .number(Double(rows)), "cols": .number(Double(cols))]
        o["cells"] = .object(Dictionary(uniqueKeysWithValues: cells.filter { contains($0.key) }.map { ($0.key.name, JSONValue.string($0.value)) }))
        let fmt = styles.filter { contains($0.key) && !$0.value.isDefault }
        if !fmt.isEmpty { o["fmt"] = .object(Dictionary(uniqueKeysWithValues: fmt.map { ($0.key.name, $0.value.json) })) }
        if !colWidths.isEmpty { o["cw"] = .object(Dictionary(uniqueKeysWithValues: colWidths.map { ("\($0.key)", JSONValue.number($0.value)) })) }
        if !rowHeights.isEmpty { o["rh"] = .object(Dictionary(uniqueKeysWithValues: rowHeights.map { ("\($0.key)", JSONValue.number($0.value)) })) }
        if !header { o["head"] = 0 }
        let flt = filters.filter { !$0.value.isEmpty }
        if !flt.isEmpty { o["flt"] = .object(Dictionary(uniqueKeysWithValues: flt.map { ("\($0.key)", JSONValue.array($0.value.sorted().map(JSONValue.string))) })) }
        if !charts.isEmpty { o["charts"] = .array(charts.map(\.json)) }
        if show != "both" { o["show"] = .string(show) }
        if isDocument { o["doc"] = 1 }
        return .object(o)
    }
}

// MARK: - Tabelle als Objekt der Seite

public enum SheetObject {
    /// Schmalste und breiteste Tabelle auf der Seite (Punkte)
    public static let widthRange = 60.0...4_000.0

    public static func isSheet(_ o: JSONValue) -> Bool { o["type"]?.string == "text" && o["sheet"]?.object != nil }

    public static func sheet(_ o: JSONValue) -> Sheet? { isSheet(o) ? Sheet(json: o["sheet"]) : nil }

    /// Was der Kasten zeigt
    public struct Layout: Equatable, Sendable {
        public var showsTable: Bool
        public var charts: [SheetChart]
        /// Natuerliche Groesse (Massstab 1)
        public var width: Double
        public var tableHeight: Double
        public var height: Double
        public var hidden: Set<Int>
    }

    public static func layout(_ s: Sheet, _ calc: SheetCalc) -> Layout {
        let charts = s.show == "table" ? [] : s.charts
        let showsTable = s.show != "chart" || charts.isEmpty
        let hidden = s.hiddenRows(calc)
        let tableHeight = showsTable ? s.tableHeight(hidden: hidden) : 0
        let width = max(showsTable ? s.tableWidth : 0, charts.isEmpty ? 0 : SheetChart.minWidth)
        var height = tableHeight
        for _ in charts { height += (height > 0 ? Sheet.gap : 0) + SheetChart.height }
        return Layout(showsTable: showsTable, charts: charts, width: max(1, width), tableHeight: tableHeight, height: max(1, height), hidden: hidden)
    }

    /// Massstab auf der Seite: `width` des Objekts / natuerliche Breite
    public static func scale(_ o: JSONValue, _ layout: Layout) -> Double {
        guard let w = o["width"]?.double, w.isFinite, w > 0 else { return 1 }
        return min(20, max(0.05, w / layout.width))
    }

    /// Natuerliche Groesse, wie `saving` sie ins Objekt geschrieben hat (`sheet.box`): Damit kostet die Frage nach der
    /// Groesse nichts - sie kommt bei jedem Antippen der Seite fuer jedes Objekt.
    static func storedBox(_ o: JSONValue) -> (width: Double, height: Double)? {
        guard let b = o["sheet"]?["box"]?.array, b.count == 2, let w = b[0].double, let h = b[1].double,
              w.isFinite, h.isFinite, w >= 1, h >= 1, w < 1e6, h < 1e6 else { return nil }
        return (w, h)
    }

    /// Groesse auf der Seite (Punkte)
    public static func size(_ o: JSONValue) -> (width: Double, height: Double)? {
        guard isSheet(o) else { return nil }
        if let box = storedBox(o) {
            guard let w = o["width"]?.double, w.isFinite, w > 0 else { return box }
            let k = min(20, max(0.05, w / box.width))
            return (box.width * k, box.height * k)
        }
        guard let s = sheet(o) else { return nil }
        let l = layout(s, s.calc()), k = scale(o, l)
        return (l.width * k, l.height * k)
    }

    /// Kleinster Massstab, auf den eine Tabelle von selbst schrumpft, damit sie auf die Seite passt (Schrift 5 pt)
    public static let minFitScale = 5.0 / Sheet.fontSize

    /// Tabelle auf der Seite halten, wenn sie gewachsen ist: erst nach links/oben ruecken, dann kleiner zeichnen (bis
    /// `minFitScale`). Was dann noch uebersteht, zeigt die grosse Ansicht.
    public static func fitted(_ o: JSONValue, page: (width: Double, height: Double), margin: Double = 8) -> JSONValue {
        guard var obj = o.object, let size = size(o), let x = o["x"]?.double, let y = o["y"]?.double,
              page.width.isFinite, page.height.isFinite, page.width > 4 * margin, page.height > 4 * margin else { return o }
        var w = size.width, h = size.height
        let roomW = page.width - 2 * margin, roomH = page.height - 2 * margin
        if w > roomW || h > roomH {
            let now = scaleFactor(o, size)
            let next = min(now, max(minFitScale, now * min(roomW / w, roomH / h)))
            w *= next / now
            h *= next / now
        }
        obj["width"] = .number(PageRotation.round2(max(widthRange.lowerBound, w)))
        if x + w > page.width - margin { obj["x"] = .number(PageRotation.round2(max(margin, page.width - margin - w))) }
        if y + h > page.height - margin { obj["y"] = .number(PageRotation.round2(max(margin, page.height - margin - h))) }
        return .object(obj)
    }

    /// Massstab eines Objekts aus seiner Groesse auf der Seite
    private static func scaleFactor(_ o: JSONValue, _ size: (width: Double, height: Double)) -> Double {
        guard let box = storedBox(o) else {
            guard let s = sheet(o) else { return 1 }
            return scale(o, layout(s, s.calc()))
        }
        return size.width / box.width
    }

    /// Neue Tabelle: linke obere Ecke am Tippunkt, ganz auf der Seite, wenn `page` bekannt ist
    public static func object(id: String, x: Double, y: Double, sheet: Sheet = Sheet(), page: (width: Double, height: Double)? = nil) -> JSONValue {
        let calc = sheet.calc(), l = layout(sheet, calc)
        var left = x, top = y, width = l.width
        if let page, page.width.isFinite, page.height.isFinite {
            width = min(width, max(widthRange.lowerBound, page.width - 24))
            let h = l.height * width / l.width
            left = min(max(0, left), max(0, page.width - width))
            top = min(max(0, top), max(0, page.height - h))
        }
        var o = PageObjectEdit.text(id: id, x: left, y: top).object ?? [:]
        o["fontSize"] = .number(Sheet.fontSize)
        o["width"] = .number(PageRotation.round2(width))
        return saving(sheet, in: .object(o), keepScale: false)
    }

    /// Tabelle ins Objekt schreiben: `sheet`, Ersatztext und Breite (der Massstab bleibt, auch wenn Spalten dazukommen)
    public static func saving(_ s: Sheet, in o: JSONValue, keepScale: Bool = true) -> JSONValue {
        guard o["type"]?.string == "text", var obj = o.object else { return o }
        let calc = s.calc(), l = layout(s, calc)
        if keepScale, isSheet(o), let now = size(o) {
            let k = scaleFactor(o, now)
            obj["width"] = .number(PageRotation.round2(min(widthRange.upperBound, max(widthRange.lowerBound, l.width * k))))
        } else if obj["width"]?.double == nil {
            obj["width"] = .number(PageRotation.round2(l.width))
        }
        var json = s.json.object ?? [:]
        json["box"] = .array([.number(PageRotation.round2(l.width)), .number(PageRotation.round2(l.height))])
        obj["sheet"] = .object(json)
        obj["text"] = .string(s.fallbackText(calc))
        // aeltere Apps: kleine Schrift, damit die Spalten des Ersatztexts halbwegs passen
        obj["fontSize"] = .number(Sheet.fontSize)
        return .object(obj)
    }
}
