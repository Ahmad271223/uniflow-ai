import SwiftUI
import UniFlowCore

// Studiengruppen und Faecher im Lernkalender (Auftrag des Inhabers 12.11.2026).
//
// 1. "Studiengruppen": hat jemand bei Stud.IP Studiengruppen (`StudIPStudyGroups`), fragt die App nach dem ersten
//    Abgleich einmal je Gruppe (oder fuer alle): Dateien durchsuchen und zu Dokumente & Notizen hinzufuegen, einem Modul
//    zuordnen (bestehendes oder eigenes), Termine in den Stundenplan. Vorgabe alles aus; aendern unter
//    Einstellungen -> Stud.IP (`StudyGroupsCard`).
// 2. "Was soll in den Lernkalender?": nach dem ersten vollstaendigen Abgleich einmal die Module mit Haken "Im
//    Lernkalender planen" (`StudyPlanModules` im Kern; Vorgabe alle aktuellen Module an, Studiengruppen-Module aus);
//    aendern unter Einstellungen -> Lernzeit & Verfuegbarkeit.
// Beide Fragen zeigt `StudIPQuestionsHost` je nur einmal von selbst, nie waehrend ein Dokument zum Schreiben offen ist,
// und immer mit "Später". Eigene kleine Ansichtstypen (`ViewTypeDepthAppTests`).

enum StudyGroupsText {
    static let title = "Studiengruppen"
    static func intro(_ n: Int) -> String {
        (n == 1 ? "Du bist bei Stud.IP in einer Studiengruppe." : "Du bist bei Stud.IP in \(n) Studiengruppen.")
            + " Was soll StudiNow damit tun? Alles bleibt aus, bis du es einschaltest."
    }
    static let note = UFDevice.adapt("Ändern kannst du das jederzeit unter Einstellungen → Stud.IP. StudiNow liest Stud.IP nur und ändert dort nichts.")
    static let files = "Dateien durchsuchen und zu Dokumente & Notizen hinzufügen"
    static let module = "Einem Modul zuordnen"
    static let timetable = "Termine in den Stundenplan"
    static let all = "Für alle Gruppen"
    static let ownModule = "Eigenes Modul"
    static let later = "Später"
    static let apply = "Übernehmen"
    static let cancel = "Abbrechen"

    /// Kurzer Stand einer Gruppe fuer die Karte in den Einstellungen
    static func summary(_ c: StudIPStudyGroups.Choice) -> String {
        var parts: [String] = []
        if c.files { parts.append("Dateien") }
        if c.module { parts.append(c.moduleName.map { "Modul \($0)" } ?? "eigenes Modul") }
        if c.timetable { parts.append("Termine") }
        return parts.isEmpty ? "aus" : parts.joined(separator: " · ")
    }
}

/// Die Frage bzw. Einstellung "Studiengruppen": je Gruppe drei Schalter, bei mehreren Gruppen eine Zeile "Für alle"
struct StudyGroupsSheet: View {
    let groups: [StudIPCourse]
    let modules: [String]
    /// von selbst gezeigt (Knopf "Später") oder aus den Einstellungen ("Abbrechen")
    let asQuestion: Bool
    @State private var choices: [String: StudIPStudyGroups.Choice]
    @EnvironmentObject private var studip: StudIPSync
    @Environment(\.ufClose) private var close

    init(groups: [StudIPCourse], modules: [String], choices: [String: StudIPStudyGroups.Choice], asQuestion: Bool) {
        self.groups = groups
        self.modules = modules
        self.asQuestion = asQuestion
        _choices = State(initialValue: choices)
    }

    var body: some View {
        UFDialog(StudyGroupsText.title, icon: "users") {
            VStack(alignment: .leading, spacing: 0) {
                Text(StudyGroupsText.intro(groups.count))
                    .ufFont(14.08).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)
                if groups.count > 1 {
                    StudyGroupsAllRow(choices: $choices, ids: groups.map(\.id))
                }
                ForEach(groups, id: \.id) { g in
                    SettingsDivider()
                    StudyGroupRow(title: g.title, modules: modules, choice: binding(g.id))
                }
                Text(StudyGroupsText.note)
                    .ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
        } foot: {
            UFButton(asQuestion ? StudyGroupsText.later : StudyGroupsText.cancel) { close() }
                .frame(minHeight: 44)
                .accessibilityIdentifier("studyGroups.later")
            UFButton(StudyGroupsText.apply, kind: .primary) {
                studip.applyGroupChoices(choices)
                close()
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("studyGroups.apply")
        }
    }

    private func binding(_ id: String) -> Binding<StudIPStudyGroups.Choice> {
        Binding(get: { choices[id] ?? .init() }, set: { choices[id] = $0 })
    }
}

/// "Für alle Gruppen": schaltet einen Schalter bei allen Gruppen; an, wenn er bei allen an ist
struct StudyGroupsAllRow: View {
    @Binding var choices: [String: StudIPStudyGroups.Choice]
    let ids: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(StudyGroupsText.all).ufFont(14.5, 650).foregroundStyle(UF.text)
            StudyGroupSwitch(StudyGroupsText.files, isOn: all(\.files))
            StudyGroupSwitch(StudyGroupsText.module, isOn: all(\.module))
            StudyGroupSwitch(StudyGroupsText.timetable, isOn: all(\.timetable))
        }
        .padding(.vertical, 8)
    }

    private func all(_ key: WritableKeyPath<StudIPStudyGroups.Choice, Bool>) -> Binding<Bool> {
        Binding(get: { ids.allSatisfy { (choices[$0] ?? .init())[keyPath: key] } },
                set: { on in for id in ids { var c = choices[id] ?? .init(); c[keyPath: key] = on; choices[id] = c } })
    }
}

/// Eine Gruppe: Titel, drei Schalter, mit "Modul" die Wahl des Moduls
struct StudyGroupRow: View {
    let title: String
    let modules: [String]
    @Binding var choice: StudIPStudyGroups.Choice

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).ufFont(14.5, 650).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
            StudyGroupSwitch(StudyGroupsText.files, isOn: $choice.files)
            StudyGroupSwitch(StudyGroupsText.module, isOn: $choice.module)
            if choice.module {
                UFSelect(options: [("", StudyGroupsText.ownModule + " „\(title)“")] + modules.filter { $0 != title }.map { ($0, $0) },
                         selection: Binding(get: { choice.moduleName ?? "" }, set: { choice.moduleName = $0.isEmpty ? nil : $0 }),
                         fill: true, small: true)
                    .padding(.leading, 4).padding(.bottom, 4)
            }
            StudyGroupSwitch(StudyGroupsText.timetable, isOn: $choice.timetable)
        }
        .padding(.vertical, 8)
    }
}

/// Schalter wie in den Einstellungen (Toggle in Akzentfarbe)
struct StudyGroupSwitch: View {
    let text: String
    @Binding var isOn: Bool

    init(_ text: String, isOn: Binding<Bool>) {
        self.text = text
        self._isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(text).ufFont(13.6).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
        }
        .tint(UF.accent)
        .frame(minHeight: 40)
    }
}

/// Einstellungen -> Stud.IP: Stand je Gruppe und "Studiengruppen einstellen". Die Stud.IP-Seite liegt in den
/// Einstellungen selbst in einem Blatt; darum ein eigenes Blatt statt eines Dialogs der Wurzel (der laege darunter).
struct StudyGroupsCard: View {
    @EnvironmentObject private var studip: StudIPSync
    @State private var editing: StudyGroupsEdit?

    struct StudyGroupsEdit: Identifiable {
        let id = UUID()
        let groups: [StudIPCourse]
        let modules: [String]
    }

    var body: some View {
        let groups = studip.studyGroups
        if !groups.isEmpty {
            UFCard {
                UFCardHead(StudyGroupsText.title, icon: "users") { UFBadge("\(groups.count)", tone: .neutral) }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(groups.enumerated()), id: \.element.id) { i, g in
                        if i > 0 { SettingsDivider() }
                        SettingsValue(label: g.title, value: StudyGroupsText.summary(studip.groupSettings.choice(g.id))).padding(.vertical, 8)
                    }
                }
                UFFlexWrap(gap: 9.6) {
                    UFButton("Studiengruppen einstellen", icon: "settings") {
                        Task { editing = StudyGroupsEdit(groups: groups, modules: await studip.moduleNames()) }
                    }
                    .disabled(studip.isRunning)
                    .accessibilityIdentifier("studyGroups.edit")
                }
                .padding(.top, 12.8)
            }
            .sheet(item: $editing) { e in
                ScrollView {
                    StudyGroupsSheet(groups: e.groups, modules: e.modules, choices: studip.groupSettings.choices, asQuestion: false)
                        .padding(16)
                }
                .background(UF.bg)
                .environment(\.ufClose, { editing = nil })
            }
        }
    }
}

// MARK: - Faecher im Lernkalender

enum PlanModulesText {
    static let title = "Was soll in den Lernkalender?"
    static let intro = "Wähle die Fächer, für die StudiNow Lernblöcke plant. Nicht gewählte Fächer bleiben in Modulen, Stundenplan und Dokumenten."
    static let note = UFDevice.adapt("Ändern kannst du das jederzeit unter Einstellungen → Lernzeit & Verfügbarkeit.")
    static let planned = "Im Lernkalender planen"
    static let save = "Speichern"
    static let later = "Später"
    static let cancel = "Abbrechen"
    static let button = "Fächer im Lernkalender"
    /// Rueckfrage nach dem Abwaehlen: selbst angelegte oder geaenderte Lernpakete werden nie still geloescht
    static func keptQuestion(_ n: Int) -> String {
        (n == 1 ? "1 selbst angelegtes oder geändertes Lernpaket gehört" : "\(n) selbst angelegte oder geänderte Lernpakete gehören")
            + " zu nicht gewählten Fächern. Auch entfernen? Erledigtes und erfasste Lernzeit bleiben."
    }
}

/// Ein Fach der Auswahl (aus `GET /api/calendar/modules`)
struct PlanModuleItem: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let color: String?
    var planned: Bool

    static func list(_ overview: JSONValue) -> [PlanModuleItem] {
        (overview["modules"]?.array ?? []).compactMap { m in
            guard let name = m["name"]?.string, !name.isEmpty else { return nil }
            return PlanModuleItem(name: name, color: m["color"]?.string, planned: m["planned"]?.bool ?? true)
        }
    }
}

/// Die Frage bzw. Einstellung: Module mit Haken "Im Lernkalender planen"; gespeichert ueber `POST /api/calendar/modules`
struct PlanModulesSheet: View {
    let asQuestion: Bool
    @State private var items: [PlanModuleItem]
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @EnvironmentObject private var overlay: UFOverlay
    @Environment(\.ufClose) private var close

    init(items: [PlanModuleItem], asQuestion: Bool) {
        self.asQuestion = asQuestion
        _items = State(initialValue: items)
    }

    var body: some View {
        UFDialog(PlanModulesText.title, icon: "calendar") {
            VStack(alignment: .leading, spacing: 0) {
                Text(PlanModulesText.intro)
                    .ufFont(14.08).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)
                ForEach($items) { $item in
                    SettingsDivider()
                    PlanModuleRow(item: $item)
                }
                Text(PlanModulesText.note)
                    .ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
        } foot: {
            UFButton(asQuestion ? PlanModulesText.later : PlanModulesText.cancel) { close() }
                .frame(minHeight: 44)
                .accessibilityIdentifier("planModules.later")
            UFButton(PlanModulesText.save, kind: .primary) { save() }
                .frame(minHeight: 44)
                .accessibilityIdentifier("planModules.save")
        }
    }

    static func body(_ items: [PlanModuleItem]) -> JSONValue {
        ["modules": .array(items.map { ["name": .string($0.name), "planned": .bool($0.planned)] })]
    }

    private func save() {
        let body = Self.body(items)
        close()
        Task {
            guard let api = session.api else { return }
            var saved: JSONValue?
            guard await toast.attempt("Speichern", { saved = try await api.value("/api/calendar/modules", method: "POST", body: body) }) else { return }
            // Automatische Pakete abgewaehlter Faecher sind schon weg; eigene bzw. geaenderte nur nach Rueckfrage
            if let kept = saved?["kept"]?.int, kept > 0, await overlay.confirm(PlanModulesText.keptQuestion(kept)) {
                _ = await toast.attempt("Entfernen") {
                    _ = try await api.value("/api/calendar/modules", method: "POST", body: ["remove_own": true])
                }
            }
            router.reload()
        }
    }
}

/// Ein Fach mit Farbpunkt und Haken
struct PlanModuleRow: View {
    @Binding var item: PlanModuleItem

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Color(hex: item.color)).frame(width: 10, height: 10)
            Toggle(isOn: $item.planned) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).ufFont(14.5, 600).foregroundStyle(UF.text).fixedSize(horizontal: false, vertical: true)
                    Text(PlanModulesText.planned).ufFont(12.8).foregroundStyle(UF.muted)
                }
            }
            .tint(UF.accent)
        }
        .frame(minHeight: 48)
        .accessibilityIdentifier("planModules.\(item.name)")
    }
}

/// Einstellungen -> Lernzeit: "Fächer im Lernkalender" oeffnet die Auswahl
enum PlanModulesOpen {
    @MainActor
    static func open(api: APIClient?, overlay: UFOverlay, toast: UFToastCenter) {
        Task {
            guard let api else { return }
            do {
                let o = try await api.value("/api/calendar/modules")
                _ = overlay.modal { PlanModulesSheet(items: PlanModuleItem.list(o), asQuestion: false) }
            } catch { toast.show(error.localizedDescription) }
        }
    }
}

// MARK: - Einmal von selbst fragen

/// Zeigt nach einem Abgleich einmal "Studiengruppen" (wenn es Gruppen gibt) und danach einmal "Was soll in den
/// Lernkalender?" (wenn es Module gibt). Gefragt gilt, sobald die Frage zu sehen ist: "Später" und das Schliessen
/// fragen nicht erneut, aendern geht in den Einstellungen. Nie waehrend ein Dokument zum Schreiben offen ist
/// (`OpenDocuments.writing`), nie ueber einem anderen Dialog und nie waehrend eines Abgleichs; dann spaeter erneut
/// pruefen. Nicht unter XCTest (Logik: `StudIPSync.groupsQuestionDue`, `shouldAskPlan`).
struct StudIPQuestionsHost: ViewModifier {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var studip: StudIPSync
    @State private var checking = false
    @State private var retry: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .task { await check() }
            .onChange(of: studip.finishedRuns) { _, _ in Task { await check() } }
    }

    /// Lernkalender-Frage zeigen? Noch nicht gefragt und mindestens ein aktuelles Modul
    static func shouldAskPlan(_ overview: JSONValue) -> Bool {
        overview["asked"]?.bool != true && !(overview["modules"]?.array ?? []).isEmpty
    }

    /// Jetzt nicht stoeren? (Schreiben, anderer Dialog offen, Abgleich laeuft)
    @MainActor
    static func busy(overlay: UFOverlay, studip: StudIPSync) -> Bool {
        OpenDocuments.shared.writing || !overlay.modals.isEmpty || studip.isRunning
    }

    private func check() async {
        guard !StudIPSync.isUnderTest(), !checking else { return }
        checking = true
        defer { checking = false }
        guard let api = session.api, api.isLocal, studip.lastRun != nil else { return }
        let groupsDue = studip.groupsQuestionDue
        let overview = try? await api.value("/api/calendar/modules")
        let planDue = overview.map(Self.shouldAskPlan) ?? false
        guard groupsDue || planDue else { return }
        if Self.busy(overlay: overlay, studip: studip) {
            later()
            return
        }
        if groupsDue {
            let groups = studip.studyGroups, modules = await studip.moduleNames()
            studip.groupSettings.asked = true                       // einmal von selbst; "Später" fragt nicht erneut
            _ = overlay.modal { StudyGroupsSheet(groups: groups, modules: modules, choices: studip.groupSettings.choices, asQuestion: true) }
            if planDue { later() }                                 // die Lernkalender-Frage danach (Module der Gruppen)
            return
        }
        if let overview {
            _ = try? await api.value("/api/calendar/modules", method: "POST", body: ["asked": true])
            _ = overlay.modal { PlanModulesSheet(items: PlanModuleItem.list(overview), asQuestion: true) }
        }
    }

    /// In 20 Sekunden erneut pruefen (einmal vorgemerkt)
    private func later() {
        guard retry == nil else { return }
        retry = Task {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            retry = nil
            if !Task.isCancelled { await check() }
        }
    }
}
