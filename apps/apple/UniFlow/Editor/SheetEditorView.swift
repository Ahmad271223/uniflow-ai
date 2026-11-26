import GameController
import SwiftUI
import UIKit
import UniFlowCore

/// Grosse Ansicht einer Tabelle ("Excel", 26.11.2026): oben die Eingabezeile wie in Excel (Zelle, fx, Text bzw. Formel),
/// darunter die Leiste (Fett, Farben, Zahlenformat, Rahmen, Zeilen/Spalten, Sortieren, Filter, Diagramm), das Gitter und
/// die Diagramme. Oeffnet sich ueber dem Dokument; "Fertig" schreibt die Tabelle zurueck auf die Seite.
struct SheetEditorView: View {
    @ObservedObject var model: SheetEditorModel
    /// Tabelle auf die Seite schreiben ("Fertig", App geht in den Hintergrund); `false`: hat nicht geklappt
    let onSave: (Sheet) async -> Bool
    let onClose: () -> Void

    @State private var showFilter = false
    @State private var showAI = false
    @State private var aiWish = ""
    @State private var titleChart: SheetChart?
    @State private var titleText = ""
    @State private var saving = false
    @State private var saveFailed = false
    /// Die Bildschirmtastatur ist offen: Die Diagramme machen dem Gitter Platz
    @State private var keyboardUp = false
    @State private var chartsFolded = false
    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.readOnly { readOnlyRow } else {
                formulaRow
                toolbar
            }
            Divider()
            SheetGridHost(model: model)
                .ignoresSafeArea(.container, edges: .horizontal)
                // Hinweise liegen ueber dem unteren Rand des Gitters: Es rutscht nicht, wenn einer kommt oder geht,
                // und die Buchstaben der Spalten bleiben frei
                .overlay(alignment: .bottom) { hintRow }
            if !model.sheet.charts.isEmpty, !keyboardUp { chartStrip }
        }
        .background(UF.bg.ignoresSafeArea())
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            // Zwischenstand: Geht die App im Hintergrund verloren, steht die Arbeit schon auf der Seite
            model.commitEditing()
            let s = model.sheet
            if model.changed { Task { if await onSave(s) { model.markSaved(s) } } }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
            let h = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect)?.height ?? 0
            keyboardUp = h > 120          // nicht bei der schmalen Leiste einer angeschlossenen Tastatur
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardUp = false }
        .onChange(of: showAI) { _, open in
            model.dialogOpen = open || titleChart != nil
            // Fehler der KI auch zeigen, wenn das Feld schon zu ist
            if !open, let e = model.aiError { model.notice = e; model.aiError = nil }
        }
        .onChange(of: model.aiError) { _, e in
            if let e, !showAI { model.notice = e; model.aiError = nil }
        }
        .onChange(of: titleChart?.id) { _, id in model.dialogOpen = showAI || id != nil }
        .alert("Die Tabelle konnte nicht gesichert werden", isPresented: $saveFailed) {
            Button("Noch einmal versuchen") { finish() }
            Button("Ohne Sichern schließen", role: .destructive) { onClose() }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Die Seite, auf der die Tabelle liegt, ist gerade nicht erreichbar. Deine Änderungen stehen noch hier.")
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
            if !model.readOnly {
                Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 34, height: 34) }
                    .disabled(!model.canUndo && !model.isEditing).accessibilityLabel("Widerrufen").accessibilityIdentifier("sheet.undo")
                Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward").frame(width: 34, height: 34) }
                    .disabled(!model.canRedo).accessibilityLabel("Wiederholen").accessibilityIdentifier("sheet.redo")
            }
            Button { finish() } label: {
                Group {
                    if saving { ProgressView().tint(.white) } else { Text(model.readOnly ? "Schließen" : "Fertig").ufFont(15, 600) }
                }
                .padding(.horizontal, 14).padding(.vertical, 7)
            }
                .background(Capsule().fill(UF.accent))
                .foregroundStyle(.white)
                .disabled(saving)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityIdentifier("sheet.done")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(UF.surface)
    }

    /// "Fertig": erst sichern, dann schliessen - schlaegt das Sichern fehl, bleibt die Tabelle offen
    private func finish() {
        guard !saving else { return }
        model.cancelAI()
        model.commitEditing()
        guard model.changed else { onClose(); return }
        saving = true
        let s = model.sheet
        Task {
            let ok = await onSave(s)
            saving = false
            if ok { model.markSaved(s); onClose() } else { saveFailed = true }
        }
    }

    private var readOnlyRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill").font(.system(size: 12)).foregroundStyle(UF.muted)
            Text("Nur ansehen. Bearbeiten, Formeln und Diagramme gibt es mit Pro AI.").ufFont(12.5).foregroundStyle(UF.text2)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(UF.surface)
        .accessibilityIdentifier("sheet.readOnly")
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
        if model.aiBusy, !showAI {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Die KI arbeitet an deiner Tabelle …").ufFont(12.5).foregroundStyle(UF.text2)
                Spacer()
                Button("Abbrechen") { model.cancelAI() }.ufFont(12.5, 600)
            }
            .padding(.horizontal, 14).padding(.vertical, 5)
            .background(UF.surface)
            .accessibilityIdentifier("sheet.ai.busy")
        } else if let n = model.notice {
            hint(n, UF.warn).task(id: n) {
                try? await Task.sleep(nanoseconds: UInt64(max(3.5, Double(n.count) / 14) * 1_000_000_000))
                if model.notice == n { model.notice = nil }
            }
        } else if let n = model.info {
            // was die KI gebaut hat: bleibt laenger stehen, damit man es lesen kann
            hint(n, UF.accentText).task(id: n) {
                try? await Task.sleep(nanoseconds: UInt64(max(6, Double(n.count) / 14) * 1_000_000_000))
                if model.info == n { model.info = nil }
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
        .overlay(alignment: .top) { Rectangle().fill(UF.line).frame(height: 1) }
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
                if model.askAI != nil {
                    Button { showAI = true } label: {
                        Label("KI", systemImage: "sparkles").labelStyle(.titleAndIcon).ufFont(13.5, 600)
                            .padding(.horizontal, 10).frame(height: 32)
                            .background(RoundedRectangle(cornerRadius: 8).fill(UF.accentSoft))
                            .foregroundStyle(UF.accentText)
                    }
                    .accessibilityLabel("KI hilft bei der Tabelle").accessibilityIdentifier("sheet.ai")
                    .popover(isPresented: $showAI) { aiPanel }
                    sep
                }
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

    // MARK: KI-Hilfe

    private var aiPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(UF.accentText)
                Text("KI hilft bei der Tabelle").ufFont(15, 600).foregroundStyle(UF.text)
            }
            Text("Schreib, was du brauchst: eine neue Tabelle, eine Formel oder ein Diagramm. Die KI sieht deine Tabelle und baut es hinein.")
                .ufFont(13, lh: 1.4).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
            TextField("z. B. Notenübersicht mit Schnitt", text: $aiWish, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
                .disabled(model.aiBusy)
                .accessibilityIdentifier("sheet.ai.wish")
                .onChange(of: aiWish) { _, w in
                    // laenger geht nicht mit: lieber gleich sichtbar begrenzen als still abschneiden
                    if w.count > SheetAI.wishLimit { aiWish = String(w.prefix(SheetAI.wishLimit)) }
                }
            if aiWish.count > SheetAI.wishLimit - 40 {
                Text("Noch \(max(0, SheetAI.wishLimit - aiWish.count)) Zeichen").ufFont(11.5).foregroundStyle(UF.muted)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(SheetAI.examples, id: \.self) { e in
                    Button { aiWish = e } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "text.badge.plus").font(.system(size: 12))
                            Text(e).ufFont(12.5).multilineTextAlignment(.leading)
                        }
                        .foregroundStyle(UF.accentText)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.aiBusy)
                }
            }
            if let e = model.aiError {
                Text(e).ufFont(12.5, lh: 1.35).foregroundStyle(UF.bad).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("sheet.ai.error")
            }
            HStack(alignment: .center, spacing: 10) {
                Text("Deine Tabelle und dein Wunsch gehen an die KI. Das zählt wie eine Frage an die KI.")
                    .ufFont(11.5, lh: 1.35).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if model.aiBusy {
                    Button("Abbrechen") { model.cancelAI() }.ufFont(13, 600).accessibilityIdentifier("sheet.ai.cancel")
                }
                Button {
                    model.startAI(wish: aiWish) { ok in
                        if ok {
                            showAI = false
                            aiWish = ""
                        }
                    }
                } label: {
                    Group {
                        if model.aiBusy { ProgressView().tint(.white) } else { Text("Los").ufFont(14, 600) }
                    }
                    .frame(minWidth: 44)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                }
                .background(Capsule().fill(UF.accent))
                .foregroundStyle(.white)
                .disabled(model.aiBusy || aiWish.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(aiWish.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
                .accessibilityLabel("KI starten").accessibilityIdentifier("sheet.ai.go")
            }
        }
        .padding(14)
        .frame(minWidth: 260, idealWidth: 360, maxWidth: 360)
        .presentationCompactAdaptation(.popover)
        .accessibilityIdentifier("sheet.ai.panel")
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
            if model.sheet.filters.keys.contains(where: { $0 != model.active.col }) {
                Divider()
                Button("Filter in allen Spalten aufheben") { model.clearFilter(all: true) }
                    .ufFont(13, 600).padding(12).accessibilityIdentifier("sheet.filter.clearAll")
            }
        }
        .frame(width: 280)
        .presentationCompactAdaptation(.popover)
        .accessibilityIdentifier("sheet.filterList")
    }

    // MARK: Diagramme

    private var chartStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button { chartsFolded.toggle() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: chartsFolded ? "chevron.right" : "chevron.down").font(.system(size: 11, weight: .semibold))
                        Text(model.sheet.charts.count == 1 ? "1 Diagramm" : "\(model.sheet.charts.count) Diagramme").ufFont(13, 600)
                    }
                    .foregroundStyle(UF.text2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(chartsFolded ? "Diagramme zeigen" : "Diagramme einklappen").accessibilityIdentifier("sheet.charts.fold")
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
            if !chartsFolded {
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
        // gewoehnliche Tastatur: Faecher und Namen werden so oft getippt wie Zahlen
        f.keyboardType = .default
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
