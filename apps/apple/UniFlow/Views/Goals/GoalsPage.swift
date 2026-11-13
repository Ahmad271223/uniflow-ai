import SwiftUI
import UniFlowCore

/// Smart Planner 2.0 (Auftrag des Inhabers vom 12.11.2026): Lernziele in Stunden im Lernkalender (Ansicht "Lernziele",
/// `#/plan?view=ziele`). Übersicht: Tage bis zur nächsten Klausur, Ziel/gelernt/fehlt je Modul, Plan dieser Woche,
/// Prognose, Konflikte, Vorschläge bei Unterdeckung. Daten: `GET /api/goals` (rechnet ohne KI und plant nur bei
/// geänderten Eingaben um). Jeder Abschnitt ist ein eigener kleiner View-Typ (`ViewTypeDepthAppTests`).
struct GoalsPage: View {
    let onView: (String) -> Void
    @EnvironmentObject private var session: Session
    @State private var o: JSONValue?
    @State private var error: String?

    var body: some View {
        UFContent(wide: true, maxWidth: 1400, insets: EdgeInsets(top: 20.8, leading: 24, bottom: 48, trailing: 24)) {
            GoalsHead(o: o, onView: onView)
            if let o {
                GoalsBody(o: o)
            } else if let error {
                UFEmpty(icon: "alert", text: error)
            } else {
                UFSkeleton().frame(height: 380)
            }
        }
        .task { await load() }
        .ufReload { await load() }
    }

    private func load() async {
        guard let api = session.api else { error = "Nicht mit dem Server verbunden."; return }
        do {
            o = try await api.value("/api/goals")
            error = nil
        } catch {
            if o == nil { self.error = error.localizedDescription }
        }
    }
}

/// Stunden wie im Rechenkern: "12,5 h", "320 h"
enum GoalsFmt {
    static func h(_ minutes: Double?) -> String {
        let m = Int(minutes ?? 0)
        let tenths = (abs(m) * 10 + 30) / 60
        let t = tenths % 10 == 0 ? "\(tenths / 10) h" : "\(tenths / 10),\(tenths % 10) h"
        return m < 0 ? "-" + t : t
    }

    static let status: [String: (String, UFTone)] = [
        "auf_kurs": ("Auf Kurs", .ok), "knapp": ("Knapp", .warn), "gefaehrdet": ("Gefährdet", .bad),
        "erreicht": ("Ziel erreicht", .ok), "vorbei": ("Klausur vorbei", .neutral),
    ]

    static func days(_ n: Int?) -> String {
        guard let n else { return "kein Termin" }
        if n == 0 { return "heute" }
        return n == 1 ? "morgen" : "in \(n) Tagen"
    }

    /// Wochentag aus dem ISO-Tag (Mo ... So)
    static func weekday(_ iso: String?) -> String {
        guard let d = Fmt.date(iso ?? "") else { return "" }
        let wd = (Calendar(identifier: .gregorian).component(.weekday, from: d) + 5) % 7
        return ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"][wd]
    }
}

/// Kopf: Titel, Ansichten des Lernkalenders, Zeitrahmen, Zeit eintragen, Plan erstellen
struct GoalsHead: View {
    let o: JSONValue?
    let onView: (String) -> Void
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter

    var body: some View {
        UFPageHead("Lernziele", sub: "Wie viele Stunden du bis zur Klausur lernen willst – StudiNow verteilt sie auf deine freie Zeit.") {
            UFButton("Zeitrahmen", icon: "clock") { overlay.modal { GoalSettingsDialog() } }
            UFButton("Zeit eintragen", icon: "plus") {
                let mods = o?.list("modules") ?? []
                overlay.modal { SessionEntryDialog(modules: mods, moduleID: mods.first?.i("module_id")) }
            }
            .disabled((o?.list("modules") ?? []).isEmpty)
            GoalsPlanButton(o: o)
        }
        UFSegPill(options: PlanViews.all, selection: "ziele") { v in onView(v) }
            .padding(.bottom, 16)
    }
}

/// "Plan erstellen" / "Neu verteilen": automatisch planen ab Plus (lokal), wie "Plan erstellen" im Kalender
struct GoalsPlanButton: View {
    let o: JSONValue?
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter

    var body: some View {
        let planned = o?["planned"]?.bool == true
        let b = UFButton(planned ? "Neu verteilen" : "Plan erstellen", icon: "sparkles", kind: .primary) { Task { await GoalsActions.plan(session.api, toast, router, [:]) } }
            .disabled((o?.list("modules") ?? []).isEmpty)
        if session.api?.isLocal != false { b.ufRequires(.autoPlan) } else { b }
    }
}

/// Aufrufe, die mehrere Ansichten teilen
@MainActor
enum GoalsActions {
    static func plan(_ api: APIClient?, _ toast: UFToastCenter, _ router: UFRouter, _ body: JSONValue) async {
        guard let api else { return }
        // automatisch planen ab Plus (am PC/Dienst entscheidet der Server), auch über die Optionen bei Unterdeckung
        if api.isLocal && !Entitlements.shared.allows(.autoPlan) {
            toast.show("Lernblöcke automatisch planen gibt es ab Plus. Ziele und Lernzeit kannst du weiter eintragen.", seconds: 5)
            router.reload()
            return
        }
        var result: JSONValue = .null
        guard await toast.attempt("Planen", { result = try await api.value("/api/goals/plan", method: "POST", body: body) }) else { return }
        if result["applied"]?.bool == true {
            let ch = result["change"]
            toast.show("Lernplan steht: \(ch?.i("added") ?? 0) neue, \(ch?.i("removed") ?? 0) entfernte Lernblöcke", seconds: 4)
        } else {
            toast.show(result["result"]?.s("message") ?? "Zu wenig Zeit – wähle unten eine Option.", seconds: 5)
        }
        router.reload()
    }

    static func send(_ api: APIClient?, _ toast: UFToastCenter, _ router: UFRouter, _ label: String, _ path: String,
                     method: String, body: JSONValue? = nil, done: String? = nil) async -> JSONValue? {
        guard let api else { return nil }
        var out: JSONValue?
        guard await toast.attempt(label, { out = try await api.value(path, method: method, body: body) }) else { return nil }
        if let done { toast.show(done) }
        router.reload()
        return out
    }
}

/// Die Ansichten des Lernkalenders samt "Lernziele" (eine Liste für Kalender und Lernziele)
enum PlanViews {
    static let all: [(value: String, label: String, icon: String?)] = [
        ("ziele", "Lernziele", "flag"), ("day", "Tag", nil), ("3days", "3 Tage", nil), ("week", "Woche", nil), ("month", "Monat", nil),
        ("list", "Liste", "list"),
    ]
}

/// Inhalt: Vorschlag, Stoppuhr, Kennzahlen, Machbarkeit, Module, Woche, Konflikte
struct GoalsBody: View {
    let o: JSONValue
    @Environment(\.ufWindowWidth) private var windowWidth

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let p = o["proposal"], p.object != nil { GoalsProposalBanner(p: p) }
            if !o.list("running").isEmpty { GoalsTimerBar(running: o.list("running"), modules: o.list("modules")) }
            if o.list("modules").isEmpty {
                GoalsStartCard(others: o.list("modules_without_goal"))
            } else {
                GoalsKPIRow(o: o)
                if let plan = o["plan"], plan.object != nil, plan.s("status") != "ok" { GoalsFeasibilityCard(plan: plan, o: o) }
                if windowWidth > 1100 {
                    HStack(alignment: .top, spacing: 16) {
                        GoalsModulesCard(o: o)
                        GoalsSideColumn(o: o).frame(width: 340)
                    }
                } else {
                    GoalsModulesCard(o: o)
                    GoalsSideColumn(o: o)
                }
                if !o.list("modules_without_goal").isEmpty { GoalsOthersCard(others: o.list("modules_without_goal")) }
            }
        }
    }
}

struct GoalsSideColumn: View {
    let o: JSONValue
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GoalsWeekCard(week: o["week"] ?? .null)
            GoalsConflictsCard(conflicts: o.list("conflicts"))
        }
    }
}

/// Erste Schritte: noch kein Lernziel
struct GoalsStartCard: View {
    let others: [JSONValue]
    @EnvironmentObject private var overlay: UFOverlay

    var body: some View {
        UFCard {
            UFCardHead("Lernziele festlegen", icon: "flag")
            Text("Trage je Modul ein, wie viele Stunden du bis zur Klausur selbst lernen willst (zum Beispiel Mathematik 200 h). StudiNow plant daraus Lernblöcke in deine freie Zeit – nie über Vorlesungen, nie nach der Klausur.")
                .ufFont(14).foregroundStyle(UF.text2)
                .padding(.bottom, 12)
            if others.isEmpty {
                Text("Noch keine Module. Verbinde Stud.IP oder lege Module an.").ufFont(13.12).foregroundStyle(UF.muted)
            }
            UFFlexWrap(gap: 8) {
                ForEach(Row.rows(others, key: "module_id")) { r in
                    UFButton(r.value.s("name") ?? "Modul", icon: "plus", size: .small) { overlay.modal { GoalEditDialog(module: r.value) } }
                }
            }
        }
    }
}

/// Module ohne Lernziel
struct GoalsOthersCard: View {
    let others: [JSONValue]
    @EnvironmentObject private var overlay: UFOverlay

    var body: some View {
        UFCard {
            UFCardHead("Module ohne Lernziel", icon: "book")
            UFFlexWrap(gap: 8) {
                ForEach(Row.rows(others, key: "module_id")) { r in
                    UFButton(r.value.s("name") ?? "Modul", icon: "plus", size: .small) { overlay.modal { GoalEditDialog(module: r.value) } }
                }
            }
        }
    }
}

/// Kennzahlen: nächste Klausur, Woche geplant/gelernt, Ziel gesamt, fehlt gesamt
struct GoalsKPIRow: View {
    let o: JSONValue

    var body: some View {
        let mods = o.list("modules")
        let target = mods.reduce(0.0) { $0 + ($1.n("target_minutes") ?? 0) }
        let missing = mods.reduce(0.0) { $0 + ($1["stats"]?.n("remaining_minutes") ?? 0) }
        let next = o["next_exam"]
        UFCard {
            UFGridLayout(columns: 4) {
                UFKPI(value: next?.i("days").map { "\($0)" } ?? "–",
                      label: next.flatMap { $0.s("name") }.map { "Tage bis \($0)" } ?? "Keine Klausur geplant")
                UFKPI(value: GoalsFmt.h(o["week"]?.n("planned_minutes")), label: "Diese Woche geplant")
                UFKPI(value: GoalsFmt.h(o["week"]?.n("learned_minutes")), label: "Diese Woche gelernt")
                UFKPI(value: GoalsFmt.h(missing), label: "Fehlt noch von \(GoalsFmt.h(target))")
            }
        }
    }
}

/// Größere Umplanung oder Unterdeckung: der Nutzer entscheidet
struct GoalsProposalBanner: View {
    let p: JSONValue
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter

    var body: some View {
        let short = p.s("kind") == "unterdeckt"
        UFFlexWrap(gap: 9.6) {
            HStack(spacing: 6) {
                UFIcon("alert", size: 16)
                Text(short ? "Die Zeit reicht nicht mehr: \(p.s("message") ?? "")" : (p.s("message") ?? "Dein Plan sollte neu verteilt werden."))
            }
            .ufFont(14.5, 700).foregroundStyle(short ? UF.bad : UF.warnText)
            UFFlexSpacer()
            if !short {
                UFButton("Neu verteilen", kind: .primary, size: .small) { Task { await GoalsActions.plan(session.api, toast, router, [:]) } }
            }
            UFButton("Alten Plan behalten", size: .small) {
                Task { _ = await GoalsActions.send(session.api, toast, router, "Behalten", "/api/goals/plan/keep", method: "POST", done: "Plan bleibt wie er ist") }
            }
        }
        .padding(.vertical, 14 + ufB).padding(.horizontal, 18 + ufB)
        .background(RoundedRectangle(cornerRadius: UF.r).fill(short ? UF.badSoft : UF.warnSoft))
    }
}

/// Unterdeckung: Erklärung und Optionen; nichts wird ohne Antippen geändert
struct GoalsFeasibilityCard: View {
    let plan: JSONValue
    let o: JSONValue

    var body: some View {
        UFCard {
            UFCardHead(plan.s("status") == "teilplan" ? "Teilplan: nicht alle Stunden passen" : "Zu wenig Zeit bis zu den Klausuren", icon: "alert")
            if let m = plan.s("message") { Text(m).ufFont(16, 700).foregroundStyle(UF.bad).padding(.bottom, 6) }
            ForEach(Row.rows(plan.list("deadlines"), key: "date")) { r in
                GoalsDeadlineLine(d: r.value, modules: o.list("modules"))
            }
            Text("Was möchtest du tun? StudiNow ändert nichts, bevor du eine Option wählst.")
                .ufFont(13.12).foregroundStyle(UF.muted).padding(.vertical, 8)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(plan.list("options").enumerated()), id: \.offset) { _, opt in GoalsOptionRow(opt: opt, o: o) }
            }
        }
    }
}

struct GoalsDeadlineLine: View {
    let d: JSONValue
    let modules: [JSONValue]

    var body: some View {
        let names = d.list("modules").compactMap { id in modules.first { $0["module_id"] == id }?.s("name") }.joined(separator: ", ")
        let missing = (d.n("missing_minutes") ?? 0) > 0
        HStack(spacing: 8) {
            Text("bis \(UFFmt.short(d.s("date")))").ufFont(13.6, 650).frame(width: 90, alignment: .leading)
            Text("\(GoalsFmt.h(d.n("need_minutes"))) nötig, \(GoalsFmt.h(d.n("available_minutes"))) verfügbar")
                .ufFont(13.6).foregroundStyle(UF.text2)
            if missing { UFBadge("fehlen \(GoalsFmt.h(d.n("missing_minutes")))", tone: .bad) }
            Text(names).ufFont(12.8).foregroundStyle(UF.muted).lineLimit(1)
        }
    }
}

/// Eine Option: Text und "Übernehmen" (nach Rückfrage), danach wird neu geplant
struct GoalsOptionRow: View {
    let opt: JSONValue
    let o: JSONValue
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter

    var body: some View {
        HStack(spacing: 9.6) {
            Text(opt.s("text") ?? "").ufFont(14).foregroundStyle(UF.text).frame(maxWidth: .infinity, alignment: .leading)
            if actionable { UFButton("Übernehmen", size: .small) { Task { await apply() } } }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: UF.rSm).fill(UF.surface2))
    }

    private var actionable: Bool {
        switch opt.s("kind") {
        case "nutzungsquote": return opt.i("value") != nil
        case "freizeit": return opt.i("minutes_per_day") != nil
        case "ziele", "zweittermin", "teilplan": return true
        default: return false
        }
    }

    private func apply() async {
        guard await overlay.confirm("\(opt.s("text") ?? "Option") – übernehmen und neu planen?") else { return }
        let api = session.api
        let s = o["settings"]
        switch opt.s("kind") {
        case "nutzungsquote":
            guard await GoalsActions.send(api, toast, router, "Speichern", "/api/goals/settings", method: "PUT", body: ["utilization": .number(Double(opt.i("value") ?? 60))]) != nil else { return }
        case "freizeit":
            let left = max(0, (s?.i("leisure_minutes") ?? 120) - (opt.i("minutes_per_day") ?? 0))
            guard await GoalsActions.send(api, toast, router, "Speichern", "/api/goals/settings", method: "PUT", body: ["leisure_minutes": .number(Double(left))]) != nil else { return }
        case "ziele":
            for c in opt.list("cuts") {
                guard let mid = c.i("module_id"), let m = o.list("modules").first(where: { $0.i("module_id") == mid }) else { continue }
                let hours = max(0, ((m.n("target_minutes") ?? 0) - (c.n("minutes") ?? 0)) / 60)
                guard await GoalsActions.send(api, toast, router, "Ziel", "/api/goals/\(mid)", method: "PUT", body: ["target_hours": .number((hours * 10).rounded(.down) / 10)]) != nil else { return }
            }
        case "zweittermin":
            guard let mid = opt.i("module_id"),
                  await GoalsActions.send(api, toast, router, "Zweittermin", "/api/goals/\(mid)", method: "PUT",
                                          body: ["exam_attempt": 2, "exam_date_2": .string(opt.s("date") ?? "")]) != nil else { return }
        case "teilplan":
            await GoalsActions.plan(api, toast, router, ["accept_partial": true])
            return
        default:
            return
        }
        await GoalsActions.plan(api, toast, router, [:])
    }
}

/// Module: Ziel, gelernt, fehlt, Tage, Stunden je Woche, Prognose
struct GoalsModulesCard: View {
    let o: JSONValue

    var body: some View {
        UFCard {
            UFCardHead("Module", icon: "book")
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Row.rows(o.list("modules"), key: "module_id")) { r in GoalsModuleRow(m: r.value, all: o.list("modules")) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct GoalsModuleRow: View {
    let m: JSONValue
    let all: [JSONValue]
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter

    var body: some View {
        let st = m["stats"] ?? .null
        let target = st.n("target_minutes") ?? 0
        let done = (st.n("learned_minutes") ?? 0) + (st.n("lecture_minutes") ?? 0)
        let color = Color(hex: m.s("color"))
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4)
            VStack(alignment: .leading, spacing: 6) {
                GoalsModuleTitle(m: m)
                UFProgress(value: target > 0 ? done / target : 1, color: color, track: color.opacity(0.15), height: 7)
                Text(GoalsModuleRow.numbers(st)).ufFont(13.12).foregroundStyle(UF.text2)
                UFFlexWrap(gap: 8) {
                    UFButton("Ziel", icon: "pencil", size: .small) { overlay.modal { GoalEditDialog(module: m) } }
                    UFButton("Starten", icon: "play", size: .small) {
                        Task {
                            _ = await GoalsActions.send(session.api, toast, router, "Stoppuhr", "/api/sessions/start", method: "POST",
                                                        body: ["module_id": .number(Double(m.i("module_id") ?? 0))], done: "Stoppuhr läuft")
                        }
                    }
                    UFButton("Zeit eintragen", icon: "plus", size: .small) {
                        overlay.modal { SessionEntryDialog(modules: all, moduleID: m.i("module_id")) }
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    static func numbers(_ st: JSONValue) -> String {
        var parts = ["Ziel \(GoalsFmt.h(st.n("target_minutes")))", "gelernt \(GoalsFmt.h(st.n("learned_minutes")))"]
        if (st.n("lecture_minutes") ?? 0) > 0 { parts.append("Veranstaltungen \(GoalsFmt.h(st.n("lecture_minutes")))") }
        parts.append("fehlt \(GoalsFmt.h(st.n("remaining_minutes")))")
        if let w = st.n("per_week_minutes") { parts.append("\(GoalsFmt.h(w)) pro Woche") }
        parts.append("Prognose \(st.i("forecast_percent") ?? 0) %")
        return parts.joined(separator: " · ")
    }
}

struct GoalsModuleTitle: View {
    let m: JSONValue
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter

    var body: some View {
        let st = m["stats"] ?? .null
        let label = GoalsFmt.status[st.s("status") ?? ""] ?? ("", .neutral)
        UFFlexWrap(gap: 8) {
            Text(m.s("name") ?? "").ufFont(15, 700).foregroundStyle(UF.text)
            if m["writing"]?.bool == false {
                UFBadge("schreibe ich nicht", tone: .neutral)
            } else if let d = m.s("exam_date") {
                Text("Klausur \(UFFmt.short(d)) · \(GoalsFmt.days(st.i("days_left")))").ufFont(13.12).foregroundStyle(UF.text2)
                if m.s("exam_source") == "zweittermin" { UFBadge("Zweittermin", tone: .info) }
                if m["exam_confirmed"]?.bool == false {
                    UFBadge("unbestätigt", tone: .warn)
                    UFButton("Bestätigen", size: .small) {
                        Task {
                            _ = await GoalsActions.send(session.api, toast, router, "Bestätigen", "/api/goals/\(m.i("module_id") ?? 0)",
                                                        method: "PUT", body: ["confirm_exam": true], done: "Klausurtermin bestätigt")
                        }
                    }
                }
            } else {
                UFBadge("Klausurtermin fehlt", tone: .warn)
            }
            UFFlexSpacer()
            if !label.0.isEmpty { UFBadge(label.0, tone: label.1) }
        }
    }
}

/// Plan dieser Woche: geplant gegen gelernt je Tag
struct GoalsWeekCard: View {
    let week: JSONValue

    var body: some View {
        let days = week.list("days")
        let top = max(60, days.map { max($0.n("planned_minutes") ?? 0, $0.n("learned_minutes") ?? 0) }.max() ?? 60)
        UFCard {
            UFCardHead("Diese Woche", icon: "calendar")
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Row.rows(days, key: "date")) { r in GoalsWeekDay(d: r.value, top: top) }
            }
            HStack(spacing: 12) {
                Label { Text("geplant").ufFont(12) } icon: { RoundedRectangle(cornerRadius: 2).fill(UF.info.opacity(0.35)).frame(width: 12, height: 8) }
                Label { Text("gelernt").ufFont(12) } icon: { RoundedRectangle(cornerRadius: 2).fill(UF.ok).frame(width: 12, height: 8) }
            }
            .foregroundStyle(UF.muted).padding(.top, 8)
        }
    }
}

struct GoalsWeekDay: View {
    let d: JSONValue
    let top: Double

    var body: some View {
        let planned = d.n("planned_minutes") ?? 0, learned = d.n("learned_minutes") ?? 0
        HStack(spacing: 8) {
            Text(GoalsFmt.weekday(d.s("date"))).ufFont(13, 650).frame(width: 26, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(UF.info.opacity(0.35)).frame(width: max(0, planned / top) * g.size.width)
                    Capsule().fill(UF.ok).frame(width: max(0, min(1, learned / top)) * g.size.width, height: 5)
                }
            }
            .frame(height: 9)
            Text("\(GoalsFmt.h(learned)) / \(GoalsFmt.h(planned))").ufFont(12.5).foregroundStyle(UF.text2).frame(width: 96, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Konflikte: gesperrte/verschobene Blöcke über Terminen oder nach der Klausur, unbestätigte Termine, Unterdeckung,
/// Unterlagen ohne Platz im Stundenbudget
struct GoalsConflictsCard: View {
    let conflicts: [JSONValue]
    @EnvironmentObject private var overlay: UFOverlay

    var body: some View {
        UFCard {
            UFCardHead("Konflikte", icon: "alert")
            if conflicts.isEmpty {
                Text("Keine Konflikte.").ufFont(13.12).foregroundStyle(UF.muted)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(conflicts.prefix(12).enumerated()), id: \.offset) { _, c in
                    Button {
                        if let id = c.i("package_id") { overlay.openDrawer { PackageDrawer(id: id) } }
                    } label: {
                        HStack(alignment: .top, spacing: 6) {
                            UFIcon(c.s("kind") == "material" ? "file-text" : "alert", size: 14).foregroundStyle(c.s("kind") == "unbestaetigt" ? UF.warnText : UF.bad)
                            Text(c.s("text") ?? "").ufFont(13.12).foregroundStyle(UF.text2).multilineTextAlignment(.leading)
                        }
                    }
                    .buttonStyle(.plain)
                }
                if conflicts.count > 12 { Text("und \(conflicts.count - 12) weitere").ufFont(12.5).foregroundStyle(UF.muted) }
            }
        }
    }
}

/// Laufende Stoppuhr(en): Zeit läuft sichtbar mit; Pause, Weiter, Stopp
struct GoalsTimerBar: View {
    let running: [JSONValue]
    let modules: [JSONValue]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Row.rows(running, key: "uuid")) { r in GoalsTimerRow(s: r.value, name: name(r.value)) }
        }
    }

    private func name(_ s: JSONValue) -> String {
        modules.first { $0["module_id"] == s["module_id"] }?.s("name") ?? "Lernzeit"
    }
}

struct GoalsTimerRow: View {
    let s: JSONValue
    let name: String
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter

    var body: some View {
        let uid = s.s("uuid") ?? ""
        let paused = s.s("state") == "pause"
        HStack(spacing: 10) {
            UFIcon("clock", size: 18).foregroundStyle(paused ? UF.muted : UF.ok)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text("\(name): \(GoalsTimerRow.elapsed(s, now: ctx.date))\(paused ? " (Pause)" : "")")
                    .ufFont(14.5, 700).foregroundStyle(UF.text).monospacedDigit()
            }
            UFFlexSpacer()
            UFButton(paused ? "Weiter" : "Pause", icon: paused ? "play" : "clock", size: .small) {
                Task {
                    if paused {
                        _ = await GoalsActions.send(session.api, toast, router, "Stoppuhr", "/api/sessions/\(uid)/resume", method: "POST")
                    } else {
                        _ = await GoalsActions.send(session.api, toast, router, "Stoppuhr", "/api/sessions/\(uid)/pause", method: "POST")
                    }
                }
            }
            UFButton("Beenden", icon: "check", kind: .primary, size: .small) {
                Task {
                    if let r = await GoalsActions.send(session.api, toast, router, "Beenden", "/api/sessions/\(uid)/stop", method: "POST") {
                        toast.show("\(GoalsFmt.h(r.n("credited_minutes"))) gelernt – gespeichert")
                    }
                }
            }
        }
        .padding(.vertical, 12 + ufB).padding(.horizontal, 16 + ufB)
        .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.okSoft))
    }

    /// Summe der Abschnitte (offener Abschnitt bis jetzt) als H:MM:SS
    static func elapsed(_ s: JSONValue, now: Date) -> String {
        let t = Int(now.timeIntervalSince1970)
        var sec = 0
        for seg in s.list("segments") {
            guard let a = seg.array, a.count >= 2, let start = a[0].int else { continue }
            sec += max(0, (a[1].int ?? t) - start)
        }
        return String(format: "%d:%02d:%02d", sec / 3600, sec / 60 % 60, sec % 60)
    }
}
