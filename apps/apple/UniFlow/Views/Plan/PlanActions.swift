import SwiftUI
import UniFlowCore

// Lernkalender-Aktionen 1:1 nach app/static/views-plan.js: openPackage, taskRow/bindTaskRows, moveDialog,
// addTaskDialog, addPackageDialog, useFreeWindow, suggestFlow, generatePlan, configDialog.

/// Gemeinsame Aktionen fuer Übersicht, Lernkalender und Stundenplan (im Web exportierte Funktionen).
@MainActor
struct PlanActions {
    let api: APIClient?
    let overlay: UFOverlay
    let toast: UFToastCenter
    let router: UFRouter

    /// openPackage(id): Lernpaket-Drawer
    func openPackage(_ id: Int) {
        overlay.openDrawer { PackageDrawer(id: id) }
    }

    /// openEvent(id, date): Termin-Drawer (views-tt.js)
    func openEvent(_ id: Int, date: String) {
        overlay.openDrawer { EventDrawer(eventID: id, date: date) }
    }

    func addPackage(date: String, minutes: Int = 60) {
        overlay.modal { AddPackageDialog(date: date, minutes: minutes) }
    }

    func generatePlan(_ start: String) {
        overlay.modal { UFWithClose { close in GeneratePlanDialog(api: api, start: start, onClose: close) } }
    }

    /// configDialog(after): nach dem Speichern `after`, sonst die Ansicht neu laden
    func config(after: (() -> Void)? = nil) {
        let router = router
        overlay.modal {
            UFWithClose { close in
                ConfigDialog(api: api) { saved in
                    close()
                    if saved { if let after { after() } else { router.reload() } }
                }
            }
        }
    }

    /// suggestFlow(body): ohne Vorschlaege nur die Meldung, sonst "Meine Woche retten" / "Neu einplanen"
    func suggest(_ body: JSONValue) async {
        guard let api else { return }
        do {
            let r = try await api.value("/api/calendar/suggest", method: "POST", body: body)
            if r.list("moves").isEmpty { toast.show(r.s("message") ?? ""); return }
            let rescue = body["rescue"]?.bool == true
            let router = router
            overlay.modal {
                UFWithClose { close in
                    SuggestDialog(api: api, rescue: rescue, suggestion: r) { close(); router.reload() }
                }
            }
        } catch { toast.show(error.localizedDescription) }
    }

    /// useFreeWindow(date, "a:b", { materials, module_id })
    func useFreeWindow(date: String, start: Int, end: Int, materials: [JSONValue] = [], moduleID: Int? = nil) {
        overlay.modal { FreeWindowDialog(date: date, start: start, end: end, materials: materials, moduleID: moduleID) }
    }

    /// moveDialog(title, onPick, current)
    func move(title: String, current: String? = nil, onPick: @escaping (String) async -> Void) {
        overlay.modal { MoveDialog(title: title, date: current ?? UFFmt.todayISO(), onPick: onPick) }
    }

    func eventDialog(_ e: JSONValue?, preset: [String: JSONValue] = [:]) {
        overlay.modal { EventDialog(event: e, preset: preset) }
    }

    func availability() {
        overlay.modal { AvailabilityDialog() }
    }

    /// "Lernpaket erledigt" im Wochenraster: alle Aufgaben auf erledigt bzw. zurueck auf geplant
    func togglePackageDone(_ id: Int) async {
        guard let api, let p = try? await api.value("/api/packages/\(id)") else { return }
        let done = p.s("status") == "erledigt"
        for t in p.list("tasks") where (t.s("status") == "erledigt") == done {
            guard let tid = t.i("id") else { continue }
            _ = try? await api.value("/api/tasks/\(tid)/status", method: "POST", body: ["status": .string(done ? "geplant" : "erledigt")])
        }
        toast.show(done ? "Wieder offen" : "Lernpaket erledigt ✓")
        router.reload()
    }
}

/// Liest Router, Overlay und Toast aus der Umgebung und baut daraus PlanActions
struct PlanEnv {
    @MainActor
    static func make(_ session: Session, _ overlay: UFOverlay, _ toast: UFToastCenter, _ router: UFRouter) -> PlanActions {
        PlanActions(api: session.api, overlay: overlay, toast: toast, router: router)
    }
}

// MARK: - Lernpaket-Drawer

struct PackageDrawer: View {
    let id: Int
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @Environment(\.ufClose) private var close
    @State private var p: JSONValue?

    private var actions: PlanActions { PlanEnv.make(session, overlay, toast, router) }

    var body: some View {
        Group {
            if let p {
                content(p)
            } else {
                VStack { ProgressView() }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await load(first: true) }
        .ufReload { await load(first: false) }
    }

    private func load(first: Bool) async {
        guard let api = session.api else { return }
        do { p = try await api.value("/api/packages/\(id)") } catch {
            if first { toast.show("Paket nicht gefunden"); close() }
        }
    }

    @ViewBuilder private func content(_ p: JSONValue) -> some View {
        let tasks = p.list("tasks")
        let status = p.s("status") ?? "geplant"
        let late = tasks.filter { $0.s("status") == "nachholen" }
        UFDrawerFrame {
            UFDot(color: Color(hex: p.s("color")))
            VStack(alignment: .leading, spacing: 0) {
                Text(p.s("subject") ?? "").ufFont(14.5, 700).foregroundStyle(UF.text)
                Text(subline(p)).ufFont(13.12).foregroundStyle(UF.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            UFStatusPill(status: status)
            UFButton(icon: "x", kind: .ghost) { close() }
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Row.rows(tasks)) { row in TaskRow(t: row.value) { Task { await load(first: false) } } }
            }
            // passende Opencast-Aufzeichnungen zu den Aufgaben, nur bei sicherem Treffer (lokal)
            if session.api?.isLocal == true { RecordingPackageHints(packageID: id) }
            if status == "nachholen" || status == "teilweise" {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(late.count) Aufgaben müssen nachgeholt werden.").ufFont(14.5, 700).foregroundStyle(UF.text)
                    UFFlexWrap(gap: 9.6) {
                        UFButton("Neu einplanen", kind: .primary, size: .small) { Task { await actions.suggest(["package_id": .number(Double(id))]) } }
                        UFButton("Bewusst überspringen", size: .small) {
                            Task {
                                _ = try? await session.api?.value("/api/tasks/skip", method: "POST",
                                                                  body: ["task_ids": .array(late.compactMap { $0.i("id") }.map { .number(Double($0)) })])
                                toast.show("Übersprungen")
                                router.reload()
                            }
                        }
                    }
                }
                .padding(.vertical, 17.6 + ufB).padding(.horizontal, 19.2 + ufB)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.badSoft))
                .padding(.top, 16)
            }
        } foot: {
            UFButton("Verschieben", icon: "move", size: .small) {
                actions.move(title: "Lernpaket „\(p.s("subject") ?? "")“ verschieben", current: p.s("date")) { date in
                    _ = try? await session.api?.value("/api/packages/\(id)", method: "PATCH", body: ["date": .string(date)])
                    toast.show("Verschoben")
                    router.reload()
                }
            }
            UFButton("Uhrzeit", icon: "clock", size: .small) {
                overlay.modal { PackageTimeDialog(id: id, start: p.s("start_time") ?? "09:00", minutes: p.i("planned_minutes") ?? 60) }
            }
            UFButton("Aufgabe", icon: "plus", size: .small) { overlay.modal { AddTaskDialog(package: p) } }
            UFFlexSpacer()
            UFButton(icon: "trash", kind: .danger, size: .small) {
                Task {
                    if await overlay.confirm("Lernpaket mit allen Aufgaben löschen?") {
                        _ = try? await session.api?.value("/api/packages/\(id)", method: "DELETE")
                        router.reload()
                    }
                }
            }
        }
    }

    private func subline(_ p: JSONValue) -> String {
        var s = "\(p.s("title") ?? "") · \(UFFmt.short(p.s("date")))"
        if let st = p.s("start_time") { s += " · \(st)–\(p.s("end_time") ?? "")" }
        return s + " · " + UFFmt.min(p.n("planned_minutes"))
    }
}

// MARK: - Aufgabenzeile (taskRow + bindTaskRows)

/// .task-row: Kontrollkaestchen 22 pt (erledigt = --ok), Titel mit Typ-Icon, Unterzeile, Öffnen/Test, Mehr-Menue
struct TaskRow: View {
    let t: JSONValue
    var refresh: () -> Void
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @State private var creatingTest = false

    var body: some View {
        let status = t.s("status") ?? "geplant"
        let done = status == "erledigt"
        HStack(spacing: 11.2) {
            Button { Task { await toggle(done) } } label: {
                RoundedRectangle(cornerRadius: 6)
                    .fill(done ? UF.ok : .clear)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(done ? UF.ok : UF.lineStrong, lineWidth: 2))
                    .overlay { if done { UFIcon("check", size: 14).foregroundStyle(.white) } }
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(done ? "Als offen markieren" : "Als erledigt markieren")
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {       // Icon inline in der ersten Zeile (vertical-align -3px)
                    UFIcon(ShellState.typeIcon[t.s("type") ?? ""] ?? "file", size: 14)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                    Text(t.s("title") ?? "").strikethrough(done)
                }
                .ufFont(14.5, 550)
                .foregroundStyle(done ? UF.muted : status == "nachholen" ? UF.bad : UF.text)
                Text(meta).ufFont(12.48).foregroundStyle(UF.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let f = t.s("file_id") {
                UFButton("Öffnen", icon: "book", size: .small) {
                    let lp = t.i("last_page") ?? 1
                    router.go(.doc(f, task: t.i("id"), page: lp > 1 ? lp : nil))
                }
            } else if t.s("type") == "test" {
                let submitted = t["test_submitted"].map { !$0.isNull } ?? false
                let label = creatingTest ? "Test wird erstellt…" : (t.i("test_id") != nil ? (submitted ? "Ergebnis" : "Fortsetzen") : "Test starten")
                UFButton(label, icon: creatingTest ? nil : "play", kind: submitted ? .normal : .primary, size: .small) { Task { await startTest() } }
                    .disabled(creatingTest)
            }
            UFButton(icon: "more", kind: .ghost, size: .small) {
                overlay.modal { TaskMenuDialog(id: t.i("id") ?? 0, title: t.s("title") ?? "", refresh: refresh) }
            }
        }
        .padding(.vertical, 8.8)
        .padding(.horizontal, 4.8)
        .ufBorderBottom()
    }

    private var meta: String {
        var s = "\(ShellState.typeText[t.s("type") ?? ""] ?? (t.s("type") ?? "")) · \(t.i("est_minutes") ?? 0) min"
        if let st = t.s("start_time") { s += " · \(st)–\(t.s("end_time") ?? "")" }
        s += " · " + (UFStatusPill.labels[t.s("status") ?? ""] ?? (t.s("status") ?? ""))
        if let m = t.s("moved_from") { s += " · verschoben von \(UFFmt.short(m))" }
        if t["test_submitted"].map({ !$0.isNull }) == true {
            s += " · \(Int((t.n("test_score") ?? 0).rounded()))/\(Int((t.n("test_max") ?? 0).rounded())) P."
        }
        return s
    }

    private func toggle(_ done: Bool) async {
        guard let id = t.i("id") else { return }
        _ = try? await session.api?.value("/api/tasks/\(id)/status", method: "POST", body: ["status": .string(done ? "geplant" : "erledigt")])
        toast.show(done ? "Wieder offen" : "Erledigt ✓")
        refresh()
        router.reload()
    }

    private func startTest() async {
        guard let api = session.api, let id = t.i("id") else { return }
        creatingTest = true
        do {
            let r = try await api.value("/api/tasks/\(id)/start-test", method: "POST")
            overlay.closeAll()
            if let tid = r.i("test_id") { router.go(.exam(tid, task: id)) }
        } catch {
            toast.show(error.localizedDescription, seconds: 5)
            creatingTest = false
        }
    }
}

/// Modal "Aufgabe": In Bearbeitung, Verschieben, Ueberspringen, Titel/Dauer, Loeschen
struct TaskMenuDialog: View {
    let id: Int
    let title: String
    let refresh: () -> Void
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @Environment(\.ufClose) private var close

    var body: some View {
        UFDialog("Aufgabe") {
            VStack(alignment: .leading, spacing: 8) {
                menuButton("In Bearbeitung", icon: "play") { await setStatus("in_bearbeitung") }
                menuButton("Auf anderen Tag verschieben", icon: "move") {
                    PlanEnv.make(session, overlay, toast, router).move(title: "Aufgabe verschieben") { date in
                        _ = try? await session.api?.value("/api/calendar/apply", method: "POST",
                                                          body: ["moves": [["task_id": .number(Double(id)), "to": .string(date)]]])
                        toast.show("Verschoben")
                        refresh()
                        router.reload()
                    }
                }
                menuButton("Bewusst überspringen", icon: "x") { await setStatus("uebersprungen") }
                menuButton("Titel / Dauer ändern", icon: "pencil") { overlay.modal { TaskEditDialog(id: id, title: title, refresh: refresh) } }
                menuButton("Löschen", icon: "trash", kind: .danger) {
                    if await overlay.confirm("Aufgabe löschen?") {
                        _ = try? await session.api?.value("/api/tasks/\(id)", method: "DELETE")
                        refresh()
                        router.reload()
                    }
                }
            }
        } foot: {
            UFButton("Abbrechen") { close() }
        }
    }

    private func menuButton(_ text: String, icon: String, kind: UFButtonKind = .normal, action: @escaping () async -> Void) -> some View {
        Button { close(); Task { await action() } } label: {
            HStack(spacing: 7.2) { UFIcon(icon, size: 14); Text(text) }.frame(maxWidth: .infinity)
        }
        .buttonStyle(UFButtonStyle(kind: kind))
    }

    private func setStatus(_ s: String) async {
        _ = try? await session.api?.value("/api/tasks/\(id)/status", method: "POST", body: ["status": .string(s)])
        refresh()
        router.reload()
    }
}

/// Modal "Aufgabe bearbeiten": Titel vorbelegt, Dauer immer mit 45 vorbelegt (wie im Web)
struct TaskEditDialog: View {
    let id: Int
    let refresh: () -> Void
    @State var title: String
    @State private var minutes = 45
    @EnvironmentObject private var session: Session
    @Environment(\.ufClose) private var close

    init(id: Int, title: String, refresh: @escaping () -> Void) {
        self.id = id
        self.refresh = refresh
        _title = State(initialValue: title)
    }

    var body: some View {
        UFDialog("Aufgabe bearbeiten") {
            UFField("Titel") { UFTextInput(text: $title) }
            UFField("Dauer (Minuten)") { UFNumberField(value: $minutes) }
        } foot: {
            UFButton("Abbrechen") { close() }
            UFButton("Speichern", kind: .primary) {
                Task {
                    _ = try? await session.api?.value("/api/tasks/\(id)", method: "PATCH",
                                                      body: ["title": .string(title), "est_minutes": .number(Double(max(5, minutes)))])
                    close()
                    refresh()
                }
            }
        }
    }
}

/// moveDialog: "Neuer Tag" und Chips +1/+2/+3/+7 Tage (ab heute)
struct MoveDialog: View {
    let title: String
    @State var date: String
    let onPick: (String) async -> Void
    @Environment(\.ufClose) private var close

    var body: some View {
        UFDialog(title) {
            UFField("Neuer Tag") { UFDateField(iso: $date) }
            HStack(spacing: 9.6) {
                ForEach([1, 2, 3, 7], id: \.self) { n in
                    UFChip(text: "+\(n) Tag\(n > 1 ? "e" : "")") {
                        date = Fmt.isoDay(Calendar.current.date(byAdding: .day, value: n, to: Date()) ?? Date())
                    }
                }
            }
            .padding(.vertical, 4.8)
        } foot: {
            UFButton("Abbrechen") { close() }
            UFButton("Verschieben", kind: .primary) {
                guard !date.isEmpty else { return }
                close()
                Task { await onPick(date) }
            }
        }
    }
}

/// Modal "Uhrzeit" im Lernpaket: Beginn (Standard 09:00), Dauer (Schritt 15)
struct PackageTimeDialog: View {
    let id: Int
    @State var start: String
    @State var minutes: Int
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var router: UFRouter
    @Environment(\.ufClose) private var close

    var body: some View {
        UFDialog("Uhrzeit") {
            HStack(spacing: 9.6) {
                UFField("Beginn") { UFTimeField(hm: $start) }
                UFField("Dauer") { UFNumberField(value: $minutes) }
            }
        } foot: {
            UFButton("Abbrechen") { close() }
            UFButton("Speichern", kind: .primary) {
                Task {
                    _ = try? await session.api?.value("/api/packages/\(id)", method: "PATCH",
                                                      body: ["start_time": .string(start), "end_time": .string(UFTime.mh(UFTime.hm(start) + minutes))])
                    close()
                    router.reload()
                }
            }
        }
    }
}

/// addTaskDialog: Art, Dokument (Dateien des Moduls, fuellt den Titel vor), Titel, Dauer
struct AddTaskDialog: View {
    let package: JSONValue
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @Environment(\.ufClose) private var close
    @State private var type = "vorlesung"
    @State private var file = ""
    @State private var title = ""
    @State private var minutes = 45
    @State private var files: [JSONValue] = []

    var body: some View {
        UFDialog("Aufgabe hinzufügen") {
            UFField("Art") {
                UFSelect(options: [("vorlesung", "Vorlesung"), ("uebung", "Übung"), ("test", "Wochentest"), ("wiederholung", "Wiederholung"), ("frei", "Freies Lernen")],
                         selection: $type, fill: true)
            }
            UFField("Dokument (optional)") {
                UFSelect(options: [("", "– keins –")] + files.compactMap { f in f.s("id").map { ($0, f.s("ai_title") ?? f.s("name") ?? "") } },
                         selection: $file, fill: true)
            }
            UFField("Titel") { UFTextInput("z. B. Kapitel 3 wiederholen", text: $title) }
            UFField("Dauer (Minuten)") { UFNumberField(value: $minutes) }
        } foot: {
            UFButton("Abbrechen") { close() }
            UFButton("Hinzufügen", kind: .primary) { Task { await add() } }
        }
        .task {
            if let m = package.i("module_id"), let d = try? await session.api?.value("/api/modules/\(m)") { files = d.list("files") }
        }
        .onChange(of: file) { _, f in
            if let x = files.first(where: { $0.s("id") == f }), title.isEmpty { title = x.s("ai_title") ?? x.s("name") ?? "" }
        }
    }

    private func add() async {
        guard let pid = package.i("id") else { return }
        let body: JSONValue = ["type": .string(type), "file_id": file.isEmpty ? .null : .string(file),
                               "title": .string(title.isEmpty ? (ShellState.typeText[type] ?? type) : title), "est_minutes": .number(Double(minutes))]
        _ = try? await session.api?.value("/api/packages/\(pid)/tasks", method: "POST", body: body)
        close()
        toast.show("Aufgabe hinzugefügt")
        router.reload()
    }
}

/// addPackageDialog(date, minutes): Tag, Modul, Titel, Beginn (optional), Dauer
struct AddPackageDialog: View {
    @State var date: String
    @State var minutes: Int
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @Environment(\.ufClose) private var close
    @State private var modules: [JSONValue] = []
    @State private var module = 0
    @State private var title = ""
    @State private var start = ""

    var body: some View {
        UFDialog("Neues Lernpaket") {
            HStack(alignment: .top, spacing: 9.6) {
                UFField("Tag") { UFDateField(iso: $date) }
                UFField("Modul") { UFSelect(options: modules.compactMap { m in m.i("id").map { ($0, m.s("name") ?? "") } }, selection: $module, fill: true) }
            }
            UFField("Titel") { UFTextInput("z. B. Kapitel 2 lernen", text: $title) }
            HStack(alignment: .top, spacing: 9.6) {
                UFField("Beginn (optional)") { UFTimeField(hm: $start, allowEmpty: true) }
                UFField("Dauer (Minuten)") { UFNumberField(value: $minutes) }
            }
        } foot: {
            UFButton("Abbrechen") { close() }
            UFButton("Anlegen", kind: .primary) { Task { await create() } }
        }
        .task {
            if let m = try? await session.api?.value("/api/modules") {
                modules = m.items
                if module == 0 { module = modules.first?.i("id") ?? 0 }
            }
        }
    }

    private func create() async {
        guard let api = session.api else { return }
        do {
            let r = try await api.value("/api/packages", method: "POST",
                                        body: ["date": .string(date), "module_id": .number(Double(module)), "title": .string(title.isEmpty ? "Lernen" : title),
                                               "minutes": .number(Double(minutes))])
            if !start.isEmpty, let id = r.i("id") {
                _ = try await api.value("/api/packages/\(id)", method: "PATCH",
                                        body: ["start_time": .string(start), "end_time": .string(UFTime.mh(UFTime.hm(start) + minutes))])
            }
            close()
            toast.show("Lernpaket angelegt")
            router.reload()
        } catch { toast.show(error.localizedDescription) }
    }
}

/// useFreeWindow: "X frei (hh:mm–hh:mm)" – Wie moechtest du die Zeit nutzen?
struct FreeWindowDialog: View {
    let date: String
    let start: Int
    let end: Int
    let materials: [JSONValue]
    let moduleID: Int?
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @Environment(\.ufClose) private var close

    var body: some View {
        let mins = end - start
        UFDialog("\(UFFmt.min(mins)) frei (\(UFTime.mh(start))–\(UFTime.mh(end)))", icon: "sun") {
            Text("Wie möchtest du die Zeit nutzen?").ufFont(14.5).foregroundStyle(UF.muted).padding(.bottom, 5.6)
            VStack(spacing: 8) {
                if !materials.isEmpty {
                    choice("Passende Übung bearbeiten", icon: "pencil") { await material(lecture: false, mins: mins) }
                    choice("Vorlesung selbstständig nacharbeiten", icon: "book") { await material(lecture: true, mins: mins) }
                }
                choice("Lerneinheit automatisch einplanen", icon: "sparkles") {
                    if let r = try? await session.api?.value("/api/calendar/generate", method: "POST", body: ["start": .string(date), "days": 1]) {
                        toast.show(r.s("message") ?? "")
                    }
                    router.reload()
                }
                choice("Offene Aufgaben nachholen", icon: "alert") {
                    await PlanEnv.make(session, overlay, toast, router).suggest(["horizon": 1])
                }
                choice("Eigenen Lernblock anlegen", icon: "plus") {
                    PlanEnv.make(session, overlay, toast, router).addPackage(date: date, minutes: mins)
                }
                Button { close() } label: { Text("Frei lassen").frame(maxWidth: .infinity) }.buttonStyle(UFButtonStyle(kind: .ghost))
            }
        } foot: { EmptyView() }
    }

    private func choice(_ text: String, icon: String, action: @escaping () async -> Void) -> some View {
        Button { close(); Task { await action() } } label: {
            HStack(spacing: 7.2) { UFIcon(icon, size: 16); Text(text) }.frame(maxWidth: .infinity)
        }
        .buttonStyle(UFButtonStyle())
    }

    /// "Passende Übung bearbeiten" / "Vorlesung nacharbeiten": Paket aus den Unterlagen, danach Uhrzeiten vergeben
    private func material(lecture: Bool, mins: Int) async {
        guard let api = session.api else { return }
        let lec = materials.filter { $0.s("doc_type") == "vorlesung" }, ex = materials.filter { $0.s("doc_type") == "uebung" }
        var tasks: [JSONValue] = []
        var used = 0
        if lecture, let l = lec.first {
            used = min(mins, l.i("est_minutes") ?? 60)
            tasks.append(["type": "vorlesung", "file_id": .string(l.s("id") ?? ""), "title": .string(l.s("ai_title") ?? l.s("name") ?? ""), "est_minutes": .number(Double(used))])
        }
        if let e = ex.first {
            tasks.append(["type": "uebung", "file_id": .string(e.s("id") ?? ""), "title": .string(e.s("ai_title") ?? e.s("name") ?? ""),
                          "est_minutes": .number(Double(min(mins - used, e.i("est_minutes") ?? 45)))])
        }
        if lecture { tasks.append(["type": "test", "title": "Gemeinsamer Wochentest", "est_minutes": 15]) }
        let body: JSONValue = ["date": .string(date), "module_id": moduleID.map { .number(Double($0)) } ?? .null,
                               "title": .string(lecture ? "Vorlesung nacharbeiten" : "Übung bearbeiten"),
                               "tasks": .array(tasks.filter { ($0["est_minutes"]?.double ?? 0) > 0 })]
        _ = try? await api.value("/api/packages", method: "POST", body: body)
        _ = try? await api.value("/api/timetable/reslot", method: "POST", body: ["dates": [.string(date)]])
        toast.show("Lernblock angelegt")
        router.reload()
    }
}

// MARK: - Zeit hm/mh wie core.js

enum UFTime {
    /// hm("08:15") = 495
    static func hm(_ s: String?) -> Int {
        let p = (s ?? "0:0").split(separator: ":").map { Int($0) ?? 0 }
        return (p.first ?? 0) * 60 + (p.count > 1 ? p[1] : 0)
    }

    /// mh(495) = "08:15"
    static func mh(_ m: Int) -> String { String(format: "%02d:%02d", m / 60, m % 60) }
}
