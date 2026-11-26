import SwiftUI
import UIKit
import UniFlowCore

/// Zustand der grossen Tabellen-Ansicht (`SheetEditorView`): die Tabelle, die Auswahl, der Text, der gerade getippt
/// wird, Rueckgaengig. Gespeichert wird beim Schliessen (ein Rueckgaengig-Schritt auf der Seite).
@MainActor
final class SheetEditorModel: ObservableObject {
    @Published private(set) var sheet: Sheet
    /// Aktive Zelle (dort wird getippt) und das andere Ende der Auswahl
    @Published private(set) var active: SheetRef
    @Published private(set) var corner: SheetRef
    /// Text, der gerade getippt wird (nil: es wird nicht getippt)
    @Published var editing: String?
    /// Zaehlt bei jeder Aenderung der Tabelle hoch (das Gitter zeichnet neu)
    @Published private(set) var revision = 0
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    /// Kurzer Hinweis unter der Leiste (z. B. "Mehr Zeilen gehen nicht")
    @Published var notice: String?

    let title: String
    private(set) var calc: SheetCalc
    private var undoStack: [Sheet] = []
    private var redoStack: [Sheet] = []
    private let original: Sheet
    static let undoLimit = 80

    /// Das Eingabefeld setzt Text an der Schreibmarke ein (Bezug antippen, Funktion waehlen)
    var insertAtCursor: ((String) -> Void)?
    /// Zwischenablage der App (behaelt Formeln und Aussehen); daneben geht der reine Text in die Zwischenablage des Geraets
    static var clipboard: (block: Sheet.Block, text: String)?

    init(sheet: Sheet, title: String) {
        self.sheet = sheet
        self.original = sheet
        self.title = title
        calc = sheet.calc()
        active = SheetRef(col: 0, row: 0)
        corner = SheetRef(col: 0, row: 0)
    }

    var changed: Bool { sheet != original }
    var selection: SheetRange { SheetRange(active, corner) }
    var hidden: Set<Int> { SheetObject.layout(sheet, calc).hidden }

    // MARK: Aendern

    /// Jede Aenderung der Tabelle: ein Rueckgaengig-Schritt, neu rechnen
    func change(_ f: (inout Sheet) -> Void) {
        var next = sheet
        f(&next)
        guard next != sheet else { return }
        undoStack.append(sheet)
        if undoStack.count > Self.undoLimit { undoStack.removeFirst() }
        redoStack = []
        apply(next)
    }

    /// Aenderung ohne eigenen Rueckgaengig-Schritt (laufendes Ziehen; der Schritt wurde am Anfang gemerkt)
    func changeQuietly(_ f: (inout Sheet) -> Void) {
        var next = sheet
        f(&next)
        guard next != sheet else { return }
        apply(next)
    }

    func rememberForUndo() {
        undoStack.append(sheet)
        if undoStack.count > Self.undoLimit { undoStack.removeFirst() }
        redoStack = []
        canUndo = true
        canRedo = false
    }

    private func apply(_ next: Sheet) {
        sheet = next
        calc = next.calc()
        active = clamp(active)
        corner = clamp(corner)
        revision += 1
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        editing = nil
        redoStack.append(sheet)
        apply(last)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        editing = nil
        undoStack.append(sheet)
        apply(next)
    }

    private func clamp(_ r: SheetRef) -> SheetRef {
        SheetRef(col: min(sheet.cols - 1, max(0, r.col)), row: min(sheet.rows - 1, max(0, r.row)))
    }

    // MARK: Auswahl

    func select(_ r: SheetRef, extend: Bool = false) {
        let c = clamp(r)
        if extend { corner = c } else { active = c; corner = c }
    }

    func select(_ range: SheetRange) {
        let g = sheet.clamped(range)
        active = g.from
        corner = g.to
    }

    func selectColumn(_ col: Int, extend: Bool = false) {
        if extend { corner = SheetRef(col: col, row: sheet.rows - 1); active = SheetRef(col: active.col, row: 0); return }
        active = SheetRef(col: col, row: 0)
        corner = SheetRef(col: col, row: sheet.rows - 1)
    }

    func selectRow(_ row: Int, extend: Bool = false) {
        if extend { corner = SheetRef(col: sheet.cols - 1, row: row); active = SheetRef(col: 0, row: active.row); return }
        active = SheetRef(col: 0, row: row)
        corner = SheetRef(col: sheet.cols - 1, row: row)
    }

    /// Einen Schritt weiter (Pfeiltasten, Eingabe, Tab); gefilterte Zeilen werden uebersprungen
    func move(dCol: Int, dRow: Int, extend: Bool = false) {
        var r = extend ? corner : active
        r.col += dCol
        r.row += dRow
        let h = hidden
        while dRow != 0, r.row >= 0, r.row < sheet.rows, h.contains(r.row) { r.row += dRow > 0 ? 1 : -1 }
        guard r.row >= 0, r.col >= 0, r.row < sheet.rows, r.col < sheet.cols else { return }
        select(r, extend: extend)
    }

    // MARK: Tippen

    var isEditing: Bool { editing != nil }
    /// Es wird eine Formel getippt: Antippen einer Zelle setzt ihren Namen ein
    var isFormulaEditing: Bool { editing?.drop(while: { $0.isWhitespace }).hasPrefix("=") == true }

    func beginEditing(_ initial: String? = nil) {
        corner = active
        editing = initial ?? sheet.raw(active)
    }

    /// Getipptes uebernehmen; `move`: danach einen Schritt weiter (Eingabe: nach unten, Tab: nach rechts). Am unteren
    /// Rand waechst die Tabelle um eine Zeile, am rechten Rand um eine Spalte.
    func commitEditing(dCol: Int = 0, dRow: Int = 0) {
        if let text = editing {
            let at = active
            if text != sheet.raw(at) { change { $0.set(text, at: at) } }
            editing = nil
        }
        guard dCol != 0 || dRow != 0 else { return }
        if dRow > 0, active.row == sheet.rows - 1, sheet.rows < Sheet.maxRows { change { $0.insertRows(at: $0.rows) } }
        if dCol > 0, active.col == sheet.cols - 1, sheet.cols < Sheet.maxCols { change { $0.insertCols(at: $0.cols) } }
        move(dCol: dCol, dRow: dRow)
    }

    func cancelEditing() { editing = nil }

    func insertReference(_ r: SheetRef) {
        guard isFormulaEditing else { return }
        if let insertAtCursor { insertAtCursor(r.name) } else { editing = (editing ?? "") + r.name }
    }

    /// Funktion aus der Auswahl: beginnt eine Formel bzw. setzt sie an der Schreibmarke ein
    func insertFunction(_ pattern: String) {
        if isEditing, isFormulaEditing { insertAtCursor?(pattern) ?? (editing = (editing ?? "") + pattern) }
        else { beginEditing("=" + pattern) }
    }

    // MARK: Anzeige der aktiven Zelle

    var activeStyle: SheetStyle { sheet.style(active) }
    var activeRaw: String { sheet.raw(active) }
    var activeError: SheetError? { calc.value(active).error }
    var selectionName: String { selection.name }

    // MARK: Aussehen

    func restyle(_ f: @escaping (inout SheetStyle) -> Void) {
        let g = selection
        change { $0.restyle(g, f) }
    }

    func toggleBold() { let on = !activeStyle.bold; restyle { $0.bold = on } }
    func toggleItalic() { let on = !activeStyle.italic; restyle { $0.italic = on } }
    func setColor(_ hex: String?) { restyle { $0.color = hex } }
    func setFill(_ hex: String?) { restyle { $0.fill = hex } }
    func setAlign(_ a: String?) { restyle { $0.align = a } }
    func setFormat(_ f: String?) { restyle { $0.format = f; if f == nil { $0.decimals = nil } } }

    /// Eine Nachkommastelle mehr oder weniger (ausgehend von dem, was die aktive Zelle gerade zeigt)
    func changeDecimals(_ d: Int) {
        let st = activeStyle
        var now = st.decimals ?? (st.format == "e" || st.format == "n" ? 2 : 0)
        if st.decimals == nil, st.format == nil, case .number(let v) = calc.value(active) {
            let text = SheetText.general(v)
            now = text.firstIndex(of: ",").map { text.distance(from: $0, to: text.endIndex) - 1 } ?? 0
        }
        let next = min(6, max(0, now + d))
        restyle { $0.decimals = next }
    }

    func setBorder(_ mode: String) {
        let g = selection
        change { $0.setBorder(g, mode) }
    }

    // MARK: Zeilen und Spalten

    func insertRows(below: Bool) {
        guard sheet.rows < Sheet.maxRows else { notice = "Mehr als \(Sheet.maxRows) Zeilen gehen nicht."; return }
        let g = selection
        change { $0.insertRows(at: below ? g.to.row + 1 : g.from.row, count: g.rows.count) }
        if !below { select(SheetRange(SheetRef(col: g.from.col, row: g.from.row), SheetRef(col: g.to.col, row: g.to.row))) }
    }

    func insertCols(right: Bool) {
        guard sheet.cols < Sheet.maxCols else { notice = "Mehr als \(Sheet.maxCols) Spalten gehen nicht."; return }
        let g = selection
        change { $0.insertCols(at: right ? g.to.col + 1 : g.from.col, count: g.cols.count) }
    }

    func deleteRows() {
        let g = selection
        guard g.rows.count < sheet.rows else { notice = "Eine Zeile muss bleiben."; return }
        change { $0.deleteRows(at: g.from.row, count: g.rows.count) }
        select(SheetRef(col: g.from.col, row: g.from.row))
    }

    func deleteCols() {
        let g = selection
        guard g.cols.count < sheet.cols else { notice = "Eine Spalte muss bleiben."; return }
        change { $0.deleteCols(at: g.from.col, count: g.cols.count) }
        select(SheetRef(col: g.from.col, row: g.from.row))
    }

    func setWidth(_ w: Double, col: Int) { change { $0.setWidth(w, col: col) } }
    func setHeight(_ h: Double, row: Int) { change { $0.setHeight(h, row: row) } }
    func toggleHeader() { change { $0.header.toggle() } }

    // MARK: Sortieren und Filtern

    func sort(ascending: Bool) {
        let col = active.col
        change { $0.sort(byCol: col, ascending: ascending) }
    }

    var filterValues: [String] { sheet.filterValues(col: active.col, calc) }
    func isFiltered(_ col: Int) -> Bool { !(sheet.filters[col] ?? []).isEmpty }
    func isHiddenByFilter(_ value: String) -> Bool { sheet.filters[active.col]?.contains(value) == true }

    func toggleFilter(_ value: String) {
        let col = active.col
        change {
            var set = $0.filters[col] ?? []
            if set.contains(value) { set.remove(value) } else { set.insert(value) }
            $0.filters[col] = set.isEmpty ? nil : set
        }
    }

    /// Nur diesen Wert zeigen
    func filterOnly(_ value: String) {
        let col = active.col
        let all = Set(filterValues)
        change { $0.filters[col] = all.subtracting([value]) }
    }

    func clearFilter(all: Bool) {
        let col = active.col
        change { if all { $0.filters = [:] } else { $0.filters[col] = nil } }
    }

    // MARK: Kopieren

    func copy() {
        let g = selection
        let block = sheet.block(g)
        let text = block.plainText { self.sheet.display($0, self.calc) }
        Self.clipboard = (block, text)
        UIPasteboard.general.string = text
    }

    func cut() {
        copy()
        clearContents()
    }

    /// Einfuegen: aus der App mit Formeln und Aussehen; sonst der Text der Zwischenablage (Tabulator, Zeilen)
    func paste() {
        let at = selection.from
        let text = UIPasteboard.general.string
        if let own = Self.clipboard, text == nil || text == own.text {
            var filled = SheetRange(at)
            change { filled = $0.paste(own.block, at: at) }
            select(filled)
        } else if let text, !text.isEmpty {
            var filled = SheetRange(at)
            change { filled = $0.pasteText(text, at: at) }
            select(filled)
        }
    }

    func clearContents() {
        let g = selection
        change { $0.clear(g) }
    }

    func fillDown() {
        let g = selection
        guard g.rows.count > 1 else { notice = "Erst mehrere Zeilen auswählen: Die oberste wird nach unten übernommen."; return }
        change { $0.fillDown(g) }
    }

    // MARK: Diagramme

    func addChart(_ kind: String) {
        guard sheet.charts.count < SheetChart.maxPerSheet else { notice = "Mehr als \(SheetChart.maxPerSheet) Diagramme gehen nicht."; return }
        // eine einzelne Zelle gewaehlt: alle gefuellten Zellen nehmen
        let range = selection.count > 1 ? selection : (sheet.usedRange ?? selection)
        change { $0.charts.append(SheetChart(id: PageOrder.uid(), kind: kind, range: range)) }
    }

    func updateChart(_ id: String, _ f: @escaping (inout SheetChart) -> Void) {
        change { s in
            guard let i = s.charts.firstIndex(where: { $0.id == id }) else { return }
            var c = s.charts[i]
            f(&c)
            s.charts[i] = SheetChart(id: c.id, kind: c.kind, range: c.range, title: c.title)
        }
    }

    func removeChart(_ id: String) { change { $0.charts.removeAll { $0.id == id } } }
    func setShow(_ show: String) { change { $0.show = show } }
}
