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
    /// Gute Nachricht unter der Leiste (was die KI gebaut hat)
    @Published var info: String?
    /// KI-Hilfe (26.11.2026; seit dem Tarifmodell vom 26.11. ab Plus, die Antworten kosten Credits): schickt den Rumpf an die KI-Hilfe und liefert ihre Antwort; nil = keine KI
    var askAI: ((JSONValue) async throws -> String)?
    /// Fehler einer KI-Anfrage in Worten fuer den Nutzer (Credits aufgebraucht, nicht angemeldet ...)
    var explainAIError: ((Error) -> String)?
    @Published private(set) var aiBusy = false
    @Published var aiError: String?
    static let aiNothing = "Die KI hat nichts geliefert, das in die Tabelle passt. Schreib den Wunsch bitte etwas genauer."
    static let aiSame = "Das steht schon so in der Tabelle – die KI hat nichts geändert."

    let title: String
    /// Nur ansehen (ohne Plus): rollen, zoomen, auswaehlen und kopieren gehen, aendern nicht
    let readOnly: Bool
    /// Warum nur ansehen (Zeile oben)
    var readOnlyReason = ""
    /// Ein Dialog (KI-Wunsch, Titel eines Diagramms) hat die Tastatur: Das Gitter holt sie sich nicht zurueck
    var dialogOpen = false
    private(set) var calc: SheetCalc

    private struct Step {
        let sheet: Sheet
        let active: SheetRef
        let corner: SheetRef
    }
    private var undoStack: [Step] = []
    private var redoStack: [Step] = []
    /// Stand, der auf der Seite steht
    private var saved: Sheet
    static let undoLimit = 80
    /// So viele Zellen duerfen alle gemerkten Schritte zusammen halten (eine volle Tabelle hat 26 000)
    static let undoCellBudget = 300_000

    /// Das Eingabefeld setzt Text an der Schreibmarke ein (Bezug antippen, Funktion waehlen)
    var insertAtCursor: ((String) -> Void)?
    /// Zwischenablage der App (behaelt Formeln und Aussehen); daneben geht der reine Text in die Zwischenablage des
    /// Geraets. `cut`: ausgeschnitten - beim ersten Einfuegen zeigen die Formeln weiter auf dieselben Zellen.
    static var clipboard: (block: Sheet.Block, text: String, cut: Bool)?

    init(sheet: Sheet, title: String, readOnly: Bool = false) {
        self.sheet = sheet
        self.saved = sheet
        self.title = title
        self.readOnly = readOnly
        calc = sheet.calc()
        active = SheetRef(col: 0, row: 0)
        corner = SheetRef(col: 0, row: 0)
    }

    /// Es gibt etwas, das noch nicht auf der Seite steht
    var changed: Bool { sheet != saved }
    func markSaved(_ s: Sheet) { saved = s }
    var selection: SheetRange { SheetRange(active, corner) }
    var hidden: Set<Int> { sheet.filters.isEmpty ? [] : sheet.hiddenRows(calc) }

    // MARK: Aendern

    private func remember() {
        undoStack.append(Step(sheet: sheet, active: active, corner: corner))
        var cells = undoStack.reduce(0) { $0 + $1.sheet.cells.count }
        while undoStack.count > 1, undoStack.count > Self.undoLimit || cells > Self.undoCellBudget {
            cells -= undoStack.removeFirst().sheet.cells.count
        }
        redoStack = []
    }

    /// Jede Aenderung der Tabelle: ein Rueckgaengig-Schritt, neu rechnen
    func change(_ f: (inout Sheet) -> Void) {
        guard !readOnly else { return }
        var next = sheet
        f(&next)
        guard next != sheet else { return }
        remember()
        apply(next)
    }

    /// Spalte oder Zeile groesser/kleiner ziehen: Der Schritt wird beim ersten wirklichen Aendern gemerkt (`first`),
    /// danach laeuft das Ziehen ohne weitere Schritte. Liefert, ob sich etwas geaendert hat.
    @discardableResult
    func changeLive(first: Bool, _ f: (inout Sheet) -> Void) -> Bool {
        guard !readOnly else { return false }
        var next = sheet
        f(&next)
        guard next != sheet else { return false }
        if first { remember() }
        apply(next)
        return true
    }

    private func apply(_ next: Sheet, selection: (SheetRef, SheetRef)? = nil) {
        sheet = next
        calc = next.calc()
        active = clamp(selection?.0 ?? active)
        corner = clamp(selection?.1 ?? corner)
        // ein Filter hat die aktive Zeile versteckt: auf die naechste sichtbare gehen
        let h = hidden
        if h.contains(active.row), let row = nearestVisible(active.row, hidden: h) {
            active = SheetRef(col: active.col, row: row)
            corner = active
        }
        revision += 1
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    private func nearestVisible(_ row: Int, hidden: Set<Int>) -> Int? {
        (row..<sheet.rows).first { !hidden.contains($0) } ?? (0..<row).reversed().first { !hidden.contains($0) }
    }

    func undo() {
        // waehrend des Tippens: nur das Getippte verwerfen
        if isEditing { editing = nil; return }
        guard let last = undoStack.popLast() else { return }
        redoStack.append(Step(sheet: sheet, active: active, corner: corner))
        apply(last.sheet, selection: (last.active, last.corner))
    }

    func redo() {
        if isEditing { commitEditing() }
        guard let next = redoStack.popLast() else { return }
        undoStack.append(Step(sheet: sheet, active: active, corner: corner))
        apply(next.sheet, selection: (next.active, next.corner))
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

    /// Die Auswahl ohne die Zeilen, die ein Filter versteckt (zusammenhaengende Stuecke von oben nach unten):
    /// Loeschen, Aussehen und Ausfuellen sollen nur treffen, was man sieht.
    var visibleSelection: [SheetRange] {
        let g = selection, h = hidden
        guard !h.isEmpty else { return [g] }
        var out: [SheetRange] = []
        var start: Int?
        for row in g.rows {
            if h.contains(row) {
                if let s = start { out.append(SheetRange(SheetRef(col: g.from.col, row: s), SheetRef(col: g.to.col, row: row - 1))) }
                start = nil
            } else if start == nil { start = row }
        }
        if let s = start { out.append(SheetRange(SheetRef(col: g.from.col, row: s), SheetRef(col: g.to.col, row: g.to.row))) }
        return out
    }

    // MARK: Tippen

    var isEditing: Bool { editing != nil }
    /// Es wird eine Formel getippt: Antippen einer Zelle setzt ihren Namen ein
    var isFormulaEditing: Bool { editing?.drop(while: { $0.isWhitespace }).hasPrefix("=") == true }

    func beginEditing(_ initial: String? = nil) {
        guard !readOnly else { return }
        corner = active
        editing = initial ?? sheet.raw(active)
    }

    /// Getipptes uebernehmen; `move`: danach einen Schritt weiter (Eingabe: nach unten, Tab: nach rechts). Steht in
    /// der letzten Zeile etwas, waechst die Tabelle dabei um eine Zeile (am rechten Rand um eine Spalte) - alles
    /// zusammen ist ein Schritt fuer "Widerrufen".
    func commitEditing(dCol: Int = 0, dRow: Int = 0) {
        let text = editing.map { sheet.typed($0, at: active) }, at = active
        editing = nil
        let typed = text.map { $0 != sheet.raw(at) } ?? false
        func filled(_ refs: [SheetRef]) -> Bool {
            (typed && !(text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || refs.contains { $0 != at && sheet.cells[$0] != nil }
                || (!typed && sheet.cells[at] != nil)
        }
        let growRow = dRow > 0 && at.row == sheet.rows - 1 && sheet.rows < Sheet.maxRows
            && filled((0..<sheet.cols).map { SheetRef(col: $0, row: at.row) })
        let growCol = dCol > 0 && at.col == sheet.cols - 1 && sheet.cols < Sheet.maxCols
            && filled((0..<sheet.rows).map { SheetRef(col: at.col, row: $0) })
        if typed || growRow || growCol {
            change { s in
                if typed, let text { s.set(text, at: at) }
                if growRow { s.insertRows(at: s.rows) }
                if growCol { s.insertCols(at: s.cols) }
            }
        }
        guard dCol != 0 || dRow != 0 else { return }
        move(dCol: dCol, dRow: dRow)
    }

    func cancelEditing() { editing = nil }

    /// Vor jeder Aktion der Leiste: Was gerade getippt wird, gehoert in seine Zelle - nicht in die Zelle, die nach
    /// dem Sortieren oder Einfuegen an dieser Stelle steht.
    private func settle() { if isEditing { commitEditing() } }

    func insertReference(_ r: SheetRef) {
        guard isFormulaEditing else { return }
        if let insertAtCursor { insertAtCursor(r.name) } else { editing = (editing ?? "") + r.name }
    }

    /// Funktion aus der Auswahl: beginnt eine Formel bzw. setzt sie an der Schreibmarke ein
    func insertFunction(_ pattern: String) {
        guard !readOnly else { return }
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
        settle()
        let parts = visibleSelection
        change { s in for g in parts { s.restyle(g, f) } }
    }

    func toggleBold() { let on = !activeStyle.bold; restyle { $0.bold = on } }
    func toggleItalic() { let on = !activeStyle.italic; restyle { $0.italic = on } }
    func setColor(_ hex: String?) { restyle { $0.color = hex } }
    func setFill(_ hex: String?) { restyle { $0.fill = hex } }
    func setAlign(_ a: String?) { restyle { $0.align = a } }
    func setFormat(_ f: String?) { restyle { $0.format = f; if f == nil { $0.decimals = nil } } }

    /// Eine Nachkommastelle mehr oder weniger (ausgehend von dem, was die aktive Zelle gerade zeigt)
    func changeDecimals(_ d: Int) {
        settle()
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
        settle()
        let parts = visibleSelection
        change { s in for g in parts { s.setBorder(g, mode) } }
    }

    // MARK: Zeilen und Spalten

    func insertRows(below: Bool) {
        settle()
        guard sheet.rows < Sheet.maxRows else { notice = "Mehr als \(Sheet.maxRows) Zeilen gehen nicht."; return }
        let g = selection
        change { $0.insertRows(at: below ? g.to.row + 1 : g.from.row, count: g.rows.count) }
        if !below { select(SheetRange(SheetRef(col: g.from.col, row: g.from.row), SheetRef(col: g.to.col, row: g.to.row))) }
    }

    func insertCols(right: Bool) {
        settle()
        guard sheet.cols < Sheet.maxCols else { notice = "Mehr als \(Sheet.maxCols) Spalten gehen nicht."; return }
        let g = selection
        change { $0.insertCols(at: right ? g.to.col + 1 : g.from.col, count: g.cols.count) }
    }

    func deleteRows() {
        settle()
        let g = selection, parts = visibleSelection
        guard parts.reduce(0, { $0 + $1.rows.count }) < sheet.rows else { notice = "Eine Zeile muss bleiben."; return }
        // von unten nach oben, damit die Zeilennummern der oberen Stuecke stimmen
        change { s in for p in parts.reversed() { s.deleteRows(at: p.from.row, count: p.rows.count) } }
        select(SheetRef(col: g.from.col, row: g.from.row))
    }

    func deleteCols() {
        settle()
        let g = selection
        guard g.cols.count < sheet.cols else { notice = "Eine Spalte muss bleiben."; return }
        change { $0.deleteCols(at: g.from.col, count: g.cols.count) }
        select(SheetRef(col: g.from.col, row: g.from.row))
    }

    func setWidth(_ w: Double, col: Int) { change { $0.setWidth(w, col: col) } }
    func setHeight(_ h: Double, row: Int) { change { $0.setHeight(h, row: row) } }
    func toggleHeader() { settle(); change { $0.header.toggle() } }

    // MARK: Sortieren und Filtern

    func sort(ascending: Bool) {
        settle()
        let col = active.col
        change { $0.sort(byCol: col, ascending: ascending) }
    }

    var filterValues: [String] { sheet.filterValues(col: active.col, calc) }
    func isFiltered(_ col: Int) -> Bool { !(sheet.filters[col] ?? []).isEmpty }
    /// Erste Zelle der Spalte, die so aussieht (fuer Eintraege, die eine Zahl in anderem Format meinen)
    private func cellValue(showing value: String, col: Int) -> SheetValue {
        for row in sheet.firstDataRow..<sheet.rows {
            let r = SheetRef(col: col, row: row)
            if sheet.display(r, calc) == value { return calc.value(r) }
        }
        return .text(value)
    }

    func isHiddenByFilter(_ value: String) -> Bool {
        guard let set = sheet.filters[active.col] else { return false }
        return Sheet.filterHides(set, value, cellValue(showing: value, col: active.col))
    }

    func toggleFilter(_ value: String) {
        settle()
        let col = active.col
        let v = cellValue(showing: value, col: col)
        change {
            var set = $0.filters[col] ?? []
            if Sheet.filterHides(set, value, v) {
                // auch Eintraege derselben Zahl in anderem Format
                set = set.filter { !Sheet.filterHides([$0], value, v) }
            } else { set.insert(value) }
            $0.filters[col] = set.isEmpty ? nil : set
        }
    }

    /// Nur diesen Wert zeigen
    func filterOnly(_ value: String) {
        settle()
        let col = active.col
        let all = Set(filterValues)
        change { $0.filters[col] = all.subtracting([value]) }
    }

    func clearFilter(all: Bool) {
        settle()
        let col = active.col
        change { if all { $0.filters = [:] } else { $0.filters[col] = nil } }
    }

    // MARK: Kopieren

    /// Ausschnitt der Auswahl; versteckt ein Filter Zeilen darin, ruecken die sichtbaren zusammen
    private func selectionBlock() -> Sheet.Block {
        let g = selection, parts = visibleSelection
        guard parts.count != 1 || parts[0] != g else { return sheet.block(g) }
        var b = Sheet.Block(origin: g.from, rows: 0, cols: g.cols.count, cells: [:], styles: [:])
        for p in parts {
            for row in p.rows {
                for col in g.cols {
                    let from = SheetRef(col: col, row: row), to = SheetRef(col: col - g.from.col, row: b.rows)
                    if let raw = sheet.cells[from] { b.cells[to] = SheetFormula.shifted(raw, dCol: 0, dRow: g.from.row + b.rows - row) }
                    if let st = sheet.styles[from] { b.styles[to] = st }
                }
                b.rows += 1
            }
        }
        return b
    }

    func copy() { copy(cut: false) }

    private func copy(cut: Bool) {
        settle()
        let g = selection, parts = visibleSelection
        let block = selectionBlock()
        let rows = parts.flatMap { Array($0.rows) }
        let text = rows.map { row in g.cols.map { self.sheet.display(SheetRef(col: $0, row: row), self.calc) }.joined(separator: "\t") }.joined(separator: "\n")
        Self.clipboard = (block, text, cut)
        UIPasteboard.general.string = text
    }

    func cut() {
        guard !readOnly else { return }
        // versteckt ein Filter Zeilen in der Auswahl, ruecken die sichtbaren zusammen - dann gilt es wie eine Kopie
        let whole = visibleSelection.count == 1 && visibleSelection.first == selection
        copy(cut: whole)
        clearContents()
    }

    /// Einfuegen: aus der App mit Formeln und Aussehen; sonst der Text der Zwischenablage (Tabulator, Zeilen)
    func paste() {
        guard !readOnly else { return }
        settle()
        let at = selection.from
        let text = UIPasteboard.general.string
        if let own = Self.clipboard, text == nil || text == own.text {
            var filled = SheetRange(at)
            change { filled = $0.paste(own.block, at: at, cut: own.cut) }
            // nach dem ersten Einfuegen ist es eine gewoehnliche Kopie
            if own.cut { Self.clipboard = (own.block, own.text, false) }
            select(filled)
        } else if let text, !text.isEmpty {
            var filled = SheetRange(at)
            change { filled = $0.pasteText(text, at: at) }
            select(filled)
        }
    }

    func clearContents() {
        if isEditing { cancelEditing() }
        let parts = visibleSelection
        change { s in for g in parts { s.clear(g) } }
    }

    func fillDown() {
        settle()
        let g = selection
        let rows = visibleSelection.flatMap { Array($0.rows) }
        guard rows.count > 1, let first = rows.first else { notice = "Erst mehrere Zeilen auswählen: Die oberste wird nach unten übernommen."; return }
        change { s in
            let top = s.block(SheetRange(SheetRef(col: g.from.col, row: first), SheetRef(col: g.to.col, row: first)))
            for row in rows.dropFirst() { s.paste(top, at: SheetRef(col: g.from.col, row: row)) }
        }
    }

    // MARK: KI-Hilfe

    private var aiTask: Task<Void, Never>?

    /// KI starten (Knopf "Los"); `done`: ob etwas eingesetzt wurde
    func startAI(wish: String, done: @escaping (Bool) -> Void = { _ in }) {
        guard aiTask == nil, !aiBusy else { return }
        aiTask = Task { [weak self] in
            let ok = await self?.runAI(wish: wish) ?? false
            self?.aiTask = nil
            done(ok)
        }
    }

    /// Laufende Anfrage abbrechen (die Antwort wird nicht mehr eingesetzt)
    func cancelAI() { aiTask?.cancel() }

    /// Wunsch an die KI: Sie bekommt die Tabelle und liefert Zellen und Diagramme; alles zusammen ist ein Schritt, den
    /// "Widerrufen" zuruecknimmt. `true`, wenn etwas eingesetzt wurde.
    @discardableResult
    func runAI(wish: String) async -> Bool {
        let w = wish.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !readOnly, !w.isEmpty, !aiBusy, let askAI else { return false }
        commitEditing()
        aiBusy = true
        aiError = nil
        defer { aiBusy = false }
        let at = selection.from
        do {
            let answer = try await askAI(SheetAI.requestBody(wish: w, sheet: sheet, selection: selection))
            if Task.isCancelled { return false }
            guard let plan = SheetAI.parse(answer) else { aiError = Self.aiNothing; return false }
            // wurde inzwischen weitergetippt, kommt die Antwort trotzdem hinein (ein Schritt, "Widerrufen" nimmt ihn
            // zurueck): Die Anfrage ist bezahlt und soll nicht verfallen
            if isEditing { commitEditing() }
            let before = sheet
            var outcome = SheetAI.Outcome()
            change { outcome = SheetAI.apply(plan, to: &$0, at: at) }
            guard outcome.cells > 0 || outcome.charts > 0 else { aiError = Self.aiNothing; return false }
            guard sheet != before else { aiError = Self.aiSame; return false }
            if let f = outcome.filled { select(f) }
            info = outcome.summary + (plan.note.isEmpty ? "" : " " + plan.note) + " Mit „Widerrufen“ nimmst du es zurück."
            return true
        } catch {
            if Task.isCancelled || error is CancellationError { return false }
            aiError = explainAIError?(error) ?? error.localizedDescription
            return false
        }
    }

    // MARK: Diagramme

    func addChart(_ kind: String) {
        settle()
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
