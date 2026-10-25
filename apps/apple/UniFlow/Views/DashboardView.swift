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
    @State private var showGenerate = false
    @State private var suggestion: JSONValue?
    private let api: APIClient?

    init(api: APIClient?) {
        self.api = api
        _data = StateObject(wrappedValue: RemoteData(path: "/api/dashboard", api: api))
    }

    var body: some View {
        UFRemote(data: data) { d in content(d) }
            .task { await data.load() }
            .onChange(of: shell.reloadToken) { _, _ in Task { await data.load() } }
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

    @ViewBuilder private func content(_ d: JSONValue) -> some View {
        let today = d["today"] ?? .null
        let pk = today.list("packages")
        let evs = today.list("events").filter { $0.s("status") != "verschoben" }
        let tasks = pk.flatMap { $0.list("tasks") }
        let done = tasks.filter { $0.s("status") == "erledigt" }.count
        let total = tasks.count
        let nextOpen = pk.flatMap { p in p.list("tasks").filter { !["erledigt", "uebersprungen"].contains($0.s("status") ?? "") } }.first
        let todayDate = today.s("date") ?? UFFmt.todayISO()
        let backlog = d.i("backlog") ?? 0

        UFContent {
            VStack(alignment: .leading, spacing: 0) {
                UFPageHeadGreet(title: "\(UFFmt.greeting())!", sub: dateLine(pk: pk, evs: evs)) {
                    UFButton("Tagesansicht", icon: "calendar") { router.go(.plan(view: "day", date: todayDate)) }
                    if let n = nextOpen {
                        UFButton("Weiterlernen", icon: "play", kind: .primary) {
                            if let f = n.s("file_id") { router.go(.doc(f, task: n.i("id"))) } else { router.go(.plan(view: "day", date: todayDate)) }
                        }
                    }
                }

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
                    weekCard(d["week"] ?? .null, today: todayDate)
                    newFilesCard(d.list("new_files"), total: d.i("new_total") ?? 0)
                })
            }
            .frame(maxWidth: 1120, alignment: .leading)
        }
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
                Text("\(backlog)").font(.system(size: 21.6, weight: .bold)).foregroundStyle(backlog > 0 ? UF.bad : UF.text)
                HStack(spacing: 0) {
                    Text("nachzuholen").font(.system(size: 12.8)).foregroundStyle(UF.muted)
                    if backlog > 0 {
                        Text(" · ").font(.system(size: 12.8)).foregroundStyle(UF.muted)
                        Button("neu planen") { Task { await rescue() } }
                            .font(.system(size: 12.8)).foregroundStyle(UF.accentText).buttonStyle(.plain)
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
                Button("Stundenplan") { router.go(.timetable) }.font(UF.small).foregroundStyle(UF.accentText).buttonStyle(.plain)
            }
            ForEach(Row.rows(evs, key: "event_id")) { row in
                let e = row.value
                let attending = e.s("status") == "teilnahme"
                Button { router.go(.timetable) } label: {
                    HStack(spacing: 9.6) {
                        UFDot(color: Color(hex: e.s("color")))
                        Text("\(e.s("start") ?? "")–\(e.s("end") ?? "")").font(.system(size: 13.12, weight: .bold)).frame(minWidth: 92, alignment: .leading)
                        Text(e.s("title") ?? "").font(UF.small).strikethrough(!attending)
                            .foregroundStyle(attending ? UF.text : UF.muted).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                        Text(String((e.s("room") ?? "").prefix(22))).font(UF.small).foregroundStyle(UF.muted).lineLimit(1)
                    }
                    .padding(.vertical, 4.8)
                    .overlay(alignment: .bottom) { Rectangle().fill(UF.line).frame(height: 1) }
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
                Text("Keine Termine.").font(UF.small).foregroundStyle(UF.muted).frame(maxWidth: .infinity).padding(.vertical, 32)
            } else {
                ForEach(Row.rows(Array(up.prefix(6)), key: "date")) { row in
                    let u = row.value
                    let kind = u.s("kind") == "klausur" ? "Klausur" : u.s("kind") == "test" ? "Wochentest" : "Lernpaket"
                    Button {
                        if u["package_id"].map({ !$0.isNull }) == true { router.go(.plan(view: "day", date: u.s("date"))) }
                        else if let m = u.i("module_id") { router.go(.module(m)) } else { router.go(.plan()) }
                    } label: {
                        UFItemRow(UFFmt.shortName(u.s("title")), sub: "\(UFFmt.short(u.s("date"))) · \(kind)") {
                            UFDot(color: Color(hex: u.s("color")))
                        }
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .bottom) { Rectangle().fill(UF.line).frame(height: 1) }
                }
            }
        }
    }

    private func weekCard(_ w: JSONValue, today: String) -> some View {
        let doneW = w.i("done") ?? 0, totalW = w.i("total") ?? 0
        return UFCard {
            UFCardHead("Diese Woche", icon: "clock") { Text("\(doneW)/\(totalW)").font(UF.small).foregroundStyle(UF.muted) }
            UFProgress(value: totalW > 0 ? Double(doneW) / Double(totalW) : 0, ok: true).padding(.bottom, 11.2)
            HStack(spacing: 5.6) {                                          // .week-strip: 7 gleich breite Tage
                ForEach(Row.rows(w.list("days"), key: "date")) { row in
                    let day = row.value
                    let isToday = day.s("date") == today
                    Button { router.go(.plan(view: "day", date: day.s("date"))) } label: {
                        VStack(spacing: 3.2) {
                            Text(UFFmt.weekdayShort(day.s("date"))).font(.system(size: 13.6, weight: .bold)).foregroundStyle(UF.text)
                            UFStatusDot(status: day.s("status") ?? "leer")
                            Text((day.n("minutes") ?? 0) > 0 ? UFFmt.min(day.n("minutes")) : "–")
                                .font(.system(size: 11.2)).foregroundStyle(UF.muted).lineLimit(1).minimumScaleFactor(0.8)
                        }
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
            UFCardHead("Neu aus Stud.IP", icon: "sparkles") { Text("\(total)").font(UF.small).foregroundStyle(UF.muted) }
            if total == 0 {
                Text("Nichts Neues.").font(UF.small).foregroundStyle(UF.muted).frame(maxWidth: .infinity).padding(.vertical, 32)
            } else {
                ForEach(Array(order.prefix(4)), id: \.self) { s in
                    let fs = groups[s] ?? []
                    let first = fs.first.map { $0.s("ai_title") ?? $0.s("name") ?? "" } ?? ""
                    Button { router.go(.files(section: "new")) } label: {
                        UFItemRow(UFFmt.shortName(s), sub: "\(fs.count) neue \(fs.count == 1 ? "Datei" : "Dateien") · \(first)\(fs.count > 1 ? " …" : "")") {
                            EmptyView()
                        } trailing: { UFBadge("\(fs.count)") }
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .bottom) { Rectangle().fill(UF.line).frame(height: 1) }
                }
                HStack {
                    Button("Alle anzeigen") { router.go(.files(section: "new")) }.font(UF.small).foregroundStyle(UF.accentText).buttonStyle(.plain)
                    Spacer()
                    UFButton("Gesehen", kind: .ghost, size: .small) {
                        Task {
                            _ = try? await api?.value("/api/files/mark-seen", method: "POST")
                            await data.load()
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

/// .page-head.greet: h1 1.6rem, Datum gedimmt; Aktionen rechts
private struct UFPageHeadGreet<Actions: View>: View {
    let title: String
    let sub: String
    @ViewBuilder var actions: Actions

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 16) { titles; Spacer(minLength: 0); HStack(spacing: 8) { actions } }
            VStack(alignment: .leading, spacing: 12) { titles; HStack(spacing: 8) { actions } }
        }
        .padding(.bottom, 19.2)
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 2.4) {
            Text(title).font(.system(size: 25.6, weight: .semibold)).foregroundStyle(UF.text)
            Text(sub).font(UF.body).foregroundStyle(UF.muted)
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

/// Zwei Spalten im Verhaeltnis 2:1 wie .span-2 in .grid.cols-3 (Spaltenbreite (B - 2 Abstaende) / 3)
private struct TwoOneLayout: Layout {
    var spacing: CGFloat = 16

    private func widths(_ w: CGFloat) -> (CGFloat, CGFloat) {
        let col = max(0, (w - 2 * spacing) / 3)
        return (col * 2 + spacing, col)
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

    var body: some View {
        let tasks = p.list("tasks")
        let done = tasks.filter { $0.s("status") == "erledigt" }.count
        let color = Color(hex: p.s("color"))
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3.2) {
                    HStack(spacing: 9.6) {
                        UFDot(color: color)
                        Text(UFFmt.shortName(p.s("subject"))).font(.system(size: 14.5, weight: .bold)).foregroundStyle(UF.text)
                        Text(timeText).font(UF.small).foregroundStyle(UF.muted)
                    }
                    Text(p.s("title") ?? "").font(UF.small).foregroundStyle(UF.text).padding(.leading, 17.6)
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
                    .font(UF.small)
                    .foregroundStyle(isDone ? UF.muted : UF.text)
                }
            }
            .padding(.leading, 17.6)
            .padding(.top, 8)
            .padding(.bottom, 6.4)
            HStack(spacing: 9.6) {
                UFProgress(value: tasks.isEmpty ? 0 : Double(done) / Double(tasks.count), ok: true)
                UFButton("Lernpaket öffnen", size: .small) { router.go(.plan(view: "day", date: p.s("date") ?? UFFmt.todayISO())) }
            }
            .padding(.leading, 17.6)
        }
        .padding(.vertical, 11.2)
        .padding(.horizontal, 14.4)
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
