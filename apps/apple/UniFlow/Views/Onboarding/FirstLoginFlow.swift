import SwiftUI
import UniFlowCore

// Erster Start, Entscheidung des Inhabers (docs/OFFEN-V1.md, Punkt 2): Mit Apple anmelden -> Tarif -> Hochschule ->
// SOFORT die Anmeldeseiten der Hochschule in der App (LUH: Stud.IP, danach QIS; Uni Hildesheim: CAS fuer Learnweb,
// danach LSF ueber dieselbe CAS-Sitzung), der Nutzer tippt selbst (Vorausfuellen beim naechsten Mal) -> Erstabgleich
// mit Fortschritt (Dateien, Stundenplan, Noten, an der LUH auch die Opencast-Listen) -> gefuellter Startbildschirm.
// Auf jeder Anmeldeseite ein kleiner Link "Später anmelden": dann die bisherigen Karten "… verbinden" auf der
// Uebersicht. Der Schritt erscheint einmal je (Nutzer, Hochschule) (`AccountStore.loginDone`); Uni-Wechsel nur in den
// Einstellungen. Debug: -UFOnboarding login (mit -UFLoginStub <ordner> gegen lokale Nachbildungen, DebugUniStub).
// Ohne Hochschulkonto (App-Pruefung, Ausprobieren): klein daneben "Ohne Hochschulkonto ansehen (Demo)" legt die
// Demo-Inhalte im offenen Container an (`ContainerManager.setDemo`, kein Netz) und fuehrt gleich zur Oberflaeche.

/// Eine Anmeldeseite des ersten Starts
enum FirstLoginStep: String, CaseIterable, Identifiable {
    case studip, qis, learnweb, lsf

    var id: String { rawValue }

    /// Reihenfolge je Hochschule (LUH: Stud.IP, dann QIS; Hildesheim: Learnweb, dann LSF ueber dieselbe CAS-Sitzung)
    static func steps(for u: UniversityKey) -> [FirstLoginStep] {
        switch u {
        case .luh: return [.studip, .qis]
        case .hildesheim: return [.learnweb, .lsf]
        }
    }

    var title: String {
        switch self {
        case .studip: return "Bei Stud.IP anmelden"
        case .qis: return "Bei QIS anmelden"
        case .learnweb: return "Beim Learnweb anmelden"
        case .lsf: return "Beim LSF anmelden"
        }
    }

    /// Was die Anmeldung bringt (ein Satz unter dem Titel)
    var intro: String {
        switch self {
        case .studip: return "UniFlow holt danach deine Kurse, Dateien, den Stundenplan und die Aufzeichnungen auf dieses iPad."
        case .qis: return "Danach steht dein Notenspiegel in UniFlow. Meist dieselbe LUH-ID wie bei Stud.IP."
        case .learnweb: return "UniFlow holt danach deine Learnweb-Kurse und -Dateien auf dieses iPad (UNI-Account)."
        case .lsf: return "Danach kommen Stundenplan und Notenspiegel aus dem LSF. Mit der Learnweb-Anmeldung geht das meist ohne neues Passwort."
        }
    }
}

/// Der Ablauf: Anmeldeseiten nacheinander, danach der Erstabgleich mit Fortschritt, am Ende die Oberflaeche
/// (`AccountStore.markLoginDone`). Schritte, deren Quelle schon verbunden ist, werden uebersprungen. Die Abgleiche
/// kommen immer vom `ContainerManager` (die des gerade geoeffneten Containers; der Container oeffnet sich erst mit
/// der Hochschulwahl, also waehrend dieser Ablauf schon im Aufbau ist).
struct FirstLoginFlow: View {
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var containers: ContainerManager
    @EnvironmentObject private var toast: UFToastCenter
    @State private var index = 0
    @State private var syncing = false
    @State private var startingDemo = false

    private var university: UniversityKey { account.university ?? .luh }
    private var steps: [FirstLoginStep] { FirstLoginStep.steps(for: university) }

    var body: some View {
        Group {
            if syncing || index >= steps.count {
                FirstSyncView(university: university, studip: containers.studip, qis: containers.qis, hildesheim: containers.hildesheim) {
                    account.markLoginDone()
                }
            } else {
                FirstLoginPage(step: steps[index], index: index, count: steps.count, studip: containers.studip, qis: containers.qis,
                               hildesheim: containers.hildesheim, onDone: advance, onLater: later,
                               demo: Self.offersDemo(studip: containers.studip, qis: containers.qis, hildesheim: containers.hildesheim)
                                   ? (startingDemo ? .starting : .offered) : .hidden,
                               onDemo: startDemo)
                    .id(steps[index])
                    .onAppear {
                        if Self.isConnected(steps[index], studip: containers.studip, qis: containers.qis, hildesheim: containers.hildesheim) { advance() }
                    }
            }
        }
        .animation(UF.transition, value: syncing)
        .animation(UF.transition, value: index)
    }

    /// Quelle dieses Schritts schon verbunden (z. B. nach Hochschulwechsel zurueck)?
    static func isConnected(_ step: FirstLoginStep, studip: StudIPSync, qis: QISConnection?, hildesheim: HildesheimConnection?) -> Bool {
        switch step {
        case .studip: return studip.phase != .signedOut && studip.phase != .needsLogin
        case .qis: return qis?.isConnected == true && qis?.state != .needsLogin
        case .learnweb: return hildesheim?.isConnected(.learnweb) == true && hildesheim?.state(.learnweb) != .needsLogin
        case .lsf: return hildesheim?.isConnected(.lsf) == true && hildesheim?.state(.lsf) != .needsLogin
        }
    }

    /// Ist irgendeine Quelle verbunden (dann lohnt der Erstabgleich)?
    static func anyConnected(studip: StudIPSync, qis: QISConnection?, hildesheim: HildesheimConnection?) -> Bool {
        studip.hasStoredSession || qis?.isConnected == true || hildesheim?.anyConnected == true
    }

    private func advance() {
        if index + 1 < steps.count { index += 1 } else { syncing = true }
    }

    /// "Später anmelden": die uebrigen Anmeldeseiten auslassen; verbundene Quellen gleichen noch ab, sonst gleich die
    /// Oberflaeche mit den Karten "… verbinden"
    private func later() {
        if Self.anyConnected(studip: containers.studip, qis: containers.qis, hildesheim: containers.hildesheim) { syncing = true } else { account.markLoginDone() }
    }

    /// "Ohne Hochschulkonto ansehen (Demo)" nur, solange keine Quelle der Hochschule verbunden ist (wer sich angemeldet
    /// hat, braucht keine Demo, und ein laufender Abgleich soll nicht neben der Demo weiterlaufen)
    static func offersDemo(studip: StudIPSync, qis: QISConnection?, hildesheim: HildesheimConnection?) -> Bool {
        !anyConnected(studip: studip, qis: qis, hildesheim: hildesheim)
    }

    private func startDemo() {
        guard !startingDemo else { return }
        startingDemo = true
        Task {
            defer { startingDemo = false }
            do {
                try await Self.startDemo(containers: containers, account: account)
            } catch {
                toast.show(error.localizedDescription, seconds: 4)
            }
        }
    }

    /// Demo-Inhalte im offenen Container anlegen (keine Anmeldung, keine Anfrage an die Hochschule), dann die Oberflaeche
    /// (der Schritt gilt als erledigt; anmelden geht spaeter in den Einstellungen, nachdem die Demo entfernt ist)
    static func startDemo(containers: ContainerManager, account: AccountStore) async throws {
        try await containers.setDemo(true)
        account.markLoginDone()
    }
}

/// "Ohne Hochschulkonto ansehen (Demo)" auf der Anmeldeseite
enum FirstLoginDemo: Equatable { case hidden, offered, starting }

/// Eine Anmeldeseite: Kopf mit Schritt und Erklaerung, darunter die Anmeldeansicht der Quelle (Webansicht der
/// Hochschule mit "Auf diesem iPad merken"), ganz unten der kleine Link "Später anmelden"
struct FirstLoginPage: View {
    let step: FirstLoginStep
    let index: Int
    let count: Int
    /// Abgleiche des offenen Containers (ContainerManager)
    let studip: StudIPSync
    let qis: QISConnection?
    let hildesheim: HildesheimConnection?
    let onDone: () -> Void
    let onLater: () -> Void
    var demo: FirstLoginDemo = .hidden
    var onDemo: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            header
            pane
        }
        .background(UF.bg.ignoresSafeArea())
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14.4) {
            UFLogoMark(size: 40)
            VStack(alignment: .leading, spacing: 3.2) {
                Text("Schritt \(index + 1) von \(count): \(step.title)").ufFont(20, 700, em: -0.01).foregroundStyle(UF.text)
                    .accessibilityIdentifier("firststart.title")
                Text(step.intro).ufFont(13.12).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                Text("Du tippst Benutzername und Passwort selbst auf der Seite der Universität ein; UniFlow füllt sie beim nächsten Mal nur vor.")
                    .ufFont(12.16).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                ForEach(0..<count, id: \.self) { i in
                    Circle().fill(i <= index ? UF.accent : UF.line).frame(width: 8, height: 8)
                }
            }
            .padding(.top, 8)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 25.6).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(UF.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(UF.line).frame(height: 1) }
    }

    @ViewBuilder private var pane: some View {
        switch step {
        case .studip:
            StudIPLoginPane(base: StudIPSync.base, dataStore: studip.websiteDataStore, onSignedIn: { cookies in
                studip.signedIn(cookies: cookies)
                onDone()
            }) { later }
        case .qis:
            if let qis {
                QISLoginPane(connection: qis, onSignedIn: onDone) { later }
            } else {
                missing
            }
        case .learnweb, .lsf:
            if let hildesheim {
                HildesheimStepPane(target: step == .learnweb ? .learnweb : .lsf, connection: hildesheim, onDone: onDone) { later }
            } else {
                missing
            }
        }
    }

    /// Verbindung dieser Hochschule fehlt (Container nicht offen): nichts vortaeuschen, weiter mit "Später"
    private var missing: some View {
        VStack {
            UFCard {
                UFCardHead("Anmeldung gerade nicht möglich", icon: "alert")
                Text("Der Speicher deiner Hochschule ist noch nicht geöffnet. Du findest die Anmeldung gleich auf der Übersicht.")
                    .ufFont(14.5).foregroundStyle(UF.text2).fixedSize(horizontal: false, vertical: true)
                UFButton("Weiter", icon: "arrow-right", kind: .primary) { onLater() }.padding(.top, 12.8)
            }
            .frame(maxWidth: 560)
            Spacer()
        }
        .padding(25.6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Link "Später anmelden" unter dem Schalter "Auf diesem iPad merken", davor klein der Weg ohne Hochschulkonto
    private var later: some View {
        HStack(spacing: 8) {
            Text(Self.laterHint).ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if demo != .hidden {
                UFButton(demo == .starting ? DemoTexts.firstStartRunning : DemoTexts.firstStart, icon: "sparkles", kind: .ghost, size: .small) { onDemo() }
                    .disabled(demo == .starting)
                    .accessibilityIdentifier("firststart.demo")
            }
            UFButton("Später anmelden", icon: "arrow-right", kind: .ghost, size: .small) { onLater() }
                .accessibilityIdentifier("firststart.later")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(UF.surface)
        .overlay(alignment: .top) { Rectangle().fill(UF.line).frame(height: 1) }
    }

    static let laterHint = "Du kannst dich auch später anmelden – die Übersicht zeigt dann die Karte zum Verbinden."
}

/// Learnweb- bzw. LSF-Anmeldung als Schritt des ersten Starts (eigener `HildesheimLogin` je Schritt)
private struct HildesheimStepPane<Bottom: View>: View {
    @StateObject private var login: HildesheimLogin
    let onDone: () -> Void
    @ViewBuilder let bottom: Bottom

    init(target: HildesheimConnection.Source, connection: HildesheimConnection, onDone: @escaping () -> Void, @ViewBuilder bottom: () -> Bottom) {
        _login = StateObject(wrappedValue: HildesheimLogin(target: target, connection: connection))
        self.onDone = onDone
        self.bottom = bottom()
    }

    var body: some View {
        HildesheimLoginPane(login: login) { bottom }
            .onChange(of: login.stage) { _, stage in if stage == .done { onDone() } }
    }
}

// MARK: - Erstabgleich

/// Eine Zeile des Erstabgleichs (Dateien, Stundenplan, Noten, Aufzeichnungen)
struct FirstSyncRow: Equatable, Identifiable {
    enum State: Equatable { case waiting, running, done, skipped, needsLogin, failed }

    let id: String
    let title: String
    let state: State
    /// Zusammenfassung oder Fehlermeldung
    var detail: String?
}

/// Zeilen des Erstabgleichs aus dem Stand der Abgleiche (reine Funktionen, FirstStartAppTests)
enum FirstSyncProgress {
    /// LUH: Stud.IP-Abgleich (Kurse und Dateien -> Stundenplan -> Aufzeichnungen, Reihenfolge wie `StudIPSync.perform`,
    /// erkannt am Fortschrittstext) und der QIS-Abruf
    static func luh(phase: StudIPSync.Phase, hasSession: Bool, summary: String?, qis: QISConnection.State?, qisMessage: String?) -> [FirstSyncRow] {
        let titles = ["Kurse und Dateien aus Stud.IP", "Stundenplan", "Aufzeichnungen (Opencast)"]
        let ids = ["files", "timetable", "recordings"]
        var rows: [FirstSyncRow] = []
        switch phase {
        case .signedOut:
            rows = zip(ids, titles).map { FirstSyncRow(id: $0, title: $1, state: .skipped, detail: hasSession ? nil : "Stud.IP später anmelden") }
        case .running(let text):
            let stage = text.hasPrefix("Aufzeichnungen") ? 2 : text.hasPrefix("Stundenplan") ? 1 : 0
            rows = zip(ids, titles).enumerated().map { i, r in
                FirstSyncRow(id: r.0, title: r.1, state: i < stage ? .done : i == stage ? .running : .waiting, detail: i == stage ? text : nil)
            }
        case .idle:
            rows = zip(ids, titles).map { FirstSyncRow(id: $0, title: $1, state: .done, detail: $0 == "files" ? summary : nil) }
        case .needsLogin:
            rows = zip(ids, titles).map { FirstSyncRow(id: $0, title: $1, state: .needsLogin, detail: "Stud.IP-Anmeldung abgelaufen – bitte erneut anmelden") }
        case .failed(let message):
            rows = zip(ids, titles).map { FirstSyncRow(id: $0, title: $1, state: .failed, detail: $0 == "files" ? message : nil) }
        }
        let grades: FirstSyncRow
        switch qis {
        case nil, .notConnected?: grades = FirstSyncRow(id: "grades", title: "Noten aus QIS", state: .skipped, detail: "QIS später anmelden")
        case .connected?, .running?: grades = FirstSyncRow(id: "grades", title: "Noten aus QIS", state: .running)
        case .ok?: grades = FirstSyncRow(id: "grades", title: "Noten aus QIS", state: .done, detail: qisMessage)
        case .needsLogin?: grades = FirstSyncRow(id: "grades", title: "Noten aus QIS", state: .needsLogin, detail: qisMessage)
        case .failed(let m)?: grades = FirstSyncRow(id: "grades", title: "Noten aus QIS", state: .failed, detail: m)
        }
        return rows + [grades]
    }

    /// Uni Hildesheim: Learnweb (Kurse und Dateien), LSF (Stundenplan und Noten im selben Lauf)
    static func hildesheim(learnweb: HildesheimConnection.State, lsf: HildesheimConnection.State, messages: [String]) -> [FirstSyncRow] {
        func state(_ s: HildesheimConnection.State) -> FirstSyncRow.State {
            switch s {
            case .notConnected: return .skipped
            case .connected: return .waiting
            case .running: return .running
            case .ok: return .done
            case .needsLogin: return .needsLogin
            case .failed: return .failed
            }
        }
        // Meldungen des Kerns: "<n> neue/geänderte Dateien aus <m> Learnweb-Kursen", "Stundenplan: …", "Notenspiegel: …"
        func message(_ word: String) -> String? { messages.first { $0.contains(word) } }
        func detail(_ s: HildesheimConnection.State, _ word: String, skipped: String) -> String? {
            switch s {
            case .notConnected: return skipped
            case .failed(let m): return message(word) ?? m
            case .needsLogin: return "Anmeldung abgelaufen – bitte erneut anmelden"
            case .ok: return message(word)
            case .connected, .running: return nil
            }
        }
        return [
            FirstSyncRow(id: "files", title: "Kurse und Dateien aus dem Learnweb", state: state(learnweb),
                         detail: detail(learnweb, "Learnweb", skipped: "Learnweb später anmelden")),
            FirstSyncRow(id: "timetable", title: "Stundenplan aus dem LSF", state: state(lsf),
                         detail: detail(lsf, "Stundenplan", skipped: "LSF später anmelden")),
            FirstSyncRow(id: "grades", title: "Noten aus dem LSF", state: state(lsf),
                         detail: detail(lsf, "Notenspiegel", skipped: "LSF später anmelden")),
        ]
    }

    /// Fertig: keine Zeile wartet oder laeuft noch
    static func isFinished(_ rows: [FirstSyncRow]) -> Bool { !rows.contains { $0.state == .waiting || $0.state == .running } }

    /// Kopfzeile je Stand
    static func title(finished: Bool, anyLoaded: Bool) -> String {
        guard finished else { return "Dein Studium wird geladen …" }
        return anyLoaded ? "Alles da – los geht’s" : "Fertig"
    }
}

/// Erstabgleich mit Fortschritt: je Quelle eine Zeile mit Stand; "Zur Übersicht", sobald alles durch ist (vorher
/// "Im Hintergrund weiter": die Statusleiste der Uebersicht zeigt den Rest)
struct FirstSyncView: View {
    let university: UniversityKey
    /// Abgleiche des offenen Containers (ContainerManager); beobachtet, damit jede Phase sofort erscheint
    @ObservedObject var studip: StudIPSync
    let qis: QISConnection?
    let hildesheim: HildesheimConnection?
    let onDone: () -> Void

    var body: some View {
        if university == .hildesheim, let hildesheim {
            HildesheimObserver(connection: hildesheim, onDone: onDone)
        } else if let qis {
            QISObserver(connection: qis, studip: studip, onDone: onDone)
        } else {
            FirstSyncPage(rows: Self.rows(studip: studip, qis: nil), onDone: onDone)
        }
    }

    static func rows(studip: StudIPSync, qis: QISConnection?) -> [FirstSyncRow] {
        FirstSyncProgress.luh(phase: studip.phase, hasSession: studip.hasStoredSession, summary: studip.lastSummary,
                              qis: qis?.state, qisMessage: qis?.lastMessage)
    }

    private struct HildesheimObserver: View {
        @ObservedObject var connection: HildesheimConnection
        let onDone: () -> Void
        var body: some View {
            FirstSyncPage(rows: FirstSyncProgress.hildesheim(learnweb: connection.learnweb, lsf: connection.lsf, messages: connection.messages),
                          onDone: onDone)
        }
    }

    private struct QISObserver: View {
        @ObservedObject var connection: QISConnection
        @ObservedObject var studip: StudIPSync
        let onDone: () -> Void
        var body: some View { FirstSyncPage(rows: FirstSyncView.rows(studip: studip, qis: connection), onDone: onDone) }
    }
}

/// Seite des Erstabgleichs im Rahmen des ersten Starts
struct FirstSyncPage: View {
    let rows: [FirstSyncRow]
    let onDone: () -> Void

    var body: some View {
        let finished = FirstSyncProgress.isFinished(rows)
        let loaded = rows.contains { $0.state == .done }
        OnboardingPage {
            VStack(alignment: .leading, spacing: 0) {
                UFLogoMark(size: 52)
                Text(FirstSyncProgress.title(finished: finished, anyLoaded: loaded))
                    .ufFont(28.8, 700, em: -0.02).foregroundStyle(UF.text).padding(.top, 19.2)
                    .accessibilityIdentifier("firststart.sync.title")
                Text(finished
                     ? "Deine Daten liegen nur auf diesem iPad. Alles Weitere holt UniFlow beim Öffnen der App von selbst."
                     : "UniFlow holt deine Daten auf dieses iPad. Das kann beim ersten Mal ein paar Minuten dauern.")
                    .ufFont(16).foregroundStyle(UF.text2).padding(.top, 6.4)
                    .fixedSize(horizontal: false, vertical: true)
                UFCard {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { r in
                            HStack(alignment: .top, spacing: 11.2) {
                                icon(r.state).frame(width: 22, height: 22).padding(.top, 1)
                                VStack(alignment: .leading, spacing: 2.4) {
                                    Text(r.title).ufFont(14.5, 600).foregroundStyle(UF.text)
                                    if let d = r.detail {
                                        Text(d).ufFont(12.8).foregroundStyle(r.state == .failed || r.state == .needsLogin ? UF.bad : UF.muted)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                Spacer(minLength: 0)
                                UFBadge(Self.label(r.state), tone: Self.tone(r.state))
                            }
                            .padding(.vertical, 9.6)
                            .ufBorderBottom(r.id != rows.last?.id)
                            .accessibilityIdentifier("firststart.row.\(r.id)")
                        }
                    }
                }
                .padding(.top, 22.4)
                HStack {
                    Spacer()
                    UFButton(finished ? "Zur Übersicht" : "Im Hintergrund weiter", icon: "arrow-right", kind: finished ? .primary : .normal) { onDone() }
                        .accessibilityIdentifier("firststart.done")
                }
                .padding(.top, 22.4)
                if !finished {
                    Text("Du kannst schon loslegen; der Abgleich läuft weiter und die Übersicht zeigt seinen Stand.")
                        .ufFont(12.8).foregroundStyle(UF.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 16)
                }
            }
        }
    }

    @ViewBuilder private func icon(_ s: FirstSyncRow.State) -> some View {
        switch s {
        case .running: ProgressView().tint(UF.accent).controlSize(.small)
        case .done: UFIcon("check", size: 18).foregroundStyle(UF.ok)
        case .waiting: UFIcon("clock", size: 18).foregroundStyle(UF.muted)
        case .skipped: UFIcon("arrow-right", size: 18).foregroundStyle(UF.muted)
        case .needsLogin, .failed: UFIcon("alert", size: 18).foregroundStyle(UF.bad)
        }
    }

    static func label(_ s: FirstSyncRow.State) -> String {
        switch s {
        case .waiting: return "wartet"
        case .running: return "läuft"
        case .done: return "fertig"
        case .skipped: return "übersprungen"
        case .needsLogin: return "Anmeldung nötig"
        case .failed: return "Fehler"
        }
    }

    static func tone(_ s: FirstSyncRow.State) -> UFTone {
        switch s {
        case .waiting, .skipped: return .neutral
        case .running: return .info
        case .done: return .ok
        case .needsLogin: return .warn
        case .failed: return .bad
        }
    }
}
