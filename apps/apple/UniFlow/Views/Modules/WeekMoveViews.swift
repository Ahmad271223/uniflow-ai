import SwiftUI
import UniFlowCore

// Wochen von Hand (07.11.2026, Vorgabe des Inhabers fuer Version 1.0): Dokumente in eine andere Lehrwoche oder einen
// eigenen Abschnitt verschieben (Kontextmenue "In Woche verschieben …", Ziehen auf einen Wochenblock, Mehrfachauswahl),
// eigene Abschnitte je Modul anlegen, umbenennen, ordnen, loeschen, "Zurueck auf automatisch". Daten und Regeln im Kern
// (`ModuleSections`, `WeekAssignmentEndpoints`): POST /api/files/week, /api/modules/{id}/sections. Nur lokal (der
// PC-Server kennt das nicht). Dieselben Bausteine im Moduldetail (ModulesPage) und im Regal (LibraryShelf).

/// Eine waehlbare Woche aus `week_choices` (Moduldetail, Regal, GET /api/modules/{id}/sections)
struct WeekChoice: Identifiable, Equatable, Hashable {
    let week: Int
    let label: String
    let custom: Bool
    var id: Int { week }

    init(week: Int, label: String, custom: Bool = false) { self.week = week; self.label = label; self.custom = custom }

    init(_ j: JSONValue) {
        week = j.i("week") ?? 0
        label = j.s("label") ?? ""
        custom = j["custom"]?.bool ?? false
    }

    static func list(_ j: JSONValue?) -> [WeekChoice] { (j?.array ?? []).map(WeekChoice.init) }

    /// Nummer eines Abschnitts, nil fuer Lehrwochen
    var sectionID: Int? { ModuleSections.sectionID(week: week) }
}

/// Aufrufe und Texte
enum WeekMove {
    /// Ziehen: ein Text mit allen Datei-IDs (eine je Zeile); andere Texte (Lernblocks "pkg:…") werden nicht angenommen
    static let dragPrefix = "uniflow-files:"

    static func payload(_ ids: [String]) -> String { dragPrefix + ids.joined(separator: "\n") }

    static func ids(from items: [String]) -> [String] {
        var out: [String] = []
        for item in items where item.hasPrefix(dragPrefix) {
            out += item.dropFirst(dragPrefix.count).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        }
        return Array(NSOrderedSet(array: out)) as? [String] ?? out
    }

    static func move(_ api: APIClient, ids: [String], week: Int) async throws {
        _ = try await api.value("/api/files/week", method: "POST", body: ["file_ids": .array(ids.map(JSONValue.string)), "week": .number(Double(week))])
    }

    static func reset(_ api: APIClient, ids: [String]) async throws {
        _ = try await api.value("/api/files/week", method: "POST", body: ["file_ids": .array(ids.map(JSONValue.string)), "auto": true])
    }

    static func count(_ n: Int) -> String { n == 1 ? "1 Dokument" : "\(n) Dokumente" }

    /// "2 Dokumente → Woche 7"
    static func movedText(_ n: Int, to label: String) -> String { "\(count(n)) → \(label.components(separatedBy: " · ").first ?? label)" }

    static let resetText = "Zurück auf automatisch"
    static let menuTitle = "In Woche verschieben …"
    static let newSectionTitle = "Neuer Abschnitt …"
    static let manualHint = "Woche von Hand gesetzt"
}

// MARK: - Kontextmenue

/// Eintraege fuer ein Kontextmenue oder ein Menue in der Auswahlleiste: Untermenue "In Woche verschieben …" mit allen
/// Wochen des Moduls (die aktuelle mit Haken) und "Neuer Abschnitt …", dazu "Zurück auf automatisch", wenn die Woche
/// von Hand gesetzt ist. `done` laeuft nach einer gelungenen Aenderung (neu laden).
struct FileWeekMenuItems: View {
    let fileIDs: [String]
    let choices: [WeekChoice]
    var current: Int? = nil
    var manual = false
    var moduleID: Int? = nil
    let done: () -> Void
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var overlay: UFOverlay

    var body: some View {
        Menu {
            ForEach(choices) { c in
                Button { Task { await move(c) } } label: {
                    if c.week == current { Label(c.label, systemImage: "checkmark") } else { Text(c.label) }
                }
            }
            if let moduleID {
                Divider()
                Button { overlay.modal { SectionEditDialog(moduleID: moduleID, fileIDs: fileIDs, done: done) } } label: {
                    Label(WeekMove.newSectionTitle, systemImage: "plus")
                }
            }
        } label: {
            Label(WeekMove.menuTitle, systemImage: "calendar")
        }
        if manual {
            Button { Task { await reset() } } label: { Label(WeekMove.resetText, systemImage: "arrow.uturn.backward") }
        }
    }

    private func move(_ c: WeekChoice) async {
        guard let api = session.api, !fileIDs.isEmpty else { return }
        if await toast.attempt("Verschieben", { try await WeekMove.move(api, ids: fileIDs, week: c.week) }) {
            toast.show(WeekMove.movedText(fileIDs.count, to: c.label))
            done()
        }
    }

    private func reset() async {
        guard let api = session.api, !fileIDs.isEmpty else { return }
        if await toast.attempt("Zurücksetzen", { try await WeekMove.reset(api, ids: fileIDs) }) {
            toast.show("Wieder automatisch zugeordnet")
            done()
        }
    }
}

// MARK: - Dialog "In Woche verschieben" (Bibliothek: Wochenliste wird geladen)

/// Wochenliste als Dialog, wenn die Wochen nicht schon in der Ansicht stecken (Menue eines Dokuments in Dokumente &
/// Notizen): laedt GET /api/modules/{id}/sections und zeigt jede Woche als Zeile; antippen verschiebt.
struct MoveToWeekDialog: View {
    let fileIDs: [String]
    let moduleID: Int
    var current: Int? = nil
    /// nil: unbekannt, dann wird "Zurück auf automatisch" trotzdem angeboten
    var manual: Bool? = nil
    var done: () -> Void = {}
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var overlay: UFOverlay
    @Environment(\.ufClose) private var close
    @State private var choices: [WeekChoice]?
    @State private var error: String?

    var body: some View {
        UFDialog(WeekMove.menuTitle, icon: "calendar") {
            if let error {
                Text(error).ufFont(13.6).foregroundStyle(UF.bad)
            } else if let choices {
                Text(fileIDs.count == 1 ? "Das Dokument kommt dauerhaft in diese Woche; der nächste Abgleich ändert das nicht."
                     : "\(WeekMove.count(fileIDs.count)) kommen dauerhaft in diese Woche; der nächste Abgleich ändert das nicht.")
                    .ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true).padding(.bottom, 8)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(choices) { c in
                            Button { Task { await move(c) } } label: {
                                HStack(spacing: 8) {
                                    if c.custom { UFIcon("layers", size: 14).foregroundStyle(UF.text2) }
                                    Text(c.label).ufFont(14.5, c.week == current ? 650 : 450).foregroundStyle(UF.text)
                                    Spacer(minLength: 0)
                                    if c.week == current { UFIcon("check", size: 15).foregroundStyle(UF.accentText) }
                                }
                                .padding(.vertical, 10).padding(.horizontal, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(ModuleRowPressStyle())
                            .ufBorderBottom(c.id != choices.last?.id)
                            .accessibilityLabel(c.label + (c.week == current ? ", aktuell" : ""))
                            .accessibilityIdentifier("weekMove.choice.\(c.week)")
                        }
                    }
                }
                .frame(maxHeight: 420)
            } else {
                UFSkeleton().frame(height: 160)
            }
        } foot: {
            if manual != false {
                UFButton(WeekMove.resetText, icon: "rotate") { Task { await reset() } }
                    .accessibilityIdentifier("weekMove.reset")
            }
            UFButton(WeekMove.newSectionTitle, icon: "plus") {
                close()
                overlay.modal { SectionEditDialog(moduleID: moduleID, fileIDs: fileIDs, done: done) }
            }
            UFButton("Abbrechen") { close() }
        }
        .task { await load() }
    }

    private func load() async {
        guard let api = session.api else { error = "Nicht mit dem Server verbunden."; return }
        do {
            choices = WeekChoice.list(try await api.value("/api/modules/\(moduleID)/sections")["choices"])
        } catch { self.error = "Wochen ließen sich nicht laden: \(error.localizedDescription)" }
    }

    private func move(_ c: WeekChoice) async {
        guard let api = session.api else { return }
        if await toast.attempt("Verschieben", { try await WeekMove.move(api, ids: fileIDs, week: c.week) }) {
            close()
            toast.show(WeekMove.movedText(fileIDs.count, to: c.label))
            done()
        }
    }

    private func reset() async {
        guard let api = session.api else { return }
        if await toast.attempt("Zurücksetzen", { try await WeekMove.reset(api, ids: fileIDs) }) {
            close()
            toast.show("Wieder automatisch zugeordnet")
            done()
        }
    }
}

// MARK: - Abschnitt anlegen oder umbenennen

/// Neuer Abschnitt (mit `fileIDs`: die Dokumente kommen gleich hinein) oder einen bestehenden umbenennen und hinter
/// eine andere Woche setzen. `anchors`: die Wochen, hinter die er kann (ohne Abschnitte); fehlen sie, werden sie geladen.
struct SectionEditDialog: View {
    let moduleID: Int
    var section: JSONValue? = nil
    var fileIDs: [String] = []
    var anchors: [WeekChoice]? = nil
    var done: () -> Void = {}
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @Environment(\.ufClose) private var close
    @State private var name = ""
    @State private var after = ModuleSections.topAnchor
    @State private var options: [WeekChoice] = []
    @State private var loaded = false
    @State private var saving = false

    private var editing: Bool { section != nil }

    var body: some View {
        UFDialog(editing ? "Abschnitt umbenennen" : "Neuer Abschnitt", icon: "layers") {
            Text("Ein eigener Abschnitt steht wie eine Woche im Modul, z. B. „Woche 7b Klausurvorbereitung“, „Altklausuren“ oder „Allgemein“.")
                .ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true).padding(.bottom, 10)
            UFField("Name") { UFTextInput("z. B. Klausurvorbereitung", text: $name) }
            UFField("Einordnen nach") {
                UFSelect(options: [(ModuleSections.topAnchor, "Ganz oben")] + options.map { ($0.week, $0.label) }, selection: $after, fill: true)
                    .accessibilityLabel("Einordnen nach")
            }
            if !fileIDs.isEmpty {
                Text(fileIDs.count == 1 ? "Das Dokument kommt gleich in den neuen Abschnitt." : "\(WeekMove.count(fileIDs.count)) kommen gleich in den neuen Abschnitt.")
                    .ufFont(13.12).foregroundStyle(UF.muted).padding(.top, 8)
            }
        } foot: {
            UFButton("Abbrechen") { close() }
            UFButton(editing ? "Speichern" : "Anlegen", kind: .primary) { Task { await save() } }
                .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("section.save")
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            name = section?.s("name") ?? ""
            after = section?.i("after_week") ?? ModuleSections.topAnchor
            if let anchors { options = anchors.filter { !$0.custom } }
        }
        .task {
            guard anchors == nil, let api = session.api, let v = try? await api.value("/api/modules/\(moduleID)/sections") else { return }
            options = WeekChoice.list(v["choices"]).filter { !$0.custom }
        }
    }

    private func save() async {
        guard let api = session.api else { return }
        saving = true
        defer { saving = false }
        let body: JSONValue = ["name": .string(name.trimmingCharacters(in: .whitespaces)), "after_week": .number(Double(after)),
                               "file_ids": .array(fileIDs.map(JSONValue.string))]
        let ok = await toast.attempt(editing ? "Umbenennen" : "Abschnitt anlegen") {
            if let sid = section?.i("id") {
                _ = try await api.value("/api/modules/\(moduleID)/sections/\(sid)", method: "PATCH", body: body)
            } else {
                _ = try await api.value("/api/modules/\(moduleID)/sections", method: "POST", body: body)
            }
        }
        if ok {
            close()
            toast.show(editing ? "Gespeichert" : fileIDs.isEmpty ? "Abschnitt angelegt" : WeekMove.movedText(fileIDs.count, to: name))
            done()
        }
    }
}

// MARK: - Abschnitte ordnen

/// Alle Wochenbloecke des Moduls in ihrer Reihenfolge; eigene Abschnitte lassen sich nach oben/unten schieben,
/// umbenennen und loeschen (die Dokumente darin gehen zurueck auf automatisch).
struct SectionsManageDialog: View {
    let moduleID: Int
    var done: () -> Void = {}
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var overlay: UFOverlay
    @Environment(\.ufClose) private var close
    @State private var weeks: [JSONValue]?
    @State private var choices: [WeekChoice] = []
    @State private var error: String?
    @State private var changed = false

    var body: some View {
        UFDialog("Wochen & Abschnitte", icon: "layers") {
            if let error {
                Text(error).ufFont(13.6).foregroundStyle(UF.bad)
            } else if let weeks {
                Text("Eigene Abschnitte stehen zwischen den Lehrwochen. Reihenfolge mit den Pfeilen; Löschen legt die Dokumente wieder automatisch ein.")
                    .ufFont(13.12).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true).padding(.bottom, 8)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Row.rows(weeks, key: "week")) { row in blockRow(row.value, last: row.id == Row.rows(weeks, key: "week").last?.id) }
                    }
                }
                .frame(maxHeight: 440)
            } else {
                UFSkeleton().frame(height: 160)
            }
        } foot: {
            UFButton(WeekMove.newSectionTitle, icon: "plus") {
                overlay.modal { SectionEditDialog(moduleID: moduleID, anchors: choices, done: { changed = true; Task { await load() } }) }
            }
            .accessibilityIdentifier("sections.new")
            UFButton("Fertig", kind: .primary) { close(); if changed { done() } }
        }
        .task { await load() }
    }

    private func blockRow(_ w: JSONValue, last: Bool) -> some View {
        let custom = w["custom"]?.bool == true
        let sid = w.i("section_id") ?? 0
        return HStack(spacing: 8) {
            UFIcon(custom ? "layers" : "calendar", size: 14).foregroundStyle(custom ? UF.accentText : UF.muted).frame(width: 20)
            Text(w.s("label") ?? "").ufFont(14.5, custom ? 600 : 450).foregroundStyle(UF.text).lineLimit(1)
            Text("\(w.i("count") ?? 0)").ufFont(12.48).monospacedDigit().foregroundStyle(UF.muted)
            Spacer(minLength: 0)
            if custom {
                UFButton(icon: "chevron-left", kind: .ghost, size: .small) { Task { await move(sid, up: true) } }
                    .rotationEffect(.degrees(90)).accessibilityLabel("Nach oben").accessibilityIdentifier("section.up.\(sid)")
                UFButton(icon: "chevron-right", kind: .ghost, size: .small) { Task { await move(sid, up: false) } }
                    .rotationEffect(.degrees(90)).accessibilityLabel("Nach unten").accessibilityIdentifier("section.down.\(sid)")
                UFButton(icon: "pencil", kind: .ghost, size: .small) {
                    overlay.modal { SectionEditDialog(moduleID: moduleID, section: w.merged(["id": .number(Double(sid)), "name": w["label"] ?? .null]),
                                                      anchors: choices, done: { changed = true; Task { await load() } }) }
                }
                .accessibilityLabel("Umbenennen").accessibilityIdentifier("section.rename.\(sid)")
                UFButton(icon: "trash", kind: .ghost, size: .small) { Task { await remove(sid, label: w.s("label") ?? "") } }
                    .accessibilityLabel("Löschen").accessibilityIdentifier("section.delete.\(sid)")
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 4)
        .ufBorderBottom(!last)
    }

    private func load() async {
        guard let api = session.api else { error = "Nicht mit dem Server verbunden."; return }
        do {
            let d = try await api.value("/api/modules/\(moduleID)")
            weeks = d.list("weeks")
            choices = WeekChoice.list(d["week_choices"])
            // after_week der Abschnitte fuer den Umbenennen-Dialog
            let sections = d.list("sections")
            weeks = weeks?.map { w in
                guard let sid = w.i("section_id"), let s = sections.first(where: { $0.i("id") == sid }) else { return w }
                return w.merged(["after_week": s["after_week"] ?? .null])
            }
            error = nil
        } catch { self.error = "Ließ sich nicht laden: \(error.localizedDescription)" }
    }

    private func move(_ sid: Int, up: Bool) async {
        guard let api = session.api else { return }
        if await toast.attempt("Ordnen", { _ = try await api.value("/api/modules/\(moduleID)/sections/\(sid)/move", method: "POST",
                                                                   body: ["direction": .string(up ? "up" : "down")]) }) {
            changed = true
            await load()
        }
    }

    private func remove(_ sid: Int, label: String) async {
        guard let api = session.api else { return }
        guard await overlay.confirm("„\(label)“ löschen? Die Dokumente darin werden wieder automatisch zugeordnet.") else { return }
        if await toast.attempt("Löschen", { _ = try await api.value("/api/modules/\(moduleID)/sections/\(sid)", method: "DELETE") }) {
            changed = true
            await load()
        }
    }
}

extension JSONValue {
    /// Objekt mit weiteren Schluesseln (fuer Dialoge, die eine Zeile um Felder ergaenzen)
    func merged(_ extra: [String: JSONValue]) -> JSONValue {
        var o = object ?? [:]
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }
}

/// Auswahlleiste im Moduldetail: Zahl der gewaehlten Dokumente, "In Woche verschieben …", "Zurück auf automatisch",
/// "Fertig"
struct WeekSelectionBar: View {
    let moduleID: Int
    let selected: [String]
    let choices: [WeekChoice]
    let anyManual: Bool
    let done: () -> Void
    let finish: () -> Void
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter

    var body: some View {
        UFFlexWrap(gap: 8, rowGap: 8) {
            Text(selected.isEmpty ? "Dokumente antippen, um sie auszuwählen" : "\(selected.count) ausgewählt")
                .ufFont(13.6, 600).foregroundStyle(UF.text).accessibilityIdentifier("weekSelect.count")
            Menu {
                FileWeekMenuItems(fileIDs: selected, choices: choices, manual: anyManual, moduleID: moduleID, done: done)
            } label: {
                HStack(spacing: 7.2) { UFIcon("calendar", size: 14); Text(WeekMove.menuTitle) }
            }
            .buttonStyle(UFButtonStyle(kind: .primary, size: .small))
            .disabled(selected.isEmpty)
            .accessibilityLabel(WeekMove.menuTitle)
            .accessibilityIdentifier("weekSelect.menu")
            if anyManual {
                UFButton(WeekMove.resetText, icon: "rotate", size: .small) { Task { await reset() } }
                    .accessibilityIdentifier("weekSelect.reset")
            }
            UFFlexSpacer()
            UFButton("Fertig", size: .small, action: finish).accessibilityIdentifier("weekSelect.done")
        }
        .padding(.vertical, 10).padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: UF.r, style: .continuous).fill(UF.accentSoft))
        .padding(.bottom, 14.4)
    }

    private func reset() async {
        guard let api = session.api, !selected.isEmpty else { return }
        if await toast.attempt("Zurücksetzen", { try await WeekMove.reset(api, ids: selected) }) {
            toast.show("Wieder automatisch zugeordnet")
            done()
        }
    }
}

/// Ziel zum Ablegen gezogener Dokumente: ein Wochenblock oder ein Brett im Regal. Hebt den Rahmen hervor, solange etwas
/// darueber schwebt, und verschiebt beim Loslassen.
struct WeekDropTarget: ViewModifier {
    let week: Int
    let label: String
    let radius: CGFloat
    let done: () -> Void
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(UF.accent, lineWidth: 2).opacity(targeted ? 1 : 0)
                        .allowsHitTesting(false))
            .dropDestination(for: String.self) { items, _ in
                let ids = WeekMove.ids(from: items)
                guard !ids.isEmpty else { return false }
                Task { await move(ids) }
                return true
            } isTargeted: { targeted = $0 }
    }

    private func move(_ ids: [String]) async {
        guard let api = session.api else { return }
        if await toast.attempt("Verschieben", { try await WeekMove.move(api, ids: ids, week: week) }) {
            toast.show(WeekMove.movedText(ids.count, to: label))
            done()
        }
    }
}

extension View {
    /// Wochenblock bzw. Brett als Ziel fuer gezogene Dokumente (nur lokal sinnvoll)
    func ufWeekDropTarget(week: Int, label: String, radius: CGFloat = UF.r, done: @escaping () -> Void) -> some View {
        modifier(WeekDropTarget(week: week, label: label, radius: radius, done: done))
    }
}
