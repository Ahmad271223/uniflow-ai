import SwiftUI
import UniFlowCore

/// Lernkalender 1:1 nach viewPlan() in app/static/views-plan.js: Kopf mit Aktionen, Nachhol-Banner, Leiste
/// (Tag/3 Tage/Woche/Monat/Liste, ‹ ›, Zeitraum, Heute, Modulfilter, Lernkombination, Seitenspalte), Inhalt je
/// Ansicht und Seitenspalte (Fortschritt, Nicht erledigt, Schnell hinzufügen, Mini-Kalender bzw. Tagesübersicht).
struct PlanView: View {
    let params: (view: String?, date: String?, module: String?)
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var router: UFRouter
    @Environment(\.ufWindowWidth) private var windowWidth
    @AppStorage("cal-side") private var calSide = ""                 // localStorage "cal-side": "on" | "off"
    @State private var data: PlanData?
    @State private var error: String?

    /// planState im Web: bleibt fuer die Sitzung erhalten
    @MainActor static var state = (view: "week", date: UFFmt.todayISO(), module: "")

    private var actions: PlanActions { PlanEnv.make(session, overlay, toast, router) }

    var body: some View {
        Group {
            if let data {
                content(data)
            } else if let error {
                UFContent { UFEmpty(icon: "alert", text: error) }
            } else {
                UFContent {
                    UFSkeleton().frame(width: 280, height: 28).padding(.bottom, 16)
                    UFSkeleton().frame(height: 420)
                }
            }
        }
        .task(id: key) { await load() }
        .ufReload { await load() }
    }

    private var key: String { "\(params.view ?? "")|\(params.date ?? "")|\(params.module ?? "")" }

    // MARK: Laden

    private func load() async {
        if let v = params.view { Self.state.view = v }
        if let d = params.date { Self.state.date = d }
        if let m = params.module { Self.state.module = m }
        guard let api = session.api else { error = "Nicht mit dem Server verbunden."; return }
        let st = Self.state
        let d = Fmt.date(st.date) ?? Date()
        let (start, end) = PlanData.range(view: st.view, date: d)
        let (mStart, mEnd) = PlanData.range(view: "month", date: d)
        do {
            async let cal = api.value("/api/calendar?start=\(Fmt.isoDay(start))&end=\(Fmt.isoDay(end))")
            async let open = api.value("/api/tasks/open")
            async let mods = api.value("/api/modules")
            let month: JSONValue? = st.view == "month" ? nil : try await api.value("/api/calendar?start=\(Fmt.isoDay(mStart))&end=\(Fmt.isoDay(mEnd))")
            var pd = PlanData(view: st.view, date: d, start: start, end: end, module: st.module, cal: try await cal, open: try await open,
                              modules: try await mods, month: month)
            if st.view == "week" || st.view == "3days" {
                for w in Set([PlanData.monday(start), PlanData.monday(end)]) {
                    if let tw = try? await api.value("/api/timetable/week?start=\(Fmt.isoDay(w))") {
                        for x in tw.list("days") { if let k = x.s("date") { pd.free[k] = x.list("free") } }
                    }
                }
            }
            if st.view == "day" { pd.dayTT = try? await api.value("/api/timetable/day?date=\(st.date)") }
            data = pd
            error = nil
        } catch {
            if data == nil { self.error = error.localizedDescription }
        }
    }

    /// go(v, date): Hash setzen (Modulfilter bleibt erhalten)
    private func go(_ view: String, _ date: String) {
        router.go(.plan(view: view, date: date, module: Self.state.module.isEmpty ? nil : Self.state.module))
    }

    // MARK: Inhalt

    @ViewBuilder private func content(_ d: PlanData) -> some View {
        let backlog = d.open.filter { $0.s("status") == "nachholen" }
        let wk = d.view == "week" || d.view == "3days"
        let sideOff = wk && (calSide.isEmpty ? windowWidth < 1400 : calSide == "off")
        UFContent(wide: true, maxWidth: 1600, insets: EdgeInsets(top: 20.8, leading: 24, bottom: 48, trailing: 24)) {
            // ohne PC keine Wochentests (KI, entfallen in V1): nicht ankuendigen
            UFPageHead("Lernkalender", sub: session.api?.isLocal == true ? "Dein Wochenplan – perfekt auf Vorlesungen und Übungen abgestimmt."
                                                                       : "Dein Wochenplan – perfekt auf Vorlesungen, Übungen und Tests abgestimmt.") {
                UFButton("Lernpaket", icon: "plus") { actions.addPackage(date: Fmt.isoDay(d.view == "day" ? d.date : d.start)) }
                UFButton("Lernkombination", icon: "settings") { actions.config() }
                UFButton("Woche retten", icon: "life-buoy") { Task { await actions.suggest(["rescue": true]) } }
                    .disabled(backlog.isEmpty)
                    .help(backlog.isEmpty ? "Nichts nachzuholen" : "")
                UFButton("Plan erstellen", icon: "sparkles", kind: .primary) { actions.generatePlan(Fmt.isoDay(d.view == "week" ? d.start : d.date)) }
            }
            if !backlog.isEmpty { backlogBanner(backlog, d) }
            if windowWidth > 1100 || sideOff {
                HStack(alignment: .top, spacing: 16) {
                    mainCard(d, wk: wk)
                    if !sideOff { PlanSide(d: d, backlog: backlog).frame(width: 286) }
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {                  // <= 1100: Seitenspalte darunter, Karten nebeneinander
                    mainCard(d, wk: wk)
                    PlanSide(d: d, backlog: backlog, wrap: true)
                }
            }
        }
    }

    private func backlogBanner(_ backlog: [JSONValue], _ d: PlanData) -> some View {
        UFFlexWrap(gap: 9.6) {
            HStack(spacing: 6) {
                UFIcon("alert", size: 16)
                Text("\(backlog.count) Aufgabe\(backlog.count > 1 ? "n müssen" : " muss") nachgeholt werden")
            }
            .ufFont(14.5, 700).foregroundStyle(UF.bad)
            UFFlexSpacer()
            UFButton("Jetzt nachholen", size: .small) { go("list", Self.state.date) }
            UFButton("Neu einplanen", kind: .primary, size: .small) { Task { await actions.suggest([:]) } }
            UFButton("Bewusst überspringen", kind: .ghost, size: .small) {
                Task {
                    if await overlay.confirm("\(backlog.count) offene Aufgaben als bewusst übersprungen markieren?") {
                        _ = try? await session.api?.value("/api/tasks/skip", method: "POST",
                                                          body: ["task_ids": .array(backlog.compactMap { $0.i("id") }.map { .number(Double($0)) })])
                        toast.show("Übersprungen")
                        router.reload()
                    }
                }
            }
        }
        .padding(.vertical, 17.6 + ufB).padding(.horizontal, 19.2 + ufB)
        .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.badSoft))
        .ufShadow(.sm)
        .padding(.bottom, 16)
    }

    // MARK: Hauptkarte (.cal2-main)

    private func mainCard(_ d: PlanData, wk: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            bar(d, wk: wk).padding(.bottom, 14.4)
            switch d.view {
            case "week", "3days": PlanWeekGrid(d: d)
            case "month": PlanMonthGrid(d: d)
            case "day": PlanDayTimeline(d: d)
            default: PlanTaskList(open: d.open)
            }
        }
        .padding(EdgeInsets(top: 14.4 + ufB, leading: 16 + ufB, bottom: 16 + ufB, trailing: 16 + ufB))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: UF.rLg).fill(UF.surface))
        .overlay(RoundedRectangle(cornerRadius: UF.rLg).strokeBorder(UF.line, lineWidth: 1))
        .ufShadow(.sm)
    }

    /// .cal2-bar
    private func bar(_ d: PlanData, wk: Bool) -> some View {
        let views: [(value: String, label: String, icon: String?)] = [("day", "Tag", nil), ("3days", "3 Tage", nil), ("week", "Woche", nil), ("month", "Monat", nil), ("list", "Liste", "list")]
        let modOptions: [(value: String, label: String)] = [("", "Alle Module")] + d.modules.compactMap { m in m.i("id").map { ("\($0)", UFFmt.shortName(m.s("name"))) } }
        return UFFlexWrap(gap: 8) {
            UFSegPill(options: views, selection: d.view) { v in go(v, Self.state.date) }
            UFFlexSpacer(max: 24)
            UFButton(icon: "chevron-left") { go(d.view, d.step(-1)) }
            HStack(spacing: 8) { UFIcon("calendar", size: 17); Text(d.label) }                 // .cal2-title
                .ufFont(16, 650).foregroundStyle(UF.text)
                .frame(minWidth: 250)
            UFButton(icon: "chevron-right") { go(d.view, d.step(1)) }
            UFFlexSpacer()
            UFButton("Heute") { go(d.view, UFFmt.todayISO()) }
            UFSelect(options: modOptions, selection: Binding(get: { Self.state.module }, set: { m in
                Self.state.module = m
                router.go(.plan(view: d.view, date: Self.state.date, module: m))
            }))
            UFButton(icon: "settings") { actions.config() }.help("Lernkombination")
            if wk {
                UFButton(icon: "panel-right") {
                    let off = !(calSide.isEmpty ? windowWidth < 1400 : calSide == "off")
                    calSide = off ? "off" : "on"
                }
                .help("Seitenspalte ein-/ausblenden")
            }
        }
    }
}

// MARK: - Daten einer Kalenderansicht

struct PlanData {
    let view: String
    let date: Date
    let start: Date
    let end: Date
    let module: String
    let cal: JSONValue
    let open: [JSONValue]
    let modules: [JSONValue]
    let month: JSONValue?
    var free: [String: [JSONValue]] = [:]
    var dayTT: JSONValue?

    init(view: String, date: Date, start: Date, end: Date, module: String, cal: JSONValue, open: JSONValue, modules: JSONValue, month: JSONValue?) {
        self.view = view; self.date = date; self.start = start; self.end = end; self.module = module
        self.cal = cal; self.open = open.items; self.modules = modules.items; self.month = month
    }

    static var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2
        return c
    }

    static func add(_ d: Date, _ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: d) ?? d }
    static func monday(_ d: Date) -> Date { add(cal.startOfDay(for: d), -((cal.component(.weekday, from: d) + 5) % 7)) }

    /// Zeitraum wie in viewPlan (Woche Mo–So, 3 Tage ab Datum, Monat in ganzen Wochen, sonst der Tag)
    static func range(view: String, date d: Date) -> (Date, Date) {
        switch view {
        case "week": let s = monday(d); return (s, add(s, 6))
        case "3days": return (d, add(d, 2))
        case "month":
            let comps = cal.dateComponents([.year, .month], from: d)
            let first = cal.date(from: comps) ?? d
            let last = cal.date(byAdding: DateComponents(month: 1, day: -1), to: first) ?? d
            return (monday(first), add(monday(last), 6))
        default: return (d, d)
        }
    }

    var moduleFilter: Int? { Int(module) }

    /// Tage mit Modulfilter (filt in viewPlan)
    var days: [JSONValue] {
        cal.list("days").map { dd in
            guard let m = moduleFilter, var o = dd.object else { return dd }
            o["events"] = .array(dd.list("events").filter { $0.i("module_id") == m })
            o["packages"] = .array(dd.list("packages").filter { $0.i("module_id") == m })
            return .object(o)
        }
    }

    var monthCal: JSONValue { month ?? cal }

    /// Zeitraum-Titel
    var label: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        switch view {
        case "week", "3days":
            f.dateFormat = "d. MMMM"
            let a = f.string(from: start)
            f.dateFormat = "d. MMMM y"
            return "\(a) – \(f.string(from: end))"
        case "month":
            f.dateFormat = "LLLL y"
            return f.string(from: date)
        default:
            f.dateFormat = "EEEE, d. MMMM y"
            return f.string(from: date)
        }
    }

    /// ‹ / ›: Monat ±1, Woche ±7, 3 Tage ±3, Tag/Liste ±1
    func step(_ n: Int) -> String {
        if view == "month" {
            let c = Self.cal.dateComponents([.year, .month], from: date)
            let first = Self.cal.date(from: c) ?? date
            return Fmt.isoDay(Self.cal.date(byAdding: .month, value: n, to: first) ?? first)
        }
        return Fmt.isoDay(Self.add(date, n * (view == "week" ? 7 : view == "3days" ? 3 : 1)))
    }
}

// MARK: - Aufgabenliste (tasksListHtml)

struct PlanTaskList: View {
    let open: [JSONValue]
    @EnvironmentObject private var router: UFRouter

    var body: some View {
        let t = UFFmt.todayISO()
        let groups: [(String, [JSONValue], UFTone)] = [
            ("Nachholen", open.filter { $0.s("status") == "nachholen" }, .bad),
            ("Heute", open.filter { $0.s("date") == t && $0.s("status") != "nachholen" }, .info),
            ("Demnächst", open.filter { ($0.s("date") ?? "") > t }, .neutral),
        ].filter { !$0.1.isEmpty }
        VStack(alignment: .leading, spacing: 8) {
            if groups.isEmpty {
                UFCard { UFEmpty(icon: "check", text: "Keine offenen Aufgaben.") }
            }
            ForEach(groups.indices, id: \.self) { gi in
                let g = groups[gi]
                UFCard {
                    HStack(spacing: 7.2) { UFBadge("\(g.1.count)", tone: g.2); Text(g.0) }
                        .ufFont(17.6, 650, em: -0.01).foregroundStyle(UF.text).padding(.bottom, 12.8)
                    ForEach(Row.rows(g.1)) { row in
                        let x = row.value
                        HStack(spacing: 9.6) {
                            UFDot(color: Color(hex: x.s("color")))
                            Text("\(UFFmt.shortName(x.s("subject"))) · \(UFFmt.short(x.s("date")))")
                        }
                        .ufFont(13.12).foregroundStyle(UF.muted)
                        .padding(.top, 6.4).padding(.bottom, -3.2)
                        TaskRow(t: x) { router.reload() }
                    }
                }
            }
        }
    }
}
