import SwiftUI
import UniFlowCore

/// Übersicht 1:1 nach viewDashboard() in app/static/app.js: Begruessung mit Datum, Kennzahlen (heute geplant,
/// Aufgaben erledigt, nachzuholen), "Heute für dich geplant" mit Lernpaketen, "Heute an der Uni", "Nächste Termine",
/// "Diese Woche" mit Wochenstreifen, "Neu aus Stud.IP". Daten: GET /api/dashboard.
struct DashboardView: View {
    @StateObject private var data: RemoteData
    @EnvironmentObject private var router: UFRouter
    @EnvironmentObject private var shell: ShellState
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var studip: StudIPSync
    @Environment(\.ufDemoActive) private var demo
    @Environment(\.openURL) private var openURL
    @State private var showGenerate = false
    @State private var suggestion: JSONValue?
    /// Tag, fuer den die Seite gerade steht: nach Mitternacht (NSCalendarDayChanged) laedt sie neu, und Begruessung
    /// und "heute" folgen dem neuen Tag ohne Neustart
    @State private var day = UFFmt.todayISO()
    private let api: APIClient?

    init(api: APIClient?) {
        self.api = api
        _data = StateObject(wrappedValue: RemoteData(path: "/api/dashboard", api: api))
    }

    var body: some View {
        Group {
            let mode = UFDataMode.current(api: api, studip: studip, demo: demo)
            UFRemote(data: data) { d in content(d, mode: mode) }
                .task { await data.load() }
                .ufReload { await data.load() }
                .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: RunLoop.main)) { _ in
                    day = UFFmt.todayISO()                                   // neuer Tag: Begruessung und Datum neu, Daten neu
                    Task { await data.load() }
                }
        }
            .ufModal(isPresented: $showGenerate) {
                GeneratePlanDialog(api: api, start: UFFmt.todayISO()) { showGenerate = false }
            }
            .ufModal(isPresented: Binding(get: { suggestion != nil }, set: { if !$0 { suggestion = nil } })) {
                if let s = suggestion {
                    SuggestDialog(api: api, rescue: true, suggestion: s) {
                        suggestion = nil
                        Task { await data.load() }
                    }
                }
            }
    }

    // MARK: Inhalt

    @ViewBuilder private func content(_ d: JSONValue, mode: UFDataMode) -> some View {
        let today = d["today"] ?? .null
        let pk = today.list("packages")
        let evs = today.list("events").filter { $0.s("status") != "verschoben" }
        let tasks = pk.flatMap { $0.list("tasks") }
        let done = tasks.filter { $0.s("status") == "erledigt" }.count
        let total = tasks.count
        let nextOpen = pk.flatMap { p in p.list("tasks").filter { !["erledigt", "uebersprungen"].contains($0.s("status") ?? "") } }.first
        let todayDate = today.s("date") ?? day
        let backlog = d.i("backlog") ?? 0

        UFContent {
            VStack(alignment: .leading, spacing: 0) {
                UFPageHeadGreet(title: "\(UFFmt.greeting())!", sub: dateLine(pk: pk, evs: evs)) {
                    UFButton("Tagesansicht", icon: "calendar") { router.go(.plan(view: "day", date: todayDate)) }
                    if let n = nextOpen {
                        UFButton("Weiterlernen", icon: "play", kind: .primary) {
                            // an der zuletzt gelesenen Seite weiter (wie "Öffnen" im Lernplan)
                            if let f = n.s("file_id") {
                                let lp = n.i("last_page") ?? 1
                                router.go(.doc(f, task: n.i("id"), page: lp > 1 ? lp : nil))
                            } else { router.go(.plan(view: "day", date: todayDate)) }
                        }
                    }
                }
                // lokal: solange Stud.IP nicht verbunden ist, oben die Karte "Stud.IP verbinden" (Auftrag 2a); danach
                // der Abgleichstand (die neuen Dateien stehen unten unter "Neu aus Stud.IP"). Mit Demo-Inhalten statt
                // dessen der Hinweis "Demo-Inhalte aktiv" mit "Entfernen"
                if mode.isDemo { DemoActiveBar().padding(.bottom, 19.2) }
                if mode.showsConnectCard { ConnectStudIPCard(mode: mode).padding(.bottom, 19.2) }
                if statusBar(mode) { UFStudIPStatusBar(kind: .dashboard, mode: mode).padding(.bottom, 19.2) }

                UFGrid(columns: 3) {
                    kpiCard(value: UFFmt.min(today.n("minutes")),
                            label: "heute geplant" + freeText(today))
                    UFCard {
                        UFKPI(value: "\(done) / \(total)", label: "Aufgaben erledigt")
                        UFProgress(value: total > 0 ? Double(done) / Double(total) : 0, ok: true).padding(.top, 6.4)
                    }
                    backlogCard(backlog)
                }
                .padding(.bottom, 19.2)

                twoColumns(left: {
                    todayCard(pk: pk)
                    if !evs.isEmpty { eventsCard(evs) }
                }, right: {
                    upcomingCard(d.list("upcoming"))
                    DueListCard()                                                  // Abgaben & Prüfungen (nur lokal)
                    if !d.list("announcements").isEmpty { announcementsCard(d.list("announcements")) }
                    weekCard(d["week"] ?? .null, today: todayDate)
                    newFilesCard(d.list("new_files"), total: d.i("new_total") ?? 0)
                })
            }
            .frame(maxWidth: 1120, alignment: .leading)
        }
    }

    private func statusBar(_ mode: UFDataMode) -> Bool {
        UFNoServerContent.resolve(kind: .dashboard, mode: mode, phase: studip.phase).showsStatusBar
    }

    /// "Sonntag, 25. Oktober · heute 2 Lernpakete · 3 Uni-Termine"
    private func dateLine(pk: [JSONValue], evs: [JSONValue]) -> String {
        var s = UFFmt.longToday() + " · "
        s += pk.isEmpty ? "heute ist nichts geplant" : "heute \(pk.count) Lernpaket\(pk.count > 1 ? "e" : "")"
        if !evs.isEmpty { s += " · \(evs.filter { $0.s("status") == "teilnahme" }.count) Uni-Termine" }
        return s
    }

    private func freeText(_ today: JSONValue) -> String {
        let free = today.list("free")
        guard !free.isEmpty else { return "" }
        return " · \(UFFmt.min(free.reduce(0) { $0 + ($1.n("minutes") ?? 0) })) frei"
    }

    private func kpiCard(value: String, label: String) -> some View {
        UFCard { UFKPI(value: value, label: label) }
    }

    /// Dritte Kennzahl: rot umrandet, wenn etwas nachzuholen ist; "neu planen" startet "Meine Woche retten"
    private func backlogCard(_ backlog: Int) -> some View {
        UFCard {
            VStack(alignment: .leading, spacing: 2.4) {
                Text("\(backlog)").ufFont(21.6, 700).foregroundStyle(backlog > 0 ? UF.bad : UF.text)
                HStack(spacing: 0) {
                    Text("nachzuholen").ufFont(12.8).foregroundStyle(UF.muted)
                    if backlog > 0 {
                        Text(" · ").ufFont(12.8).foregroundStyle(UF.muted)
                        Button("neu planen") { Task { await rescue() } }          // .kpi a { font-weight: 600 }
                            .ufFont(12.8, 600).foregroundStyle(UF.accentText).buttonStyle(.plain)
                    }
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: UF.r).strokeBorder(backlog > 0 ? UF.bad : .clear, lineWidth: 1))
    }

    /// linke Spalte doppelt so breit wie die rechte (span-2), unter 1100 pt untereinander
    private func twoColumns<L: View, R: View>(@ViewBuilder left: () -> L, @ViewBuilder right: () -> R) -> some View {
        DashboardColumns(left: left(), right: right())
    }

    // MARK: Karten

    private func todayCard(pk: [JSONValue]) -> some View {
        UFCard {
            UFCardHead("Heute für dich geplant", icon: "play")
            if pk.isEmpty {
                UFEmpty(icon: "calendar", text: "Für heute ist nichts geplant.") {
                    UFButton("Lernplan erstellen", icon: "sparkles", kind: .primary, size: .small) { showGenerate = true }
                        .padding(.top, 9.6)
                }
            } else {
                ForEach(Row.rows(pk)) { row in PackageCard(p: row.value) }
            }
        }
    }

    private func eventsCard(_ evs: [JSONValue]) -> some View {
        UFCard {
            UFCardHead("Heute an der Uni", icon: "clock") {
                Button("Stundenplan") { router.go(.timetable()) }.ufFont(13.12).foregroundStyle(UF.accentText).buttonStyle(.plain)
            }
            ForEach(Row.rows(evs, key: "event_id")) { row in
                let e = row.value
                let attending = e.s("status") == "teilnahme"
                Button { PlanEnv.make(session, overlay, toast, router).openOccurrence(e, date: e.s("date") ?? UFFmt.todayISO()) } label: {
                    HStack(spacing: 9.6) {
                        UFDot(color: Color(hex: e.s("color")))
                        Text("\(e.s("start") ?? "")–\(e.s("end") ?? "")").ufFont(13.12, 700).foregroundStyle(UF.text).frame(minWidth: 92, alignment: .leading)
                        Text(e.s("title") ?? "").ufFont(13.12).strikethrough(!attending)
                            .foregroundStyle(attending ? UF.text : UF.muted).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                        Text(String((e.s("room") ?? "").prefix(22))).ufFont(13.12).foregroundStyle(UF.muted).lineLimit(1)
                    }
                    .padding(.vertical, 4.8)
                    .ufBorderBottom()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func upcomingCard(_ up: [JSONValue]) -> some View {
        UFCard {
            UFCardHead("Nächste Termine", icon: "flag")
            if up.isEmpty {
                Text("Keine Termine.").ufFont(13.12).foregroundStyle(UF.muted).frame(maxWidth: .infinity).padding(.vertical, 32)
            } else {
                let rows = Row.rows(Array(up.prefix(6)), key: "date")
                ForEach(rows) { row in
                    let u = row.value
                    let isDeadline = u["deadline_id"].map { !$0.isNull } == true
                    Button {
                        // erkannter Termin: Quelle (PDF auf der Seite, Ankuendigung); Learnweb-Frist: Eintrag oeffnet das
                        // Learnweb (nur http/https), sonst Lernplan bzw. Modul
                        if u["detected"]?.bool == true { DueOpen.open(u, router: router, openURL: openURL) }
                        else if isDeadline { if let url = UFDayExtras.safeURL(u.s("url")) { openURL(url) } }
                        else if u["package_id"].map({ !$0.isNull }) == true { router.go(.plan(view: "day", date: u.s("date"))) }
                        else if let m = u.i("module_id") { router.go(.module(m)) } else { router.go(.plan()) }
                    } label: {
                        UFItemRow(UFFmt.shortName(u.s("title")), sub: Self.upcomingSub(u), link: true, leading: {
                            UFDot(color: Color(hex: u.s("color")))
                        })
                        .foregroundStyle(isDeadline && (u["overdue"]?.bool ?? false) ? UF.bad : UF.text)
                    }
                    .buttonStyle(.plain)
                    .help(u.s("full_title") ?? u.s("title") ?? "")
                    .accessibilityLabel(isDeadline ? "Frist: \(u.s("title") ?? "") · \(Self.upcomingSub(u))" : "\(u.s("title") ?? "") · \(Self.upcomingSub(u))")
                    .ufBorderBottom(row.id != rows.last?.id)                     // .item:last-child { border-bottom: 0 }
                }
            }
        }
    }

    /// Unterzeile wie im Web: Frist "Datum Uhrzeit · Abgabe · Kurs" (ueberfaellig rot), sonst "Datum · Klausur/Wochentest/Lernpaket"
    static func upcomingSub(_ u: JSONValue) -> String {
        if u["deadline_id"].map({ !$0.isNull }) == true {
            var s = UFFmt.short(u.s("date"))
            if let t = u.s("time"), !t.isEmpty { s += " \(t)" }
            s += " · \(u.s("kind_label") ?? "Frist")"
            if let c = u.s("course_title"), !c.isEmpty { s += " · \(UFFmt.shortName(c))" }
            return s
        }
        let kind = u.s("kind") == "klausur" ? "Klausur" : u.s("kind") == "test" ? "Wochentest" : "Lernpaket"
        return "\(UFFmt.short(u.s("date"))) · \(kind)"
    }

    /// Karte "Ankuendigungen" wie im Web: Titel, Datum, Kurs, Quelle, erkannte Termine als Chips, Text aufklappbar,
    /// Link oeffnet das Learnweb bzw. Stud.IP (nur http/https)
    private func announcementsCard(_ list: [JSONValue]) -> some View {
        UFCard {
            UFCardHead("Ankündigungen", icon: "info") { Text("\(list.count)").ufFont(13.12).foregroundStyle(UF.muted) }
            let rows = Row.rows(Array(list.prefix(5)))
            ForEach(rows) { row in
                let a = row.value
                let source = a.s("source") == "studip" ? "Stud.IP" : "Learnweb"
                var sub = UFFmt.short(a.s("posted_at").map { String($0.prefix(10)) })
                let _ = { if let c = a.s("course_title"), !c.isEmpty { sub += " · \(UFFmt.shortName(c))" } }()
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 6.4) {
                        Text(a.s("text") ?? "").ufFont(12.8).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                        if let url = UFDayExtras.safeURL(a.s("url")) {
                            Button("Im \(source) öffnen") { openURL(url) }.ufFont(12.8).foregroundStyle(UF.accentText).buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4.8)
                } label: {
                    VStack(alignment: .leading, spacing: 2.4) {
                        Text(a.s("title") ?? "Ankündigung").ufFont(14.5, 550).foregroundStyle(UF.text).lineLimit(2)
                        Text("\(sub) · \(source)").ufFont(12.8).foregroundStyle(UF.muted).lineLimit(1)
                        let upcoming = a.list("upcoming").prefix(3)
                        if !upcoming.isEmpty {
                            let notices: [JSONValue] = upcoming.map { x in
                                let kind = x.s("kind") ?? ""
                                let label = ["ausfall": "Ausfall?", "verlegt": "Verlegung?", "raum": "Raum", "pruefung": "Prüfung",
                                             "frist": "Frist", "online": "Online"][kind] ?? "Termin"
                                return .object(["kind_label": .string("\(UFFmt.short(x.s("date"))) \(label)"), "time": x["time"] ?? .null,
                                                "title": a["title"] ?? .null, "url": a["url"] ?? .null, "course_title": a["course_title"] ?? .null,
                                                "snippet": x["snippet"] ?? .null, "kind": x["kind"] ?? .null])
                            }
                            UFDayExtraChips(dd: .object(["notices": .array(notices)]), stacked: false).padding(.top, 2.4)
                        }
                    }
                    .padding(.vertical, 4.8)
                }
                .tint(UF.muted)
                .ufBorderBottom(row.id != rows.last?.id)
            }
        }
    }

    private func weekCard(_ w: JSONValue, today: String) -> some View {
        let doneW = w.i("done") ?? 0, totalW = w.i("total") ?? 0
        return UFCard {
            UFCardHead("Diese Woche", icon: "clock") { Text("\(doneW)/\(totalW)").ufFont(13.12).foregroundStyle(UF.muted) }
            UFProgress(value: totalW > 0 ? Double(doneW) / Double(totalW) : 0, ok: true).padding(.bottom, 11.2)
            HStack(spacing: 5.6) {                                          // .week-strip: 7 gleich breite Tage
                ForEach(Row.rows(w.list("days"), key: "date")) { row in
                    let day = row.value
                    let isToday = day.s("date") == today
                    Button { router.go(.plan(view: "day", date: day.s("date"))) } label: {
                        VStack(spacing: 3.2) {                                   // .d: b .85rem, .sd, .m .7rem (bricht um)
                            Text(UFFmt.weekdayShort(day.s("date"))).ufFont(13.6, 700).foregroundStyle(UF.text)
                            UFStatusDot(status: day.s("status") ?? "leer")
                            Text((day.n("minutes") ?? 0) > 0 ? UFFmt.min(day.n("minutes")) : "–")
                                .ufFont(11.2).foregroundStyle(UF.muted).multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxHeight: .infinity, alignment: .top)
                        .padding(.vertical, 6.4)
                        .padding(.horizontal, 3.2)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: UF.rSm).fill(UF.surface2))
                        .overlay(RoundedRectangle(cornerRadius: UF.rSm).stroke(isToday ? UF.accent : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func newFilesCard(_ files: [JSONValue], total: Int) -> some View {
        // nach Modul gruppiert, Reihenfolge des ersten Auftretens wie Object.entries im Web
        var order: [String] = []
        var groups: [String: [JSONValue]] = [:]
        for f in files {
            let s = f.s("subject") ?? "Sonstiges"
            if groups[s] == nil { order.append(s) }
            groups[s, default: []].append(f)
        }
        return UFCard {
            UFCardHead(UFSourceText.newFiles(studip.university), icon: "sparkles") { Text("\(total)").ufFont(13.12).foregroundStyle(UF.muted) }
            if total == 0 {
                Text("Nichts Neues.").ufFont(13.12).foregroundStyle(UF.muted).frame(maxWidth: .infinity).padding(.vertical, 32)
            } else {
                ForEach(Array(order.prefix(4)), id: \.self) { s in
                    let fs = groups[s] ?? []
                    let first = fs.first.map { $0.s("ai_title") ?? $0.s("name") ?? "" } ?? ""
                    Button { router.go(.files(section: "new")) } label: {
                        UFItemRow(UFFmt.shortName(s), sub: "\(fs.count) neue \(fs.count == 1 ? "Datei" : "Dateien") · \(first)\(fs.count > 1 ? " …" : "")", link: true) {
                            EmptyView()
                        } trailing: { UFBadge("\(fs.count)") }
                    }
                    .buttonStyle(.plain)
                    .ufBorderBottom()
                }
                HStack {
                    Button("Alle anzeigen") { router.go(.files(section: "new")) }.ufFont(13.12).foregroundStyle(UF.accentText).buttonStyle(.plain)
                    Spacer()
                    UFButton("Gesehen", kind: .ghost, size: .small) {
                        Task {
                            // Fehler sichtbar (vorher try?: die Karte blieb voll, ohne Grund)
                            guard let api else { return }
                            if await toast.attempt("Als gesehen markieren", { _ = try await api.value("/api/files/mark-seen", method: "POST") }) {
                                await data.load()
                            }
                        }
                    }
                }
                .padding(.top, 6.4)
            }
        }
    }

    // MARK: Aktionen

    /// suggestFlow({ rescue: true }) – ohne Vorschlaege nur Meldung, sonst Dialog
    private func rescue() async {
        guard let api else { return }
        do {
            let r = try await api.value("/api/calendar/suggest", method: "POST", body: ["rescue": true])
            if (r["moves"]?.array ?? []).isEmpty { toast.show(r.s("message") ?? "Nichts zu verschieben") } else { suggestion = r }
        } catch { toast.show(error.localizedDescription) }
    }
}

/// .page-head.greet: h1 wie .page-head h1 (1.9rem/700, -.02em; ueberschreibt .greet h1), Datum gedimmt; Aktionen rechts
private struct UFPageHeadGreet<Actions: View>: View {
    let title: String
    let sub: String
    @ViewBuilder var actions: Actions

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 16) {
                titles.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                HStack(spacing: 8) { actions }.fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 16) { titles; HStack(spacing: 8) { actions } }
        }
        .padding(.bottom, 19.2)
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 0) {                             // .greet .date: ohne margin-top (anders als .sub)
            Text(title).ufFont(30.4, 700, em: -0.02).foregroundStyle(UF.text)
            Text(sub).ufFont(14.5).foregroundStyle(UF.muted)
        }
    }
}

/// .grid.cols-3 mit .span-2 links und .stack rechts; schmal untereinander
private struct DashboardColumns<L: View, R: View>: View {
    let left: L
    let right: R
    @Environment(\.ufWindowWidth) private var width

    var body: some View {
        if width > 1100 {
            TwoOneLayout(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) { left }
                VStack(alignment: .leading, spacing: 8) { right }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) { left; right }
        }
    }
}

/// Zwei Spalten im Verhaeltnis 2:1 wie .span-2 in .grid.cols-3 (Spaltenbreite (B - 2 Abstaende) / 3). Seit dem
/// PC-Stand vom 26.10.2026 gilt `.grid > * { min-width: 0 }`: die rechte Spur waechst nicht mehr auf die Breite
/// langer Titel (Learnweb-Fristen drueckten sie breit, "Heute an der Uni" lief ueber); die Zeilen kuerzen mit "…".
private struct TwoOneLayout: Layout {
    var spacing: CGFloat = 16

    private func widths(_ w: CGFloat) -> (CGFloat, CGFloat) {
        let col = max(0, (w - 2 * spacing) / 3)
        return (w - spacing - col, col)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 900
        let (lw, rw) = widths(w)
        let lh = subviews.count > 0 ? subviews[0].sizeThatFits(ProposedViewSize(width: lw, height: nil)).height : 0
        let rh = subviews.count > 1 ? subviews[1].sizeThatFits(ProposedViewSize(width: rw, height: nil)).height : 0
        return CGSize(width: w, height: max(lh, rh))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (lw, rw) = widths(bounds.width)
        if subviews.count > 0 { subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: lw, height: nil)) }
        if subviews.count > 1 {
            subviews[1].place(at: CGPoint(x: bounds.minX + lw + spacing, y: bounds.minY), proposal: ProposedViewSize(width: rw, height: nil))
        }
    }
}

/// .pkg-card: linker Farbbalken 4 pt, Kopf mit Fach, Zeit und Status, Aufgabenliste, Fortschritt + "Lernpaket öffnen"
struct PackageCard: View {
    let p: JSONValue
    @EnvironmentObject private var router: UFRouter
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var toast: UFToastCenter

    var body: some View {
        let tasks = p.list("tasks")
        let done = tasks.filter { $0.s("status") == "erledigt" }.count
        let color = Color(hex: p.s("color"))
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3.2) {
                    HStack(spacing: 9.6) {
                        UFDot(color: color)
                        Text(UFFmt.shortName(p.s("subject"))).ufFont(14.5, 700).foregroundStyle(UF.text)
                        Text(timeText).ufFont(13.12).foregroundStyle(UF.muted)
                    }
                    Text(p.s("title") ?? "").ufFont(13.12).foregroundStyle(UF.text).padding(.leading, 17.6)
                }
                Spacer(minLength: 8)
                UFStatusPill(status: p.s("status") ?? "geplant")
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Row.rows(tasks)) { row in
                    let t = row.value
                    let isDone = t.s("status") == "erledigt"
                    HStack(spacing: 6.4) {
                        UFIcon(isDone ? "check" : (ShellState.typeIcon[t.s("type") ?? ""] ?? "file"), size: 14)
                        Text(t.s("title") ?? "").strikethrough(isDone)
                        Text("\(t.i("est_minutes") ?? 0) min").foregroundStyle(UF.muted)
                        if let f = t.s("file_id"), !isDone {
                            Button("öffnen") { router.go(.doc(f, task: t.i("id"))) }.foregroundStyle(UF.accentText).buttonStyle(.plain)
                        }
                    }
                    .ufFont(13.12)
                    .foregroundStyle(isDone ? UF.muted : UF.text)
                }
            }
            .padding(.leading, 17.6)
            .padding(.top, 8)
            .padding(.bottom, 6.4)
            HStack(spacing: 9.6) {
                UFProgress(value: tasks.isEmpty ? 0 : Double(done) / Double(tasks.count), ok: true)
                UFButton("Lernpaket öffnen", size: .small) { PlanEnv.make(session, overlay, toast, router).openPackage(p.i("id") ?? 0) }
            }
            .padding(.leading, 17.6)
        }
        .padding(.vertical, 11.2 + ufB)                                      // .pkg-card: padding + Rand, links 4px
        .padding(.trailing, 14.4 + ufB)
        .padding(.leading, 14.4 + 4)
        .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.surface))
        .overlay(RoundedRectangle(cornerRadius: UF.r).strokeBorder(UF.line, lineWidth: 1))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: UF.r, bottomLeadingRadius: UF.r).fill(color).frame(width: 4)
        }
        .padding(.bottom, 9.6)
    }

    private var timeText: String {
        let t = p.s("start_time").map { "\($0)–\(p.s("end_time") ?? "") · " } ?? ""
        return t + UFFmt.min(p.n("planned_minutes"))
    }
}
