import SwiftUI
import UniFlowCore

/// Übersicht 1:1 nach viewDashboard() in app/static/app.js: Begruessung mit Datum, Kennzahlen (heute geplant,
/// Aufgaben erledigt, nachzuholen), "Heute für dich geplant" mit Lernpaketen, "Heute an der Uni", "Nächste Termine",
/// "Diese Woche" mit Wochenstreifen, "Neu aus Stud.IP". Daten: GET /api/dashboard. Dazu die Karte "Neuigkeiten"
/// (Ankuendigungen, Nachrichten, Aenderungen gebuendelt, `NewsCard`) aus GET /api/news; sie ersetzt die fruehere Karte
/// "Ankündigungen".
struct DashboardView: View {
    @Environment(\.ufStudoraAccount) private var studoraAccount
    @StateObject private var data: RemoteData
    @EnvironmentObject private var router: UFRouter
    @EnvironmentObject private var shell: ShellState
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var studip: StudIPSync
    /// Name fuer die Begruessung (Vorname aus "Mit Apple anmelden", `UFGreeting`)
    @EnvironmentObject private var account: AccountStore
    @Environment(\.ufDemoActive) private var demo
    @Environment(\.openURL) private var openURL
    @Environment(\.ufWindowWidth) private var windowWidth
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showGenerate = false
    @State private var suggestion: JSONValue?
    /// Tag, fuer den die Seite gerade steht: nach Mitternacht (NSCalendarDayChanged) laedt sie neu, und Begruessung
    /// und "heute" folgen dem neuen Tag ohne Neustart
    @State private var day = UFFmt.todayISO()
    /// Ausfaelle laut Stud.IP von heute: in "Heute an der Uni" ausgeblendet wie in Stud.IP (`StudIPCancelled`)
    @State private var studipCancelled: Set<String> = []
    /// Neuigkeiten (GET /api/news) und die Liste "Alle anzeigen"
    @State private var news: [JSONValue] = []
    @State private var showNews = false
    /// neue Anzeigen im Schwarzen Brett (GET /api/studip/bulletin, nur lokal; eine Zeile in der Karte "Neuigkeiten")
    @State private var bulletinNew = 0
    /// "Zuletzt benutzt" (Weitermachen wie zuvor, `RecentCard`): Dokumente, KI-Gespraeche, Wochentests
    @State private var recent: [RecentItem] = []
    private let api: APIClient?

    init(api: APIClient?) {
        self.api = api
        _data = StateObject(wrappedValue: RemoteData(path: "/api/dashboard", api: api))
    }

    var body: some View {
        Group {
            let mode = UFDataMode.current(api: api, studip: studip, demo: demo)
            UFRemote(data: data) { d in content(d, mode: mode) }
                .task { await load() }
                .ufReload { await load() }
                .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: RunLoop.main)) { _ in
                    day = UFFmt.todayISO()                                   // neuer Tag: Begruessung und Datum neu, Daten neu
                    Task { await load() }
                }
        }
            .ufModal(isPresented: $showNews) {
                NewsAllList(items: news, today: data.value?["today"]?.s("date") ?? day) { showNews = false }
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

    /// Uebersicht und die Ausfaelle laut Stud.IP von heute (vorher geladen, damit nichts aufblitzt); nennt die
    /// Uebersicht einen anderen Tag als das Geraet (Uhr des Backends), gilt ihrer
    private func load() async {
        let device = day
        studipCancelled = await StudIPCancelled.keys(api, from: device, to: device)
        await data.load()
        news = (try? await api?.value("/api/news"))?.list("items") ?? []
        bulletinNew = api?.isLocal == true ? (try? await api?.value("/api/studip/bulletin"))?.i("new_count") ?? 0 : 0
        if let shown = data.value?["today"]?.s("date"), shown != device {
            studipCancelled = await StudIPCancelled.keys(api, from: shown, to: shown)
        }
        recent = await RecentItem.load(api: api, conversations: .shared, limit: Self.recentLimit)
    }

    /// so viele Eintraege in "Zuletzt benutzt" auf der Uebersicht (KI-Start: 15)
    static let recentLimit = 10

    // MARK: Inhalt

    @ViewBuilder private func content(_ d: JSONValue, mode: UFDataMode) -> some View {
        let today = d["today"] ?? .null
        let pk = today.list("packages")
        let evs = StudIPCancellations.visible(today.list("events").filter { $0.s("status") != "verschoben" }, keys: studipCancelled)
        // Aufgaben erledigt: dieselbe Zaehlung wie "Diese Woche" und der Lernkalender (`UFTaskProgress`, Woche Mo–So)
        let week = UFTaskProgress.of(week: d["week"] ?? .null)
        let nextOpen = pk.flatMap { p in p.list("tasks").filter { !["erledigt", "uebersprungen"].contains($0.s("status") ?? "") } }.first
        let todayDate = today.s("date") ?? day
        let backlog = d.i("backlog") ?? 0

        UFContent {
            VStack(alignment: .leading, spacing: 0) {
                // "Hallo Ahmad – lass uns gemeinsam lernen." (Wunsch des Inhabers 04.11.2026, `UFGreeting`): Rufname,
                // sonst Vorname der Apple-Anmeldung, sonst ohne Namen; `day` haelt die Tageszeit nach Mitternacht aktuell
                UFPageHeadGreet(title: UFGreeting.text(name: greetingName), sub: dateLine(pk: pk, evs: evs)) {
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
                // der Abgleichstand (die neuen Dateien stehen unten unter "Neu aus Stud.IP"). Mit Demo-Inhalten keins von
                // beiden; den Hinweis mit "Beenden" zeigt die App-Huelle ueber jeder Seite (`DemoActiveBar`)
                // Probe (StudiNow-Konto oder, ohne Dienst, die Probe auf dem iPad); ohne Inhalt nichts
                TrialBanner(link: studoraAccount).padding(.bottom, 19.2)
                if mode.showsConnectCard { ConnectStudIPCard(mode: mode).padding(.bottom, 19.2) }
                if statusBar(mode) { UFStudIPStatusBar(kind: .dashboard, mode: mode).padding(.bottom, 19.2) }
                // "Nächste Klausuren" (04.11.2026, `UpcomingExamsCard`): aus allen Quellen, nur wenn es welche gibt
                UpcomingExamsCard(api: api, token: day)
                // "Prüfungsanmeldung" (05.11.2026, `ExamRegistrationCard`): nur im Meldezeitraum und in den 7 Tagen davor
                ExamRegistrationCard(api: api, token: day)

                // drei Kennzahlen immer in einer Reihe (iPad hochkant: vorher 2 + 1 mit leerer Zelle), erst sehr schmal
                // untereinander; Kennzahlen sind Schrift, keine Kacheln mit Zierrat (Design-Ueberarbeitung 03.11.2026)
                // Bedienungshilfen-Schriftgroessen: untereinander (dreispaltig brach "nachzu-holen" mitten im Wort)
                UFGridLayout(columns: windowWidth > 640 && !typeSize.isAccessibilitySize ? 3 : 1, spacing: 16) {
                    // Karten erscheinen beim ersten Oeffnen der Seite leicht gestaffelt (UFMotion), Zahlen rollen
                    kpiCard(value: UFFmt.min(today.n("minutes")),
                            label: "heute geplant" + freeText(today))
                        .ufAppear("dashboard", index: 0)
                    UFCard {
                        // ohne Aufgaben kein "0 / 0" und kein leerer Balken (Audit 03.11.2026)
                        if let text = week.text {
                            UFKPI(value: text, label: "Aufgaben erledigt · diese Woche")
                            UFProgress(value: week.fraction, ok: true).padding(.top, 6.4)
                        } else {
                            UFKPI(value: "–", label: "diese Woche keine Aufgaben geplant")
                        }
                    }
                    .accessibilityIdentifier("dashboard.kpi.tasks")
                    .ufAppear("dashboard", index: 1)
                    backlogCard(backlog).ufAppear("dashboard", index: 2)
                }
                .environment(\.ufFillsCell, true)
                .padding(.bottom, 19.2)

                // Wunsch des Inhabers 03.11.2026: im Querformat endete die breite Spalte frueh, die schmale stapelte alles
                // (Abgaben mit 14 Eintraegen, Neuigkeiten …) und kuerzte Zeilen mit "…". Jetzt: Heute, Uni-Termine und
                // "Abgaben & Prüfungen" in der breiten Spalte, die uebrigen Karten jeweils in die kuerzere Spalte
                // (`DashboardFlow`); hochkant eine Spalte in dieser Reihenfolge
                DashboardFlow(twoColumns: windowWidth > 1100, spacing: 8) {
                    todayCard(pk: pk).ufAppear("dashboard", index: 3).dashboardSlot(.main)
                    if !evs.isEmpty { eventsCard(evs).ufAppear("dashboard", index: 4).dashboardSlot(.main) }
                    DueListCard().ufAppear("dashboard", index: 5).dashboardSlot(.main)   // Abgaben & Prüfungen (nur lokal)
                    if !recent.isEmpty { RecentCard(items: recent).ufAppear("dashboard", index: 4).dashboardSlot(.flow) }
                    upcomingCard(d.list("upcoming")).ufAppear("dashboard", index: 4).dashboardSlot(.flow)
                    // "Deine Module" mit Lernstand (docs/LERNSTAND-2026-11-04.md), wie modulesCard im Web
                    if !Self.activeModules(d).isEmpty {
                        modulesCard(Self.activeModules(d)).ufAppear("dashboard", index: 5).dashboardSlot(.flow)
                    }
                    if !news.isEmpty {                                                   // Neuigkeiten (+ Schwarzes Brett, eine Zeile)
                        NewsCard(items: news, today: todayDate, bulletinNew: bulletinNew, openBulletin: { router.go(.services) }) { showNews = true }
                            .ufAppear("dashboard", index: 6).dashboardSlot(.flow)
                    }
                    weekCard(d["week"] ?? .null, today: todayDate).ufAppear("dashboard", index: 7).dashboardSlot(.flow)
                    newFilesCard(d.list("new_files"), total: d.i("new_total") ?? 0, demo: mode.isDemo).ufAppear("dashboard", index: 8).dashboardSlot(.flow)
                }
            }
            .frame(maxWidth: 1120, alignment: .leading)
        }
    }

    private func statusBar(_ mode: UFDataMode) -> Bool {
        UFNoServerContent.resolve(kind: .dashboard, mode: mode, phase: studip.phase).showsStatusBar
    }

    /// Name der Begruessung in der Reihenfolge von `UFGreeting.pick`; das StudiNow-Konto hat in V1 keinen Anzeigenamen
    private var greetingName: String? { UFGreeting.name(for: account.account) }    // dieselbe Quelle wie die Seitenleiste

    /// "Sonntag, 25. Oktober · heute 2 Lernpakete · 3 Uni-Termine"
    private func dateLine(pk: [JSONValue], evs: [JSONValue]) -> String {
        var s = UFFmt.longToday() + " · "
        s += pk.isEmpty ? "heute ist nichts geplant" : "heute \(pk.count) Lernpaket\(pk.count > 1 ? "e" : "")"
        if !evs.isEmpty {
            let n = evs.filter { $0.s("status") == "teilnahme" }.count
            s += " · \(n) Uni-Termin\(n == 1 ? "" : "e")"                  // "1 Uni-Termin" (Store-Bilder 05.11.2026)
        }
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

    /// Dritte Kennzahl: Zahl rot, wenn etwas nachzuholen ist; "neu planen" startet "Meine Woche retten". Die Farbe
    /// sitzt auf der Zahl (Daten), nicht als roter Rahmen um die ganze Karte (Chrom)
    private func backlogCard(_ backlog: Int) -> some View {
        UFCard {
            VStack(alignment: .leading, spacing: 2.4) {
                Text("\(backlog)").ufFont(21.6, 700).foregroundStyle(backlog > 0 ? UF.bad : UF.text)
                    .ufNumber(backlog, numeric: Double(backlog))
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
                        if let mark = UFCancel.label(e) { UFCancelMark(text: mark, size: 11.52).help(UFCancel.helpText(e) ?? mark) }
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
            UFCardHead("Nächste Termine", icon: "calendar")
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
                        // Titel in Textfarbe statt ganz in Linkfarbe, der Pfeil rechts zeigt, dass die Zeile oeffnet
                        UFItemRow(UFFmt.shortName(u.s("title")), sub: Self.upcomingSub(u), wraps: true, leading: {
                            UFDot(color: Color(hex: u.s("color")))
                        }, trailing: {
                            UFIcon("chevron-right", size: 14).foregroundStyle(UF.muted)
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

    /// modules[] aus /api/dashboard ohne abgeschaltete Module, hoechstens fuenf (wie modulesCard in views-home.js)
    static func activeModules(_ d: JSONValue) -> [JSONValue] {
        Array(d.list("modules").filter { ($0.i("active") ?? 1) != 0 }.prefix(5))
    }

    /// Unterzeile der Modulzeile wie im Web: offene Aufgaben, dazu Klausur oder der naechste Termin
    static func moduleSub(_ m: JSONValue) -> String {
        var s = (m.i("open_tasks") ?? 0) > 0 ? "\(m.i("open_tasks") ?? 0) offen" : "nichts offen"
        if let exam = m.s("exam_date"), !exam.isEmpty {
            s += " · Klausur \(UFFmt.short(exam))"
        } else if let e = m["next_event"], !e.isNull {
            s += " · \(e.s("kind") == "vorlesung" ? "Vorlesung" : "Termin") \(UFFmt.short(e.s("date"))) \(e.s("start") ?? "")"
        }
        return s
    }

    /// "Deine Module": Name, Unterzeile und rechts der Lernstand (Ring in Modulfarbe, grau "noch kein Lernstand");
    /// jede Zeile oeffnet das Modul, "Alle" die Modulseite
    private func modulesCard(_ mods: [JSONValue]) -> some View {
        UFCard {
            UFCardHead("Deine Module", icon: "book") {
                Button("Alle") { router.go(.modules) }.font(.uf(13.12, 600)).foregroundStyle(UF.accentText).buttonStyle(.plain)
            }
            let rows = Row.rows(mods)
            ForEach(rows) { row in
                let m = row.value
                let mc = Color(hex: m.s("color"))
                Button { router.go(.module(m.i("id") ?? 0)) } label: {
                    // Name und Unterzeile, darunter die Kachel "Lernstand" (Ring mit Prozent und Begruendung, `LernstandTile`)
                    VStack(alignment: .leading, spacing: 0) {
                        UFItemRow(UFFmt.shortName(m.s("name")), sub: Self.moduleSub(m), wraps: true, leading: {
                            UFDot(color: mc)
                        }, trailing: {
                            UFIcon("chevron-right", size: 14).foregroundStyle(UF.muted)
                        })
                        LernstandTile(m: m["mastery"], color: mc, style: .inline)
                            .padding(.horizontal, 8).padding(.bottom, 12)
                    }
                    .foregroundStyle(UF.text)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(m.s("name") ?? "") · \(Self.moduleSub(m)) · \(LernstandText.accessibility(m["mastery"]))")
                .ufBorderBottom(row.id != rows.last?.id)
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

    private func weekCard(_ w: JSONValue, today: String) -> some View {
        let p = UFTaskProgress.of(week: w)
        return UFCard {
            // dieselbe Zahl wie die Kennzahl oben ("1 / 4 erledigt"); ohne Aufgaben keine Zahl und kein leerer Balken
            UFCardHead("Diese Woche", icon: "tasks") {
                if let text = p.text { Text("\(text) erledigt").ufFont(13.12).foregroundStyle(UF.muted).ufNumber(p.done, numeric: Double(p.done)) }
            }
            if !p.isEmpty { UFProgress(value: p.fraction, ok: true).padding(.bottom, 11.2) }
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

    private func newFilesCard(_ files: [JSONValue], total: Int, demo: Bool) -> some View {
        // nach Modul gruppiert, Reihenfolge des ersten Auftretens wie Object.entries im Web
        var order: [String] = []
        var groups: [String: [JSONValue]] = [:]
        for f in files {
            let s = f.s("subject") ?? "Sonstiges"
            if groups[s] == nil { order.append(s) }
            groups[s, default: []].append(f)
        }
        return UFCard {
            UFCardHead(UFSourceText.newFiles(studip.university, demo: demo), icon: "sparkles") { Text("\(total)").ufFont(13.12).foregroundStyle(UF.muted) }
            if total == 0 {
                Text("Nichts Neues.").ufFont(13.12).foregroundStyle(UF.muted).frame(maxWidth: .infinity).padding(.vertical, 32)
            } else {
                ForEach(Array(order.prefix(4)), id: \.self) { s in
                    let fs = groups[s] ?? []
                    let first = fs.first.map { $0.s("ai_title") ?? $0.s("name") ?? "" } ?? ""
                    Button { router.go(.files(section: "new")) } label: {
                        UFItemRow(UFFmt.shortName(s), sub: "\(fs.count) neue \(fs.count == 1 ? "Datei" : "Dateien") · \(first)\(fs.count > 1 ? " und weitere" : "")", wraps: true) {
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

/// Platz einer Karte der Uebersicht in `DashboardFlow`
enum DashboardSlot { case main, flow }

private struct DashboardSlotKey: LayoutValueKey { static let defaultValue: DashboardSlot = .flow }

extension View {
    func dashboardSlot(_ slot: DashboardSlot) -> some View { layoutValue(key: DashboardSlotKey.self, value: slot) }
}

/// Karten der Uebersicht ueber 1100 pt in zwei Spalten im Verhaeltnis 2:1 wie .span-2 in .grid.cols-3 (Spaltenbreite
/// (B - 2 Abstaende) / 3): `.main` immer in die breite Spalte, `.flow` der Reihe nach in die gerade kuerzere Spalte,
/// damit beide etwa gleich lang enden (Wunsch des Inhabers 03.11.2026). Schmaler: eine Spalte in der Reihenfolge der
/// Karten. Leere Karten (Hoehe 0, z. B. "Abgaben & Prüfungen" vor dem Laden) bekommen keinen Abstand.
/// `frames` ist eine reine Funktion (AuditApp20261103Tests).
struct DashboardFlow: Layout {
    var twoColumns: Bool
    var spacing: CGFloat = 8
    /// Abstand zwischen den Spalten (.grid gap 1rem)
    var gutter: CGFloat = 16

    static func widths(_ w: CGFloat, gutter: CGFloat) -> (CGFloat, CGFloat) {
        let col = max(0, (w - 2 * gutter) / 3)
        return (w - gutter - col, col)
    }

    /// Rahmen je Karte; `height(i, width)` misst Karte i bei der Breite
    static func frames(width w: CGFloat, slots: [DashboardSlot], twoColumns: Bool, spacing: CGFloat, gutter: CGFloat,
                       height: (Int, CGFloat) -> CGFloat) -> [CGRect] {
        guard twoColumns else {
            var y: CGFloat = 0
            return slots.indices.map { i in
                let h = height(i, w)
                guard h > 0.5 else { return CGRect(x: 0, y: y, width: w, height: 0) }
                if y > 0 { y += spacing }
                defer { y += h }
                return CGRect(x: 0, y: y, width: w, height: h)
            }
        }
        let (lw, rw) = widths(w, gutter: gutter)
        var left: CGFloat = 0, right: CGFloat = 0
        return slots.indices.map { i in
            let toLeft = slots[i] == .main || left < right
            let cw = toLeft ? lw : rw
            let h = height(i, cw)
            let x: CGFloat = toLeft ? 0 : lw + gutter
            var y = toLeft ? left : right
            guard h > 0.5 else { return CGRect(x: x, y: y, width: cw, height: 0) }
            if y > 0 { y += spacing }
            if toLeft { left = y + h } else { right = y + h }
            return CGRect(x: x, y: y, width: cw, height: h)
        }
    }

    private func frames(_ w: CGFloat, _ subviews: Subviews) -> [CGRect] {
        Self.frames(width: w, slots: subviews.map { $0[DashboardSlotKey.self] }, twoColumns: twoColumns, spacing: spacing, gutter: gutter) { i, cw in
            subviews[i].sizeThatFits(ProposedViewSize(width: cw, height: nil)).height
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 900
        return CGSize(width: w, height: frames(w, subviews).map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (i, f) in frames(bounds.width, subviews).enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), proposal: ProposedViewSize(width: f.width, height: nil))
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
