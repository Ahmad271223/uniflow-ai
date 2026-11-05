import SwiftUI
import UniFlowCore

// Seite "Studienverlauf" (Auftrag des Inhabers 04.11.2026, docs/STUDIENVERLAUF-2026-11-04.md): Kopf mit Studiengang,
// Pruefungsordnung, Katalogsemester, Ring "84 von 180 LP", kurzen Hinweisen und dem Satz, dass die Pruefungsordnung
// verbindlich ist. Darunter das Board: quer eine Spalte je Semester (waagerecht scrollend), hochkant Abschnitte
// untereinander mit Karten im Raster. Karte je Modul mit LP, Art, Turnus und Status. Das laufende Semester ist
// hervorgehoben, Filter Alle / Offen / Bestanden. Ein Tipp auf ein Modul oeffnet das Blatt mit den Details
// (StudyPlanModuleSheet), "Einstellungen" das Blatt mit Pruefungsordnung, Studienbeginn und Wahlpflicht.
// Ohne Plan: QIS verbinden, Katalogsuche mit Fortschritt (GET /api/study-catalog/status, fragt alle 2 s nach) oder
// "Noch kein Katalog" mit Feld fuer den Link zum Modulhandbuch. Rechnet nichts selbst (Plan kommt fertig vom Kern).

/// Board quer (Spalten) oder Liste hochkant (Abschnitte)
enum StudyPlanLayout { case board, list }

/// Modul, dessen Detail offen ist
struct StudyPlanDetailRef: Identifiable, Equatable { let id: String }

struct StudyPlanPage: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var router: UFRouter
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.ufCompact) private var compact

    /// Modul (id oder Titel), das beim Oeffnen gezeigt wird ("Im Studienverlauf zeigen" auf der Modulseite)
    var focus: String?
    /// Tests: Board oder Liste erzwingen (nil: quer Board, hochkant Liste)
    var layoutOverride: StudyPlanLayout?
    /// Abstand der Nachfrage waehrend der Katalogsuche
    var pollInterval: Double = 2

    enum Phase: Equatable { case loading, failed(String), loaded(StudyPlan) }

    @State private var phase: Phase = .loading
    @State private var catalog: StudyCatalogStatus?
    @State private var filter: StudyPlanFilter = .all
    @State private var detail: StudyPlanDetailRef?
    @State private var showSettings = false
    @State private var focusDone = false
    /// erste sichtbare Spalte des Boards (Semestername)
    @State private var boardStart: String?
    @State private var linkText = ""
    @State private var linkMessage: (text: String, ok: Bool)?
    @State private var linkBusy = false
    @State private var poBusy = false
    @State private var poError: String?

    /// `initialLink`: vorbelegter Link zum Modulhandbuch (Tests, Bildvergleich)
    init(focus: String? = nil, layoutOverride: StudyPlanLayout? = nil, pollInterval: Double = 2, initialLink: String = "") {
        self.focus = focus
        self.layoutOverride = layoutOverride
        self.pollInterval = pollInterval
        _linkText = State(initialValue: initialLink)
    }

    private var plan: StudyPlan? { if case .loaded(let p) = phase { return p }; return nil }

    var body: some View {
        GeometryReader { g in
            // kompakt (iPhone, auch quer): immer die Semesterliste, nie Spalten
            let layout = layoutOverride ?? (!compact && g.size.width > g.size.height && typeSize < .accessibility1 ? .board : .list)
            let pad: CGFloat = g.size.width < 700 ? 16 : 25.6
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        UFPageHead(StudyPlanText.title) { headActions }
                        content(layout: layout, pad: pad)
                    }
                    .padding(EdgeInsets(top: 22.4, leading: pad, bottom: 48, trailing: pad))
                    .frame(maxWidth: 1480, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .background(UF.bg)
                .onChange(of: plan) { _, p in scrollToStart(p, proxy: proxy) }
                .onAppear { scrollToStart(plan, proxy: proxy) }
            }
        }
        .background(UF.bg)
        .task { await load() }
        .task(id: pollKey) { await poll() }
        .ufReload { await load() }
        .sheet(item: $detail) { ref in
            StudyModuleSheet(startID: ref.id, api: session.api, titles: plan?.titles ?? [:]) { route in
                detail = nil
                router.go(route)
            }
        }
        .sheet(isPresented: $showSettings) {
            StudyPlanSettingsSheet(api: session.api) { await load() }
        }
        .accessibilityIdentifier("studyplan.page")
    }

    // MARK: Kopf

    @ViewBuilder private var headActions: some View {
        if let p = plan, p.gap != .noQIS {
            UFButton("Einstellungen", icon: "settings") { showSettings = true }
                .accessibilityIdentifier("studyplan.settings")
        }
    }

    @ViewBuilder private func content(layout: StudyPlanLayout, pad: CGFloat) -> some View {
        switch phase {
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text(StudyPlanText.loading).ufFont(14.5).foregroundStyle(UF.muted)
            }
            .frame(maxWidth: .infinity, minHeight: 200)
            .accessibilityElement(children: .combine)
        case .failed(let message):
            StudyPlanNoticeCard(icon: "alert", tone: .bad, title: "Studienverlauf nicht lesbar", text: message) {
                UFButton("Erneut laden", icon: "refresh") { Task { await load() } }
            }
        case .loaded(let p):
            if p.available {
                VStack(alignment: .leading, spacing: 16) {
                    if let s = p.suggestedPO, !p.poConfirmed { poCard(p, suggested: s) }
                    StudyPlanHeaderCard(plan: p)
                    filterRow(p)
                    board(p, layout: layout, pad: pad)
                }
            } else {
                gapCard(p)
            }
        }
    }

    // MARK: Pruefungsordnung bestaetigen

    private func poCard(_ p: StudyPlan, suggested: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                StudyPlanIconTile(icon: "file-text", pair: CommunityPalette.sky)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Deine Prüfungsordnung: PO \(suggested)?").ufFont(15.2, 650, lh: 1.3).foregroundStyle(UF.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(poSub(p, suggested: suggested)).ufFont(13.12, lh: 1.4).foregroundStyle(UF.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            UFFlexWrap(gap: 8) {
                UFButton("Ja, PO \(suggested)", icon: "check", kind: .primary, size: .small) { Task { await confirmPO(suggested) } }
                    .disabled(poBusy)
                    .accessibilityIdentifier("studyplan.po.confirm")
                UFButton("Ändern", size: .small) { showSettings = true }
                    .accessibilityIdentifier("studyplan.po.change")
            }
            .padding(.leading, 52)
            if let poError {
                Text(poError).ufFont(12.8).foregroundStyle(UF.badText).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: UF.r).fill(Color.mix(UF.info, 0.07, UF.surface)))
        .overlay(RoundedRectangle(cornerRadius: UF.r).strokeBorder(Color.mix(UF.info, 0.3, UF.line), lineWidth: 1))
        .accessibilityIdentifier("studyplan.po")
    }

    private func poSub(_ p: StudyPlan, suggested: String) -> String {
        if let q = p.qisProgram, !q.isEmpty {
            return "QIS nennt „\(q)“. Der passende aktuelle Katalog gehört zur PO \(suggested) – stimmt das?"
        }
        return "StudiNow hat die passende Ordnung vorgeschlagen. Bestätige sie oder wähle eine andere."
    }

    // MARK: Filter

    private func filterRow(_ p: StudyPlan) -> some View {
        let all = p.modules
        let counts: [StudyPlanFilter: Int] = [.all: all.count, .open: all.filter { $0.status.isOpen }.count,
                                              .passed: all.filter { $0.status == .passed }.count]
        return UFSegmented(options: StudyPlanFilter.allCases.map { ($0, "\($0.label) (\(counts[$0] ?? 0))") }, selection: $filter)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("studyplan.filter")
    }

    private func visible(_ p: StudyPlan) -> [StudyPlanSemester] {
        guard filter != .all else { return p.semesters }
        return p.semesters.compactMap { s in
            let ms = s.modules.filter(filter.keeps)
            guard !ms.isEmpty else { return nil }
            return StudyPlanSemesterView.filtered(s, modules: ms)
        }
    }

    // MARK: Board

    @ViewBuilder private func board(_ p: StudyPlan, layout: StudyPlanLayout, pad: CGFloat) -> some View {
        let semesters = visible(p)
        if semesters.isEmpty {
            UFCard(flat: true) {
                UFEmpty(icon: filter == .passed ? "check" : "calendar",
                        text: filter == .passed ? "Noch kein Modul bestanden." : "Alles bestanden – nichts mehr offen.")
            }
        } else if layout == .board {
            let width = columnWidth
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(semesters) { s in
                        StudyPlanSemesterView(semester: s, style: .column) { detail = StudyPlanDetailRef(id: $0.id) }
                            .frame(width: width)
                            .id(s.term)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, pad)
                .padding(.vertical, 2)
            }
            .scrollPosition(id: $boardStart, anchor: .leading)
            .padding(.horizontal, -pad)
            .onAppear { boardStart = Self.boardLead(p, semesters: semesters, focus: focus) }
            .onChange(of: semesters.map(\.term)) { _, _ in boardStart = Self.boardLead(p, semesters: semesters, focus: focus) }
            .accessibilityIdentifier("studyplan.board")
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(semesters) { s in
                    StudyPlanSemesterView(semester: s, style: .section) { detail = StudyPlanDetailRef(id: $0.id) }
                        .id("sem-\(s.term)")
                }
            }
            .accessibilityIdentifier("studyplan.list")
        }
    }

    /// Spaltenbreite waechst mit der Schrift (bis Bedienungshilfen-Stufe 1 bleibt es ein Board)
    private var columnWidth: CGFloat {
        typeSize >= .xxxLarge ? 316 : (typeSize >= .xLarge ? 290 : 268)
    }

    // MARK: Ohne Plan

    @ViewBuilder private func gapCard(_ p: StudyPlan) -> some View {
        switch p.gap ?? .other("") {
        case .noQIS:
            StudyPlanNoticeCard(icon: "graduation", pair: CommunityPalette.sky, title: StudyPlanText.noQIS, text: StudyPlanText.noQISSub) {
                UFButton("Zu Uni & Noten", icon: "arrow-right", kind: .primary) { router.go(.services) }
                    .accessibilityIdentifier("studyplan.qis")
            }
            .accessibilityIdentifier("studyplan.gap.qis")
        case .catalogLoading:
            if catalog?.notFound == true {
                noCatalogCard(p)
            } else {
                loadingCard(p)
            }
        case .noCatalog:
            if catalog?.busy == true || catalog?.failed == true { loadingCard(p) } else { noCatalogCard(p) }
        case .other(let message):
            StudyPlanNoticeCard(icon: "info", tone: .neutral, title: "Studienverlauf noch nicht verfügbar", text: message) {
                UFButton("Erneut laden", icon: "refresh") { Task { await load() } }
            }
        }
    }

    private func loadingCard(_ p: StudyPlan) -> some View {
        let st = catalog
        return UFCard {
            HStack(alignment: .top, spacing: 12) {
                StudyPlanIconTile(icon: st?.failed == true ? "alert" : "download",
                                  pair: st?.failed == true ? CommunityPalette.rose : CommunityPalette.lavender)
                VStack(alignment: .leading, spacing: 6) {
                    Text(st?.failed == true ? "Modulkatalog nicht geladen" : "Modulkatalog wird vorbereitet")
                        .ufFont(15.2, 650, lh: 1.3).foregroundStyle(UF.text)
                    if !p.programLine.isEmpty {
                        Text(([p.programLine] + [p.po.map { "PO \($0)" }].compactMap { $0 }).joined(separator: " · "))
                            .ufFont(13.12).foregroundStyle(UF.text2)
                    }
                    HStack(spacing: 8) {
                        if st?.failed != true { ProgressView().controlSize(.small) }
                        Text(st?.text ?? StudyCatalogStatus(["state": "searching"]).text)
                            .ufFont(13.12, lh: 1.4).foregroundStyle(st?.failed == true ? UF.badText : UF.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("studyplan.catalog.status")
                    if let pr = st?.progress, st?.failed != true {
                        UFProgress(value: pr).frame(maxWidth: 360)
                            .accessibilityElement()
                            .accessibilityLabel("Fortschritt")
                            .accessibilityValue("\(Int((pr * 100).rounded())) Prozent")
                    }
                    Text("Der Katalog wird einmal je Studiengang geladen und geteilt – ohne deine Noten oder deinen Namen.")
                        .ufFont(12.48, lh: 1.4).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
                    if st?.failed == true {
                        UFButton("Erneut versuchen", icon: "refresh", size: .small) { Task { await load() } }.padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
        .accessibilityIdentifier("studyplan.gap.loading")
    }

    private func noCatalogCard(_ p: StudyPlan) -> some View {
        UFCard {
            HStack(alignment: .top, spacing: 12) {
                StudyPlanIconTile(icon: "book", pair: CommunityPalette.peach)
                VStack(alignment: .leading, spacing: 8) {
                    Text(StudyPlanText.noCatalog).ufFont(15.2, 650, lh: 1.3).foregroundStyle(UF.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if !p.programLine.isEmpty {
                        Text(([p.programLine] + [p.po.map { "PO \($0)" }].compactMap { $0 }).joined(separator: " · "))
                            .ufFont(13.12, 600).foregroundStyle(UF.text2)
                    }
                    if let msg = p.message, msg != StudyPlanText.noCatalog, !msg.hasPrefix("Für deinen Studiengang") {
                        Text(msg).ufFont(13.12, 600, lh: 1.45).foregroundStyle(UF.warnText).fixedSize(horizontal: false, vertical: true)
                    }
                    Text(StudyPlanText.noCatalogSub).ufFont(13.12, lh: 1.45).foregroundStyle(UF.text2)
                        .fixedSize(horizontal: false, vertical: true)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { linkField.frame(minWidth: 280); linkButton }
                        VStack(alignment: .leading, spacing: 8) { linkField; linkButton }
                    }
                    .padding(.top, 2)
                    if let m = linkMessage {
                        Label { Text(m.text) } icon: { UFIcon(m.ok ? "check" : "alert", size: 14) }
                            .ufFont(12.8).foregroundStyle(m.ok ? UF.okText : UF.badText)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("studyplan.link.message")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
        .accessibilityIdentifier("studyplan.gap.catalog")
    }

    private var linkField: some View {
        UFTextField("https://…/modulhandbuch.pdf", text: $linkText)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .onSubmit { Task { await saveLink() } }
            .accessibilityLabel(StudyPlanText.linkField)
            .accessibilityIdentifier("studyplan.link.field")
    }

    private var linkButton: some View {
        UFButton("Link speichern", icon: "check", kind: .primary) {
            Task { await saveLink() }
        }
        .disabled(linkBusy || linkText.trimmingCharacters(in: .whitespaces).isEmpty)
        .fixedSize()
        .accessibilityIdentifier("studyplan.link.save")
    }

    // MARK: Laden und Schreiben

    func load() async {
        guard let api = session.api else { phase = .failed("Keine Datenquelle."); return }
        do {
            let v = try await api.value("/api/study-plan")
            let p = StudyPlan(v)
            phase = .loaded(p)
            if p.gap == .catalogLoading || p.gap == .noCatalog {
                catalog = (try? await api.value("/api/study-catalog/status")).map(StudyCatalogStatus.init)
            }
            if !focusDone, let f = focus, p.available {
                focusDone = true
                if let m = p.module(matching: f) { detail = StudyPlanDetailRef(id: m.id) }
            }
        } catch {
            if case .loaded = phase { return }                                  // letzter Stand bleibt
            phase = .failed(error.localizedDescription)
        }
    }

    /// Nachfrage waehrend der Katalogsuche; fertig: Plan neu lesen
    private var pollKey: String {
        plan?.gap == .catalogLoading || (plan?.gap == .noCatalog && catalog?.busy == true) ? "poll" : ""
    }

    private func poll() async {
        guard pollKey == "poll", let api = session.api else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(max(0.2, pollInterval) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let v = try? await api.value("/api/study-catalog/status") else { continue }
            let st = StudyCatalogStatus(v)
            catalog = st
            if st.ready { await load(); return }
            if !st.busy { return }
        }
    }

    /// Einstellungen lesen und mit einer Aenderung zuruecksenden (fehlt GET, nur das eine Feld)
    private func post(_ change: (inout JSONValue) -> Void, api: APIClient) async throws {
        var body: JSONValue
        if let v = try? await api.value("/api/study-plan/settings") {
            let s = StudyPlanSettings(v)
            body = s.body(po: s.po, startTerm: s.startTerm, electives: Set(s.electives))
        } else {
            body = .object([:])
        }
        change(&body)
        _ = try await api.value("/api/study-plan/settings", method: "POST", body: body)
    }

    private func confirmPO(_ po: String) async {
        guard let api = session.api else { return }
        poBusy = true
        defer { poBusy = false }
        do {
            try await post({ $0["po"] = .string(po) }, api: api)
            poError = nil
            await load()
        } catch {
            poError = "Speichern fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    private func saveLink() async {
        guard let api = session.api else { return }
        guard let url = StudyPlanText.catalogURL(linkText) else {
            linkMessage = (StudyPlanText.linkInvalid, false)
            return
        }
        linkBusy = true
        defer { linkBusy = false }
        do {
            try await post({ $0["catalog_url"] = .string(url.absoluteString) }, api: api)
            linkMessage = (StudyPlanText.linkSaved, true)
            await load()
        } catch {
            linkMessage = ("Speichern fehlgeschlagen: \(error.localizedDescription)", false)
        }
    }

    /// Board quer: liegt das aktuelle Semester (bzw. das aus `focus`) hinter der dritten Spalte (am iPad 10,9" quer
    /// passen drei ganz), beginnt das Board beim Semester davor, damit es als zweite Spalte mit dem vorigen als Bezug
    /// erscheint; sonst bleibt es am Anfang (nil)
    static func boardLead(_ p: StudyPlan, semesters: [StudyPlanSemester], focus: String?) -> String? {
        let target = focus.flatMap { p.module(matching: $0) }.flatMap { p.semester(of: $0.id) } ?? p.currentSemester
        guard let target, let i = semesters.firstIndex(where: { $0.term == target.term }), i >= 3 else { return nil }
        return semesters[i - 1].term
    }

    /// Liste hochkant: zum Semester des Moduls aus `focus` rollen
    private func scrollToStart(_ p: StudyPlan?, proxy: ScrollViewProxy) {
        guard let p, p.available else { return }
        // nur mit `focus`: hochkant bleibt sonst der Kopf mit dem Ring oben sichtbar
        guard let target = focus.flatMap({ p.module(matching: $0) }).flatMap({ p.semester(of: $0.id) }) else { return }
        DispatchQueue.main.async { proxy.scrollTo("sem-\(target.term)", anchor: .top) }
    }
}

// MARK: - Kopfkarte

struct StudyPlanHeaderCard: View {
    let plan: StudyPlan
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let ring = min(UFScaledFont.scaled(96, typeSize), 136)
        let percent = StudyPlanText.percent(plan.lpDone, plan.lpTotal)
        UFCard {
            HStack(alignment: .center, spacing: 18) {
                ZStack {
                    LernstandRing(percent: percent, color: UF.ok, lineWidth: 7)
                    VStack(spacing: 0) {
                        Text(StudyPlanText.number(plan.lpDone)).ufFont(24, 700, lh: 1.1).monospacedDigit().foregroundStyle(UF.text)
                        Text("von \(StudyPlanText.number(plan.lpTotal)) LP").ufFont(11.2, 500, lh: 1.2).foregroundStyle(UF.muted)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 12)
                }
                .frame(width: ring, height: ring)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(StudyPlanText.progress(plan.lpDone, plan.lpTotal))
                .accessibilityValue("\(Int(percent.rounded())) Prozent")
                .accessibilityIdentifier("studyplan.progress")
                VStack(alignment: .leading, spacing: 4) {
                    Text(plan.programLine.isEmpty ? "Dein Studiengang" : plan.programLine)
                        .ufFont(17.6, 650, lh: 1.3, em: -0.01).foregroundStyle(UF.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    if !plan.subLine.isEmpty {
                        Text(plan.subLine).ufFont(13.12).foregroundStyle(UF.text2)
                    }
                    Text(StudyPlanText.progress(plan.lpDone, plan.lpTotal) + " erreicht")
                        .ufFont(13.12, 600).foregroundStyle(UF.okText)
                        .accessibilityHidden(true)
                    if !plan.notes.isEmpty {
                        UFFlexWrap(gap: 6) {
                            ForEach(Array(plan.notes.enumerated()), id: \.offset) { _, n in
                                UFBadge(n.text, tone: n.tone, icon: n.tone == .bad ? "alert" : (n.tone == .warn ? "move" : "info"))
                            }
                        }
                        .padding(.top, 4)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Hinweise: " + plan.notes.map(\.text).joined(separator: ", "))
                        .accessibilityIdentifier("studyplan.notes")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                UFIcon("info", size: 13).foregroundStyle(UF.muted)
                Text(plan.disclaimer).ufFont(12.48, lh: 1.4).foregroundStyle(UF.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(UF.line).frame(height: 1).padding(.top, 4) }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("studyplan.disclaimer")
        }
    }
}

// MARK: - Semester (Spalte bzw. Abschnitt)

struct StudyPlanSemesterView: View {
    enum Style { case column, section }
    let semester: StudyPlanSemester
    let style: Style
    let open: (StudyPlanModule) -> Void

    /// Semester mit gefilterten Modulen (LP-Summe bleibt die des ganzen Semesters)
    static func filtered(_ s: StudyPlanSemester, modules: [StudyPlanModule]) -> StudyPlanSemester {
        var copy = s
        copy.modules = modules
        return copy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            head
            if semester.modules.isEmpty {
                Text("Keine Module geplant").ufFont(12.8).foregroundStyle(UF.muted).padding(.vertical, 6)
            } else if style == .column {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(semester.modules) { m in StudyPlanModuleCard(module: m) { open(m) } }
                }
            } else {
                UFGridLayout(spacing: 10, minWidth: gridMin) {
                    ForEach(semester.modules) { m in StudyPlanModuleCard(module: m, fills: true) { open(m) } }
                }
            }
        }
        .padding(style == .column ? 10 : 14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(semester.current ? Color.mix(UF.accent, 0.07, UF.bg) : Color.mix(UF.surface2, 0.7, UF.bg)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(semester.current ? Color.mix(UF.accent, 0.55, UF.line) : UF.line,
                                                                 lineWidth: semester.current ? 1.5 : 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("studyplan.semester.\(semester.term)")
    }

    @Environment(\.dynamicTypeSize) private var typeSize

    /// Mindestbreite der Karten im Raster: mit grosser Schrift weniger, breitere Spalten (Woerter brechen nie mitten)
    private var gridMin: CGFloat { typeSize >= .accessibility1 ? 340 : (typeSize >= .xxLarge ? 280 : 236) }

    private var head: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(semester.term).ufFont(15.2, 650, lh: 1.3).foregroundStyle(UF.text).lineLimit(1)
                    if semester.current { UFBadge("Aktuell", tone: .accent) }
                }
                if let f = StudyPlanText.fach(semester.fachsemester) {
                    Text(f).ufFont(12.48).foregroundStyle(UF.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            UFBadge(StudyPlanText.lp(semester.lp), tone: semester.overloaded ? .warn : .neutral, icon: semester.overloaded ? "alert" : nil)
                .fixedSize()
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(StudyPlanText.accessibility(semester))
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Modulkarte

struct StudyPlanModuleCard: View {
    let module: StudyPlanModule
    /// im Raster: Karte fuellt die Zeilenhoehe
    var fills = false
    let action: () -> Void

    var body: some View {
        let m = module
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(m.title).ufFont(14, 600, lh: 1.3).foregroundStyle(m.status == .passed ? UF.text2 : UF.text)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(StudyPlanText.lp(m.lp)).ufFont(12.48, 650).monospacedDigit().foregroundStyle(UF.text2).fixedSize()
                }
                UFFlexWrap(gap: 5, rowGap: 5) {
                    StudyPlanTag(text: StudyPlanText.kind(m.kind), pair: StudyPlanText.kindPair(m.kind))
                    if let t = StudyPlanText.turnus(m.turnus) { StudyPlanTag(text: t, pair: nil) }
                }
                StudyPlanStatusPill(text: StudyPlanText.status(m), status: m.status)
                if let r = StudyPlanText.reasonLine(m) {
                    Text(r).ufFont(12, lh: 1.35).foregroundStyle(UF.muted)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if m.lastAttempt {
                    HStack(spacing: 4) {
                        UFIcon("alert", size: 12)
                        Text("Letzter Versuch").ufFont(12, 650)
                    }
                    .foregroundStyle(UF.badText)
                }
            }
            .padding(.vertical, 10)
            .padding(.leading, 13)
            .padding(.trailing, 11)
            .frame(maxWidth: .infinity, maxHeight: fills ? .infinity : nil, alignment: .topLeading)
            .background(UF.surface)
            .overlay(alignment: .leading) { Rectangle().fill(StudyPlanText.areaColor(m.area)).frame(width: 3.5) }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(m.status == .failed ? Color.mix(UF.bad, 0.4, UF.line) : UF.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(StudyPlanPressStyle())
        .accessibilityLabel(StudyPlanText.accessibility(m))
        .accessibilityHint("Zeigt Details zum Modul")
        .accessibilityIdentifier("studyplan.module.\(m.id)")
    }
}

/// leichtes Eindruecken beim Tippen (ohne Bewegung reduzieren nur Deckkraft)
struct StudyPlanPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed && !UIAccessibility.isReduceMotionEnabled ? 0.985 : 1)
            .animation(UF.motion(.easeOut(duration: 0.12)), value: configuration.isPressed)
    }
}

/// Statuspille: Ton und Symbol je Status, bricht bei grosser Schrift um
struct StudyPlanStatusPill: View {
    let text: String
    let status: StudyPlanStatus

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4.8) {
            UFIcon(status.icon, size: 12).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
            Text(text).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
        }
        .ufFont(12, 600, lh: 1.3)
        .foregroundStyle(status.tone.fg)
        .padding(.vertical, 2.4)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(status.tone.bg))
        .accessibilityElement(children: .combine)
    }
}

/// kleines Etikett: Art (farbig) oder Turnus (Umriss)
struct StudyPlanTag: View {
    let text: String
    let pair: CommunityPair?

    var body: some View {
        Text(text)
            .ufFont(11.52, 600, lh: 1.3)
            .lineLimit(1)
            .foregroundStyle(pair?.fg ?? UF.text2)
            .padding(.vertical, 1.2)
            .padding(.horizontal, 7)
            .background(Capsule().fill(pair?.bg ?? Color.clear))
            .overlay(Capsule().strokeBorder(pair == nil ? UF.lineStrong : Color.clear, lineWidth: 1))
    }
}

/// Symbolkachel links in Hinweiskarten
struct StudyPlanIconTile: View {
    let icon: String
    let pair: CommunityPair

    var body: some View {
        RoundedRectangle(cornerRadius: 11)
            .fill(pair.bg)
            .overlay(UFIcon(icon, size: 19).foregroundStyle(pair.fg))
            .frame(width: 40, height: 40)
            .accessibilityHidden(true)
    }
}

/// Karte fuer Zustaende ohne Plan: Symbolkachel, Titel, Text, Aktionen
struct StudyPlanNoticeCard<Actions: View>: View {
    let icon: String
    var pair: CommunityPair
    let title: String
    let text: String
    @ViewBuilder var actions: Actions

    init(icon: String, pair: CommunityPair, title: String, text: String, @ViewBuilder actions: () -> Actions) {
        self.icon = icon
        self.pair = pair
        self.title = title
        self.text = text
        self.actions = actions()
    }

    init(icon: String, tone: UFTone, title: String, text: String, @ViewBuilder actions: () -> Actions) {
        self.init(icon: icon, pair: CommunityPair(bg: tone.bg, fg: tone.fg, solid: tone.fg), title: title, text: text, actions: actions)
    }

    var body: some View {
        UFCard {
            HStack(alignment: .top, spacing: 12) {
                StudyPlanIconTile(icon: icon, pair: pair)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).ufFont(15.2, 650, lh: 1.3).foregroundStyle(UF.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    if !text.isEmpty {
                        Text(text).ufFont(13.12, lh: 1.45).foregroundStyle(UF.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    UFFlexWrap(gap: 8) { actions }.padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
    }
}
