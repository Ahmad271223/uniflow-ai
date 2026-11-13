import SwiftUI
import UniFlowCore

/// Smart Planner 2.0: Dialoge der Lernziele. Zahlen mit Komma oder Punkt ("200,5"), gespeichert über die Endpunkte
/// des lokalen Kerns bzw. des Dienstes (`/api/goals*`, `/api/sessions*`, Klausurtag über `PATCH /api/modules/{id}`).

/// "12,5" / "12.5" -> 12.5; leer -> nil
enum GoalsInput {
    static func number(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !t.isEmpty, let d = Double(t), d.isFinite else { return nil }
        return d
    }

    static func text(_ d: Double?) -> String {
        guard let d else { return "" }
        return d == d.rounded() ? String(Int(d)) : String(format: "%.1f", d).replacingOccurrences(of: ".", with: ",")
    }

    /// Ortszeit Berlin (Tag + HH:MM) -> Unix-Sekunden
    static func epoch(day: String, hm: String) -> Int? {
        guard let d = Fmt.date(day) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        var c = cal.dateComponents([.year, .month, .day], from: d)
        let parts = hm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        c.hour = h
        c.minute = m
        return cal.date(from: c).map { Int($0.timeIntervalSince1970) }
    }
}

// MARK: - Lernziel eines Moduls

struct GoalEditDialog: View {
    let module: JSONValue
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @EnvironmentObject private var overlay: UFOverlay
    @Environment(\.ufClose) private var close

    @State private var target = ""
    @State private var before = ""
    @State private var lectures = false
    @State private var writing = true
    @State private var exam = ""
    @State private var attempt = 1
    @State private var second = ""
    @State private var priority = 2
    /// erkannte Klausurtermine dieses Moduls (Stud.IP, QIS-Anmeldung, Kalender, Dokumente) zum Übernehmen
    @State private var candidates: [JSONValue] = []

    private var mid: Int { module.i("module_id") ?? 0 }
    private var hasGoal: Bool { module["target_minutes"] != nil }

    var body: some View {
        UFDialog("Lernziel: \(module.s("name") ?? "Modul")", icon: "flag") {
            Text("Wie viele Stunden willst du bis zur Klausur selbst lernen? Pflichtveranstaltungen zählen nur mit, wenn du es unten einschaltest.")
                .ufFont(13.12).foregroundStyle(UF.muted)
            UFGridLayout(columns: 2) {
                UFField("Ziel in Stunden (z. B. 200)") { UFTextInput("200", text: $target) }
                UFField("Schon gelernt (Stunden)") { UFTextInput("0", text: $before) }
                UFField("Klausurtermin") { UFDateField(iso: $exam, allowEmpty: true) }
                UFField("Zweittermin (falls bekannt)") { UFDateField(iso: $second, allowEmpty: true) }
                UFField("Ich schreibe") {
                    UFSegPill(options: [(1, "Ersttermin", nil), (2, "Zweittermin", nil)], selection: attempt) { attempt = $0 }
                }
                UFField("Priorität") {
                    UFSelect(options: [(1, "niedrig"), (2, "normal"), (3, "hoch")], selection: $priority)
                }
            }
            if !candidates.isEmpty { GoalExamCandidates(candidates: candidates, exam: $exam) }
            UFCheckbox("Pflichtveranstaltungen (Vorlesungen, Übungen laut Stundenplan) zählen zum Ziel", isOn: $lectures)
            UFCheckbox("Ich schreibe diese Klausur in diesem Semester", isOn: $writing)
            if module.s("exam_source") == "automatisch" {
                Text("Der Klausurtermin wurde automatisch erkannt. Prüfe ihn und tippe in der Übersicht auf „Bestätigen“.")
                    .ufFont(12.8).foregroundStyle(UF.warnText)
            }
        } foot: {
            if hasGoal {
                UFButton(icon: "trash", kind: .danger) { Task { await remove() } }
            }
            UFFlexSpacer()
            UFButton("Abbrechen") { close() }
            UFButton("Speichern", kind: .primary) { Task { await save() } }
        }
        .onAppear(perform: fill)
        .task { candidates = await UFExam.load(session.api, module: mid).filter { $0.i("module_id") == mid } }
    }

    private func fill() {
        target = GoalsInput.text(module.n("target_minutes").map { $0 / 60 })
        before = GoalsInput.text(module.n("learned_before_minutes").map { $0 / 60 })
        lectures = module["include_lectures"]?.bool ?? false
        writing = module["writing"]?.bool ?? true
        exam = module.s("module_exam_date") ?? module.s("exam_date") ?? ""
        attempt = module.i("exam_attempt") ?? 1
        second = module.s("exam_date_2") ?? ""
        priority = module.i("priority") ?? 2
    }

    private func save() async {
        guard let hours = GoalsInput.number(target), hours >= 0 else { toast.show("Ziel bitte als Zahl in Stunden eintragen."); return }
        var body: [String: JSONValue] = ["target_hours": .number(hours), "include_lectures": .bool(lectures), "writing": .bool(writing),
                                         "priority": .number(Double(priority)), "exam_date_2": second.isEmpty ? .null : .string(second),
                                         "exam_attempt": .number(Double(attempt))]
        if let b = GoalsInput.number(before) { body["learned_before_hours"] = .number(b) }
        guard let api = session.api else { return }
        let oldExam = module.s("module_exam_date") ?? module.s("exam_date") ?? ""
        let ok = await toast.attempt("Speichern") {
            if exam != oldExam { _ = try await api.value("/api/modules/\(mid)", method: "PATCH", body: ["exam_date": .string(exam)]) }
            _ = try await api.value("/api/goals/\(mid)", method: "PUT", body: .object(body))
        }
        if ok {
            close()
            toast.show("Lernziel gespeichert")
            router.reload()
        }
    }

    private func remove() async {
        guard await overlay.confirm("Lernziel für „\(module.s("name") ?? "")“ entfernen? Künftige automatische Lernblöcke fallen weg.") else { return }
        if await GoalsActions.send(session.api, toast, router, "Entfernen", "/api/goals/\(mid)", method: "DELETE", done: "Lernziel entfernt") != nil {
            close()
        }
    }
}

/// Gefundene Termine mit Quelle; Antippen übernimmt den Tag (gespeichert erst mit "Speichern", dann selbst eingetragen)
struct GoalExamCandidates: View {
    let candidates: [JSONValue]
    @Binding var exam: String

    var body: some View {
        UFField("Gefundene Termine (antippen zum Übernehmen)") {
            UFFlexWrap(gap: 8) {
                ForEach(Array(candidates.prefix(6).enumerated()), id: \.offset) { _, c in
                    let d = c.s("date") ?? ""
                    UFChip(text: "\(UFFmt.short(d)) · \(c.s("source_label") ?? "erkannt")", on: d == exam) { exam = d }
                }
            }
        }
    }
}

// MARK: - Zeitrahmen (Schlaf, Freizeit, Verpflichtungen, Nutzungsquote)

struct GoalSettingsDialog: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @Environment(\.ufClose) private var close

    struct Commitment: Identifiable { let id = UUID(); var weekday: Int; var start: String; var end: String; var kind: String; var title: String }

    @State private var sleep = "10"
    @State private var bedtime = "23:00"
    @State private var leisure = 120
    @State private var quota = 60
    @State private var minBlock = 30
    @State private var maxBlock = 120
    @State private var pause = 10
    @State private var weekHours = ""
    @State private var items: [Commitment] = []

    var body: some View {
        UFDialog("Zeitrahmen fürs Lernen", icon: "clock") {
            Text("Geplant wird nur in echter freier Zeit: ohne Schlaf, Freizeit, Vorlesungen samt Fahrtzeit, Sperrzeiten, Arbeit und Verpflichtungen. Von der freien Zeit nutzt StudiNow höchstens die Nutzungsquote.")
                .ufFont(13.12).foregroundStyle(UF.muted)
            UFGridLayout(columns: 2) {
                UFField("Schlaf pro Nacht (Stunden)") { UFTextInput("10", text: $sleep) }
                UFField("Schlafenszeit") { UFTimeField(hm: $bedtime) }
                UFField("Freizeit pro Tag (Minuten, abends)") { UFNumberField(value: $leisure) }
                UFField("Nutzungsquote der freien Zeit (%)") { UFNumberField(value: $quota) }
                UFField("Kürzester Lernblock (Minuten)") { UFNumberField(value: $minBlock) }
                UFField("Längster Lernblock (Minuten)") { UFNumberField(value: $maxBlock) }
                UFField("Pause zwischen Blöcken (Minuten)") { UFNumberField(value: $pause) }
                UFField("Höchstens pro Woche (Stunden, leer = ohne)") { UFTextInput("", text: $weekHours) }
            }
            UFField("Arbeit und feste Verpflichtungen") {
                VStack(alignment: .leading, spacing: 8) {
                    if items.isEmpty { Text("Keine.").ufFont(13.12).foregroundStyle(UF.muted) }
                    ForEach($items) { $c in GoalCommitmentRow(c: $c) { items.removeAll { $0.id == c.id } } }
                    UFButton("Eintrag", icon: "plus", size: .small) { items.append(Commitment(weekday: 0, start: "16:00", end: "20:00", kind: "arbeit", title: "")) }
                }
            }
        } foot: {
            UFButton("Abbrechen") { close() }
            UFButton("Speichern", kind: .primary) { Task { await save() } }
        }
        .task { await load() }
    }

    private func load() async {
        guard let s = try? await session.api?.value("/api/goals/settings") else { return }
        sleep = GoalsInput.text(s.n("sleep_hours"))
        bedtime = s.s("bedtime_hm") ?? "23:00"
        leisure = s.i("leisure_minutes") ?? 120
        quota = s.i("utilization") ?? 60
        minBlock = s.i("min_block") ?? 30
        maxBlock = s.i("max_block") ?? 120
        pause = s.i("break") ?? 10
        weekHours = (s.i("max_week_minutes") ?? 0) > 0 ? GoalsInput.text(Double(s.i("max_week_minutes")!) / 60) : ""
        items = s.list("commitments").map {
            Commitment(weekday: $0.i("weekday") ?? 0, start: UFTime.mh($0.i("start") ?? 960), end: UFTime.mh($0.i("end") ?? 1200),
                       kind: $0.s("kind") ?? "verpflichtung", title: $0.s("title") ?? "")
        }
    }

    private func save() async {
        guard let h = GoalsInput.number(sleep) else { toast.show("Schlaf bitte als Zahl in Stunden."); return }
        let body: JSONValue = [
            "sleep_hours": .number(h), "bedtime": .string(bedtime), "leisure_minutes": .number(Double(leisure)), "utilization": .number(Double(quota)),
            "min_block": .number(Double(minBlock)), "max_block": .number(Double(maxBlock)), "break": .number(Double(pause)),
            "max_week_minutes": .number(((GoalsInput.number(weekHours) ?? 0) * 60).rounded()),
            "commitments": .array(items.map { ["weekday": .number(Double($0.weekday)), "start": .string($0.start), "end": .string($0.end),
                                               "kind": .string($0.kind), "title": .string($0.title)] }),
        ]
        if await GoalsActions.send(session.api, toast, router, "Speichern", "/api/goals/settings", method: "PUT", body: body, done: "Zeitrahmen gespeichert") != nil {
            close()
        }
    }
}

struct GoalCommitmentRow: View {
    @Binding var c: GoalSettingsDialog.Commitment
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 9.6) {
            UFSelect(options: ShellState.days.enumerated().map { ($0.offset, $0.element) }, selection: $c.weekday)
            UFTimeField(hm: $c.start).frame(width: 90)
            UFTimeField(hm: $c.end).frame(width: 90)
            UFSelect(options: [("arbeit", "Arbeit"), ("verpflichtung", "Verpflichtung")], selection: $c.kind)
            UFTextInput("Bezeichnung", text: $c.title)
            UFButton(icon: "x", kind: .ghost, size: .small) { remove() }
        }
    }
}

// MARK: - Lernzeit eintragen

struct SessionEntryDialog: View {
    let modules: [JSONValue]
    @State var moduleID: Int?
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @Environment(\.ufClose) private var close

    @State private var day = UFFmt.todayISO()
    @State private var withTimes = false
    @State private var minutes = 60
    @State private var start = "14:00"
    @State private var end = "15:30"

    var body: some View {
        UFDialog("Lernzeit eintragen", icon: "clock") {
            Text("Mit Uhrzeit zählt eine Überschneidung mit der Stoppuhr nur einmal.").ufFont(13.12).foregroundStyle(UF.muted)
            UFGridLayout(columns: 2) {
                UFField("Modul") {
                    UFSelect(options: modules.compactMap { m in m.i("module_id").map { ($0, m.s("name") ?? "Modul") } },
                             selection: Binding(get: { moduleID ?? modules.first?.i("module_id") ?? 0 }, set: { moduleID = $0 }))
                }
                UFField("Tag") { UFDateField(iso: $day) }
                if withTimes {
                    UFField("Von") { UFTimeField(hm: $start) }
                    UFField("Bis") { UFTimeField(hm: $end) }
                } else {
                    UFField("Dauer (Minuten)") { UFNumberField(value: $minutes) }
                }
            }
            UFCheckbox("Mit Uhrzeit eintragen", isOn: $withTimes)
        } foot: {
            UFButton("Abbrechen") { close() }
            UFButton("Speichern", kind: .primary) { Task { await save() } }
        }
    }

    private func save() async {
        let mid = moduleID ?? modules.first?.i("module_id") ?? 0
        var body: [String: JSONValue] = ["module_id": .number(Double(mid)), "uuid": .string(UUID().uuidString.lowercased())]
        if withTimes {
            guard let a = GoalsInput.epoch(day: day, hm: start), let b = GoalsInput.epoch(day: day, hm: end) else { toast.show("Uhrzeit prüfen."); return }
            body["start"] = .number(Double(a))
            body["end"] = .number(Double(b))
        } else {
            body["minutes"] = .number(Double(minutes))
            body["day"] = .string(day)
        }
        if await GoalsActions.send(session.api, toast, router, "Eintragen", "/api/sessions", method: "POST", body: .object(body), done: "Lernzeit gespeichert") != nil {
            close()
        }
    }
}

// MARK: - Block abhaken

/// Ein abgehakter Block zählt nur mit der wirklich gelernten Zeit (Vorschlag: gemessene Zeit, sonst die Dauer)
struct BlockDoneDialog: View {
    let package: JSONValue
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @Environment(\.ufClose) private var close
    @State private var minutes = 0

    var body: some View {
        UFDialog("Wie lange hast du gelernt?", icon: "check") {
            Text("\(package.s("subject") ?? "Lernblock") · \(UFFmt.short(package.s("date"))) · \(package.s("start_time") ?? "")–\(package.s("end_time") ?? "")")
                .ufFont(14, 650).foregroundStyle(UF.text)
            Text("Nur die Zeit, die du wirklich gelernt hast, zählt für dein Ziel.").ufFont(13.12).foregroundStyle(UF.muted)
            UFField("Gelernt (Minuten)") { UFNumberField(value: $minutes) }
        } foot: {
            UFButton("Nicht gelernt") { Task { await save(0) } }
            UFFlexSpacer()
            UFButton("Abbrechen") { close() }
            UFButton("Speichern", kind: .primary) { Task { await save(minutes) } }
        }
        .onAppear {
            let planned = max(0, UFTime.hm(package.s("end_time") ?? "") - UFTime.hm(package.s("start_time") ?? ""))
            minutes = planned > 0 ? planned : (package.i("planned_minutes") ?? 60)
        }
    }

    private func save(_ m: Int) async {
        let id = package.i("id") ?? 0
        if await GoalsActions.send(session.api, toast, router, "Abhaken", "/api/goals/blocks/\(id)/done", method: "POST", body: ["minutes": .number(Double(m))],
                                   done: m > 0 ? "\(GoalsFmt.h(Double(m))) gelernt ✓" : "Als nicht gelernt vermerkt") != nil {
            close()
        }
    }
}

// MARK: - Lernblock des Stundenplaners im Lernpaket-Drawer

struct SmartBlockPanel: View {
    let p: JSONValue
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter

    var body: some View {
        let id = p.i("id") ?? 0
        let locked = (p.i("locked") ?? 0) == 1
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                UFIcon("flag", size: 15)
                Text(locked ? "Lernblock aus deinen Lernzielen · gesperrt" : (p.i("manual") ?? 0) == 1 ? "Lernblock aus deinen Lernzielen · von dir verschoben"
                                                                                                    : "Lernblock aus deinen Lernzielen")
            }
            .ufFont(13.6, 650).foregroundStyle(UF.text2)
            Text("Gesperrte und von dir verschobene Blöcke verschiebt StudiNow nie von selbst.").ufFont(12.8).foregroundStyle(UF.muted)
            UFFlexWrap(gap: 8) {
                if p.s("status") == "erledigt" {
                    UFButton("Wieder offen", size: .small) {
                        Task { _ = await GoalsActions.send(session.api, toast, router, "Zurücksetzen", "/api/goals/blocks/\(id)/undone", method: "POST", done: "Wieder offen") }
                    }
                } else if (p.s("date") ?? "") <= UFFmt.todayISO() {
                    UFButton("Abhaken mit Zeit", icon: "check", kind: .primary, size: .small) { overlay.modal { BlockDoneDialog(package: p) } }
                }
                UFButton("Stoppuhr", icon: "play", size: .small) {
                    Task {
                        _ = await GoalsActions.send(session.api, toast, router, "Stoppuhr", "/api/sessions/start", method: "POST",
                                                    body: ["module_id": .number(Double(p.i("module_id") ?? 0)), "package_id": .number(Double(id))],
                                                    done: "Stoppuhr läuft")
                    }
                }
                UFButton(locked ? "Entsperren" : "Sperren", icon: "flag", size: .small) {
                    Task {
                        _ = await GoalsActions.send(session.api, toast, router, "Sperren", "/api/goals/blocks/\(id)", method: "PATCH",
                                                    body: ["locked": .bool(!locked)], done: locked ? "Entsperrt" : "Gesperrt: bleibt, wo er ist")
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.infoSoft))
        .padding(.top, 12)
    }

    /// Verschieben mit sofortiger Konfliktprüfung: Termine, Sperrzeiten, andere Blöcke, Klausurtag
    @MainActor
    static func move(_ p: JSONValue, to date: String, api: APIClient?, overlay: UFOverlay, toast: UFToastCenter, router: UFRouter) async {
        guard let api, let id = p.i("id") else { return }
        var check: JSONValue = .null
        guard await toast.attempt("Prüfen", { check = try await api.value("/api/goals/blocks/\(id)/check", method: "POST", body: ["date": .string(date)]) }) else { return }
        let conflicts = check.list("conflicts").compactMap { $0.s("text") }
        if !conflicts.isEmpty {
            guard await overlay.confirm("Konflikt am neuen Tag:\n" + conflicts.joined(separator: "\n") + "\nTrotzdem verschieben?") else { return }
        }
        if await toast.attempt("Verschieben", { _ = try await api.value("/api/packages/\(id)", method: "PATCH", body: ["date": .string(date)]) }) {
            toast.show("Verschoben – der Block bleibt jetzt dort")
            router.reload()
        }
    }
}
