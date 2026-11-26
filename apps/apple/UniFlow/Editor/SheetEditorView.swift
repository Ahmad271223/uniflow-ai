import GameController
import SwiftUI
import UIKit
import UniFlowCore

/// Grosse Ansicht einer Tabelle ("Excel", 26.11.2026): oben die Eingabezeile wie in Excel (Zelle, fx, Text bzw. Formel),
/// darunter die Leiste (Fett, Farben, Zahlenformat, Rahmen, Zeilen/Spalten, Sortieren, Filter, Diagramm), das Gitter und
/// die Diagramme. Oeffnet sich ueber dem Dokument; "Fertig" schreibt die Tabelle zurueck auf die Seite.
struct SheetEditorView: View {
    @ObservedObject var model: SheetEditorModel
    /// Zwischenstand sichern (App geht in den Hintergrund)
    let onSave: (Sheet) -> Void
    let onClose: () -> Void

    @State private var showFilter = false
    @State private var titleChart: SheetChart?
    @State private var titleText = ""
    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        VStack(spacing: 0) {
            header
            formulaRow
            hintRow
            toolbar
            Divider()
            SheetGridHost(model: model)
                .ignoresSafeArea(.container, edges: .horizontal)
            if !model.sheet.charts.isEmpty { chartStrip }
        }
        .background(UF.bg.ignoresSafeArea())
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            model.commitEditing()
            if model.changed { onSave(model.sheet) }
        }
        .alert("Titel des Diagramms", isPresented: Binding(get: { titleChart != nil }, set: { if !$0 { titleChart = nil } })) {
            TextField("Titel", text: $titleText)
            Button("Abbrechen", role: .cancel) { titleChart = nil }
            Button("Sichern") {
                if let c = titleChart { model.updateChart(c.id) { $0.title = titleText } }
                titleChart = nil
            }
        }
        .accessibilityIdentifier("sheet.editor")
    }

    // MARK: Kopf

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "tablecells").foregroundStyle(UF.accentText)
            Text(model.title).ufFont(16, 600).foregroundStyle(UF.text).lineLimit(1)
            Spacer(minLength: 8)
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 34, height: 34) }
                .disabled(!model.canUndo).accessibilityLabel("Widerrufen").accessibilityIdentifier("sheet.undo")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward").frame(width: 34, height: 34) }
                .disabled(!model.canRedo).accessibilityLabel("Wiederholen").accessibilityIdentifier("sheet.redo")
            Button {
                model.commitEditing()
                if model.changed { onSave(model.sheet) }
                onClose()
            } label: { Text("Fertig").ufFont(15, 600).padding(.horizontal, 14).padding(.vertical, 7) }
                .background(Capsule().fill(UF.accent))
                .foregroundStyle(.white)
                .accessibilityIdentifier("sheet.done")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(UF.surface)
    }

    // MARK: Eingabezeile

    private var formulaRow: some View {
        HStack(spacing: 8) {
            Text(model.selectionName)
                .ufFont(13, 600).foregroundStyle(UF.text2)
                .frame(minWidth: 54)
                .padding(.vertical, 7).padding(.horizontal, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(UF.surface2))
                .accessibilityIdentifier("sheet.cellName")
            Menu {
                ForEach(SheetFormula.catalog, id: \.name) { f in
                    Button { model.insertFunction(f.pattern) } label: { Text("\(f.name) – \(f.hint)") }
                }
            } label: {
                Text("fx").font(.system(size: 15, weight: .semibold, design: .serif)).italic()
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 8).fill(UF.surface2))
            }
            .accessibilityLabel("Funktion einsetzen")
            .accessibilityIdentifier("sheet.fx")
            SheetFormulaField(model: model)
                .frame(height: 34)
                .padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 8).stroke(model.isEditing ? UF.accent : UF.lineStrong, lineWidth: model.isEditing ? 2 : 1))
            if model.isEditing {
                Button { model.cancelEditing() } label: { Image(systemName: "xmark").frame(width: 34, height: 34) }
                    .accessibilityLabel("Eingabe verwerfen").accessibilityIdentifier("sheet.cancel")
                Button { model.commitEditing() } label: { Image(systemName: "checkmark").frame(width: 34, height: 34) }
                    .accessibilityLabel("Eingabe übernehmen").accessibilityIdentifier("sheet.commit")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(UF.surface)
    }

    @ViewBuilder private var hintRow: some View {
        if let n = model.notice {
            hint(n, UF.warn).task(id: n) {
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                if model.notice == n { model.notice = nil }
            }
        } else if !model.isEditing, let e = model.activeError {
            hint("\(e.rawValue)  \(e.hint)", UF.bad)
        }
    }

    private func hint(_ text: String, _ color: Color) -> some View {
        HStack {
            Text(text).ufFont(12.5).foregroundStyle(color)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 5)
        .background(UF.surface)
        .accessibilityIdentifier("sheet.hint")
    }

    // MARK: Leiste

    private func icon(_ name: String, on: Bool = false) -> some View {
        Image(systemName: name)
            .frame(width: 34, height: 32)
            .background(RoundedRectangle(cornerRadius: 7).fill(on ? UF.accentSoft : Color.clear))
            .foregroundStyle(on ? UF.accentText : UF.text)
    }

    private func dot(_ hex: String?) -> some View {
        TextFormatBar.dot(hex ?? "#ffffff")
    }

    private var toolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                let st = model.activeStyle
                Button { model.toggleBold() } label: { icon("bold", on: st.bold) }
                    .accessibilityLabel("Fett").accessibilityIdentifier("sheet.bold")
                Button { model.toggleItalic() } label: { icon("italic", on: st.italic) }
                    .accessibilityLabel("Kursiv").accessibilityIdentifier("sheet.italic")
                Menu {
                    ForEach(SheetStyle.textColors, id: \.self) { c in
                        Button { model.setColor(c == SheetStyle.textColors[0] ? nil : c) } label: { Label { Text(Self.colorName(c)) } icon: { dot(c) } }
                    }
                } label: { icon("character") }
                    .accessibilityLabel("Textfarbe").accessibilityIdentifier("sheet.color")
                Menu {
                    Button { model.setFill(nil) } label: { Label("Keine Farbe", systemImage: "circle.slash") }
                    ForEach(SheetStyle.fillColors, id: \.self) { c in
                        Button { model.setFill(c) } label: { Label { Text(Self.colorName(c)) } icon: { dot(c) } }
                    }
                } label: { icon("paintbrush.pointed", on: st.fill != nil) }
                    .accessibilityLabel("Zellfarbe").accessibilityIdentifier("sheet.fill")
                Menu {
                    Button { model.setAlign("l") } label: { Label("Links", systemImage: "text.alignleft") }
                    Button { model.setAlign("c") } label: { Label("Mitte", systemImage: "text.aligncenter") }
                    Button { model.setAlign("r") } label: { Label("Rechts", systemImage: "text.alignright") }
                    Button("Automatisch (Zahlen rechts)") { model.setAlign(nil) }
                } label: { icon(st.align == "c" ? "text.aligncenter" : st.align == "r" ? "text.alignright" : "text.alignleft") }
                    .accessibilityLabel("Ausrichtung").accessibilityIdentifier("sheet.align")
                sep
                Menu {
                    Button("Automatisch") { model.setFormat(nil) }
                    Button("Zahl  1.234,50") { model.setFormat("n") }
                    Button("Prozent  12 %") { model.setFormat("p") }
                    Button("Euro  3,20 €") { model.setFormat("e") }
                    Button("Text (nicht rechnen)") { model.setFormat("t") }
                    Divider()
                    Button("Eine Stelle mehr nach dem Komma") { model.changeDecimals(1) }
                    Button("Eine Stelle weniger nach dem Komma") { model.changeDecimals(-1) }
                } label: { icon("number", on: st.format != nil) }
                    .accessibilityLabel("Zahlenformat").accessibilityIdentifier("sheet.format")
                Menu {
                    Button { model.setBorder("outer") } label: { Label("Rahmen außen", systemImage: "square") }
                    Button { model.setBorder("all") } label: { Label("Alle Linien", systemImage: "squareshape.split.2x2") }
                    Button { model.setBorder("bottom") } label: { Label("Linie unten", systemImage: "underline") }
                    Button { model.setBorder("none") } label: { Label("Kein Rahmen", systemImage: "square.dashed") }
                } label: { icon("square.grid.2x2") }
                    .accessibilityLabel("Rahmen").accessibilityIdentifier("sheet.border")
                sep
                Menu {
                    Button { model.insertRows(below: false) } label: { Label("Zeile darüber einfügen", systemImage: "arrow.up.to.line") }
                    Button { model.insertRows(below: true) } label: { Label("Zeile darunter einfügen", systemImage: "arrow.down.to.line") }
                    Button { model.insertCols(right: false) } label: { Label("Spalte links einfügen", systemImage: "arrow.left.to.line") }
                    Button { model.insertCols(right: true) } label: { Label("Spalte rechts einfügen", systemImage: "arrow.right.to.line") }
                    Divider()
                    Button(role: .destructive) { model.deleteRows() } label: { Label(model.selection.rows.count > 1 ? "Zeilen löschen" : "Zeile löschen", systemImage: "trash") }
                    Button(role: .destructive) { model.deleteCols() } label: { Label(model.selection.cols.count > 1 ? "Spalten löschen" : "Spalte löschen", systemImage: "trash") }
                    Divider()
                    Button { model.toggleHeader() } label: {
                        Label(model.sheet.header ? "Erste Zeile ist keine Kopfzeile" : "Erste Zeile als Kopfzeile", systemImage: "tablecells.badge.ellipsis")
                    }
                } label: { icon("plus.rectangle.on.rectangle") }
                    .accessibilityLabel("Zeilen und Spalten").accessibilityIdentifier("sheet.rows")
                Menu {
                    let col = SheetRef.colName(model.active.col)
                    Button { model.sort(ascending: true) } label: { Label("Spalte \(col): klein nach groß, A bis Z", systemImage: "arrow.up") }
                    Button { model.sort(ascending: false) } label: { Label("Spalte \(col): groß nach klein, Z bis A", systemImage: "arrow.down") }
                } label: { icon("arrow.up.arrow.down") }
                    .accessibilityLabel("Sortieren").accessibilityIdentifier("sheet.sort")
                Button { showFilter = true } label: { icon("line.3.horizontal.decrease.circle", on: !model.sheet.filters.isEmpty) }
                    .accessibilityLabel("Filtern").accessibilityIdentifier("sheet.filter")
                    .popover(isPresented: $showFilter) { filterList }
                sep
                Menu {
                    ForEach(SheetChart.kinds, id: \.id) { k in
                        Button { model.addChart(k.id) } label: { Label(k.title, systemImage: Self.chartIcon(k.id)) }
                    }
                } label: { icon("chart.bar.xaxis") }
                    .accessibilityLabel("Diagramm aus der Auswahl").accessibilityIdentifier("sheet.chart")
                Menu {
                    Button { model.copy() } label: { Label("Kopieren", systemImage: "doc.on.doc") }
                    Button { model.cut() } label: { Label("Ausschneiden", systemImage: "scissors") }
                    Button { model.paste() } label: { Label("Einfügen", systemImage: "doc.on.clipboard") }
                    Button { model.fillDown() } label: { Label("Nach unten ausfüllen", systemImage: "arrow.down.square") }
                    Button(role: .destructive) { model.clearContents() } label: { Label("Inhalt löschen", systemImage: "delete.left") }
                } label: { icon("doc.on.doc") }
                    .accessibilityLabel("Kopieren und Einfügen").accessibilityIdentifier("sheet.edit")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
        .background(UF.surface)
    }

    private var sep: some View { Rectangle().fill(UF.line).frame(width: 1, height: 22).padding(.horizontal, 4) }

    static func colorName(_ hex: String) -> String {
        ["#1a1a1a": "Schwarz", "#d7263d": "Rot", "#2f7fd1": "Blau", "#2e9e5b": "Grün", "#e08a00": "Orange", "#7c3aed": "Lila",
         "#7a8199": "Grau", "#fff7a8": "Gelb", "#ffd3e0": "Rosa", "#d6f5c8": "Hellgrün", "#cfe8ff": "Hellblau", "#ffe2b8": "Hellorange",
         "#e7dbff": "Helllila", "#eceef2": "Hellgrau"][hex] ?? hex
    }

    static func chartIcon(_ kind: String) -> String {
        kind == "pie" ? "chart.pie" : kind == "line" ? "chart.xyaxis.line" : "chart.bar"
    }

    // MARK: Filter

    private var filterList: some View {
        let col = SheetRef.colName(model.active.col)
        let values = model.filterValues
        return VStack(alignment: .leading, spacing: 0) {
            Text("Spalte \(col) filtern").ufFont(14, 600).foregroundStyle(UF.text).padding(12)
            Divider()
            if values.isEmpty {
                Text("In dieser Spalte steht noch nichts.").ufFont(13).foregroundStyle(UF.muted).padding(12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(values, id: \.self) { v in
                            Button { model.toggleFilter(v) } label: {
                                HStack {
                                    Image(systemName: model.isHiddenByFilter(v) ? "circle" : "checkmark.circle.fill")
                                        .foregroundStyle(model.isHiddenByFilter(v) ? UF.muted : UF.accent)
                                    Text(v.isEmpty ? "(leer)" : v).ufFont(14).foregroundStyle(UF.text).lineLimit(1)
                                    Spacer()
                                }
                                .padding(.horizontal, 12).padding(.vertical, 9)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu { Button("Nur das zeigen") { model.filterOnly(v) } }
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
            Divider()
            HStack {
                Button("Alles zeigen") { model.clearFilter(all: false) }.disabled(!model.isFiltered(model.active.col))
                Spacer()
                Button("Fertig") { showFilter = false }
            }
            .ufFont(14, 600)
            .padding(12)
        }
        .frame(width: 280)
        .presentationCompactAdaptation(.popover)
        .accessibilityIdentifier("sheet.filterList")
    }

    // MARK: Diagramme

    private var chartStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Diagramme").ufFont(13, 600).foregroundStyle(UF.text2)
                Spacer()
                Text("Auf der Seite:").ufFont(12.5).foregroundStyle(UF.muted)
                Picker("Auf der Seite", selection: Binding(get: { model.sheet.show }, set: { model.setShow($0) })) {
                    Text("Tabelle + Diagramm").tag("both")
                    Text("Nur Tabelle").tag("table")
                    Text("Nur Diagramm").tag("chart")
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("sheet.show")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(model.sheet.charts, id: \.id) { chart in
                        SheetChartPreview(chart: chart, sheet: model.sheet, calc: model.calc)
                            .frame(width: hSize == .compact ? 260 : 320, height: 170)
                            .overlay(alignment: .topTrailing) { chartMenu(chart) }
                            .accessibilityIdentifier("sheet.chart.\(chart.kind)")
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(UF.surface)
    }

    private func chartMenu(_ chart: SheetChart) -> some View {
        Menu {
            ForEach(SheetChart.kinds, id: \.id) { k in
                Button { model.updateChart(chart.id) { $0.kind = k.id } } label: {
                    Label(k.title, systemImage: chart.kind == k.id ? "checkmark" : Self.chartIcon(k.id))
                }
            }
            Divider()
            Button {
                titleText = chart.title
                titleChart = chart
            } label: { Label("Titel ändern …", systemImage: "textformat") }
            Button {
                let g = model.selection
                model.updateChart(chart.id) { $0.range = g }
            } label: { Label("Zahlen aus der Auswahl (\(model.selectionName))", systemImage: "rectangle.dashed") }
            Text("Bereich jetzt: \(chart.range.name)")
            Divider()
            Button(role: .destructive) { model.removeChart(chart.id) } label: { Label("Diagramm löschen", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(UF.muted)
                .padding(6)
        }
        .accessibilityLabel("Diagramm ändern")
    }
}

// MARK: - Gitter in SwiftUI

struct SheetGridHost: UIViewRepresentable {
    let model: SheetEditorModel
    func makeUIView(context: Context) -> SheetGridView { SheetGridView(model: model) }
    func updateUIView(_ v: SheetGridView, context: Context) {}
}

/// Vorschau eines Diagramms (derselbe Zeichner wie auf der Seite)
struct SheetChartPreview: UIViewRepresentable {
    let chart: SheetChart
    let sheet: Sheet
    let calc: SheetCalc

    final class Box: UIView {
        var chart: SheetChart?
        var content: SheetChart.Content?
        override func draw(_ rect: CGRect) {
            guard let ctx = UIGraphicsGetCurrentContext(), let chart, let content else { return }
            SheetChartRender.draw(chart, content, in: bounds, ctx: ctx)
        }
    }

    func makeUIView(context: Context) -> Box {
        let v = Box()
        v.backgroundColor = .clear
        v.isOpaque = false
        v.contentMode = .redraw
        v.overrideUserInterfaceStyle = .light
        return v
    }

    func updateUIView(_ v: Box, context: Context) {
        v.chart = chart
        v.content = chart.content(sheet, calc)
        v.setNeedsDisplay()
    }
}

// MARK: - Eingabefeld

/// Eingabezeile: was hier getippt wird, steht zugleich in der aktiven Zelle. Eingabe uebernimmt und geht eine Zeile
/// tiefer, Tab eine Spalte weiter, Esc verwirft.
struct SheetFormulaField: UIViewRepresentable {
    @ObservedObject var model: SheetEditorModel

    final class Field: UITextField {
        var onTab: ((Bool) -> Void)?
        var onEscape: (() -> Void)?

        override var keyCommands: [UIKeyCommand]? {
            let tab = UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(tabbed))
            let back = UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(tabbedBack))
            let esc = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escaped))
            for c in [tab, back, esc] { c.wantsPriorityOverSystemBehavior = true }
            return [tab, back, esc]
        }

        @objc private func tabbed() { onTab?(false) }
        @objc private func tabbedBack() { onTab?(true) }
        @objc private func escaped() { onEscape?() }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        let model: SheetEditorModel
        init(_ model: SheetEditorModel) { self.model = model }

        /// Ohne angeschlossene Tastatur bleibt die Bildschirmtastatur nach "Eingabe" offen und die naechste Zelle ist dran
        static var hasHardwareKeyboard: Bool { GCKeyboard.coalesced != nil }

        @objc func changed(_ field: UITextField) { model.editing = field.text ?? "" }

        func textFieldDidBeginEditing(_ field: UITextField) {
            if !model.isEditing { model.beginEditing() }
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            model.commitEditing(dCol: 0, dRow: 1)
            if !Self.hasHardwareKeyboard { model.beginEditing() }
            return false
        }

        func textFieldDidEndEditing(_ field: UITextField) {
            if model.isEditing { model.commitEditing() }
        }

        func tab(back: Bool) {
            model.commitEditing(dCol: back ? -1 : 1, dRow: 0)
            if !Self.hasHardwareKeyboard { model.beginEditing() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model) }

    func makeUIView(context: Context) -> Field {
        let f = Field()
        f.delegate = context.coordinator
        f.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        f.font = .systemFont(ofSize: 16)
        f.autocorrectionType = .no
        f.autocapitalizationType = .none
        f.spellCheckingType = .no
        f.smartQuotesType = .no
        f.smartDashesType = .no
        f.smartInsertDeleteType = .no
        f.keyboardType = .numbersAndPunctuation
        f.returnKeyType = .next
        f.placeholder = "Text, Zahl oder =Formel"
        f.clearButtonMode = .never
        f.accessibilityIdentifier = "sheet.field"
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let c = context.coordinator
        f.onTab = { [weak c] back in c?.tab(back: back) }
        f.onEscape = { [weak model] in model?.cancelEditing() }
        model.insertAtCursor = { [weak f, weak model] text in
            guard let f else { return }
            f.insertText(text)
            model?.editing = f.text ?? ""
        }
        return f
    }

    func updateUIView(_ f: Field, context: Context) {
        let wanted = model.editing ?? model.activeRaw
        if f.text != wanted { f.text = wanted }
        let editing = model.isEditing
        // nicht mitten in der Aktualisierung der Ansicht: Fokus aendern loest Rueckrufe aus, die das Modell aendern
        DispatchQueue.main.async { [weak f, weak model] in
            guard let f, let model, model.isEditing == editing else { return }
            if editing, !f.isFirstResponder, f.window != nil { f.becomeFirstResponder() }
            if !editing, f.isFirstResponder { f.resignFirstResponder() }
        }
    }
}
