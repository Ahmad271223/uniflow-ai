import SwiftUI
import UniFlowCore

// V1 ohne PC-Server (docs/AUFTRAG-APPSTORE-V1.md, Abschnitt 2a): Die Seiten laden vom lokalen Backend des iPads
// (dieselben /api/-Pfade wie der PC-Server, docs/IPAD-OHNE-PC.md) und zeigen ihre echten, anfangs leeren Zustaende.
// Solange Stud.IP nicht verbunden ist, steht die Karte "Stud.IP verbinden" oberhalb der Seite, danach die
// Statusleiste mit dem Abgleichstand (laufend, Fehler mit "Erneut versuchen"). An der Universitaet Hildesheim stehen
// dort stattdessen die Karten "Learnweb verbinden"/"LSF verbinden" und danach die Statusleiste mit dem Stand je
// Quelle (HildesheimSourcesBar, Views/HildesheimViews.swift). Die abgeglichenen Dateien stehen seit S3
// in den Seiten selbst (Dokumente, Uebersicht, Editor) – keine Beispieldaten, keine Hinweise auf PC oder PIN. Mit
// eigenem Server (Entwicklungsmodus des Inhabers) laden die Seiten wie bisher.
// Die Entscheidung trifft nur UFDataMode.current (Weiche fuer alle Seiten), UFGatePresentation.resolve (Leiste
// oberhalb oder leerer Zustand) und UFNoServerContent.resolve (Abgleichstand, Text des leeren Zustands); alle sind
// reine Funktionen mit Unit-Tests (NoServerStateTests, LocalBackendAppTests). Eine Datenquelle gibt es immer:
// `Session.api` ist das lokale Backend oder (nur Entwicklung) der eigene Server.

/// Stand der Stud.IP-Verbindung aus Sicht der Oberflaeche.
enum StudIPLink: Equatable {
    case notConnected
    /// Sitzung abgelaufen: erneut anmelden
    case expired
    /// angemeldet; auch waehrend eines Abgleichs und nach einem Abgleichfehler (z. B. offline)
    case connected
    /// die gewaehlte Hochschule hat statt Stud.IP eigene Quellen (Universitaet Hildesheim: Learnweb und LSF):
    /// keine Karte "Stud.IP verbinden", sondern deren Karten bzw. Stand (`HildesheimSourcesBar`)
    case otherSources
    /// Demo-Inhalte aktiv (`DemoContent`): keine Anmeldung, keine Karten "… verbinden", kein Abgleich; die App-Huelle
    /// zeigt die Demo-Leiste mit "Beenden" (`DemoActiveBar`)
    case demo

    /// `hasSession`: liegt ein Sitzungs-Cookie im Schluesselbund? Nur bei `.failed` gefragt – scheitert schon das
    /// Speichern nach der Anmeldung (StudIPSync.signedIn), ist Stud.IP nicht verbunden, obwohl die Phase `.failed` ist.
    init(_ phase: StudIPSync.Phase, hasSession: @autoclosure () -> Bool) {
        switch phase {
        case .signedOut: self = .notConnected
        case .needsLogin: self = .expired
        case .idle, .running: self = .connected
        case .failed: self = hasSession() ? .connected : .notConnected
        }
    }
}

/// Welchen Zustand eine Seite zeigt.
enum UFDataMode: Equatable {
    /// eigener UniFlow-Server verbunden: Seite laedt wie bisher
    case server
    /// lokales Backend des iPads (Normalfall): Seite laedt wie mit Server; solange Stud.IP nicht verbunden bzw.
    /// abgelaufen ist, steht die Karte "Stud.IP verbinden" oberhalb der Seite
    case local(StudIPLink)

    /// Eigener Server nur, wenn `api` einer ist; sonst das lokale Backend (`Session.api` ist nie nil, vorher gab es
    /// dafuer drei unerreichbare Zustaende "ohne Datenquelle")
    static func resolve(api: APIClient?, studIP: StudIPLink) -> UFDataMode {
        api?.isLocal == false ? .server : .local(studIP)
    }

    /// Die eine Weiche fuer alle Seiten (UFServerGate, Uebersicht, UFRemote, Community): Datenquelle aus der Sitzung,
    /// Stud.IP aus dem Abgleich des offenen Containers. Den Schluesselbund liest sie nur bei einem Abgleichfehler.
    /// An einer Hochschule ohne Stud.IP gibt es keine Karte "Stud.IP verbinden" (dort Learnweb und LSF). Mit
    /// Demo-Inhalten (`demo`, `ContainerManager.demoActive` ueber `\.ufDemoActive`) gibt es keine Karte zum Verbinden.
    @MainActor static func current(api: APIClient?, studip: StudIPSync, demo: Bool = false) -> UFDataMode {
        if demo { return resolve(api: api, studIP: .demo) }
        guard studip.offersStudIP else { return resolve(api: api, studIP: .otherSources) }
        return resolve(api: api, studIP: StudIPLink(studip.phase, hasSession: studip.hasStoredSession))
    }

    /// Karte der Hochschul-Quellen oberhalb der Seite zeigen (`ConnectStudIPCard`): "Stud.IP verbinden" bzw.
    /// "Erneut anmelden"; an Hochschulen mit eigenen Quellen immer (Karten "Learnweb/LSF verbinden" oder ihr Stand)
    var showsConnectCard: Bool {
        switch self {
        case .local(let link): return link != .connected && link != .demo
        case .server: return false
        }
    }

    /// Demo-Inhalte aktiv (lokal)
    var isDemo: Bool { self == .local(.demo) }

    /// Hochschule mit eigenen Quellen statt Stud.IP (Uni Hildesheim)
    var hasOtherSources: Bool { self == .local(.otherSources) }

    /// Karte mit "Erneut anmelden" statt "Stud.IP verbinden"
    var studIPExpired: Bool { self == .local(.expired) }

    /// Ohne PC: lokales Backend (Texte ohne Hinweis auf den PC)
    var isOnDevice: Bool { self != .server }
}

/// Abgleichstand oberhalb einer lokalen Seite und was der leere Zustand einer Seite zeigt, die es in V1 nicht gibt
/// (Wochentests).
struct UFNoServerContent: Equatable {
    enum Status: Equatable {
        /// erster oder laufender Abgleich (Fortschrittstext aus StudIPSync)
        case syncing(String)
        /// Abgleich fehlgeschlagen (z. B. offline): Meldung mit "Erneut versuchen"
        case failed(String)
    }

    let showsConnectCard: Bool
    let status: Status?
    let text: String
    /// Funktion braucht eine spaetere Version: als "bald" kennzeichnen (seit QIS auf dem Geraet keine mehr)
    let soon: Bool

    /// Statusleiste oberhalb einer lokalen Seite zeigen: Abgleich laeuft oder ist fehlgeschlagen
    var showsStatusBar: Bool { status != nil }

    static func resolve(kind: UFNoServerPage.Kind, mode: UFDataMode, phase: StudIPSync.Phase) -> UFNoServerContent {
        // die abgeglichenen Dateien zeigen die Seiten seit S3 selbst; hier nur der Abgleichstand bei verbundenem Stud.IP
        var status: Status?
        if mode == .local(.connected) {
            switch phase {
            case .running(let step): status = .syncing(step)
            case .failed(let message): status = .failed(message)
            case .signedOut, .needsLogin, .idle: status = nil
            }
        }
        return UFNoServerContent(showsConnectCard: mode.showsConnectCard, status: status, text: text(kind), soon: false)
    }

    /// Tests ohne KI: was sie brauchen (verbundenes ChatGPT) und der Weg zu den Karteikarten - kein Versprechen, dass es
    /// Tests schon gibt, kein "bald"
    static var examsText: String {
        ChatGPTLink.isEnabled ? "Tests gibt es nur mit verbundenem ChatGPT. Ohne ChatGPT wiederholst du mit deinen eigenen Karteikarten."
                              : "Tests gibt es mit der StudiNow-KI in StudiNow Pro AI. Bis dahin wiederholst du mit deinen eigenen Karteikarten."
    }

    private static func text(_ kind: UFNoServerPage.Kind) -> String {
        switch kind {
        case .dashboard: return "Hier stehen deine Lernpakete, Uni-Termine und neuen Dateien – noch ist nichts da."
        case .plan: return "Noch keine Lernpakete geplant."
        case .timetable: return "Noch keine Termine im Stundenplan."
        case .modules: return "Noch keine Module."
        case .library: return "Noch keine Dokumente."
        // Wochentests nur mit KI (ChatGPT des Nutzers); ohne sie fuehrt die Seite zu den Karteikarten (Audit 03.11.2026:
        // vorher nur "Noch keine Tests." ohne Weg weiter)
        case .exams: return examsText
        case .cards: return "Noch keine Karteikarten."
        case .services: return "Noch keine Noten."
        }
    }
}

/// Karte "Stud.IP verbinden": kurzer Satz und Knopf, oeffnet die echte Stud.IP-Anmeldung (StudIPLoginView);
/// das Passwort tippt der Nutzer selbst auf der Seite der Universitaet. Zeigt nur etwas, solange `mode` die Karte
/// verlangt – sie verschwindet also nach erfolgreicher Anmeldung von selbst. An der Universitaet Hildesheim
/// (`hasOtherSources`) stehen hier die Karten "Learnweb verbinden"/"LSF verbinden" bzw. die Statusleiste
/// (`HildesheimSourcesBar`).
struct ConnectStudIPCard: View {
    let mode: UFDataMode
    /// einzeilige Leiste statt der Karte: auf allen Seiten ausser der Uebersicht (Audit 03.11.2026: die Karten standen
    /// ueber jeder Seite und schoben den Seitentitel nach unten); die volle Karte bleibt auf der Uebersicht und in den
    /// Einstellungen (Karte "Stud.IP & QIS" bzw. "Learnweb & LSF")
    var compact = false
    @EnvironmentObject private var studip: StudIPSync
    @State private var showLogin = false

    var body: some View {
        if mode.hasOtherSources {
            HildesheimSourcesBar(compact: compact)
        } else if mode.showsConnectCard && compact {
            let expired = mode.studIPExpired
            UFConnectBar(title: expired ? "Stud.IP-Anmeldung abgelaufen" : "Stud.IP nicht verbunden",
                         text: expired ? "Melde dich erneut an, damit StudiNow weiter abgleicht." : "Kurse und Dateien kommen nach der Anmeldung.") {
                UFButton(expired || isFailed ? "Erneut anmelden" : "Stud.IP verbinden", icon: "arrow-right", kind: .primary, size: .small) { showLogin = true }
                    .fixedSize()
                    .accessibilityIdentifier("connectBar.studip")
            }
            .sheet(isPresented: $showLogin) { login }
        } else if mode.showsConnectCard {
            let expired = mode.studIPExpired
            UFCard {
                UFCardHead(expired ? "Stud.IP-Anmeldung abgelaufen" : "Stud.IP verbinden", icon: "graduation")
                Text(expired
                     ? "Melde dich erneut bei Stud.IP an, damit StudiNow deine Kurse und Dateien weiter abgleicht."
                     : "Melde dich bei Stud.IP der Leibniz Universität an, damit StudiNow deine Kurse und Dateien auf dieses iPad holt.")
                    .ufFont(14.5).foregroundStyle(UF.text2)
                    .fixedSize(horizontal: false, vertical: true)
                // z. B. Schluesselbundfehler nach der Anmeldung: Meldung zeigen statt still zu verschwinden
                if case .failed(let message) = studip.phase {
                    HStack(alignment: .top, spacing: 6) {
                        UFIcon("alert", size: 14).padding(.top, 2)
                        Text("Die Anmeldung konnte nicht abgeschlossen werden: \(message)")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .ufFont(13.12).foregroundStyle(UF.bad)
                    .padding(.top, 6)
                }
                Text("Dein Passwort gibst du nur auf der Seite der Universität ein.")
                    .ufFont(13.12).foregroundStyle(UF.muted)
                    .padding(.top, 4)
                UFButton(expired || isFailed ? "Erneut anmelden" : "Stud.IP verbinden", icon: "arrow-right", kind: .primary) { showLogin = true }
                    .padding(.top, 12.8)
            }
            .sheet(isPresented: $showLogin) { login }
        }
    }

    private var login: some View {
        StudIPLoginView(base: StudIPSync.base, dataStore: studip.websiteDataStore) { cookies in
            showLogin = false
            studip.signedIn(cookies: cookies)
        }
    }

    private var isFailed: Bool { if case .failed = studip.phase { return true }; return false }
}

/// Einzeilige Leiste oberhalb einer Seite: Symbol, Stand fett, kurzer Satz gedaempft, Knoepfe rechts; bricht erst
/// bei wenig Breite um. Hoehe etwa eine Knopfzeile statt einer ganzen Karte.
struct UFConnectBar<Buttons: View>: View {
    let title: String
    let text: String
    @ViewBuilder var buttons: Buttons

    var body: some View {
        // eine Zeile: mit Satz, sonst ohne Satz; erst wenn auch das nicht passt, umbrechend
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 9.6) { label(text: true).fixedSize(); Spacer(minLength: 8); HStack(spacing: 8) { buttons } }
            HStack(spacing: 9.6) { label(text: false).fixedSize(); Spacer(minLength: 8); HStack(spacing: 8) { buttons } }
            UFFlexWrap(gap: 9.6, rowGap: 6) { label(text: true); UFFlexSpacer(); buttons }
        }
        .padding(.vertical, 7.2 + ufB).padding(.horizontal, 14.4 + ufB)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: UF.r).fill(UF.accentSoft))
        .overlay(RoundedRectangle(cornerRadius: UF.r).strokeBorder(UF.accent.opacity(0.18), lineWidth: 1))
    }

    private func label(text show: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7.2) {
            UFIcon("graduation", size: 16).foregroundStyle(UF.accentText)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
            (Text(title).font(.uf(13.76, 600)).foregroundColor(UF.text)
             + Text(show ? "  " + text : "").foregroundColor(UF.text2))
                .ufFont(13.12)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title + ". " + text)
    }
}

/// Leerer Zustand einer Seite, die es in V1 nicht gibt: Kopf wie die Seite, Karte "Stud.IP verbinden", leere Karte.
struct UFNoServerPage: View {
    /// Seite, deren leerer Zustand gezeigt wird (bestimmt Icon und Text, UFNoServerContent)
    enum Kind: Equatable {
        case dashboard, plan, timetable, modules, library, exams, cards, services

        var icon: String {
            switch self {
            case .dashboard, .plan: return "calendar"
            case .timetable: return "clock"
            case .modules: return "book"
            case .library: return "folder"
            case .exams: return "exam"
            case .cards: return "cards"
            case .services: return "graduation"
            }
        }
    }

    struct Spec {
        let title: String
        var sub: String?
        let kind: Kind
        var maxWidth: CGFloat?
        /// Seite gibt es mit dem lokalen Backend (sonst lokal der leere Zustand, z. B. QIS-Noten, KI-Wochentests)
        var local = true
        /// lokal auch an Hochschulen mit eigenen Quellen, wenn `local` aus ist (Uni & Noten: Notenspiegel aus dem LSF)
        var localWithOtherSources = false
        /// lokal Karte "Stud.IP verbinden" bzw. Statusleiste oberhalb der Seite; im Editor nicht (dort zaehlt die
        /// ganze Hoehe fuer die Seite, Abgleich und Anmeldung stehen auf den uebrigen Seiten)
        var barAbove = true
    }

    let spec: Spec
    let mode: UFDataMode

    var body: some View {
        UFContent(maxWidth: spec.maxWidth) {
            UFPageHead(spec.title, sub: spec.sub)
            UFNoServerBody(kind: spec.kind, mode: mode)
        }
    }
}

/// Inhalt unter dem Seitenkopf des leeren Zustands
struct UFNoServerBody: View {
    let kind: UFNoServerPage.Kind
    let mode: UFDataMode
    @EnvironmentObject private var studip: StudIPSync
    @EnvironmentObject private var router: UFRouter

    var body: some View {
        let c = UFNoServerContent.resolve(kind: kind, mode: mode, phase: studip.phase)
        VStack(alignment: .leading, spacing: 16) {
            // ausserhalb der Uebersicht nur die einzeilige Leiste (Audit 03.11.2026)
            if c.showsConnectCard { ConnectStudIPCard(mode: mode, compact: true) }
            if let status = c.status { UFStudIPStatusCard(status: status) }
            UFCard {
                UFEmpty(icon: kind.icon, text: c.text) {
                    if c.soon { UFBadge("bald", tone: .info, icon: "clock") }
                    if kind == .exams { examsActions }
                }
            }
        }
    }

    /// Tests ohne KI: der naechste sinnvolle Schritt statt einer Sackgasse
    private var examsActions: some View {
        UFFlexWrap(gap: 8, justify: .center) {
            UFButton("Zu den Karteikarten", icon: "cards", kind: .primary, size: .small) { router.go(.cards) }
                .accessibilityIdentifier("exams.toCards")
            if ChatGPTLink.isEnabled {                          // erst nach der Freigabe durch OpenAI (05.11.2026)
                UFButton("ChatGPT verbinden", icon: "sparkles", size: .small) { router.go(.settings(tab: "advanced")) }
                    .accessibilityIdentifier("exams.connectChatGPT")
            }
        }
        .padding(.top, 9.6)
    }
}

/// Abgleichstand: Fortschrittszeile beim Abgleich, Meldung mit "Erneut versuchen" nach einem Fehler
struct UFStudIPStatusCard: View {
    let status: UFNoServerContent.Status
    @EnvironmentObject private var studip: StudIPSync
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        UFCard(flat: true) {
            switch status {
            case .syncing(let step):
                HStack(spacing: 9.6) {
                    ProgressView().tint(UF.accent)
                    Text("Stud.IP wird abgeglichen – \(step)")
                        .ufFont(14.5).foregroundStyle(UF.text2)
                        .lineLimit(2)
                        .contentTransition(.opacity)                        // neuer Schritt blendet ueber statt zu springen
                        .animation(UFMotion.animation(reduce: reduce), value: step)
                }
            case .failed(let message):
                HStack(alignment: .top, spacing: 7.2) {
                    UFIcon("alert", size: 18).foregroundStyle(UF.warn)
                    VStack(alignment: .leading, spacing: 2.4) {
                        Text("Stud.IP-Abgleich fehlgeschlagen").ufFont(14.5, 600).foregroundStyle(UF.text)
                        Text(message).ufFont(13.12).foregroundStyle(UF.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    UFButton("Erneut versuchen", icon: "refresh", size: .small) { Task { await studip.run() } }
                    // schliessbar (07.11.2026); der naechste Fehler zeigt sich wieder
                    UFButton(icon: "x", kind: .ghost, size: .small) { studip.dismissFailure() }
                        .accessibilityLabel("Meldung schließen")
                        .accessibilityIdentifier("studip.failure.dismiss")
                }
            }
        }
    }
}

/// Statusleiste oberhalb einer lokalen Seite bei verbundenem Stud.IP: Abgleichstand und Fehler mit "Erneut
/// versuchen" (die Dateien selbst stehen seit S3 in den Seiten). Zeigt nichts, wenn nichts davon da ist.
struct UFStudIPStatusBar: View {
    let kind: UFNoServerPage.Kind
    let mode: UFDataMode
    @EnvironmentObject private var studip: StudIPSync
    @EnvironmentObject private var router: UFRouter

    var body: some View {
        // im laufenden Test (Fokus) keine Abgleich-Leiste: sie lag ueber dem Test und dem Zurueck (Geraetetest 07.11.2026)
        if !router.examFocus, let status = UFNoServerContent.resolve(kind: kind, mode: mode, phase: studip.phase).status {
            UFStudIPStatusCard(status: status)
        }
    }
}

extension UFNoServerPage.Spec {
    // ohne PC keine Tests (KI, entfallen in V1): weder anbieten noch ankuendigen
    static let plan = Self(title: "Lernkalender", sub: "Dein Wochenplan – abgestimmt auf Vorlesungen und Übungen.",
                           kind: .plan, maxWidth: 1600)
    static let timetable = Self(title: "Stundenplan", kind: .timetable, maxWidth: 1600)
    static let modules = Self(title: "Meine Module", sub: "Alle Module deines Studiums – Vorlesungen, Übungen und Materialien an einem Ort.",
                              kind: .modules, maxWidth: 1480)
    static let library = Self(title: "Dokumente & Notizen", sub: "Alle Materialien deiner Module an einem Ort. Übersichtlich, schnell und fokussiert.",
                              kind: .library)
    /// geoeffnetes Dokument (Editor): wie `library`, aber ohne Leiste oberhalb
    static let document = Self(title: "Dokumente & Notizen", sub: "Alle Materialien deiner Module an einem Ort. Übersichtlich, schnell und fokussiert.",
                               kind: .library, barAbove: false)
    // Wochentests sind KI (entfallen in V1), Noten kommen erst mit QIS (F4): lokal der leere Zustand
    static let exams = Self(title: "Tests & Wiederholung", sub: "Deine eigenen Karteikarten wiederholst du unter „Karteikarten“.",
                            kind: .exams, local: false)
    /// mit KI ueber das ChatGPT-Abo des Nutzers (`ufAIEnabled`): Wochentests auch auf dem Geraet (lokales Backend)
    static let examsWithAI = Self(title: "Tests & Wiederholung", sub: "Wochentests deiner Module, erstellt mit deinem ChatGPT.", kind: .exams)
    static let cards = Self(title: "Karteikarten", kind: .cards, maxWidth: 820)
    /// KI-Start (03.11.2026): lokal immer echt; ohne verbundene KI zeigt die Seite selbst den Weg dorthin
    static let aiStart = Self(title: "KI-Start", sub: ChatGPTLink.isEnabled ? "Fragen, Karteikarten, Erklären und Wochentests mit deinem ChatGPT." : "Fragen, Karteikarten, Erklären und Wochentests zu deinen Unterlagen.", kind: .exams, maxWidth: 960)
    // Notenspiegel auf dem Geraet an beiden Hochschulen: LUH aus dem QIS (QISConnection), Uni Hildesheim aus dem LSF
    // (HildesheimSync); die Seite ist lokal immer echt
    static let services = Self(title: "Uni & Noten", sub: "Alle Dienste der Leibniz Universität an einem Ort.",
                               kind: .services, maxWidth: 1120, localWithOtherSources: true)
}

/// Seite mit Datenquelle laden (eigener Server oder lokales Backend), sonst den leeren Zustand zeigen. Lokal steht
/// die Karte "Stud.IP verbinden" oberhalb der echten Seite, solange Stud.IP nicht verbunden ist, danach die
/// Statusleiste mit dem Abgleichstand. Seiten, deren Funktion es in V1 nicht gibt (KI-Wochentests), zeigen lokal
/// weiter den ehrlichen leeren Zustand (`Spec.local == false`).
struct UFServerGate<Content: View>: View {
    let spec: UFNoServerPage.Spec
    @ViewBuilder var content: () -> Content
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var studip: StudIPSync
    @Environment(\.ufDemoActive) private var demo

    init(_ spec: UFNoServerPage.Spec, @ViewBuilder content: @escaping () -> Content) {
        self.spec = spec
        self.content = content
    }

    var body: some View {
        let mode = UFDataMode.current(api: session.api, studip: studip, demo: demo)
        let presentation = UFGatePresentation.resolve(spec: spec, mode: mode, phase: studip.phase)
        if presentation == .empty {
            UFNoServerPage(spec: spec, mode: mode)
        } else if case .local = mode {
            // lokal immer dieselbe Huelle: wechselt nur die Leiste (Anmeldung, Abgleich beginnt/endet), bleibt die
            // Seite bestehen und laedt nicht neu
            UFAbovePage(maxWidth: spec.maxWidth) {
                switch presentation {
                case .pageBelowConnectCard: ConnectStudIPCard(mode: mode, compact: true).padding(.ufAbovePage)
                case .pageBelowStudIPStatus: UFStudIPStatusBar(kind: spec.kind, mode: mode).padding(.ufAbovePage)
                case .page, .empty: EmptyView()
                }
            } content: { content() }
        } else {
            content()
        }
    }
}

/// Was UFServerGate zeigt (reine Funktion, LocalBackendAppTests)
enum UFGatePresentation: Equatable {
    case page, pageBelowConnectCard, pageBelowStudIPStatus, empty

    static func resolve(spec: UFNoServerPage.Spec, mode: UFDataMode, phase: StudIPSync.Phase) -> UFGatePresentation {
        guard case .local = mode else { return .page }
        guard spec.local || (spec.localWithOtherSources && mode.hasOtherSources) else { return .empty }
        guard spec.barAbove else { return .page }
        if mode.showsConnectCard { return .pageBelowConnectCard }
        // Abgleichstand und Fehler oberhalb der Seite; die Dateien zeigt die Seite selbst (S3)
        return UFNoServerContent.resolve(kind: spec.kind, mode: mode, phase: phase).showsStatusBar ? .pageBelowStudIPStatus : .page
    }
}

/// Leiste oberhalb einer Seite (lokaler Modus: Karte "Stud.IP verbinden" oder Statusleiste), in der Breite des
/// Seiteninhalts. Den Abstand `.ufAbovePage` setzt der Aufrufer an die Leiste, damit eine leere Leiste nichts einrueckt.
struct UFAbovePage<Top: View, Content: View>: View {
    var maxWidth: CGFloat?
    @ViewBuilder var top: () -> Top
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            // Breite wie UFContent (max. 1480 px bzw. die der Seite)
            VStack(alignment: .leading, spacing: 0) { top() }
            .frame(maxWidth: maxWidth ?? 1480, alignment: .leading)
            .frame(maxWidth: .infinity)
            content()
        }
        .background(UF.bg)
    }
}

extension EdgeInsets {
    /// Abstaende der Leiste oberhalb einer Seite wie UFContent (padding 1.4rem 1.6rem, unten keiner)
    static let ufAbovePage = EdgeInsets(top: 22.4, leading: 25.6, bottom: 0, trailing: 25.6)
}
