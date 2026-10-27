import SwiftUI
import UniFlowCore

// App-Rahmen 1:1 nach index.html / app.js: Seitenleiste (Logo, Menue, Einstellungen/Einklappen unten fest),
// Kopfzeile (Menue, Suche, Sync-Status, Sync, Hell/Dunkel, Zeitmesser, Avatar), Inhalt; unter 900 pt Breite
// Schublade + untere Leiste wie im Web (@media max-width: 900px).

// MARK: - Routen (Hash-Routen der Web-App)

enum UFRoute: Hashable {
    case dashboard
    case plan(view: String? = nil, date: String? = nil, module: String? = nil)
    case timetable(date: String? = nil)
    case modules
    case module(Int)
    case files(section: String? = nil, path: String? = nil, q: String? = nil)
    case doc(String, task: Int? = nil, page: Int? = nil)
    case exams
    case exam(Int, task: Int? = nil)
    case cards
    case services
    case community
    case settings(tab: String? = nil)

    /// Menuepunkt, der markiert wird (Dokument -> "Dokumente & Notizen", wie route() in app.js)
    var navKey: String {
        switch self {
        case .dashboard: return "dashboard"
        case .plan: return "plan"
        case .timetable: return "timetable"
        case .modules, .module: return "modules"
        case .files, .doc: return "files"
        case .exams, .exam, .cards: return "exams"
        case .services: return "services"
        case .community: return "community"
        case .settings: return "settings"
        }
    }

    /// Hash-Route der Web-App, z. B. fuer eingebettete Web-Ansichten
    var hash: String {
        func q(_ pairs: [(String, String?)]) -> String {
            let s = pairs.compactMap { k, v in v.map { "\(k)=\($0)" } }.joined(separator: "&")
            return s.isEmpty ? "" : "?" + s
        }
        switch self {
        case .dashboard: return "#/dashboard"
        case .plan(let v, let d, let m): return "#/plan" + q([("view", v), ("date", d), ("module", m)])
        case .timetable(let d): return "#/timetable" + q([("date", d)])
        case .modules: return "#/modules"
        case .module(let id): return "#/modules/\(id)"
        case .files(let s, let p, let qq): return "#/files" + q([("section", s), ("path", p), ("q", qq.map { $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0 })])
        case .doc(let id, let t, let p): return "#/doc/\(id)" + q([("task", t.map { "\($0)" }), ("page", p.map { "\($0)" })])
        case .exams: return "#/exams"
        case .exam(let id, let t): return "#/exams/\(id)" + q([("task", t.map { "\($0)" })])
        case .cards: return "#/cards"
        case .services: return "#/services"
        case .community: return "#/community"
        case .settings(let t): return "#/settings" + q([("tab", t)])
        }
    }

    /// Web-Link wie "#/plan?view=day&date=2026-10-26" (Links aus Serverdaten) in eine Route uebersetzen.
    init(hash: String) {
        var h = hash
        if h.hasPrefix("#") { h.removeFirst() }
        if h.hasPrefix("/") { h.removeFirst() }
        let pq = h.split(separator: "?", maxSplits: 1).map(String.init)
        let parts = (pq.first ?? "").split(separator: "/").map(String.init)
        var q: [String: String] = [:]
        if pq.count > 1 {
            for kv in pq[1].split(separator: "&") {
                let p = kv.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                if p.count == 2 { q[p[0]] = p[1] }
            }
        }
        let first = parts.first ?? "dashboard"
        let second = parts.count > 1 ? parts[1] : nil
        switch first {
        case "plan": self = .plan(view: q["view"], date: q["date"], module: q["module"])
        case "tasks": self = .plan(view: "list", date: q["date"])
        case "timetable": self = .timetable(date: q["date"])
        case "modules": self = second.flatMap(Int.init).map { .module($0) } ?? .modules
        case "files": self = .files(section: q["section"], path: q["path"].flatMap { $0.isEmpty ? nil : $0 }, q: q["q"].flatMap { $0.isEmpty ? nil : $0 })
        case "doc": self = second.map { .doc($0, task: q["task"].flatMap(Int.init), page: q["page"].flatMap(Int.init)) } ?? .files()
        case "exams": self = second.flatMap(Int.init).map { .exam($0, task: q["task"].flatMap(Int.init)) } ?? .exams
        case "cards": self = .cards
        case "services": self = .services
        case "community": self = .community
        case "settings": self = .settings(tab: q["tab"])
        default: self = .dashboard
        }
    }

    /// uniflow://#/plan?view=week oder uniflow://plan?view=week -> "#/plan?view=week"
    static func hash(fromDeepLink url: URL) -> String? {
        guard url.scheme == "uniflow" else { return nil }
        if let f = url.fragment, !f.isEmpty { return "#" + f }
        let path = (url.host ?? "") + url.path
        return "#/" + path + (url.query.map { "?" + $0 } ?? "")
    }
}

@MainActor
final class UFRouter: ObservableObject {
    @Published private(set) var route: UFRoute = .dashboard
    @Published var drawerOpen = false
    @Published var fullscreenDoc = false
    @Published var examFocus = false
    /// state.route(): aktuelle Ansicht neu laden (nach Aenderungen in Dialogen und Drawern)
    @Published private(set) var reloadToken = 0
    private var history: [UFRoute] = []

    func reload() { reloadToken += 1 }

    func go(_ r: UFRoute) {
        guard r != route else { return }
        history.append(route)
        if history.count > 50 { history.removeFirst() }
        route = r
        drawerOpen = false
        fullscreenDoc = false            // route() entfernt exam-focus, fullscreen-doc, doc-open
        examFocus = false
    }

    func go(hash: String) { go(UFRoute(hash: hash)) }

    func back() {
        if let r = history.popLast() { route = r }
    }
}

// MARK: - Menue (NAV in app.js)

struct UFNavItem: Identifiable {
    let id: String
    let title: String
    let icon: String
    let route: UFRoute

    static let main: [UFNavItem] = [
        UFNavItem(id: "dashboard", title: "Übersicht", icon: "home", route: .dashboard),
        UFNavItem(id: "plan", title: "Lernkalender", icon: "calendar", route: .plan()),
        UFNavItem(id: "timetable", title: "Stundenplan", icon: "clock", route: .timetable()),
        UFNavItem(id: "modules", title: "Meine Module", icon: "book", route: .modules),
        UFNavItem(id: "files", title: "Dokumente & Notizen", icon: "folder", route: .files()),
        UFNavItem(id: "exams", title: "Tests & Wiederholung", icon: "exam", route: .exams),
        UFNavItem(id: "services", title: "Uni & Noten", icon: "graduation", route: .services),
        UFNavItem(id: "community", title: "Community", icon: "users", route: .community),
    ]

    /// Eigene Karteikarten ohne PC: Eintrag an Stelle von "Tests & Wiederholung"
    static let cards = UFNavItem(id: "cards", title: "Karteikarten", icon: "cards", route: .cards)

    /// Eintraege der Seitenleiste. Ohne PC (lokales Backend) nur Bereiche mit Funktion (App Review 2.1/2.2): statt
    /// "Tests & Wiederholung" (Wochentests entfallen in V1) "Karteikarten" (`flashcards`: eigene Karten auf dem Geraet,
    /// Plus; ohne Plus zeigt die Seite die Sperrkarte), "Community" nur, wenn der Build einen iCloud-Container hat
    /// (`community`: CloudKit-Dienst verfuegbar; sonst teilt man Loesungen im Editor als Datei und die Einstellungen
    /// sagen ehrlich, warum) und "Uni & Noten" nur, wo der Notenspiegel auf dem Geraet ankommt (`gradesOnDevice`: seit
    /// QIS auf dem Geraet an der LUH wie am LSF der Uni Hildesheim immer).
    static func visible(local: Bool, gradesOnDevice: Bool, community: Bool,
                        flashcards: Bool = UFFeatureMatrix.flashcardsOnDevice) -> [UFNavItem] {
        guard local else { return main }
        return main.compactMap { item in
            switch item.id {
            case "exams": return flashcards ? cards : nil
            case "community": return community ? item : nil
            case "services": return gradesOnDevice ? item : nil
            default: return item
            }
        }
    }

    /// Markiert: "Karteikarten" nur auf der Karteikarten-Seite, sonst nach `UFRoute.navKey` (am eigenen Server fuehrt
    /// die Karteikarten-Seite weiter unter "Tests & Wiederholung")
    func isActive(_ route: UFRoute) -> Bool { id == "cards" ? route == .cards : route.navKey == id }

    /// untere Leiste (mobileNav in app.js)
    static let mobile: [UFNavItem] = [
        UFNavItem(id: "dashboard", title: "Start", icon: "home", route: .dashboard),
        UFNavItem(id: "plan", title: "Kalender", icon: "calendar", route: .plan()),
        UFNavItem(id: "modules", title: "Module", icon: "book", route: .modules),
        UFNavItem(id: "files", title: "Dokumente", icon: "folder", route: .files()),
        UFNavItem(id: "settings", title: "Mehr", icon: "settings", route: .settings()),
    ]
}

// MARK: - Rahmen

struct AppShell<Content: View>: View {
    @EnvironmentObject private var router: UFRouter
    @EnvironmentObject private var overlay: UFOverlay
    @AppStorage("sidebar") private var sidebarMode = "full"          // localStorage "sidebar": "min" | "full"
    @ViewBuilder let content: (UFRoute) -> Content

    var body: some View {
        GeometryReader { geo in
            let narrow = geo.size.width <= 900
            let docOpen: Bool = { if case .doc = router.route { return true }; return false }()
            let hideChrome = router.fullscreenDoc || router.examFocus
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    if !narrow && !hideChrome {
                        UFSidebar(collapsed: docOpen || sidebarMode == "min", allowCollapse: !docOpen)
                            .frame(width: docOpen || sidebarMode == "min" ? UF.sidebarMin : UF.sidebar)
                            .transition(.move(edge: .leading))
                    }
                    VStack(spacing: 0) {
                        if !hideChrome && !docOpen { UFHeader(narrow: narrow) }          // doc-open: Kopfzeile aus
                        content(router.route)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if narrow && !hideChrome && !docOpen { UFMobileNav() }
                    }
                    .modifier(UFDrawerHost(overlay: overlay))
                }
                .background(UF.bg)
                if narrow && router.drawerOpen {
                    Color.black.opacity(0.35).ignoresSafeArea()
                        .onTapGesture { router.drawerOpen = false }
                    UFSidebar(collapsed: false, allowCollapse: false)
                        .frame(width: UF.sidebar)
                        .ufShadow(.lg)
                        .transition(.move(edge: .leading))
                }
            }
            .animation(UF.transition, value: sidebarMode)
            .animation(UF.transition, value: router.drawerOpen)
            .environment(\.ufWindowWidth, geo.size.width)
        }
    }
}

struct UFSidebar: View {
    @EnvironmentObject private var router: UFRouter
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var studip: StudIPSync
    @AppStorage("sidebar") private var sidebarMode = "full"
    let collapsed: Bool
    let allowCollapse: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 9.6) {                                       // .brand
                RoundedRectangle(cornerRadius: 9).fill(UF.logoGradient)
                    .frame(width: 30, height: 30)
                    .overlay(UFIcon("graduation", size: 18).foregroundStyle(.white))
                if !collapsed { Text("UniFlow").font(.uf(16.32, 700)).foregroundStyle(UF.text).lineLimit(1) }
            }
            .padding(EdgeInsets(top: 5.6, leading: 8, bottom: 14.4, trailing: 8))
            .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)

            ScrollView(showsIndicators: false) {                         // .nav scrollt selbst, Fuss bleibt fest
                VStack(spacing: 4) {
                    // Noten auf dem Geraet wie bei UFServerGate (`Spec.services.localWithOtherSources`): an beiden Hochschulen
                    // (QIS an der LUH, LSF in Hildesheim); Community nur mit CloudKit-Dienst des aktiven Containers
                    ForEach(UFNavItem.visible(local: session.api?.isLocal ?? true, gradesOnDevice: true,
                                              community: SolutionSharing.community.isConnected)) { item in
                        navRow(item.title, icon: item.icon, active: item.isActive(router.route)) { router.go(item.route) }
                    }
                }
            }
            VStack(spacing: 4) {                                         // .side-foot
                navRow("Einstellungen", icon: "settings", active: router.route.navKey == "settings") { router.go(.settings()) }
                if allowCollapse {
                    navRow("Einklappen", icon: "panel-left", active: false) { sidebarMode = sidebarMode == "min" ? "full" : "min" }
                }
            }
            .padding(.top, 5.6)
            .overlay(alignment: .top) { Rectangle().fill(UF.line).frame(height: 1) }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 9.6)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(UF.surface)
        .overlay(alignment: .trailing) { Rectangle().fill(UF.line).frame(width: 1) }
    }

    private func navRow(_ title: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10.4) {
                UFIcon(icon, size: 18)
                if !collapsed { Text(title).font(.uf(14.5, 500)).lineLimit(1) }
            }
            .foregroundStyle(active ? UF.accentText : UF.text2)
            .padding(.vertical, collapsed ? 9.6 : 8.8)
            .padding(.horizontal, collapsed ? 9.6 : 11.2)
            .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
            .background(RoundedRectangle(cornerRadius: UF.rSm).fill(active ? UF.accentSoft : .clear))
            .contentShape(RoundedRectangle(cornerRadius: UF.rSm))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .help(title)
    }
}

/// .mobile-nav: fuenf gleich breite Eintraege, aktiv mit --accent-soft
struct UFMobileNav: View {
    @EnvironmentObject private var router: UFRouter

    var body: some View {
        HStack(spacing: 0) {
            ForEach(UFNavItem.mobile) { item in
                let active = router.route.navKey == item.id
                Button { router.go(item.route) } label: {
                    VStack(spacing: 1.6) {
                        UFIcon(item.icon, size: 20)
                        Text(item.title).font(.uf(10.56))
                    }
                    .foregroundStyle(active ? UF.accentText : UF.muted)
                    .padding(4)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 6).fill(active ? UF.accentSoft : .clear))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 3.2)
        .padding(.top, 4.8)
        .padding(.bottom, 4.8)
        .background(UF.surface.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(UF.line).frame(height: 1) }
    }
}

// MARK: - Kopfzeile

/// Erscheinungsbild wie setTheme() in app.js: "light" (Vorgabe), "dark", "auto"
enum UFThemeMode: String {
    case light, dark, auto

    var scheme: ColorScheme? { self == .light ? .light : self == .dark ? .dark : nil }
    /// Reihenfolge des Knopfs: dunkel -> hell -> automatisch -> dunkel
    var next: UFThemeMode { self == .dark ? .light : self == .light ? .auto : .dark }
    var label: String { self == .dark ? "Dunkel" : self == .light ? "Hell" : "Automatisch" }
}

struct UFHeader: View {
    /// Sync-Knopf: Abgleich des eigenen Servers, sonst Stud.IP bzw. Learnweb und LSF direkt auf dem iPad oder der Weg
    /// zur Anmeldung
    private func sync() {
        if session.isOwnServer { Task { await shell.startSync(toast: toast) }; return }
        // Demo-Inhalte: kein Abgleich mit der Hochschule, Hinweis und der Weg zum Entfernen
        if demo {
            toast.show(DemoTexts.syncBlocked, seconds: 4)
            router.go(.settings(tab: "advanced"))
            return
        }
        guard studip.offersStudIP else {
            guard let hildesheim, hildesheim.anyConnected else {
                toast.show("Zuerst Learnweb oder LSF verbinden")
                router.go(.settings(tab: "account"))
                return
            }
            let names = HildesheimConnection.Source.allCases.filter { hildesheim.isConnected($0) }.map(\.rawValue)
            toast.show("\(names.joined(separator: " und ")) \(names.count == 1 ? "wird" : "werden") abgeglichen …")
            Task { await hildesheim.run() }
            return
        }
        switch studip.phase {
        case .signedOut, .needsLogin:
            toast.show("Zuerst Stud.IP verbinden")
            router.go(.settings(tab: "account"))
        default:
            toast.show("Stud.IP wird abgeglichen …")
            Task { await studip.run() }
        }
    }

    let narrow: Bool
    @EnvironmentObject private var router: UFRouter
    @EnvironmentObject private var shell: ShellState
    @EnvironmentObject private var toast: UFToastCenter
    @EnvironmentObject private var timer: StudyTimer
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var studip: StudIPSync
    @Environment(\.hildesheim) private var hildesheim
    @Environment(\.ufDemoActive) private var demo
    @AppStorage("theme") private var theme = UFThemeMode.light.rawValue
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 9.6) {
            if narrow {
                UFButton(icon: "menu", kind: .ghost) { router.drawerOpen.toggle() }
            }
            // .search { flex: 1; max-width: 520px } und .spacer { flex: 1 } teilen sich den freien Platz
            searchField
            Color.clear.frame(height: 1)
            if !narrow, let chip = shell.syncChip {
                HStack(spacing: 6.4) {
                    UFIcon(shell.syncRunning ? "refresh" : (shell.lastSyncOK ? "check" : "info"), size: 14)
                        .foregroundStyle(shell.lastSyncOK && !shell.syncRunning ? UF.ok : UF.muted)
                    Text(chip)
                }
                .font(.uf(12.8))
                .foregroundStyle(UF.muted)
                .lineLimit(1)
            }
            // mit eigenem Server dessen Abgleich, sonst Stud.IP bzw. Learnweb und LSF direkt auf dem iPad (V1 ohne PC-Server)
            UFButton("Sync", icon: "sync", size: .small) { sync() }
                .disabled(shell.syncRunning || studip.isRunning)
            UFButton(icon: theme == UFThemeMode.dark.rawValue ? "moon" : "sun", kind: .ghost) {
                let next = (UFThemeMode(rawValue: theme) ?? .light).next
                theme = next.rawValue
                toast.show("Design: \(next.label)")
            }
            if !narrow {
                UFButton(icon: "clock", kind: .ghost) { timer.toggle() }     // #profileBtn: Zeitmesser
            }
            // .avatar: 34 pt, accent-soft, .78rem fett; ohne Server die Initialen aus dem Apple-Namen, sonst ein Symbol
            let ini = shell.initials.isEmpty ? ShellState.initials(of: account.account?.name) : shell.initials
            Group {
                if ini.isEmpty { UFIcon("user", size: 16) } else { Text(ini).font(.uf(12.48, 700)) }
            }
            .foregroundStyle(UF.accentText)
            .frame(width: 34, height: 34)
            .background(Circle().fill(UF.accentSoft))
            .help(account.account == nil ? "Nicht angemeldet" : "Angemeldet mit deiner Apple-ID")
        }
        .padding(.horizontal, narrow ? 11.2 : 17.6)
        .frame(height: UF.header)
        .background(.ultraThinMaterial)
        .background(UF.surface.opacity(0.88))
        .ufBorderBottom()
        .overlay(alignment: .topLeading) { searchResults }
        .zIndex(15)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            UFIcon("search", size: 16).foregroundStyle(UF.muted)
            TextField("Suche nach Dateien, Modulen, Themen…", text: $query)
                .font(UF.body)
                .focused($searchFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: query) { _, q in shell.search(q) }
                .onSubmit { if let first = shell.searchHits.first { open(first.route) } }
            if !narrow && query.isEmpty {                                   // .kbd (Web: "Strg K"; iPad-Tastatur: Cmd)
                Text("⌘ K")
                    .font(.uf(10.88)).foregroundStyle(UF.muted)
                    .padding(.horizontal, 5.6)
                    .background(RoundedRectangle(cornerRadius: 5).fill(UF.surface))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(UF.line, lineWidth: 1))
            }
        }
        .padding(.vertical, 8)
        .padding(.leading, 11.2)
        .padding(.trailing, 12.8)
        .background(Capsule().fill(UF.surface2))
        .overlay(Capsule().strokeBorder(UF.line, lineWidth: 1))
        .frame(maxWidth: 520)
        .background(Button("") { searchFocused = true }.keyboardShortcut("k", modifiers: .command).opacity(0))
    }

    @ViewBuilder private var searchResults: some View {
        if searchFocused && query.trimmingCharacters(in: .whitespaces).count >= 2 {
            VStack(alignment: .leading, spacing: 0) {
                if let e = shell.searchError {
                    HStack(spacing: 6) { UFIcon("alert", size: 14); Text(e) }.font(UF.small).foregroundStyle(UF.warn).padding(9.6)
                } else if shell.searchHits.isEmpty {
                    Text("Keine Treffer").font(UF.small).foregroundStyle(UF.muted).padding(9.6)
                } else {
                    ForEach(shell.searchHits) { hit in
                        Button { open(hit.route) } label: {
                            HStack(spacing: 8) {
                                if let c = hit.color { UFDot(color: c) } else { UFIcon(hit.icon, size: 16).foregroundStyle(UF.text2) }
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(hit.title).font(.uf(14.5, hit.color == nil ? 400 : 600)).foregroundStyle(UF.text).lineLimit(1)
                                    Text(hit.sub).font(UF.small).foregroundStyle(UF.muted).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 7.2)
                            .padding(.horizontal, 9.6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(5.6)
            .frame(maxWidth: 520, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.surface))
            .overlay(RoundedRectangle(cornerRadius: UF.r).strokeBorder(UF.line, lineWidth: 1))
            .ufShadow(.lg)
            .padding(.leading, narrow ? 56 : 17.6)
            .offset(y: UF.header + 6)
        }
    }

    private func open(_ r: UFRoute) {
        query = ""
        searchFocused = false
        router.go(r)
    }
}
