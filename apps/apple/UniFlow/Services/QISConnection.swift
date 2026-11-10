import Foundation
import UniFlowCore
import WebKit

// Noten aus dem QIS der LUH auf dem iPad (F4): die duenne Schicht ueber dem Kern (`QISClient`, `QISGradesSync`),
// wie `HildesheimConnection` fuer das LSF. Die Anmeldung passiert in der Webansicht des Containers (QISLoginView; das
// Passwort tippt der Mensch, gespeichert hoechstens von iOS, nie von der App); der Abruf laeuft mit den Cookies dieser Webansicht ueber `URLSessionUniTransport`, nur auf dem
// Rechner des QIS. Der Sitzungsparameter asi und die Stammdaten der Seiten werden nie gespeichert (Kern).

/// Verbindung zum QIS fuer einen Container (Apple-Nutzer, LUH). Der `ContainerManager` baut je offenem LUH-Container
/// eine; sie haelt ihren Container fest. Abgerufen wird hoechstens alle 20 Stunden von selbst (beim Oeffnen der App,
/// `runIfDue`) und auf Knopfdruck sofort (`run(force: true)`). Ein leerer Notenspiegel ist kein Fehler.
@MainActor
final class QISConnection: ObservableObject {
    enum State: Equatable {
        case notConnected
        /// angemeldet, noch kein Abruf bekannt
        case connected
        case running
        /// letzter erfolgreicher Abruf
        case ok(Date)
        case needsLogin
        case failed(String)
    }

    @Published private(set) var state: State = .notConnected
    @Published private(set) var isRunning = false
    /// Meldung des letzten Abrufs ("2 Leistungen", Fehler) fuer Uni & Noten und den Erstabgleich
    @Published private(set) var lastMessage: String?
    /// Zahl der Leistungen des letzten erfolgreichen Abrufs; nil, solange keiner gelang
    @Published private(set) var lastCount: Int?
    /// Zahl der beendeten Abrufe; offene Seiten laden danach neu (`ufReload`)
    @Published private(set) var finishedRuns = 0
    /// "Angemeldete Prüfungen abrufen" laeuft (Pruefungsanmeldung, nur lesend)
    @Published private(set) var registrationsRunning = false
    /// Meldung des letzten Abrufs der angemeldeten Pruefungen ("2 angemeldete Prüfungen gelesen.", Fehler)
    @Published private(set) var registrationsMessage: String?

    typealias TransportFactory = @MainActor (WKWebsiteDataStore) async -> UniTransport

    let key: DataContainerKey
    /// Datenspeicher der Anmelde-Webansichten dieses Containers (Cookies der QIS-Sitzung)
    let websiteDataStore: WKWebsiteDataStore
    private let host: LocalBackendHost
    private let defaults: UserDefaults
    private let clock: UniFlowClock
    private let makeTransport: TransportFactory
    private let retry: UniRetry
    /// nach einer Anmeldung sofort abrufen (Tests schalten das ab)
    var syncsAfterSignIn = true
    private var current: Task<QISGradesSync.Report?, Never>?
    private(set) var stopped = false
    /// zaehlt jedes Abmelden: ein Abruf, der vorher begann und noch auf die Demo-Pruefung wartete, beginnt danach nicht
    /// mehr (er setzte sonst nach dem Abmelden wieder seinen Stand, Pruefpunkt 362)
    private var signOuts = 0

    /// Rueckfrage vor dem Abmelden (Einstellungen, Uni & Noten)
    static let signOutMessage = "Die QIS-Anmeldung in der Webansicht wird gelöscht, ebenso ein in StudiNow gemerktes Passwort der LUH. Die geladenen Noten bleiben; Stud.IP bleibt angemeldet. Ein Passwort, das iOS gesichert hat, bleibt unter „Passwörter“."

    /// Rechner des QIS aus dem Profil (nur dorthin gehen Anfragen)
    static var qisDomains: [String] { [UniversityProfile.luhQISStart.host?.lowercased() ?? "qis.verwaltung.uni-hannover.de"] }

    init(container c: ActiveContainer, websiteDataStore: WKWebsiteDataStore, clock: UniFlowClock = .system,
         transport: TransportFactory? = nil, retry: UniRetry = UniRetry()) {
        key = c.key
        host = c.host
        defaults = c.defaults
        self.websiteDataStore = websiteDataStore
        self.clock = clock
        self.retry = retry
        makeTransport = transport ?? { store in await URLSessionUniTransport.make(dataStore: store, allowedDomains: QISConnection.qisDomains) }
        lastMessage = defaults.string(forKey: Keys.message)
        lastCount = defaults.object(forKey: Keys.count) as? Int
        state = storedState()
        StudyCatalogSync.attach(host: host)      // Modulkatalog: Ausloeser fuer die Seite Studienverlauf
    }

    // MARK: Einstellungen des Containers (UserDefaults-Suite, gehen mit "Daten dieser Hochschule löschen")

    enum Keys {
        static let connected = "uniflow.qis.connected"
        static let lastRun = "uniflow.qis.lastRun"
        static let login = "uniflow.qis.login"
        static let message = "uniflow.qis.message"
        static let count = "uniflow.qis.count"
        static let all = [connected, lastRun, login, message, count]
    }

    /// Noten hoechstens alle 20 Stunden von selbst (wie am PC und beim LSF)
    static let interval: TimeInterval = 20 * 3600

    var isConnected: Bool { defaults.bool(forKey: Keys.connected) }
    var lastRun: Date? { defaults.object(forKey: Keys.lastRun) as? Date }

    /// Karte "QIS verbinden" bzw. "Erneut anmelden" zeigen
    var needsAttention: Bool { state == .notConnected || state == .needsLogin }

    private func storedState() -> State {
        guard isConnected else { return .notConnected }
        if defaults.bool(forKey: Keys.login) { return .needsLogin }
        return lastRun.map(State.ok) ?? .connected
    }

    private func set(_ s: State) {
        state = s
        switch s {
        case .ok(let d):
            defaults.set(d, forKey: Keys.lastRun)
            defaults.removeObject(forKey: Keys.login)
        case .needsLogin:
            defaults.set(true, forKey: Keys.login)
        case .connected, .notConnected:
            defaults.removeObject(forKey: Keys.login)
        case .running, .failed:
            break
        }
    }

    // MARK: Anmeldung (aus QISLoginView)

    /// Die Webansicht zeigt eine angemeldete QIS-Seite: verbunden, danach gleich abrufen
    func signedIn() {
        defaults.set(true, forKey: Keys.connected)
        set(.connected)
        let store = websiteDataStore
        UniAutoLogin.clearSignedOut(.qis, store: store)        // angemeldet: die Abmelden-Sperre faellt
        UniAutoLogin.signedIn(store, portal: .qis)             // mitgelesenes Passwort jetzt merken (falls zugelassen)
        Task { await UniWebSessions.save(store) }              // QIS-Sitzung ueber Neustarts merken (`UniWebSessions`)
        guard syncsAfterSignIn, !isRunning else { return }
        Task { await run(force: true) }
    }

    /// Abmelden: Verbindung, Stand und die QIS-Cookies der Webansicht (Stud.IP bleibt angemeldet); Noten in der
    /// Datenbank bleiben. Ein gemerktes Passwort der LUH (`UniAutoLogin`) geht mit.
    func signOut() async {
        signOuts += 1
        // laufenden Abruf zuerst anhalten und abwarten (er schriebe danach seinen Stand zurueck)
        if let task = current {
            task.cancel()
            _ = await task.value
        }
        for k in Keys.all { defaults.removeObject(forKey: k) }
        UniAutoLogin.forget(websiteDataStore)                  // gemerktes Passwort der LUH (Schluesselbund)
        UniAutoLogin.markSignedOut(.qis, store: websiteDataStore)   // bewusst abgemeldet: nie still wieder verbinden
        lastMessage = nil
        lastCount = nil
        set(.notConnected)
        await UniWebSessions.ready(websiteDataStore)           // erst die zurueckgesetzte Anmeldung, dann loeschen
        let store = websiteDataStore.httpCookieStore
        for c in await store.allCookies() where Self.qisDomains.contains(where: { c.domain.lowercased().hasSuffix($0) }) {
            await store.deleteCookie(c)
        }
        // Gemerktes ohne die QIS-Cookies neu schreiben (die Anmeldung fuer Stud.IP bleibt)
        await UniWebSessions.save(websiteDataStore)
    }

    // MARK: Abruf

    private var due: Bool {
        guard let last = lastRun else { return true }
        return clock.now.timeIntervalSince(last) >= Self.interval
    }

    /// Beim Oeffnen der App: hoechstens alle 20 Stunden, nur verbunden; nie automatisch unter XCTest oder mit
    /// Startargumenten fuer Bildvergleiche (dieselbe Regel wie der Stud.IP-Abgleich)
    func runIfDue() {
        guard StudIPSync.automaticRunAllowed(), isConnected, !isRunning, state != .needsLogin, due else { return }
        Task { await run() }
    }

    /// Ein Abruf; `force`: auch vor Ablauf der 20 Stunden (Knopf "Noten abrufen")
    @discardableResult
    func run(force: Bool = false) async -> QISGradesSync.Report? {
        guard !isRunning, !stopped, isConnected, force || due else { return nil }
        let signOutsBefore = signOuts
        // Demo-Inhalte aktiv: nie zur Hochschule, keine Anfrage (DemoContent); erst nach "Entfernen" wieder
        if await host.demoActive() { return nil }
        // waehrend der Pruefung angehalten, schon ein Abruf oder abgemeldet
        guard !isRunning, !stopped, signOuts == signOutsBefore, isConnected else { return nil }
        isRunning = true
        let before = state
        set(.running)
        let task = Task { await self.perform() }
        current = task
        let report = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        current = nil
        apply(report, before: before)
        isRunning = false
        finishedRuns += 1
        return report
    }

    /// Anhalten vor dem Loeschen des Containers (ContainerSync)
    func stop() async {
        stopped = true
        guard let task = current else { return }
        task.cancel()
        _ = await task.value
    }

    private func perform() async -> QISGradesSync.Report? {
        let transport = await makeTransport(websiteDataStore)
        do {
            let db = try await host.backend().context.database
            let report = await QISGradesSync.run(db: db, transport: transport, clock: clock, retry: retry)
            // Pruefungsanmeldung: im selben Abruf auch "Info über angemeldete Prüfungen" lesen (nur lesend; ein Fehler
            // dort aendert den Stand der Noten nicht, er steht in settings.exam_registration_run)
            if report.ok, !Task.isCancelled {
                let r = await QISRegistrationsSync.run(db: db, transport: transport, clock: clock, retry: retry)
                if !r.cancelled { registrationsMessage = r.message }
            }
            return report
        } catch {
            return QISGradesSync.Report(message: LocalBackendHost.message(for: error))
        }
    }

    /// Knopf "Angemeldete Prüfungen abrufen" (Pruefungsanmeldung): liest nur "Info über angemeldete Prüfungen" mit der
    /// Sitzung der Webansicht. Meldet nie an oder ab. nil ohne Verbindung, waehrend eines Abrufs oder mit Demo-Inhalten
    @discardableResult
    func fetchRegistrations() async -> QISRegistrationsSync.Report? {
        guard isConnected, !stopped, !isRunning, !registrationsRunning else { return nil }
        if await host.demoActive() { return nil }
        guard isConnected, !stopped, !registrationsRunning else { return nil }
        registrationsRunning = true
        defer { registrationsRunning = false }
        let transport = await makeTransport(websiteDataStore)
        let r: QISRegistrationsSync.Report
        do {
            let db = try await host.backend().context.database
            r = await QISRegistrationsSync.run(db: db, transport: transport, clock: clock, retry: retry)
        } catch {
            r = QISRegistrationsSync.Report(message: LocalBackendHost.message(for: error))
        }
        if !r.cancelled { registrationsMessage = r.message }
        if r.needsLogin {
            set(.needsLogin)
            Task { await self.autoLogin() }
        }
        finishedRuns += 1                                       // offene Seiten laden neu (Haken)
        return r
    }

    private func apply(_ r: QISGradesSync.Report?, before: State) {
        guard let r else { set(.failed("Abruf nicht möglich.")); return }
        if r.cancelled {
            set(before == .running ? .connected : before)
            return
        }
        lastMessage = r.message
        defaults.set(r.message, forKey: Keys.message)
        if let n = r.grades {
            lastCount = n
            defaults.set(n, forKey: Keys.count)
            set(.ok(clock.now))
            StudyCatalogSync.trigger(host: host)     // Studiengang aus dem Notenspiegel -> Modulkatalog suchen (Hintergrund)
        } else if r.needsLogin {
            set(.needsLogin)
            Task { await self.autoLogin() }                    // still mit dem gespeicherten Passwort, dann einmal neu
        } else {
            set(.failed(r.message))
        }
    }

    // MARK: Automatisch anmelden (docs/AUTOMATISCH-ANMELDEN-2026-11-06.md)

    /// Abgelaufen: unsichtbar mit dem gespeicherten Passwort (nur mit Zustimmung, nur dieses Geraet) auf der QIS-Seite
    /// anmelden, dann genau einmal neu abrufen (`signedIn`). Scheitert es (falsches Passwort), bleibt "Anmeldung nötig".
    /// Nie waehrend des Abmeldens, nie im Hintergrund, nie in einer Schleife (`UniAutoLoginMachine`).
    @discardableResult
    func autoLogin(userAction: Bool = false) async -> Bool {
        guard isConnected, state == .needsLogin, !stopped else { return false }
        let before = signOuts
        let d = await UniAutoLogin.handleExpiry(portal: "qis", store: websiteDataStore, entry: QISClient.startURL,
                                                userAction: userAction) { url, html in QISConnection.isSignedInPage(url, html: html) }
        guard d == .retryOnce, signOuts == before, isConnected, !stopped else { return false }
        for _ in 0..<300 where isRunning { try? await Task.sleep(nanoseconds: 200_000_000) }   // Abruf von eben zu Ende
        guard signOuts == before, isConnected, !stopped else { return false }
        signedIn()                                              // verbunden, ruft gleich (einmal) ab
        return true
    }

    /// wie `QISLoginPane.isSignedIn`: Seite des QIS mit Abmelden-Link, ohne Anmeldeformular
    static func isSignedInPage(_ url: URL, html: String) -> Bool {
        guard url.scheme?.lowercased() == "https", qisDomains.contains(url.host?.lowercased() ?? "") else { return false }
        let page = QISPage.parse(html: html, url: url)
        return page.isLoggedIn && !page.hasLoginForm
    }

    /// Uni-Zugang einmal speichern (10.11.2026): noch nie verbunden -> mit dem gespeicherten Zugang zum ersten Mal
    /// anmelden (unsichtbar, nur im Vordergrund, `UniAutoLogin.handleExpiry`), dann verbunden und gleich abrufen.
    /// Nie nach bewusstem Abmelden (`UniAutoLogin.signedOut`), nie mit einem abgelehnten Passwort.
    @discardableResult
    func connectWithStoredLogin(userAction: Bool = false) async -> Bool {
        guard !isConnected, !stopped, !UniAutoLogin.signedOut(.qis, store: websiteDataStore) else { return false }
        let before = signOuts
        let d = await UniAutoLogin.handleExpiry(portal: "qis", store: websiteDataStore, entry: QISClient.startURL,
                                                userAction: userAction) { url, html in QISConnection.isSignedInPage(url, html: html) }
        guard d == .retryOnce, signOuts == before, !isConnected, !stopped else { return false }
        signedIn()                                              // verbunden, ruft gleich (einmal) ab
        return true
    }

    // MARK: Anzeige

    /// "QIS: 16:30 ok", "QIS: Anmeldung nötig" (Uhrzeit in Berlin; nicht von heute mit Datum)
    static func statusText(_ state: State, now: Date = Date()) -> String {
        switch state {
        case .notConnected: return "QIS: nicht verbunden"
        case .connected: return "QIS: verbunden"
        case .running: return "QIS: ruft ab …"
        case .ok(let d): return "QIS: \(HildesheimConnection.time(d, now: now)) ok"
        case .needsLogin: return "QIS: Anmeldung nötig"
        case .failed: return "QIS: Fehler"
        }
    }

    /// Text unter dem Notenspiegel, wenn er leer ist: ehrlich je nach Stand (nicht verbunden, Anmeldung noetig, Abruf
    /// gelungen ohne Leistungen, noch kein Abruf)
    static func emptyText(_ state: State, lastCount: Int?) -> String {
        switch state {
        case .notConnected: return "Verbinde QIS, damit StudiNow deinen Notenspiegel holt."
        case .needsLogin: return "Die QIS-Anmeldung ist abgelaufen. Melde dich erneut an, dann holt StudiNow deinen Notenspiegel."
        case .running: return "Der Notenspiegel wird gerade abgerufen …"
        case .ok, .failed, .connected:
            if lastCount == 0 { return QISGradesSync.emptyNotice + " Sobald eine Note eingetragen ist, erscheint sie hier nach dem nächsten Abruf." }
            return "Noch keine Leistungen geladen. Nach dem nächsten Abruf erscheinen hier alle Prüfungsleistungen aus deinem QIS-Notenspiegel."
        }
    }
}

extension QISConnection: ContainerSync {}

// MARK: Bescheinigungen (CertificateCenter, docs/BESCHEINIGUNGEN-2026-11-06.md): dieselbe QIS-Sitzung der Webansicht
extension QISConnection {
    var certificateClock: UniFlowClock { clock }
    func certificateTransport() async -> UniTransport { await makeTransport(websiteDataStore) }
    var certificateHost: LocalBackendHost { host }
    /// Sitzung beim Lesen der Bescheinigungen abgelaufen: "Anmeldung nötig" wie beim Notenabruf
    func certificatesExpired() { if isConnected { set(.needsLogin) } }
}
