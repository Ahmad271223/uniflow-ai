import SwiftUI
import UniFlowCore

// V1 ohne PC-Server (docs/AUFTRAG-APPSTORE-V1.md, Abschnitt 2a): Die Seiten laden vom lokalen Backend des iPads
// (dieselben /api/-Pfade wie der PC-Server, docs/IPAD-OHNE-PC.md) und zeigen ihre echten, anfangs leeren Zustaende.
// Solange Stud.IP nicht verbunden ist, steht die Karte "Stud.IP verbinden" oberhalb der Seite, danach bis S3 die
// Statusleiste mit Abgleichstand und Stud.IP-Dateien – keine Beispieldaten, keine Hinweise auf PC oder PIN. Mit eigenem Server (Entwicklungsmodus des Inhabers) laden die Seiten wie bisher.
// Die Entscheidung trifft nur UFDataMode.current (Weiche fuer alle Seiten) und UFNoServerContent.resolve (was der
// leere Zustand ohne Datenquelle zeigt); beide sind reine Funktionen mit Unit-Tests (NoServerStateTests).

/// Stand der Stud.IP-Verbindung aus Sicht der Oberflaeche.
enum StudIPLink: Equatable {
    case notConnected
    /// Sitzung abgelaufen: erneut anmelden
    case expired
    /// angemeldet; auch waehrend eines Abgleichs und nach einem Abgleichfehler (z. B. offline)
    case connected

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
    /// keine Datenquelle, Stud.IP nicht verbunden: leerer Zustand mit Karte "Stud.IP verbinden"
    case connectStudIP
    /// keine Datenquelle, Stud.IP-Anmeldung abgelaufen: leerer Zustand mit Karte "Erneut anmelden"
    case reconnectStudIP
    /// keine Datenquelle, Stud.IP verbunden: leerer Zustand ohne Karte
    case empty

    static func resolve(hasServer: Bool, studIP: StudIPLink) -> UFDataMode {
        if hasServer { return .server }
        switch studIP {
        case .notConnected: return .connectStudIP
        case .expired: return .reconnectStudIP
        case .connected: return .empty
        }
    }

    /// mit Datenquelle: lokal oder eigener Server
    static func resolve(api: APIClient?, studIP: StudIPLink) -> UFDataMode {
        if let api, api.isLocal { return .local(studIP) }
        return resolve(hasServer: api != nil, studIP: studIP)
    }

    /// Die eine Weiche fuer alle Seiten (UFServerGate, Uebersicht, UFRemote, Community): Datenquelle aus der Sitzung,
    /// Stud.IP aus dem Abgleich. Den Schluesselbund liest sie nur bei einem Abgleichfehler.
    @MainActor static func current(api: APIClient?, studip: StudIPSync) -> UFDataMode {
        resolve(api: api, studIP: StudIPLink(studip.phase, hasSession: !StudIPKeychain.load().isEmpty))
    }

    /// Karte "Stud.IP verbinden" zeigen
    var showsConnectCard: Bool {
        switch self {
        case .connectStudIP, .reconnectStudIP: return true
        case .local(let link): return link != .connected
        case .server, .empty: return false
        }
    }

    /// Karte mit "Erneut anmelden" statt "Stud.IP verbinden"
    var studIPExpired: Bool { self == .reconnectStudIP || self == .local(.expired) }

    /// Seite laedt ihre Daten (eigener Server oder lokales Backend) statt den leeren Zustand ohne Datenquelle zu zeigen
    var loadsPages: Bool {
        switch self {
        case .server, .local: return true
        case .connectStudIP, .reconnectStudIP, .empty: return false
        }
    }

    /// Ohne PC: lokales Backend oder gar keine Datenquelle (Texte ohne Hinweis auf den PC)
    var isOnDevice: Bool { self != .server }
}

/// Was der leere Zustand einer Seite ohne Server zeigt: Abgleichstand, Text, Knopf zu den Stud.IP-Dateien.
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
    /// Funktion braucht eine spaetere Version (QIS-Noten, KI-Wochentests): als "bald" kennzeichnen
    let soon: Bool
    /// Beschriftung des Knopfs zu StudIPView; nil = kein Knopf
    let filesButton: String?
    /// kurzer Satz neben dem Knopf in der Statusleiste oberhalb einer lokalen Seite (UFStudIPStatusBar)
    var filesSummary: String?

    /// Statusleiste oberhalb einer lokalen Seite zeigen: Abgleichstand oder Stud.IP-Dateien sind da
    var showsStatusBar: Bool { status != nil || filesButton != nil }

    static func resolve(kind: UFNoServerPage.Kind, mode: UFDataMode, phase: StudIPSync.Phase,
                        files: Int, courses: Int) -> UFNoServerContent {
        // Stud.IP verbunden: ohne Datenquelle oder mit lokalem Backend (bis S3 kennen die lokalen Seiten die
        // abgeglichenen Dateien noch nicht, deshalb Abgleichstand und Knopf zu StudIPView wie im leeren Zustand)
        let connected = mode == .empty || mode == .local(.connected)
        var status: Status?
        if connected {
            switch phase {
            case .running(let step): status = .syncing(step)
            case .failed(let message): status = .failed(message)
            case .signedOut, .needsLogin, .idle: status = nil
            }
        }
        var button: String?
        var summary: String?
        if connected, files > 0 {
            button = "Stud.IP-Dateien ansehen (\(files))"
            summary = filesHere(files)
        } else if connected, courses > 0 {
            button = "Stud.IP-Kurse ansehen (\(courses))"
            summary = coursesSynced(courses)
        }
        return UFNoServerContent(showsConnectCard: mode.showsConnectCard, status: status,
                                 text: text(kind, connected: connected, files: files, courses: courses),
                                 soon: kind == .services, filesButton: button, filesSummary: summary)
    }

    private static func filesHere(_ files: Int) -> String {
        files == 1 ? "1 Datei aus Stud.IP liegt auf diesem iPad." : "\(files) Dateien aus Stud.IP liegen auf diesem iPad."
    }

    private static func coursesSynced(_ courses: Int) -> String {
        courses == 1 ? "1 Kurs aus Stud.IP ist abgeglichen." : "\(courses) Kurse aus Stud.IP sind abgeglichen."
    }

    private static func text(_ kind: UFNoServerPage.Kind, connected: Bool, files: Int, courses: Int) -> String {
        let filesHere = filesHere(files)
        switch kind {
        case .dashboard:
            if connected, files > 0 { return filesHere + " Lernpakete und Uni-Termine gibt es noch keine." }
            return "Hier stehen deine Lernpakete, Uni-Termine und neuen Dateien – noch ist nichts da."
        case .plan: return "Noch keine Lernpakete geplant."
        case .timetable: return "Noch keine Termine im Stundenplan."
        case .modules:
            if connected, courses > 0 { return coursesSynced(courses) }
            return "Noch keine Module."
        case .library:
            if connected, files > 0 { return filesHere }
            return "Noch keine Dokumente."
        // keine KI in V1 (Entscheidung 25.10.): Wochentests weder anbieten noch ankuendigen
        case .exams: return "Noch keine Tests."
        case .cards: return "Noch keine Karteikarten."
        case .services: return "Noten aus QIS kommen in einer späteren Version."
        case .generic: return "Hier ist noch nichts."
        }
    }
}

/// Karte "Stud.IP verbinden": kurzer Satz und Knopf, oeffnet die echte Stud.IP-Anmeldung (StudIPLoginView);
/// das Passwort tippt der Nutzer selbst auf der Seite der Universitaet. Zeigt nur etwas, solange `mode` die Karte
/// verlangt – sie verschwindet also nach erfolgreicher Anmeldung von selbst. In den Einstellungen (ohne Server)
/// mit `UFDataMode.current(api: nil, studip:)` nutzbar.
struct ConnectStudIPCard: View {
    let mode: UFDataMode
    @EnvironmentObject private var studip: StudIPSync
    @State private var showLogin = false

    var body: some View {
        if mode.showsConnectCard {
            let expired = mode.studIPExpired
            UFCard {
                UFCardHead(expired ? "Stud.IP-Anmeldung abgelaufen" : "Stud.IP verbinden", icon: "graduation")
                Text(expired
                     ? "Melde dich erneut bei Stud.IP an, damit UniFlow deine Kurse und Dateien weiter abgleicht."
                     : "Melde dich bei Stud.IP der Leibniz Universität an, damit UniFlow deine Kurse und Dateien auf dieses iPad holt.")
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
            .sheet(isPresented: $showLogin) {
                StudIPLoginView(base: StudIPSync.base) { cookies in
                    showLogin = false
                    studip.signedIn(cookies: cookies)
                }
            }
        }
    }

    private var isFailed: Bool { if case .failed = studip.phase { return true }; return false }
}

/// Leerer Zustand einer Seite ohne Server: Kopf wie die Seite, Karte "Stud.IP verbinden", leere Karte.
struct UFNoServerPage: View {
    /// Seite, deren leerer Zustand gezeigt wird (bestimmt Icon und Text, UFNoServerContent)
    enum Kind: Equatable {
        case dashboard, plan, timetable, modules, library, exams, cards, services, generic

        var icon: String {
            switch self {
            case .dashboard, .plan: return "calendar"
            case .timetable: return "clock"
            case .modules: return "book"
            case .library: return "folder"
            case .exams: return "exam"
            case .cards: return "cards"
            case .services: return "graduation"
            case .generic: return "info"
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

/// Inhalt unter dem Seitenkopf ohne Server (auch fuer die Uebersicht mit eigener Begruessung).
struct UFNoServerBody: View {
    let kind: UFNoServerPage.Kind
    let mode: UFDataMode
    @EnvironmentObject private var studip: StudIPSync
    @State private var showFiles = false

    var body: some View {
        let c = UFNoServerContent.resolve(kind: kind, mode: mode, phase: studip.phase,
                                          files: studip.entries.count, courses: studip.courses.count)
        VStack(alignment: .leading, spacing: 16) {
            if c.showsConnectCard { ConnectStudIPCard(mode: mode) }
            if let status = c.status { UFStudIPStatusCard(status: status) }
            UFCard {
                UFEmpty(icon: kind.icon, text: c.text) {
                    if c.soon { UFBadge("bald", tone: .info, icon: "clock") }
                    // die heruntergeladenen Stud.IP-Dateien und Kurse sind echte Daten auf diesem iPad
                    if let label = c.filesButton {
                        UFButton(label, icon: "folder") { showFiles = true }
                            .padding(.top, 8)
                    }
                }
            }
        }
        .sheet(isPresented: $showFiles) {
            NavigationStack {
                StudIPView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { showFiles = false } } }
            }
        }
    }
}

/// Abgleichstand: Fortschrittszeile beim Abgleich, Meldung mit "Erneut versuchen" nach einem Fehler
struct UFStudIPStatusCard: View {
    let status: UFNoServerContent.Status
    @EnvironmentObject private var studip: StudIPSync

    var body: some View {
        UFCard(flat: true) {
            switch status {
            case .syncing(let step):
                HStack(spacing: 9.6) {
                    ProgressView().tint(UF.accent)
                    Text("Stud.IP wird abgeglichen – \(step)")
                        .ufFont(14.5).foregroundStyle(UF.text2)
                        .lineLimit(2)
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
                }
            }
        }
    }
}

/// Statusleiste oberhalb einer lokalen Seite bei verbundenem Stud.IP (bis S3): Abgleichstand, Fehler mit
/// "Erneut versuchen" und der Knopf zu den abgeglichenen Stud.IP-Dateien. Zeigt nichts, wenn nichts davon da ist.
struct UFStudIPStatusBar: View {
    let kind: UFNoServerPage.Kind
    let mode: UFDataMode
    @EnvironmentObject private var studip: StudIPSync
    @State private var showFiles = false

    var body: some View {
        let c = UFNoServerContent.resolve(kind: kind, mode: mode, phase: studip.phase,
                                          files: studip.entries.count, courses: studip.courses.count)
        if c.showsStatusBar {
            VStack(alignment: .leading, spacing: 12.8) {
                if let status = c.status { UFStudIPStatusCard(status: status) }
                if let label = c.filesButton {
                    UFCard(flat: true) {
                        HStack(spacing: 9.6) {
                            UFIcon("folder", size: 18).foregroundStyle(UF.accent)
                            Text(c.filesSummary ?? "").ufFont(14.5).foregroundStyle(UF.text2)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            UFButton(label, icon: "folder", size: .small) { showFiles = true }
                        }
                    }
                }
            }
            .sheet(isPresented: $showFiles) {
                NavigationStack {
                    StudIPView()
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { showFiles = false } } }
                }
            }
        }
    }
}

extension UFNoServerPage.Spec {
    static let plan = Self(title: "Lernkalender", sub: "Dein Wochenplan – perfekt auf Vorlesungen, Übungen und Tests abgestimmt.",
                           kind: .plan, maxWidth: 1600)
    static let timetable = Self(title: "Stundenplan", kind: .timetable, maxWidth: 1600)
    static let modules = Self(title: "Meine Module", sub: "Alle Module deines Studiums – Vorlesungen, Übungen, Materialien und Tests an einem Ort.",
                              kind: .modules, maxWidth: 1480)
    static let library = Self(title: "Dokumente & Notizen", sub: "Alle Materialien deiner Module an einem Ort. Übersichtlich, schnell und fokussiert.",
                              kind: .library)
    // Wochentests sind KI (entfallen in V1), Noten kommen erst mit QIS (F4): lokal der leere Zustand
    static let exams = Self(title: "Tests & Wiederholung", sub: "Ein gemeinsamer Wochentest pro Modul und Lehrwoche, dazu Karteikarten zum Wiederholen.",
                            kind: .exams, local: false)
    static let cards = Self(title: "Karteikarten", kind: .cards, maxWidth: 820)
    // ohne "Notenspiegel direkt in der App": Noten kommen erst mit QIS (F4)
    static let services = Self(title: "Uni & Noten", sub: "Alle Dienste der Leibniz Universität an einem Ort.",
                               kind: .services, maxWidth: 1120, local: false)
    /// Rueckfall fuer Ansichten ohne eigene Angaben (UFRemote)
    static let generic = Self(title: "UniFlow", kind: .generic)
}

/// Seite mit Datenquelle laden (eigener Server oder lokales Backend), sonst den leeren Zustand zeigen. Lokal steht
/// die Karte "Stud.IP verbinden" oberhalb der echten Seite, solange Stud.IP nicht verbunden ist, danach bis S3 die
/// Statusleiste mit Abgleichstand und Stud.IP-Dateien. Seiten, deren Funktion es in V1 nicht gibt (KI-Wochentests,
/// QIS-Noten), zeigen lokal weiter den ehrlichen leeren Zustand (`Spec.local == false`).
struct UFServerGate<Content: View>: View {
    let spec: UFNoServerPage.Spec
    @ViewBuilder var content: () -> Content
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var studip: StudIPSync

    init(_ spec: UFNoServerPage.Spec, @ViewBuilder content: @escaping () -> Content) {
        self.spec = spec
        self.content = content
    }

    var body: some View {
        let mode = UFDataMode.current(api: session.api, studip: studip)
        let presentation = UFGatePresentation.resolve(spec: spec, mode: mode, phase: studip.phase,
                                                      files: studip.entries.count, courses: studip.courses.count)
        if presentation == .empty {
            UFNoServerPage(spec: spec, mode: mode)
        } else if case .local = mode {
            // lokal immer dieselbe Huelle: wechselt nur die Leiste (Anmeldung, Abgleich beginnt/endet), bleibt die
            // Seite bestehen und laedt nicht neu
            UFAbovePage(maxWidth: spec.maxWidth) {
                switch presentation {
                case .pageBelowConnectCard: ConnectStudIPCard(mode: mode).padding(.ufAbovePage)
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

    static func resolve(spec: UFNoServerPage.Spec, mode: UFDataMode, phase: StudIPSync.Phase,
                        files: Int, courses: Int) -> UFGatePresentation {
        guard mode.loadsPages else { return .empty }
        if case .local = mode {
            guard spec.local else { return .empty }
            if mode.showsConnectCard { return .pageBelowConnectCard }
            // bis S3: Abgleichstand, Fehler und die Stud.IP-Dateien oberhalb der Seite, die sie noch nicht kennt
            let c = UFNoServerContent.resolve(kind: spec.kind, mode: mode, phase: phase, files: files, courses: courses)
            return c.showsStatusBar ? .pageBelowStudIPStatus : .page
        }
        return .page
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
