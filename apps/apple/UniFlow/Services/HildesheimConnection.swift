import Foundation
import os
import UniFlowCore
import WebKit

// Universitaet Hildesheim auf dem iPad: Learnweb (Kurse, Dateien) und LSF (Stundenplan, Notenspiegel), die duenne
// Schicht der App ueber dem Kern der PC-Sitzung (docs/AUFTRAG-HILDESHEIM-IPAD.md, Punkte 2 und 3). Abgleich, Regeln,
// Speichern und Ausfallsicherheit stehen im Kern (`HildesheimSync`, `LearnwebAPI`, `LSFClient`, `MoodleSSO`,
// `HildesheimCAS`); hier nur: Anmeldung im WKWebView mit dem Datenspeicher des Containers, Learnweb-Schluessel im
// Schluesselbund, Transport (`URLSessionUniTransport`), wann abgeglichen wird und der Stand je Quelle.

/// Verbindung und Abgleich der Uni Hildesheim fuer einen Container (Apple-Nutzer, Uni Hildesheim). Der
/// `ContainerManager` baut je offenem Hildesheimer Container eine; sie haelt ihren Container fest (ein Wechsel der
/// Hochschule baut eine neue).
///
/// Learnweb: bevorzugt mit Schluessel aus dem Moodle-SSO (REST, Moodle zaehlt keine Aufrufe; Schluessel im
/// Schluesselbund unter `<nutzer>.hildesheim.learnweb.token`), sonst mit der CAS-/Moodle-Sitzung der Webansicht. Der
/// Schluessel gilt fuer die Learnweb-Instanz, bei der er geholt wurde; im naechsten Jahr (learnweb2027) heisst es neu
/// verbinden. LSF: immer mit der Sitzung der Webansicht.
///
/// Abgeglichen wird beim Oeffnen der App (hoechstens alle 30 Minuten) und auf Knopfdruck, Noten hoechstens alle
/// 20 Stunden wie am PC (auf Knopfdruck "Noten abrufen" sofort). `report.messages` stehen in der Statusleiste, dazu
/// der Stand je Quelle ("Learnweb: 16:30 ok", "LSF: Anmeldung nötig"). Eine Quelle, die waehrend eines Laufs verbunden
/// wird, bewertet erst der direkt folgende eigene Lauf. Vor dem Loeschen des Containers haelt `stop` einen laufenden
/// Abgleich an und wartet auf sein Ende.
@MainActor
final class HildesheimConnection: ObservableObject {
    enum Source: String, CaseIterable, Identifiable {
        case learnweb = "Learnweb"
        case lsf = "LSF"
        var id: String { rawValue }
    }

    enum State: Equatable {
        case notConnected
        /// verbunden, noch kein Abgleich in diesem App-Lauf und keiner bekannt
        case connected
        case running
        /// letzter erfolgreicher Abgleich
        case ok(Date)
        case needsLogin
        case failed(String)
    }

    @Published private(set) var learnweb: State = .notConnected
    @Published private(set) var lsf: State = .notConnected
    @Published private(set) var isRunning = false
    /// Meldungen des letzten Abgleichs (`HildesheimSync.Report.messages`) fuer die Statusleiste
    @Published private(set) var messages: [String] = []
    @Published private(set) var lastRun: Date?
    /// Zahl der beendeten Abgleiche; offene Seiten laden danach neu (`ufReload`)
    @Published private(set) var finishedRuns = 0
    /// Bericht des letzten Abgleichs (Tests, Diagnose)
    private(set) var lastReport: HildesheimSync.Report?

    /// Transport je Lauf aus dem Datenspeicher der Webansichten (Tests: feste Antworten)
    typealias TransportFactory = @MainActor (WKWebsiteDataStore) async -> UniTransport

    let key: DataContainerKey
    let layout: DataContainerLayout
    /// Datenspeicher der Anmelde-Webansichten dieses Containers (Cookies von CAS, Learnweb, LSF)
    let websiteDataStore: WKWebsiteDataStore
    private let host: LocalBackendHost
    private let defaults: UserDefaults
    /// Learnweb-Schluessel dieses Containers (nie Benutzername oder Passwort)
    let tokens: UniversityTokenStore
    private let clock: UniFlowClock
    private let makeTransport: TransportFactory
    private let retry: UniRetry
    /// nach einer Anmeldung sofort abgleichen (Tests schalten das ab)
    var syncsAfterSignIn = true
    /// laufender Abgleich (zum Anhalten vor dem Loeschen des Containers, `stop`)
    private var current: Task<HildesheimSync.Report?, Never>?
    /// angehalten (Container wird geloescht): kein weiterer Abgleich
    private(set) var stopped = false
    /// Quellen, die waehrend eines laufenden Abgleichs (neu) verbunden wurden: der laufende bewertet sie nicht (sie
    /// bleiben "verbunden"), direkt danach folgt ein eigener Lauf
    private var connectedDuringRun: Set<Source> = []

    init(container c: ActiveContainer, websiteDataStore: WKWebsiteDataStore, clock: UniFlowClock = .system,
         transport: TransportFactory? = nil, retry: UniRetry = UniRetry()) {
        key = c.key
        layout = c.layout
        host = c.host
        defaults = c.defaults
        tokens = c.tokens
        self.websiteDataStore = websiteDataStore
        self.clock = clock
        self.retry = retry
        makeTransport = transport ?? { store in await URLSessionUniTransport.make(dataStore: store) }
        lastRun = defaults.object(forKey: Keys.lastRun) as? Date
        messages = defaults.stringArray(forKey: Keys.messages) ?? []
        learnweb = storedState(.learnweb)
        lsf = storedState(.lsf)
    }

    // MARK: Einstellungen des Containers (UserDefaults-Suite, gehen mit "Daten dieser Hochschule löschen")

    enum Keys {
        static let learnwebMode = "uniflow.hildesheim.learnweb.mode"
        static let learnwebBase = "uniflow.hildesheim.learnweb.base"
        static let lsfConnected = "uniflow.hildesheim.lsf.connected"
        static let lastRun = "uniflow.hildesheim.lastRun"
        static let messages = "uniflow.hildesheim.messages"
        static let gradesRun = "uniflow.hildesheim.grades.lastRun"
        static func ok(_ s: Source) -> String { "uniflow.hildesheim.\(s.rawValue.lowercased()).ok" }
        static func login(_ s: Source) -> String { "uniflow.hildesheim.\(s.rawValue.lowercased()).login" }
    }

    /// Schluessel-Dienst im Profil (`tokenServices`)
    static let tokenService = "learnweb"

    enum LearnwebMode: String { case token, session }

    var learnwebMode: LearnwebMode? { defaults.string(forKey: Keys.learnwebMode).flatMap(LearnwebMode.init(rawValue:)) }
    var lsfConnected: Bool { defaults.bool(forKey: Keys.lsfConnected) }

    func isConnected(_ s: Source) -> Bool { s == .learnweb ? learnwebMode != nil : lsfConnected }
    var anyConnected: Bool { Source.allCases.contains(where: isConnected) }

    func state(_ s: Source) -> State { s == .learnweb ? learnweb : lsf }

    /// Karte "… verbinden" bzw. "Erneut anmelden" zeigen
    func needsAttention(_ s: Source) -> Bool {
        let st = state(s)
        return st == .notConnected || st == .needsLogin
    }

    private func storedState(_ s: Source) -> State {
        guard isConnected(s) else { return .notConnected }
        if defaults.bool(forKey: Keys.login(s)) { return .needsLogin }
        return (defaults.object(forKey: Keys.ok(s)) as? Date).map(State.ok) ?? .connected
    }

    private func set(_ s: Source, _ state: State) {
        if s == .learnweb { learnweb = state } else { lsf = state }
        switch state {
        case .ok(let d):
            defaults.set(d, forKey: Keys.ok(s))
            defaults.removeObject(forKey: Keys.login(s))
        case .needsLogin:
            defaults.set(true, forKey: Keys.login(s))
        case .connected, .notConnected:
            defaults.removeObject(forKey: Keys.login(s))
        case .running, .failed:
            break
        }
    }

    // MARK: Anmeldung (aus HildesheimLogin)

    /// Learnweb verbunden: mit Schluessel (Moodle-SSO) oder mit der Sitzung der Webansicht. false, wenn sich der
    /// Schluessel nicht ablegen liess (dann bleibt alles wie vorher).
    @discardableResult
    func learnwebSignedIn(token: LearnwebToken?, base: String) -> Bool {
        if let token {
            guard tokens.saveToken(token.keychainValue, .hildesheim, service: Self.tokenService) else { return false }
            defaults.set(LearnwebMode.token.rawValue, forKey: Keys.learnwebMode)
        } else {
            tokens.deleteToken(.hildesheim, service: Self.tokenService)
            defaults.set(LearnwebMode.session.rawValue, forKey: Keys.learnwebMode)
        }
        defaults.set(base, forKey: Keys.learnwebBase)
        set(.learnweb, .connected)
        afterSignIn(.learnweb)
        return true
    }

    /// LSF verbunden (die Webansicht zeigt eine angemeldete Seite des LSF, `LSFClient.isLoggedIn`)
    func lsfSignedIn() {
        defaults.set(true, forKey: Keys.lsfConnected)
        set(.lsf, .connected)
        afterSignIn(.lsf)
    }

    /// Nach einer Anmeldung abgleichen. Laeuft schon einer (der uebliche Weg: Learnweb verbunden, Abgleich laeuft, dann
    /// LSF verbinden), gilt die Quelle fuer ihn nicht; sie bekommt direkt danach einen eigenen Lauf.
    private func afterSignIn(_ s: Source) {
        if isRunning {
            connectedDuringRun.insert(s)
            return
        }
        guard syncsAfterSignIn else { return }
        Task { await run() }
    }

    /// Abmelden: Schluessel, Verbindungen und Anmeldungen der Webansicht (CAS, Learnweb, LSF) der Uni Hildesheim
    /// dieses Kontos; heruntergeladene Dateien, Stundenplan und Noten bleiben. Ein Passwort hat die App nicht zu
    /// loeschen (das merkt hoechstens iOS im Schluesselbund).
    func signOut() async {
        tokens.deleteAll(for: .hildesheim)
        for k in [Keys.learnwebMode, Keys.learnwebBase, Keys.lsfConnected] { defaults.removeObject(forKey: k) }
        for s in Source.allCases {
            defaults.removeObject(forKey: Keys.ok(s))
            set(s, .notConnected)
        }
        await websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    /// Transport fuer Anfragen ausserhalb eines Abgleichs (Anmeldung: Learnweb-Instanz, Moodle-Konfiguration)
    func transport() async -> UniTransport { await makeTransport(websiteDataStore) }

    /// Jahr und Monat heute in Berlin (Learnweb-Instanz des Semesters, `Learnweb.discoverBase`)
    var yearMonth: (year: Int, month: Int) {
        // clock.today ist immer "YYYY-MM-DD"
        let d = clock.today.split(separator: "-").compactMap { Int($0) }
        return (d.first ?? 0, d.count > 1 ? d[1] : 0)
    }

    // MARK: Abgleich

    /// Beim Oeffnen der App: hoechstens alle 30 Minuten, nur mit einer verbundenen Quelle
    func runIfDue() {
        // dieselbe Regel wie beim Stud.IP-Abgleich: nie automatisch unter XCTest, -UFNoStudIPSync oder Startargumenten
        guard StudIPSync.automaticRunAllowed(), anyConnected, !isRunning else { return }
        if let last = lastRun, clock.now.timeIntervalSince(last) < 30 * 60 { return }
        Task { await run() }
    }

    /// Noten hoechstens alle 20 Stunden (wie am PC)
    private var gradesDue: Bool {
        guard let last = defaults.object(forKey: Keys.gradesRun) as? Date else { return true }
        return clock.now.timeIntervalSince(last) >= 20 * 3600
    }

    /// Ein Abgleich: Learnweb, danach LSF-Stundenplan und Noten (`HildesheimSync.run`). `forceGrades`: Noten auch vor
    /// Ablauf der 20 Stunden. Wurde waehrend des Laufs eine Quelle verbunden, folgt direkt danach ein weiterer Lauf.
    @discardableResult
    func run(forceGrades: Bool = false) async -> HildesheimSync.Report? {
        guard !isRunning, !stopped, anyConnected else { return nil }
        isRunning = true
        let task = Task { await self.perform(forceGrades: forceGrades) }
        current = task
        let report = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        current = nil
        isRunning = false
        finishedRuns += 1
        if !connectedDuringRun.isEmpty {
            connectedDuringRun = []
            if syncsAfterSignIn, !stopped { Task { await run() } }
        }
        return report
    }

    /// Anhalten, bevor der Container geloescht wird: laufenden Abgleich abbrechen (`Task.cancel`, der Kern endet als
    /// "abgebrochen") und auf sein Ende warten, danach schreibt er nichts mehr; diese Verbindung gleicht nicht mehr ab
    func stop() async {
        stopped = true
        connectedDuringRun = []
        guard let task = current else { return }
        task.cancel()
        _ = await task.value
    }

    private func perform(forceGrades: Bool) async -> HildesheimSync.Report? {
        // nur die Quellen, die zu Beginn verbunden sind, bewertet dieser Lauf (vor dem ersten await festgehalten)
        let sources = Set(Source.allCases.filter(isConnected))
        let before = (learnweb, lsf)
        for s in sources { set(s, .running) }
        let transport = await makeTransport(websiteDataStore)
        var lw = LearnwebAccess()
        if sources.contains(.learnweb) { lw = await learnwebAccess(transport: transport) }
        let lsfClient = sources.contains(.lsf) ? LSFClient(transport: transport, retry: retry) : nil
        let includeGrades = forceGrades || gradesDue
        let database: SQLiteDatabase
        do {
            database = try await host.backend().context.database
        } catch {
            let message = LocalBackendHost.message(for: error)
            for s in sources.subtracting(connectedDuringRun) where isConnected(s) { set(s, .failed(message)) }
            finish(messages: [message], report: nil, succeeded: false)
            return nil
        }
        var report = HildesheimSync.Report()
        if lw.api != nil || lsfClient != nil {
            // Seitentexte mit PDFKit (Suche, Seitenzuordnung einer neuen Fassung, S7)
            report = await HildesheimSync(db: database, container: layout, learnweb: lw.api, lsf: lsfClient, transport: transport,
                                          clock: clock, retry: retry, tools: AppDocumentTools())
                .run(includeGrades: includeGrades)
        }
        apply(report, sources: sources.subtracting(connectedDuringRun), learnweb: lw, includeGrades: includeGrades, before: before)
        return report
    }

    /// Learnweb fuer einen Lauf: Zugang, oder warum es keinen gibt (Meldung; Anmeldung noetig, ohne die Uni zu fragen)
    private struct LearnwebAccess {
        var api: LearnwebAPI?
        var loginNeeded = false
        var message: String?
    }

    /// Learnweb-Zugang fuer diesen Lauf: Instanz des Semesters (`Learnweb.discoverBase`; nicht erreichbar: die beim
    /// Verbinden gemerkte), Schluessel nur fuer die Instanz, bei der er geholt wurde
    private func learnwebAccess(transport: UniTransport) async -> LearnwebAccess {
        guard let mode = learnwebMode else { return LearnwebAccess() }
        let stored = defaults.string(forKey: Keys.learnwebBase)
        let found = await Learnweb.discoverBase(year: yearMonth.year, month: yearMonth.month, transport: transport)
        guard let base = found ?? stored else {
            return LearnwebAccess(message: "Learnweb: \(HildesheimError.noLearnwebInstance.description)")
        }
        switch mode {
        case .session:
            return LearnwebAccess(api: LearnwebAPI(base: base, mode: .session, transport: transport, retry: retry))
        case .token:
            guard let raw = tokens.token(.hildesheim, service: Self.tokenService), let token = LearnwebToken(raw) else {
                return LearnwebAccess(loginNeeded: true, message: "Learnweb: Der Learnweb-Schlüssel fehlt auf diesem iPad. Bitte neu verbinden.")
            }
            guard stored == nil || stored == base else {
                return LearnwebAccess(loginNeeded: true, message: "Learnweb: Das Learnweb des neuen Semesters braucht eine neue Anmeldung.")
            }
            return LearnwebAccess(api: LearnwebAPI(base: base, mode: .token(token), transport: transport, retry: retry))
        }
    }

    /// Stand je Quelle aus dem Bericht: Anmeldung noetig (`needsLogin`), zu Ende gelaufen (`completed`), Abbruch (alter
    /// Stand bleibt), sonst Fehler mit der Meldung des Kerns. Bewertet werden nur `sources` (zu Beginn des Laufs
    /// verbunden und nicht waehrend des Laufs neu angemeldet) und nur, solange sie noch verbunden sind.
    private func apply(_ r: HildesheimSync.Report, sources: Set<Source>, learnweb lw: LearnwebAccess, includeGrades: Bool,
                       before: (State, State)) {
        let now = clock.now
        let all = (lw.message.map { [$0] } ?? []) + r.messages
        func message(_ prefixes: [String]) -> String {
            all.first { m in prefixes.contains { m.hasPrefix($0) } } ?? r.refused ?? "Abgleich nicht abgeschlossen."
        }
        typealias Part = HildesheimSync.Report.Part
        var succeeded = !r.cancelled
        if sources.contains(.learnweb), isConnected(.learnweb) {
            if lw.loginNeeded || r.needsLogin.contains(Source.learnweb.rawValue) {
                set(.learnweb, .needsLogin)
                succeeded = false
            } else if lw.api != nil, r.completed.contains(Part.learnweb) {
                set(.learnweb, .ok(now))
            } else if r.cancelled {
                set(.learnweb, before.0)
            } else {
                set(.learnweb, .failed(message(["Learnweb"])))
                succeeded = false
            }
        }
        if sources.contains(.lsf), isConnected(.lsf) {
            let planOK = r.completed.contains(Part.plan)
            let gradesOK = !includeGrades || r.completed.contains(Part.grades)
            if r.needsLogin.contains(Source.lsf.rawValue) {
                set(.lsf, .needsLogin)
                succeeded = false
            } else if planOK && gradesOK {
                set(.lsf, .ok(now))
            } else if r.cancelled {
                set(.lsf, before.1)
            } else {
                set(.lsf, .failed(message(["LSF", "Stundenplan", "Notenspiegel"])))
                succeeded = false
            }
        }
        if r.completed.contains(Part.grades) { defaults.set(now, forKey: Keys.gradesRun) }
        finish(messages: all, report: r, succeeded: succeeded)
    }

    /// Ende eines Laufs: Meldungen merken; die 30-Minuten-Sperre (`lastRun`) wie beim Stud.IP-Abgleich nur nach einem
    /// Lauf ohne Fehler (vorher auch nach einem gescheiterten, dann wartete der naechste Versuch 30 Minuten)
    private func finish(messages all: [String], report: HildesheimSync.Report?, succeeded: Bool) {
        lastReport = report
        messages = all
        defaults.set(all, forKey: Keys.messages)
        guard succeeded else { return }
        lastRun = clock.now
        defaults.set(lastRun, forKey: Keys.lastRun)
    }

    // MARK: Anzeige

    /// "Learnweb: 16:30 ok", "LSF: Anmeldung nötig" (Uhrzeit in Berlin; nicht von heute mit Datum)
    static func statusText(_ s: Source, _ state: State, now: Date = Date()) -> String {
        let what: String
        switch state {
        case .notConnected: what = "nicht verbunden"
        case .connected: what = "verbunden"
        case .running: what = "gleicht ab …"
        case .ok(let d): what = "\(time(d, now: now)) ok"
        case .needsLogin: what = "Anmeldung nötig"
        case .failed: what = "Fehler"
        }
        return "\(s.rawValue): \(what)"
    }

    /// Uhrzeit fuer Statustexte (auch QISConnection)
    static func time(_ d: Date, now: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .current
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.timeZone = cal.timeZone
        f.dateFormat = cal.isDate(d, inSameDayAs: now) ? "HH:mm" : "dd.MM. HH:mm"
        return f.string(from: d)
    }
}

/// Anmeldung bei Learnweb oder LSF in der Webansicht des Containers (CAS der Uni). Die Studierenden tippen ihre
/// Zugangsdaten selbst ein und tippen selbst auf "Anmelden"; die App liest und fuellt keine Felder, ein gespeichertes
/// Passwort setzt hoechstens iOS ein (Passwort-Autofill aus dem Schluesselbund).
///
/// - LSF: `HildesheimCAS.lsfLoginURL`; fertig, sobald eine Seite des LSF angemeldet ist (`LSFClient.isLoggedIn`).
/// - Learnweb: Instanz des Semesters (`Learnweb.discoverBase`), dann `MoodleSSO.publicConfig`. Ist das SSO moeglich,
///   oeffnet die Webansicht `MoodleSSO.launchURL(config:base:passport:)` mit einem neuen Passport; die abschliessende
///   Weiterleitung `<schema>://token=…` faengt `intercept` ab (nie an das System), `MoodleSSO.parseLaunchToken` prueft
///   Passport und Adresse, der Schluessel geht in den Schluesselbund. Sonst der Sitzungsweg
///   `HildesheimCAS.learnwebLoginURL(base:)`: fertig auf einer angemeldeten Learnweb-Seite (`Learnweb.isLoggedIn`).
@MainActor
final class HildesheimLogin: ObservableObject {
    nonisolated static let log = Logger(subsystem: "de.uniflow.ai", category: "hildesheim-login")

    enum Stage: Equatable {
        case preparing
        /// Webansicht mit dieser Seite
        case page(URL)
        case done
        case failed(String)
    }

    @Published private(set) var stage: Stage = .preparing
    /// Fehlertext des CAS (z. B. falsches Passwort), aus #loginErrorsPanel
    @Published private(set) var casError: String?
    let target: HildesheimConnection.Source
    let connection: HildesheimConnection
    /// Learnweb ueber das Moodle-SSO (Schluessel) statt der Sitzung
    private(set) var viaToken = false
    private(set) var base: String?
    private var passport: String?
    private var scheme = MoodleSSO.defaultScheme
    private var siteURLs: [String] = []

    init(target: HildesheimConnection.Source, connection: HildesheimConnection) {
        self.target = target
        self.connection = connection
    }

    /// Startseite bestimmen (Learnweb: Netz fuer Instanz und Konfiguration, ohne Anmeldedaten)
    func prepare() async {
        stage = .preparing
        casError = nil
        switch target {
        case .lsf:
            stage = URL(string: HildesheimCAS.lsfLoginURL).map(Stage.page) ?? .failed("Anmeldeseite des LSF fehlt.")
        case .learnweb:
            let t = await connection.transport()
            let day = connection.yearMonth
            let found = await Learnweb.discoverBase(year: day.year, month: day.month, transport: t)
            guard let b = found else {
                stage = .failed("Das Learnweb ist gerade nicht erreichbar. Bitte prüfe die Verbindung und versuche es erneut.")
                return
            }
            base = b
            do {
                let config = try await MoodleSSO.publicConfig(base: b, transport: t)
                let p = MoodleSSO.newPassport()
                let launch = try MoodleSSO.launchURL(config: config, base: b, passport: p)
                guard let url = URL(string: launch) else { throw HildesheimError.ssoUnavailable("Startadresse") }
                passport = p
                scheme = config.urlScheme
                siteURLs = [config.wwwroot, config.httpsWWWRoot].compactMap { $0 }
                viaToken = true
                stage = .page(url)
            } catch {
                // Uni erlaubt das App-Schema nicht oder die Schnittstelle ist aus: Sitzung der Webansicht
                viaToken = false
                passport = nil
                stage = URL(string: HildesheimCAS.learnwebLoginURL(base: b)).map(Stage.page) ?? .failed("Anmeldeseite des Learnweb fehlt.")
            }
        }
    }

    /// Fuer `decidePolicyFor navigationAction`: true = Navigation abbrechen. Alles ausser http(s) und about geht nie an
    /// das System (keine andere App); die Moodle-Antwort `<schema>://token=…` wird hier ausgewertet. http im Hauptrahmen
    /// haelt die Webansicht selbst an (`StudIPWebView.blocksMainFrame`).
    func intercept(_ url: URL) -> Bool {
        let s = url.scheme?.lowercased() ?? ""
        if s == "https" || s == "http" || s == "about" { return false }
        if s == "file", DebugUniStub.isActive { return false }                 // nur Debug: lokale Nachbildung der Anmeldeseite
        guard target == .learnweb, viaToken, let base, let passport,
              MoodleSSO.isTokenRedirect(url.absoluteString, scheme: scheme) else { return true }
        self.passport = nil                                              // jede Antwort gilt nur einmal
        guard let token = MoodleSSO.parseLaunchToken(url.absoluteString, base: base, passport: passport, scheme: scheme,
                                                     siteURLs: siteURLs) else {
            stage = .failed("Die Antwort des Learnweb passt nicht zu dieser Anmeldung. Bitte versuche es erneut.")
            return true
        }
        stage = connection.learnwebSignedIn(token: token, base: base)
            ? .done : .failed("Der Learnweb-Schlüssel ließ sich nicht im Schlüsselbund dieses iPads ablegen.")
        return true
    }

    /// Nur Debug mit -UFLoginStub (DebugUniStub): die Nachbildung zeigt "angemeldet" - verbunden wie nach der echten
    /// Anmeldung (Learnweb mit erfundenem Schluessel fuer die gefundene Instanz, LSF ueber die Sitzung)
    func stubSignedIn() {
        guard DebugUniStub.isActive, stage != .done else { return }
        switch target {
        case .lsf:
            connection.lsfSignedIn()
            stage = .done
        case .learnweb:
            guard let base else { return }
            stage = connection.learnwebSignedIn(token: viaToken ? LearnwebToken("StubSchluessel0001") : nil, base: base) ? .done : .failed("Stub")
        }
    }

    /// Nach jeder geladenen Seite (Hauptrahmen): fertig? Fehlertext des CAS?
    func pageLoaded(url: URL?, html: String) {
        guard stage != .done, let url else { return }
        if HildesheimCAS.isCASPage(url.absoluteString) {
            casError = HildesheimCAS.errorText(html: html)
            return
        }
        casError = nil
        switch target {
        case .lsf:
            // Nur Rechner, Pfad und Merkmale ins Protokoll (keine Abfrage mit Ticket oder Sitzung, kein Seiteninhalt):
            // so laesst sich eine echte LSF-Seite pruefen, die die Anmeldung nicht erkennt
            Self.log.info("LSF-Seite \(url.host ?? "-", privacy: .public)\(url.path, privacy: .public): Laenge \(html.count), abmelden \(html.range(of: "abmelden", options: .caseInsensitive) != nil), auth.logout \(html.contains("auth.logout")), auth.login \(html.contains("auth.login"))")
            // dieselbe Regel wie fuer jede Seite im Abgleich (LSF ueber HTTPS mit "Abmelden")
            if LSFClient.isLoggedIn(html: html, url: url) {
                connection.lsfSignedIn()
                stage = .done
            }
        case .learnweb:
            // Sitzungsweg: angemeldete Seite der Instanz (beim SSO-Weg zaehlt nur der Schluessel)
            guard !viaToken, let base, url.absoluteString.hasPrefix(base + "/"), Learnweb.isLoggedIn(html: html) else { return }
            if connection.learnwebSignedIn(token: nil, base: base) { stage = .done }
        }
    }
}
