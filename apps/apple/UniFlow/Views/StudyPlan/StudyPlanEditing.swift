import SwiftUI
import UniFlowCore

// Studienverlauf selbst gestalten (Inhaber 05.11.2026, docs/STUDIENVERLAUF-2026-11-04.md, Abschnitte "Wahlbereiche"
// und "Eigene Lage"): offene Plaetze je Semester fuer Wahlbereiche ("Vertiefung: 1 von 3 Modulen gewählt",
// "Studium Generale (4 LP)", "Schwerpunkt wählen"), Auswahl der erlaubten Module mit LP, Turnus, Semester und Kurztext,
// eigene Eintraege, Stand je Bereich, Module verschieben (Ziehen auf dem Board, "Verschieben nach …" im Menue, in
// den Details und fuer VoiceOver), "Nicht belegen", "Zurück in den Plan", "Plan zurücksetzen". Die Ansichten rechnen
// nichts selbst; sie schicken nur die Aenderung (StudyPlanEdit) und lesen den Plan neu.

/// Was am Modul geaendert werden kann
enum StudyPlanModuleAction: Equatable {
    case move, drop, resetPlacement, replace
}

/// offenes Bearbeitungsblatt
enum StudyPlanEditRef: Identifiable, Equatable {
    case move(String)
    case choose(StudyPlanSlot?)
    /// gewaehltes Wahlmodul gegen ein anderes desselben Bereichs tauschen
    case replace(String)
    case areas

    var id: String {
        switch self {
        case .move(let m): return "move-\(m)"
        case .choose(let s): return "choose-\(s?.id ?? "frei")"
        case .replace(let m): return "replace-\(m)"
        case .areas: return "areas"
        }
    }
}

/// Ziehen und Ablegen auf dem Board: die Spalte meldet (Modul-ids, Semester) hierher, die Seite verschiebt. Eigene
/// Klasse, damit Tests das Ablegen ohne echte Geste ausloesen koennen.
@MainActor
final class StudyPlanDropHub {
    var perform: (([String], String) async -> Bool)?

    nonisolated init() {}

    @discardableResult
    func drop(_ ids: [String], on term: String) async -> Bool { await perform?(ids, term) ?? false }
}

// MARK: - Platz im Semester

struct StudyPlanSlotCard: View {
    let slot: StudyPlanSlot
    let plan: StudyPlan
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                UFIcon(slot.isTrack ? "layers" : "plus", size: 15)
                    .foregroundStyle(UF.accentText)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.mix(UF.accent, 0.12, UF.surface)))
                VStack(alignment: .leading, spacing: 5) {
                    Text(StudyPlanText.slotTitle(slot)).ufFont(13.6, 600, lh: 1.3).foregroundStyle(UF.text)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    UFFlexWrap(gap: 5, rowGap: 5) {
                        if !slot.isTrack { StudyPlanTag(text: StudyPlanText.kind(slot.areaKind), pair: StudyPlanText.kindPair(slot.areaKind)) }
                        if let t = StudyPlanText.typeLabel(slot.type) { StudyPlanTag(text: t, pair: nil) }
                    }
                    Text(StudyPlanText.slotLine(slot, plan: plan)).ufFont(12, lh: 1.35).foregroundStyle(UF.text2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.mix(UF.surface, 0.6, UF.bg)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.mix(UF.accent, 0.45, UF.line),
                                                                     style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(StudyPlanPressStyle())
        .accessibilityLabel(StudyPlanText.accessibility(slot, plan: plan))
        .accessibilityHint(slot.isTrack ? "Wählt die Richtung" : "Zeigt die Module, die du hier wählen kannst")
        .accessibilityIdentifier("studyplan.slot.\(slot.id)")
    }
}

// MARK: - Wahlbereiche (Stand je Bereich)

struct StudyPlanAreasCard: View {
    @Environment(\.hildesheim) private var hildesheim
    @Environment(\.hsh) private var hsh
    let plan: StudyPlan
    let chooseTrack: (StudyPlanSlot) -> Void
    let restore: (StudyPlanOption) -> Void

    private var shown: [StudyPlanArea] {
        plan.areas.filter { $0.active && $0.type != "abschluss"
            && ($0.target != nil || $0.modulesRequired != nil || $0.lpDone + $0.lpPlanned > 0) }
            .sorted { ($0.choice ? 0 : 1, 0) < ($1.choice ? 0 : 1, 0) }
    }

    var body: some View {
        UFCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    UFIcon("layers", size: 16).foregroundStyle(UF.text2)
                    Text("Bereiche und Wahl").ufFont(15.2, 650, lh: 1.3).foregroundStyle(UF.text)
                        .accessibilityAddTraits(.isHeader)
                }
                ForEach(plan.groups) { g in groupRow(g) }
                UFGridLayout(spacing: 10, minWidth: 250) {
                    ForEach(shown) { a in areaRow(a) }
                }
                if !plan.excluded.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Nicht belegt").ufFont(12.8, 650).foregroundStyle(UF.text2)
                        ForEach(plan.excluded) { o in
                            HStack(spacing: 8) {
                                Text("\(o.title) · \(StudyPlanText.lp(o.lp))").ufFont(13.12).foregroundStyle(UF.text)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                UFButton("Zurück in den Plan", icon: "undo", size: .small) { restore(o) }
                                    .accessibilityLabel("\(o.title) zurück in den Plan")
                                    .accessibilityIdentifier("studyplan.restore.\(o.id)")
                            }
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("studyplan.areas")
    }

    private func groupRow(_ g: StudyPlanGroup) -> some View {
        let name = plan.area(g.chosen)?.name
        let text = name.map { "\(g.label): \($0)" + (g.auto ? " (\(StudyPlanText.gradeSourceFrom(hildesheim: hildesheim != nil, hsh: hsh != nil)))" : "") } ?? "\(g.label): noch nicht gewählt"
        let slot = StudyPlanSlot(["id": .string("gruppe-\(g.id)"), "kind": "track", "title": .string("\(g.label) wählen"),
                                  "group": .string(g.id), "areas": .array(g.options.map(JSONValue.string))], term: "")
        return HStack(spacing: 8) {
            Text(text).ufFont(13.6, 600, lh: 1.3).foregroundStyle(name == nil ? UF.warnText : UF.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            UFButton(name == nil ? "Wählen" : "Ändern", size: .small) { chooseTrack(slot) }
                .accessibilityLabel(name == nil ? "\(g.label) wählen" : "\(g.label) ändern")
                .accessibilityIdentifier("studyplan.group.\(g.id)")
        }
    }

    private func areaRow(_ a: StudyPlanArea) -> some View {
        let progress = StudyPlanText.areaProgress(a)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(a.name).ufFont(13.12, 600, lh: 1.3).foregroundStyle(UF.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                StudyPlanTag(text: StudyPlanText.kind(a.kind), pair: StudyPlanText.kindPair(a.kind))
            }
            if let value = progress.value {
                UFProgress(value: value, ok: progress.done).accessibilityHidden(true)
            }
            Text(StudyPlanText.areaLine(a)).ufFont(12, lh: 1.35).foregroundStyle(UF.text2).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(UF.surface2))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(a.name), \(StudyPlanText.kind(a.kind)), \(StudyPlanText.areaLine(a))")
        .accessibilityIdentifier("studyplan.area.\(a.id)")
    }
}

// MARK: - Rueckmeldung

struct StudyPlanToast: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            UFIcon("check", size: 14)
            Text(text).ufFont(13.6, 600, lh: 1.35).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(UF.okText)
        .padding(.vertical, 10).padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.mix(UF.ok, 0.12, UF.surface)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.mix(UF.ok, 0.4, UF.line), lineWidth: 1))
        .frame(maxWidth: 640)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("studyplan.toast")
    }
}

// MARK: - Verschieben nach …

struct StudyPlanMoveSheet: View {
    let module: StudyPlanModule
    let plan: StudyPlan
    let pick: (String) -> Void
    let resetPlacement: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let here = plan.semester(of: module.id)?.term
        VStack(spacing: 0) {
            StudyPlanSheetHeader(title: "Verschieben nach …", close: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(module.title).ufFont(17.6, 650, lh: 1.3).foregroundStyle(UF.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text("\(StudyPlanText.lp(module.lp)) · \(StudyPlanText.turnusLong(module.turnus))"
                         + (module.recommended.map { " · empfohlen im \($0). Fachsemester" } ?? ""))
                        .ufFont(13.12).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: 0) {
                        ForEach(Array(plan.moveTerms.enumerated()), id: \.element) { i, term in
                            row(term, current: term == here).ufBorderBottom(i < plan.moveTerms.count - 1)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 12).fill(UF.surface))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(UF.line, lineWidth: 1))
                    if module.placed {
                        UFButton("Ins empfohlene Semester", icon: "undo") { dismiss(); resetPlacement() }
                            .accessibilityIdentifier("studyplan.move.reset")
                    }
                }
                .padding(EdgeInsets(top: 18, leading: 20, bottom: 28, trailing: 20))
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .background(UF.bg)
        .accessibilityIdentifier("studyplan.move.sheet")
    }

    private func row(_ term: String, current: Bool) -> some View {
        let sem = plan.semesters.first { $0.term == term }
        let fach = plan.fachsemester(of: term)
        let warn = StudyPlanText.turnusWarning(module.turnus, term: term)
        let lp = (sem?.lp ?? 0) + (current ? 0 : module.lp)
        return Button {
            dismiss()
            if !current { pick(term) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(term + (fach.map { " · \($0). Fachsemester" } ?? "")).ufFont(14.5, 600, lh: 1.3).foregroundStyle(UF.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(current ? "Hier liegt das Modul jetzt" : "danach \(StudyPlanText.lp(lp)) in diesem Semester")
                        .ufFont(12.48).foregroundStyle(lp > StudyPlanText.lpLimit && !current ? UF.warnText : UF.muted)
                    if let warn, !current {
                        Label { Text(warn) } icon: { UFIcon("alert", size: 12) }.ufFont(12).foregroundStyle(UF.warnText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if current { UFIcon("check", size: 15).foregroundStyle(UF.accentText) }
            }
            .padding(.vertical, 10).padding(.horizontal, 14)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel([term, fach.map { "\($0). Fachsemester" }, current ? "aktuelle Lage" : "danach \(StudyPlanText.number(lp)) Leistungspunkte",
                             current ? nil : warn].compactMap { $0 }.joined(separator: ", "))
        .accessibilityIdentifier("studyplan.move.\(term)")
    }
}

// MARK: - Modul waehlen (Platz, Hinzufuegen, Schwerpunkt)

struct StudyPlanChooserSheet: View {
    @Environment(\.hildesheim) private var hildesheim
    @Environment(\.hsh) private var hsh
    let plan: StudyPlan
    /// Platz, aus dem gewaehlt wird; nil: beliebiges Modul aus dem Katalog in ein Semester legen
    let slot: StudyPlanSlot?
    let api: APIClient?
    let choose: (StudyPlanOption, String?) -> Void
    let addCustom: (String, Double, String?, Int?) -> Void
    let chooseTrack: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var expanded: String?
    @State private var details: [String: StudyModuleDetail] = [:]
    @State private var term = ""
    @State private var customTitle = ""
    @State private var customLP = "5"

    private var title: String {
        if let slot { return slot.isTrack ? slot.title : "Modul wählen" }
        return "Modul hinzufügen"
    }

    var body: some View {
        VStack(spacing: 0) {
            StudyPlanSheetHeader(title: title, close: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let slot, slot.isTrack { tracks(slot) } else { modules }
                }
                .padding(EdgeInsets(top: 18, leading: 20, bottom: 28, trailing: 20))
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .background(UF.bg)
        .onAppear {
            if term.isEmpty { term = slot?.term.isEmpty == false ? slot!.term : (plan.currentTerm ?? plan.semesters.first?.term ?? "") }
        }
        .modifier(StudyPlanSheetSizing())
        .accessibilityIdentifier("studyplan.chooser")
    }

    // Schwerpunkt / Nebenfach

    @ViewBuilder private func tracks(_ slot: StudyPlanSlot) -> some View {
        let g = plan.groups.first { $0.id == slot.group }
        Text("Wähle eine Richtung. Ihre Module erscheinen danach als Plätze im Plan.")
            .ufFont(13.12, lh: 1.45).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
        VStack(spacing: 10) {
            ForEach(slot.areas, id: \.self) { aid in
                let a = plan.area(aid)
                Button {
                    dismiss()
                    chooseTrack(slot.group ?? "", aid)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(a?.name ?? StudyPlanText.titleFromID(aid)).ufFont(14.5, 650, lh: 1.3).foregroundStyle(UF.text)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if g?.chosen == aid { UFIcon("check", size: 15).foregroundStyle(UF.accentText) }
                        }
                        Text([a.map { "\($0.options) Module" }, (a?.lpMax ?? a?.lpRequired).map { "bis \(StudyPlanText.lp($0))" }]
                            .compactMap { $0 }.joined(separator: " · "))
                            .ufFont(12.48).foregroundStyle(UF.muted)
                        if let r = a?.rule {
                            Text(r).ufFont(12.48, lh: 1.4).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(UF.surface))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(g?.chosen == aid ? UF.accentFill : UF.line, lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel((a?.name ?? aid) + (g?.chosen == aid ? ", gewählt" : ""))
                .accessibilityIdentifier("studyplan.track.\(aid)")
            }
        }
    }

    // Module

    private var options: [StudyPlanOption] {
        let all = plan.choices(for: slot)
        let q = StudyPlanText.normalized(query)
        let hits = q.isEmpty ? all : all.filter { StudyPlanText.normalized($0.title).contains(q) }
        return hits.sorted { ($0.semester ?? 99, $0.title) < ($1.semester ?? 99, $1.title) }
    }

    @ViewBuilder private var modules: some View {
        if let slot {
            let rule = plan.area(slot.area)?.rule
            Text([StudyPlanText.slotTitle(slot), StudyPlanText.slotLine(slot, plan: plan)].joined(separator: " · "))
                .ufFont(13.6, 600, lh: 1.4).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
            if let rule { Text(rule).ufFont(12.48, lh: 1.4).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true) }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Semester").ufFont(12.8, 650).foregroundStyle(UF.text2)
                UFSelect(options: plan.moveTerms.map { ($0, $0 + (plan.fachsemester(of: $0).map { " · \($0). Fachsemester" } ?? "")) },
                         selection: $term)
                    .accessibilityLabel("Semester")
                    .accessibilityValue(term)
                    .accessibilityIdentifier("studyplan.chooser.term")
            }
        }
        UFTextField("Modul suchen", text: $query)
            .accessibilityLabel("Modul suchen")
            .accessibilityIdentifier("studyplan.chooser.search")
        let list = options
        if list.isEmpty {
            Text(slot == nil ? "Alle Module des Katalogs sind schon im Plan." : "Für diesen Platz gibt es im Katalog keine weiteren Module – trag unten einen eigenen ein.")
                .ufFont(13.12, lh: 1.45).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(list.prefix(150).enumerated()), id: \.element.id) { i, o in
                    optionRow(o).ufBorderBottom(i < min(list.count, 150) - 1)
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(UF.surface))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(UF.line, lineWidth: 1))
        }
        customBlock
    }

    private func optionRow(_ o: StudyPlanOption) -> some View {
        let open = expanded == o.id
        let target = slot?.term.isEmpty == false ? slot!.term : term
        let warn = StudyPlanText.turnusWarning(o.turnus, term: target)
        let areaName = plan.area(o.area)?.name
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                UFMotion.toggle { expanded = open ? nil : o.id }
                if !open { Task { await loadDetail(o.id) } }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(o.title).ufFont(14.5, 600, lh: 1.3).foregroundStyle(UF.text)
                            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        UFFlexWrap(gap: 5, rowGap: 5) {
                            StudyPlanTag(text: StudyPlanText.kind(o.kind), pair: StudyPlanText.kindPair(o.kind))
                            if let t = StudyPlanText.turnus(o.turnus) { StudyPlanTag(text: t, pair: nil) }
                            if let s = o.semester { StudyPlanTag(text: "\(s). Semester", pair: nil) }
                            if o.excluded { StudyPlanTag(text: "nicht belegt", pair: nil) }
                        }
                        if let areaName { Text(areaName).ufFont(12.48).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(StudyPlanText.lp(o.lp)).ufFont(13.12, 650).monospacedDigit().foregroundStyle(UF.text2).fixedSize()
                    UFIcon(open ? "chevron-down" : "chevron-right", size: 14).foregroundStyle(UF.muted)
                }
                .padding(.vertical, 10).padding(.horizontal, 14)
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel([o.title, "\(StudyPlanText.number(o.lp)) Leistungspunkte", StudyPlanText.kind(o.kind),
                                 StudyPlanText.turnus(o.turnus).map { _ in StudyPlanText.turnusLong(o.turnus) },
                                 o.semester.map { "empfohlen im \($0). Semester" }].compactMap { $0 }.joined(separator: ", "))
            .accessibilityIdentifier("studyplan.option.\(o.id)")
            if open {
                VStack(alignment: .leading, spacing: 8) {
                    if let d = details[o.id] {
                        if let e = d.exam { Text("Prüfung: \(e)").ufFont(12.8, lh: 1.4).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true) }
                        if let c = d.sections.first(where: { $0.id == "content" }) {
                            Text(String(c.text.prefix(240)) + (c.text.count > 240 ? " …" : ""))
                                .ufFont(12.8, lh: 1.45).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let warn { Label { Text(warn) } icon: { UFIcon("alert", size: 12) }.ufFont(12).foregroundStyle(UF.warnText) }
                    UFButton("In \(target) wählen", icon: "plus", kind: .primary, size: .small) {
                        dismiss()
                        choose(o, target.isEmpty ? nil : target)
                    }
                    .accessibilityIdentifier("studyplan.option.choose")
                }
                .padding(.horizontal, 14).padding(.bottom, 12)
            }
        }
    }

    private var customBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Eigener Eintrag").ufFont(13.6, 650).foregroundStyle(UF.text).accessibilityAddTraits(.isHeader)
            Text("Zum Beispiel eine Studium-generale-Veranstaltung einer anderen Fakultät. Heißt er wie \(StudyPlanText.gradeSourceIn(hildesheim: hildesheim != nil, hsh: hsh != nil)), übernimmt StudiNow Stand und Note.")
                .ufFont(12.48, lh: 1.4).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { customTitleField.frame(minWidth: 240); customLPField.frame(width: 90); customButton }
                VStack(alignment: .leading, spacing: 8) { customTitleField; HStack(spacing: 8) { customLPField.frame(width: 90); customButton } }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(UF.surface2))
    }

    private var customTitleField: some View {
        UFTextField("Titel", text: $customTitle)
            .accessibilityLabel("Titel des eigenen Eintrags")
            .accessibilityIdentifier("studyplan.custom.title")
    }

    private var customLPField: some View {
        UFTextField("LP", text: $customLP)
            .keyboardType(.decimalPad)
            .accessibilityLabel("Leistungspunkte des eigenen Eintrags")
            .accessibilityIdentifier("studyplan.custom.lp")
    }

    private var customButton: some View {
        UFButton("Hinzufügen", icon: "plus", size: .small) {
            let lp = Double(customLP.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) ?? 0
            let target = slot?.term.isEmpty == false ? slot!.term : term
            dismiss()
            addCustom(customTitle, max(0, min(60, lp)), slot?.area, plan.fachsemester(of: target))
        }
        .disabled(customTitle.trimmingCharacters(in: .whitespaces).isEmpty)
        .fixedSize()
        .accessibilityIdentifier("studyplan.custom.add")
    }

    private func loadDetail(_ id: String) async {
        guard details[id] == nil, let api, let v = try? await api.value("/api/study-plan/module/\(id)") else { return }
        details[id] = StudyModuleDetail(v)
    }
}

// MARK: - Gesamtansicht (alle Semester auf einen Blick)

/// Alle Semester und Module ohne Rollen (Inhaber 05.11.2026: „mach dass man alles auf einmal sehen kann"): je Semester
/// eine Spalte, je Modul ein kleiner Chip mit Kurzname, LP und Statusfarbe; Groesse passt sich Breite und Hoehe an
/// (quer eine Reihe, hochkant zwei). Tippen oeffnet das Detail, Ziehen auf eine Spalte verschiebt, Menue und
/// VoiceOver-Aktionen wie auf dem Board.
struct StudyPlanOverview: View {
    let plan: StudyPlan
    let semesters: [StudyPlanSemester]
    let size: CGSize
    var actions: ((StudyPlanModule, StudyPlanModuleAction) -> Void)?
    var openSlot: ((StudyPlanSlot) -> Void)?
    var dropHub: StudyPlanDropHub?
    let open: (StudyPlanModule) -> Void

    /// Reihen: quer 1, hochkant 2 (bei mehr als 4 Semestern)
    var rows: Int { size.width >= size.height || semesters.count <= 4 ? 1 : 2 }

    var body: some View {
        let perRow = max(1, Int((Double(semesters.count) / Double(rows)).rounded(.up)))
        let gap: CGFloat = 6
        let colWidth = max(60, (size.width - gap * CGFloat(perRow - 1)) / CGFloat(perRow))
        let rowHeight = max(120, (size.height - gap * CGFloat(rows - 1)) / CGFloat(rows))
        let most = semesters.map { $0.modules.count + $0.slots.count }.max() ?? 1
        // Kopf ~30 pt, Rest teilen sich die Chips (hoechstens 30 pt, mindestens 14 pt)
        let chip = min(30, max(14, (rowHeight - 34 - CGFloat(most) * 3) / CGFloat(max(1, most))))
        VStack(alignment: .leading, spacing: gap) {
            ForEach(0..<rows, id: \.self) { r in
                HStack(alignment: .top, spacing: gap) {
                    ForEach(Array(semesters.enumerated()).filter { $0.offset / perRow == r }, id: \.element.id) { _, s in
                        column(s, width: colWidth, height: rowHeight, chip: chip)
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .accessibilityIdentifier("studyplan.overview")
    }

    private func column(_ s: StudyPlanSemester, width: CGFloat, height: CGFloat, chip: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(s.fachsemester.map { "\($0)." } ?? "").ufFont(11.52, 700).foregroundStyle(UF.text2)
                Text(s.term).ufFont(11.52, 650).foregroundStyle(UF.text).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 2)
                Text(StudyPlanText.number(s.lp)).ufFont(11.52, 700).monospacedDigit()
                    .foregroundStyle(s.overloaded ? UF.warnText : UF.muted).lineLimit(1).fixedSize()
            }
            .frame(height: 26)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(StudyPlanText.accessibility(s))
            .accessibilityAddTraits(.isHeader)
            ForEach(s.modules) { m in moduleChip(m, width: width - 8, height: chip) }
            ForEach(s.slots) { sl in slotChip(sl, height: chip) }
            Spacer(minLength: 0)
        }
        .padding(4)
        .frame(width: width, height: height, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(s.current ? Color.mix(UF.accent, 0.08, UF.bg) : Color.mix(UF.surface2, 0.7, UF.bg)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(s.overloaded ? Color.mix(UF.warn, 0.6, UF.line)
                                                                 : (s.current ? Color.mix(UF.accent, 0.55, UF.line) : UF.line), lineWidth: 1))
        .modifier(StudyPlanOverviewDrop(hub: dropHub, term: s.term))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("studyplan.overview.\(s.term)")
    }

    @ViewBuilder private func moduleChip(_ m: StudyPlanModule, width: CGFloat, height: CGFloat) -> some View {
        let tone = m.status.tone
        let font = max(9.5, min(12.5, height * 0.45))
        let chip = Button { open(m) } label: {
            HStack(spacing: 3) {
                Circle().fill(tone == .neutral ? StudyPlanText.areaColor(m.area) : tone.fg).frame(width: 6, height: 6)
                Text(StudyPlanText.abbreviation(m.title, width: width - 34, font: font))
                    .ufFont(font, 600).foregroundStyle(m.status == .passed ? UF.text2 : UF.text)
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(StudyPlanText.number(m.lp)).ufFont(font * 0.92, 650).monospacedDigit().foregroundStyle(UF.muted).fixedSize()
                if !m.hints.isEmpty { UFIcon("alert", size: font * 0.9).foregroundStyle(UF.warnText) }
            }
            .padding(.horizontal, 5)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 6).fill(tone == .neutral ? UF.surface : Color.mix(tone.fg, 0.12, UF.surface)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(m.status == .failed ? Color.mix(UF.bad, 0.5, UF.line) : UF.line, lineWidth: 0.8))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(StudyPlanPressStyle())
        .contextMenu {
            if let actions, m.movable {
                Button { actions(m, .move) } label: { Label("Verschieben nach …", systemImage: "arrow.left.arrow.right") }
                Button(role: .destructive) { actions(m, .drop) } label: { Label("Nicht belegen", systemImage: "minus.circle") }
            }
        }
        .accessibilityLabel(StudyPlanText.accessibility(m))
        .accessibilityHint("Zeigt Details zum Modul")
        .modifier(StudyPlanCardActions(module: m, actions: actions))
        .accessibilityIdentifier("studyplan.chip.\(m.id)")
        if dropHub != nil && m.movable { chip.draggable(m.id) } else { chip }
    }

    private func slotChip(_ sl: StudyPlanSlot, height: CGFloat) -> some View {
        let font = max(9.5, min(12.5, height * 0.45))
        return Button { openSlot?(sl) } label: {
            HStack(spacing: 3) {
                UFIcon(sl.isTrack ? "layers" : "plus", size: font * 0.9)
                Text(sl.title).ufFont(font, 600).lineLimit(1).minimumScaleFactor(0.75).frame(maxWidth: .infinity, alignment: .leading)
                if let lp = sl.lp { Text(StudyPlanText.number(lp)).ufFont(font * 0.92, 650).monospacedDigit().fixedSize() }
            }
            .foregroundStyle(UF.accentText)
            .padding(.horizontal, 5)
            .frame(height: height)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.mix(UF.accent, 0.5, UF.line), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(StudyPlanPressStyle())
        .accessibilityLabel(StudyPlanText.accessibility(sl, plan: plan))
        .accessibilityIdentifier("studyplan.chip.\(sl.id)")
    }
}

private struct StudyPlanOverviewDrop: ViewModifier {
    let hub: StudyPlanDropHub?
    let term: String
    @State private var targeted = false

    func body(content: Content) -> some View {
        content.modifier(StudyPlanDropTarget(hub: hub, term: term, targeted: $targeted))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(targeted ? UF.accentFill : .clear, lineWidth: 2))
    }
}
