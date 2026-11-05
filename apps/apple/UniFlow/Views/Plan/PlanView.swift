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
    /// iPhone (docs/IPHONE-2026-11-04.md): Woche als 3 Tage (sieben Spalten passen nicht), Aktionen im Menue,
    /// Leiste untereinander
    @Environment(\.ufCompact) private var compact
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

    private var key: String { "\(params.view ?? "")|\(params.date ?? "")|\(params.module ?? "")|\(weekFits)" }

    /// Sieben Tagesspalten brauchen mindestens 560 pt (iPhone hoch: nein; iPad im schmalen Split View und iPhone quer: ja)
    static func weekFits(width: CGFloat) -> Bool { width >= 560 }
    private var weekFits: Bool { Self.weekFits(width: windowWidth) }

    /// Ansichten der Leiste; ohne Platz fuer die Woche ohne "Woche" (sie zeigt dann 3 Tage, `PlanView.shownView`)
    static func views(compact: Bool, weekFits: Bool = true) -> [(value: String, label: String, icon: String?)] {
        let all: [(value: String, label: String, icon: String?)] = [("day", "Tag", nil), ("3days", "3 Tage", nil), ("week", "Woche", nil),
                                                                    ("month", "Monat", nil), ("list", "Liste", compact ? nil : "list")]
        return weekFits ? all : all.filter { $0.value != "week" }
    }

    /// Gezeigte Ansicht: ohne Platz fuer sieben Spalten wird "Woche" zu "3 Tage" ab dem gewaehlten Tag
    static func shownView(_ view: String, weekFits: Bool) -> String { !weekFits && view == "week" ? "3days" : view }

    // MARK: Laden

    private func load() async {
        if let v = params.view { Self.state.view = v }
        if let d = params.date { Self.state.date = d }
        if let m = params.module { Self.state.module = m }
        guard let api = session.api else { error = "Nicht mit dem Server verbunden."; return }
        var st = Self.state
        st.view = Self.shownView(st.view, weekFits: weekFits)
        let d = Fmt.date(st.date) ?? Date()
        let (start, end) = PlanData.range(view: st.view, date: d)
        let (mStart, mEnd) = PlanData.range(view: "month", date: d)
        do {
            async let cal = api.value("/api/calendar?start=\(Fmt.isoDay(start))&end=\(Fmt.isoDay(end))")
            async let open = api.value("/api/tasks/open")
            async let mods = api.value("/api/modules")
            // Ausfaelle laut Stud.IP wie in Stud.IP ausblenden (`StudIPCancelled`), im gezeigten Zeitraum und im Monat;
            // gleichzeitig mit den anderen Anfragen, damit das Neuladen nicht laenger dauert
            async let hiddenKeys = StudIPCancelled.keys(api, from: Fmt.isoDay(min(start, mStart)), to: Fmt.isoDay(max(end, mEnd)))
            // Klausuren als eigene Pins je Tag (`UFExam`, immer sichtbar)
            async let examList = UFExam.load(api)
            let month: JSONValue? = st.view == "month" ? nil : try await api.value("/api/calendar?start=\(Fmt.isoDay(mStart))&end=\(Fmt.isoDay(mEnd))")
            let hidden = await hiddenKeys, exams = await examList
            var pd = PlanData(view: st.view, date: d, start: start, end: end, module: st.module,
                              cal: UFExam.attach(StudIPCancellations.hiding(in: try await cal, keys: hidden), exams), open: try await open,
                              modules: try await mods, month: month.map { UFExam.attach(StudIPCancellations.hiding(in: $0, keys: hidden), exams) })
            if st.view == "week" || st.view == "3days" {
                for w in Set([PlanData.monday(start), PlanData.monday(end)]) {
                    if let tw = try? await api.value("/api/timetable/week?start=\(Fmt.isoDay(w))") {
                        for x in tw.list("days") { if let k = x.s("date") { pd.free[k] = x.list("free") } }
                    }
                }
            }
            if st.view == "day" { pd.dayTT = (try? await api.value("/api/timetable/day?date=\(st.date)")).map { StudIPCancellations.hiding(in: $0, keys: hidden) } }
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
        let side: CGFloat = compact ? 16 : 24
        UFContent(wide: true, maxWidth: 1600, insets: EdgeInsets(top: 20.8, leading: side, bottom: 48, trailing: side)) {
            // ohne PC keine Wochentests (KI, entfallen in V1): nicht ankuendigen
            UFPageHead("Lernkalender", sub: session.api?.isLocal == true ? "Dein Wochenplan – perfekt auf Vorlesungen und Übungen abgestimmt."
                                                                       : "Dein Wochenplan – perfekt auf Vorlesungen, Übungen und Tests abgestimmt.") {
              if compact {
                // iPhone: "Plan erstellen" sichtbar, die uebrigen Aktionen im Menue daneben
                UFButton("Plan erstellen", icon: "sparkles", kind: .primary) { actions.generatePlan(Fmt.isoDay(d.view == "week" ? d.start : d.date)) }
                Menu {
                    Button { actions.addPackage(date: Fmt.isoDay(d.view == "day" ? d.date : d.start)) } label: { Label("Lernpaket", systemImage: "plus") }
                    Button { actions.availability() } label: { Label("Verfügbarkeit", systemImage: "clock") }
                    Button { actions.config() } label: { Label("Lernkombination", systemImage: "gearshape") }
                    Button { Task { await actions.suggest(["rescue": true]) } } label: { Label("Woche retten", systemImage: "lifepreserver") }
                        .disabled(backlog.isEmpty)
                } label: {
                    HStack(spacing: 6) { UFIcon("more", size: 16); Text("Mehr") }
                        .ufFont(14.5, 500).foregroundStyle(UF.text)
                        .padding(.vertical, 8).padding(.horizontal, 14)
                        .background(RoundedRectangle(cornerRadius: UF.rSm).fill(UF.surface))
                        .overlay(RoundedRectangle(cornerRadius: UF.rSm).strokeBorder(UF.lineStrong, lineWidth: 1))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Weitere Aktionen")
                .accessibilityIdentifier("plan.more")
              } else {
                UFButton("Lernpaket", icon: "plus") { actions.addPackage(date: Fmt.isoDay(d.view == "day" ? d.date : d.start)) }
                // Verfuegbarkeit (Lernzeiten, Fahrtzeit, Sperrzeiten) gehoert zu den Lernslots: seit 03.11.2026 hier statt im Stundenplan
                UFButton("Verfügbarkeit", icon: "clock") { actions.availability() }
                UFButton("Lernkombination", icon: "settings") { actions.config() }
                UFButton("Woche retten", icon: "life-buoy") { Task { await actions.suggest(["rescue": true]) } }
                    .disabled(backlog.isEmpty)
                    .help(backlog.isEmpty ? "Nichts nachzuholen" : "")
                UFButton("Plan erstellen", icon: "sparkles", kind: .primary) { actions.generatePlan(Fmt.isoDay(d.view == "week" ? d.start : d.date)) }
              }
            }
            if !backlog.isEmpty { backlogBanner(backlog, d) }
            if (windowWidth > 1100 || sideOff) && !compact {
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
                    // Fehler sichtbar, "Übersprungen" nur bei Erfolg (vorher try? und immer die Erfolgsmeldung)
                    if await overlay.confirm("\(backlog.count) offene Aufgaben als bewusst übersprungen markieren?"), let api = session.api,
                       await toast.attempt("Überspringen", {
                           _ = try await api.value("/api/tasks/skip", method: "POST",
                                                   body: ["task_ids": .array(backlog.compactMap { $0.i("id") }.map { .number(Double($0)) })])
                       }) {
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
            case "day":
                // .cal-day-extras: Feiertag/vorlesungsfrei, Fristen und Hinweise des Tages ueber der Zeitleiste
                if let dd = d.days.first, UFDayExtras.hasAny(dd) {
                    UFDayExtraChips(dd: dd, compact: false, stacked: false).padding(.bottom, 9.6)
                }
                PlanDayTimeline(d: d)
            default: PlanTaskList(open: d.open)
            }
        }
        .padding(compact ? EdgeInsets(top: 12 + ufB, leading: 10 + ufB, bottom: 12 + ufB, trailing: 10 + ufB)
                         : EdgeInsets(top: 14.4 + ufB, leading: 16 + ufB, bottom: 16 + ufB, trailing: 16 + ufB))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: UF.rLg).fill(UF.surface))
        .overlay(RoundedRectangle(cornerRadius: UF.rLg).strokeBorder(UF.line, lineWidth: 1))
        .ufShadow(.sm)
    }

    /// .cal2-bar
    @ViewBuilder private func bar(_ d: PlanData, wk: Bool) -> some View {
        if compact { compactBar(d) } else { regularBar(d, wk: wk) }
    }

    private func moduleOptions(_ d: PlanData) -> [(value: String, label: String)] {
        [("", "Alle Module")] + d.modules.compactMap { m in m.i("id").map { ("\($0)", UFFmt.shortName(m.s("name"))) } }
    }

    private var moduleBinding: Binding<String> {
        Binding(get: { Self.state.module }, set: { m in
            Self.state.module = m
            router.go(.plan(view: Self.state.view, date: Self.state.date, module: m))
        })
    }

    /// iPhone: Ansichten in voller Breite, darunter ‹ Zeitraum ›, dann Heute, Modulfilter und Lernkombination
    private func compactBar(_ d: PlanData) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            UFSegPill(options: Self.views(compact: true, weekFits: weekFits), selection: d.view, fill: true) { v in go(v, Self.state.date) }
                .accessibilityIdentifier("plan.views")
            HStack(spacing: 6) {
                UFButton(icon: "chevron-left") { go(d.view, d.step(-1)) }
                Text(d.label)
                    .ufFont(15.2, 650).foregroundStyle(UF.text)
                    .multilineTextAlignment(.center)
                    .lineLimit(2).minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity)
                UFButton(icon: "chevron-right") { go(d.view, d.step(1)) }
            }
            HStack(spacing: 8) {
                UFButton("Heute") { go(d.view, UFFmt.todayISO()) }
                UFSelect(options: moduleOptions(d), selection: moduleBinding, fill: true)
                UFButton(icon: "settings") { actions.config() }.accessibilityLabel("Lernkombination")
            }
        }
    }

    private func regularBar(_ d: PlanData, wk: Bool) -> some View {
        let views = Self.views(compact: false)
        let modOptions = moduleOptions(d)
        return UFFlexWrap(gap: 8) {
            UFSegPill(options: views, selection: d.view) { v in go(v, Self.state.date) }
            UFFlexSpacer(max: 24)
            // ‹ Zeitraum › als eine Einheit: einzeln umbrochen landete › allein in der naechsten Zeile (Tag, Monat,
            // Liste) bzw. ‹ neben den Ansichten und › hinter dem Titel (Woche) - Audit 03.11.2026
            HStack(spacing: 8) {
                UFButton(icon: "chevron-left") { go(d.view, d.step(-1)) }
                HStack(spacing: 8) { UFIcon("calendar", size: 17); Text(d.label) }             // .cal2-title
                    .ufFont(16, 650).foregroundStyle(UF.text)
                    .frame(minWidth: 250)
                UFButton(icon: "chevron-right") { go(d.view, d.step(1)) }
            }
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

    /// Woche ab Montag, Zeitzone wie das Backend (`Fmt.calendar`)
    static var cal: Calendar { Fmt.calendar }

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

    /// Tage der Woche (Montag–Sonntag) um `date` aus dem gezeigten Zeitraum und dem Monat, mit Modulfilter: fuer
    /// "Mein Fortschritt" (`UFTaskProgress`); der Monat umfasst ganze Wochen, die Woche des Datums liegt immer darin
    func weekDays(of date: Date) -> [JSONValue] {
        let mon = Self.monday(date)
        let keys = Set((0..<7).map { Fmt.isoDay(Self.add(mon, $0)) })
        var seen = Set<String>()
        var out: [JSONValue] = []
        for dd in cal.list("days") + monthCal.list("days") {
            guard let k = dd.s("date"), keys.contains(k), !seen.contains(k) else { continue }
            seen.insert(k)
            guard let m = moduleFilter, var o = dd.object else { out.append(dd); continue }
            o["events"] = .array(dd.list("events").filter { $0.i("module_id") == m })
            o["packages"] = .array(dd.list("packages").filter { $0.i("module_id") == m })
            out.append(.object(o))
        }
        return out.sorted { ($0.s("date") ?? "") < ($1.s("date") ?? "") }
    }

    /// Zeitraum-Titel
    var label: String {
        let f = Fmt.formatter("d. MMMM")
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

// MARK: - Fortschritt (eine Zaehlweise)

/// "Aufgaben erledigt" an allen Stellen gleich gezaehlt (Audit 03.11.2026: oben auf der Uebersicht "0 / 0" fuer heute,
/// unten "Diese Woche 0/4", im Lernkalender je nach Ansicht der Tag (Liste "0 / 0") oder sechs Wochen (Monat "0 / 4")):
/// immer eine Woche Montag–Sonntag, auf der Uebersicht die laufende, im Lernkalender die Woche des gezeigten Datums.
/// Gezaehlt werden alle Aufgaben der Lernpakete dieser Tage wie `tasks_total` des Backends (auch uebersprungene);
/// erledigt = "erledigt". Ohne Aufgaben zeigen die Stellen keine Zahl ("0 / 0"), sondern einen Satz.
struct UFTaskProgress: Equatable {
    var done = 0
    var late = 0
    var skipped = 0
    var total = 0

    /// noch offen (geplant, in Bearbeitung)
    var open: Int { max(0, total - done - late - skipped) }
    var isEmpty: Bool { total == 0 }
    var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
    /// "1 / 4"; leer nil (keine "0 / 0")
    var text: String? { isEmpty ? nil : "\(done) / \(total)" }

    /// aus den Kalendertagen (`/api/calendar`): Aufgaben aller Lernpakete
    static func of(days: [JSONValue]) -> UFTaskProgress {
        var p = UFTaskProgress()
        for t in days.flatMap({ $0.list("packages").flatMap { $0.list("tasks") } }) {
            p.total += 1
            switch t.s("status") {
            case "erledigt": p.done += 1
            case "nachholen": p.late += 1
            case "uebersprungen": p.skipped += 1
            default: break
            }
        }
        return p
    }

    /// aus der Woche der Uebersicht (`/api/dashboard` → week.done/total, dieselbe Zaehlung im Backend)
    static func of(week w: JSONValue) -> UFTaskProgress {
        UFTaskProgress(done: w.i("done") ?? 0, total: w.i("total") ?? 0)
    }

    /// Zeitraum in Worten: "diese Woche", sonst "Woche 2.–8. Nov." bzw. "Woche 28. Dez. – 3. Jan."
    static func weekLabel(monday: Date, today: Date = Date()) -> String {
        if PlanData.monday(today) == PlanData.monday(monday) { return "diese Woche" }
        let mon = PlanData.monday(monday), sun = PlanData.add(mon, 6)
        let c = PlanData.cal
        let f = Fmt.formatter("d. MMM")
        if c.component(.month, from: mon) == c.component(.month, from: sun) {
            return "Woche \(c.component(.day, from: mon)).–\(f.string(from: sun))"
        }
        return "Woche \(f.string(from: mon)) – \(f.string(from: sun))"
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
