import SwiftUI
import UniFlowCore

// Lernplaner: Faecher in der Lernkombination, Wochenwunsch, "Thema gemacht" (Auftrag des Inhabers 14.11.2026, Teil 1;
// docs/PLANER-FAECHER-WOCHENWUNSCH.md). Logik im Kern (StudyChoice.swift, StudyPlanModules.swift) und am PC
// (app/study_choice.py): GET/POST /api/calendar/modules, GET/PUT /api/calendar/week-wish, POST /api/calendar/topic-done.

enum PlanChoiceText {
    static let subjects = "Fächer"
    static let subjectsHint = "Diese Fächer plant der Lernkalender. Abgewählte Fächer bekommen nie Lernpakete."
    static let addPlaceholder = "Eigenes Fach, z. B. Englisch"
    static let add = "Hinzufügen"
    static let week = "Diese Woche"
    static let weekTitle = "Was willst du diese Woche machen?"
    static let weekIntro = "Wähle die Fächer, auf die du diese Woche Lust hast. Der Plan für den Rest der Woche richtet sich danach. Fächer mit einer Klausur in den nächsten 14 Tagen bleiben trotzdem dabei."
    static let weekNone = "Keine Fächer im Lernkalender."
    static let weekSaved = "Wochenwunsch gespeichert"
    static let done = "Thema schon gemacht"
    static let other = "Hier ein anderes Fach gemacht"
    static let otherTitle = "Was hast du stattdessen gemacht?"
    static let otherIntro = "Wähle das Thema, das du in dieser Zeit gelernt hast. Es zählt als erledigt, sein späterer Termin wird frei, und dieses Lernpaket rückt dorthin."
    static let otherNone = "Keine geplanten Themen anderer Fächer."
    static let otherSave = "Erledigt – Termine tauschen"
}

/// Ruft "Thema gemacht" auf und zeigt die Antwort ("1 Aufgabe erledigt, 1 Termin frei …")
enum PlanChoiceActions {
    @MainActor
    static func topicDone(_ ids: [Int], inPackage: Int? = nil, api: APIClient?, toast: UFToastCenter, router: UFRouter) async -> Bool {
        guard let api, !ids.isEmpty else { return false }
        var body: [String: JSONValue] = ["task_ids": .array(ids.map { .number(Double($0)) })]
        if let inPackage { body["in_package"] = .number(Double(inPackage)) }
        var out: JSONValue?
        guard await toast.attempt("Speichern", { out = try await api.value("/api/calendar/topic-done", method: "POST", body: .object(body)) }) else {
            return false
        }
        toast.show(out?.s("message") ?? "Erledigt")
        router.reload()
        return true
    }
}

// MARK: - Faecher in der Lernkombination

/// Abschnitt "Faecher" in "Meinen Lernplan konfigurieren": Haken je aktuellem Modul, eigenes Fach hinzufuegen
struct ConfigSubjectsSection: View {
    @Binding var items: [PlanModuleItem]
    let api: APIClient?
    @EnvironmentObject private var toast: UFToastCenter
    @State private var name = ""

    var body: some View {
        UFField(PlanChoiceText.subjects) {
            VStack(alignment: .leading, spacing: 8) {
                Text(PlanChoiceText.subjectsHint).ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                UFFlexWrap(gap: 8) {
                    ForEach($items) { $item in
                        UFChip(text: item.name, on: item.planned, icon: item.planned ? "check" : nil) { item.planned.toggle() }
                            .accessibilityIdentifier("config.subject.\(item.name)")
                    }
                }
                HStack(spacing: 8) {
                    UFTextInput(PlanChoiceText.addPlaceholder, text: $name)
                    UFButton(PlanChoiceText.add, icon: "plus", size: .small) { Task { await add() } }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("config.subject.add")
                }
            }
        }
    }

    private func add() async {
        guard let api else { return }
        let n = name.trimmingCharacters(in: .whitespaces)
        var out: JSONValue?
        guard await toast.attempt("Hinzufügen", { out = try await api.value("/api/calendar/modules", method: "POST", body: ["add": .string(n)]) }),
              let out else { return }
        // neue Liste, die noch nicht gespeicherten Haken bleiben
        let chosen = Dictionary(items.map { ($0.name, $0.planned) }, uniquingKeysWith: { a, _ in a })
        items = PlanModuleItem.list(out).map { var i = $0; if let p = chosen[i.name] { i.planned = p }; return i }
        name = ""
    }
}

// MARK: - Wochenwunsch

/// "Diese Woche will ich vor allem X und Y machen": Faecher antippen, Speichern plant den Rest der Woche neu
struct WeekWishDialog: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @Environment(\.ufClose) private var close
    @State private var choices: [(name: String, color: String?)] = []
    @State private var wished: [String] = []
    @State private var loaded = false

    var body: some View {
        UFDialog(PlanChoiceText.weekTitle, icon: "star") {
            VStack(alignment: .leading, spacing: 12) {
                Text(PlanChoiceText.weekIntro).ufFont(14.08).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                if loaded && choices.isEmpty {
                    Text(PlanChoiceText.weekNone).ufFont(14.08).foregroundStyle(UF.muted)
                }
                UFFlexWrap(gap: 8) {
                    ForEach(choices, id: \.name) { c in
                        UFChip(text: c.name, on: wished.contains(c.name), icon: wished.contains(c.name) ? "star" : nil) { toggle(c.name) }
                            .accessibilityIdentifier("weekWish.\(c.name)")
                    }
                }
            }
        } foot: {
            UFButton("Abbrechen") { close() }
            UFButton("Speichern", kind: .primary) { Task { await save() } }
                .accessibilityIdentifier("weekWish.save")
        }
        .task { await load() }
    }

    private func toggle(_ name: String) {
        if let i = wished.firstIndex(of: name) { wished.remove(at: i) } else { wished.append(name) }
    }

    private func load() async {
        guard let o = try? await session.api?.value("/api/calendar/week-wish") else { loaded = true; return }
        choices = o.list("choices").compactMap { c in c.s("name").map { ($0, c.s("color")) } }
        wished = o.list("modules").compactMap(\.string)
        loaded = true
    }

    private func save() async {
        guard let api = session.api else { return }
        var out: JSONValue?
        guard await toast.attempt("Speichern", {
            out = try await api.value("/api/calendar/week-wish", method: "PUT", body: ["modules": .array(wished.map(JSONValue.string))])
        }) else { return }
        toast.show(out?["plan"]?.s("message") ?? PlanChoiceText.weekSaved)
        close()
        router.reload()
    }
}

// MARK: - Anderes Fach gemacht

/// Im Termin eines Lernpakets ein Thema eines anderen Fachs gelernt: Thema waehlen, Termine tauschen
struct OtherTopicDialog: View {
    let package: JSONValue
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @Environment(\.ufClose) private var close
    @State private var tasks: [JSONValue] = []
    @State private var chosen: Set<Int> = []
    @State private var loaded = false

    var body: some View {
        UFDialog(PlanChoiceText.otherTitle, icon: "move") {
            VStack(alignment: .leading, spacing: 10) {
                Text(PlanChoiceText.otherIntro).ufFont(14.08).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                if loaded && tasks.isEmpty {
                    Text(PlanChoiceText.otherNone).ufFont(14.08).foregroundStyle(UF.muted)
                }
                ForEach(tasks.indices, id: \.self) { i in
                    OtherTopicRow(t: tasks[i], on: chosen.contains(tasks[i].i("id") ?? -1)) {
                        guard let id = tasks[i].i("id") else { return }
                        if chosen.contains(id) { chosen.remove(id) } else { chosen.insert(id) }
                    }
                }
            }
        } foot: {
            UFButton("Abbrechen") { close() }
            UFButton(PlanChoiceText.otherSave, kind: .primary) {
                Task {
                    if await PlanChoiceActions.topicDone(Array(chosen).sorted(), inPackage: package.i("id"), api: session.api, toast: toast, router: router) {
                        close()
                    }
                }
            }
            .disabled(chosen.isEmpty)
            .accessibilityIdentifier("otherTopic.save")
        }
        .task { await load() }
    }

    /// Offene, geplante Themen anderer Faecher ab heute (hoechstens 30, nach Datum)
    static func candidates(_ open: [JSONValue], package: JSONValue, today: String) -> [JSONValue] {
        let mine = package.i("module_id")
        return Array(open.filter { t in
            t.s("status") == "geplant" && t.i("module_id") != mine && (t.s("date") ?? "") >= today && t.i("package_id") != package.i("id")
        }.prefix(30))
    }

    private func load() async {
        let open = (try? await session.api?.value("/api/tasks/open"))?.array ?? []
        tasks = Self.candidates(open, package: package, today: UFFmt.todayISO())
        loaded = true
    }
}

/// Ein Thema zur Auswahl: Fach, Titel, Tag
struct OtherTopicRow: View {
    let t: JSONValue
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                UFCheckMark(on: on)
                Circle().fill(Color(hex: t.s("color"))).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.s("title") ?? "").ufFont(14.5, 600).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
                    Text("\(t.s("subject") ?? "") · \(UFFmt.short(t.s("date")))").ufFont(12.8).foregroundStyle(UF.muted)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Kaestchen mit Haken
struct UFCheckMark: View {
    let on: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .strokeBorder(on ? UF.accent : UF.lineStrong, lineWidth: 1.5)
            .background(RoundedRectangle(cornerRadius: 5).fill(on ? UF.accent : Color.clear))
            .overlay { if on { UFIcon("check", size: 12).foregroundStyle(.white) } }
            .frame(width: 20, height: 20)
    }
}
