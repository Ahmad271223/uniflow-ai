import SwiftUI
import UniFlowCore

// App-Rahmen 1:1 nach index.html / app.js: Seitenleiste (Logo, Menue, Einstellungen/Einklappen unten fest),
// Kopfzeile (Menue, Suche, Sync-Status, Sync, Hell/Dunkel, Zeitmesser, Avatar), Inhalt; unter 900 pt Breite
// Schublade + untere Leiste wie im Web (@media max-width: 900px).

// MARK: - Routen (Hash-Routen der Web-App)

enum UFRoute: Hashable {
    case dashboard
    /// Nachrichten aus Stud.IP (04.11.2026): Posteingang auf dem Geraet mit Leser (Views/Messages/MessagesPage.swift)
    case messages
    case plan(view: String? = nil, date: String? = nil, module: String? = nil)
    case timetable(date: String? = nil)
    case modules
    case module(Int)
    /// Studienverlauf (04.11.2026, docs/STUDIENVERLAUF-2026-11-04.md); `module` = Modul-id aus dem Katalog zum Hervorheben
    case studyPlan(module: String? = nil)
    case files(section: String? = nil, path: String? = nil, q: String? = nil)
    case doc(String, task: Int? = nil, page: Int? = nil)
    case exams
    case exam(Int, task: Int? = nil)
    case cards
    /// KI-Start (03.11.2026): Fragen, Karteikarten, Erklären, Wochentest – unter "Tests & Wiederholung"
    case aiStart
    case services
    case community
    /// Seite einer Community (Modul oder Lerngruppe) ueber ihren Schluessel, 03.11.2026: ganze Seite statt Vollbild-Blatt
    case communitySpace(String)
    case settings(tab: String? = nil)
    /// Mensa (05.11.2026, Views/Mensa/MensaViews.swift): Speiseplaene der Studentenwerke, frei in jedem Tarif
    case mensa
    /// Raumfinder (05.11.2026, Views/Rooms/RoomFinderViews.swift): Standortfinder der LUH mit Google-Maps-Link, frei
    case rooms

    /// Menuepunkt, der markiert wird (Dokument -> "Dokumente & Notizen", wie route() in app.js)
    var navKey: String {
        switch self {
        case .dashboard: return "dashboard"
        case .messages: return "messages"
        case .plan: return "plan"
        case .timetable: return "timetable"
        case .modules, .module: return "modules"
        case .studyPlan: return "studyplan"
        case .files, .doc: return "files"
        case .exams, .exam, .cards, .aiStart: return "exams"
        case .services: return "services"
        case .community, .communitySpace: return "community"
        case .settings: return "settings"
        case .mensa: return "mensa"
        case .rooms: return "rooms"
        }
    }

    /// Geoeffnetes Dokument: nicht von aussen neu laden (Notizen fuehrt der Editor beim Sichern zusammen)
    var isDocument: Bool { if case .doc = self { return true }; return false }

    /// Hash-Route der Web-App, z. B. fuer eingebettete Web-Ansichten
    var hash: String {
        func q(_ pairs: [(String, String?)]) -> String {
            let s = pairs.compactMap { k, v in v.map { "\(k)=\($0)" } }.joined(separator: "&")
            return s.isEmpty ? "" : "?" + s
        }
        switch self {
        case .dashboard: return "#/dashboard"
        case .messages: return "#/messages"
        case .plan(let v, let d, let m): return "#/plan" + q([("view", v), ("date", d), ("module", m)])
        case .timetable(let d): return "#/timetable" + q([("date", d)])
        case .modules: return "#/modules"
        case .module(let id): return "#/modules/\(id)"
        case .studyPlan(let m): return "#/studyplan" + q([("module", m)])
        case .files(let s, let p, let qq): return "#/files" + q([("section", s), ("path", p), ("q", qq.map { $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0 })])
        case .doc(let id, let t, let p): return "#/doc/\(id)" + q([("task", t.map { "\($0)" }), ("page", p.map { "\($0)" })])
        case .exams: return "#/exams"
        case .exam(let id, let t): return "#/exams/\(id)" + q([("task", t.map { "\($0)" })])
        case .cards: return "#/cards"
        case .aiStart: return "#/ki"
        case .services: return "#/services"
        case .community: return "#/community"
        case .communitySpace(let key): return "#/community/\(key)"
        case .settings(let t): return "#/settings" + q([("tab", t)])
        case .mensa: return "#/mensa"
        case .rooms: return "#/raumfinder"
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
        case "studyplan", "studienverlauf": self = .studyPlan(module: q["module"])
        case "files": self = .files(section: q["section"], path: q["path"].flatMap { $0.isEmpty ? nil : $0 }, q: q["q"].flatMap { $0.isEmpty ? nil : $0 })
        case "doc": self = second.map { .doc($0, task: q["task"].flatMap(Int.init), page: q["page"].flatMap(Int.init)) } ?? .files()
        case "exams": self = second.flatMap(Int.init).map { .exam($0, task: q["task"].flatMap(Int.init)) } ?? .exams
        case "cards": self = .cards
        case "messages", "nachrichten": self = .messages
        case "ki": self = .aiStart
        case "services": self = .services
        case "community": self = second.map { .communitySpace($0) } ?? .community
        case "settings": self = .settings(tab: q["tab"])
        case "mensa": self = .mensa
        case "raumfinder", "rooms": self = .rooms
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
    /// KI-Start "Erklären": dieses Dokument soll gleich mit offener KI-Hilfe erscheinen (der Editor nimmt die Kennung
    /// beim Laden und leert sie; eine andere Datei laesst sie unberuehrt)
    @Published var tutorOpenRequest: String?
    /// state.route(): aktuelle Ansicht neu laden (nach Aenderungen in Dialogen und Drawern)
    @Published private(set) var reloadToken = 0
    /// Zaehler an den Menuepunkten, Schluessel = `UFRoute.navKey` ("community": neue Korrekturhinweise an eigene
    /// Loesungen, `CommunityBadge`; spaeter z. B. "exams": faellige Karteikarten). 0 oder fehlend = kein Abzeichen.
    @Published private(set) var badges: [String: Int] = [:]
    private var history: [UFRoute] = []
    /// Weitermachen wie zuvor (Services/ResumeState.swift): Stand dieses Fensters mitschreiben und beim Start einmal
    /// wiederherstellen
    let resume = ResumeTracker()

    func reload() { reloadToken += 1 }

    /// Abzeichen eines Menuepunkts setzen (Lieferanten rufen das vom Hauptthread; gleicher Wert loest nichts aus)
    func setBadge(_ count: Int, for navKey: String) {
        let n = max(0, count)
        if (badges[navKey] ?? 0) == n { return }
        if n == 0 { badges.removeValue(forKey: navKey) } else { badges[navKey] = n }
    }

    func badge(for navKey: String) -> Int { badges[navKey] ?? 0 }

    func go(_ r: UFRoute) {
        guard r != route else { return }
        history.append(route)
        if history.count > 50 { history.removeFirst() }
        route = r
        drawerOpen = false
        fullscreenDoc = false            // route() entfernt exam-focus, fullscreen-doc, doc-open
        examFocus = false
        resume.noteRoute(r)
    }

    func go(hash: String) { go(UFRoute(hash: hash)) }

    func back() {
        if let r = history.popLast() { route = r; resume.noteRoute(r) }
    }

    /// Es gibt eine vorige Seite (sonst fuehrt "Zurück" auf die uebergeordnete Seite)
    var canGoBack: Bool { !history.isEmpty }

    /// Der Editor fragt beim Laden: soll die KI-Hilfe fuer diese Datei gleich offen sein? (einmalig)
    func takeTutorOpenRequest(for fileID: String) -> Bool {
        guard tutorOpenRequest == fileID else { return false }
        tutorOpenRequest = nil
        return true
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
        UFNavItem(id: "studyplan", title: "Studienverlauf", icon: "columns", route: .studyPlan()),
        UFNavItem(id: "files", title: "Dokumente & Notizen", icon: "folder", route: .files()),
        UFNavItem(id: "exams", title: "Tests & Wiederholung", icon: "exam", route: .exams),
        UFNavItem(id: "services", title: "Uni & Noten", icon: "graduation", route: .services),
        UFNavItem(id: "mensa", title: "Mensa", icon: "utensils", route: .mensa),
        UFNavItem(id: "rooms", title: "Raumfinder", icon: "map-pin", route: .rooms),
        UFNavItem(id: "community", title: "Community", icon: "users", route: .community),
    ]

    /// Stud.IP-Nachrichten (04.11.2026): direkt nach "Übersicht", nur wenn `visible(messages:)` es erlaubt
    /// (`MessagesInbox.showsNavItem`: iPad mit lokalem Backend und verbundenem Stud.IP oder gespeicherten Nachrichten)
    static let messages = UFNavItem(id: "messages", title: "Nachrichten", icon: "mail", route: .messages)

    /// Eigene Karteikarten ohne PC: Eintrag an Stelle von "Tests & Wiederholung"
    static let cards = UFNavItem(id: "cards", title: "Karteikarten", icon: "cards", route: .cards)

    /// Eintraege der Seitenleiste. Ohne PC (lokales Backend) nur Bereiche mit Funktion (App Review 2.1/2.2): statt
    /// "Tests & Wiederholung" (Wochentests entfallen in V1) "Karteikarten" (`flashcards`: eigene Karten auf dem Geraet,
    /// Plus; ohne Plus zeigt die Seite die Sperrkarte), "Community" nur, wenn der Build einen iCloud-Container hat
    /// (`community`: CloudKit-Dienst verfuegbar; sonst teilt man Loesungen im Editor als Datei und die Einstellungen
    /// sagen ehrlich, warum) und "Uni & Noten" nur, wo der Notenspiegel auf dem Geraet ankommt (`gradesOnDevice`: seit
    /// QIS auf dem Geraet an der LUH wie am LSF der Uni Hildesheim immer).
    /// `ai`: KI ueber das ChatGPT-Abo verbunden; dann gibt es auch ohne PC "Tests & Wiederholung" (Wochentests),
    /// "Karteikarten" bleibt daneben.
    /// `messages`: "Nachrichten" direkt nach "Übersicht" (Stud.IP-Posteingang nur auf dem Geraet; der Aufrufer
    /// entscheidet mit `MessagesInbox.showsNavItem`, am eigenen Server und in Hildesheim ohne Nachrichten nie)
    static func visible(local: Bool, gradesOnDevice: Bool, community: Bool,
                        flashcards: Bool = UFFeatureMatrix.flashcardsOnDevice, ai: Bool = false, messages: Bool = false) -> [UFNavItem] {
        let base: [UFNavItem] = local ? main.flatMap { item -> [UFNavItem] in
            switch item.id {
            case "exams": return (ai ? [item] : []) + (flashcards ? [cards] : [])
            case "community": return community ? [item] : []
            case "services": return gradesOnDevice ? [item] : []
            default: return [item]
            }
        } : main
        guard messages else { return base }
        return base.flatMap { $0.id == "dashboard" ? [$0, Self.messages] : [$0] }
    }

    /// Markiert: "Karteikarten" auf der Karteikarten-Seite, sonst nach `UFRoute.navKey` (am eigenen Server fuehrt
    /// die Karteikarten-Seite weiter unter "Tests & Wiederholung"). Steht "Tests & Wiederholung" nicht im Menue (ohne KI),
    /// markiert `#/exams` die Karteikarten, auf die die Seite dann verweist (Audit 03.11.2026: vorher nichts markiert)
    /// Stehen beide im Menue (iPad mit KI), markiert `#/cards` nur die Karteikarten, nie zusaetzlich "Tests &
    /// Wiederholung" (Rueckmeldung des Inhabers 04.11.2026: beide leuchteten).
    func isActive(_ route: UFRoute, examsShown: Bool = true, cardsShown: Bool = false) -> Bool {
        switch id {
        case "cards": return route == .cards || (!examsShown && route.navKey == "exams")
        case "exams": return route.navKey == "exams" && !(cardsShown && route == .cards)
        default: return route.navKey == id
        }
    }

    /// Markierung in einer Liste sichtbarer Eintraege (Seitenleiste, Schublade, "Mehr")
    static func active(_ item: UFNavItem, in items: [UFNavItem], route: UFRoute) -> Bool {
        item.isActive(route, examsShown: items.contains { $0.id == "exams" }, cardsShown: items.contains { $0.id == "cards" })
    }

    /// Was die Zahl am Menuepunkt bedeutet (VoiceOver): "2 neue Hinweise" an der Community, sonst "2 neu"
    static func badgeText(key: String, count: Int) -> String {
        switch key {
        case "community": return count == 1 ? "1 neuer Hinweis" : "\(count) neue Hinweise"
        case "messages": return count == 1 ? "1 neue Nachricht" : "\(count) neue Nachrichten"
        default: return "\(count) neu"
        }
    }

    /// VoiceOver-Name eines Menuepunkts mit Abzeichen: "Community, 2 neue Hinweise"; ohne Abzeichen nur der Titel
    static func accessibilityLabel(title: String, key: String, badge: Int) -> String {
        badge > 0 ? "\(title), \(badgeText(key: key, count: badge))" : title
    }

    /// Zahl im Abzeichen: ab 100 "99+"
    static func badgeLabel(_ count: Int) -> String { count > 99 ? "99+" : "\(count)" }

    /// untere Leiste (mobileNav in app.js)
    static let mobile: [UFNavItem] = [
        UFNavItem(id: "dashboard", title: "Start", icon: "home", route: .dashboard),
        UFNavItem(id: "plan", title: "Kalender", icon: "calendar", route: .plan()),
        UFNavItem(id: "modules", title: "Module", icon: "book", route: .modules),
        UFNavItem(id: "files", title: "Dokumente", icon: "folder", route: .files()),
        UFNavItem(id: "more", title: "Mehr", icon: "more", route: .settings()),
    ]

    /// Eintrag "Einstellungen" (Fuss der Seitenleiste, Liste "Mehr")
    static let settings = UFNavItem(id: "settings", title: "Einstellungen", icon: "settings", route: .settings())

    /// Liste hinter "Mehr" in der unteren Leiste: alle sichtbaren Bereiche, die dort nicht stehen, dann die
    /// Einstellungen (Audit 03.11.2026: "Mehr" oeffnete nur die Einstellungen; Stundenplan, Karteikarten, Uni & Noten
    /// und Community waren nur ueber das Menue oben erreichbar)
    static func more(visible: [UFNavItem]) -> [UFNavItem] {
        let bar = Set(mobile.map(\.id))
        return visible.filter { !bar.contains($0.id) } + [settings]
    }

    /// Farbpaar der Lern-Eintraege als Kapsel in der Seitenleiste, wie die Knoepfe im KI-Start (Wochentest blau,
    /// Karteikarten Pfirsich/Bernstein); uebrige Eintraege ohne Farbe
    var pill: CommunityPair? {
        switch id {
        case "exams": return CommunityPalette.sky
        case "cards": return CommunityPalette.peach
        default: return nil
        }
    }
}

// MARK: - Gruppen der Seitenleiste

/// Abschnitt der Seitenleiste mit kleiner Ueberschrift in Grossbuchstaben (Neugestaltung 04.11.2026): "STUDIUM",
/// "LERNEN" (Tests & Wiederholung und Karteikarten als farbige Kapseln), "GEMEINSAM". Welche Eintraege es gibt, bleibt
/// Sache von `UFNavItem.visible`; die Gruppen ordnen sie nur. Gruppen ohne sichtbaren Eintrag entfallen.
struct UFNavGroup: Identifiable, Equatable {
    let id: String
    /// Name der Gruppe ("Lernen"); angezeigt in Grossbuchstaben (`label`)
    let title: String
    let items: [UFNavItem]

    var label: String { title.uppercased(with: Locale(identifier: "de_DE")) }
    /// VoiceOver: "Gruppe Lernen"
    var accessibilityLabel: String { "Gruppe \(title)" }

    static func == (a: UFNavGroup, b: UFNavGroup) -> Bool { a.id == b.id && a.items.map(\.id) == b.items.map(\.id) }

    /// Reihenfolge je Gruppe (Schluessel = `UFNavItem.id`); "aiStart" stuende in "Lernen", sobald der KI-Start ein
    /// eigener Menuepunkt wird
    static let layout: [(id: String, title: String, members: [String])] = [
        ("study", "Studium", ["dashboard", "messages", "plan", "timetable", "modules", "studyplan", "files", "services"]),
        ("learn", "Lernen", ["aiStart", "exams", "cards"]),
        // Mensa (05.11.2026): Alltag neben dem Studium, auf jedem Geraet und in jedem Tarif
        // Raumfinder (05.11.2026) neben der Mensa
        ("everyday", "Alltag", ["mensa", "rooms"]),
        ("together", "Gemeinsam", ["community"]),
    ]

    /// Sichtbare Eintraege auf die Gruppen verteilen; ein unbekannter Eintrag landet am Ende von "Studium" (nie
    /// verloren), leere Gruppen fallen weg
    static func groups(_ visible: [UFNavItem]) -> [UFNavGroup] {
        let known = Set(layout.flatMap(\.members))
        let stray = visible.filter { !known.contains($0.id) }
        return layout.compactMap { g in
            var items = g.members.compactMap { id in visible.first { $0.id == id } }
            if g.id == "study" { items += stray }
            return items.isEmpty ? nil : UFNavGroup(id: g.id, title: g.title, items: items)
        }
    }
}

// MARK: - Fuss der Seitenleiste: Profil und Tarif

/// Profil unten in der Seitenleiste: Initialen, Name wie in der Begruessung, Tarif und ein kleiner Knopf zum
/// naechsthoeheren Tarif. Reine Funktionen (DesignShellAppTests).
struct UFSidebarProfile: Equatable {
    /// "Free", "Plus", "Pro AI" oder "Probe · noch 5 Tage"
    let planLabel: String
    /// VoiceOver: "Tarif Free" bzw. "Probe, noch 5 Tage"
    let planAccessibility: String
    /// naechsthoeherer Tarif fuer den Knopf; nil auf dem hoechsten Tarif
    let upgrade: UFPlan?

    /// "Plus holen" / "Pro AI holen"
    var upgradeTitle: String? { upgrade.map { "\(Self.short($0)) holen" } }

    static func short(_ p: UFPlan) -> String {
        switch p {
        case .free: return "Free"
        case .plus: return "Plus"
        case .proAI: return "Pro AI"
        }
    }

    /// `plan`: wirksamer Tarif, `purchased`: gekaufter Tarif, `trialDaysLeft`: laufende Probe auf dem iPad (nil = keine).
    /// Die Probe zaehlt nur ohne Kauf (wie `Entitlements.statusLabel`); danach geht es zu Plus, weil die Probe endet.
    static func make(plan: UFPlan, purchased: UFPlan, trialDaysLeft: Int?) -> UFSidebarProfile {
        if let d = trialDaysLeft, d > 0, purchased == .free {
            let days = d == 1 ? "1 Tag" : "\(d) Tage"
            return UFSidebarProfile(planLabel: "Probe · noch \(days)", planAccessibility: "Probe, noch \(days)", upgrade: .plus)
        }
        let next: UFPlan? = plan == .free ? .plus : plan == .plus ? .proAI : nil
        return UFSidebarProfile(planLabel: short(plan), planAccessibility: "Tarif \(short(plan))", upgrade: next)
    }

    @MainActor
    static func make(_ ent: Entitlements) -> UFSidebarProfile {
        make(plan: ent.plan, purchased: ent.purchasedPlan, trialDaysLeft: ent.localTrial.flatMap { $0.isActive ? $0.daysLeft : nil })
    }

    /// Initialen fuer den Avatar: wie die Kopfzeile (Server, sonst Apple-Name), sonst aus dem Namen der Begruessung
    static func initials(server: String, appleName: String?, greetingName: String?) -> String {
        if !server.isEmpty { return server }
        let apple = ShellState.initials(of: appleName)
        return apple.isEmpty ? ShellState.initials(of: greetingName) : apple
    }
}

extension UFGreeting {
    /// Name der Begruessung fuer das angemeldete Konto (Uebersicht und Seitenleiste): Reihenfolge von `pick`; das
    /// StudiNow-Konto hat in V1 keinen Anzeigenamen
    static func name(for a: AccountStore.Account?) -> String? {
        pick(rufname: Rufname.current(), accountName: nil, appleGivenName: a?.givenName, appleFullName: a?.name)
    }
}

// MARK: - Rahmen

struct AppShell<Content: View>: View {
    @EnvironmentObject private var router: UFRouter
    @EnvironmentObject private var overlay: UFOverlay
    @EnvironmentObject private var session: Session
    @Environment(\.ufAIEnabled) private var aiEnabled
    @EnvironmentObject private var studip: StudIPSync
    /// Demo-Inhalte aktiv (nur App-Pruefung): schmale Leiste mit "Beenden" ueber jeder Seite; in den Store-Bildern aus
    @Environment(\.ufDemoActive) private var demoActive
    @Environment(\.ufDemoBarHidden) private var demoBarHidden
    /// Stud.IP-Nachrichten: ob der Eintrag erscheint (`MessagesInbox.showsNavItem`)
    @ObservedObject private var inbox = MessagesInbox.shared
    @AppStorage("sidebar") private var sidebarMode = "full"          // localStorage "sidebar": "min" | "full"
    @ViewBuilder let content: (UFRoute) -> Content

    /// Nur Debug-Builds: -UFCanvas 1194x834 legt die Oberflaeche in dieser Groesse an und verkleinert sie auf den
    /// Bildschirm - Bildvergleiche im Querformat, weil der Simulator per simctl nicht dreht und iPadOS das Drehen per
    /// Programm im Fenstermodus ablehnt
    static var debugCanvas: CGSize? {
        #if DEBUG
        guard let v = UserDefaults.standard.string(forKey: "UFCanvas") else { return nil }
        let p = v.lowercased().split(separator: "x").compactMap { Double($0) }
        return p.count == 2 ? CGSize(width: p[0], height: p[1]) : nil
        #else
        return nil
        #endif
    }

    var body: some View {
        if let c = Self.debugCanvas {
            GeometryReader { outer in
                shell.frame(width: c.width, height: c.height)
                    .scaleEffect(min(outer.size.width / c.width, outer.size.height / c.height), anchor: .topLeading)
            }
        } else {
            shell
        }
    }

    private var shell: some View {
        GeometryReader { geo in
            let narrow = geo.size.width <= 900
            let docOpen: Bool = { if case .doc = router.route { return true }; return false }()
            let hideChrome = router.fullscreenDoc || router.examFocus
            let showsSidebar = !narrow && !hideChrome && !docOpen
            let sidebarWidth = sidebarMode == "min" ? UF.sidebarMin : UF.sidebar
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    // im Editor keine Leiste: das Logo in seiner Werkzeugleiste fuehrt zu den Bereichen (`UFLogoMenu`)
                    if showsSidebar {
                        UFSidebar(collapsed: sidebarMode == "min", allowCollapse: true)
                            .frame(width: sidebarWidth)
                            .transition(.move(edge: .leading))
                    }
                    VStack(spacing: 0) {
                        if !hideChrome && !docOpen { UFHeader(narrow: narrow) }          // doc-open: Kopfzeile aus
                        if demoActive && !demoBarHidden && !session.isOwnServer && !hideChrome && !docOpen { DemoActiveBar() }
                        // Die Seite bekommt genau die Breite neben der Leiste: eine zu breite Seite schob sonst Kopfzeile,
                        // Demo-Leiste und alles darunter ueber den rechten Rand (Breiten-Audit 04.11.2026, Einstellungen
                        // im iPad (A16) quer); LayoutWidthAuditTests prueft, dass keine Seite breiter wird
                        content(router.route)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .frame(width: max(0, geo.size.width - (showsSidebar ? sidebarWidth : 0)), alignment: .leading)
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
            .environment(\.ufLogoMenu, UFLogoMenuTargets(
                items: UFNavItem.visible(local: session.api?.isLocal ?? true, gradesOnDevice: true,
                                         community: SolutionSharing.community.isConnected, ai: aiEnabled,
                                         messages: inbox.showsNavItem(api: session.api, studip: studip)).map { ($0.title, $0.route) },
                go: { [router] r in router.go(r) }))
        }
    }
}

/// StudiNow-Logo in der Werkzeugleiste des Editors (dort ist die App-Leiste aus): Menue mit denselben Bereichen wie
/// die Leiste und den Einstellungen. Die Ziele setzt `AppShell` (`\.ufLogoMenu`); ohne sie (Editor ausserhalb der App-
/// Huelle, z. B. alte Fassung, Tests) erscheint nichts.
struct UFLogoMenu: View {
    @Environment(\.ufLogoMenu) private var menu

    var body: some View {
        if let menu {
            // Tipp: zurueck zur Uebersicht (Wunsch des Inhabers: aus dem Dokument immer wieder nach StudiNow); gedrueckt
            // halten: alle Bereiche
            Button { menu.go(.dashboard) } label: {
                RoundedRectangle(cornerRadius: 8).fill(UF.logoGradient)
                    .frame(width: 28, height: 28)
                    .overlay(UFIcon("graduation", size: 16).foregroundStyle(.white))
                    .ufHitArea()                                            // 28 pt sichtbar, 44 pt antippbar
            }
            .buttonStyle(.plain)
            .contextMenu {
                ForEach(menu.items, id: \.title) { item in Button(item.title) { menu.go(item.route) } }
                Divider()
                Button("Einstellungen") { menu.go(.settings()) }
            }
            .accessibilityLabel("Zur Übersicht")
            .accessibilityHint("Gedrückt halten für alle Bereiche")
            .accessibilityIdentifier("doc.logoMenu")
        }
    }
}

struct UFLogoMenuTargets {
    var items: [(title: String, route: UFRoute)]
    var go: (UFRoute) -> Void
}

private struct UFLogoMenuKey: EnvironmentKey { static let defaultValue: UFLogoMenuTargets? = nil }

extension EnvironmentValues {
    var ufLogoMenu: UFLogoMenuTargets? {
        get { self[UFLogoMenuKey.self] }
        set { self[UFLogoMenuKey.self] = newValue }
    }
}

/// Seitenleiste (Neugestaltung 04.11.2026): Logo, Gruppen mit kleinen Ueberschriften ("STUDIUM", "LERNEN",
/// "GEMEINSAM", `UFNavGroup`), die Lern-Eintraege als farbige Kapseln (aktiv gefuellt, sonst umrandet), unten fest das
/// Profil mit Initialen, Namen der Begruessung, Tarif und "Plus holen" bzw. "Pro AI holen", dann Einstellungen und
/// Einklappen. Eingeklappt nur Symbole (unten nur der Avatar). Welche Eintraege erscheinen und welcher markiert ist,
/// bleibt bei `UFNavItem.visible` und `UFNavItem.active`.
struct UFSidebar: View {
    @EnvironmentObject private var router: UFRouter
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var shell: ShellState
    @EnvironmentObject private var account: AccountStore
    @Environment(\.ufAIEnabled) private var aiEnabled
    @Environment(\.ufShowPlans) private var showPlans
    @EnvironmentObject private var studip: StudIPSync
    @ObservedObject private var ent = Entitlements.shared
    @ObservedObject private var inbox = MessagesInbox.shared
    @AppStorage("sidebar") private var sidebarMode = "full"
    let collapsed: Bool
    let allowCollapse: Bool

    var body: some View {
        // Noten auf dem Geraet wie bei UFServerGate (`Spec.services.localWithOtherSources`): an beiden Hochschulen
        // (QIS an der LUH, LSF in Hildesheim); Community nur mit CloudKit-Dienst des aktiven Containers
        let items = UFNavItem.visible(local: session.api?.isLocal ?? true, gradesOnDevice: true,
                                      community: SolutionSharing.community.isConnected, ai: aiEnabled,
                                      messages: inbox.showsNavItem(api: session.api, studip: studip))
        let groups = UFNavGroup.groups(items)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 9.6) {                                       // .brand
                RoundedRectangle(cornerRadius: 9).fill(UF.logoGradient)
                    .frame(width: 30, height: 30)
                    .overlay(UFIcon("graduation", size: 18).foregroundStyle(.white))
                if !collapsed { Text("StudiNow").font(.uf(16.32, 700)).foregroundStyle(UF.text).lineLimit(1) }
            }
            .padding(EdgeInsets(top: 5.6, leading: 8, bottom: 16, trailing: 8))
            .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("StudiNow")

            ScrollView(showsIndicators: false) {                         // .nav scrollt selbst, Fuss bleibt fest
                VStack(alignment: .leading, spacing: collapsed ? 8 : 14) {
                    ForEach(groups) { g in
                        VStack(alignment: .leading, spacing: g.id == "learn" ? 6 : 2) {
                            if collapsed {
                                // eingeklappt: kurze Haarlinie statt Ueberschrift zwischen den Gruppen
                                if g.id != groups.first?.id {
                                    Rectangle().fill(UF.line).frame(width: 24, height: 1)
                                        .frame(maxWidth: .infinity).padding(.bottom, 6)
                                        .accessibilityHidden(true)
                                }
                            } else {
                                Text(g.label)
                                    .ufFont(11.2, 650, lh: 1.2, em: 0.08)
                                    .foregroundStyle(UF.muted)
                                    .lineLimit(1)
                                    .padding(.horizontal, 11.2)
                                    .padding(.bottom, 4)
                                    .accessibilityLabel(g.title)
                                    .accessibilityAddTraits(.isHeader)
                            }
                            ForEach(g.items) { item in
                                let active = UFNavItem.active(item, in: items, route: router.route)
                                if let pair = item.pill {
                                    pillRow(item, pair: pair, active: active, badge: router.badge(for: item.id))
                                } else {
                                    navRow(item.title, icon: item.icon, active: active, key: item.id,
                                           badge: router.badge(for: item.id)) { router.go(item.route) }
                                }
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(g.accessibilityLabel)
                        .accessibilityIdentifier("sidebar.group.\(g.id)")
                    }
                }
                .padding(.bottom, 8)
            }
            VStack(spacing: 4) {                                         // .side-foot
                profile.padding(.bottom, 4)
                navRow("Einstellungen", icon: "settings", active: router.route.navKey == "settings") { router.go(.settings()) }
                if allowCollapse {
                    navRow("Einklappen", icon: "panel-left", active: false) { sidebarMode = sidebarMode == "min" ? "full" : "min" }
                }
            }
            .padding(.top, 9.6)
            .overlay(alignment: .top) { Rectangle().fill(UF.line).frame(height: 1) }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 9.6)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(UF.surface)
        .overlay(alignment: .trailing) { Rectangle().fill(UF.line).frame(width: 1) }
    }

    // MARK: Profil

    /// Name wie die Begruessung der Uebersicht (`UFGreeting.name`)
    private var name: String? { UFGreeting.name(for: account.account) }

    private var initials: String {
        UFSidebarProfile.initials(server: shell.initials, appleName: account.account?.name, greetingName: name)
    }

    private var avatar: some View {
        let ini = initials
        return Group {
            if ini.isEmpty { UFIcon("user", size: 16) } else { Text(ini).font(.uf(12.48, 700)) }
        }
        .foregroundStyle(UF.accentText)
        .frame(width: 34, height: 34)
        .background(Circle().fill(UF.accentSoft))
        .overlay(Circle().strokeBorder(UF.accent.opacity(0.35), lineWidth: 1))
    }

    @ViewBuilder private var profile: some View {
        let p = UFSidebarProfile.make(ent)
        let shownName = name ?? "Dein Konto"
        let openAccount = { router.go(.settings(tab: "account")) }
        if collapsed {
            Button(action: openAccount) { avatar.frame(maxWidth: .infinity).ufHitArea() }
                .buttonStyle(.plain)
                .accessibilityLabel("\(shownName), \(p.planAccessibility)")
                .accessibilityHint("Öffnet dein Konto")
                .accessibilityIdentifier("sidebar.profile")
                .help("\(shownName) · \(p.planLabel)")
        } else {
            let info = Button(action: openAccount) {
                HStack(spacing: 9.6) {
                    avatar
                    VStack(alignment: .leading, spacing: 0) {
                        Text(shownName).ufFont(13.6, 650, lh: 1.25).foregroundStyle(UF.text).lineLimit(1)
                        Text(p.planLabel).ufFont(11.84, 500, lh: 1.25).foregroundStyle(UF.muted).lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(shownName), \(p.planAccessibility)")
            .accessibilityHint("Öffnet dein Konto")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("sidebar.profile")
            VStack(alignment: .leading, spacing: 8) {
                info
                if let title = p.upgradeTitle { upgradeButton(title) }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.surface2))
            .overlay(RoundedRectangle(cornerRadius: UF.r).strokeBorder(UF.line, lineWidth: 1))
        }
    }

    /// "Plus holen →": oeffnet die Tarife (Einstellungen -> Tarif, oder die vom Rahmen gesetzte Tarifwahl)
    private func upgradeButton(_ title: String) -> some View {
        Button {
            if let showPlans { showPlans() } else { router.go(.settings(tab: "plan")) }
        } label: {
            HStack(spacing: 6) {
                Text(title).ufFont(12.8, 650, lh: 1.2).lineLimit(1)
                UFIcon("arrow-right", size: 13)
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(Capsule().fill(UF.accentFill))
            .contentShape(Capsule())
        }
        .buttonStyle(UFPressStyle())
        .accessibilityLabel(title)
        .accessibilityHint("Öffnet die Tarife")
        .accessibilityIdentifier("sidebar.upgrade")
    }

    // MARK: Eintraege

    /// Lern-Eintrag als Kapsel in seiner Farbe (wie die Knoepfe im KI-Start): aktiv gefuellt, sonst nur umrandet
    private func pillRow(_ item: UFNavItem, pair: CommunityPair, active: Bool, badge: Int) -> some View {
        Button { router.go(item.route) } label: {
            HStack(spacing: 9.6) {
                UFIcon(item.icon, size: 17)
                    .foregroundStyle(pair.fg)
                    .overlay(alignment: .topTrailing) {
                        if collapsed, badge > 0 { UFNavBadge(count: badge, compact: true).offset(x: 9, y: -7) }
                    }
                if !collapsed {
                    Text(item.title).ufFont(14.08, active ? 650 : 550, lh: 1.25)
                        .foregroundStyle(active ? pair.fg : UF.text)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    if badge > 0 {
                        Spacer(minLength: 6)
                        UFNavBadge(count: badge)
                    }
                }
            }
            // eingeklappt ein Kreis um das Symbol, sonst eine Kapsel ueber die ganze Breite
            .padding(.vertical, collapsed ? 0 : 8)
            .padding(.horizontal, collapsed ? 0 : 12)
            .frame(maxWidth: collapsed ? 42 : .infinity, minHeight: collapsed ? 42 : 40, alignment: collapsed ? .center : .leading)
            .background(Capsule().fill(active ? pair.bg : Color.clear))
            .overlay(Capsule().strokeBorder(active ? pair.solid : Color.mix(pair.solid, 0.55, UF.surface), lineWidth: 1.5))
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(UFNavItem.accessibilityLabel(title: item.title, key: item.id, badge: badge))
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityIdentifier("nav.\(item.id)")
        .help(UFNavItem.accessibilityLabel(title: item.title, key: item.id, badge: badge))
    }

    /// Eintrag der Leiste; `badge` > 0 zeigt die Zahl rechts (eingeklappt: klein am Symbol) und nennt sie VoiceOver
    private func navRow(_ title: String, icon: String, active: Bool, key: String = "", badge: Int = 0,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10.4) {
                UFIcon(icon, size: 18)
                    .overlay(alignment: .topTrailing) {
                        if collapsed, badge > 0 { UFNavBadge(count: badge, compact: true).offset(x: 9, y: -7) }
                    }
                if !collapsed {
                    Text(title).ufFont(14.5, active ? 600 : 500, lh: 1.25)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    if badge > 0 {
                        Spacer(minLength: 6)
                        UFNavBadge(count: badge)
                    }
                }
            }
            .foregroundStyle(active ? UF.accentText : UF.text2)
            .padding(.vertical, collapsed ? 9.6 : 8.8)
            .padding(.horizontal, collapsed ? 9.6 : 11.2)
            .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
            .background(RoundedRectangle(cornerRadius: UF.rSm).fill(active ? UF.accentSoft : .clear))
            .contentShape(RoundedRectangle(cornerRadius: UF.rSm))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(UFNavItem.accessibilityLabel(title: title, key: key, badge: badge))
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityIdentifier("nav.\(key.isEmpty ? title : key)")
        .help(UFNavItem.accessibilityLabel(title: title, key: key, badge: badge))
    }
}

/// Zahl am Menuepunkt (Seitenleiste, Schublade, untere Leiste): Kapsel in der Akzentflaeche mit weisser Schrift,
/// mindestens 18 pt (klein 16 pt am Symbol), Schrift folgt Dynamic Type. Erscheint und wechselt mit einer kurzen
/// Ueberblendung; bei "Bewegung reduzieren" und unter XCTest ohne Bewegung (`UFMotion`). Nur Anzeige: den Namen fuer
/// VoiceOver traegt der Menuepunkt (`UFNavItem.accessibilityLabel`).
struct UFNavBadge: View {
    let count: Int
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        Text(UFNavItem.badgeLabel(count))
            .ufFont(compact ? 9.6 : 11.2, 700, lh: 1)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()                                                 // "12" und "99+" nie zu "…" gekuerzt
            .foregroundStyle(Color.white)
            .padding(.horizontal, compact ? 4 : 6)
            .frame(minWidth: compact ? 16 : 18, minHeight: compact ? 16 : 18)
            .background(Capsule().fill(UF.accentFill))
            .overlay(Capsule().strokeBorder(UF.surface, lineWidth: compact ? 1.5 : 0))
            .contentTransition(reduce ? .opacity : .numericText())
            .animation(UFMotion.animation(reduce: reduce), value: count)
            .transition(.opacity)
            .accessibilityHidden(true)
    }
}

/// .mobile-nav: fuenf gleich breite Eintraege, aktiv mit --accent-soft; Abzeichen klein am Symbol. "Mehr" oeffnet die
/// Liste der uebrigen Bereiche (`UFMoreSheet`) mit ihren Abzeichen; markiert, wenn einer davon offen ist.
struct UFMobileNav: View {
    @EnvironmentObject private var router: UFRouter
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var studip: StudIPSync
    @Environment(\.ufAIEnabled) private var aiEnabled
    @ObservedObject private var inbox = MessagesInbox.shared
    @State private var showMore = false

    private var moreItems: [UFNavItem] {
        let visible = UFNavItem.visible(local: session.api?.isLocal ?? true, gradesOnDevice: true,
                                        community: SolutionSharing.community.isConnected, ai: aiEnabled,
                                        messages: inbox.showsNavItem(api: session.api, studip: studip))
        return UFNavItem.more(visible: visible)
    }

    /// "Mehr" markiert, wenn einer seiner Bereiche offen ist (reine Funktion, AuditApp20261103Tests)
    static func moreActive(_ route: UFRoute, items: [UFNavItem]) -> Bool {
        items.contains { UFNavItem.active($0, in: items + UFNavItem.mobile, route: route) }
    }

    /// Zahl an "Mehr": Summe der Abzeichen seiner Bereiche
    static func moreBadge(_ badges: [String: Int], items: [UFNavItem]) -> Int {
        items.reduce(0) { $0 + (badges[$1.id] ?? 0) }
    }

    /// Abzeichen von Bereichen, die nicht in der unteren Leiste stehen (z. B. Community): Summe am Menueknopf der
    /// Kopfzeile, der die Schublade mit allen Bereichen oeffnet
    static func drawerBadge(_ badges: [String: Int]) -> Int {
        let shown = Set(UFNavItem.mobile.map(\.id))
        return badges.filter { !shown.contains($0.key) }.values.reduce(0, +)
    }

    var body: some View {
        let more = moreItems
        HStack(spacing: 0) {
            ForEach(UFNavItem.mobile) { item in
                let isMore = item.id == "more"
                let active = isMore ? Self.moreActive(router.route, items: more) : router.route.navKey == item.id
                let badge = isMore ? Self.moreBadge(router.badges, items: more) : router.badge(for: item.id)
                Button { if isMore { showMore = true } else { router.go(item.route) } } label: {
                    VStack(spacing: 1.6) {
                        UFIcon(item.icon, size: 20)
                            .overlay(alignment: .topTrailing) {
                                if badge > 0 { UFNavBadge(count: badge, compact: true).offset(x: 9, y: -6) }
                            }
                        Text(item.title).font(.uf(10.56))
                    }
                    .foregroundStyle(active ? UF.accentText : UF.muted)
                    .padding(4)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 6).fill(active ? UF.accentSoft : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(UFNavItem.accessibilityLabel(title: item.title, key: item.id, badge: badge))
                .accessibilityHint(isMore ? "Weitere Bereiche und Einstellungen" : "")
                .accessibilityIdentifier("mobileNav.\(item.id)")
                .popover(isPresented: isMore ? $showMore : .constant(false), arrowEdge: .bottom) {
                    UFMoreSheet(items: more) { r in
                        showMore = false
                        router.go(r)
                    }
                    .presentationCompactAdaptation(.sheet)
                    .presentationDetents([.medium, .large])
                }
            }
        }
        .padding(.horizontal, 3.2)
        .padding(.top, 4.8)
        .padding(.bottom, 4.8)
        .background(UF.surface.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(UF.line).frame(height: 1) }
        .task {
            #if DEBUG
            // Bildvergleich: -UFShowMore YES oeffnet die Liste "Mehr" beim Start
            if UserDefaults.standard.bool(forKey: "UFShowMore") {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                showMore = true
            }
            #endif
        }
    }
}

/// Liste hinter "Mehr": je Bereich Symbol, Name, Abzeichen und Pfeil, mindestens 44 pt hoch, der offene Bereich markiert
struct UFMoreSheet: View {
    let items: [UFNavItem]
    let go: (UFRoute) -> Void
    @EnvironmentObject private var router: UFRouter

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Mehr").ufFont(17.6, 650, em: -0.01).foregroundStyle(UF.text)
                .padding(.horizontal, 11.2).padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
            ForEach(items) { item in
                let active = UFNavItem.active(item, in: items + UFNavItem.mobile, route: router.route)
                let badge = router.badge(for: item.id)
                Button { go(item.route) } label: {
                    HStack(spacing: 10.4) {
                        UFIcon(item.icon, size: 18)
                        Text(item.title).ufFont(14.5, 500).frame(maxWidth: .infinity, alignment: .leading)
                        if badge > 0 { UFNavBadge(count: badge) }
                        UFIcon("chevron-right", size: 14).foregroundStyle(UF.muted)
                    }
                    .foregroundStyle(active ? UF.accentText : UF.text)
                    .padding(.horizontal, 11.2)
                    .frame(minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: UF.rSm).fill(active ? UF.accentSoft : .clear))
                    .contentShape(RoundedRectangle(cornerRadius: UF.rSm))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(UFNavItem.accessibilityLabel(title: item.title, key: item.id, badge: badge))
                .accessibilityAddTraits(active ? .isSelected : [])
                .accessibilityIdentifier("more.\(item.id)")
            }
        }
        .padding(16)
        .frame(minWidth: 300, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(UF.surface)
    }
}

// MARK: - Kopfzeile

/// Erscheinungsbild wie setTheme() in app.js: "light", "dark", "auto"
enum UFThemeMode: String {
    case light, dark, auto

    /// Vorgabe, solange der Nutzer nichts gewaehlt hat: wie das iPad (Audit 03.11.2026; vorher "light", die App folgte
    /// dem Dunkelmodus des Systems nicht). @AppStorage schreibt die Vorgabe nie, darum gilt sie fuer alle, die nie
    /// gewaehlt haben, ohne Umzug; eine gewaehlte Einstellung (auch "light") bleibt.
    static let standard: UFThemeMode = .auto
    /// Wert in @AppStorage("theme"), solange nichts gewaehlt ist
    static var standardRaw: String { standard.rawValue }

    var scheme: ColorScheme? { self == .light ? .light : self == .dark ? .dark : nil }
    /// Reihenfolge des Knopfs: dunkel -> hell -> automatisch -> dunkel
    var next: UFThemeMode { self == .dark ? .light : self == .light ? .auto : .dark }
    var label: String { self == .dark ? "Dunkel" : self == .light ? "Hell" : "wie iPad" }
}

struct UFHeader: View {
    /// Sync-Knopf: Abgleich des eigenen Servers, sonst Stud.IP bzw. Learnweb und LSF direkt auf dem iPad oder der Weg
    /// zur Anmeldung
    private func sync() {
        if session.isOwnServer { Task { await shell.startSync(toast: toast) }; return }
        // Demo-Inhalte: kein Abgleich mit der Hochschule, nur der Hinweis auf "Beenden" in der Leiste darunter
        if demo {
            toast.show(DemoTexts.syncBlocked, seconds: 4)
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
    @AppStorage("theme") private var theme = UFThemeMode.standardRaw
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 9.6) {
            if narrow {
                // Schublade mit allen Bereichen; Abzeichen der Bereiche, die nicht in der unteren Leiste stehen
                let drawerBadge = UFMobileNav.drawerBadge(router.badges)
                UFButton(icon: "menu", kind: .ghost) { router.drawerOpen.toggle() }
                    .overlay(alignment: .topTrailing) {
                        if drawerBadge > 0 { UFNavBadge(count: drawerBadge, compact: true).offset(x: 2, y: -2) }
                    }
                    .accessibilityLabel(drawerBadge > 0 ? "Menü, \(UFNavItem.badgeText(key: "", count: drawerBadge))" : "Menü")
                    .accessibilityIdentifier("header.menu")
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
                let next = (UFThemeMode(rawValue: theme) ?? .standard).next
                theme = next.rawValue
                toast.show("Design: \(next.label)")
            }
            if !narrow && StudyTimer.isEnabled {
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
