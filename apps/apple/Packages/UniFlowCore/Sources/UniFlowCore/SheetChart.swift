import Foundation

/// Diagramm zu einer Tabelle (`Sheet.charts`): Balken, Linien oder Kreis aus einem Bereich. Gezeichnet wird in der App
/// selbst (CoreGraphics), damit Seite, PDF-Export und geteilte Loesungen dasselbe Bild zeigen - kein Fremdbaustein.
public struct SheetChart: Equatable, Sendable {
    public static let kinds: [(id: String, title: String)] = [("bar", "Balken"), ("line", "Linien"), ("pie", "Kreis")]
    public static let maxPerSheet = 6
    /// Groesse im Kasten (Tabellen-Punkte)
    public static let height = 190.0
    public static let minWidth = 300.0
    /// Farben der Reihen bzw. Kreisstuecke
    public static let palette = ["#2f7fd1", "#e08a00", "#2e9e5b", "#d7263d", "#7c3aed", "#0ea5a0", "#c2410c", "#7a8199"]
    public static let maxPoints = 60
    public static let maxSeries = 8

    public var id: String
    public var kind: String
    public var range: SheetRange
    public var title: String

    public init(id: String, kind: String = "bar", range: SheetRange, title: String = "") {
        self.id = id
        self.kind = SheetChart.kinds.contains { $0.id == kind } ? kind : "bar"
        self.range = range
        self.title = String(title.prefix(80))
    }

    public init?(json o: JSONValue) {
        guard let id = o["id"]?.string, !id.isEmpty, let r = o["range"]?.string.flatMap(SheetRange.init) else { return nil }
        self.init(id: String(id.prefix(40)), kind: o["kind"]?.string ?? "bar", range: r, title: o["title"]?.string ?? "")
    }

    public var json: JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "kind": .string(kind), "range": .string(range.name)]
        if !title.isEmpty { o["title"] = .string(title) }
        return .object(o)
    }

    /// Zahlen eines Diagramms
    public struct Content: Equatable, Sendable {
        public var categories: [String]
        public var series: [Series]
        public var isEmpty: Bool { !series.contains { $0.values.contains { $0 != nil } } }
        /// Kleinster und groesster Wert (immer mit der Null)
        public var bounds: (min: Double, max: Double) {
            let all = series.flatMap { $0.values.compactMap { $0 } }
            return (min(0, all.min() ?? 0), max(0, all.max() ?? 0))
        }
    }

    public struct Series: Equatable, Sendable {
        public var name: String
        public var values: [Double?]
    }

    /// Bereich lesen: Steht in der ersten Spalte Text, sind das die Beschriftungen; steht in der ersten Zeile Text, sind
    /// das die Namen der Reihen. Gefilterte Zeilen fehlen auch im Diagramm.
    public func content(_ sheet: Sheet, _ calc: SheetCalc) -> Content {
        let g = sheet.clamped(range)
        let hidden = sheet.hiddenRows(calc)
        let rows = g.rows.filter { !hidden.contains($0) }
        guard !rows.isEmpty else { return Content(categories: [], series: []) }
        func value(_ c: Int, _ r: Int) -> SheetValue { calc.value(SheetRef(col: c, row: r)) }
        func isLabel(_ v: SheetValue) -> Bool { if case .text = v { return true }; return false }
        let cols = Array(g.cols)
        let headerRow = rows.count > 1 && cols.contains { isLabel(value($0, rows[0])) } && !cols.contains { value($0, rows[0]).number != nil }
        let dataRows = Array((headerRow ? Array(rows.dropFirst()) : rows).prefix(SheetChart.maxPoints))
        // Beschriftung: Text in der ersten Spalte - oder eine Zaehlung (Semester 1, 2, 3; Jahre 2023, 2024, 2025)
        let firstNumbers = dataRows.map { value(cols[0], $0).number }
        var counting = false
        if cols.count > 1, firstNumbers.count >= 3, let a = firstNumbers[0], a == a.rounded() {
            counting = zip(firstNumbers, firstNumbers.dropFirst()).allSatisfy { x, y in x != nil && y != nil && y! - x! == 1 }
        }
        let labelCol = cols.count > 1 && (counting || (dataRows.contains { isLabel(value(cols[0], $0)) } && !dataRows.contains { value(cols[0], $0).number != nil }))
        let dataCols = Array((labelCol ? Array(cols.dropFirst()) : cols).prefix(SheetChart.maxSeries))
        let categories = dataRows.map { r in labelCol ? sheet.display(SheetRef(col: cols[0], row: r), calc) : "\(r + 1)" }
        let series = dataCols.map { c in
            Series(name: headerRow ? sheet.display(SheetRef(col: c, row: rows[0]), calc) : "Spalte " + SheetRef.colName(c),
                   values: dataRows.map { value(c, $0).number })
        }
        return Content(categories: categories, series: series)
    }

    /// Schoene Schritte fuer die Achse: (unten, oben, Schritt)
    public static func axis(min lo: Double, max hi: Double, lines: Int = 4) -> (low: Double, high: Double, step: Double) {
        guard lo.isFinite, hi.isFinite, hi > lo else { return (0, 1, 0.25) }
        let rough = (hi - lo) / Double(max(1, lines))
        let mag = pow(10, (log10(rough)).rounded(.down))
        let step = [1.0, 2, 2.5, 5, 10].map { $0 * mag }.first { $0 >= rough } ?? rough
        let low = (lo / step).rounded(.down) * step, high = (hi / step).rounded(.up) * step
        return (low, high, step)
    }
}
